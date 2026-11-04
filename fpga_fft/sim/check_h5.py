"""check_h5.py — turn tb_h5_spec.v's pixels into a PNG and check the spectrogram page.

    python check_h5.py <pixels.txt> <out.png>

Checks, against the fake blocks of tb_h5_spec.v (300 written, so blocks 44..299 are on screen):
  - screen column 0 (being overwritten next) is black;
  - screen column c (1..255) is block 44 + c: its diagonal-line row (block mod 256) is colour
    15, the fixed tone's row 23 is colour 11 (or 15 where the line crosses it), and every other
    row is black;
  - the colour scale shows the 16 colours, 0 dB at the top;
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
for c in range(1, 256):
    blk = 44 + c
    for row in range(256):
        want = C[15] if row == blk % 256 else C[11] if row == 23 else C[0]
        got = rgb[659 - 2 * row, 128 + 4 * c + 1]
        if got != want:
            bad += 1
            if bad <= 5:
                print(f"    column {c} row {row}: got {got:06X}, want {want:06X}")
print(f"  plot: column 0 black {col0_black}; {255 * 256 - bad} of {255 * 256} points right")
ok &= col0_black and bad == 0
# each point is a full 4 x 2 block: compare the whole plot with the points scaled up
pts = np.array([[rgb[659 - 2 * r, 128 + 4 * c + 1] for c in range(256)] for r in range(255, -1, -1)])
full = np.repeat(np.repeat(pts, 2, axis=0), 4, axis=1)
full[:, 0:4] = 0
blocks_ok = bool((full == rgb[148:660, 128:1152]).all())
print(f"  every point fills its 4 x 2 px block: {blocks_ok}")
ok &= blocks_ok

# ---- colour scale: 16 blocks of 32 px, colour 15 at the top ----
scale = [rgb[148 + 32 * j + 16, 1175] for j in range(16)]
scale_ok = scale == [C[15 - j] for j in range(16)]
print(f"  colour scale top -> bottom matches colours 15 -> 0: {scale_ok}")
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
scale_labels = [cell_text(r, 75, 4) for r in (9, 25, 41)]
print(f"  title {title!r}; kHz labels {khz}; scale {scale_labels}; dB unit {cell_text(8, 73, 2)!r}")
print(f"  time axis {times.strip()!r}")
ok &= title == "LIVE SPECTROGRAM" and khz == [f"{k:>2}" for k in range(len(g.f_ticks))]
ok &= scale_labels == ["   0", " -40", " -80"] and cell_text(7, 4, 3) == "kHz"
ok &= times.split() == ["-10s", "-8s", "-6s", "-4s", "-2s", "now"]
print("  PASS" if ok else "  FAIL")
sys.exit(0 if ok else 1)
