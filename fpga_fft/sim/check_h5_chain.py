"""check_h5_chain.py — check tb_h5_chain.v's spectrogram memory: a sweep must draw a line.

    python check_h5_chain.py <columns.txt> <out.png>

During block c the tone sweeps bins 10 + 6c .. 16 + 6c, i.e. rows 5 + 3c .. 8 + 3c. Checks:
  - in every column the brightest row lies in that range (one row of slack each side);
  - a straight-line fit through those rows rises 3 rows per column;
  - the quiet 1 kHz tone (row 23) shows (colour >= 3) wherever the sweep is far from it;
  - rows far from both tones are dark (colour <= 2) in at least 95 % of places.
Also writes the 40 columns as a picture (4 x 2 px per point, as on the screen).
"""
import os
import sys

import numpy as np
from PIL import Image

sys.path.insert(0, os.path.join(os.path.dirname(__file__), ".."))
import gen_h4_text as g  # noqa: E402

cols = np.array([[int(v) for v in l.split()] for l in open(sys.argv[1]) if l.strip()])   # [column, row]
n = len(cols)
ok = cols.shape == (40, 256)

top = cols.argmax(axis=1)
lo, hi = 5 + 3 * np.arange(n) - 1, 8 + 3 * np.arange(n) + 1
in_range = (top >= lo) & (top <= hi)
slope, icpt = np.polyfit(np.arange(n), top, 1)
print(f"  brightest row in the sweep's range: {int(in_range.sum())} of {n} columns; "
      f"line fit: {slope:.2f} rows per column (want 3), start row {icpt:.1f} (want ~6.5)")
print(f"  brightest colour per column: min {cols.max(axis=1).min()}, max {cols.max(axis=1).max()}")
ok &= bool(in_range.all()) and abs(slope - 3) < 0.1

far = [c for c in range(n) if abs(top[c] - 23) > 10]
k1 = cols[far, 23]
print(f"  1 kHz tone (row 23), where the sweep is > 10 rows away: colours {sorted(set(k1.tolist()))}")
ok &= bool((k1 >= 3).all())

mask = np.ones_like(cols, dtype=bool)
for c in range(n):
    mask[c, max(0, top[c] - 15):top[c] + 16] = False
mask[:, 18:29] = False
dark = float((cols[mask] <= 2).mean())
print(f"  away from both tones: {100 * dark:.1f} % dark (colour <= 2)")
ok &= dark >= 0.95

pic = np.array(g.SPEC_RGB, dtype=np.uint32)[cols.T[::-1]]          # rows top-down, columns left-right
pic = np.repeat(np.repeat(pic, 2, axis=0), 4, axis=1)
img = np.stack([(pic >> 16) & 255, (pic >> 8) & 255, pic & 255], axis=-1).astype(np.uint8)
Image.fromarray(img).save(sys.argv[2])
print("  PASS" if ok else "  FAIL")
sys.exit(0 if ok else 1)
