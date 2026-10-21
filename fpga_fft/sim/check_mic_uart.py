"""check_mic_uart.py — check the UART bytes captured by tb_mic_uart.v.

    python check_mic_uart.py <bytes file> mic|tone

Parses the v3 frames (AA 55 A5 5A | seq | ovf | cfg | hdrsum | 512 x int16 | sum), checks both
checksums, and reads the sample rate with the viewer's own functions. Then:
  mic   every sample is the top 16 bits of the INMP441 model's next word, in order
  tone  the spectrum peak (viewer's Hann window) is at 1 kHz, amplitude about 4096
"""
import os
import sys

import numpy as np

sys.path.insert(0, os.path.join(os.path.dirname(__file__), "..", "..", "host"))
from inmp441_viewer import plausible_cfg, sample_rate_from_cfg  # noqa: E402

SYNC = b"\xAA\x55\xA5\x5A"
WORDS = [0xA5A5A5, 0x800000, 0x7FFFFF, 0x123456, 0x000123,
         0xFFFEDC, 0x001000, 0xFFF000, 0x00007F, 0x400000]
TOP16 = [w >> 8 for w in WORDS]

data = bytes(int(l, 16) for l in open(sys.argv[1]) if l.strip())
mode = sys.argv[2]
ok = True

frames, i = [], data.find(SYNC)
while i >= 0 and i + 1038 <= len(data):
    h = data[i + 4:i + 10]
    seq, ovf, cfg = (int.from_bytes(h[j:j + 2], "little") for j in (0, 2, 4))
    hsum = int.from_bytes(data[i + 10:i + 12], "little")
    pay = data[i + 12:i + 1036]
    psum = int.from_bytes(data[i + 1036:i + 1038], "little")
    good = hsum == sum(h) & 0xFFFF and psum == sum(pay) & 0xFFFF
    frames.append((seq, ovf, cfg, good, pay))
    i = data.find(SYNC, i + 1038)

print(f"  {len(frames)} frames: seq {[f[0] for f in frames]}  ovf {[f[1] for f in frames]}  "
      f"checksums ok {sum(f[3] for f in frames)}/{len(frames)}")
ok &= len(frames) >= 3 and all(f[3] for f in frames) and all(f[1] == 0 for f in frames)
ok &= [f[0] for f in frames] == list(range(frames[0][0], frames[0][0] + len(frames)))

cfg = frames[0][2]
fs = sample_rate_from_cfg(cfg)
want = 27e6 / 64 / (cfg & 0xFF)
print(f"  cfg 0x{cfg:04x}: plausible {plausible_cfg(cfg)}, BCLK_DIV {cfg & 0xFF}, fs {fs:.4f} Hz "
      f"(want {want:.4f})")
ok &= plausible_cfg(cfg) and abs(fs - want) < 1e-6

samples = np.concatenate([np.frombuffer(f[4], "<u2") for f in frames[1:]]).astype(np.int64)
if mode == "mic":
    k = TOP16.index(int(samples[0]))
    bad = sum(int(s) != TOP16[(k + n) % 10] for n, s in enumerate(samples))
    print(f"  {len(samples)} microphone samples in model order: {bad} wrong")
    ok &= bad == 0
else:
    s = np.where(samples >= 32768, samples - 65536, samples).astype(float)
    for f in range(len(frames) - 1):
        x = s[f * 512:(f + 1) * 512]
        w = np.hanning(512)
        mag = np.abs(np.fft.rfft(x * w)) / w.sum()
        k = int(np.argmax(mag))
        freqs = np.fft.rfftfreq(512, 1 / fs)
        print(f"  frame {f + 1}: peak bin {k} = {freqs[k]:.1f} Hz (bins {fs / 512:.1f} Hz apart), "
              f"amplitude {2 * mag[k]:.0f}, max |sample| {np.abs(x).max():.0f}")
        ok &= abs(freqs[k] - 1000) <= fs / 512 and 3500 < np.abs(x).max() <= 4096
print("  PASS" if ok else "  FAIL")
sys.exit(0 if ok else 1)
