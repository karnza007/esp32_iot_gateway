#!/usr/bin/env python3
"""Measure link 2's real capacity: how many bytes per second actually reach the host.

    .venv/bin/python tools/measure_link2.py --port /dev/cu.usbmodem11301 --seconds 10
    .venv/bin/python tools/measure_link2.py --port /dev/cu.wchusbserial... --baud 2000000

Pairs with firmware/link2_blast. The ESP32 writes an incrementing byte as fast as
the chosen link accepts; this reads for a fixed time and reports the rate.

WHY THE HOST TIMES IT, NOT THE DEVICE
    The obvious approach -- and the one in most published serial speed tests -- is to
    time N writes on the microcontroller with micros() and a flush(). That measures
    how fast the DEVICE's own buffer drains, which for a short burst is partly just
    the buffer absorbing it. It also cannot tell whether the data arrived.

    Here the host is the clock and the witness. It counts what it actually received
    over a wall-clock interval, and because the payload is a counting sequence it
    also verifies nothing went missing. Speed without integrity is not a measurement:
    this project has already recorded a link carrying its full rated byte rate while
    delivering zero usable frames.
"""
import argparse
import sys
import time

import serial


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__,
                                 formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--port", required=True)
    ap.add_argument("--baud", type=int, default=2_000_000,
                    help="ignored by USB CDC, which has no baud rate")
    ap.add_argument("--seconds", type=float, default=10.0)
    ap.add_argument("--label", default="")
    a = ap.parse_args()

    ser = serial.Serial(a.port, a.baud, timeout=0.2)
    time.sleep(0.3)
    ser.reset_input_buffer()

    MOD = 251         # prime, so a loss is invisible only if it is a multiple of
                      # 251 -- and no serial buffer is. A mod-256 counter would be
                      # blind to exactly the 256/512/1024-byte losses we are hunting.
    total = 0
    gaps = 0          # discontinuities in the counting sequence = loss
    lost = 0          # bytes implied missing by those discontinuities
    prev = None
    t0 = time.monotonic()
    # discard the first read: it may straddle the buffer flush above
    ser.read(4096)
    t0 = time.monotonic()

    while time.monotonic() - t0 < a.seconds:
        d = ser.read(65536)
        if not d:
            continue
        total += len(d)
        if prev is not None and d[0] != (prev + 1) % MOD:
            gaps += 1
            lost += (d[0] - prev - 1) % MOD
        for i in range(1, len(d)):
            if d[i] != (d[i - 1] + 1) % MOD:
                gaps += 1
                lost += (d[i] - d[i - 1] - 1) % MOD
        prev = d[-1]
    elapsed = time.monotonic() - t0
    ser.close()

    rate = total / elapsed
    name = a.label or a.port
    print(f"  {name}")
    print(f"    received      {total:,} bytes in {elapsed:.1f} s")
    print(f"    throughput    {rate:,.0f} B/s   ({rate*8/1e6:.2f} Mbit/s of payload)")
    if a.baud and "usbmodem" not in a.port:
        print(f"    nominal       {a.baud//10:,} B/s at {a.baud:,} baud "
              f"->  {100*rate/(a.baud/10):.1f} % achieved")
    pct = 100.0 * lost / (total + lost) if total else 0.0
    if total == 0:
        verdict = "NO DATA - the link carried nothing"
    elif gaps == 0:
        verdict = "LOSSLESS"
    elif pct > 50:
        verdict = f"GARBAGE  {pct:.2f} % - bytes arrive but do not follow the pattern"
    else:
        verdict = f"LOSSY  {pct:.4f} %"
    print(f"    sequence      {gaps} discontinuit{'y' if gaps == 1 else 'ies'}, "
          f"{lost:,} bytes implied lost   ->  {verdict}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
