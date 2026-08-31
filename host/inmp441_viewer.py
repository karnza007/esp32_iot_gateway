"""Live viewer and link analyser for the INMP441 -> FPGA -> ESP32-S3 -> host chain.

Displays the latest audio frame as a waveform and a spectrum, and — the point of
this revision — measures how much data the link is losing and *where*.

FRAME FORMAT v3 (1038 bytes, must match fpga/src/framer.v)
    off  size  field
      0     4  sync      AA 55 A5 5A
      4     2  seq       uint16 LE, frame counter, wraps
      6     2  ovf       uint16 LE, cumulative FPGA FIFO overflow BYTES
      8     2  cfg       uint16 LE, [7:0]=BCLK_DIV, [9:8]=channels
     10     2  hdrsum    uint16 LE, additive sum of bytes 4..9
     12  1024  payload   512 x int16 LE
   1036     2  checksum  uint16 LE, additive sum of the payload bytes

The header has its OWN checksum. The payload checksum does not cover it, because
under saturation the payload is routinely destroyed while the header survives --
and seq/ovf are most needed exactly then. Without hdrsum a corrupted header is
undetectable, and a corrupt ovf value injects phantom overflow.

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
import os
import sys
import threading
import time
from dataclasses import dataclass, field

import numpy as np
import serial

# ---------------------------------------------------------------- constants
BAUD = 2_000_000               # link 2: ESP32 UART0 -> CH9102 -> host.
                               # MUST match HOST_BAUD in the ESP32 sketch.
                               # Override per-run with --baud.
SYNC = b"\xAA\x55\xA5\x5A"
FRAME_SAMPLES = 512
HEADER_BYTES = 12              # sync(4) + seq(2) + ovf(2) + cfg(2) + hdrsum(2)
PAYLOAD_BYTES = FRAME_SAMPLES * 2
TRAILER_BYTES = 2              # checksum
FRAME_BYTES = HEADER_BYTES + PAYLOAD_BYTES + TRAILER_BYTES   # 1036
BODY_BYTES = FRAME_BYTES - len(SYNC)                         # read after sync

LINK1_BPS = 200_000            # FPGA -> ESP32 @ 2 Mbaud
LINK2_BPS = BAUD // 10         # ESP32 -> host, 8N1 = 10 bits per byte
FPGA_CLK_HZ = 24_000_000
BCLK_PER_FRAME = 64
FFT_YMAX_DEFAULT = 5000        # fixed magnitude axis; no auto-scaling


# Port-name families, most-likely-ESP32 first. The Tang Nano 4K's own FT2232
# debugger also enumerates as /dev/cu.usbserial-* (two of them: JTAG + UART), so
# that family is tried last and never silently preferred over a real gateway port.
PORT_GLOBS = ("/dev/cu.wchusbserial*", "/dev/cu.usbmodem*", "/dev/cu.usbserial*")


def list_ports() -> list[str]:
    seen: list[str] = []
    for pat in PORT_GLOBS:
        for p in sorted(glob.glob(pat)):
            if p not in seen:
                seen.append(p)
    return seen


def autodetect_port() -> str | None:
    cands = list_ports()
    if not cands:
        return None
    if len(cands) > 1:
        print(f"Multiple serial ports found: {', '.join(cands)}")
        print(f"Using {cands[0]}. Pass one explicitly if that is wrong.")
    return cands[0]


def sample_rate_from_cfg(cfg: int) -> float:
    """fs = 24 MHz / (64 * BCLK_DIV). BCLK_DIV lives in cfg[7:0]."""
    bclk_div = cfg & 0xFF
    if bclk_div == 0:
        return float("nan")
    return FPGA_CLK_HZ / (BCLK_PER_FRAME * bclk_div)


def channels_from_cfg(cfg: int) -> int:
    return (cfg >> 8) & 0x3


def interpolate_peak(mag, k: int) -> float:
    """Sub-bin peak position by parabolic interpolation on log magnitude.

    An FFT of 512 points at 46,875 Hz has bins 91.6 Hz apart, so a 440 Hz tone can
    only land on the 457.8 Hz bin — a 4 % error that is resolution, not a fault.
    Fitting a parabola through the peak bin and its two neighbours recovers the true
    frequency to a fraction of a bin, which matters because the SNR/THD work later
    needs the peak located accurately, not merely quantised.

    Returns a fractional bin index offset in [-0.5, +0.5].
    """
    if k <= 0 or k >= len(mag) - 1:
        return 0.0
    a, b, c = (float(np.log(max(mag[i], 1e-12))) for i in (k - 1, k, k + 1))
    denom = a - 2.0 * b + c
    if denom == 0.0:
        return 0.0
    return float(np.clip(0.5 * (a - c) / denom, -0.5, 0.5))


def plausible_cfg(cfg: int) -> bool:
    """Does this cfg word look like one our FPGA could have sent?

    Used to accept a header from a frame whose PAYLOAD failed its checksum. Under
    heavy saturation no frame arrives intact, so insisting on a perfect frame
    before starting would make the program refuse to run in exactly the condition
    it exists to measure.
    """
    bclk_div = cfg & 0xFF
    nch = (cfg >> 8) & 0x3
    reserved = cfg >> 10
    return 8 <= bclk_div <= 64 and 1 <= nch <= 2 and reserved == 0


# ---------------------------------------------------------------- statistics
@dataclass
class LinkStats:
    """Counters for one reporting interval, plus session totals."""

    frames_ok: int = 0
    frames_expected: int = 0        # ok + inferred-lost, from seq gaps
    frames_lost: int = 0
    checksum_errors: int = 0
    resync_events: int = 0          # times the stream had to be re-found
    bytes_skipped: int = 0          # garbage bytes discarded while re-finding it
    header_errors: int = 0          # frames whose HEADER failed its own checksum
    frames_short: int = 0           # frames that arrived with bytes missing
    bytes_missing: int = 0          # how many bytes those frames were missing
    payload_bytes: int = 0          # audio bytes delivered
    wire_bytes: int = 0             # payload + framing, i.e. what the link carried
    ovf_delta: int = 0
    ovf_total: int = 0
    t_start: float = field(default_factory=time.monotonic)

    def reset_interval(self) -> None:
        self.frames_ok = 0
        self.frames_expected = 0
        self.frames_lost = 0
        self.checksum_errors = 0
        self.resync_events = 0
        self.bytes_skipped = 0
        self.header_errors = 0
        self.frames_short = 0
        self.bytes_missing = 0
        self.payload_bytes = 0
        self.wire_bytes = 0
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
        """Audio bytes per second — the useful data actually delivered."""
        return self.payload_bytes / self.elapsed

    @property
    def wire_throughput(self) -> float:
        """Bytes per second on the wire, including sync/header/checksum.
        This is the number to compare against the link's 200 kB/s capacity."""
        return self.wire_bytes / self.elapsed

    def verdict(self) -> str:
        """Attribute the loss to a stage. This is the headline result."""
        # ONLY ovf proves the FPGA was the culprit: it is incremented inside the
        # FPGA. Short frames and missing frames prove bytes went astray SOMEWHERE
        # -- the ESP32 dropping bytes mid-frame also produces short frames at the
        # host -- so they must not be attributed to the FPGA on their own.
        if self.ovf_delta > 0:
            return "LINK SATURATED (FPGA FIFO)"
        if self.frames_lost > 0 or self.bytes_missing > 0:
            return "GATEWAY LOSS (ESP32/USB)"
        if self.checksum_errors > 0:
            return "SIGNAL INTEGRITY"
        return "OK"


# ---------------------------------------------------------------- reader
class FrameReader:
    """Background thread: resynchronise, validate, publish the latest frame."""

    def __init__(self, port: str, baud: int = BAUD) -> None:
        self._init_state(serial.Serial(port, baud, timeout=1))

    def _init_state(self, ser) -> None:
        """All mutable state, in one place.

        Kept separate from __init__ so tests can attach a fake serial object
        without opening a real port, and cannot drift out of sync with the
        constructor when a field is added.
        """
        self.ser = ser
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
        self._ovf_accum: int = 0        # our own total; the wire field wraps at 65536
        self._hdr_err_run: int = 0      # header-corrupt frames since the last good one
        self.frames_seen_any = 0        # sync matched + full body read, intact or not

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
                               "checksum_errors", "resync_events", "bytes_skipped",
                               "header_errors", "frames_short", "bytes_missing",
                               "payload_bytes", "wire_bytes", "ovf_delta", "ovf_total")})
            iv.t_start = self.stats.t_start
            self.stats.reset_interval()
            tot = LinkStats(**{k: getattr(self.total, k) for k in
                               ("frames_ok", "frames_expected", "frames_lost",
                                "checksum_errors", "resync_events", "bytes_skipped",
                                "header_errors", "frames_short", "bytes_missing",
                                "payload_bytes", "wire_bytes", "ovf_delta", "ovf_total")})
            tot.t_start = self.total.t_start
        return iv, tot

    # -- internals ---------------------------------------------------------
    def _account(self, seq: int, ovf: int, good: bool) -> None:
        """Update loss/integrity counters for one received frame."""
        with self._lock:
            for s in (self.stats, self.total):
                if good:
                    s.frames_ok += 1
                    s.payload_bytes += PAYLOAD_BYTES
                    s.wire_bytes += FRAME_BYTES
                else:
                    s.checksum_errors += 1

            # frame loss, inferred from gaps in the sequence number
            if self._last_seq is not None:
                gap = (seq - self._last_seq - 1) & 0xFFFF
                # Frames rejected for a bad header DID arrive; they are counted as
                # header_errors, not as loss. Discount them from the gap so the two
                # failure modes are not double-counted.
                gap = max(gap - self._hdr_err_run, 0)
                # a huge "gap" means the counter wrapped past our visibility;
                # treat only plausible gaps as loss
                if 0 < gap < 30000:
                    for s in (self.stats, self.total):
                        s.frames_lost += gap
                        s.frames_expected += gap
            for s in (self.stats, self.total):
                s.frames_expected += 1
            self._last_seq = seq
            self._hdr_err_run = 0

            # FPGA-side overflow. The wire field is free-running and wraps at
            # 65536, so the true total is rebuilt here by summing modulo-65536
            # differences between consecutive frames.
            if self._last_ovf is None:
                self._ovf_accum = ovf
                delta = ovf
            else:
                delta = (ovf - self._last_ovf) & 0xFFFF
                self._ovf_accum += delta
            self._last_ovf = ovf
            for s in (self.stats, self.total):
                s.ovf_delta += delta
                s.ovf_total = self._ovf_accum

    def _process(self, frame: bytes) -> None:
        """Handle one sync-delimited frame: everything from one sync word to the next.

        Its LENGTH is a measurement. A healthy frame is exactly FRAME_BYTES; a
        shorter one means the FPGA discarded that many payload bytes on its way
        out, which cross-checks directly against the `ovf` field in the header.
        """
        n = len(frame)
        if n < HEADER_BYTES:
            with self._lock:
                for st in (self.stats, self.total):
                    st.resync_events += 1
                    st.bytes_skipped += n
            return

        if n > FRAME_BYTES:
            # Longer than a frame: either junk between frames, or a sync word was
            # itself destroyed and two frames merged. Take the leading FRAME_BYTES
            # as the frame and charge the remainder to skipped bytes.
            extra = n - FRAME_BYTES
            with self._lock:
                for st in (self.stats, self.total):
                    st.resync_events += 1
                    st.bytes_skipped += extra
            frame = frame[:FRAME_BYTES]
            n = FRAME_BYTES

        seq = int.from_bytes(frame[4:6], "little")
        ovf = int.from_bytes(frame[6:8], "little")
        cfg = int.from_bytes(frame[8:10], "little")
        hdrsum = int.from_bytes(frame[10:12], "little")
        header_ok = (sum(frame[4:10]) & 0xFFFF) == hdrsum
        self.frames_seen_any += 1

        if not header_ok:
            # seq and ovf cannot be trusted. Using them would inject phantom frame
            # loss and phantom overflow, and misattribute the failure.
            with self._lock:
                self._hdr_err_run += 1
                for st in (self.stats, self.total):
                    st.header_errors += 1
                    if n < FRAME_BYTES:
                        st.frames_short += 1
                        st.bytes_missing += FRAME_BYTES - n
            return

        good = False
        if n == FRAME_BYTES:
            payload = frame[HEADER_BYTES:HEADER_BYTES + PAYLOAD_BYTES]
            want = int.from_bytes(frame[HEADER_BYTES + PAYLOAD_BYTES:], "little")
            good = (sum(payload) & 0xFFFF) == want
            if good:
                samples = np.frombuffer(payload, dtype="<i2")
                with self._lock:
                    self._latest = samples
                    self._cfg = cfg
                self._first.set()
        else:
            with self._lock:
                for st in (self.stats, self.total):
                    st.frames_short += 1
                    st.bytes_missing += max(FRAME_BYTES - n, 0)

        if self._cfg is None and plausible_cfg(cfg):
            # Saturated link: payloads are shredded but headers survive, because
            # framing bytes have reserved FIFO space. Start anyway — reporting the
            # loss IS the result.
            with self._lock:
                self._cfg = cfg
            self._first.set()

        self._account(seq, ovf, good)

    def _run(self) -> None:
        """Split the byte stream on sync words and hand each frame to _process.

        Deliberately NOT a fixed-length read after each sync. Under overload the
        FPGA drops payload bytes, so frames arrive SHORT; a fixed-length read would
        run past the next sync word, silently swallow a frame, and report the
        overrun as loss that never happened. Delimiting on the sync word instead
        makes the frame length itself a measurement.
        """
        buf = bytearray()
        while not self._stop.is_set():
            try:
                chunk = self.ser.read(4096)
            except (serial.SerialException, OSError) as e:
                if not self._stop.is_set():
                    print(f"[reader] serial error: {e}", file=sys.stderr)
                return
            if chunk:
                buf += chunk

            while True:
                i = buf.find(SYNC)
                if i < 0:
                    # keep a 3-byte tail: a sync word may straddle two reads
                    if len(buf) > 3:
                        drop = len(buf) - 3
                        with self._lock:
                            for st in (self.stats, self.total):
                                st.resync_events += 1
                                st.bytes_skipped += drop
                        del buf[:drop]
                    break
                if i > 0:                      # garbage before the sync word
                    with self._lock:
                        for st in (self.stats, self.total):
                            st.resync_events += 1
                            st.bytes_skipped += i
                    del buf[:i]
                j = buf.find(SYNC, len(SYNC))
                if j < 0:
                    break                      # frame not complete yet
                self._process(bytes(buf[:j]))
                del buf[:j]

# ---------------------------------------------------------------- reporting
CSV_FIELDS = ["t", "link2_baud", "bclk_div", "channels",
              "frames_ok", "frames_lost", "drop_rate", "ovf_delta", "ovf_total",
              "checksum_errors", "header_errors", "frames_short", "bytes_missing",
              "resync_events", "bytes_skipped", "payload_Bps", "wire_Bps", "verdict"]


def csv_row(iv: LinkStats, t: float, link2_baud: int = 0,
            bclk_div: int = 0, channels: int = 0) -> dict:
    return {
        "link2_baud": link2_baud,
        "bclk_div": bclk_div,
        "channels": channels,
        "t": round(t, 3),
        "frames_ok": iv.frames_ok,
        "frames_lost": iv.frames_lost,
        "drop_rate": round(iv.drop_rate, 6),
        "ovf_delta": iv.ovf_delta,
        "ovf_total": iv.ovf_total,
        "checksum_errors": iv.checksum_errors,
        "header_errors": iv.header_errors,
        "frames_short": iv.frames_short,
        "bytes_missing": iv.bytes_missing,
        "resync_events": iv.resync_events,
        "bytes_skipped": iv.bytes_skipped,
        "payload_Bps": round(iv.throughput, 1),
        "wire_Bps": round(iv.wire_throughput, 1),
        "verdict": iv.verdict(),
    }


def format_line(iv: LinkStats, fs: float) -> str:
    return (f"{iv.frames_ok:4d} ok  {iv.frames_lost:4d} lost "
            f"({100*iv.drop_rate:6.2f}%)  ovf {iv.ovf_delta:5d} "
            f"(tot {iv.ovf_total:5d})  cksum {iv.checksum_errors:3d}  "
            f"hdrerr {iv.header_errors:3d}  short {iv.frames_short:3d}({iv.bytes_missing:6d}B)  "
            f"wire {iv.wire_throughput/1000:7.2f} kB/s  [{iv.verdict()}]")


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__,
                                 formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("port", nargs="?", default=None,
                    help="serial port (default: first usbmodem/wchusbserial)")
    ap.add_argument("--csv", default=None,
                    help="append per-second statistics to this CSV file")
    ap.add_argument("--append", action="store_true",
                    help="append to an existing --csv instead of refusing")
    ap.add_argument("--baud", type=int, default=BAUD,
                    help=f"link 2 baud; must match HOST_BAUD in the sketch "
                         f"(default {BAUD})")
    ap.add_argument("--fft-ymax", type=float, default=FFT_YMAX_DEFAULT,
                    help=f"fixed FFT magnitude limit (default {FFT_YMAX_DEFAULT})")
    ap.add_argument("--no-plot", action="store_true",
                    help="statistics only, no window — for long unattended runs")
    ap.add_argument("--seconds", type=float, default=None,
                    help="with --no-plot, stop after this many seconds")
    args = ap.parse_args()

    port = args.port or autodetect_port()
    if not port:
        print("No serial port found. Is the ESP32-S3 plugged in?", file=sys.stderr)
        return 1

    try:
        reader = FrameReader(port, args.baud)
    except serial.SerialException as e:
        print(f"Could not open {port}: {e}", file=sys.stderr)
        return 1

    link2 = args.baud // 10
    print(f"Reading {port} @ {args.baud} baud (link 2 = {link2:,} B/s) — "
          "waiting for the first frame…")
    reader.start()
    if not reader.wait_first(10.0):
        if reader.frames_seen_any:
            print(f"Found {reader.frames_seen_any} frames on {port}, but none had a "
                  "readable header.\n"
                  "  Bytes are arriving, so the wiring is fine — they are being mangled.\n"
                  "  Most likely the FPGA's CLK_PER_BIT and the sketch's FPGA_BAUD "
                  "disagree.", file=sys.stderr)
        else:
            print(f"No frames at all in 10 s on {port}.\n"
                  f"  - is this the ESP32 port? others seen: {', '.join(list_ports())}\n"
                  "  - ESP32 sketch UPLOADED (not just edited), USB CDC On Boot = Disabled?\n"
                  "  - do fpga/src/top.v CLK_PER_BIT and the sketch's FPGA_BAUD match?\n"
                  "    (24 MHz / CLK_PER_BIT must equal FPGA_BAUD)\n"
                  "  - common ground between the two boards?\n"
                  "  - was the FPGA re-synthesised AND re-programmed after the last edit?",
                  file=sys.stderr)
        reader.stop()
        return 1

    cfg = reader.cfg or 0
    fs = sample_rate_from_cfg(cfg)
    nch = channels_from_cfg(cfg)
    offered = fs * 2 * max(nch, 1)
    frame_rate = fs / FRAME_SAMPLES
    print(f"cfg=0x{cfg:04X}  BCLK_DIV={cfg & 0xFF}  channels={nch}  fs={fs:.4f} Hz")
    print(f"FFT: {FRAME_SAMPLES}-point, bin spacing {fs/FRAME_SAMPLES:.2f} Hz "
          f"(a peak is interpolated between bins)")
    print(f"expect {frame_rate:.2f} frames/s  "
          f"payload {frame_rate*PAYLOAD_BYTES/1000:.2f} kB/s  "
          f"wire {frame_rate*FRAME_BYTES/1000:.2f} kB/s "
          f"({100*frame_rate*FRAME_BYTES/LINK1_BPS:.1f}% of link 1, "
          f"{100*frame_rate*FRAME_BYTES/link2:.1f}% of link 2)")

    csv_writer = None
    csv_file = None
    if args.csv:
        # Refuse to append silently. The viewer used to open in "a" mode, so
        # re-running a sweep point to the same file concatenated two runs into one
        # CSV -- which happened, and put a stale-bitstream run and a good run in the
        # same file. Every measurement must be one run, or the summary is a blend.
        if os.path.exists(args.csv) and os.path.getsize(args.csv) > 0 and not args.append:
            print(f"{args.csv} already exists. A sweep point must be one run.\n"
                  "  --append   add to it anyway\n"
                  "  or delete/rename it, or choose another name.", file=sys.stderr)
            reader.stop()
            return 1
        csv_file = open(args.csv, "a" if args.append else "w", newline="")
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
            csv_writer.writerow(csv_row(iv, time.monotonic() - t0,
                                        args.baud, cfg & 0xFF, nch))
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
    bin_hz = fs / FRAME_SAMPLES
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
        # Statistics first, and unconditionally: under saturation there may be no
        # intact audio to plot, and that is precisely when the numbers matter most.
        now = time.monotonic()
        if now - last_report[0] >= 1.0:
            last_report[0] = now
            iv, tot = reader.snapshot()
            print(format_line(iv, fs))
            if csv_writer:
                csv_writer.writerow(csv_row(iv, now - t0,
                                            args.baud, cfg & 0xFF, nch))
                csv_file.flush()
            status_text[0] = (
                f"{iv.verdict()}\n"
                f"drop {100*iv.drop_rate:5.2f}%   ovf {iv.ovf_delta:d} "
                f"(tot {iv.ovf_total:d})\n"
                f"cksum err {iv.checksum_errors:d}   "
                f"hdrerr {iv.header_errors:d}   "
                f"short {iv.frames_short:d} ({iv.bytes_missing:d} B)\n"
                f"wire {iv.wire_throughput/1000:.1f} kB/s "
                f"({100*iv.wire_throughput/link2:.0f}% of link 2)"
            )
        status.set_text(status_text[0])

        samples = reader.latest()
        if samples is None or samples.size != FRAME_SAMPLES:
            ax_fft.set_title("FFT — no intact frame (link saturated?)")
            return wave_line, fft_line, peak_marker, status

        wave_line.set_ydata(samples)
        windowed = samples.astype(np.float32) * window
        magnitude = np.abs(np.fft.rfft(windowed)) / window_gain
        fft_line.set_ydata(magnitude)
        if magnitude.size > 1:
            k = int(np.argmax(magnitude[1:]) + 1)
            delta = interpolate_peak(magnitude, k)
            f_true = (k + delta) * fs / FRAME_SAMPLES
            peak_marker.set_data([float(freqs[k])], [float(magnitude[k])])
            ax_fft.set_title(f"FFT — peak {f_true:.1f} Hz "
                             f"(bin {freqs[k]:.1f}, resolution {bin_hz:.1f} Hz)")
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
