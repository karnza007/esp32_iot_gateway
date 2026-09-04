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

import numpy as np
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

    # 16-bit little-endian counter, two bytes per step. Sizes a loss exactly up
    # to 131,070 bytes, where the mod-251 byte counter could only give L mod 251 --
    # which is precisely the ambiguity that stops H-A and H-B being told apart.
    total = 0
    gaps = 0
    lost = 0
    sizes: list[int] = []
    prev = None
    buf = b""

    # ESTABLISH BYTE ALIGNMENT FIRST.
    #
    # The stream is 16-bit values with no framing, so the reader has to know which
    # byte starts a value. Reading one byte late turns 0,1,2,3... into 256,512,768...
    # -- every step then looks like a 510-byte loss, and the run reports 99.6 %
    # "garbage" that is entirely a parsing fault. That happened on the first attempt.
    #
    # Both phases are tried on a sample and the one that actually counts is kept.
    ser.read(65536)                      # discard whatever straddles the flush
    probe = b""
    while len(probe) < 8192:
        d = ser.read(8192 - len(probe))
        if d:
            probe += d
    def score(off: int) -> int:
        v = np.frombuffer(probe[off:off + ((len(probe) - off) & ~1)], dtype="<u2")
        st = (v[1:].astype(np.int32) - v[:-1].astype(np.int32)) & 0xFFFF
        return int(np.count_nonzero(st == 1))
    phase = 0 if score(0) >= score(1) else 1
    if phase:
        ser.read(1)                      # slip one byte to line up

    t0 = time.monotonic()
    while time.monotonic() - t0 < a.seconds:
        d = ser.read(65536)
        if not d:
            continue
        total += len(d)
        buf += d
        n = len(buf) & ~1
        vals = np.frombuffer(buf[:n], dtype="<u2")
        buf = buf[n:]
        if prev is not None and vals.size:
            step = int((int(vals[0]) - prev) & 0xFFFF)
            if step != 1:
                gaps += 1
                sizes.append((step - 1) * 2)
                lost += (step - 1) * 2
        if vals.size > 1:
            steps = (vals[1:].astype(np.int32) - vals[:-1].astype(np.int32)) & 0xFFFF
            bad = np.nonzero(steps != 1)[0]
            for k in bad:
                sz = (int(steps[k]) - 1) * 2
                gaps += 1
                sizes.append(sz)
                lost += sz
        if vals.size:
            prev = int(vals[-1])
    elapsed = time.monotonic() - t0
    ser.close()

    rate = total / elapsed
    name = a.label or a.port
    print(f"  {name}")
    print(f"    alignment     phase {phase} "
          f"(scores {score(0):,} vs {score(1):,} on an 8 KB probe)")
    print(f"    received      {total:,} bytes in {elapsed:.1f} s")
    print(f"    throughput    {rate:,.0f} B/s   ({rate*8/1e6:.2f} Mbit/s of payload)")
    if a.baud and "usbmodem" not in a.port:
        print(f"    nominal       {a.baud//10:,} B/s at {a.baud:,} baud "
              f"->  {100*rate/(a.baud/10):.1f} % achieved")
    pct = 100.0 * lost / (total + lost) if total else 0.0
    if sizes:
        sizes.sort()
        uniq = {}
        for z in sizes:
            uniq[z] = uniq.get(z, 0) + 1
        top = sorted(uniq.items(), key=lambda kv: -kv[1])[:6]
        mult64 = sum(1 for z in sizes if z % 64 == 0)
        print(f"    loss sizes    min {sizes[0]:,}  median {sizes[len(sizes)//2]:,}  "
              f"max {sizes[-1]:,} bytes")
        print(f"    most common   " + ", ".join(f"{z:,}x{c}" for z, c in top))
        print(f"    multiples of 64: {mult64} of {len(sizes)} "
              f"({100*mult64/len(sizes):.0f} %)   <- H-B predicts nearly all")
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
