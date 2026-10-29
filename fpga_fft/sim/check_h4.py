"""check_h4.py — turn tb_h4_frame.v's pixels into a PNG and check the picture.

    python check_h4.py <pixels.txt> <out.png>

Checks: a whole 1280x720 frame; the bars are green where the fake spectrum says; the peak
readout cells show "1002 Hz" / "-23 dB" (compared glyph by glyph with the font in
gen_h4_text.py); the tick lines sit behind the bars.
"""
import os
import sys

import numpy as np
from PIL import Image

sys.path.insert(0, os.path.join(os.path.dirname(__file__), ".."))
import gen_h4_text as g  # noqa: E402  (re-generates the ROMs; same output)

px = np.array([int(l, 16) for l in open(sys.argv[1]) if l.strip()], dtype=np.uint32)
ok = px.size == 1280 * 720
print(f"  {px.size} pixels (want {1280 * 720})")
img = np.stack([(px >> 16) & 255, (px >> 8) & 255, px & 255], axis=-1).astype(np.uint8).reshape(720, 1280, 3)
Image.fromarray(img).save(sys.argv[2])


def cell_text(row, col, n):
    """Read n cells back by matching each 16x16 cell against every glyph."""
    out = ""
    for c in range(col, col + n):
        cell = img[row * 16:(row + 1) * 16, c * 16:(c + 1) * 16].max(axis=2) > 0
        bits = [int("".join("1" if cell[r * 2, k * 2] else "0" for k in range(8)), 2) for r in range(8)]
        match = [ch for ch in list(g.GLYPHS) + [" "] if g.glyph_rows(ch) == bits]
        out += match[0] if match else "?"
    return out


hz, db, gain = cell_text(5, 72, 8), cell_text(6, 72, 7), cell_text(2, 67, 11)
title, axis = cell_text(1, 1, 17), cell_text(42, 76, 3)
print(f"  readout {hz!r} {db!r}   gain {gain!r}   title {title!r}   axis unit {axis!r}")
ok &= hz == " 1002 Hz" and db == " -23 dB" and gain == "GAIN +24 dB"
ok &= title == "LIVE FFT SPECTRUM" and axis == "kHz"
# bar at bin 46 (x 220-221) reaches up to y = 660 - 428 = 232; DC bins 0-1 are drawn too
bar = img[233:660, 221]
ok &= bool((bar == [0, 0xDC, 0x5A]).all()) and bool((img[231, 221] != [0, 0xDC, 0x5A]).any())
# gridlines for the -80 dB floor: every 150 px (y 60, 210, 360, 510, 660), none at the old 180
grid = [bool((img[y, 1100] == [0x46] * 3).all()) for y in (60, 210, 360, 510, 180)]
print(f"  gridlines at y 60/210/360/510: {grid[:4]}, at old y 180: {grid[4]}")
ok &= all(grid[:4]) and not grid[4]
labels = [cell_text(r, 1, 6) for r in (3, 13, 22, 31, 41)]
print(f"  dB labels {labels}")
ok &= labels == ["  0 dB", "-20 dB", "-40 dB", "-60 dB", "-80 dB"]
# a tick line (mic source, 1 kHz: x = 220) is dim grey above the bars, inside the plot
ok &= bool((img[100, 220] == [0x2A, 0x2A, 0x2A]).all()) and bool((img[30, 220] != [0x2A] * 3).any())
print("  PASS" if ok else "  FAIL")
sys.exit(0 if ok else 1)
