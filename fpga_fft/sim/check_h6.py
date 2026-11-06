"""check_h6.py — turn tb_h6_wave.v's pixels into a PNG and check the waveform page.

    python check_h6.py <pixels.txt> <samples.txt> <out.png>

Checks:
  - the plot shows 1,024 consecutive fed samples, starting where the wave crosses 0 going up
    (the trigger): this file searches the samples for the start that matches;
  - every plot pixel: column c (x = 128 + c) is lit from the previous column's height to its own
    (height y = 403 - off, off = sample x 800 // 4096 limited to -256..255), red where off is at
    an edge (the -40 dB tone peak, 1311, or beyond), green otherwise; grid lines (gen_h4_text.py's
    w_grid) grey where not lit; everything else black;
  - tick marks every 5 ms below the plot; the labels (title, dB, ms, the note at the bottom).
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
Image.fromarray(img).save(sys.argv[3])
rgb = (img[..., 0].astype(np.uint32) << 16) | (img[..., 1].astype(np.uint32) << 8) | img[..., 2]
samples = np.array([int(l) for l in open(sys.argv[2]) if l.strip()])


def off(v):
    return np.clip((v * g.WAVE_MUL) >> 12, -256, 255)


def render(seg):
    o = off(seg)
    prev = np.concatenate([[o[0]], o[:-1]])
    yc, yp = 403 - o, 403 - prev
    lo, hi = np.minimum(yc, yp), np.maximum(yc, yp)
    ys = np.arange(148, 660)[:, None]
    lit = (ys >= lo) & (ys <= hi)
    clip = (o == 255) | (o == -256)
    out = np.zeros((512, 1024), dtype=np.uint32)
    for gy in g.w_grid:
        out[gy - 148, :] = 0x464646
    out[lit] = np.where(np.broadcast_to(clip, lit.shape)[lit], 0xFF4040, 0x00DC5A)
    return out


plot = rgb[148:660, 128:1152]
start = None
for i in range(1, len(samples) - 1024):
    if samples[i - 1] < 0 <= samples[i] and (render(samples[i:i + 1024]) == plot).all():
        start = i
        break
print(f"  plot = samples {start} .. {None if start is None else start + 1023}, starting at a rising "
      f"zero crossing; every pixel of the plot right: {start is not None}")
ok &= start is not None
if start is not None:
    o = off(samples[start:start + 1024])
    print(f"  red (at the -40 dB edges) in {int(((o == 255) | (o == -256)).sum())} of 1024 columns; "
          f"heights {int(o.min())} .. {int(o.max())}")
    ok &= bool(((o == 255) | (o == -256)).any())

t_ok = all(rgb[663, x] == 0x808080 for x in g.w_ticks)
outside = rgb[660:668, 128:1152].copy()
outside[:, [x - 128 for x in g.w_ticks]] = 0
print(f"  tick marks every 5 ms: {len(g.w_ticks)} {t_ok}; nothing else below the plot: {not outside.any()}")
ok &= t_ok and not outside.any()


def cell_text(row, col, n):
    out = ""
    for c in range(col, col + n):
        cell = img[row * 16:(row + 1) * 16, c * 16:(c + 1) * 16].max(axis=2) > 0
        bits = [int("".join("1" if cell[r * 2, k * 2] else "0" for k in range(8)), 2) for r in range(8)]
        match = [ch for ch in list(g.GLYPHS) + [" "] if g.glyph_rows(ch) == bits]
        out += match[0] if match else "?"
    return out


title = cell_text(1, 1, 13)
dbl = [cell_text(r, 0, 7).strip() for r in (9, 20, 23, 25, 26, 30, 41)]   # 25: centre, no label
ms = cell_text(42, 7, 72).split()
note = cell_text(43, 8, 64).strip()
print(f"  title {title!r}; dB labels {dbl}")
print(f"  time labels {ms}; note {note!r}")
ok &= title == "LIVE WAVEFORM"
ok &= dbl == ["-40 dB", "-50 dB", "-60 dB", "", "-60 dB", "-50 dB", "-40 dB"]
ok &= ms == [str(m) for m in range(0, 50, 5)] + ["ms"]
ok &= note == "EDGES: PEAK OF A -40 dB TONE  1311 / 32767    RED: AT THE EDGE"
print("  PASS" if ok else "  FAIL")
sys.exit(0 if ok else 1)
