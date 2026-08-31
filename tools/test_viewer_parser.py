#!/usr/bin/env python3
"""Offline test of the viewer's frame parser and link statistics.

Builds a synthetic byte stream with known, deliberate faults and checks that the
analyser reports exactly those faults. Runs without any hardware:

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


def frame(seq, ovf, cfg, samples, corrupt=False):
    payload = np.asarray(samples, dtype="<i2").tobytes()
    ck = sum(payload) & 0xFFFF
    if corrupt:
        payload = bytes([payload[0] ^ 0xFF]) + payload[1:]
    return (V.SYNC + seq.to_bytes(2, "little") + ovf.to_bytes(2, "little")
            + cfg.to_bytes(2, "little") + payload + ck.to_bytes(2, "little"))


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


def build_reader(stream):
    r = V.FrameReader.__new__(V.FrameReader)
    r.ser = FakeSerial(stream)
    r._latest = None
    r._cfg = None
    r._lock = threading.Lock()
    r._stop = threading.Event()
    r._first = threading.Event()
    r.stats = V.LinkStats()
    r.total = V.LinkStats()
    r._last_seq = None
    r._last_ovf = None
    r._thread = threading.Thread(target=r._run, daemon=True)
    return r


def main() -> int:
    CFG = (1 << 8) | 25                       # 1 channel, BCLK_DIV = 25
    sig = (np.sin(2 * np.pi * np.arange(512) * 1000 / 15000) * 10000).astype("<i2")

    stream = b""
    stream += frame(0, 0, CFG, sig)
    stream += frame(1, 0, CFG, sig)
    stream += b"\x00\xFF\x13"                 # 3 garbage bytes -> one resync event
    stream += frame(5, 0, CFG, sig)           # frames 2,3,4 lost
    stream += frame(6, 7, CFG, sig)           # FPGA reports 7 overflow bytes
    stream += frame(7, 7, CFG, sig, corrupt=True)   # checksum error
    stream += frame(8, 7, CFG, sig)

    r = build_reader(stream)
    r.start()
    r.wait_first(2.0)
    time.sleep(0.8)
    r.stop()
    _, tot = r.snapshot()

    fs = V.sample_rate_from_cfg(r.cfg)
    checks = [
        ("frames_ok",        tot.frames_ok,        5),
        ("frames_lost",      tot.frames_lost,      3),
        ("checksum_errors",  tot.checksum_errors,  1),
        ("ovf_delta",        tot.ovf_delta,        7),
        ("ovf_total",        tot.ovf_total,        7),
        ("resync_events",    tot.resync_events,    1),
        ("bytes_skipped",    tot.bytes_skipped,    3),
        ("wire_bytes",       tot.wire_bytes,       5 * V.FRAME_BYTES),
        ("payload_bytes",    tot.payload_bytes,    5 * V.PAYLOAD_BYTES),
        ("sample_rate",      fs,                   15000.0),
        ("channels",         V.channels_from_cfg(r.cfg), 1),
        ("verdict",          tot.verdict(),        "LINK SATURATED (FPGA FIFO)"),
    ]

    bad = 0
    for name, got, want in checks:
        ok = got == want
        bad += not ok
        print(f"  {'ok  ' if ok else 'FAIL'} {name:<16} got {got!r:<28} want {want!r}")

    lat = r.latest()
    print(f"  info latest frame     {lat.shape}, peak {int(np.abs(lat).max())}")
    print("\nPASS" if bad == 0 else f"\nFAIL ({bad})")
    return 0 if bad == 0 else 1


if __name__ == "__main__":
    raise SystemExit(main())
