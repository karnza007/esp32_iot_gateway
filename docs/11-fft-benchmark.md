# 11 — FFT benchmark: Gowin FFT IP vs ESP32-S3 vs (later) Intel FFT IP

**Plan:** `docs/plans/fft-benchmark.md` · **Code:** `host/fft_model.py`, `host/fft_bench.py`

| Step | Status |
|---|---|
| F0 — Python yardstick | ✅ 2026-10-08 |
| E1 — ESP32 FFT | ✅ 2026-10-08 — gate decision pending (§8.4) |
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
python fft_bench.py selftest            # must print ALL PASS before any device result is trusted
python fft_bench.py model               # the ceiling table -> data/fft/f0-model-baseline.csv
python fft_bench.py esp32               # ESP32 SIMD FFT    -> data/fft/e1-esp32-simd.csv
python fft_bench.py esp32 --impl ansi   # ESP32 plain-C FFT -> data/fft/e1-esp32-ansi.csv
```

ESP32 firmware: `firmware/fft_bench` (flash with `arduino-cli compile --upload -b
esp32:esp32:esp32s3:CDCOnBoot=cdc -p /dev/cu.wchusbserial* firmware/fft_bench`).

## 8. E1 — ESP32-S3 results

**Setup.** Mac → CH9102 (2 Mbaud) → ESP32-S3 at 240 MHz → ESP-DSP 16-bit FFT → back.
Each request and reply carries a checksum, so a transport error can never pass as an FFT
error. Each FFT ran 20 times on fresh copies of the input; the fastest run is reported.
Two runs on two firmware builds gave identical numbers.

ESP-DSP has two versions of the same 16-bit FFT, and both were measured:

| | What it is |
|---|---|
| **SIMD** `dsps_fft2r_sc16_aes3` | What `dsps_fft2r_sc16` uses on the S3: hand-written assembly using the S3's vector instructions |
| **Plain C** `dsps_fft2r_sc16_ansi` | Portable C, the readable version of the same algorithm |

### 8.1 Accuracy

RMS error in LSB (lower is better). Best possible 16-bit design: 0.43 LSB on noise.

| N = 1024 | SIMD | Plain C | Best possible |
|---|---|---|---|
| impulse | 0.71 | 0.71 | 0.001 |
| dc | 0.44 | 0.02 | 0 |
| tone_on_bin | 0.98 | 0.06 | 0.28 |
| tone_off_bin | **2.00** | 0.31 | 0.32 |
| two_tones | 1.00 | 0.05 | 0.006 |
| **noise** | **1.82 (+12.6 dB)** | **0.455 (+0.5 dB)** | 0.427 |
| full_scale | 0.51 | 0.24 | 0.06 |
| complex_tone | 1.04 | 0.11 | 0.009 |
| peaks | all correct | all correct | all correct |

Noise error across sizes: SIMD 1.76 / 1.81 / 1.82 / 1.82 / 1.84 LSB at N = 256 … 4096;
plain C 0.49 / 0.46 / 0.43 at N = 256 / 1024 / 4096. **Neither degrades with size.**

### 8.2 Speed (one FFT, CPU at 240 MHz)

| N | SIMD FFT | Plain C FFT | Bit-reverse (to natural order) | SIMD total |
|---|---|---|---|---|
| 256 | 14.2 µs | 210 µs | 27–31 µs | 45 µs |
| 512 | 30.4 µs | — | 54 µs | 84 µs |
| **1024** | **65.1 µs** | **1,030 µs** | 108 µs | **173 µs** |
| 2048 | 139 µs | — | 217 µs | 357 µs |
| 4096 | 297 µs | 4,868 µs | 439 µs | 736 µs |

Two surprises:
- **SIMD is 16× faster than plain C** at N = 1024.
- **Putting the output back in order costs more than the FFT itself** (108 µs vs 65 µs). The
  FPGA core outputs natural order, so the fair ESP32 figure is the **total, 173 µs**.

### 8.3 Why the SIMD version is less accurate

Three systematic effects, found in the raw output:

| Effect | Evidence |
|---|---|
| Output 1 LSB low | Impulse: every bin 31 instead of 32 (both versions: the rounding constant 0x7fff instead of 0x8000 rounds exact halves down) |
| Gain loss of 2 LSB per stage (SIMD only) | DC bin 0 is short by exactly 8 / 12 / 16 / 20 / 24 at N = 16 / 64 / 256 / 1024 / 4096 — that is, 2 × log₂N |
| More rounding noise, mostly in the real part (SIMD only) | After removing bias and gain: 1.43 LSB; real part 1.87, imaginary 1.10 |

Plain C does not have the last two, so they come from how the SIMD assembly does its
arithmetic, not from the algorithm. **ESP-DSP trades about 4× accuracy for 16× speed** in its
fast version. For audio, a 0.01 dB gain error and ~2 LSB of noise are inaudible; for
measurement-grade work, they matter.

**Overload behaviour:** plain C wraps around, matching the Python model to 0.1 LSB rms (1,448
vs 1,448). SIMD does about 7× less damage (212 LSB rms), consistent with **saturating** instead
of wrapping.

### 8.4 Against the correctness gate — decision pending

Under the gate set in F0 (rms ≤ 2.0 LSB):
- **Plain C passes all 24 tests.**
- **SIMD passes 39 of 40, failing one by 0.003 LSB** (`tone_off_bin`, N = 1024: 2.003).

That one failure is not a bug. The peaks are right, and the error is 200× smaller than the
smallest real bug's maximum error. The gate came from **modelled** designs (worst 1.32 LSB),
and the first **real, shipping** library turned out to sit right at it.

The raw rms values are saved in the CSVs, so the verdict can be recomputed under any gate.
**Proposed:** raise the gate to 4 LSB rms. That's 2× the worst correct design measured, and
still under the nearest bug (one missing bin, 7.1 LSB). Awaiting confirmation; until then, the
pre-registered result above stands as recorded.
