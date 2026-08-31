#!/usr/bin/env python3
"""Read GWDIAG lines from the gateway and classify which link is failing.

    .venv/bin/python tools/read_diag.py --baud 2000000 --seconds 8 --expect-sync 29.3

The gateway is the only place that can tell the two links apart: it sees link 1's
data before link 2 touches it. A readable GWDIAG line is proof that link 2 works,
whatever link 1 is doing.

    lines readable, sync counting up  ->  BOTH OK
    lines readable, sync == 0         ->  LINK1 FAIL
    no lines at all                   ->  LINK2 FAIL
"""
import argparse
import os
import re
import sys
import time

sys.path.insert(0, os.path.join(os.path.dirname(__file__), "..", "host"))
import serial
import inmp441_viewer as V

LINE = re.compile(rb"GWDIAG hb=(\d+) rx=(\d+) sync=(\d+) rate=(\d+) "
                  rb"baud1=(\d+) baud2=(\d+)")


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__,
                                 formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--port", default=None)
    ap.add_argument("--baud", type=int, required=True)
    ap.add_argument("--seconds", type=float, default=8.0)
    ap.add_argument("--expect-sync", type=float, default=0.0,
                    help="expected sync words per second on link 1")
    ap.add_argument("--expect-baud1", type=int, default=0)
    a = ap.parse_args()

    port = a.port or V.autodetect_port()
    if not port:
        print("no port"); return 2

    ser = serial.Serial(port, a.baud, timeout=0.5)
    ser.reset_input_buffer()
    raw = b""
    t0 = time.monotonic()
    while time.monotonic() - t0 < a.seconds:
        d = ser.read(4096)
        if d:
            raw += d
    ser.close()

    hits = LINE.findall(raw)
    if not hits:
        print(f"  lines=0  raw={len(raw)}B  ->  LINK2 FAIL "
              f"(the gateway is unreachable at {a.baud} baud)")
        return 1

    first, last = hits[0], hits[-1]
    span = max(int(last[0]) - int(first[0]), 1) * 0.5      # hb ticks every 500 ms
    d_sync = int(last[2]) - int(first[2])
    d_rx = int(last[1]) - int(first[1])
    sync_rate = d_sync / span
    rx_rate = d_rx / span
    baud1, baud2 = int(last[4]), int(last[5])

    mismatch = ""
    if a.expect_baud1 and baud1 != a.expect_baud1:
        mismatch = f"  [!! gateway reports baud1={baud1}, expected {a.expect_baud1}]"

    ok = sync_rate > 0.5 * a.expect_sync if a.expect_sync else sync_rate > 0
    verdict = "BOTH OK" if ok else "LINK1 FAIL"
    print(f"  lines={len(hits)}  link1 {rx_rate:>8,.0f} B/s  sync {sync_rate:>6.1f}/s"
          f"  (expect {a.expect_sync:.1f}/s)  ->  {verdict}{mismatch}")
    return 0 if ok else 1


if __name__ == "__main__":
    raise SystemExit(main())
