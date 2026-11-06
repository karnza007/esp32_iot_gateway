"""check_audio.py — check tb_audio.v: did the music come out of the I2S wires exactly as sent?

    python check_audio.py <out.txt> <bits.txt>

The bits are decoded with the I2S rules only (Philips: where WS changes, that bit is still the
previous word's LSB; the next 16 bits are the new word, MSB first; WS low = left). Checks:
  - left == right in every frame;
  - the played stream is exactly what audio_rx should make of the samples that arrived intact
    (all of them, minus the bad packet if there was one): with y = 0, 0, x0, x1, ... the output
    is y0, (y0 + y1) // 2, y1, (y1 + y2) // 2, ...  (each received sample covers two output
    frames, the second the average with the next one), with no gap, from start to the last sample;
  - the FPGA's counters: no dropped packets (the credits kept the buffer from overflowing), the
    bad packet seen as one bad sum and one sequence gap, exactly one underrun (the song's end);
  - the buffer never held more than 2,048 samples, and after the song PA_EN went off.
"""
import sys

import numpy as np

head, xs = open(sys.argv[1]).read().split("\n")[:2]
N, bad_pkt, n_bad, n_gap, n_drop, n_und, maxlevel, credits = map(int, head.split())
x = [int(v) for v in xs.split()]
raw = open(sys.argv[2]).read().strip()
a = np.frombuffer(raw.encode(), dtype=np.uint8) - 48
pa, ws, dn = (a >> 2) & 1, (a >> 1) & 1, a & 1
j = np.nonzero(ws[1:] != ws[:-1])[0] + 1
j = j[j + 16 < len(dn)]
v = (dn[j[:, None] + 1 + np.arange(16)] * (1 << np.arange(15, -1, -1))).sum(1)
v = np.where(v >= 32768, v - 65536, v)
ch = ws[j]
first = 0 if ch[0] == 0 else 1
L, R = v[first::2], v[first + 1::2]
m = min(len(L), len(R))
L, R = L[:m], R[:m]
same = bool((L == R).all())
print(f"  {len(raw):,} bit clocks -> {m:,} frames; left == right in all: {same}")
ok = same

kept = [s for i, s in enumerate(x) if bad_pkt < 0 or not (32 * bad_pkt <= i < 32 * bad_pkt + 32)]
y = [0, 0] + kept
exp = []
for i in range(len(y) - 1):
    exp += [y[i], (y[i] + y[i + 1]) >> 1]
exp.append(y[-1])
exp = np.array(exp)
L = np.array(L)
off = None
for o in range(len(L) - len(exp) + 1):
    if L[o] == exp[0] and L[o + 4] == exp[4] and (L[o:o + len(exp)] == exp).all():
        off = o
        break
print(f"  {len(kept):,} samples arrived intact (of {N:,}); played exactly, with no gap: {off is not None}"
      + (f" (frames {off:,} .. {off + len(exp) - 1:,})" if off is not None else ""))
ok &= off is not None
want_bad = 1 if bad_pkt >= 0 else 0
print(f"  counters: bad sums {n_bad} (want {want_bad}), seq gaps {n_gap} (want {want_bad}), "
      f"dropped {n_drop} (want 0), underruns {n_und} (want 1: the end); most buffered {maxlevel} "
      f"(max 2048); credits read {credits}")
ok &= n_bad == want_bad and n_gap == want_bad and n_drop == 0 and n_und == 1 and maxlevel <= 2048
pa_after = int(pa[-200:].max())
print(f"  PA_EN at the end: {'on' if pa_after else 'off'} (want off)")
ok &= pa_after == 0
print("  PASS" if ok else "  FAIL")
sys.exit(0 if ok else 1)
