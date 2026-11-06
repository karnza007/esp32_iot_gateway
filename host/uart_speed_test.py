"""uart_speed_test.py — how fast can the Tang Nano 20K's USB serial port (BL616) carry data?

    python host/uart_speed_test.py [port] [--bytes N] [--bauds 1000000,2000000,3000000]

Needs fpga_fft/src/top_uart_echo.v in the FPGA (pin 70 wired back to pin 69). For each baud rate
it sends N random bytes while reading the echo at the same time, then compares byte for byte:
  - bytes back / bytes sent (lost bytes),
  - wrong bytes (first mismatch position after aligning),
  - throughput (bytes per second, measured from first byte sent to last byte received).
An audio stream needs about 1.05 Mbit/s of UART data at 48,340 Hz (with packet overhead) or
0.52 Mbit/s at 24,170 Hz.
"""
import argparse
import glob
import os
import threading
import time

import serial

ap = argparse.ArgumentParser()
ap.add_argument("port", nargs="?", default=None)
ap.add_argument("--bytes", type=int, default=1_000_000)
ap.add_argument("--bauds", default="1000000,2000000,3000000")
a = ap.parse_args()
port = a.port or sorted(glob.glob("/dev/cu.usbserial-*1"))[-1]     # the BL616's 2nd channel = UART
print(f"port {port}, {a.bytes:,} bytes per test")

for baud in [int(b) for b in a.bauds.split(",")]:
    data = os.urandom(a.bytes)
    got = bytearray()
    with serial.Serial(port, baud, timeout=0.2) as s:
        s.reset_input_buffer()
        time.sleep(0.1)
        s.reset_input_buffer()
        done = threading.Event()

        def reader():
            idle = 0
            while idle < 10:                         # stop after 2 s with nothing coming back
                chunk = s.read(65536)
                if chunk:
                    got.extend(chunk)
                    idle = 0
                elif done.is_set():
                    idle += 1

        t = threading.Thread(target=reader)
        t0 = time.time()
        t.start()
        for i in range(0, len(data), 4096):
            s.write(data[i:i + 4096])
        s.flush()
        t_sent = time.time()
        done.set()
        t.join()
    n = len(got)
    # wrong bytes: compare in order up to the shorter length
    m = min(n, len(data))
    wrong = sum(1 for x, y in zip(got[:m], data[:m]) if x != y)
    first_bad = next((i for i, (x, y) in enumerate(zip(got[:m], data[:m])) if x != y), None)
    rate = a.bytes / (t_sent - t0)
    ideal = baud / 10
    print(f"  {baud:>9,} baud: back {n:,} / {len(data):,} ({len(data) - n:+,} lost), "
          f"wrong {wrong:,} (first at {first_bad}), send rate {rate / 1000:,.0f} KB/s "
          f"(line max {ideal / 1000:,.0f} KB/s)")
