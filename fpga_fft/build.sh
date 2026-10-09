#!/bin/bash
# build.sh — build the Tang Nano 20K design and print what it used.
#   ./build.sh            synthesise + place & route  -> impl/pnr/fpga_fft.fs
#   ./build.sh program    ...then load it into the FPGA (SRAM: fast, lost at power-off)
#   MHZ=54 ./build.sh ... the 54 MHz build (src/top_54.v: PLL doubles the crystal)
#   MHZ=81 ./build.sh ... the 81 MHz build (src/top_81.v: PLL triples it)
#   DESIGN=hdmi ./build.sh  the HDMI demo build (src/top_hdmi.v, docs/plans/hdmi-demo.md)
# Same result as Synthesize + Place & Route in the IDE; reports land in impl/.
set -e
# PR1014 is filtered: the 20K's crystal lands on pin 4, a PLL input rather than a
# dedicated clock pin, so Gowin warns about routing the clock; timing still passes.
IDE=/Applications/GowinIDE.app/Contents/Resources/Gowin_EDA/IDE
PRG=/Applications/GowinIDE.app/Contents/Resources/Gowin_EDA/Programmer/bin/programmer_cli
cd "$(dirname "$0")"
CST=src/top.cst
if [ "$DESIGN" = hdmi ]; then MHZ=hdmi; CST=src/top_hdmi.cst; fi
case "${MHZ:-27}" in
  hdmi) TOP=top_hdmi ;;
  27) TOP=top ;;
  54) TOP=top_54 ;;
  81) TOP=top_81 ;;
  *)  echo "MHZ must be 27, 54 or 81 (or DESIGN=hdmi)"; exit 1 ;;
esac
echo "building $TOP (${MHZ:-27})"
# gw_sh takes no arguments, so the choice is passed through a two-line wrapper script
printf 'set TOP %s\nset SDC src/top.sdc\nset CST %s\nsource build.tcl\n' "$TOP" "$CST" > impl_build.tcl
DYLD_LIBRARY_PATH="$IDE/lib" DYLD_FRAMEWORK_PATH="$IDE/lib" "$IDE/bin/gw_sh" impl_build.tcl > impl_build.log 2>&1 \
  || { grep -E "ERROR" impl_build.log | head; exit 1; }
R=impl/pnr/fpga_fft.rpt.txt
grep -E "^\s+(Logic|Register|BSRAM|DSP|--SDPB|--DPB|--pROM)\s+\|" $R
python3 - <<'PY'
import re, html
t = open("impl/pnr/fpga_fft_tr_content.html").read()
t = re.sub(r"\s+", " ", html.unescape(re.sub(r"<[^>]+>", " ", t)))
s = t[t.find("Max Frequency Summary"):t.find("Total Negative Slack")]
for name, want, got in re.findall(r"\d+ (\S+) ([0-9.]+)\(MHz\) ([0-9.]+)\(MHz\)", s):
    print(f"  timing: clock {name}: needs {want} MHz, achieves {got} MHz")
n = t[t.find("Total Negative Slack Summary"):][:400]
print("  timing violations:", "none" if not re.search(r"(Setup|Hold) -[0-9]", n) else "YES - see the report")
PY
grep -E "^(WARN|ERROR)" impl_build.log | grep -v PR1014 | sort | uniq -c | head -20 || true
if [ "$1" = program ]; then
  (cd "$(dirname "$PRG")" && ./programmer_cli -d GW2AR-18C -r 2 --fsFile "$OLDPWD/impl/pnr/fpga_fft.fs") | tail -4
fi
