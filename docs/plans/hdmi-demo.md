# HDMI demo — live microphone spectrum on a monitor

**Status:** settings confirmed 2026-10-09. H1 planned, waiting for go-ahead.
**Requested by:** the advisor, after the FFT benchmark progress report.

---

## 1. Purpose

Show the Gowin FFT doing real work, **live and on its own**: sound goes into the INMP441
microphone, the Tang Nano 20K computes the spectrum, and a monitor shows it over the board's
HDMI port. No computer and no ESP32 in the chain.

## 2. The whole system

```
              ┌──────────────────────── Tang Nano 20K (FPGA) ────────────────────────┐
 INMP441 mic ─┼─▶ ① capture ─▶ ② 1024-sample ─▶ ③ window ─▶ ④ Gowin ─▶ ⑤ magnitude  │
  (I2S)       │                  buffer          + clamp      FFT        and dB       │
              │                                                            ▼          │
 monitor ◀────┼── ⑨ serializers ◀─ ⑧ TMDS ◀─ ⑦ pixel drawer ◀──── ⑥ bar memory      │
  (HDMI)      │                     encoder   (bars, grid, text)   (512 heights)      │
              └───────────────────────────────────────────────────────────────────────┘
```

Top row: every 21 ms, 1,024 new samples → FFT → 512 bar heights. Bottom row: 60 times a
second, the bar memory is drawn on the screen. The bar memory decouples the two.

## 3. Confirmed settings

| Setting | Value |
|---|---|
| Picture | **1280×720 at 60 Hz** (CEA-861 720p), sent as DVI-mode TMDS over HDMI |
| Bins shown | **512** (bins 0–511, 0–24.2 kHz; 512–1023 are the mirror), 2 px wide each |
| Height scale | **dB**, gridlines every 20 dB |
| Window | **On** |
| Input clamp | **±32,700** (keeps a tap on the mic out of the core's full-scale wrap) |
| Bar update | every FFT (~47 /s), adjustable |
| ESP32 UART benchmark | **kept** in the same design |
| Labels | H4: title, kHz axis, dB axis, peak readout |
| IP cores to generate in the GUI | **none**: Gowin built-in blocks (rPLL, CLKDIV, OSER10, TLVDS_OBUF) are used directly |

**Scaling on the 4K monitor:** the monitor scales the 1280×720 picture to its own 3840×2160 by
itself. 3840 ÷ 1280 = 2160 ÷ 720 = **exactly 3**, so every pixel we draw becomes a clean 3×3
block. The design just draws 1280×720 normally.

## 4. Clocks

```
 27 MHz crystal ─▶ rPLL (×55 ÷4) ─▶ 371.25 MHz ─────────▶ ⑨ the 4 serializers ONLY
                                        └─▶ CLKDIV ÷5 ─▶ 74.25 MHz ─▶ ① … ⑧ (everything else)
 27 MHz crystal ───────────────────────────────────────▶ ESP32 UART benchmark (unchanged)
```

| Clock | Used by | Why |
|---|---|---|
| 74.25 MHz | everything in the demo | 720p = 1650 × 750 pixel slots (incl. blanking) × 60 = 74.25 M pixels/s, one per tick |
| 371.25 MHz | only the 4 serializers (`OSER10`) in the HDMI pins' I/O blocks | 10 bits per pixel per wire = 742.5 Mbit/s; sent on both clock edges → ÷2 |
| 27 MHz | the existing UART benchmark | unchanged, so the ESP32 tests keep working exactly as before |

PLL: `IDIV_SEL=3, FBDIV_SEL=54, ODIV_SEL=2` → 27 × 55 / 4 = 371.25 MHz, VCO 742.5 MHz
(allowed 500–1250). These are the values Sipeed's official 20K HDMI example uses.

## 5. Steps

| Step | On the screen | Proves | Karn |
|---|---|---|---|
| **H1** | Colour test pattern | clocks, TMDS, serializers, pins, monitor accepts 720p | HDMI cable, report what's on screen |
| H2 | One sharp bar from a test tone generated inside the FPGA | buffer → window → FFT → dB → bars | look |
| H3 | Live spectrum from the microphone | the full demo | wire the mic (5 wires) |
| H4 | Gridlines, kHz/dB labels, peak readout | presentable | — |

---

## 6. H1 — colour test pattern (detailed)

### 6.1 Goal

Get a **stable, correct picture** on the monitor, to prove the whole video output path before
any FFT is involved.

### 6.2 What will be on the screen

```
 ┌──────────────────────────────────────────────────────────────────────┐ ← 1-pixel white border
 │ white │ yellow │  cyan  │ green  │magenta │  red   │  blue  │ black  │   on all 4 edges
 │       │        │        │        │        │        │        │        │
 │       │        │        │        │        │        │        │        │   8 bars × 160 px
 │       │        │        │        │        │        │        │        │   = 1280 px
 │▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓│ ← grey ramp, black → white
 │                 ■ → (small square moving left to right)              │ ← proves the picture is live
 └──────────────────────────────────────────────────────────────────────┘
```

| Element | Checks |
|---|---|
| 8 colour bars in a known order | Each colour channel is wired correctly (e.g. red and blue not swapped) |
| 1-pixel white border | The whole 1280×720 is visible: nothing cropped by the monitor ("overscan") |
| Grey ramp (256 steps) | All 8 bits of each colour reach the screen |
| Moving square | The picture is redrawn live every frame, not a frozen image |

### 6.3 What gets built

New files in `fpga_fft/src/hdmi/`, plus a new top file. The existing FFT design is untouched.

| File | Job |
|---|---|
| `video_timing.v` | Counts pixels and lines: 1650 × 750 per frame. Generates HSYNC, VSYNC and "visible area", and the x/y position of the current pixel |
| `test_pattern.v` | Gives the colour of pixel (x, y): bars, border, ramp, moving square |
| `tmds_encoder.v` | Turns 8-bit colour into the 10-bit HDMI code (DVI 1.0 spec algorithm: fewer transitions, balanced 1s/0s); sends sync codes during blanking |
| `hdmi_out.v` | 3 encoders + 4 `OSER10` serializers (3 colours + clock) + 4 `TLVDS_OBUF` differential pin drivers |
| `../top_hdmi.v` | PLL + ÷5 divider + the above, **and** the existing `fft_link` benchmark on the 27 MHz crystal |

**720p timing (CEA-861):**

| | Visible | Front porch | Sync | Back porch | Total |
|---|---|---|---|---|---|
| Horizontal (pixels) | 1280 | 110 | 40 | 220 | **1650** |
| Vertical (lines) | 720 | 5 | 5 | 20 | **750** |

Sync polarity: positive for both. Refresh = 74.25 MHz ÷ (1650 × 750) = **60.00 Hz**.

**Pins** (from Sipeed's official 20K example; no conflict with the UART on 27/28 or the LEDs):

| Signal | Pins (P, N) |
|---|---|
| TMDS clock | 33, 34 |
| TMDS data 0 (blue + sync) | 35, 36 |
| TMDS data 1 (green) | 37, 38 |
| TMDS data 2 (red) | 39, 40 |

LEDs: LED 0 keeps the benchmark heartbeat; LED 5 = PLL locked.

### 6.4 Checks before the hardware (simulation)

All four Gowin blocks exist in Gowin's simulation library, so H1 can be simulated in Icarus
Verilog down to the serial bits on the HDMI wires:

| Check | Pass if |
|---|---|
| Timing counters | exactly 1650 × 750 per frame; sync pulses at the positions in the table |
| TMDS encoder | a Python reference decoder turns every 10-bit word back into the original byte; the running 1s/0s balance stays bounded |
| Serial output | decoding the simulated serial bit stream on the 3 data pins gives back the test-pattern colours |

### 6.5 On the hardware

1. Build (`fpga_fft/build.sh` with the new top) and check timing passes at 74.25 and 371.25 MHz.
2. Karn connects the 20K's HDMI socket to the monitor and selects that input.
3. Program the 20K (SRAM).
4. Karn reports what the monitor shows.

| Pass criteria |
|---|
| The monitor shows a picture, and its info menu reports **1280×720 at 60 Hz** |
| 8 bars in the right order and colours; border visible on all four edges; smooth grey ramp |
| The square moves smoothly; no flicker, sparkles or dropouts over one minute |
| The ESP32 benchmark still passes (`fft_bench.py fpga-echo -r 2`) |

| If… | Likely cause | Next |
|---|---|---|
| "No signal" | PLL not locked, pins, or the monitor rejects the timing | LED 5 shows lock; check timing numbers; try another input/cable |
| Colours swapped | Colour channels in the wrong order | Swap in `hdmi_out.v` |
| Border missing on some edges | Monitor overscan | Monitor menu: "Just Scan" / "1:1" / "PC" mode |
| Sparkles or a shaky picture | Signal quality or clock | Shorter cable; check timing slack |

### 6.6 Deliverables

- The H1 Verilog and simulation (`fpga_fft/sim/tb_hdmi.v` + Python TMDS checker)
- Build results (resources, timing) and a photo/description of the screen
- A report section: how HDMI sends a picture, the clocks, the result
