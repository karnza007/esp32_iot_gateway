#!/usr/bin/env bash
# sweep_gen.sh — drive link 1 to saturation with the synthetic generator.
#
#   tools/sweep_gen.sh <clk_per_bit> <gen_div> [gen_div ...]
#   tools/sweep_gen.sh 27 2176 1088 704 640 576 512 448 320
#
# Every link-1 measurement so far ran at ~7 % load. This fills it. GEN_DIV sets the
# offered rate: fs = 54 MHz / GEN_DIV, wire = fs / 512 * 1038 bytes per second.
# GEN_DIV must be a multiple of 64 so the rate reaches the host through the frame
# header's existing rate field as GEN_DIV/64.
set -u
cd "$(dirname "$0")/.."
ROOT=$PWD
IDE=/Applications/GowinIDE.app/Contents/Resources/Gowin_EDA/IDE
PRG=/Applications/GowinIDE.app/Contents/Resources/Gowin_EDA/Programmer/bin/programmer_cli
PY=$ROOT/.venv/bin/python
SECS=${SECS:-45}
CPB=$1; shift
CAP=$(( 54000000 / CPB / 10 ))

echo "link 1 at $(( 54000000 / CPB )) baud = ${CAP} B/s;  link 2 = native USB"
echo "synthetic payload, ${SECS}s per point"
echo
sed -i '' -E "s|^( *parameter integer GEN_MODE *= *)[0-9]+,|\11,|; s|^( *parameter integer CLK_PER_BIT *= *)[0-9]+,.*|\1${CPB},|" fpga/src/top.v
sed -i '' -E "s|^(constexpr uint32_t FPGA_BAUD   = )[0-9]+;.*|\1$(( 54000000 / CPB ));|" firmware/fpga_uart_bridge/fpga_uart_bridge.ino
arduino-cli compile --upload -b esp32:esp32:esp32s3:CDCOnBoot=cdc \
    -p "$(ls /dev/cu.wchusbserial* | head -1)" firmware/fpga_uart_bridge >/tmp/a.log 2>&1 \
    || { echo "ESP32 FLASH FAILED"; tail -3 /tmp/a.log; exit 1; }

for GD in "$@"; do
    WIRE=$(awk "BEGIN{printf \"%.0f\", 54000000/$GD/512*1038}")
    PCT=$(awk "BEGIN{printf \"%.0f\", 100*54000000/$GD/512*1038/$CAP}")
    CSV="data/m3g-link1-gen${GD}.csv"
    echo "--- GEN_DIV=${GD}: offered ${WIRE} B/s = ${PCT}% of link 1 ---"
    sed -i '' -E "s|^( *parameter integer GEN_DIV *= *)[0-9]+.*|\1${GD}  // synthetic rate|" fpga/src/top.v
    ( cd fpga && DYLD_LIBRARY_PATH="$IDE/lib" DYLD_FRAMEWORK_PATH="$IDE/lib" \
        "$IDE/bin/gw_sh" build.tcl >/tmp/b.log 2>&1 )
    grep -q 'Bitstream generation completed' /tmp/b.log || { echo "  BUILD FAILED"; continue; }
    "$PRG" -d GW1NSR-4C -r 2 --fsFile "$ROOT/fpga/impl/pnr/i2s_capture.fs" >/tmp/p.log 2>&1
    grep -q Finished /tmp/p.log || { echo "  PROGRAM FAILED"; continue; }
    sleep 2
    rm -f "$CSV"
    "$PY" host/inmp441_viewer.py --no-plot --seconds "$SECS" --csv "$CSV" >/tmp/run.log 2>&1
    [ -s "$CSV" ] || { echo "  NO FRAMES"; tail -4 /tmp/run.log; continue; }
    "$PY" - "$CSV" "$WIRE" "$CAP" <<'PYE'
import csv, sys
rows = list(csv.DictReader(open(sys.argv[1])))[1:]
offered, cap = float(sys.argv[2]), float(sys.argv[3])
S = lambda k: sum(int(r[k]) for r in rows)
d = float(rows[-1]["t"]) - float(rows[0]["t"]) + 1
ok, cks, hdr, lost = S("frames_ok"), S("checksum_errors"), S("header_errors"), S("frames_lost")
smp, brk, ovf = S("samples_lost"), S("sample_breaks"), S("ovf_delta")
wire = sum(float(r["wire_Bps"]) for r in rows) / len(rows)
seen = ok + cks + hdr
verdict = max({r["verdict"] for r in rows}, key=lambda s: (s != "OK",))
print(f"  {ok} intact  {lost} frames lost  {cks} bad payload  {hdr} bad header")
print(f"  ovf {ovf:,} B   samples lost {smp:,} in {brk} break(s)   "
      f"delivered {wire:,.0f} B/s of {offered:,.0f} offered ({100*offered/cap:.0f}% of link 1)")
print(f"  -> {verdict}")
PYE
    echo
done
