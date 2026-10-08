#!/bin/bash
# try_variant.sh — F1: rebuild the Gowin FFT core with different settings, no GUI.
#
#   usage:  [EXTRA='`define X'] ./try_variant.sh NAME DATAMEM POINTS LOG2 [TDFMEM]
#   e.g.    ./try_variant.sh reg16 REG_MEMORY 16 4
#
# WHY THIS WORKS
#   The IP Core Generator is a thin GUI over one synthesis run: it writes the chosen
#   options as `define lines (temp/FFT/defile.v), writes the twiddle tables
#   (twRe.v / twIm.v), and synthesises Gowin's encrypted fft.v with them. This
#   script edits those inputs and repeats the run, then places and routes the core
#   inside sizing_top.v -- which is where a memory the chip lacks is finally caught.
#   DATAMEM is one of EBR_MEMORY AUTOMATIC_MEMORY DISTRIBUTED_MEMORY REG_MEMORY
#   (the macro names the generator itself emits; found in libFFT.dylib).
IDE=/Applications/GowinIDE.app/Contents/Resources/Gowin_EDA/IDE
S=${WORK:-/tmp/fft_variants}   # scratch area for the variants
SRC=$HOME/Capstone-Project/fpga_fft/src/fft/temp/FFT
SZ=$HOME/Capstone-Project/fpga_fft/sizing
env_() { DYLD_LIBRARY_PATH="$IDE/lib" DYLD_FRAMEWORK_PATH="$IDE/lib" "$@"; }
d=$S/$1; rm -rf $d; mkdir -p $d; cp $SRC/defile.v $d/; $HOME/Capstone-Project/.venv/bin/python $SZ/gen_twiddles.py $3 $d
sed -i '' "s/\`define EBR_MEMORY/\`define $2/; s/FFT1024/FFT$3/; s/\`define POINTS 1024/\`define POINTS $3/; s/\`define POINTS_LOG 10/\`define POINTS_LOG $4/" $d/defile.v
[ -n "$5" ] && sed -i '' "s/\`define TDF_EBR_MEMORY/\`define $5/" $d/defile.v
[ -n "$EXTRA" ] && printf "%b\n" "$EXTRA" >> $d/defile.v
sed "s|$SRC|$d|; s|fft_1024.vg|$d/core.vg|; s|fft_1024_tmp.v|$d/core_tmp.v|" $SRC/FFT.prj > $d/FFT.prj
(cd $d && env_ "$IDE/bin/GowinSynthesis" -prj FFT.prj > syn.log 2>&1) || { echo "$1: CORE SYNTHESIS FAILED: $(grep -m1 ERROR $d/syn.log)"; exit; }
cp $SZ/sizing_top.v $SZ/sizing.cst $SZ/sizing.sdc $d/
cat > $d/b.tcl <<T
set_device -name GW1NSR-4C GW1NSR-LV4CQN48PC6/I5
add_file core.vg
add_file sizing_top.v
add_file sizing.cst
add_file sizing.sdc
set_option -top_module sizing_top
set_option -output_base_name sz
run all
T
(cd $d && env_ "$IDE/bin/gw_sh" b.tcl > pnr.log 2>&1)
R=$d/impl/pnr/sz.rpt.txt
if [ ! -f $R ]; then echo "$1: PLACE&ROUTE FAILED: $(grep -m1 ERROR $d/pnr.log | cut -c1-160)"; exit; fi
echo "$1:"; grep -E "^\s+(Logic|Register|BSRAM|DSP|CLS)\s+\|" $R | sed 's/^/   /'
grep -A3 "Max Frequency Summary" $d/impl/pnr/sz.tr.html 2>/dev/null | head -1 >/dev/null
f=$(grep -oE "[0-9.]+\(MHz\)" $d/impl/pnr/sz.tr.html | head -2 | tr '\n' ' '); echo "   timing (constraint, actual): $f"
