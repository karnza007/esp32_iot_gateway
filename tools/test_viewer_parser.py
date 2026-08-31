#!/usr/bin/env python3
"""Offline test of the viewer's frame parser and link statistics.

Builds synthetic byte streams with known, deliberate faults and checks that the
analyser reports exactly those faults and no others. No hardware needed:

    .venv/bin/python tools/test_viewer_parser.py
"""
import io
import os
import sys
import threading
import time

sys.path.insert(0, os.path.join(os.path.dirname(__file__), "..", "host"))

import numpy as np
import inmp441_viewer as V

CFG = (1 << 8) | 25                      # 1 channel, BCLK_DIV = 25
SIG = (np.sin(2 * np.pi * np.arange(512) * 1000 / 15000) * 10000).astype("<i2")


def frame(seq, ovf, cfg=CFG, samples=SIG, corrupt=False, bad_header=False):
    """Build one v3 frame. `corrupt` breaks the payload, `bad_header` the header."""
    payload = np.asarray(samples, dtype="<i2").tobytes()
    ck = sum(payload) & 0xFFFF
    if corrupt:
        payload = bytes([payload[0] ^ 0xFF]) + payload[1:]
    hdr = (seq.to_bytes(2, "little") + ovf.to_bytes(2, "little")
           + cfg.to_bytes(2, "little"))
    hs = sum(hdr) & 0xFFFF
    if bad_header:
        hdr = bytes([hdr[0] ^ 0xFF]) + hdr[1:]        # hdrsum will not match
    return V.SYNC + hdr + hs.to_bytes(2, "little") + payload + ck.to_bytes(2, "little")


class FakeSerial:
    def __init__(self, data):
        self.b = io.BytesIO(data)

    def read(self, n=1):
        d = self.b.read(n)
        if not d:
            time.sleep(0.05)
        return d

    def close(self):
        pass


def run(stream, wait=0.8):
    """Feed a stream through a real FrameReader and return its session totals."""
    r = V.FrameReader.__new__(V.FrameReader)
    r._init_state(FakeSerial(stream + V.SYNC))        # trailing sync delimits the last frame
    r.start()
    r.wait_first(2.0)
    time.sleep(wait)
    r.stop()
    _, total = r.snapshot()
    return r, total


class Checker:
    def __init__(self):
        self.failures = 0

    def section(self, name):
        print(f"\n  --- {name} ---")

    def eq(self, name, got, want):
        ok = got == want
        self.failures += not ok
        print(f"  {'ok  ' if ok else 'FAIL'} {name:<16} got {got!r:<28} want {want!r}")


def main() -> int:
    c = Checker()

    # ---- 1: a mixed stream with several distinct, known faults ----------------
    c.section("mixed faults: loss, garbage, overflow, bad payload")
    stream = (frame(0, 0) + frame(1, 0)
              + b"\x00\xFF\x13"                     # 3 garbage bytes
              + frame(5, 0)                          # frames 2,3,4 never arrived
              + frame(6, 7)                          # FPGA reports 7 overflow bytes
              + frame(7, 7, corrupt=True)            # payload damaged
              + frame(8, 7))
    r, t = run(stream)
    c.eq("frames_ok", t.frames_ok, 5)
    c.eq("frames_lost", t.frames_lost, 3)
    c.eq("checksum_errors", t.checksum_errors, 1)
    c.eq("header_errors", t.header_errors, 0)
    c.eq("ovf_delta", t.ovf_delta, 7)
    c.eq("resync_events", t.resync_events, 1)
    c.eq("bytes_skipped", t.bytes_skipped, 3)
    c.eq("wire_bytes", t.wire_bytes, 5 * V.FRAME_BYTES)
    c.eq("sample_rate", V.sample_rate_from_cfg(r.cfg), 15000.0)
    c.eq("verdict", t.verdict(), "LINK SATURATED (FPGA FIFO)")

    # ---- 2: fully saturated link, not one intact frame ------------------------
    # The positive-control condition. The program must still start and report:
    # "no intact frames" is the measurement, not a failure to measure.
    c.section("saturated link: every payload corrupt")
    r, t = run(b"".join(frame(i, 100 * i, corrupt=True) for i in range(6)))
    c.eq("started", r.cfg is not None, True)
    c.eq("cfg recovered", r.cfg, CFG)
    c.eq("frames_ok", t.frames_ok, 0)
    c.eq("checksum_errors", t.checksum_errors, 6)
    c.eq("no audio", r.latest(), None)
    c.eq("ovf_total", t.ovf_total, 500)
    c.eq("verdict", t.verdict(), "LINK SATURATED (FPGA FIFO)")

    # ---- 3: frames arriving SHORT, as under real overflow ---------------------
    c.section("short frame: bytes dropped in flight")
    f = frame(0, 0)
    r, t = run(f[:600] + f[783:] + frame(1, 0))       # 183 bytes gone from frame 0
    c.eq("frames_short", t.frames_short, 1)
    c.eq("bytes_missing", t.bytes_missing, 183)
    c.eq("frames_ok", t.frames_ok, 1)
    c.eq("verdict", t.verdict(), "GATEWAY LOSS (ESP32/USB)")

    # ---- 4: a corrupted HEADER must be rejected, not believed -----------------
    # Measured on hardware 2026-08-31: a corrupt ovf field injected a phantom
    # 65,536-byte overflow and pointed the verdict at the wrong component.
    c.section("corrupted header: rejected, and not counted as loss")
    r, t = run(frame(0, 0) + frame(1, 40000, bad_header=True) + frame(2, 0))
    c.eq("header_errors", t.header_errors, 1)
    c.eq("frames_ok", t.frames_ok, 2)
    c.eq("ovf_total", t.ovf_total, 0)         # the phantom 40000 must NOT be believed
    c.eq("frames_lost", t.frames_lost, 0)     # it arrived; it is not "lost"
    c.eq("verdict", t.verdict(), "OK")

    print("\nPASS" if c.failures == 0 else f"\nFAIL ({c.failures})")
    return 0 if c.failures == 0 else 1


if __name__ == "__main__":
    raise SystemExit(main())
