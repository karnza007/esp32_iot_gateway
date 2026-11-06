"""check_sweep.py — check tb_sweep.v's I2S stream: decode it and compare with a model of the sweep.

    python check_sweep.py <sweep.txt> [out.png]

The file has one character per BCLK rising edge: '0' + {pa_en, ws, din}. Decoding uses only the
I2S rules (Philips format): where WS changes, that bit is still the previous word's LSB, and the
next 16 bits are the new word, MSB first; WS low = left. Checks:
  - every left sample equals the right one;
  - the samples equal the model exactly: 967 zeros, then 193,359 sweep samples (phase += step,
    step += 1746 from the 200 Hz step; sine from rom_sine.v; AMP 3277 x a 512-sample fade in and
    out), then zeros;
  - the amplifier is on (PA_EN) from before the first quiet sample to after the last one;
  - the frequency (from the model's step) runs 200 Hz -> 4 kHz at fs = 74.25 MHz / 1536.
Optionally draws a spectrogram of the decoded samples.
"""
import os
import re
import sys

import numpy as np

HERE = os.path.dirname(os.path.abspath(__file__))
STEP_START, SWEEP_STEP, N_SWEEP, N_QUIET, AMP, FADE = 17769885, 1746, 193359, 967, 3277, 512
FS = 74.25e6 / 1536

sine = [0] * 1024
for m in re.finditer(r"10'd(\d+): q <= (-?)16'sd(\d+);", open(os.path.join(HERE, "..", "src", "hdmi", "rom_sine.v")).read()):
    sine[int(m.group(1))] = int(m.group(3)) * (-1 if m.group(2) else 1)


def model():
    out, ph, step, env = [], 0, STEP_START, 0
    for n in range(N_SWEEP):
        g = (AMP * env) >> 9
        out.append((sine[ph >> 22] * g) >> 15)
        ph = (ph + step) & 0xFFFFFFFF
        step += SWEEP_STEP
        if n + 1 >= N_SWEEP - FADE:
            env = max(env - 1, 0)
        elif env != FADE:
            env += 1
    return out


raw = open(sys.argv[1]).read().strip()
pa = np.array([int(c) >> 2 & 1 for c in raw], dtype=np.uint8)
ws = np.array([int(c) >> 1 & 1 for c in raw], dtype=np.uint8)
dn = np.array([int(c) & 1 for c in raw], dtype=np.uint8)
words = []                                   # (channel, value, pa_en at its MSB)
for j in np.nonzero(ws[1:] != ws[:-1])[0] + 1:
    if j + 16 >= len(dn):
        break
    v = int("".join(map(str, dn[j + 1:j + 17])), 2)
    words.append((int(ws[j]), v - 65536 if v >= 32768 else v, int(pa[j + 1])))
# pair them: left (ws 0) then right (ws 1)
first = 0 if words[0][0] == 0 else 1
L = [w for w in words[first::2]]
R = [w for w in words[first + 1::2]]
n = min(len(L), len(R))
ok = all(L[i][0] == 0 and R[i][0] == 1 for i in range(n))
lv = np.array([w[1] for w in L[:n]])
rv = np.array([w[1] for w in R[:n]])
pav = np.array([w[2] for w in L[:n]])
same = bool((lv == rv).all())
print(f"  {len(raw)} bit clocks -> {n} samples (left + right); left == right in all: {same}")
ok &= same

m = np.array(model())
on = np.nonzero(pav)[0]
p0, p1 = int(on[0]), int(on[-1])
# the sweep starts after the quiet part that follows PA_EN rising; find it exactly
best = None
for off in range(p0, p0 + N_QUIET + 8):
    if off + N_SWEEP <= n and (lv[off:off + N_SWEEP] == m).all():
        best = off
        break
print(f"  PA_EN on for samples {p0} .. {p1} ({p1 - p0 + 1}); sweep found exactly at sample {best}")
ok &= best is not None
if best is not None:
    quiet_before = int(best - p0)
    quiet_after = int(p1 - (best + N_SWEEP - 1))
    zeros = bool((lv[:best] == 0).all() and (lv[best + N_SWEEP:] == 0).all())
    print(f"  all {N_SWEEP} sweep samples equal the model; quiet with the amplifier on: "
          f"{quiet_before} before, {quiet_after} after (want {N_QUIET} +- 2); "
          f"zeros outside the sweep: {zeros}")
    # before: the 967 quiet samples plus the frame in which the press is noticed
    ok &= zeros and abs(quiet_before - N_QUIET) <= 2 and abs(quiet_after - N_QUIET) <= 2
    mid = lv[best + N_SWEEP // 2 - 2000:best + N_SWEEP // 2 + 2000]
    fade_in = lv[best:best + 600]
    print(f"  peak in the middle {int(np.abs(mid).max())} (want ~{AMP}); "
          f"largest in the first 100 samples {int(np.abs(fade_in[:100]).max())} (fading in)")
    ok &= abs(int(np.abs(mid).max()) - AMP) <= 3
f0 = STEP_START / 2**32 * FS
f1 = (STEP_START + SWEEP_STEP * (N_SWEEP - 1)) / 2**32 * FS
print(f"  frequency {f0:.1f} Hz -> {f1:.1f} Hz over {N_SWEEP / FS:.2f} s at fs {FS:.1f} Hz")
ok &= abs(f0 - 200) < 1 and abs(f1 - 4000) < 2

if len(sys.argv) > 2 and best is not None:
    import matplotlib
    matplotlib.use("Agg")
    import matplotlib.pyplot as plt
    seg = lv[max(0, best - 2000):best + N_SWEEP + 2000].astype(float)
    plt.figure(figsize=(9, 4))
    plt.specgram(seg, NFFT=1024, Fs=FS, noverlap=512, cmap="viridis")
    plt.ylim(0, 5000)
    plt.xlabel("s")
    plt.ylabel("Hz")
    plt.title("sweep_player output, decoded from the simulated I2S wires")
    plt.tight_layout()
    plt.savefig(sys.argv[2], dpi=100)
print("  PASS" if ok else "  FAIL")
sys.exit(0 if ok else 1)
