"""check_h5_chain.py — check tb_h5_chain.v's spectrogram memory: a sweep must draw a line.

    python check_h5_chain.py <columns.txt> <out.png>

With 50 % overlap, FFT c covers samples 512c .. 512c + 1023, during which the tone sweeps bins
10 + 3c .. 16 + 3c, i.e. rows 5 + 1.5c .. 8 + 1.5c. Checks:
  - in every column the brightest row lies in that range (one row of slack each side);
  - a straight-line fit through those rows rises 1.5 rows per column;
  - the quiet 1 kHz tone (row 23) shows (level >= 16, -65 dB or louder) wherever the sweep is
    far from it;
  - rows far from both tones are dark (level <= 15, below -65 dB) in at least 95 % of places.
(Levels: 0 = below -80 dB, 1..30 = -80..-51 dB, 31 = -50 dB and louder; spectrogram_display.v.
Until 2026-11-06 colour numbers 0..15 of 5 dB; the -65 dB limits are the same as then.)
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
lo, hi = 5 + 1.5 * np.arange(n) - 1, 8 + 1.5 * np.arange(n) + 1
in_range = (top >= lo) & (top <= hi)
slope, icpt = np.polyfit(np.arange(n), top, 1)
print(f"  brightest row in the sweep's range: {int(in_range.sum())} of {n} columns; "
      f"line fit: {slope:.2f} rows per column (want 1.5), start row {icpt:.1f} (want ~6.5)")
print(f"  brightest level per column: min {cols.max(axis=1).min()}, max {cols.max(axis=1).max()}")
ok &= bool(in_range.all()) and abs(slope - 1.5) < 0.05

far = [c for c in range(n) if abs(top[c] - 23) > 10]
k1 = cols[far, 23]
print(f"  1 kHz tone (row 23), where the sweep is > 10 rows away: levels {sorted(set(k1.tolist()))}")
ok &= bool((k1 >= 16).all())

mask = np.ones_like(cols, dtype=bool)
for c in range(n):
    mask[c, max(0, top[c] - 15):top[c] + 16] = False
mask[:, 18:29] = False
dark = float((cols[mask] <= 15).mean())
print(f"  away from both tones: {100 * dark:.1f} % dark (level <= 15)")
ok &= dark >= 0.95

pic = np.array(g.SPEC_RGB, dtype=np.uint32)[cols.T[::-1]]          # rows top-down, columns left-right
pic = np.repeat(np.repeat(pic, 2, axis=0), 4, axis=1)
img = np.stack([(pic >> 16) & 255, (pic >> 8) & 255, pic & 255], axis=-1).astype(np.uint8)
Image.fromarray(img).save(sys.argv[2])
print("  PASS" if ok else "  FAIL")
sys.exit(0 if ok else 1)
