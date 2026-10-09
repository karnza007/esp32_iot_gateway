"""check_h2.py — check the H2 simulations (tb_h2_audio.v, tb_h2_video.v) against Python models.

    python check_h2.py audio <dir>          # after tb_h2_audio  (+dir=<dir>)
    python check_h2.py video <bars> <pixels> # after tb_h2_video

audio: (1) the tone samples are bit-exact with a model of tone_gen's phase accumulators,
       (2) the windowed block is bit-exact with gain/clamp/Hann applied in Python,
       (3) the FFT is correct (same 4 LSB gate as the benchmark),
       (4) the 512 heights are bit-exact with the height formula applied to the FFT output,
       (5) the picture makes physical sense: tone 1 at bin 200, about -18 dB; tone 2 at 1 kHz.
video: every pixel of the frame against the layout drawn from the same heights.
"""
import math
import sys
from pathlib import Path

import numpy as np

sys.path.insert(0, str(Path(__file__).resolve().parents[2] / "host"))
import fft_model as fm  # noqa: E402

SIN = [round(32767 * math.sin(2 * math.pi * k / 1024)) for k in range(1024)]
HANN = [round(32767 * 0.5 * (1 - math.cos(2 * math.pi * k / 1024))) for k in range(1024)]
LOG2F = [round(32 * math.log2(1 + m / 32)) for m in range(32)]
ok = True


def check(name, cond, detail=""):
    global ok
    ok &= bool(cond)
    print(f"  {'PASS' if cond else 'FAIL'}  {name:<58} {detail}")


def tone_model(n, inc1=838860800, sweep=0, inc2=88849424, amp2=164, inc_max=2132386187):
    ph1 = ph2 = 0
    out = []
    for _ in range(n):
        s1 = SIN[ph1 >> 22] >> 1
        s2 = (SIN[ph2 >> 22] * amp2) >> 15
        v = (s1 + s2) & 0xFFFF
        out.append(v - 65536 if v >= 32768 else v)
        ph1 = (ph1 + inc1) & 0xFFFFFFFF
        ph2 = (ph2 + inc2) & 0xFFFFFFFF
        inc1 = 0 if inc1 + sweep > inc_max else inc1 + sweep
    return out


def window_model(block, gain_shift=0, clamp=32700):
    out = []
    for k, s in enumerate(block):
        g = max(-clamp, min(clamp, s << gain_shift))
        p = g * HANN[k]
        out.append(((p >> 15) + 32768) % 65536 - 32768)
    return out


def height_model(re, im):
    p = int(re) * int(re) + int(im) * int(im)
    if p == 0:
        return 0
    e = p.bit_length() - 1
    nm = (p << (31 - e)) & 0xFFFFFFFF
    L = e * 32 + LOG2F[(nm >> 26) & 31]
    return min(600, (289 * L + 29773) >> 9)


def audio(d: Path):
    s = [int(x) for x in (d / "samples.txt").read_text().split()]
    check("tone samples bit-exact with the phase-accumulator model", s == tone_model(len(s)),
          f"{len(s)} samples")
    w = [int(x) for x in (d / "windowed.txt").read_text().split()]
    check("windowed block (samples 1024-2047) bit-exact with gain/clamp/Hann",
          w == window_model(s[1024:2048]), "1024 values")
    fx = np.loadtxt(d / "fft.txt", dtype=np.int64)
    re, im = np.zeros(1024, np.int64), np.zeros(1024, np.int64)
    re[fx[:, 0]], im[fx[:, 0]] = fx[:, 1], fx[:, 2]
    sig = fm.Signal("h2", np.array(w, np.int16), np.zeros(1024, np.int16), "", [])
    sc = fm.score(re.astype(np.int16), im.astype(np.int16), sig)
    check("FFT of the windowed block is correct (4 LSB gate)", fm.is_correct(sc),
          f"rms {sc.rms_err_lsb:.2f} LSB")
    bars = np.loadtxt(d / "bars.txt", dtype=np.int64)
    got = dict(zip(bars[:, 0].tolist(), bars[:, 1].tolist()))
    exp = {k: height_model(re[k], im[k]) for k in range(512)}
    check("all 512 bins written", sorted(got) == list(range(512)))
    check("heights bit-exact with the dB formula applied to the FFT output",
          all(got.get(k) == exp[k] for k in range(512)),
          f"{sum(got.get(k) != exp[k] for k in range(512))} differ")
    db = lambda px: px / 6 - 100
    h = np.array([got[k] for k in range(512)])
    k1 = int(np.argmax(h))
    check("tone 1 peak in bin 200", k1 == 200, f"bin {k1}")
    check("tone 1 at about -18 dB (half scale, mirror split, window)", abs(db(h[200]) + 18) < 1,
          f"{db(h[200]):.1f} dB ({h[200]} px)")
    b2 = 1000 / (74.25e6 / 1536 / 1024)
    k2 = int(np.argmax(h[15:30])) + 15
    check("tone 2 (1 kHz) peak at bin 21", k2 == round(b2), f"bin {k2} (1 kHz = bin {b2:.2f})")
    check("tone 2 about 40 dB below tone 1 (window scalloping up to 1.4 dB)",
          38 < db(h[200]) - db(h[k2]) < 43.5, f"{db(h[200]) - db(h[k2]):.1f} dB lower")
    far = [k for k in range(512) if abs(k - 200) > 6 and abs(k - 21) > 6]
    check("everything away from the tones below -60 dB", db(h[far].max()) < -60,
          f"highest {db(h[far].max()):.1f} dB")
    np.savetxt(d / "bars_sorted.txt", np.c_[np.arange(512), h], fmt="%d")


def video(bars_file: Path, pix_file: Path):
    bars = np.loadtxt(bars_file, dtype=np.int64)
    h = np.zeros(512, np.int64)
    h[bars[:, 0]] = bars[:, 1]
    px = np.array([int(l, 16) for l in pix_file.read_text().split()], np.int64)
    check("one full frame of pixels", len(px) == 1280 * 720, f"{len(px)}")
    img = px.reshape(720, 1280)
    exp = np.zeros((720, 1280), np.int64)
    xs = np.arange(1280)
    in_x = (xs >= 128) & (xs < 1152)
    for y in (60, 180, 300, 420, 540, 660):
        exp[y, in_x] = 0x464646
    hx = np.where(in_x, h[np.clip((xs - 128) // 2, 0, 511)], 0)
    for y in range(660):
        exp[y, in_x & (y + hx >= 660)] = 0x00DC5A
    bad = np.argwhere(img != exp)
    check("every pixel matches the layout (bars, gridlines, black)", len(bad) == 0,
          f"{len(bad)} differ" + (f", first at (x,y)={tuple(bad[0][::-1])}" if len(bad) else ""))


if __name__ == "__main__":
    if sys.argv[1] == "audio":
        audio(Path(sys.argv[2]))
    else:
        video(Path(sys.argv[2]), Path(sys.argv[3]))
    print("  ->", "ALL PASS" if ok else "FAILED")
    sys.exit(0 if ok else 1)
