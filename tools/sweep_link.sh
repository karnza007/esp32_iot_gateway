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
EXPECT_SYNC=29.3          # BCLK_DIV=25 -> 15000/512 frames per second

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
sed -i '' -E "s|^( *parameter integer BCLK_DIV *= *)[0-9]+,|\125,|" fpga/src/top.v
set_mode 1
echo "gateway in MODE_DIAG, BCLK_DIV=25 (~30 kB/s, a light load on purpose)"
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
    sed -i '' -E "s|^( *parameter integer BCLK_DIV *= *)[0-9]+,|\18,|" fpga/src/top.v
    SECS=${SECS:-45}
    for CPB in "$@"; do
        B1=$(( 24000000 / CPB ))
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
seen = ok + cks
bad = cks + hdr
rate = 100 * bad / seen if seen else 100.0
mark = "CLEAN" if bad == 0 else ("MARGINAL" if rate < 1 else "FAILING")
print(f"  {ok} intact, {cks} bad payload, {hdr} bad header, {lost} lost"
      f"  ->  {rate:.3f}% corrupt   {mark}")
PYE
    done
elif [ "$PHASE" = "D2" ]; then
    printf "%-12s %s\n" "HOST_BAUD" "result"
    for B2 in "$@"; do
        set_baud2 "$B2"
        flash_esp || { printf "%-12s ESP32 FLASH FAILED\n" "$B2"; continue; }
        sleep 2
        printf "%-12s " "$B2"
        "$PY" tools/read_diag.py --baud "$B2" --seconds 8 --expect-sync "$EXPECT_SYNC"
    done
else
    echo "usage: $0 D1 <clk_per_bit>... | D2 <host_baud>..."; exit 2
fi

echo
echo "restoring MODE_PUMP"
set_mode 0
