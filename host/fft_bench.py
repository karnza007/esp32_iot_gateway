"""FFT benchmark harness: Gowin FFT IP vs ESP32-S3 ESP-DSP vs (later) Intel FFT IP.

Plan: docs/plans/fft-benchmark.md     Results: docs/11-fft-benchmark.md

Commands
    selftest           prove the models AND the correctness gate before trusting them
    model [-n N ...]   what the best possible 16-bit FFT scores per test signal,
                       saved to data/fft/f0-model-baseline.csv

Each device result is judged twice:
    correct?       right peaks and rms error <= 4 LSB (correct designs: 0.4-2.0,
                   bugs: 7+; see fft_model.CORRECT_RMS_LSB)
    how accurate?  rms error in LSB, and dB above the best possible design

    esp32 [-n N ...]   run every signal through the ESP32-S3's 16-bit FFT
                       (firmware/fft_bench), score it, time it;
                       saved to data/fft/e1-esp32-<impl>.csv
                       --impl simd (default, the fast one) | ansi (plain C)

    sim [--board]      simulate the Gowin core with free tools (Icarus Verilog + the
                       core's unencrypted gate-level model fft_1024.vo + Gowin's
                       primitive library), score it like the hardware, and with
                       --board compare every output bit with the real FPGA;
                       saved to data/fft/f3-sim-gowin.csv

    fpga-echo [-r R]   F2: every test signal (plus raw byte patterns) goes
                       Mac -> ESP32 -> FPGA -> back, R times each, and must come
                       back byte for byte; saved to data/fft/f2-fpga-echo.csv

    fpga               F3: every signal through the Gowin FFT core on the Tang Nano
                       20K (via the ESP32), same scoring as the ESP32, timed by the
                       FPGA's own cycle counter; saved to data/fft/f3-fpga-gowin.csv
"""

from __future__ import annotations

import argparse
import csv
import glob
import struct
import sys
import time
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


# ---------------------------------------------------------------------------
# Device link (protocol: see the header of firmware/fft_bench/fft_bench.ino)
# ---------------------------------------------------------------------------

STATUS = {0: "ok", 1: "bad checksum", 2: "bad size", 3: "bad command", 4: "FFT error",
          5: "FPGA did not reply", 6: "data reached the FPGA corrupted",
          7: "FPGA's reply arrived corrupted", 8: "FPGA rejected the command"}


class Device:
    """One request/reply exchange per FFT, over a serial port."""

    def __init__(self, port: str, baud: int):
        import serial
        self.ser = serial.Serial(port, baud, timeout=3)
        time.sleep(0.5)                       # let a reset-on-open finish booting
        self.ser.reset_input_buffer()

    def _request(self, cmd: bytes, log2n: int, payload: bytes = b"") -> tuple[dict, bytes]:
        body = b"FFTQ" + cmd + bytes([log2n, 0, 0])
        if payload:
            body += payload + struct.pack("<H", sum(payload) & 0xFFFF)
        self.ser.write(body)
        return self._reply()

    def _reply(self) -> tuple[dict, bytes]:
        win = b""
        t0 = time.time()
        while win != b"FFTR":                 # hunt for the magic, skip any junk
            b = self.ser.read(1)
            if not b:
                if time.time() - t0 > 5:
                    raise TimeoutError("no reply from device")
                continue
            win = (win + b)[-4:]
        hdr = self._read(20)
        status, log2n, has_payload, n_split, fmin, favg, extra, mhz = struct.unpack("<BBBBIIII", hdr)
        # extra: bit-reverse cycles for the ESP32's own FFT, ESP32<->FPGA round trip (us)
        # for FPGA commands; cpu_mhz: the clock the cycle counts are in
        # split: the time split, see esp32_split() / fpga_split()
        split = list(struct.unpack(f"<{n_split}I", self._read(4 * n_split))) if n_split else []
        meta = dict(status=status, log2n=log2n, fft_min=fmin, fft_avg=favg,
                    bitrev=extra, cpu_mhz=mhz, split=split)
        n_bytes = 4 * (1 << log2n) if has_payload else 0
        payload = self._read(n_bytes) if n_bytes else b""
        (cks,) = struct.unpack("<H", self._read(2))
        if cks != (sum(payload) & 0xFFFF):
            raise IOError("reply checksum mismatch: transport error")
        return meta, payload

    def _read(self, n: int) -> bytes:
        buf = self.ser.read(n)
        if len(buf) != n:
            raise TimeoutError(f"short read: {len(buf)} of {n} bytes")
        return buf

    def ping(self) -> dict:
        return self._request(b"P", 0)[0]

    def fft(self, sig: fm.Signal, cmd: bytes = b"L") -> tuple[np.ndarray, np.ndarray, dict]:
        n = len(sig.re)
        meta, payload = self._request(cmd, n.bit_length() - 1, fm.pack(sig.re, sig.im))
        if meta["status"] != 0:
            raise RuntimeError(f"device says: {STATUS.get(meta['status'], meta['status'])}")
        r, i = fm.unpack(payload)
        return r, i, meta


def find_port(patterns: tuple[str, ...]) -> str:
    for p in patterns:
        hits = sorted(glob.glob(p))
        if hits:
            return hits[0]
    sys.exit(f"no port matching {patterns}")


def esp32_split(meta: dict) -> dict:
    """ESP32 time split, in CPU cycles: copy -> FFT -> bit-reverse (fastest of 20 each),
    plus the fastest whole run as a cross-check on the sum of the steps."""
    copy, run = meta["split"]
    return dict(copy=copy, fft=meta["fft_min"], bitrev=meta["bitrev"], whole_run=run)


def fpga_split(meta: dict) -> dict:
    """FPGA time split, in 27 MHz cycles, from the core's phase-signal stamps.

    Stamp = cycle counter value in the first clock a signal is high; the counter is 0
    in the clock where 'start' is high, and 'cycles' = last-result clock + 1:
        setup   start .. the clock before sod          = sod
        load    sod .. eod (one sample per clock)       = eod - sod + 1
        compute after eod .. the clock before soud      = soud - eod - 1
        unload  soud .. eoud (one result per clock)     = cycles - soud
    The four add up to 'cycles' exactly. busy rise/fall show where, inside the
    compute phase, the core says it is calculating.
    """
    sod, eod, brise, bfall, soud = meta["split"]
    total = meta["fft_min"]
    return dict(setup=sod, load=eod - sod + 1, compute=soud - eod - 1, unload=total - soud,
                total=total, busy_rise=brise, busy_fall=bfall, busy=bfall - brise)


IMPLS = {"simd": (b"L", "dsps_fft2r_sc16 (S3 SIMD)"), "ansi": (b"A", "dsps_fft2r_sc16_ansi (plain C)")}


def esp32(port: str | None, baud: int, sizes: list[int], impl: str = "simd") -> bool:
    port = port or find_port(("/dev/cu.wchusbserial*",))
    dev = Device(port, baud)
    info = dev.ping()
    if info["status"] != 0:
        sys.exit(f"ESP32 not ready: {STATUS.get(info['status'])}")
    cmd, label = IMPLS[impl]
    print(f"ESP32-S3 on {port}: ESP-DSP {label}, CPU {info['cpu_mhz']} MHz, "
          f"max N {1 << info['log2n']}")

    DATA.mkdir(parents=True, exist_ok=True)
    rows, all_ok = [], True
    for n in sizes:
        floor = fm.noise_floor(n)
        print(f"\nN = {n}   (best possible 16-bit design: {floor:.3f} LSB rms on noise)")
        print(f"  {'signal':<14}{'verdict':>9}{'rms err':>9}{'max err':>9}"
              f"{'peaks':>7}{'vs best':>9}")
        timing = None
        for s in fm.make_signals(n) + [fm.overload_signal(n)]:
            r, i, meta = dev.fft(s, cmd)
            timing = meta
            sc = fm.score(r, i, s)
            scored = s.name != "overload"
            ok = fm.is_correct(sc)
            if scored:
                all_ok &= ok
            verdict = ("CORRECT" if ok else "WRONG") if scored else "(info)"
            pk = "-" if sc.peaks_ok is None else ("ok" if sc.peaks_ok else "WRONG")
            # "vs best" only where every butterfly rounds; elsewhere the model is exact by luck
            vs = (f"{fm.db_above_ideal(sc, floor):+8.1f}dB"
                  if s.name in ("noise", "tone_off_bin") else "")
            print(f"  {s.name:<14}{verdict:>9}{sc.rms_err_lsb:9.3f}{sc.max_err_lsb:9.2f}"
                  f"{pk:>7}{vs:>9}")
            rows.append(dict(device=f"esp32s3-{impl}", n=n, signal=s.name, correct=ok if scored else "",
                             rms_err_lsb=round(sc.rms_err_lsb, 4),
                             max_err_lsb=round(sc.max_err_lsb, 3),
                             sqnr_db=round(sc.sqnr_db, 2), peaks_ok=sc.peaks_ok,
                             fft_cycles_min=meta["fft_min"], fft_cycles_avg=meta["fft_avg"],
                             bitrev_cycles=meta["bitrev"], copy_cycles=meta["split"][0],
                             whole_run_cycles=meta["split"][1], cpu_mhz=meta["cpu_mhz"]))
        mhz = timing["cpu_mhz"]
        sp = esp32_split(timing)
        steps = sp["copy"] + sp["fft"] + sp["bitrev"]
        print(f"  time split (fastest of 20 runs, {mhz} MHz):")
        for name, c in (("1 copy input", sp["copy"]), ("2 FFT", sp["fft"]),
                        ("3 bit-reverse", sp["bitrev"])):
            print(f"    {name:<16}{c:>9} cycles {c / mhz:9.1f} us  {100 * c / steps:5.1f} %")
        print(f"    {'sum of steps':<16}{steps:>9} cycles {steps / mhz:9.1f} us"
              f"   (whole run measured in one go: {sp['whole_run']} = {sp['whole_run'] / mhz:.1f} us)"
              f"   FFT avg {timing['fft_avg'] / mhz:.1f} us")

    out = DATA / f"e1-esp32-{impl}.csv"
    with out.open("w", newline="") as f:
        w = csv.DictWriter(f, fieldnames=rows[0].keys())
        w.writeheader()
        w.writerows(rows)
    print(f"\nH3 part 1 (ESP32 is a correct FFT): {'PASS' if all_ok else 'FAIL'}")
    print(f"saved {out.relative_to(ROOT)}")
    return all_ok


FPGA_N = 1024                                  # the core is generated for 1024 points


def fpga_echo(port: str | None, baud: int, repeats: int) -> bool:
    """F2: prove the Mac -> ESP32 -> FPGA -> ESP32 -> Mac path loses nothing.

    The FPGA (fpga_fft/src/top.v, echo build) stores the 4096-byte signal in block
    RAM and sends it back. Besides the real test signals, raw byte patterns cover
    every byte value and the FPGA's own sync bytes (A5 5A) inside the payload.
    """
    port = port or find_port(("/dev/cu.wchusbserial*",))
    dev = Device(port, baud)
    if dev.ping()["status"] != 0:
        sys.exit("ESP32 not ready")
    rng = np.random.default_rng(2)
    payloads = [(s.name, fm.pack(s.re, s.im))
                for s in fm.make_signals(FPGA_N) + [fm.overload_signal(FPGA_N)]]
    payloads += [("random bytes", rng.integers(0, 256, 4 * FPGA_N, dtype=np.uint8).tobytes()),
                 ("sync bytes A5 5A", bytes([0xA5, 0x5A]) * (2 * FPGA_N)),
                 ("all 0x00", bytes(4 * FPGA_N)),
                 ("all 0xFF", bytes([0xFF]) * (4 * FPGA_N))]
    wire_us = (3 + 4 * FPGA_N + 9 + 4 * FPGA_N + 2) * 10   # 10 bits per byte at 1 Mbaud
    print(f"FPGA echo via ESP32 on {port}: {len(payloads)} payloads x {repeats}, "
          f"{4 * FPGA_N} bytes each way, 1 Mbaud (wire time {wire_us / 1000:.1f} ms per frame)")
    print(f"  {'payload':<18}{'frames ok':>11}{'byte errors':>13}{'round trip':>12}")

    rows, frames, good = [], 0, 0
    for name, data in payloads:
        ok_n, errs, trips = 0, 0, []
        for k in range(repeats):
            meta, back = dev._request(b"E", FPGA_N.bit_length() - 1, data)
            st = meta["status"]
            diff = (sum(a != b for a, b in zip(back, data)) + abs(len(back) - len(data))
                    if st == 0 else len(data))
            ok = st == 0 and diff == 0
            ok_n += ok
            errs += diff
            if st == 0:
                trips.append(meta["bitrev"])
            elif k == 0 or not ok:
                print(f"    {name}: frame {k}: {STATUS.get(st, st)}")
            rows.append(dict(payload=name, frame=k, status=st, byte_errors=diff,
                             round_trip_us=meta["bitrev"] if st == 0 else ""))
        frames += repeats
        good += ok_n
        rt = f"{np.mean(trips) / 1000:.1f} ms" if trips else "-"
        print(f"  {name:<18}{f'{ok_n}/{repeats}':>11}{errs:>13}{rt:>12}")

    DATA.mkdir(parents=True, exist_ok=True)
    out = DATA / "f2-fpga-echo.csv"
    with out.open("w", newline="") as f:
        w = csv.DictWriter(f, fieldnames=rows[0].keys())
        w.writeheader()
        w.writerows(rows)
    passed = good == frames
    print(f"\nF2 echo: {good}/{frames} frames came back byte for byte -> "
          f"{'PASS' if passed else 'FAIL'}")
    print(f"saved {out.relative_to(ROOT)}")
    return passed


def fpga(port: str | None, baud: int) -> bool:
    """F3: the Gowin FFT core, judged exactly like the ESP32 (same signals, same gate)."""
    port = port or find_port(("/dev/cu.wchusbserial*",))
    dev = Device(port, baud)
    if dev.ping()["status"] != 0:
        sys.exit("ESP32 not ready")
    n = FPGA_N
    floor = fm.noise_floor(n)
    print(f"Gowin FFT IP on the Tang Nano 20K (via ESP32 on {port}), N = {n}")
    print(f"  (best possible 16-bit design: {floor:.3f} LSB rms on noise)")
    print(f"  {'signal':<14}{'verdict':>9}{'rms err':>9}{'max err':>9}"
          f"{'peaks':>7}{'vs best':>9}{'cycles':>8}")
    rows, all_ok, cycles = [], True, set()
    for s in fm.make_signals(n) + [fm.overload_signal(n)]:
        r, i, meta = dev.fft(s, b"F")
        sc = fm.score(r, i, s)
        scored = s.name != "overload"
        ok = fm.is_correct(sc)
        if scored:
            all_ok &= ok
        cycles.add(meta["fft_min"])
        verdict = ("CORRECT" if ok else "WRONG") if scored else "(info)"
        pk = "-" if sc.peaks_ok is None else ("ok" if sc.peaks_ok else "WRONG")
        vs = (f"{fm.db_above_ideal(sc, floor):+8.1f}dB"
              if s.name in ("noise", "tone_off_bin") else "")
        print(f"  {s.name:<14}{verdict:>9}{sc.rms_err_lsb:9.3f}{sc.max_err_lsb:9.2f}"
              f"{pk:>7}{vs:>9}{meta['fft_min']:8d}")
        rows.append(dict(device="gowin-fft-20k", n=n, signal=s.name, correct=ok if scored else "",
                         rms_err_lsb=round(sc.rms_err_lsb, 4),
                         max_err_lsb=round(sc.max_err_lsb, 3),
                         sqnr_db=round(sc.sqnr_db, 2), peaks_ok=sc.peaks_ok,
                         fft_cycles=meta["fft_min"], clk_mhz=meta["cpu_mhz"],
                         round_trip_us=meta["bitrev"],
                         **{f"{k}_cycles": v for k, v in fpga_split(meta).items()}))
    mhz = meta["cpu_mhz"]
    c = max(cycles)
    print(f"  time: {c} cycles at {mhz} MHz = {c / mhz:.1f} us, start to last result "
          f"(load + compute + unload, natural order)"
          + ("" if len(cycles) == 1 else f"; varied {min(cycles)}..{max(cycles)}"))
    sp = fpga_split(meta)
    print(f"  time split ({mhz} MHz, last signal):")
    for name, key in (("1 setup", "setup"), ("2 load samples", "load"),
                      ("3 compute", "compute"), ("4 unload results", "unload")):
        print(f"    {name:<18}{sp[key]:>7} cycles {sp[key] / mhz:8.1f} us  {100 * sp[key] / sp['total']:5.1f} %")
    print(f"    {'total':<18}{sp['total']:>7} cycles {sp['total'] / mhz:8.1f} us"
          f"   (core's busy signal: high for {sp['busy']} cycles, "
          f"from {sp['busy_rise']} to {sp['busy_fall']})")
    print(f"  ESP32 <-> FPGA round trip (UART, not the FFT): {meta['bitrev'] / 1000:.1f} ms")

    DATA.mkdir(parents=True, exist_ok=True)
    out = DATA / "f3-fpga-gowin.csv"
    with out.open("w", newline="") as f:
        w = csv.DictWriter(f, fieldnames=rows[0].keys())
        w.writeheader()
        w.writerows(rows)
    print(f"\nH1 (the Gowin core is a correct FFT): {'PASS' if all_ok else 'FAIL'}")
    print(f"saved {out.relative_to(ROOT)}")
    return all_ok


GOWIN_SIMLIB = Path("/Applications/GowinIDE.app/Contents/Resources/Gowin_EDA/IDE/simlib/gw2a/prim_sim.v")


def sim(compare_board: bool, port: str | None, baud: int) -> bool:
    """Run the Gowin core in Icarus Verilog (fpga_fft/sim/tb_fft.v) on every test signal.

    The encrypted fft_1024.v can't be read by a free simulator; the generator's
    gate-level model fft_1024.vo is unencrypted, and prim_sim.v describes each
    building block it uses. With --board, the same signals also go through the real
    FPGA and the two outputs are compared bin by bin, bit for bit.
    """
    import re
    import subprocess
    import tempfile
    tb = ROOT / "fpga_fft" / "sim" / "tb_fft.v"
    model = ROOT / "fpga_fft" / "src" / "fft" / "fft_1024.vo"
    work = Path(tempfile.mkdtemp(prefix="fft_sim_"))
    exe = work / "tb_fft"
    subprocess.run(["iverilog", "-g2012", "-s", "tb_fft", "-o", str(exe), str(tb), str(model),
                    str(GOWIN_SIMLIB)], check=True)
    dev = None
    if compare_board:
        dev = Device(port or find_port(("/dev/cu.wchusbserial*",)), baud)
        if dev.ping()["status"] != 0:
            sys.exit("ESP32 not ready")
    n = FPGA_N
    floor = fm.noise_floor(n)
    print(f"Gowin FFT core simulated in Icarus Verilog (gate-level model), N = {n}")
    print(f"  {'signal':<14}{'verdict':>9}{'rms err':>9}{'cycles':>8}{'sim time':>10}"
          + (f"{'same as board':>16}" if dev else ""))
    rows, all_ok, all_same = [], True, True
    for s in fm.make_signals(n) + [fm.overload_signal(n)]:
        fin, fout = work / "in.hex", work / "out.hex"
        fin.write_text("".join(f"{(int(i) & 0xFFFF) << 16 | (int(r) & 0xFFFF):08x}\n"
                               for r, i in zip(s.re, s.im)))
        t0 = time.time()
        res = subprocess.run(["vvp", str(exe), f"+in={fin}", f"+out={fout}"],
                             capture_output=True, text=True, check=True)
        dt = time.time() - t0
        st = dict((k, int(v)) for k, v in re.findall(r"(\w+)=(-?\d+)", res.stdout.split("STAMPS", 1)[1]))
        words = [int(ln, 16) for ln in fout.read_text().splitlines()   # skip "// 0x.." address lines
                 if ln.strip() and not ln.lstrip().startswith("//")]
        w = np.array(words, dtype=np.uint32)
        r = (w & 0xFFFF).astype(np.uint16).view(np.int16)
        i = (w >> 16).astype(np.uint16).view(np.int16)
        sc = fm.score(r, i, s)
        scored = s.name != "overload"
        ok = fm.is_correct(sc)
        if scored:
            all_ok &= ok
        verdict = ("CORRECT" if ok else "WRONG") if scored else "(info)"
        same = ""
        n_diff = None
        if dev:
            br, bi, _ = dev.fft(s, b"F")
            n_diff = int(np.sum((br != r) | (bi != i)))
            all_same &= n_diff == 0
            same = "yes, all 1024" if n_diff == 0 else f"NO: {n_diff} bins differ"
        print(f"  {s.name:<14}{verdict:>9}{sc.rms_err_lsb:9.3f}{st['total']:8d}{dt:9.1f}s"
              + (f"{same:>16}" if dev else ""))
        rows.append(dict(device="gowin-fft-sim-icarus", n=n, signal=s.name,
                         correct=ok if scored else "", rms_err_lsb=round(sc.rms_err_lsb, 4),
                         max_err_lsb=round(sc.max_err_lsb, 3), total_cycles=st["total"],
                         sod=st["sod"], eod=st["eod"], busy_rise=st["busy_rise"],
                         busy_fall=st["busy_fall"], soud=st["soud"], eoud=st["eoud"],
                         bins_differing_from_board="" if n_diff is None else n_diff))
    out = DATA / "f3-sim-gowin.csv"
    with out.open("w", newline="") as f:
        wr = csv.DictWriter(f, fieldnames=rows[0].keys())
        wr.writeheader()
        wr.writerows(rows)
    print(f"\nsimulation says the core is correct: {'PASS' if all_ok else 'FAIL'}")
    if dev:
        print(f"simulation matches the real FPGA bit for bit: {'YES' if all_same else 'NO'}")
    print(f"saved {out.relative_to(ROOT)}")
    return all_same if dev else True


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__,
                                 formatter_class=argparse.RawDescriptionHelpFormatter)
    sub = ap.add_subparsers(dest="cmd", required=True)
    sub.add_parser("selftest")
    m = sub.add_parser("model")
    m.add_argument("-n", type=int, nargs="+", default=[256, 512, 1024])
    e = sub.add_parser("esp32")
    e.add_argument("-n", type=int, nargs="+", default=[256, 512, 1024, 2048, 4096])
    e.add_argument("--port")
    e.add_argument("--baud", type=int, default=2_000_000)
    e.add_argument("--impl", choices=IMPLS, default="simd")
    sm = sub.add_parser("sim")
    sm.add_argument("--board", action="store_true", help="also compare with the real FPGA")
    sm.add_argument("--port")
    sm.add_argument("--baud", type=int, default=2_000_000)
    fp = sub.add_parser("fpga")
    fp.add_argument("--port")
    fp.add_argument("--baud", type=int, default=2_000_000)
    fe = sub.add_parser("fpga-echo")
    fe.add_argument("-r", "--repeats", type=int, default=10)
    fe.add_argument("--port")
    fe.add_argument("--baud", type=int, default=2_000_000)
    a = ap.parse_args()

    if a.cmd == "selftest":
        return 0 if selftest() else 1
    if a.cmd == "sim":
        return 0 if sim(a.board, a.port, a.baud) else 1
    if a.cmd == "fpga":
        return 0 if fpga(a.port, a.baud) else 1
    if a.cmd == "fpga-echo":
        return 0 if fpga_echo(a.port, a.baud, a.repeats) else 1
    if a.cmd == "esp32":
        return 0 if esp32(a.port, a.baud, a.n, a.impl) else 1
    model(a.n)
    return 0


if __name__ == "__main__":
    sys.exit(main())
