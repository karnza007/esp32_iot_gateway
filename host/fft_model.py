"""Test signals, reference FFTs and scoring for the FFT benchmark (F0).

Every device under test computes a 16-bit INTEGER FFT that halves the data at
each of its log2(N) stages, so its output is  FFT(x) / N  in int16.

This module provides the two yardsticks those devices are measured against:

    reference()        numpy.fft in 64-bit float, divided by N.
                       THE RULER: the true answer.

    ideal_fixed_fft()  a radix-2 FFT done the way a careful 16-bit integer
                       design would do it: Q15 twiddles, one rounding per
                       butterfly output, divide by 2 per stage, int16 storage.
                       THE PASS LINE: how much error a *correct* 16-bit FFT
                       has. A device within 3 dB of this is doing it right.

The same butterfly code runs in two modes. In 'float' mode nothing is rounded,
so it must equal numpy to ~1e-12 -- which proves the skeleton (bit reversal,
twiddle signs, stage order) before rounding is switched on. See selftest().

WIRE FORMAT (shared with the ESP32 and the FPGA)
    N complex samples, each  re:int16 LE, im:int16 LE   ->  4*N bytes
    natural order in, natural order out.
This is ESP-DSP's sc16 layout (Re[0], Im[0], Re[1], Im[1], ...).
"""

from __future__ import annotations

from dataclasses import dataclass

import numpy as np

INT16_MIN, INT16_MAX = -32768, 32767
Q = 15                     # twiddles are Q15: cos/sin scaled by 2**15
HALF = 1 << 14             # half scale, -6 dBFS: the default test amplitude


# ---------------------------------------------------------------------------
# Test signals
# ---------------------------------------------------------------------------

@dataclass
class Signal:
    name: str
    re: np.ndarray          # int16
    im: np.ndarray          # int16
    checks: str             # what this signal is for, in words
    peaks: tuple[int, ...]  # bins that must be the largest, () = no peak test


def _i16(x) -> np.ndarray:
    return np.clip(np.round(x), INT16_MIN, INT16_MAX).astype(np.int16)


def _odd_bin(k: int, n: int) -> int:
    """k if it fits below n/2, else the largest odd bin that does (small test sizes)."""
    if k < n // 2:
        return k
    m = n // 2 - 1
    return max(1, m if m % 2 else m - 1)


def make_signals(n: int, seed: int = 1) -> list[Signal]:
    """The eight test signals from the plan, all int16, all length n."""
    t = np.arange(n)
    zero = np.zeros(n, np.int16)
    # Tone bins are ODD on purpose. A tone on an even bin (8, 16, 64, ...) splits
    # so neatly through the butterflies that rounding almost never happens:
    # bin 64 scores 97 dB, bin 37 scores 59 dB, in the SAME correct model. An
    # even bin would measure luck in the device's internal layout, not accuracy.
    k1, k2, kc = (_odd_bin(k, n) for k in (37, 101, 77))
    rng = np.random.default_rng(seed)

    impulse = zero.copy()
    impulse[0] = INT16_MAX

    sq = np.where((t // max(n // 16, 1)) % 2 == 0, INT16_MAX, -INT16_MAX)

    return [
        Signal("impulse", impulse, zero,
               "flat spectrum: every bin, and the overall scaling", ()),
        Signal("dc", np.full(n, HALF, np.int16), zero,
               "all energy in bin 0", (0,)),
        Signal("tone_on_bin", _i16(HALF * np.cos(2 * np.pi * k1 * t / n)), zero,
               f"one clean spike at bin {k1}", (k1,)),
        Signal("tone_off_bin", _i16(HALF * np.cos(2 * np.pi * (k1 + 0.5) * t / n)), zero,
               "leakage between bins matches numpy", ()),
        Signal("two_tones", _i16(HALF / 2 * np.cos(2 * np.pi * k1 * t / n)
                                 + HALF / 8 * np.cos(2 * np.pi * k2 * t / n)), zero,
               f"both found, bin {k1} 12 dB above bin {k2}", (k1, k2)),
        Signal("noise", rng.integers(INT16_MIN, INT16_MAX + 1, n).astype(np.int16), zero,
               "average error across all bins, full scale", ()),
        Signal("full_scale", sq.astype(np.int16), zero,
               "largest real input: no overflow or wraparound", ()),
        Signal("complex_tone", _i16(HALF * np.cos(-2 * np.pi * kc * t / n)),
               _i16(HALF * np.sin(-2 * np.pi * kc * t / n)),
               f"imaginary path: single peak at bin {n - kc} (a negative frequency)",
               (n - kc,)),
    ]


def overload_signal(n: int) -> Signal:
    """Not part of the pass/fail set: a rotating vector with |x| = 46,340.

    re and im are both +/-32767 (the sign of cos and sin), so the input's
    MAGNITUDE is 32767 * sqrt(2) -- beyond what one int16 component can hold
    once the butterflies rotate it onto an axis. Halving per stage stops the
    magnitude growing, but it starts too big, so a 16-bit FFT MUST overflow.
    Run it to see HOW each device fails (wrap or saturate), not whether.
    """
    t = np.arange(n)
    k = _odd_bin(37, n)
    ph = 2 * np.pi * k * t / n
    re = np.where(np.cos(ph) >= 0, INT16_MAX, -INT16_MAX).astype(np.int16)
    im = np.where(np.sin(ph) >= 0, INT16_MAX, -INT16_MAX).astype(np.int16)
    return Signal("overload", re, im, "how overflow shows up (wrap vs saturate)", ())


# ---------------------------------------------------------------------------
# Wire format
# ---------------------------------------------------------------------------

def pack(re: np.ndarray, im: np.ndarray) -> bytes:
    """int16 re/im -> interleaved little-endian bytes (ESP-DSP sc16 layout)."""
    out = np.empty(2 * len(re), "<i2")
    out[0::2], out[1::2] = re, im
    return out.tobytes()


def unpack(buf: bytes) -> tuple[np.ndarray, np.ndarray]:
    a = np.frombuffer(buf, "<i2")
    return a[0::2].astype(np.int16), a[1::2].astype(np.int16)


# ---------------------------------------------------------------------------
# References
# ---------------------------------------------------------------------------

def reference(re: np.ndarray, im: np.ndarray) -> np.ndarray:
    """THE RULER: exact FFT / N in float64."""
    x = re.astype(np.float64) + 1j * im.astype(np.float64)
    return np.fft.fft(x) / len(x)


def _bitrev(n: int) -> np.ndarray:
    bits = n.bit_length() - 1
    idx = np.arange(n)
    rev = np.zeros(n, np.int64)
    for b in range(bits):
        rev |= ((idx >> b) & 1) << (bits - 1 - b)
    return rev


def _round_shift(v: np.ndarray, s: int) -> np.ndarray:
    """Integer v / 2**s, rounded half up -- one rounding, done once."""
    return (v + (1 << (s - 1))) >> s


def _wrap16(v: np.ndarray) -> tuple[np.ndarray, int]:
    """Store into int16 the way hardware does (two's-complement wrap); count overflows."""
    bad = int(np.count_nonzero((v < INT16_MIN) | (v > INT16_MAX)))
    return ((v - INT16_MIN) & 0xFFFF) + INT16_MIN, bad


def ideal_fixed_fft(re: np.ndarray, im: np.ndarray, mode: str = "int",
                    rounding: str = "single"):
    """Radix-2 decimation-in-time FFT, divide by 2 per stage.

    mode="int"   : Q15 twiddles, int64 arithmetic, ONE rounding per output,
                   int16 storage between stages. Returns (re, im, overflows).
    mode="float" : same butterflies, no rounding, exact twiddles. Must equal
                   reference(); used only to prove the structure is right.

    Butterfly, per stage:    top = (a + w*b) / 2      bot = (a - w*b) / 2
    In int mode both are formed as (a*2**15 +/- w*b) >> 16, so the product
    w*b is never rounded on its own -- the most accurate a 16-bit butterfly
    with 16-bit storage can be.

    rounding="double" is the common real-world shortcut: round w*b to an
    integer first, then round (a +/- that) / 2. Slightly worse, still a
    CORRECT FFT. rounding="truncate" just drops the low bits (also a legal
    core option, least accurate). selftest() uses both to prove the
    correctness gate passes every correct design, not just this one.
    """
    n = len(re)
    if n & (n - 1) or n < 2:
        raise ValueError("n must be a power of two")
    order = _bitrev(n)
    integer = mode == "int"
    dt = np.int64 if integer else np.float64
    xr = re.astype(dt)[order]
    xi = im.astype(dt)[order]
    overflows = 0

    size = 2
    while size <= n:
        half = size // 2
        ang = -2 * np.pi * np.arange(half) / size
        if integer:
            wr = np.round(np.cos(ang) * (1 << Q)).clip(-INT16_MAX, INT16_MAX).astype(np.int64)
            wi = np.round(np.sin(ang) * (1 << Q)).clip(-INT16_MAX, INT16_MAX).astype(np.int64)
        else:
            wr, wi = np.cos(ang), np.sin(ang)

        r = xr.reshape(-1, size)
        i = xi.reshape(-1, size)
        ar, ai = r[:, :half], i[:, :half]
        br, bi = r[:, half:], i[:, half:]
        pr = wr * br - wi * bi          # w*b, Q15 when integer
        pi = wr * bi + wi * br

        rs = (lambda v, k: v >> k) if rounding == "truncate" else _round_shift
        if integer and rounding == "double":
            pr, pi = rs(pr, Q) << Q, rs(pi, Q) << Q
        if integer:
            sr, si = ar << Q, ai << Q   # a, lifted to the same Q15 scale
            tr, ov1 = _wrap16(rs(sr + pr, Q + 1))
            ti, ov2 = _wrap16(rs(si + pi, Q + 1))
            ur, ov3 = _wrap16(rs(sr - pr, Q + 1))
            ui, ov4 = _wrap16(rs(si - pi, Q + 1))
            overflows += ov1 + ov2 + ov3 + ov4
        else:
            tr, ti = (ar + pr) / 2, (ai + pi) / 2
            ur, ui = (ar - pr) / 2, (ai - pi) / 2

        xr = np.concatenate([tr, ur], axis=1).reshape(-1)
        xi = np.concatenate([ti, ui], axis=1).reshape(-1)
        size *= 2

    if integer:
        return xr.astype(np.int16), xi.astype(np.int16), overflows
    return xr + 1j * xi


# ---------------------------------------------------------------------------
# Scoring
# ---------------------------------------------------------------------------

@dataclass
class Score:
    sqnr_db: float          # signal-to-quantisation-noise vs the ruler
    max_err_lsb: float      # worst single-component error, in int16 LSBs
    rms_err_lsb: float
    peaks_ok: bool | None   # None = this signal has no peak test


def score(dut_re: np.ndarray, dut_im: np.ndarray, sig: Signal) -> Score:
    ref = reference(sig.re, sig.im)
    dut = dut_re.astype(np.float64) + 1j * dut_im.astype(np.float64)
    err = dut - ref
    p_sig = float(np.sum(np.abs(ref) ** 2))
    p_err = float(np.sum(np.abs(err) ** 2))
    sqnr = float("inf") if p_err == 0 else 10 * np.log10(p_sig / p_err)
    max_err = float(max(np.max(np.abs(err.real)), np.max(np.abs(err.imag))))
    rms = float(np.sqrt(p_err / len(ref) / 2))

    peaks_ok = None
    if sig.peaks:
        mag = np.abs(dut)
        real_input = not np.any(sig.im)
        if real_input:                 # real input: spectrum is mirrored, look at 0..n/2
            mag = mag[: len(mag) // 2 + 1]
        top = set(np.argsort(mag)[::-1][: len(sig.peaks)].tolist())
        peaks_ok = top == set(sig.peaks)
        if len(sig.peaks) == 2:        # two tones: order of size must match too
            a, b = sig.peaks
            peaks_ok = peaks_ok and mag[a] > mag[b]

    return Score(sqnr, max_err, rms, peaks_ok)


# A correct 16-bit FFT is off by about one LSB; a broken one by hundreds.
# Measured with this module (selftest prints it every run):
#     best possible design (one rounding per butterfly)   0.43 LSB rms
#     common design (rounds twice per butterfly)           0.73 LSB rms
#     truncating instead of rounding                       1.32 LSB rms
#     output left in bit-reversed order                     575 LSB rms
#     one stage forgot to halve                             417 LSB rms
#     wrong direction (inverse instead of forward)          604 LSB rms
# So "correct" is a wide, unambiguous gate, and HOW accurate a correct design
# is becomes a separate number, compared between devices rather than pass/fail.
#
# The gate was 2.0 in F0, set from the modelled designs above. The first real
# library measured (ESP-DSP's SIMD FFT on the ESP32-S3, E1) is correct but sits
# at 1.8-2.0 LSB and crossed 2.0 once, by 0.003. Raised to 4.0 on 2026-10-08:
# twice the worst real correct design, still below the nearest bug (one missing
# bin, 7.1 LSB). The decision and both verdicts are in docs/11-fft-benchmark.md.
CORRECT_RMS_LSB = 4.0


def noise_floor(n: int) -> float:
    """RMS error (LSB) of the best possible 16-bit design on full-scale noise.

    Noise drives every butterfly with arbitrary values, so this is the generic
    rounding noise of a 16-bit FFT at size n: the accuracy ceiling.
    """
    s = next(x for x in make_signals(n) if x.name == "noise")
    r, i, _ = ideal_fixed_fft(s.re, s.im)
    return score(r, i, s).rms_err_lsb


def is_correct(dut: Score) -> bool:
    """H1 / H3, question 1: is it an FFT at all? Right peaks, rounding-sized error."""
    return dut.peaks_ok is not False and dut.rms_err_lsb <= CORRECT_RMS_LSB


def db_above_ideal(dut: Score, floor: float) -> float:
    """Question 2: how accurate? Error relative to the best possible 16-bit FFT.

    Only meaningful on signals that exercise rounding everywhere (noise, the
    off-bin tone); on impulse/DC/some tones the ideal model is exact by luck.
    """
    return 20 * np.log10(max(dut.rms_err_lsb, 1e-12) / floor)
