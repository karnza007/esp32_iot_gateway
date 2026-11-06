"""make_test_song.py — a short piano-like "Happy Birthday" to test the music path.

    python host/make_test_song.py [out.wav]          (default data/happy_birthday.wav)

The tune (traditional, public domain) in C major, 3/4 time, 120 beats per minute (~13 s).
Each note is a "piano-like" tone: harmonics 1..6 with amplitudes 1/k^1.2, a 5 ms attack and an
exponential fade that is faster for higher harmonics, ringing on 0.25 s past its length. On the
spectrogram every note shows as a stack of lines (f, 2f, 3f, ...) that fade from the top.
Written mono, 16-bit, 24,170 Hz (the rate audio_rx.v expects), peak -14 dB of full scale.
"""
import os
import sys
import wave

import numpy as np

FS = 24170
BEAT = 0.5                                  # s
NOTE = {"C4": 261.63, "D4": 293.66, "E4": 329.63, "F4": 349.23, "G4": 392.00, "A4": 440.00,
        "B4": 493.88, "C5": 523.25, "D5": 587.33, "E5": 659.25, "F5": 698.46, "G5": 783.99}
TUNE = [("G4", .75), ("G4", .25), ("A4", 1), ("G4", 1), ("C5", 1), ("B4", 2),
        ("G4", .75), ("G4", .25), ("A4", 1), ("G4", 1), ("D5", 1), ("C5", 2),
        ("G4", .75), ("G4", .25), ("G5", 1), ("E5", 1), ("C5", 1), ("B4", 1), ("A4", 2),
        ("F5", .75), ("F5", .25), ("E5", 1), ("C5", 1), ("D5", 1), ("C5", 3)]


def piano(f, dur):
    t = np.arange(int((dur + 0.25) * FS)) / FS
    tone = sum(np.sin(2 * np.pi * k * f * t) * np.exp(-t * (1.2 + 0.7 * k)) / k ** 1.2
               for k in range(1, 7) if k * f < FS / 2 - 500)
    attack = np.minimum(t / 0.005, 1.0)
    release = np.clip((dur + 0.25 - t) / 0.25, 0, 1)        # fade out over the last 0.25 s
    return tone * attack * release


total = sum(d for _, d in TUNE) * BEAT + 1.0
out = np.zeros(int(total * FS))
pos = 0.25
for name, d in TUNE:
    n = piano(NOTE[name], d * BEAT)
    i = int(pos * FS)
    out[i:i + len(n)] += n
    pos += d * BEAT
out *= 10 ** (-14 / 20) * 32767 / np.abs(out).max()
path = sys.argv[1] if len(sys.argv) > 1 else os.path.join(os.path.dirname(__file__), "..", "data",
                                                          "happy_birthday.wav")
os.makedirs(os.path.dirname(os.path.abspath(path)), exist_ok=True)
with wave.open(path, "wb") as w:
    w.setnchannels(1)
    w.setsampwidth(2)
    w.setframerate(FS)
    w.writeframes(np.round(out).astype("<i2").tobytes())
print(f"wrote {path}: {len(out) / FS:.1f} s, {len(TUNE)} notes, {FS} Hz mono 16-bit, peak -14 dBFS")
