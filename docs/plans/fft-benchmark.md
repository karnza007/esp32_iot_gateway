# FFT benchmark — is the Tang Nano's FFT core correct, and how easy is it to use?

**Status:** confirmed 2026-10-08. F0, E1, F1, F2, F3 done (see `docs/11-fft-benchmark.md`).
**Audio work:** paused. The bench is still in synthetic-load mode (`GEN_MODE=1`); restore
before audio resumes.

---

## 1. Why

The advisor wants two things answered about the vendor FFT IP cores:

1. **Is the Gowin FFT core on the Tang Nano 4K correct?**
2. **How easy is it to use**, compared with the Intel (Altera) FFT core on a DE0-Nano
   (Cyclone IV), which will be tested later in exactly the same way?

The ESP32-S3 is added as a third device: a 16-bit integer FFT in software (ESP-DSP), so the
comparison also answers *"is an FPGA worth it for this?"*

## 2. Integer arithmetic, everywhere it matters

Every device under test computes in **16-bit signed integers (fixed point)**. No floats.

| | Data | Twiddle factors (fixed sine/cosine constants) | Scaling |
|---|---|---|---|
| Gowin FFT IP | `signed [15:0]` re + im | 16-bit integers | ÷2 per stage (`RS111`) |
| ESP32-S3 `dsps_fft2r_sc16` | `int16_t` re + im (Q15) | `int16_t` table | ÷2 per stage (Q15 multiply, `>>16` with rounding) |
| Intel FFT IP (later) | 16-bit | 16-bit | ÷2 per stage, to match |

ESP-DSP's scaling was checked in its source (`dsps_fft2r_sc16_ansi.c`): every butterfly
result goes through `(x + 0x7fff) >> 16` after a Q15 multiply, i.e. ÷2 per stage, the same
as Gowin's `RS111`. **So both devices do the same arithmetic and the comparison is fair.**

Python plays two roles, and **neither is a competitor**:

| Python part | Arithmetic | Role |
|---|---|---|
| `numpy.fft` | 64-bit float | **The ruler.** The true answer, to measure error against |
| Ideal 16-bit model | Integer (int64 with explicit rounding and ÷2 per stage) | **The accuracy ceiling.** The error of the best possible 16-bit FFT |

## 3. Block diagram

```
                Mac (Python: host/fft_bench.py)
     makes test signal ── compares result with numpy.fft + ideal 16-bit model
                │  ▲
       USB (CH9102 or native USB)
                ▼  │
       ESP32-S3  firmware/fft_bench/   — one sketch, two modes
       ┌───────────────────────────────────────────────────────┐
       │ mode "local":   int16 → dsps_fft2r_sc16 → bit reverse  │  ← E1
       │                 + CPU cycle counter                     │
       │ mode "fpga":    forward bytes to/from the FPGA          │  ← F2, F3
       └───────────────────────────────────────────────────────┘
              UART TX │  ▲ UART RX (existing link 1 wire)
           (new wire) ▼  │
       Tang Nano 4K  fpga-fft/   — separate project, audio design untouched
       ┌──────────────────────────────────────────────────────────────────┐
       │ uart_rx ─▶ buffer ─▶ Gowin FFT IP ─▶ buffer ─▶ uart_tx            │
       │            (block RAM)  int16 in/out    (may share one buffer)     │
       │            + cycle counter: start → last output                    │
       └──────────────────────────────────────────────────────────────────┘
```

**Why buffers:** once started, the FFT core takes one sample per clock (54 M/s). UART delivers
~50 k/s. So the whole signal is collected first, then fed to the core at full speed; the
result is buffered the same way on the way out.

**Swappable transport:** the FFT block only sees *bytes in, bytes out*. UART now; in M4 the
UART modules are replaced by SPI and this test becomes a ready-made correctness check for SPI.

## 4. Fixed settings (confirmed)

| Setting | Value |
|---|---|
| FFT size | 1024, or the largest that fits (see H2) |
| Direction | Forward only |
| Scaling | ÷2 per stage (`RS111`) |
| Widths | 16-bit input, twiddle, output |
| FPGA clock | **27 MHz, the board's own crystal, no PLL** (changed 2026-10-08: 54 MHz was raised for the audio work; the FFT test doesn't need it). Both the Tang Nano 9K and 20K have a 27 MHz crystal |
| UART baud (ESP32 ↔ FPGA) | **1 Mbaud** = 27 MHz ÷ 27, exact. 2 Mbaud would need ÷13.5, which a UART can't do |
| Transport | UART now, SPI in M4 |
| Board | Tang Nano 4K cannot build the core (F1); **9K or 20K**, requested from the advisor |
| DE0-Nano later | Identical settings; compared at the Tang Nano's maximum size, plus its own maximum reported separately |

## 5. Test signals (all integer, 16-bit)

| Signal | Checks |
|---|---|
| Impulse | Flat spectrum: every bin, and the scaling factor |
| DC | Everything in bin 0 |
| Tone exactly on a bin | One clean spike in the right bin |
| Tone between bins | Leakage pattern matches numpy |
| Two tones | Both found, correct relative size |
| Full-scale random noise | Average error across all bins |
| Maximum amplitude | No overflow / wraparound |
| Complex input (re + im) | The imaginary input path works |

## 6. Hypotheses

| | Hypothesis | Pass if |
|---|---|---|
| **H1** Correctness | The Gowin core is a correct 16-bit FFT | Every peak in the right bin, and rms error ≤ 4 LSB on every signal (2 LSB until E1) |
| **H2** Capacity | Memory blocks run out before logic; 1024 points fits (with buffer sharing), else 512 | Synthesis resource report — **result: rejected. The chip has no dual-port memory blocks, so 1024 cannot be built; max 16 points (F1)** |
| **H3** ESP32 accuracy | The ESP32 is correct, and as accurate as the FPGA (same widths, same scaling) | H1's gate, then rms error (LSB) on noise compared between devices |
| **H4** Speed | The FPGA finishes one FFT faster than the ESP32, and needs no CPU | Cycle counters converted to µs |

**Rule changed in F0.** The plan originally said "SQNR within 3 dB of the ideal model". F0
showed that rule is unfair: a common, *correct* design that rounds twice per butterfly is
5–7 dB worse than the ideal, and on some signals the ideal is near-exact by luck. Correct
designs measure 0.4–1.3 LSB rms; real bugs measure 400+ LSB. So correctness is now a gate at
2 LSB, and accuracy is a separate number compared between devices. Details in
`docs/11-fft-benchmark.md` §5.

## 7. Steps

| Step | What | Hardware | Who |
|---|---|---|---|
| **F0** ✅ | Python: test signals, numpy ruler, ideal 16-bit integer model | None | Claude |
| **E1** ✅ | ESP32 runs its own FFT on every signal: accuracy and speed. Also proves the Python tools | ESP32 | Claude |
| **F1** ✅ | Find the size limit: generate core at 1024 in the Gowin GUI → build → resources → step down if needed | None | Karn (GUI), then Claude |
| **F2** ✅ | Loopback: wire ESP32 TX → FPGA RX; the FPGA echoes the signal unchanged (Tang Nano 20K, pins 27/28; 650/650 frames) | Both | Claude; Karn wires and programs |
| **F3** ✅ | FFT on the FPGA: Mac → ESP32 → FPGA → ESP32 → Mac, compare (7/8 correct; fails at full scale; 266 µs) | Both | Claude |
| **F4** | Results doc (`docs/11-fft-benchmark.md`), comparison table, ease-of-use log, weekly report | — | Claude |

E1 and F1 can run in parallel.

## 8. Comparison table (filled in as we go)

| | Gowin FPGA | ESP32-S3 | Intel FPGA (later) |
|---|---|---|---|
| Correct (H1/H3)? | | | |
| SQNR vs numpy (dB) | | | |
| Time per FFT (µs) | | | |
| Runs continuously without a CPU? | Yes | No | Yes |
| Resources | LUT / BSRAM / mult | RAM / CPU time | LE / M9K / mult |
| Largest size that fits | | (4096, library limit) | |
| Can be simulated with free tools? | Yes, via the unencrypted gate-level model `.vo` + Icarus (undocumented; report §10) | n/a | |
| Exact model provided? | No | Open source | Yes (MATLAB) |
| Time to first working result | | | |
| Ease-of-use notes | | | |

## 9. Where things go

| Path | What |
|---|---|
| `fpga-fft/` | Separate Gowin project |
| `firmware/fft_bench/` | ESP32 sketch (both modes) |
| `host/fft_bench.py` | Test signals, models, comparison |
| `docs/11-fft-benchmark.md` | Results |
| `data/fft/` | Raw results per run |
