"""Live viewer and link analyser for the INMP441 -> FPGA -> ESP32-S3 -> host chain.

Displays the latest audio frame as a waveform and a spectrum, and — the point of
this revision — measures how much data the link is losing and *where*.

FRAME FORMAT v2 (1036 bytes, must match fpga/src/framer.v)
    off  size  field
      0     4  sync      AA 55 A5 5A
      4     2  seq       uint16 LE, frame counter, wraps
      6     2  ovf       uint16 LE, cumulative FPGA FIFO overflow BYTES
      8     2  cfg       uint16 LE, [7:0]=BCLK_DIV, [9:8]=channels
     10  1024  payload   512 x int16 LE
   1034     2  checksum  uint16 LE, additive sum of the payload bytes

The sample rate is not hardcoded: it is derived from `cfg` as
    fs = 24 MHz / (64 * BCLK_DIV)
so a sweep point can be changed in the Verilog alone and this program follows.

HOW LOSS IS LOCALISED
    ovf > 0 and seq gaps   the FPGA FIFO overflowed -> the UART link is saturated
    ovf = 0 but seq gaps   the FPGA kept up -> the ESP32 or USB bridge dropped it
    no gaps, bad checksums signal-integrity problem, not a throughput problem
That distinction is the experimental result the project is built to produce.

Usage:
    python inmp441_viewer.py [serial_port] [--csv FILE] [--fft-ymax N] [--no-plot]
"""

from __future__ import annotations

import argparse
import csv
import glob
import sys
import threading
import time
from dataclasses import dataclass, field

import numpy as np
import serial

# ---------------------------------------------------------------- constants
BAUD = 921600                  # ESP32 UART0 -> CH9102 -> host
SYNC = b"\xAA\x55\xA5\x5A"
FRAME_SAMPLES = 512
HEADER_BYTES = 10              # sync(4) + seq(2) + ovf(2) + cfg(2)
PAYLOAD_BYTES = FRAME_SAMPLES * 2
TRAILER_BYTES = 2              # checksum
FRAME_BYTES = HEADER_BYTES + PAYLOAD_BYTES + TRAILER_BYTES   # 1036
BODY_BYTES = FRAME_BYTES - len(SYNC)                         # read after sync

FPGA_CLK_HZ = 24_000_000
BCLK_PER_FRAME = 64
FFT_YMAX_DEFAULT = 5000        # fixed magnitude axis; no auto-scaling


def autodetect_port() -> str | None:
    cands = sorted(glob.glob("/dev/cu.usbmodem*")) + sorted(glob.glob("/dev/cu.wchusbserial*"))
    return cands[0] if cands else None


def sample_rate_from_cfg(cfg: int) -> float:
    """fs = 24 MHz / (64 * BCLK_DIV). BCLK_DIV lives in cfg[7:0]."""
    bclk_div = cfg & 0xFF
    if bclk_div == 0:
        return float("nan")
    return FPGA_CLK_HZ / (BCLK_PER_FRAME * bclk_div)


def channels_from_cfg(cfg: int) -> int:
    return (cfg >> 8) & 0x3


# ---------------------------------------------------------------- statistics
@dataclass
class LinkStats:
    """Counters for one reporting interval, plus session totals."""

    frames_ok: int = 0
    frames_expected: int = 0        # ok + inferred-lost, from seq gaps
    frames_lost: int = 0
    checksum_errors: int = 0
    resyncs: int = 0
    payload_bytes: int = 0
    ovf_delta: int = 0
    ovf_total: int = 0
    t_start: float = field(default_factory=time.monotonic)

    def reset_interval(self) -> None:
        self.frames_ok = 0
        self.frames_expected = 0
        self.frames_lost = 0
        self.checksum_errors = 0
        self.resyncs = 0
        self.payload_bytes = 0
        self.ovf_delta = 0
        self.t_start = time.monotonic()

    @property
    def elapsed(self) -> float:
        return max(time.monotonic() - self.t_start, 1e-9)

    @property
    def drop_rate(self) -> float:
        return self.frames_lost / self.frames_expected if self.frames_expected else 0.0

    @property
    def throughput(self) -> float:
        return self.payload_bytes / self.elapsed

    def verdict(self) -> str:
        """Attribute the loss to a stage. This is the headline result."""
        if self.ovf_delta > 0:
            return "LINK SATURATED (FPGA FIFO)"
        if self.frames_lost > 0:
            return "GATEWAY LOSS (ESP32/USB)"
        if self.checksum_errors > 0:
            return "SIGNAL INTEGRITY"
        return "OK"


# ---------------------------------------------------------------- reader
class FrameReader:
    """Background thread: resynchronise, validate, publish the latest frame."""

    def __init__(self, port: str, baud: int = BAUD) -> None:
        self.ser = serial.Serial(port, baud, timeout=1)
        self._latest: np.ndarray | None = None
        self._cfg: int | None = None
        self._lock = threading.Lock()
        self._stop = threading.Event()
        self._first = threading.Event()
        self._thread = threading.Thread(target=self._run, daemon=True)

        self.stats = LinkStats()
        self.total = LinkStats()
        self._last_seq: int | None = None
        self._last_ovf: int | None = None

    # -- lifecycle ---------------------------------------------------------
    def start(self) -> None:
        self._thread.start()

    def stop(self) -> None:
        self._stop.set()
        try:
            self.ser.close()
        except Exception:
            pass

    def wait_first(self, timeout: float) -> bool:
        return self._first.wait(timeout)

    # -- accessors ---------------------------------------------------------
    def latest(self) -> np.ndarray | None:
        with self._lock:
            return self._latest

    @property
    def cfg(self) -> int | None:
        return self._cfg

    def snapshot(self) -> tuple[LinkStats, LinkStats]:
        """Return (interval, session) copies and start a fresh interval."""
        with self._lock:
            iv = LinkStats(**{k: getattr(self.stats, k) for k in
                              ("frames_ok", "frames_expected", "frames_lost",
                               "checksum_errors", "resyncs", "payload_bytes",
                               "ovf_delta", "ovf_total")})
            iv.t_start = self.stats.t_start
            self.stats.reset_interval()
            tot = LinkStats(**{k: getattr(self.total, k) for k in
                               ("frames_ok", "frames_expected", "frames_lost",
                                "checksum_errors", "resyncs", "payload_bytes",
                                "ovf_delta", "ovf_total")})
            tot.t_start = self.total.t_start
        return iv, tot

    # -- internals ---------------------------------------------------------
    def _resync(self) -> bool:
        """Byte-at-a-time scan until the 4-byte sync matches."""
        matched = 0
        while not self._stop.is_set():
            b = self.ser.read(1)
            if not b:
                continue
            if b[0] == SYNC[matched]:
                matched += 1
                if matched == len(SYNC):
                    return True
            else:
                matched = 1 if b[0] == SYNC[0] else 0
        return False

    def _account(self, seq: int, ovf: int, good: bool) -> None:
        """Update loss/integrity counters for one received frame."""
        with self._lock:
            for s in (self.stats, self.total):
                if good:
                    s.frames_ok += 1
                    s.payload_bytes += PAYLOAD_BYTES
                else:
                    s.checksum_errors += 1

            # frame loss, inferred from gaps in the sequence number
            if self._last_seq is not None:
                gap = (seq - self._last_seq - 1) & 0xFFFF
                # a huge "gap" means the counter wrapped past our visibility;
                # treat only plausible gaps as loss
                if 0 < gap < 30000:
                    for s in (self.stats, self.total):
                        s.frames_lost += gap
                        s.frames_expected += gap
            for s in (self.stats, self.total):
                s.frames_expected += 1
            self._last_seq = seq

            # FPGA-side overflow: sticky and monotonic, so we report the delta
            if self._last_ovf is not None:
                d = (ovf - self._last_ovf) & 0xFFFF
                if 0 < d < 30000:
                    for s in (self.stats, self.total):
                        s.ovf_delta += d
            self._last_ovf = ovf
            for s in (self.stats, self.total):
                s.ovf_total = ovf

    def _run(self) -> None:
        while not self._stop.is_set():
            try:
                if not self._resync():
                    return
                with self._lock:
                    self.stats.resyncs += 1
                    self.total.resyncs += 1

                body = self.ser.read(BODY_BYTES)
                if len(body) != BODY_BYTES:
                    continue

                seq = int.from_bytes(body[0:2], "little")
                ovf = int.from_bytes(body[2:4], "little")
                cfg = int.from_bytes(body[4:6], "little")
                payload = body[6:6 + PAYLOAD_BYTES]
                want = int.from_bytes(body[6 + PAYLOAD_BYTES:], "little")

                good = (sum(payload) & 0xFFFF) == want
                self._account(seq, ovf, good)

                if good:
                    samples = np.frombuffer(payload, dtype="<i2")
                    with self._lock:
                        self._latest = samples
                        self._cfg = cfg
                    self._first.set()

            except serial.SerialException as e:
                print(f"[reader] serial error: {e}", file=sys.stderr)
                return


# ---------------------------------------------------------------- reporting
CSV_FIELDS = ["t", "frames_ok", "frames_lost", "drop_rate", "ovf_delta",
              "ovf_total", "checksum_errors", "resyncs", "throughput_Bps", "verdict"]


def format_line(iv: LinkStats, fs: float) -> str:
    return (f"{iv.frames_ok:4d} ok  {iv.frames_lost:4d} lost "
            f"({100*iv.drop_rate:6.2f}%)  ovf {iv.ovf_delta:5d} "
            f"(tot {iv.ovf_total:5d})  cksum {iv.checksum_errors:3d}  "
            f"{iv.throughput/1000:7.2f} kB/s  [{iv.verdict()}]")


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__,
                                 formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("port", nargs="?", default=None,
                    help="serial port (default: first usbmodem/wchusbserial)")
    ap.add_argument("--csv", default=None,
                    help="append per-second statistics to this CSV file")
    ap.add_argument("--fft-ymax", type=float, default=FFT_YMAX_DEFAULT,
                    help=f"fixed FFT magnitude limit (default {FFT_YMAX_DEFAULT})")
    ap.add_argument("--no-plot", action="store_true",
                    help="statistics only, no window — for long unattended runs")
    ap.add_argument("--seconds", type=float, default=None,
                    help="with --no-plot, stop after this many seconds")
    args = ap.parse_args()

    port = args.port or autodetect_port()
    if not port:
        print("No serial port found. Pass one explicitly, e.g. /dev/cu.wchusbserial101",
              file=sys.stderr)
        return 1

    try:
        reader = FrameReader(port)
    except serial.SerialException as e:
        print(f"Could not open {port}: {e}", file=sys.stderr)
        return 1

    print(f"Reading {port} — waiting for the first valid frame…")
    reader.start()
    if not reader.wait_first(10.0):
        print("No valid frame in 10 s. Check wiring, the bitstream, and that the "
              "FPGA was re-synthesised after the last source change.", file=sys.stderr)
        reader.stop()
        return 1

    cfg = reader.cfg or 0
    fs = sample_rate_from_cfg(cfg)
    nch = channels_from_cfg(cfg)
    offered = fs * 2 * max(nch, 1)
    print(f"cfg=0x{cfg:04X}  BCLK_DIV={cfg & 0xFF}  channels={nch}  "
          f"fs={fs:.4f} Hz  offered payload={offered/1000:.2f} kB/s")

    csv_writer = None
    csv_file = None
    if args.csv:
        csv_file = open(args.csv, "a", newline="")
        csv_writer = csv.DictWriter(csv_file, fieldnames=CSV_FIELDS)
        if csv_file.tell() == 0:
            csv_writer.writeheader()
        print(f"logging statistics to {args.csv}")

    t0 = time.monotonic()

    def report() -> None:
        iv, _ = reader.snapshot()
        if iv.frames_expected == 0 and iv.frames_ok == 0:
            return
        print(format_line(iv, fs))
        if csv_writer:
            csv_writer.writerow({
                "t": round(time.monotonic() - t0, 3),
                "frames_ok": iv.frames_ok,
                "frames_lost": iv.frames_lost,
                "drop_rate": round(iv.drop_rate, 6),
                "ovf_delta": iv.ovf_delta,
                "ovf_total": iv.ovf_total,
                "checksum_errors": iv.checksum_errors,
                "resyncs": iv.resyncs,
                "throughput_Bps": round(iv.throughput, 1),
                "verdict": iv.verdict(),
            })
            csv_file.flush()

    # ---------------- headless mode ----------------
    if args.no_plot:
        try:
            while args.seconds is None or (time.monotonic() - t0) < args.seconds:
                time.sleep(1.0)
                report()
        except KeyboardInterrupt:
            pass
        finally:
            reader.stop()
            if csv_file:
                csv_file.close()
        return 0

    # ---------------- plotting mode ----------------
    import matplotlib.animation as animation
    import matplotlib.pyplot as plt

    t_axis = np.arange(FRAME_SAMPLES)
    freqs = np.fft.rfftfreq(FRAME_SAMPLES, d=1.0 / fs)
    window = np.hanning(FRAME_SAMPLES)
    window_gain = window.sum()

    fig, (ax_wave, ax_fft) = plt.subplots(2, 1, figsize=(10, 6.5))
    fig.canvas.manager.set_window_title(f"INMP441 live — fs {fs:.1f} Hz")

    (wave_line,) = ax_wave.plot(t_axis, np.zeros(FRAME_SAMPLES), lw=0.8)
    ax_wave.set_xlim(0, FRAME_SAMPLES - 1)
    ax_wave.set_ylim(-32768, 32767)          # fixed
    ax_wave.set_xlabel("Sample index")
    ax_wave.set_ylabel("Amplitude (int16)")
    ax_wave.set_title("Waveform")
    ax_wave.grid(True, alpha=0.3)

    status = ax_wave.text(0.01, 0.97, "", transform=ax_wave.transAxes,
                          va="top", ha="left", family="monospace", fontsize=8,
                          bbox=dict(boxstyle="round", fc="w", alpha=0.75))

    (fft_line,) = ax_fft.plot(freqs, np.zeros_like(freqs), lw=0.8)
    (peak_marker,) = ax_fft.plot([], [], "ro", ms=6)
    ax_fft.set_xlim(0, fs / 2)
    ax_fft.set_ylim(0, args.fft_ymax)        # fixed magnitude axis — no auto-adjust
    ax_fft.set_xlabel("Frequency (Hz)")
    ax_fft.set_ylabel("Magnitude")
    ax_fft.set_title("FFT — waiting for data…")
    ax_fft.grid(True, alpha=0.3)

    fig.tight_layout()

    last_report = [time.monotonic()]
    status_text = [""]

    def update(_i: int):
        samples = reader.latest()
        if samples is None or samples.size != FRAME_SAMPLES:
            return wave_line, fft_line, peak_marker, status

        wave_line.set_ydata(samples)

        windowed = samples.astype(np.float32) * window
        magnitude = np.abs(np.fft.rfft(windowed)) / window_gain
        fft_line.set_ydata(magnitude)

        if magnitude.size > 1:
            k = int(np.argmax(magnitude[1:]) + 1)
            peak_marker.set_data([float(freqs[k])], [float(magnitude[k])])
            ax_fft.set_title(f"FFT — peak {freqs[k]:.1f} Hz")

        now = time.monotonic()
        if now - last_report[0] >= 1.0:
            last_report[0] = now
            iv, tot = reader.snapshot()
            print(format_line(iv, fs))
            if csv_writer:
                csv_writer.writerow({
                    "t": round(now - t0, 3),
                    "frames_ok": iv.frames_ok,
                    "frames_lost": iv.frames_lost,
                    "drop_rate": round(iv.drop_rate, 6),
                    "ovf_delta": iv.ovf_delta,
                    "ovf_total": iv.ovf_total,
                    "checksum_errors": iv.checksum_errors,
                    "resyncs": iv.resyncs,
                    "throughput_Bps": round(iv.throughput, 1),
                    "verdict": iv.verdict(),
                })
                csv_file.flush()
            status_text[0] = (
                f"{iv.verdict()}\n"
                f"drop {100*iv.drop_rate:5.2f}%   ovf {iv.ovf_delta:d} "
                f"(tot {iv.ovf_total:d})\n"
                f"cksum err {iv.checksum_errors:d}   {iv.throughput/1000:.1f} kB/s "
                f"of {offered/1000:.1f}"
            )
        status.set_text(status_text[0])
        return wave_line, fft_line, peak_marker, status

    anim = animation.FuncAnimation(fig, update, interval=33, blit=False,
                                   cache_frame_data=False)
    try:
        plt.show()
    finally:
        reader.stop()
        if csv_file:
            csv_file.close()
    _ = anim
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
