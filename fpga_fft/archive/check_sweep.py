"""check_sweep.py — check tb_sweep.v's I2S stream: decode it and compare with a model of the player.

    python check_sweep.py <sweep.txt> [out.png]

Line 1 of the file: N_SWEEP N_QUIET and the frames where the button was pressed. Line 2: one
character per BCLK rising edge, '0' + {pa_en, ws, din}. Decoding uses only the I2S rules (Philips
format): where WS changes, that bit is still the previous word's LSB, and the next 16 bits are the
new word, MSB first; WS low = left. Checks:
  - every left sample equals the right one;
  - every sample equals the model, frame by frame: a press turns the sound on (N_QUIET quiet
    samples, then a 512-sample fade in), off (fade out from wherever the fade is, then N_QUIET
    quiet samples, then the amplifier off), cancels a start still in its quiet part, or turns a
    fade out back into a fade in. The sound: phase += step; step +- 1746 per sample from the
    200 Hz step, N_SWEEP samples per leg, the step held for one sample at each turn; a 2nd tone
    whose phase moves by step + step // 2 (1.5 x) and a 3rd by 2 x step, each at a quarter of
    the amplitude: sample = (sine[ph] + sine[ph2] // 4 + sine[ph3] // 4) x (3277 x fade // 512)
    // 2^15; sine from rom_sine.v;
  - PA_EN is high exactly while the model's amplifier is on (one sample of slack at each edge);
  - the sound reaches 200 Hz and 4 kHz (the model's steps at its turns, at fs = 74.25 MHz / 1536),
    the 2nd tone 300 Hz and 6 kHz, the 3rd 400 Hz and 8 kHz;
  - the largest sample is at most 3277 + 819 + 819 = 4915 and above 3277 once faded in.
Optionally (long schedule) draws a spectrogram of the decoded samples.
"""
import os
import re
import sys

import numpy as np

HERE = os.path.dirname(os.path.abspath(__file__))
STEP_START, SWEEP_STEP, AMP, FADE = 17769885, 1746, 3277, 512
FS = 74.25e6 / 1536

sine = [0] * 1024
for m in re.finditer(r"10'd(\d+): q <= (-?)16'sd(\d+);",
                     open(os.path.join(HERE, "..", "src", "hdmi", "rom_sine.v")).read()):
    sine[int(m.group(1))] = int(m.group(3)) * (-1 if m.group(2) else 1)

head, raw = open(sys.argv[1]).read().split("\n", 1)
nums = [int(v) for v in head.split()]
N_SWEEP, N_QUIET, presses = nums[0], nums[1], set(nums[2:])
raw = raw.strip()


def model(frames):
    """Sample computed in each frame (sent during the next), and whether the amplifier is on."""
    IDLE, PRE, PLAY, STOP, POST = range(5)
    st, q, n, up, ph, ph2, ph3, step, env = IDLE, 0, 0, 1, 0, 0, 0, 0, 0
    out, pa, steps_seen = [], [], []
    for f in range(frames):
        sounding = st in (PLAY, STOP)
        mix = sine[ph >> 22] + (sine[ph2 >> 22] >> 2) + (sine[ph3 >> 22] >> 2)
        out.append(((mix * ((AMP * env) >> 9)) >> 15) if sounding else 0)
        pa.append(st != IDLE)
        if sounding:
            steps_seen.append(step)
            ph = (ph + step) & 0xFFFFFFFF
            ph2 = (ph2 + step + (step >> 1)) & 0xFFFFFFFF
            ph3 = (ph3 + (step << 1)) & 0xFFFFFFFF
            if n == N_SWEEP - 1:
                n, up = 0, 1 - up
            else:
                n += 1
                step += SWEEP_STEP if up else -SWEEP_STEP
        nst = st
        if st == PRE:
            if q == N_QUIET - 1:
                nst, ph, ph2, ph3, step, n, up, env = PLAY, 0, 0, 0, STEP_START, 0, 1, 0
            else:
                q += 1
        elif st == PLAY:
            if env != FADE:
                env += 1
        elif st == STOP:
            if env == 0:
                nst, q = POST, 0
            else:
                env -= 1
        elif st == POST:
            if q == N_QUIET - 1:
                nst = IDLE
            else:
                q += 1
        if f in presses:                     # the button acts on the state before this frame's step
            if st in (IDLE, POST):
                nst, q = PRE, 0
            elif st == PRE:
                nst = IDLE
            elif st == PLAY:
                nst = STOP
            elif st == STOP:
                nst = PLAY
        st = nst
    return np.array(out), np.array(pa), steps_seen


pa = np.array([int(c) >> 2 & 1 for c in raw], dtype=np.uint8)
ws = np.array([int(c) >> 1 & 1 for c in raw], dtype=np.uint8)
dn = np.array([int(c) & 1 for c in raw], dtype=np.uint8)
words = []                                   # (channel, value, pa_en at its MSB)
for j in np.nonzero(ws[1:] != ws[:-1])[0] + 1:
    if j + 16 >= len(dn):
        break
    v = int("".join(map(str, dn[j + 1:j + 17])), 2)
    words.append((int(ws[j]), v - 65536 if v >= 32768 else v, int(pa[j + 1])))
first = 0 if words[0][0] == 0 else 1
L, R = words[first::2], words[first + 1::2]
n = min(len(L), len(R))
ok = all(L[i][0] == 0 and R[i][0] == 1 for i in range(n))
lv = np.array([w[1] for w in L[:n]])
rv = np.array([w[1] for w in R[:n]])
pav = np.array([w[2] for w in L[:n]])
same = bool((lv == rv).all())
print(f"  {len(raw)} bit clocks -> {n} samples; presses at frames {sorted(presses)}; "
      f"left == right in all: {same}")
ok &= same

mo, mpa, steps = model(n + 8)
# decoded sample i is the one computed in frame i + off (off = a frame or two of start-up)
off = next((o for o in range(-4, 5) if (lv[max(0, -o):] == mo[max(0, o):max(0, o) + n - max(0, -o)]).all()), None)
print(f"  every sample equals the model: {off is not None} (offset {off} frames)")
ok &= off is not None
if off is not None:
    pm = mpa[off:off + n] if off >= 0 else np.concatenate([np.zeros(-off, bool), mpa[:n + off]])
    diff = np.nonzero(pav.astype(bool) != pm)[0]
    edges = np.nonzero(np.diff(pm.astype(int)))[0]
    pa_ok = all(min(abs(int(d) - int(e)) for e in edges) <= 1 for d in diff) if len(edges) else len(diff) == 0
    sessions = int((np.diff(pav.astype(int)) == 1).sum())
    print(f"  PA_EN follows the model (within one sample at its edges): {pa_ok}; "
          f"amplifier switched on {sessions} times")
    ok &= pa_ok
sounding = int((lv != 0).sum())
big = int(np.abs(lv).max())
print(f"  non-zero samples {sounding}; largest {big} (at most {AMP + 2 * (AMP // 4)}, and above {AMP} once faded in)")
ok &= AMP < big <= AMP + 2 * (AMP // 4)
lo, hi = min(steps), max(steps)
turns = sum(1 for a, b, c in zip(steps, steps[1:], steps[2:]) if a == b != c)
lo2, hi2, lo3, hi3 = lo + (lo >> 1), hi + (hi >> 1), 2 * lo, 2 * hi
print(f"  main tone {lo / 2**32 * FS:.1f} .. {hi / 2**32 * FS:.1f} Hz, 2nd "
      f"{lo2 / 2**32 * FS:.1f} .. {hi2 / 2**32 * FS:.1f} Hz, 3rd {lo3 / 2**32 * FS:.1f} .. "
      f"{hi3 / 2**32 * FS:.1f} Hz at fs {FS:.1f} Hz; {turns} turns (step held one sample)")
if N_SWEEP == 193359:
    ok &= abs(lo / 2**32 * FS - 200) < 0.5 and abs(hi / 2**32 * FS - 4000) < 1 and turns >= 2
    ok &= abs(lo2 / 2**32 * FS - 300) < 0.5 and abs(hi2 / 2**32 * FS - 6000) < 1.5
    ok &= abs(lo3 / 2**32 * FS - 400) < 0.5 and abs(hi3 / 2**32 * FS - 8000) < 2

if len(sys.argv) > 2 and N_SWEEP == 193359:
    import matplotlib
    matplotlib.use("Agg")
    import matplotlib.pyplot as plt
    plt.figure(figsize=(9, 4))
    plt.specgram(lv.astype(float), NFFT=1024, Fs=FS, noverlap=512, cmap="viridis")
    plt.ylim(0, 9000)
    plt.xlabel("s")
    plt.ylabel("Hz")
    plt.title("sweep_player output, decoded from the simulated I2S wires")
    plt.tight_layout()
    plt.savefig(sys.argv[2], dpi=100)
print("  PASS" if ok else "  FAIL")
sys.exit(0 if ok else 1)
