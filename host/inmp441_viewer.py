"""Real-time viewer for INMP441 audio: INMP441 -> FPGA -> ESP32-S3 -> here.

Reads framed audio over USB-serial and displays:
  - Top:    raw waveform of the latest 512-sample frame
  - Bottom: FFT magnitude (Hann-windowed) with the peak frequency annotated

Frame protocol (matches the FPGA framer.v):
  4 bytes sync : 0xAA 0x55 0xA5 0x5A
  1024 bytes   : 512 x int16_t little-endian audio samples (top 16 of the 24-bit word)

Usage:
    python inmp441_viewer.py [serial_port]
If no port is given, the first /dev/cu.usbmodem* or /dev/cu.wchusbserial* is used.
"""

from __future__ import annotations

import argparse
import glob
import sys
import threading
import time

import matplotlib.animation as animation
import matplotlib.pyplot as plt
import numpy as np
import serial

BAUD = 921600                 # USB-CDC: rate is nominal (native USB ignores it)
SAMPLE_RATE = 15000           # FPGA WS = 24 MHz / 1600 = 15.000 kHz
FRAME_SAMPLES = 512
SYNC = b"\xAA\x55\xA5\x5A"
PAYLOAD_BYTES = FRAME_SAMPLES * 2  # int16
FFT_YMAX = 5000               # fixed FFT magnitude scale (no auto-adjust); tune to taste


def autodetect_port() -> str | None:
    cands = sorted(glob.glob("/dev/cu.usbmodem*")) + sorted(glob.glob("/dev/cu.wchusbserial*"))
    return cands[0] if cands else None


class FrameReader:
    """Background thread that reads framed audio and exposes the latest frame."""

    def __init__(self, port: str, baud: int = BAUD) -> None:
        self.ser = serial.Serial(port, baud, timeout=1)
        self._latest: np.ndarray | None = None
        self._lock = threading.Lock()
        self._stop = threading.Event()
        self._thread = threading.Thread(target=self._run, daemon=True)

    def start(self) -> None:
        self._thread.start()

    def stop(self) -> None:
        self._stop.set()
        try:
            self.ser.close()
        except Exception:
            pass

    def latest(self) -> np.ndarray | None:
        with self._lock:
            return self._latest

    def _resync(self) -> bool:
        """Read one byte at a time until we've matched the 4-byte SYNC."""
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

    def _run(self) -> None:
        while not self._stop.is_set():
            try:
                if not self._resync():
                    return
                payload = self.ser.read(PAYLOAD_BYTES)
                if len(payload) != PAYLOAD_BYTES:
                    continue
                samples = np.frombuffer(payload, dtype="<i2")
                with self._lock:
                    self._latest = samples
            except serial.SerialException as e:
                print(f"[reader] serial error: {e}", file=sys.stderr)
                return


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument("port", nargs="?", default=None,
                    help="Serial port (default: first usbmodem/wchusbserial)")
    args = ap.parse_args()

    port = args.port or autodetect_port()
    if not port:
        print("No serial port found. Pass one explicitly, e.g. /dev/cu.usbmodem101",
              file=sys.stderr)
        return 1

    try:
        reader = FrameReader(port)
    except serial.SerialException as e:
        print(f"Could not open {port}: {e}", file=sys.stderr)
        return 1
    print(f"Reading from {port} @ {SAMPLE_RATE} Hz")
    reader.start()

    t_axis = np.arange(FRAME_SAMPLES)
    freqs = np.fft.rfftfreq(FRAME_SAMPLES, d=1.0 / SAMPLE_RATE)
    window = np.hanning(FRAME_SAMPLES)
    window_gain = window.sum()

    fig, (ax_wave, ax_fft) = plt.subplots(2, 1, figsize=(10, 6))
    fig.canvas.manager.set_window_title("INMP441 Live Viewer (FPGA path)")

    (wave_line,) = ax_wave.plot(t_axis, np.zeros(FRAME_SAMPLES), lw=0.8)
    ax_wave.set_xlim(0, FRAME_SAMPLES - 1)
    ax_wave.set_ylim(-32768, 32767)
    ax_wave.set_xlabel("Sample index")
    ax_wave.set_ylabel("Amplitude (int16)")
    ax_wave.set_title("Waveform")
    ax_wave.grid(True, alpha=0.3)

    (fft_line,) = ax_fft.plot(freqs, np.zeros_like(freqs), lw=0.8)
    peak_marker, = ax_fft.plot([], [], "ro", ms=6)
    ax_fft.set_xlim(0, SAMPLE_RATE / 2)
    ax_fft.set_ylim(0, FFT_YMAX)          # fixed magnitude axis — no auto-adjust
    ax_fft.set_xlabel("Frequency (Hz)")
    ax_fft.set_ylabel("Magnitude")
    ax_fft.set_title("FFT — waiting for data…")
    ax_fft.grid(True, alpha=0.3)

    fig.tight_layout()

    def update(_frame_idx: int):
        samples = reader.latest()
        if samples is None or samples.size != FRAME_SAMPLES:
            return wave_line, fft_line, peak_marker

        wave_line.set_ydata(samples)

        windowed = samples.astype(np.float32) * window
        magnitude = np.abs(np.fft.rfft(windowed)) / window_gain
        fft_line.set_ydata(magnitude)

        if magnitude.size > 1:
            peak_idx = int(np.argmax(magnitude[1:]) + 1)
            peak_freq = float(freqs[peak_idx])
            peak_marker.set_data([peak_freq], [float(magnitude[peak_idx])])
            ax_fft.set_title(f"FFT — peak {peak_freq:.1f} Hz")

        # Magnitude axis is fixed (FFT_YMAX); no auto-scaling.
        return wave_line, fft_line, peak_marker

    anim = animation.FuncAnimation(fig, update, interval=33, blit=False,
                                   cache_frame_data=False)
    try:
        plt.show()
    finally:
        reader.stop()
    _ = anim
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
