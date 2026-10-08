#!/bin/bash
# run.sh — can each chip build a true dual-port RAM? (F1 evidence, docs/11 §9.2b)
#   tdp.v  true dual-port: both ports read AND write   (what the Gowin FFT core needs)
#   sdp.v  semi-dual-port: one port writes, one reads  (what the 4K offers)
# Builds each through place & route and reports BUILT / FAILED.
IDE=/Applications/GowinIDE.app/Contents/Resources/Gowin_EDA/IDE
HERE=$(cd "$(dirname "$0")" && pwd); W=${WORK:-/tmp/dpb_test}
run() {
  d=$W/$1; rm -rf $d; mkdir -p $d; cp $HERE/$2 $HERE/top.v $d/
  printf "set_device -name %s %s\nadd_file %s\nadd_file top.v\nset_option -top_module top\nset_option -output_base_name t\nrun all\n" $3 $4 $2 > $d/b.tcl
  (cd $d && DYLD_LIBRARY_PATH="$IDE/lib" DYLD_FRAMEWORK_PATH="$IDE/lib" "$IDE/bin/gw_sh" b.tcl > log 2>&1)
  if [ -f $d/impl/pnr/t.rpt.txt ]; then printf "%-8s %-10s BUILT\n" $1 $3
  else printf "%-8s %-10s FAILED  %s\n" $1 $3 "$(grep -m1 ERROR $d/log | sed 's/"[^"]*"//' | cut -c1-110)"; fi
}
run tdp_4K  tdp.v GW1NSR-4C GW1NSR-LV4CQN48PC6/I5
run sdp_4K  sdp.v GW1NSR-4C GW1NSR-LV4CQN48PC6/I5
run tdp_9K  tdp.v GW1NR-9C  GW1NR-LV9QN88PC6/I5
run tdp_20K tdp.v GW2AR-18C GW2AR-LV18QN88C8/I7
