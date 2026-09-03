#!/usr/bin/env bash
# sweep_link.sh — M3-D: find each link's maximum reliable speed.
#
#   tools/sweep_link.sh D1 <clk_per_bit> [clk_per_bit ...]   # sweep link 1
#   tools/sweep_link.sh D2 <host_baud>   [host_baud ...]     # sweep link 2
#
# Runs at a LIGHT LOAD (BCLK_DIV=25, ~30 kB/s) on purpose: at 7 % of capacity a
# failure cannot be congestion, only the receiver or the wire. The gateway runs in
# MODE_DIAG so it can report on link 1 itself, which is the only way to tell the
# two links apart -- see docs/plans/m3d-method.md.
set -u
cd "$(dirname "$0")/.."
ROOT=$PWD
IDE=/Applications/GowinIDE.app/Contents/Resources/Gowin_EDA/IDE
PRG=/Applications/GowinIDE.app/Contents/Resources/Gowin_EDA/Programmer/bin/programmer_cli
PY=$ROOT/.venv/bin/python
SKETCH=firmware/fpga_uart_bridge/fpga_uart_bridge.ino
DIR=firmware/fpga_uart_bridge
PORT=$(ls /dev/cu.wchusbserial* 2>/dev/null | head -1)
EXPECT_SYNC=29.4          # BCLK_DIV=56 at 54 MHz -> 15067/512 frames per second

set_mode()  { sed -i '' -E "s|^(constexpr int MODE_DIAG = )[0-9]+;|\1${1};|" "$SKETCH"; }
set_baud1() { sed -i '' -E "s|^(constexpr uint32_t FPGA_BAUD   = )[0-9]+;|\1${1};|" "$SKETCH"; }
set_baud2() { sed -i '' -E "s|^(constexpr uint32_t HOST_BAUD   = )[0-9]+;|\1${1};|" "$SKETCH"; }
set_cpb()   { sed -i '' -E "s|^( *parameter integer CLK_PER_BIT *= *)[0-9]+,|\1${1},|" fpga/src/top.v; }

build_fpga() {
    ( cd fpga && DYLD_LIBRARY_PATH="$IDE/lib" DYLD_FRAMEWORK_PATH="$IDE/lib" \
        "$IDE/bin/gw_sh" build.tcl >/tmp/gw_build.log 2>&1 )
    grep -q 'Bitstream generation completed' /tmp/gw_build.log || return 1
    "$PRG" -d GW1NSR-4C -r 2 --fsFile "$ROOT/fpga/impl/pnr/i2s_capture.fs" >/tmp/gw_prog.log 2>&1
    grep -q 'Finished' /tmp/gw_prog.log
}
flash_esp() { arduino-cli compile --upload -b esp32:esp32:esp32s3 -p "$PORT" "$DIR" >/tmp/ard.log 2>&1; }

PHASE=$1; shift
sed -i '' -E "s|^( *parameter integer BCLK_DIV *= *)[0-9]+,|\156,|" fpga/src/top.v
set_mode 1
echo "gateway in MODE_DIAG, BCLK_DIV=56 (~30 kB/s, a light load on purpose)"
echo

if [ "$PHASE" = "D1" ]; then
    # Link 1's speed limit, measured as an ERROR RATE rather than a yes/no.
    #
    # Counting sync words in MODE_DIAG proved too coarse: 8 Mbaud failed once and
    # then passed twice, so the boundary is marginal rather than sharp. A marginal
    # link is worse than a failed one -- it works in a demo and corrupts data in a
    # measurement -- so it has to be characterised, not just classified.
    #
    # Instead: run MODE_PUMP at the HIGHEST data rate (BCLK_DIV=8, 95 kB/s) with
    # link 2 held at a known-good 2 Mbaud, and count checksum and header errors at
    # the host. Link 2 is only 48 % loaded and is proven clean, so every error is
    # attributable to link 1. This sees rare bit errors that sync-counting cannot.
    set_mode 0
    set_baud2 2000000
    # Highest sample rate available: BCLK = SYS_CLK / BCLK_DIV must stay <= 3.2 MHz,
    # so 18 at 54 MHz (was 8 at 24 MHz). Same 95 kB/s of offered data either way.
    sed -i '' -E "s|^( *parameter integer BCLK_DIV *= *)[0-9]+,|\118,|" fpga/src/top.v
    SECS=${SECS:-45}
    for CPB in "$@"; do
        B1=$(( 54000000 / CPB ))
        CSV="data/m3d-D1-baud${B1}.csv"
        echo "--- link 1 = ${B1} baud (CLK_PER_BIT=${CPB}), ${SECS}s at 95 kB/s ---"
        set_cpb "$CPB"; set_baud1 "$B1"
        build_fpga || { echo "  FPGA BUILD/PROGRAM FAILED"; continue; }
        flash_esp  || { echo "  ESP32 FLASH FAILED"; continue; }
        sleep 2
        rm -f "$CSV"
        "$PY" host/inmp441_viewer.py --no-plot --seconds "$SECS" --baud 2000000 \
              --csv "$CSV" >/tmp/run.log 2>&1
        if [ ! -s "$CSV" ]; then
            echo "  NO FRAMES AT ALL -> link 1 unusable at ${B1} baud"; continue
        fi
        "$PY" - "$CSV" "$B1" <<'PYE'
import csv, sys
rows = list(csv.DictReader(open(sys.argv[1])))[1:]
S = lambda k: sum(int(r[k]) for r in rows)
ok, cks, hdr, lost = S("frames_ok"), S("checksum_errors"), S("header_errors"), S("frames_lost")
# every frame whose sync word was found counts as "seen", including ones rejected
# for a bad header -- leaving those out of the denominator produced a 111% rate
seen = ok + cks + hdr
bad = cks + hdr
rate = 100 * bad / seen if seen else 100.0
mark = "CLEAN" if bad == 0 else ("MARGINAL" if rate < 1 else "FAILING")
print(f"  {ok} intact, {cks} bad payload, {hdr} bad header, {lost} lost"
      f"  ->  {rate:.3f}% corrupt   {mark}")
PYE
    done
elif [ "$PHASE" = "D2" ]; then
    # Link 2's speed limit, measured the same way D1 ended up being measured: as an
    # error rate at full data rate, not a yes/no from sync counting.
    #
    # Link 1 is pinned at 6 Mbaud -- proven clean over 4048 frames -- and carries
    # only 95 kB/s of 600 kB/s (16 %), so it cannot be the source of any error.
    # Every checksum or header error is therefore attributable to link 2.
    set_mode 0
    set_cpb 9; set_baud1 6000000            # link 1 held at its proven-clean rate
    sed -i '' -E "s|^( *parameter integer BCLK_DIV *= *)[0-9]+,|\118,|" fpga/src/top.v
    SECS=${SECS:-45}
    build_fpga || { echo "FPGA BUILD/PROGRAM FAILED"; exit 1; }
    echo "link 1 pinned at 6,000,000 baud (proven clean); BCLK_DIV=8 -> 95 kB/s offered"
    echo
    for B2 in "$@"; do
        CSV="data/m3d-D2-baud${B2}.csv"
        echo "--- link 2 = ${B2} baud (capacity $(( B2 / 10 )) B/s), ${SECS}s ---"
        set_baud2 "$B2"
        flash_esp || { echo "  ESP32 FLASH FAILED"; continue; }
        sleep 2
        rm -f "$CSV"
        "$PY" host/inmp441_viewer.py --no-plot --seconds "$SECS" --baud "$B2" \
              --csv "$CSV" >/tmp/run.log 2>&1
        if [ ! -s "$CSV" ]; then
            # Distinguish "the bridge refused this rate" from "the bits are mangled":
            # a raw probe reports the byte rate even when nothing decodes.
            RAW=$("$PY" tools/probe_port.py --seconds 4 --baud "$B2" 2>/dev/null \
                  | grep -E 'bytes received' | sed -E 's/.*-> *//')
            echo "  NO FRAMES  (raw byte rate at ${B2}: ${RAW:-none})  ->  link 2 FAILS"
            continue
        fi
        "$PY" - "$CSV" "$B2" <<'PYE'
import csv, sys
rows = list(csv.DictReader(open(sys.argv[1])))[1:]
cap = int(sys.argv[2]) / 10
S = lambda k: sum(int(r[k]) for r in rows)
ok, cks, hdr, lost = S("frames_ok"), S("checksum_errors"), S("header_errors"), S("frames_lost")
seen = ok + cks; bad = cks + hdr
rate = 100 * bad / seen if seen else 100.0
load = 100 * 95032 / cap
mark = "CLEAN" if bad == 0 and lost == 0 else ("MARGINAL" if rate < 1 else "FAILING")
print(f"  {ok} intact, {cks} bad payload, {hdr} bad header, {lost} lost"
      f"  ({load:.0f}% loaded)  ->  {rate:.3f}% corrupt   {mark}")
PYE
    done
else
    echo "usage: $0 D1 <clk_per_bit>... | D2 <host_baud>..."; exit 2
fi

echo
echo "restoring MODE_PUMP"
set_mode 0
