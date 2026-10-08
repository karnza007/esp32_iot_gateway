"""FFT benchmark harness: Gowin FFT IP vs ESP32-S3 ESP-DSP vs (later) Intel FFT IP.

Plan: docs/plans/fft-benchmark.md     Results: docs/11-fft-benchmark.md

Commands
    selftest           prove the models AND the correctness gate before trusting them
    model [-n N ...]   what the best possible 16-bit FFT scores per test signal,
                       saved to data/fft/f0-model-baseline.csv

Each device result is judged twice:
    correct?       right peaks and rms error <= 2 LSB (correct designs: 0.4-1.3,
                   bugs: 400+; see fft_model.CORRECT_RMS_LSB)
    how accurate?  rms error in LSB, and dB above the best possible design

    (E1 adds 'esp32', F3 adds 'fpga': same signals, same scoring.)
"""

from __future__ import annotations

import argparse
import csv
import sys
from pathlib import Path

import numpy as np

import fft_model as fm

ROOT = Path(__file__).resolve().parent.parent
DATA = ROOT / "data" / "fft"


def selftest() -> bool:
    """Prove the models and the scoring rule before trusting them on hardware.

    Each check guards one way the yardstick itself could be silently wrong.
    """
    ok = True

    def check(name: str, cond: bool, detail: str = "") -> None:
        nonlocal ok
        ok &= bool(cond)
        print(f"  {'PASS' if cond else 'FAIL'}  {name:<44} {detail}")

    def rms(r, i, s) -> float:
        return fm.score(r, i, s).rms_err_lsb

    print("selftest\n -- the model is an FFT")
    for n in (8, 64, 1024):
        sigs = fm.make_signals(n) + [fm.overload_signal(n)]
        worst = max(np.max(np.abs(fm.ideal_fixed_fft(s.re, s.im, "float")
                                  - fm.reference(s.re, s.im))) for s in sigs)
        check(f"float model == numpy (n={n})", worst < 1e-9, f"max diff {worst:.1e}")

    n = 1024
    sigs = {s.name: s for s in fm.make_signals(n)}
    r, i, _ = fm.ideal_fixed_fft(sigs["impulse"].re, sigs["impulse"].im)
    check("impulse -> flat 32767/N (the ÷N scaling)",
          np.all(np.abs(r - 32767 / n) <= 1) and np.all(i == 0),
          f"bins {r.min()}..{r.max()}, expected {32767 / n:.1f}")

    print(" -- the gate passes every CORRECT design (worst rms over all signals)")
    for design in ("single", "double", "truncate"):
        worst, bad = 0.0, []
        for n2 in (256, 512, 1024):
            for s in fm.make_signals(n2):
                sc = fm.score(*fm.ideal_fixed_fft(s.re, s.im, rounding=design)[:2], s)
                worst = max(worst, sc.rms_err_lsb)
                if not fm.is_correct(sc):
                    bad.append(f"{s.name}@{n2}")
        check(f"{design}-rounding design is correct", not bad,
              f"worst {worst:.2f} LSB" + (f"  failed: {', '.join(bad)}" if bad else ""))

    print(" -- the gate fails every BROKEN design (noise signal, n=1024)")
    s = sigs["noise"]
    r, i, _ = fm.ideal_fixed_fft(s.re, s.im)
    i32 = lambda x: x.astype(np.int32)
    i16 = lambda x: np.clip(x, -32768, 32767).astype(np.int16)
    br = fm._bitrev(n)
    bugs = {
        "output left in bit-reversed order": (r[br], i[br]),
        "one stage forgot to halve (x2)": (i16(i32(r) * 2), i16(i32(i) * 2)),
        "wrong direction (inverse FFT)": (r, i16(-i32(i))),
        "one bin missing": (np.where(np.arange(n) == 5, 0, r).astype(np.int16), i),
    }
    for name, (br_, bi_) in bugs.items():
        check(name, not fm.is_correct(fm.score(br_, bi_, s)), f"{rms(br_, bi_, s):.1f} LSB")
    t = sigs["tone_on_bin"]
    tr, ti, _ = fm.ideal_fixed_fft(t.re, t.im)
    check("tone lands one bin off", fm.score(np.roll(tr, 1), ti, t).peaks_ok is False)

    print(" -- the rest of the harness")
    o = fm.overload_signal(n)
    _, _, ovf = fm.ideal_fixed_fft(o.re, o.im)
    check("overload signal really overflows", ovf > 0, f"{ovf} overflows")
    b = fm.pack(s.re, s.im)
    r3, i3 = fm.unpack(b)
    check("pack/unpack round trip", len(b) == 4 * n and np.array_equal(r3, s.re)
          and np.array_equal(i3, s.im), f"{len(b)} bytes")

    print("  ->", "ALL PASS" if ok else "FAILED")
    return ok


def model(sizes: list[int]) -> None:
    """Print and save what the best possible 16-bit FFT scores on each signal."""
    DATA.mkdir(parents=True, exist_ok=True)
    out = DATA / "f0-model-baseline.csv"
    rows = []
    for n in sizes:
        floor = fm.noise_floor(n)
        print(f"\nbest possible 16-bit integer FFT, N = {n}   "
              f"(÷2 per stage, Q15 twiddles; noise floor {floor:.3f} LSB rms)")
        print(f"  {'signal':<14}{'SQNR dB':>9}{'max err':>9}{'rms err':>9}"
              f"{'peaks':>7}{'ovf':>6}   checks")
        for s in fm.make_signals(n) + [fm.overload_signal(n)]:
            r, i, ovf = fm.ideal_fixed_fft(s.re, s.im)
            sc = fm.score(r, i, s)
            pk = "-" if sc.peaks_ok is None else ("ok" if sc.peaks_ok else "WRONG")
            print(f"  {s.name:<14}{sc.sqnr_db:9.1f}{sc.max_err_lsb:9.2f}"
                  f"{sc.rms_err_lsb:9.3f}{pk:>7}{ovf:6d}   {s.checks}")
            rows.append(dict(n=n, signal=s.name, sqnr_db=round(sc.sqnr_db, 2),
                             max_err_lsb=round(sc.max_err_lsb, 3),
                             rms_err_lsb=round(sc.rms_err_lsb, 4),
                             peaks_ok=sc.peaks_ok, overflows=ovf,
                             noise_floor_lsb=round(floor, 4)))
    with out.open("w", newline="") as f:
        w = csv.DictWriter(f, fieldnames=rows[0].keys())
        w.writeheader()
        w.writerows(rows)
    print(f"\ncorrect = right peaks and rms error <= {fm.CORRECT_RMS_LSB} LSB")
    print(f"saved {out.relative_to(ROOT)}")


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__,
                                 formatter_class=argparse.RawDescriptionHelpFormatter)
    sub = ap.add_subparsers(dest="cmd", required=True)
    sub.add_parser("selftest")
    m = sub.add_parser("model")
    m.add_argument("-n", type=int, nargs="+", default=[256, 512, 1024])
    a = ap.parse_args()

    if a.cmd == "selftest":
        return 0 if selftest() else 1
    model(a.n)
    return 0


if __name__ == "__main__":
    sys.exit(main())
