#!/usr/bin/env python3
"""Raw serial probe — what is actually arriving on the port, before any parsing.

    .venv/bin/python tools/probe_port.py                    # auto-detect, 5 s
    .venv/bin/python tools/probe_port.py /dev/cu.wchusbserial... --seconds 5

Answers three questions in order, so a dead link and a mangled link stop looking
alike:

  1. Are ANY bytes arriving?        -> if not, the problem is link 2 / the ESP32
  2. At what rate?                  -> compare against the expected rate below
  3. Is the sync word AA 55 A5 5A in there, and how far apart are the copies?
"""
import argparse
import collections
import os
import sys
import time

sys.path.insert(0, os.path.join(os.path.dirname(__file__), "..", "host"))
import serial
import inmp441_viewer as V

EXPECTED = """  expected byte rates on this port (link 2, ESP32 -> host):
    FPGA at 2 Mbaud   (CLK_PER_BIT=12, FPGA_BAUD=2000000):  ~30,350 B/s, sync every 1036 B
    FPGA at 250 kbaud (CLK_PER_BIT=96, FPGA_BAUD=250000 ):  ~25,000 B/s, sync irregular
    a CLK_PER_BIT / FPGA_BAUD MISMATCH: any rate, but NO sync word ever found"""


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__,
                                 formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("port", nargs="?", default=None)
    ap.add_argument("--seconds", type=float, default=5.0)
    ap.add_argument("--baud", type=int, default=V.BAUD)
    a = ap.parse_args()

    port = a.port or V.autodetect_port()
    if not port:
        print("no serial port found", file=sys.stderr)
        return 1

    print(f"probing {port} @ {a.baud} baud for {a.seconds:.0f} s\n")
    ser = serial.Serial(port, a.baud, timeout=0.2)
    ser.reset_input_buffer()

    chunks = []
    t0 = time.monotonic()
    while time.monotonic() - t0 < a.seconds:
        d = ser.read(4096)
        if d:
            chunks.append(d)
    ser.close()

    data = b"".join(chunks)
    elapsed = time.monotonic() - t0
    rate = len(data) / elapsed

    print(f"  bytes received   {len(data):,} in {elapsed:.1f} s  ->  {rate:,.0f} B/s")

    if not data:
        print("\n  NOTHING IS ARRIVING.")
        print("  The FPGA is not the suspect here — this port only carries what the")
        print("  ESP32 chooses to send. Check, in this order:")
        print("    1. is the ESP32 sketch actually running? (it should send whatever it")
        print("       receives; if it received nothing it sends nothing)")
        print("    2. USB CDC On Boot = Disabled, so Serial is UART0 -> CH9102")
        print("    3. is this the ESP32's port?  candidates:", ", ".join(V.list_ports()))
        return 1

    # sync word search
    positions = []
    start = 0
    while True:
        i = data.find(V.SYNC, start)
        if i < 0:
            break
        positions.append(i)
        start = i + 1

    print(f"  sync words found {len(positions)}")

    if not positions:
        print("\n  BYTES ARE ARRIVING BUT THE SYNC WORD IS NEVER PRESENT.")
        print("  The wiring is fine — the bytes themselves are wrong. Almost always this")
        print("  is a baud mismatch on link 1: the FPGA's CLK_PER_BIT and the sketch's")
        print("  FPGA_BAUD disagree, so the ESP32 samples every bit at the wrong time.")
        print("  Requirement:  24,000,000 / CLK_PER_BIT  ==  FPGA_BAUD")
        print("  and the sketch must be UPLOADED, not merely edited.")
    else:
        gaps = [b - a_ for a_, b in zip(positions, positions[1:])]
        if gaps:
            common = collections.Counter(gaps).most_common(5)
            print(f"  gap between syncs: most common {common}")
            print(f"                     (a healthy v2 link gaps exactly {V.FRAME_BYTES})")
        first = positions[0]
        body = data[first + 4:first + V.FRAME_BYTES]
        if len(body) >= 6:
            seq = int.from_bytes(body[0:2], "little")
            ovf = int.from_bytes(body[2:4], "little")
            cfg = int.from_bytes(body[4:6], "little")
            print(f"\n  first frame header: seq={seq}  ovf={ovf}  "
                  f"cfg=0x{cfg:04X} (BCLK_DIV={cfg & 0xFF}, ch={(cfg >> 8) & 3}, "
                  f"plausible={V.plausible_cfg(cfg)})")

    print(f"\n  first 64 bytes: {data[:64].hex(' ')}")
    print()
    print(EXPECTED)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
