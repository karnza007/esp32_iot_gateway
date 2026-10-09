# 11 — FFT benchmark: Gowin FFT IP vs ESP32-S3 vs (later) Intel FFT IP

**Plan:** `docs/plans/fft-benchmark.md` · **Code:** `host/fft_model.py`, `host/fft_bench.py`

| Step | Status |
|---|---|
| F0 — Python yardstick | ✅ 2026-10-08 |
| E1 — ESP32 FFT | ✅ 2026-10-08 |
| F1 — Gowin size limit | ✅ 2026-10-08 — **1024 cannot be built; the limit is 16 points** (§9) |
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
| **1. Is it correct?** | Every peak in the right bin, and RMS error ≤ **4 LSB** on every signal (was 2 LSB until E1, see §8.4) | pass / fail |
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
python fft_bench.py fpga-echo           # F2 data path via the FPGA -> data/fft/f2-fpga-echo.csv
```

FPGA (Tang Nano 20K): `fpga_fft/build.sh program` builds `fpga_fft/` from the command line and
loads it into the FPGA's SRAM (lost at power-off; re-run after unplugging).

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

### 8.4 Against the correctness gate — revised after E1

Under the gate set in F0 (rms ≤ 2.0 LSB):
- **Plain C passes all 24 tests.**
- **SIMD passes 39 of 40, failing one by 0.003 LSB** (`tone_off_bin`, N = 1024: 2.003).

That one failure is not a bug. The peaks are right, and the error is 200× smaller than the
smallest real bug's maximum error. The gate came from **modelled** designs (worst 1.32 LSB),
and the first **real, shipping** library turned out to sit right at it.

**Decision (2026-10-08): the gate is raised to 4 LSB rms.** That's 2× the worst correct
design measured, and still under the nearest bug (one missing bin, 7.1 LSB). It's recorded
here as a revision made *after* seeing real data, with both verdicts kept:

| | Gate 2 LSB (set in F0, before any device) | Gate 4 LSB (revised after E1) |
|---|---|---|
| ESP32 plain C | 24 / 24 correct | 24 / 24 correct |
| ESP32 SIMD | 39 / 40 correct | **40 / 40 correct** |

The raw rms values are in the CSVs, so the verdict can be recomputed under any gate. The Gowin
core (F3) will be judged by the 4 LSB gate, which was fixed before it was tested.

## 9. F1 — how big a Gowin FFT fits on the Tang Nano 4K

**Setup.** Karn generated the core in the GUI (Tools → IP Core Generator → FFT) with the agreed
settings: 1024 points, forward, natural order, RS111, 16/16/16 bits, rounding, DSP multipliers,
BSRAM for data and twiddles. Every setting was confirmed from the generated `defile.v`, not just
the screenshot. The core was then placed and routed inside `fpga_fft/sizing/sizing_top.v`, a
throwaway wrapper that feeds it pseudo-random data and folds every output into one pin, so
nothing can be optimised away. Timing was judged at 54 MHz.

### 9.1 The result

| Data memory setting | N | Outcome |
|---|---|---|
| **BSRAM** (as generated) | 1024 | ❌ Place & route: *"Cannot instantiate … (DPB), there is no DPB resource in current device"* |
| AUTO | 1024 | ❌ Same error, identical netlist |
| REG / distributed | 1024 | ❌ Needs 32,768 flip-flops for the real-part memory alone; the chip has 3,573 |
| REG | 64 | ❌ 4,370 flip-flops needed (3,573 available) |
| REG | 32 | ❌ 4,964 logic cells needed (4,608 available) |
| **REG** | **16** | ✅ Fits: logic 64 %, registers 37 %, BSRAM 3/10, DSP 2/8. **Fmax 44.3 MHz** (misses 54 MHz) |

**The largest Gowin FFT that fits the Tang Nano 4K is 16 points**, and it must run at ≤ 44 MHz.

### 9.2 Why: the chip lacks the *kind* of memory, not the amount

The GW1NSR-4C has 10 memory blocks, and the 1024-point core only asked for 6. The problem is
the **type**. The core's working memory is a **true dual-port** RAM (Gowin's `DPB`): two ports,
each able to read *or* write, because a radix-2 butterfly reads two values and writes two
values back in place. The GW1NSR-4C's blocks only offer single-port and **semi**-dual-port
(one port writes, the other reads). With no `DPB`, the only fallback is building the memory
out of flip-flops, and those run out at 16 points.

H2 predicted that *memory* would be the limit, which was right, but for the wrong reason.
It was never the amount; it was the type.

### 9.2a How an FFT uses its memory (for explaining the result)

**The butterfly.** An N-point FFT is built from one small operation repeated many times: take
two numbers `a` and `b`, and produce `(a + w·b)/2` and `(a − w·b)/2`, where `w` is a twiddle
factor. Drawn out, the two crossing lines look like a butterfly.

**Stages.** The FFT runs log₂N stages, each made of N/2 butterflies. At N = 1024 that's
10 stages × 512 butterflies = **5,120 butterflies**. Each stage pairs up different elements:

```
 N = 8: which two memory addresses each butterfly reads and writes back

   stage 1 (distance 1):   (0,1)  (2,3)  (4,5)  (6,7)
   stage 2 (distance 2):   (0,2)  (1,3)  (4,6)  (5,7)
   stage 3 (distance 4):   (0,4)  (1,5)  (2,6)  (3,7)

          a ──●───────●── a' = (a + w·b) / 2
               ╲     ╱
                ╲   ╱        one butterfly:
                 ╳           2 values in, 2 values out
                ╱   ╲
               ╱     ╲
          b ──●───────●── b' = (a − w·b) / 2
```

Stage 1 pairs neighbours (0,1)(2,3)…, stage 2 pairs elements 2 apart, stage 3 pairs elements 4
apart, and so on, up to 512 apart in the last stage.

**In place.** A small FFT core keeps all N values in **one memory**. Each butterfly reads two
values and writes its two results **back into the same two addresses**. Then the next
butterfly does the same. That's why the memory needs to be only N words, not N words per stage.

**Four memory accesses per butterfly.** Read `a`, read `b`, write `a′`, write `b′`. A memory
**port** is one address-and-data connection and does **one access per clock**. So:

| Memory type | Ports | Accesses per clock | Clocks per butterfly | On GW1NSR-4C? |
|---|---|---|---|---|
| Single port (SP) | 1 read-or-write | 1 | 4 | ✅ |
| **Semi**-dual port (SDP) | 1 write-only + 1 read-only | 1 read + 1 write | 2 (limited by the reads) | ✅ |
| **True** dual port (DP / `DPB`) | 2, each read-or-write | 2 reads, or 2 writes, or one of each | 2, with any mix | ❌ |
| Flip-flops | any number | unlimited | 1 | ✅ but tiny |

The Gowin core is designed around **true** dual port: one clock reads `a` and `b` together
through both ports, a later clock writes `a′` and `b′` together through both ports. A
semi-dual-port memory can't do that, because it has only **one** read port and only **one**
write port, so two reads in one clock is impossible.

**This is a design choice in the core, not a limit of FFTs.** An FFT *can* be built for
semi-dual-port memory. For example, split the data across two memories (banking, so `a` and `b`
always live in different blocks), or alternate between two memories each stage (ping-pong), or
simply accept two clocks per read. Gowin's core doesn't offer these, and its encrypted source
can't be changed. A Gowin chip that has `DPB` blocks (the GW1A/GW2A family the generator
targets) would build the 1024-point core.

**Why flip-flops run out so fast.** Flip-flops have no port limit, but each one stores a single
bit. A 1024-point core holds 1024 complex values × 32 bits, and needs space for the results as
well, so about 65,000 bits. The chip has 3,573 flip-flops. On top of that, every read needs a
multiplexer that can pick any one of the N values, so logic runs out too: at 32 points, the
multiplexers alone overflow the chip's 4,608 logic cells.

### 9.2b Can the 4K's memory be configured as dual-port? — checked three ways

A web search summary claimed the Tang Nano 4K's block RAM supports dual-port mode. That claim
was checked against three independent primary sources:

**1. Gowin's datasheet (DS861-1.9E, GW1NSR series, §2.7.2, Table 2-5).** The series feature
list says "Supports Dual Port mode", but the table's footnote reads:

> *[1] GW1NS-4C/4 do not support dual port mode.*

The datasheet also states the GW1NSR is a system-in-package built on the GW1NS die, so the
GW1NSR-4C (Tang Nano 4K) has the GW1NS-4C's memory. **The search summary repeated the series
headline and missed the footnote.**

**2. Gowin's own IDE data.** Each memory generator lists the chips it supports:

| Memory generator | GW1NSR-4C (Tang Nano 4K) | GW1NR-9C (Tang Nano 9K) | GW2AR-18C (Tang Nano 20K) |
|---|---|---|---|
| Single port (`RAM_SP`) | ✅ | ✅ | ✅ |
| Semi-dual port (`RAM_SDPB`) | ✅ | ✅ | ✅ |
| **True dual port (`RAM_DPB`)** | **❌ not listed** | ✅ | ✅ |
| ROM (`RAM_pROM`) | ✅ | ✅ | ✅ |

**3. A direct build test** (`fpga_fft/sizing/dpb_test/run.sh`): the smallest possible RAM
where both ports read and write, built through place & route for each chip:

| Design | Chip | Result |
|---|---|---|
| True dual-port | GW1NSR-4C (4K) | ❌ *"No 'DPB' resource in current device"* |
| Semi-dual-port | GW1NSR-4C (4K) | ✅ builds (1/10 BSRAM) |
| True dual-port | GW1NR-9C (9K) | ✅ builds (1/26 BSRAM) |
| True dual-port | GW2AR-18C (20K) | ✅ builds (1/46 BSRAM) |

The 9K and 20K rows are the control: the same file builds there, so the 4K failure is the chip,
not the test. (An earlier version of the test used a read-before-write memory, which the 9K and
20K rejected with *"Not support … (DPB) WRITE_MODE0 = 2'b10"*. That message confirmed those
builds had mapped to `DPB`; the test was then changed to normal write mode.)

**Conclusion: the Tang Nano 4K's block RAM cannot be configured as true dual-port.** The
Tang Nano 9K and 20K both can, so the 1024-point Gowin core should build on either.

### 9.2c The same 1024-point core on the Tang Nano 9K and 20K chips (build only)

Before borrowing a board, the unchanged 1024-point core (BSRAM data memory, as generated) was
synthesised and placed & routed for each chip inside the same `sizing_top.v`:

| Chip (board) | Builds? | Logic | Registers | BSRAM | DSP | Fmax (constraint 54 MHz) |
|---|---|---|---|---|---|---|
| GW1NSR-4C (Tang Nano 4K) | ❌ no `DPB` | — | — | — | — | — |
| GW1NR-9C (Tang Nano 9K) | ✅ | 1,012 / 8,640 (12 %) | 254 / 6,693 (4 %) | 8 / 26 (31 %) | 2 / 10 | 53.95 MHz (just short; run at 50 MHz or lower) |
| GW2AR-18C (Tang Nano 20K) | ✅ | 1,012 / 20,736 (5 %) | 254 / 15,750 (2 %) | 8 / 46 (18 %) | 2 / 24 | 88.3 MHz |

Fmax includes the throwaway wrapper's logic, so it is a lower bound for the core itself.
Either board can run the full 1024-point test with plenty of room for the buffers.

### 9.3 What this says about ease of use

| Observation | Why it matters |
|---|---|
| The generator offered BSRAM for this exact part number and produced the core without a warning | The failure only appears at place & route, after the user has written a design around it |
| The generator's own synthesis report showed "6 BSRAM" as if all was well | Synthesis counts blocks but doesn't check that the chip has that block **type** |
| The generator's settings file only has targets for the GW1A/GW2A family (`TARGET_DEVICE_GW1A2A`) and GW5 | Nothing specific to the GW1NSR, which is the chip that lacks `DPB` |
| *Low Resource* vs *High Performance* produced **identical** netlists (211 REG, 184 ALU, 729 LUT, 2 DSP, 6 BSRAM) | For this configuration, the architecture option appears to do nothing |
| The core is encrypted | The memory structure could only be found by trial builds, not by reading the code |

**How the variants were built without the GUI.** The generator turned out to be a thin layer
over one synthesis run: it writes the options as `` `define `` lines (`temp/FFT/defile.v`) plus
two twiddle tables, then synthesises Gowin's encrypted `fft.v`. `fpga_fft/sizing/try_variant.sh`
edits those inputs and repeats the run. The macro names were read from the generator's library
(`libFFT.dylib`). The twiddle tables are `round(32767·cos)` and `round(−32767·sin)` over a full
circle; `gen_twiddles.py` reproduces the GUI's 1024-point tables **byte for byte**, which
confirms the method.

```bash
cd fpga_fft/sizing
./try_variant.sh ebr1024 EBR_MEMORY 1024 10    # -> no DPB resource
./try_variant.sh reg16   REG_MEMORY 16 4       # -> fits, Fmax 44.3 MHz
```


## 10. F2 — the data path to the FPGA, proven with an echo (Tang Nano 20K)

**Why first:** before trusting any FFT result from the FPGA, the path that carries the signal
there and back must be shown to lose nothing. Otherwise a wrong spectrum could be a transport
fault, not a core fault. So the FPGA first just **echoes** the signal: no FFT, same path.

### 10.1 The setup

```
 Mac ──USB, 2 Mbaud──▶ ESP32-S3 ──GPIO17 → pin 27, 1 Mbaud──▶ Tang Nano 20K
     (host/fft_bench.py)  (firmware/fft_bench, cmd 'E')          (fpga_fft/src/top.v)
 Mac ◀──────────────── ESP32-S3 ◀──GPIO18 ← pin 28 ────────────── uart_rx → RAM → uart_tx
                                   + GND ↔ GND, no power wire between boards
```

| Setting | Value |
|---|---|
| FPGA | GW2AR-LV18QN88C8/I7 (Tang Nano 20K), 27 MHz crystal on pin 4, no PLL |
| ESP32 ↔ FPGA | UART 8N1, **1 Mbaud** = 27 MHz ÷ 27, exact on both sides (ESP32: 80 MHz ÷ 80) |
| Frame | `A5 5A cmd` + 4096 bytes (1024 points × re, im int16) → `5A A5 status cycles rx_sum` + 4096 bytes + `tx_sum` |
| FPGA design | `uart_rx` (new) → frame engine → 1024×32 block RAM → `uart_tx` (reused from the audio design) |
| Build | `fpga_fft/build.sh program` (command line; same as Synthesize + Place & Route + Program in the IDE) |

**Two checksums, two directions.** The FPGA reports the byte sum of what it *received*
(`rx_sum`) as well as of what it *sent* (`tx_sum`). The ESP32 checks both, so a fault can be
placed on the inbound wire (status 6) or the outbound wire (status 7), not just "somewhere".
A frame that stops for 1 ms mid-way is dropped by the FPGA (LED 2 records it), so one lost
byte can't misalign every frame after it.

### 10.2 Resources and timing (echo design, place & route report)

| Logic | Registers | BSRAM | DSP | Fmax (constraint 27 MHz) |
|---|---|---|---|---|
| 318 / 20,736 (2 %) | 229 / 15,750 (2 %) | 2 / 46 (2 × SDPB, the 1024×32 buffer) | 0 | 147.6 MHz, no setup/hold violations |

One warning stays: `PR1014`. The 20K's crystal is wired to pin 4, a PLL input rather than a
dedicated global-clock pin, so the clock reaches the global network over general routing. At
27 MHz the timing report shows positive setup and hold slack, so it is harmless here.

### 10.3 Result: PASS

`python fft_bench.py fpga-echo -r 50`: 13 payloads × 50 frames.

| Payloads | Frames back byte for byte | Byte errors | Round trip (ESP32 → FPGA → ESP32) |
|---|---|---|---|
| The 9 test signals (incl. overload) + random bytes, sync bytes `A5 5A` repeated, all `0x00`, all `0xFF` | **650 / 650** | **0** (of 2.66 M bytes each way) | **82.4 ms**, against 82.1 ms of pure wire time |

- The raw patterns cover every byte value, and a payload made entirely of the FPGA's own sync
  bytes. That proves the frame engine counts bytes rather than hunting for markers mid-frame.
- Round trip ≈ wire time: neither side leaves gaps. The UART is the whole cost: 41 ms each way
  at 1 Mbaud. That's why the FFT time in F3 is measured **inside** the FPGA by a cycle counter,
  not from the outside.
- The ESP32's own FFT commands still give the E1 numbers after the protocol change (noise
  1.821 LSB, 65.1 µs), so nothing regressed.

**So in F3, any error in the spectrum belongs to the FFT core, not to the transport.**

## 11. F3 — the Gowin FFT core on the Tang Nano 20K

Full write-up with tables and interpretation: `docs/reports/2026-10-11.md`, Part B. Key facts:

| | Result |
|---|---|
| Design | `fpga_fft/src/top.v` command `'F'`: the shared 1024×32 buffer feeds `fft_1024` and receives its results; cycle counter from `start` to `eoud`; 39 ms watchdog |
| Driving the core | Gowin IPUG503 Figure 6-1: `start` pulse; sample `idx` supplied while `ipd` is high (the RAM is addressed with `idx + 1` one clock ahead, because it answers one clock later); result stored at `idx` while `opd` is high |
| Correct (4 LSB gate) | **7 / 8** at N = 1024. Original 2 LSB gate: 4 / 8 |
| RMS error on noise | **2.184 LSB** (+14.2 dB over the best possible 0.427). ESP32 SIMD 1.821, plain C 0.455 |
| **Full-scale square wave** | **Wrong** (1023.8 LSB rms). Inputs near −32768 wrap inside the core; see the threshold table in the report |
| Time | **7,190 cycles = 266.3 µs** at 27 MHz, start to last result (identical on every signal) |
| Resources | F3 build: 1,426 logic (7 %), 480 registers, 8 / 46 BSRAM (2 SDPB + 4 DPB + 2 pROM), 2 / 24 DSP, Fmax 80.6 MHz. With the time-split counters (§12, current): 1,612 logic (8 %), 649 registers, same BSRAM/DSP, Fmax 94.1 MHz |

```bash
fpga_fft/build.sh program          # build + load the FPGA (SRAM)
python host/fft_bench.py fpga      # -> data/fft/f3-fpga-gowin.csv
```

**Note on F2's LED 3.** After bring-up, LED 3 (UART framing error) was found lit once. Reprogramming
cleared it; an ESP32 reset alone and a full echo run did not light it again. All frames were
unaffected (byte count + two checksums). Most likely a one-time setup event (ESP32 flashing or
wire handling).

## 12. Time split (where the time goes)

Method, diagrams and full tables: `docs/reports/2026-10-11.md` §8. N = 1024:

| Step | Gowin FPGA (27 MHz) | ESP32 SIMD (240 MHz) | ESP32 plain C |
|---|---|---|---|
| Input in (FPGA load / ESP32 copy) | 1,024 cyc = 37.9 µs | 2,596 cyc = 10.8 µs | 10.8 µs |
| Compute | 5,141 cyc = 190.4 µs (~1 butterfly/clock) | 15,631 cyc = 65.1 µs (~3 cyc/butterfly) | 247,166 cyc = 1,029.9 µs (~48) |
| Natural order (FPGA unload / ESP32 bit-reverse) | 1,024 cyc = 37.9 µs | 25,972 cyc = 108.2 µs | 108.2 µs |
| Total | 7,190 cyc = 266.3 µs | 44,199 cyc = 184.2 µs | 275,734 cyc = 1,148.9 µs |

- FPGA: `top.v` stamps the cycle counter at the first clock of `sod`, `eod`, `busy`↑, `busy`↓
  and `soud`; the reply carries the 5 stamps (FPGA reply header is now 29 bytes). Cost: +186
  logic, +169 registers.
- ESP32: the cycle counter is read between copy, FFT and bit-reverse in each of 20 runs; the
  fastest of each step is reported, and a whole-run timing cross-checks the sum (within 0.1 %).
  The ESP32 → Mac reply carries these as a "split" block (`n_split` × u32 after the header).

## 13. Free simulation of the Gowin core

`fpga_fft/sim/tb_fft.v` + `src/fft/fft_1024.vo` (unencrypted gate-level model) + Gowin's
`IDE/simlib/gw2a/prim_sim.v`, compiled with Icarus Verilog (`iverilog -g2012 -s tb_fft`). The
testbench needs a `GSR` instance (the library's flip-flops reference `GSR.GSRO`). Result: phase
stamps and rms/max error on all 9 signals identical to the board. Run: `python host/fft_bench.py
sim [--board]` → `data/fft/f3-sim-gowin.csv`. Full write-up: weekly report §10.
