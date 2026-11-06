"""check_h5.py — turn tb_h5_spec.v's pixels into a PNG and check the spectrogram page.

    python check_h5.py <pixels.txt> <out.png>

Checks, against the fake blocks of tb_h5_spec.v (300 written, so blocks 44..299 are on screen):
  - screen column 0 (being overwritten next) is black;
  - screen column c (1..255) is block 44 + c, and every point has the colour of its level,
    worked out here from the same heights: the louder bin of the pair, then 0 = height 0
    (black), 31 = height 225 and up (white), else height / 7.5 + 1 (rounded down);
  - the colour scale shows white at the top, then levels 30 .. 1, 16 px each;
  - tick marks and labels (title, kHz, time, colour scale) are where gen_h4_text.py put them.
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
rgb = (img[..., 0].astype(np.uint32) << 16) | (img[..., 1].astype(np.uint32) << 8) | img[..., 2]


def cell_text(row, col, n):
    """Read n cells back by matching each 16x16 cell against every glyph."""
    out = ""
    for c in range(col, col + n):
        cell = img[row * 16:(row + 1) * 16, c * 16:(c + 1) * 16].max(axis=2) > 0
        bits = [int("".join("1" if cell[r * 2, k * 2] else "0" for k in range(8)), 2) for r in range(8)]
        match = [ch for ch in list(g.GLYPHS) + [" "] if g.glyph_rows(ch) == bits]
        out += match[0] if match else "?"
    return out


# ---- the plot: every point, 256 x 256 (one pixel per point, inside its 4 x 2 px block) ----
C = g.SPEC_RGB
bad = 0
col0_black = not rgb[148:660, 128:132].any()
def height(k, b):
    h = (7 * b + 3 * k) % 61 if b % 2 else (13 * b + 5 * k) % 241
    return 600 if b == (2 * k) % 512 else 150 if b == 46 else h


def level(h):
    return 0 if h == 0 else 31 if h >= 225 else int(h / 7.5) + 1


used = set()
for c in range(1, 256):
    blk = 44 + c
    for row in range(256):
        lv = level(max(height(blk, 2 * row), height(blk, 2 * row + 1)))
        used.add(lv)
        want = C[lv]
        got = rgb[659 - 2 * row, 128 + 4 * c + 1]
        if got != want:
            bad += 1
            if bad <= 5:
                print(f"    column {c} row {row}: got {got:06X}, want {want:06X}")
print(f"  plot: column 0 black {col0_black}; {255 * 256 - bad} of {255 * 256} points right; "
      f"{len(used)} of 32 levels used")
ok &= col0_black and bad == 0 and len(used) == 32
# each point is a full 4 x 2 block: compare the whole plot with the points scaled up
pts = np.array([[rgb[659 - 2 * r, 128 + 4 * c + 1] for c in range(256)] for r in range(255, -1, -1)])
full = np.repeat(np.repeat(pts, 2, axis=0), 4, axis=1)
full[:, 0:4] = 0
blocks_ok = bool((full == rgb[148:660, 128:1152]).all())
print(f"  every point fills its 4 x 2 px block: {blocks_ok}")
ok &= blocks_ok

# ---- colour scale: white (32 px), then levels 30 .. 1, 16 px each ----
scale = [rgb[148 + y, 1175] for y in [0, 31] + [32 + 16 * j + d for j in range(30) for d in (0, 15)]]
scale_ok = scale == [C[31]] * 2 + [C[30 - j] for j in range(30) for d in (0, 15)]
print(f"  colour scale top -> bottom: white, then levels 30 -> 1: {scale_ok}")
ok &= scale_ok

# ---- tick marks ----
f_ok = all(rgb[y, 123] == 0x808080 for y in g.f_ticks)
t_ok = all(rgb[663, x] == 0x808080 for x in g.t_ticks)
print(f"  tick marks: {len(g.f_ticks)} kHz {f_ok}, {len(g.t_ticks)} time {t_ok}")
ok &= f_ok and t_ok

# ---- text ----
title = cell_text(1, 1, 16)
khz = [cell_text(round((y - 8) / 16), 5, 2) for y in g.f_ticks]
times = cell_text(42, 8, 66)
scale_labels = [cell_text(r, 75, 4) for r in (10, 11, 21, 31, 41)]
print(f"  title {title!r}; kHz labels {khz}; scale {scale_labels}; dB unit {cell_text(8, 73, 2)!r}")
print(f"  time axis {times.strip()!r}")
ok &= title == "LIVE SPECTROGRAM" and khz == [f"{k:>2}" for k in range(len(g.f_ticks))]
ok &= scale_labels == [">-50", " -50", " -60", " -70", " -80"] and cell_text(7, 4, 3) == "kHz"
ts = [t for t in range(0, 100, g.STEP_S) if 255 - t * g.COL_PER_S >= 1]
ok &= times.split() == ["now" if t == 0 else f"-{t}s" for t in reversed(ts)]
print("  PASS" if ok else "  FAIL")
sys.exit(0 if ok else 1)
