"""play_song.py — play a song on the Tang Nano 20K's speaker through its own USB cable.

    python host/play_song.py song.(wav|mp3|...) [--port /dev/cu.usbserial-...1] [--volume -6]

Path: this script -> USB -> the board's BL616 debugger chip (its 2nd serial channel) -> FPGA pin 70
-> audio_rx.v -> i2s_tx.v -> MAX98357A -> speaker. Needs ffmpeg.

1. ffmpeg decodes the file to mono, 16-bit, 24,170 Hz (half the FPGA's output rate; the FPGA
   fills in every other sample), with --volume in dB; 0.2 s of silence is added at the end.
2. The port is opened at 3 Mbaud (the FPGA reads 2.97 Mbaud: 74.25 MHz / 25).
3. RESET (a packet with seq 255) empties the FPGA's buffer; the FPGA answers "R".
4. Packets of 32 samples (B5 6A | seq | 64 bytes | sum16) are sent only as credits allow:
   1,536 samples after RESET, 256 more per "C" from the FPGA. Writes are 8 packets (552 bytes) or
   more at a time: the BL616 needs writes of 512 bytes or more to reach its 170 KB/s (measured).
5. The FPGA's status ("S" + bad sums, seq gaps, dropped, underruns) is printed as it comes; the
   underrun count includes the song's own end.
"""
import argparse
import glob
import subprocess
import sys
import time

import numpy as np
import serial

FS = 24170
ap = argparse.ArgumentParser()
ap.add_argument("song")
ap.add_argument("--port", default=None)
ap.add_argument("--baud", type=int, default=3_000_000)
ap.add_argument("--volume", type=float, default=0.0, help="dB, applied by ffmpeg")
a = ap.parse_args()
port = a.port or sorted(glob.glob("/dev/cu.usbserial-*1"))[-1]

pcm = subprocess.run(["ffmpeg", "-v", "error", "-i", a.song, "-ac", "1", "-ar", str(FS),
                      "-af", f"volume={a.volume}dB", "-f", "s16le", "-"],
                     capture_output=True, check=True).stdout
x = np.frombuffer(pcm, dtype="<i2")
x = np.concatenate([x, np.zeros(int(0.2 * FS), dtype="<i2")])
x = np.concatenate([x, np.zeros((-len(x)) % 32, dtype="<i2")])          # whole packets
npk = len(x) // 32
print(f"{a.song}: {len(x) / FS:.1f} s, {npk} packets; port {port} at {a.baud:,} baud")


def packet(seq, samples):
    body = samples.astype("<i2").tobytes()
    s = sum(body) & 0xFFFF
    return bytes([0xB5, 0x6A, seq]) + body + bytes([s & 255, s >> 8])


status = [0, 0, 0, 0]
credit = 0
got_r = False
pending = bytearray()


def read_back(s):
    """Credits ("C"), the reset answer ("R") and status ("S" + 4 bytes) from the FPGA."""
    global credit, got_r
    pending.extend(s.read(s.in_waiting or 0))
    while pending:
        c = pending[0]
        if c == ord("C"):
            credit += 256
            del pending[0]
        elif c == ord("R"):
            got_r = True
            del pending[0]
        elif c == ord("S"):
            if len(pending) < 5:
                return
            status[:] = list(pending[1:5])
            del pending[:5]
        else:
            del pending[0]                                  # a damaged byte: skip it


with serial.Serial(port, a.baud, timeout=0) as s:
    s.reset_input_buffer()
    for attempt in range(5):
        s.write(packet(255, np.zeros(32, dtype="<i2")) * 8)  # RESET (8 copies make a 552-byte write)
        t0 = time.time()
        while not got_r and time.time() - t0 < 0.5:
            read_back(s)
            time.sleep(0.005)
        if got_r:
            break
    if not got_r:
        sys.exit("no answer from the FPGA (is the music build loaded, and the port right?)")
    time.sleep(0.05)
    read_back(s)
    credit = 1536
    t_start = time.time()
    sent = 0
    last_print = 0.0
    try:
        while sent < npk:
            read_back(s)
            n = min(credit // 32, npk - sent)
            if n >= 8 or (n > 0 and n == npk - sent):
                s.write(b"".join(packet(p % 255, x[32 * p:32 * p + 32]) for p in range(sent, sent + n)))
                sent += n
                credit -= 32 * n
            else:
                time.sleep(0.002)
            now = time.time() - t_start
            if now - last_print >= 1.0:
                last_print = now
                print(f"\r  {now:5.1f} s  sent {32 * sent / FS:5.1f} s of {len(x) / FS:.1f} s   "
                      f"FPGA: bad sums {status[0]}, seq gaps {status[1]}, dropped {status[2]}, "
                      f"underruns {status[3]}   ", end="", flush=True)
        # let the buffer play out (about 0.1 s) and collect the last status
        t_end = time.time() + 0.6
        while time.time() < t_end:
            read_back(s)
            time.sleep(0.01)
    except KeyboardInterrupt:
        print("\n  stopped; sending RESET")
        s.write(packet(255, np.zeros(32, dtype="<i2")) * 8)
print(f"\n  done in {time.time() - t_start:.1f} s. Last FPGA status: bad sums {status[0]}, "
      f"seq gaps {status[1]}, dropped {status[2]}, underruns {status[3]} "
      f"(sent every 16 credits, so the very end is not included)")
