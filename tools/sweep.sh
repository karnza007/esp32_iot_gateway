#!/usr/bin/env bash
# sweep.sh — build, program and capture one sweep point per BCLK_DIV value.
#
#   tools/sweep.sh <phase> <link2_baud> <seconds> <div> [div ...]
#   tools/sweep.sh B 921600 60 25 20 16 12 10
#
# For each divider it edits fpga/src/top.v, runs Gowin synthesis + place & route
# from the command line, programs the bitstream to SRAM (fast and volatile --
# ideal for a sweep; flash the final configuration when finished), captures a run,
# and then VERIFIES that the bclk_div recorded in the CSV matches what was asked
# for. A stale bitstream once cost this project a full session, and a mismatched
# one silently mislabelled a data point; this check makes both impossible.
set -u
cd "$(dirname "$0")/.."
ROOT=$PWD
IDE=/Applications/GowinIDE.app/Contents/Resources/Gowin_EDA/IDE
PRG=/Applications/GowinIDE.app/Contents/Resources/Gowin_EDA/Programmer/bin/programmer_cli
PY=$ROOT/.venv/bin/python

PHASE=$1; BAUD=$2; SECS=$3; shift 3
fail=0

for DIV in "$@"; do
    CSV="data/m3-${PHASE}-div${DIV}.csv"
    echo "=============================================================="
    echo "  phase $PHASE   BCLK_DIV=$DIV   link2=$BAUD baud   ${SECS}s"
    echo "=============================================================="

    sed -i '' -E "s|^( *parameter integer BCLK_DIV *= *)[0-9]+,|\1${DIV},|" fpga/src/top.v
    grep -qE "parameter integer BCLK_DIV *= *${DIV}," fpga/src/top.v || { echo "  EDIT FAILED"; fail=1; continue; }

    echo "  synthesising..."
    ( cd fpga && DYLD_LIBRARY_PATH="$IDE/lib" DYLD_FRAMEWORK_PATH="$IDE/lib" \
        "$IDE/bin/gw_sh" build.tcl >/tmp/gw_build.log 2>&1 )
    if ! grep -q 'Bitstream generation completed' /tmp/gw_build.log; then
        echo "  BUILD FAILED — see /tmp/gw_build.log"; tail -5 /tmp/gw_build.log; fail=1; continue
    fi

    echo "  programming..."
    "$PRG" -d GW1NSR-4C -r 2 --fsFile "$ROOT/fpga/impl/pnr/i2s_capture.fs" >/tmp/gw_prog.log 2>&1
    grep -q 'Finished' /tmp/gw_prog.log || { echo "  PROGRAM FAILED"; tail -3 /tmp/gw_prog.log; fail=1; continue; }

    rm -f "$CSV"
    echo "  capturing ${SECS}s..."
    "$PY" host/inmp441_viewer.py --no-plot --seconds "$SECS" --baud "$BAUD" --csv "$CSV" >/tmp/gw_run.log 2>&1
    if [ ! -s "$CSV" ]; then
        echo "  CAPTURE FAILED — no data"; tail -6 /tmp/gw_run.log; fail=1; continue
    fi

    # the data must agree with what we asked for
    GOT=$(awk -F, 'NR==2{print $3}' "$CSV")
    if [ "$GOT" != "$DIV" ]; then
        echo "  MISMATCH: asked for BCLK_DIV=$DIV, the FPGA reported $GOT"; fail=1; continue
    fi
    "$PY" tools/summarize_run.py "$CSV" | sed 's/^/  /'
done

echo
[ "$fail" -eq 0 ] && echo "SWEEP COMPLETE" || echo "SWEEP FINISHED WITH FAILURES"
exit $fail
