#!/usr/bin/env bash
# run_sims.sh — simulate everything before touching hardware.
#
#   ./fpga/sim/run_sims.sh
#
# Runs:
#   tb_framer  frame layout, seq, cfg, checksum, and the overflow counter
#              (including a positive control: a stalled drain MUST report drops)
#   tb_chain   full datapath with an I2S microphone model, swept over every
#              BCLK_DIV in the planned load sweep
#
# Requires Icarus Verilog:  brew install icarus-verilog

set -u
cd "$(dirname "$0")/../.."          # repo root
SRC=fpga/src
SIM=fpga/sim
OUT="${TMPDIR:-/tmp}"
fail=0

echo "=== tb_framer ==="
iverilog -g2012 -o "$OUT/tb_framer" "$SIM/tb_framer.v" "$SRC/framer.v" || fail=1
vvp "$OUT/tb_framer" | grep -v '^VCD info' || fail=1
vvp "$OUT/tb_framer" | grep -q 'tb_framer: PASS' || fail=1

echo
echo "=== tb_chain (swept over the whole load-sweep range) ==="
for N in 25 20 16 12 10 8; do
    iverilog -g2012 -Ptb_chain.BCLK_DIV=$N -o "$OUT/tb_chain_$N" \
        "$SIM/tb_chain.v" "$SRC/i2s_master_rx.v" "$SRC/framer.v" "$SRC/uart_tx.v" || fail=1
    result=$(vvp "$OUT/tb_chain_$N" | grep -E 'PASS|FAIL' | tail -1)
    fs=$(awk "BEGIN{printf \"%.4f\", 24000000/(64*$N)/1000}")
    printf "  BCLK_DIV=%-3s fs=%9s kHz  %s\n" "$N" "$fs" "$result"
    case "$result" in *PASS*) ;; *) fail=1 ;; esac
done

echo
if [ "$fail" -eq 0 ]; then echo "ALL SIMULATIONS PASS"; else echo "SIMULATION FAILURES"; fi
exit $fail
