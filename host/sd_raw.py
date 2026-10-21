"""sd_raw.py — read the FPGA's raw-bits mode: what the INMP441's SD wire does, bit by bit.

In raw-bits mode (press S2 on the Tang Nano 20K, fpga_fft/src/top_mic_uart.v) every WS frame's
64 SD bits arrive as four 16-bit words, first bit in the MSB. Bit k is what the FPGA's I2S
receiver sees at bit_cnt k:

    bits  0-31  WS low  (left half)    the mic's 24-bit word should be bits  1-24 (L/R = GND)
    bits 32-63  WS high (right half)   a right-channel mic would put it at 33-56 (L/R = VDD)

The report says, for each half, whether it carries real sound, is stuck, or is just noise.

    python sd_raw.py [port] [--seconds 2]        live, through the ESP32 bridge
    python sd_raw.py --file bytes.txt            a capture from tb_mic_uart.v (one hex byte per line)
"""
from __future__ import annotations

import argparse
import sys
import time

import numpy as np

SYNC = b"\xAA\x55\xA5\x5A"
FRAME_BYTES = 1038


def frames_from_bytes(data: bytes) -> tuple[list[np.ndarray], int, int]:
    """64-bit WS frames from every intact raw-mode UART frame; also counts of skipped frames."""
    out, other, bad = [], 0, 0
    i = data.find(SYNC)
    while i >= 0 and i + FRAME_BYTES <= len(data):
        h = data[i + 4:i + 10]
        cfg = int.from_bytes(h[4:6], "little")
        pay = data[i + 12:i + 1036]
        good = (int.from_bytes(data[i + 10:i + 12], "little") == sum(h) & 0xFFFF
                and int.from_bytes(data[i + 1036:i + 1038], "little") == sum(pay) & 0xFFFF)
        if not good:
            bad += 1
        elif (cfg >> 8) & 3 != 2:
            other += 1
        else:
            words = np.frombuffer(pay, "<u2").reshape(-1, 4)       # 128 WS frames x 4 words
            bits = (words[:, :, None] >> np.arange(15, -1, -1)) & 1
            out.append(bits.reshape(-1, 64).astype(np.uint8))
        i = data.find(SYNC, i + FRAME_BYTES)
    return out, other, bad


def word24(bits: np.ndarray, first: int) -> np.ndarray:
    v = np.zeros(len(bits), dtype=np.int64)
    for k in range(24):
        v = (v << 1) | bits[:, first + k]
    return np.where(v >= 1 << 23, v - (1 << 24), v)


def describe(name: str, w: np.ndarray, ones_half: float) -> str:
    zero = np.mean(w == 0)
    ones = np.mean(w == -1)
    corr = float(np.corrcoef(w[:-1], w[1:])[0, 1]) if w.std() > 0 else float("nan")
    if ones_half < 0.002:
        verdict = "silent: SD never goes high here"
    elif zero > 0.95:
        verdict = "almost always 0: nobody is driving SD here (stray pulses only)"
    elif ones > 0.95:
        verdict = "stuck high"
    elif corr > 0.5:
        verdict = "REAL SOUND: smooth, neighbouring samples agree"
    else:
        verdict = "busy but not sound: scrambled bits"
    return (f"  {name}: ones {100 * ones_half:5.1f}%  word==0 {100 * zero:5.1f}%  "
            f"rms {w.std() / 256:9.1f} (16-bit units)  neighbour corr {corr:5.2f}\n"
            f"      -> {verdict}")


def report(frames: list[np.ndarray], other: int, bad: int) -> None:
    if not frames:
        print(f"no raw-mode frames ({other} normal frames, {bad} damaged): press S2 on the board")
        return
    b = np.concatenate(frames)
    print(f"{len(b)} WS frames ({len(frames)} UART frames; skipped {other} normal, {bad} damaged)")
    p = b.mean(axis=0)
    digits = "".join(" " if x == 0 else "." if x < 0.05 else str(min(9, int(x * 10))) for x in p)
    print("\nhow often each bit is 1 (blank = never, . = <5%, 1-9 = 10-90%)")
    print("  bit  0         1         2         3         4         5         6   ")
    print("       0123456789012345678901234567890123456789012345678901234567890123")
    print(f"       {digits}")
    print("       |--- WS low: left half ------------|--- WS high: right half -----|")
    print("\nfirst WS frames (left | right):")
    for row in b[:6]:
        s = "".join(map(str, row))
        print(f"  {s[:32]} | {s[32:]}")
    print()
    print(describe("left half,  bits  1-24", word24(b, 1), p[:32].mean()))
    print(describe("right half, bits 33-56", word24(b, 33), p[32:].mean()))


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("port", nargs="?", default="/dev/cu.wchusbserial54E20114571")
    ap.add_argument("--seconds", type=float, default=2.0)
    ap.add_argument("--baud", type=int, default=2_000_000)
    ap.add_argument("--file", help="read a tb_mic_uart.v capture instead of the serial port")
    a = ap.parse_args()
    if a.file:
        data = bytes(int(l, 16) for l in open(a.file) if l.strip())
    else:
        import serial
        with serial.Serial(a.port, a.baud, timeout=0.5) as s:
            s.reset_input_buffer()
            t_end, chunks = time.time() + a.seconds, []
            while time.time() < t_end:
                chunks.append(s.read(65536))
        data = b"".join(chunks)
    report(*frames_from_bytes(data))
    return 0


if __name__ == "__main__":
    sys.exit(main())
