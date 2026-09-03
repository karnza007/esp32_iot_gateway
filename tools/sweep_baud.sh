#!/usr/bin/env bash
# sweep_baud.sh — M3 phase C: hold the data rate fixed and lower link 2's capacity.
#
#   tools/sweep_baud.sh <phase> <bclk_div> <seconds> <baud> [baud ...]
#   tools/sweep_baud.sh C 8 45 2000000 1500000 1200000 1000000 950000 900000
#
# Phase A and B raise demand against fixed capacity. This lowers capacity against
# fixed demand, approaching the same knee from the opposite direction. If both
# locate it in the same place, the result is far stronger than either alone.
#
# The FPGA is built and programmed once (BCLK_DIV never changes here); each point
# only re-flashes the ESP32 with a new HOST_BAUD.
set -u
cd "$(dirname "$0")/.."
ROOT=$PWD
IDE=/Applications/GowinIDE.app/Contents/Resources/Gowin_EDA/IDE
PRG=/Applications/GowinIDE.app/Contents/Resources/Gowin_EDA/Programmer/bin/programmer_cli
PY=$ROOT/.venv/bin/python
SKETCH=firmware/fpga_uart_bridge
FQBN=esp32:esp32:esp32s3:CDCOnBoot=cdc
PORT=$(ls /dev/cu.wchusbserial* 2>/dev/null | head -1)

PHASE=$1; DIV=$2; SECS=$3; shift 3
[ -n "$PORT" ] || { echo "no ESP32 port found"; exit 1; }
fail=0

echo "### FPGA: BCLK_DIV=$DIV, built and programmed once for the whole phase"
sed -i '' -E "s|^( *parameter integer BCLK_DIV *= *)[0-9]+,|\1${DIV},|" fpga/src/top.v
( cd fpga && DYLD_LIBRARY_PATH="$IDE/lib" DYLD_FRAMEWORK_PATH="$IDE/lib" \
    "$IDE/bin/gw_sh" build.tcl >/tmp/gw_build.log 2>&1 )
grep -q 'Bitstream generation completed' /tmp/gw_build.log || { echo "BUILD FAILED"; tail -5 /tmp/gw_build.log; exit 1; }
"$PRG" -d GW1NSR-4C -r 2 --fsFile "$ROOT/fpga/impl/pnr/i2s_capture.fs" >/tmp/gw_prog.log 2>&1
grep -q 'Finished' /tmp/gw_prog.log || { echo "PROGRAM FAILED"; exit 1; }
echo "### done"; echo

for BAUD in "$@"; do
    CSV="data/m3-${PHASE}-baud${BAUD}.csv"
    echo "=============================================================="
    echo "  phase $PHASE   BCLK_DIV=$DIV   link2=$BAUD baud   ${SECS}s"
    echo "=============================================================="

    sed -i '' -E "s|^(constexpr uint32_t HOST_BAUD   = )[0-9]+;|\1${BAUD};|" "$SKETCH/fpga_uart_bridge.ino"
    grep -qE "HOST_BAUD   = ${BAUD};" "$SKETCH/fpga_uart_bridge.ino" || { echo "  EDIT FAILED"; fail=1; continue; }

    echo "  uploading sketch..."
    arduino-cli compile --upload -b "$FQBN" -p "$PORT" "$SKETCH" >/tmp/ard.log 2>&1 \
        || { echo "  UPLOAD FAILED"; tail -4 /tmp/ard.log; fail=1; continue; }
    sleep 2

    rm -f "$CSV"
    echo "  capturing ${SECS}s..."
    "$PY" host/inmp441_viewer.py --no-plot --seconds "$SECS" --baud "$BAUD" --csv "$CSV" >/tmp/gw_run.log 2>&1
    if [ ! -s "$CSV" ]; then
        echo "  CAPTURE FAILED — no frames. This baud may not be usable on this link."
        tail -5 /tmp/gw_run.log; fail=1; continue
    fi
    GOT=$(awk -F, 'NR==2{print $3}' "$CSV")
    [ "$GOT" = "$DIV" ] || { echo "  MISMATCH: FPGA reports BCLK_DIV=$GOT, expected $DIV"; fail=1; continue; }
    "$PY" tools/summarize_run.py "$CSV" | sed 's/^/  /'
done

echo
[ "$fail" -eq 0 ] && echo "SWEEP COMPLETE" || echo "SWEEP FINISHED WITH FAILURES"
exit $fail
