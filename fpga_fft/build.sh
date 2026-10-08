#!/bin/bash
# build.sh — build the Tang Nano 20K design and print what it used.
#   ./build.sh            synthesise + place & route  -> impl/pnr/fpga_fft.fs
#   ./build.sh program    ...then load it into the FPGA (SRAM: fast, lost at power-off)
# Same result as Synthesize + Place & Route in the IDE; reports land in impl/.
set -e
# PR1014 is filtered: the 20K's crystal lands on pin 4, a PLL input rather than a
# dedicated clock pin, so Gowin warns about routing the clock; timing still passes.
IDE=/Applications/GowinIDE.app/Contents/Resources/Gowin_EDA/IDE
PRG=/Applications/GowinIDE.app/Contents/Resources/Gowin_EDA/Programmer/bin/programmer_cli
cd "$(dirname "$0")"
DYLD_LIBRARY_PATH="$IDE/lib" DYLD_FRAMEWORK_PATH="$IDE/lib" "$IDE/bin/gw_sh" build.tcl > impl_build.log 2>&1 \
  || { grep -E "ERROR" impl_build.log | head; exit 1; }
R=impl/pnr/fpga_fft.rpt.txt
grep -E "^\s+(Logic|Register|BSRAM|DSP|--SDPB|--DPB|--pROM)\s+\|" $R
echo "  timing (constraint, achieved): $(grep -oE "[0-9.]+\(MHz\)" impl/pnr/fpga_fft_tr_content.html | head -2 | tr '\n' ' ')"
grep -E "^(WARN|ERROR)" impl_build.log | grep -v PR1014 | sort | uniq -c | head -20 || true
if [ "$1" = program ]; then
  (cd "$(dirname "$PRG")" && ./programmer_cli -d GW2AR-18C -r 2 --fsFile "$OLDPWD/impl/pnr/fpga_fft.fs") | tail -4
fi
