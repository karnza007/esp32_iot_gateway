# 11 — FFT benchmark: Gowin FFT IP vs ESP32-S3 vs (later) Intel FFT IP

**Plan:** `docs/plans/fft-benchmark.md` · **Code:** `host/fft_model.py`, `host/fft_bench.py`

| Step | Status |
|---|---|
| F0 — Python yardstick | ✅ 2026-10-08 |
| E1 — ESP32 FFT | — |
| F1 — Gowin size limit | — |
| F2 — FPGA loopback | — |
| F3 — FPGA FFT | — |
| F4 — Report | — |

---

## 1. Overview

The advisor's question: **is the Gowin FFT IP core on the Tang Nano 4K correct, and how easy is
it to use** compared with the Intel FFT IP core (to be tested later on a DE0-Nano, Cyclone IV)?
The ESP32-S3's software FFT (ESP-DSP) is added as a third device.

The method: the Mac makes a test signal, a device computes its FFT, the Mac checks the answer.

```
   Mac: make test signal ──▶ device under test ──▶ Mac: score the result
                              (ESP32-S3, or          against numpy.fft
                               Tang Nano via ESP32)
```

## 2. Integer arithmetic

Every device computes in **16-bit signed integers**, and every one halves the data at each of
its log₂N stages, so each outputs **FFT(x) ÷ N** in int16.

| | Data | Twiddles | Scaling |
|---|---|---|---|
| Gowin FFT IP | `signed [15:0]` | 16-bit | ÷2 per stage (`RS111`) |
| ESP32-S3 `dsps_fft2r_sc16` | `int16_t` (Q15) | `int16_t` | ÷2 per stage — `(x + 0x7fff) >> 16` after a Q15 multiply, read in the ESP-DSP source |

*Twiddles* are the fixed sine/cosine constants an FFT multiplies by. *Q15* means a 16-bit
integer read as a fraction: 32767 ≈ 1.0.

**Why ÷N matters:** an FFT adds N numbers into each output bin, so its output can be N times
bigger than its input. 16 bits can't hold that, so each stage halves. Our reference must
divide by N too, or every device would look wrong by a factor of 1024.

## 3. F0 — the yardstick

Before measuring a device, the measuring tool has to be proven. That is all F0 is.

### 3.1 Two Python references

| | Arithmetic | Role |
|---|---|---|
| `numpy.fft` ÷ N | 64-bit float | **The ruler** — the true answer |
| `ideal_fixed_fft` | integer | **The ceiling** — the best a 16-bit integer FFT can possibly do |

The integer model is a textbook radix-2 FFT done as carefully as 16 bits allow: Q15 twiddles,
one rounding per butterfly output, ÷2 per stage, int16 storage between stages (with overflow
counted and wrapped the way hardware wraps).

The same butterfly code also runs in a **float mode** with no rounding. That version must equal
numpy to ~10⁻¹¹ — and it does, at N = 8, 64 and 1024. That proves the structure (bit-reversal,
twiddle signs, stage order) before any rounding is switched on, so any later error can only
come from rounding.

### 3.2 Test signals

All int16, generated at any N:

| Signal | What it checks |
|---|---|
| `impulse` | Flat spectrum: every bin, and the ÷N scaling (32767 in → 32 in every bin at N = 1024) |
| `dc` | All energy in bin 0 |
| `tone_on_bin` | One clean spike at bin 37 |
| `tone_off_bin` | Leakage between bins matches numpy |
| `two_tones` | Bins 37 and 101 both found, the first 12 dB louder |
| `noise` | Full-scale random: every butterfly exercised; the average error |
| `full_scale` | ±32767 square wave: largest real input, must not overflow |
| `complex_tone` | Real + imaginary input: a single peak at a negative frequency (bin N − 77) |
| `overload` | *Not scored.* Magnitude 46,340 — must overflow; shows **how** a device fails |

### 3.3 Wire format

N complex samples, each `re:int16 LE, im:int16 LE`, natural order — 4N bytes (4 KB at N = 1024).
This is ESP-DSP's native layout, so the ESP32 needs no conversion.

## 4. F0 results — what the best possible 16-bit FFT scores

From `python host/fft_bench.py model` (`data/fft/f0-model-baseline.csv`), N = 1024:

| Signal | SQNR (dB) | Max error (LSB) | RMS error (LSB) | Peaks |
|---|---|---|---|---|
| impulse | 90.3 | 0.00 | 0.001 | — |
| dc | exact | 0.00 | 0.000 | ok |
| tone_on_bin | 59.2 | 1.03 | 0.280 | ok |
| tone_off_bin | 58.1 | 1.35 | 0.319 | — |
| two_tones | 86.5 | 0.04 | 0.006 | ok |
| **noise** | **59.8** | **1.28** | **0.427** | — |
| full_scale | 81.2 | 0.93 | 0.063 | — |
| complex_tone | 92.3 | 0.08 | 0.009 | ok |
| overload | −3.0 | 59,078 | 1,448 | 128 overflows, wrapped |

**Read it as:** even a perfect 16-bit FFT is off by about **0.4 LSB rms** on full-scale noise.
That is the **noise floor**, 0.398 / 0.434 / 0.427 LSB at N = 256 / 512 / 1024. No 16-bit
device can beat it; a good one comes close.

## 5. Two traps F0 caught, and the rule that replaced them

### 5.1 The lucky tone

The first version put tones on bins that scaled with N (bin 9 at N = 256, bin 18 at N = 512).
Those scored **92 dB**, but bin 37 at N = 1024 scored **59 dB** in the same model. A sweep
showed why:

| Tone bin | 8 | 16 | 32 | 36 | **37** | 38 | 64 | 100 | **101** |
|---|---|---|---|---|---|---|---|---|---|
| SQNR (dB) | 94 | 93 | 93 | 93 | **59** | 65 | 98 | 93 | **57** |

A tone on an even bin divides so neatly through the butterflies that almost nothing ever needs
rounding. That measures **luck in the internal layout**, not accuracy. A correct device built
differently would have scored 30 dB worse and been called broken. **Fix:** all tones are on
odd bins (37, 101, 77).

### 5.2 "Within 3 dB of the ideal" fails correct designs

The plan's rule was *"SQNR within 3 dB of the ideal 16-bit model."* To test the rule itself,
two other **correct** designs were added to the model: one that rounds twice per butterfly
(common in real cores) and one that truncates instead of rounding (a legal Gowin option). Then
some realistic **bugs** were faked on purpose:

| Design | RMS error (LSB), worst signal | Verdict should be |
|---|---|---|
| Best possible (rounds once) | 0.43 | correct |
| Rounds twice | 0.73 | correct |
| Truncates | 1.32 | correct |
| Output left in bit-reversed order | 575 | **broken** |
| One stage forgot to halve | 417 | **broken** |
| Wrong direction (inverse FFT) | 604 | **broken** |
| One bin missing | 7.1 | **broken** |

The old rule **failed the rounds-twice design** (5–7 dB above the ideal) — a correct FFT
called wrong. The table also shows why a simpler rule works: **correct designs are off by about
one LSB; broken ones by hundreds.** There's a gap of more than 300× between them.

### 5.3 The rule now: two questions, not one

| Question | Rule | Type |
|---|---|---|
| **1. Is it correct?** | Every peak in the right bin, and RMS error ≤ **2 LSB** on every signal | pass / fail |
| **2. How accurate?** | RMS error on `noise`, in LSB and in dB above the 0.43-LSB floor | a number, compared between devices |

`python host/fft_bench.py selftest` re-proves all of this on every run: the gate passes all
three correct designs and fails all five bugs.

## 6. Hypotheses (updated in F0)

| | Hypothesis | Tested by |
|---|---|---|
| **H1** | The Gowin core is a correct 16-bit FFT | Question 1 on every signal |
| **H2** | Memory runs out before logic; 1024 points fits, else 512 | Synthesis report (F1) |
| **H3** | The ESP32 is correct, and about as accurate as the FPGA | Question 1, then question 2 compared |
| **H4** | The FPGA finishes one FFT faster than the ESP32 and needs no CPU | Cycle counters (E1, F3) |

## 7. How to run

```bash
cd host
python fft_bench.py selftest     # must print ALL PASS before any device result is trusted
python fft_bench.py model        # the ceiling table, saved to data/fft/f0-model-baseline.csv
```
