"""check_h3.py — check tb_h3_mic.v: every gain picks the right 16 bits, saturating at the limits.

    python check_h3.py <file written by tb_h3_mic>
"""
import sys

ok = True
rows = [list(map(int, l.split())) for l in open(sys.argv[1]) if l.strip()]
rows = rows[2:]                                  # the first frames hold the start-up zeros
bad = 0
for r in rows:
    w = r[0] - (1 << 24) if r[0] >= (1 << 23) else r[0]
    for g in range(8):
        v = w >> (8 - g)                         # pick bits 23-g .. 8-g (arithmetic shift)
        exp = max(-32768, min(32767, v))
        if r[1 + g] != exp:
            bad += 1
            if bad <= 5:
                print(f"  word {r[0]:06x} gain {g}: got {r[1 + g]}, want {exp}")
words = {r[0] for r in rows}
print(f"  {'PASS' if bad == 0 else 'FAIL'}  all 8 gains x {len(rows)} frames ({len(words)} different words) "
      f"bit-exact incl. saturation   {bad} wrong")
sys.exit(0 if bad == 0 else 1)
