# 12 — HDMI demo: live microphone spectrum on a monitor

Plan: `docs/plans/hdmi-demo.md`. Requested by the advisor after the FFT benchmark report:
microphone → Tang Nano 20K → Gowin FFT → spectrum on a monitor over the board's HDMI port.

| Step | What | Status |
|---|---|---|
| **H1** | Colour test pattern at 1280×720, 60 Hz | ✅ 2026-10-09 |
| H2 | Spectrum of a test tone generated inside the FPGA | planned |
| H3 | Live spectrum from the INMP441 microphone | — |
| H4 | Gridlines, kHz/dB labels, peak readout | — |

---

## 1. How HDMI sends a picture

**A frame is more than the visible picture.** After every line and every frame comes invisible
*blanking* time. It's a leftover from CRT monitors (the beam needed time to fly back), and it is
where the sync pulses live: **HSYNC** = "new line", **VSYNC** = "new frame". The exact totals are
fixed by the standard (CEA-861), which is how a monitor recognises the format:

```
 ◀──────────────────────── 1650 slots per line ─────────────────────────▶
 ┌──────────────────────────────────────┬──────┬──────┬──────────────────┐ ▲
 │                                      │front │ sync │   back porch     │ │
 │        VISIBLE PICTURE 1280 × 720    │porch │  40  │      220         │ │ 720 lines
 │                                      │ 110  │      │                  │ │
 ├──────────────────────────────────────┴──────┴──────┴──────────────────┤ ▼
 │  vertical blanking: 5 front porch + 5 sync + 20 back porch = 30 lines │
 └───────────────────────────────────────────────────────────────────────┘
   1280 + 370 = 1650 slots per line,   720 + 30 = 750 lines per frame
```

**Each pixel travels as bits.** A pixel is 3 colours × 8 bits. HDMI has one wire pair per
colour; each 8-bit value is coded into a **10-bit TMDS word** and sent one bit after another,
bit 0 first. A fourth pair carries the clock.

**TMDS coding** (DVI 1.0, `src/hdmi/tmds_encoder.v`) solves two problems of a fast cable:
1. *Fewer transitions:* the byte is rewritten as an XOR (or XNOR) chain, whichever toggles
   less; bit 8 records which.
2. *Balance of 1s and 0s:* a running count of "1s minus 0s" is kept, and a word is sent
   inverted when the count leans one way; bit 9 records the inversion.

During blanking, one of four fixed control words is sent instead; on the blue lane they carry
HSYNC and VSYNC. The monitor undoes both steps, so the colours arrive unchanged.

## 2. The clocks: why 371.25 MHz is fine

```
 27 MHz crystal ─▶ rPLL ×55 ÷4 ─▶ 371.25 MHz ─────────────▶ 4 × OSER10 serializers ONLY
                                      └─▶ CLKDIV ÷5 ─▶ 74.25 MHz ─▶ timing, pattern, TMDS encoders
 27 MHz crystal ──────────────────────────────────────────▶ ESP32 UART benchmark (unchanged)
```

| Clock | Calculation | Used by |
|---|---|---|
| **74.25 MHz** pixel clock | 1650 × 750 slots × 60 frames | everything that makes the picture |
| **371.25 MHz** serializer clock | 74.25 M pixels × 10 bits = 742.5 Mbit/s per wire; sent on both clock edges → ÷2 | only the 4 serializers |

- **OSER10** is a serializer built into the pin's I/O block: it takes 10 bits once per pixel and
  shifts them out at the fast clock. It is designed for this speed; our own logic never sees
  that clock (like a cashier handing 10 coins at a time to a fast coin machine).
- **TLVDS_OBUF** drives each serial bit as a differential pair (P/N), as HDMI needs.
- PLL: VCO = 371.25 × 2 = 742.5 MHz (allowed 500–1250). The same numbers as Sipeed's official
  20K HDMI example, whose pin list (33–40) is also used here.
- **No IP core was generated**: rPLL, CLKDIV, OSER10 and TLVDS_OBUF are Gowin built-in blocks
  used directly in Verilog.

## 3. H1: colour test pattern

### 3.1 The picture

| Element | Checks |
|---|---|
| 8 colour bars (white, yellow, cyan, green, magenta, red, blue, black) | each colour lane wired correctly |
| 1-pixel white border | the whole 1280×720 is visible, nothing cropped |
| grey ramp, black → white | all 8 bits of each colour arrive |
| moving 40×40 square (4 px per frame) | the picture is live |

### 3.2 Simulation first, down to the serial bits

`fpga_fft/sim/tb_hdmi.v` runs the picture chain with **Gowin's own models** of CLKDIV and OSER10
and records every bit leaving the 4 lanes (2 frames, ~25 million bits, ~2.5 min in Icarus).
`fpga_fft/sim/check_hdmi.py` then decodes the stream **like a monitor**: word alignment from the
clock lane, TMDS decoding, sync recovery, and a pixel-by-pixel comparison.

| Check (complete frame between two VSYNCs) | Result |
|---|---|
| clock lane = 5 zeros + 5 ones per pixel | ✅ 100 % |
| 720 visible lines × 1280 pixels; 1650 slots/line; 750 lines/frame | ✅ exact |
| HSYNC 40, front porch 110, back porch 220 | ✅ exact |
| VSYNC 5 lines, starting at line 725, slot 1390, together with HSYNC | ✅ exact |
| DC balance within each line, all 3 lanes | ✅ worst running 1s − 0s: 9 |
| **every visible pixel decoded back to the expected colour** | ✅ **0 of 921,600 differ** |

Found and fixed on the way:
1. **VSYNC started one slot after HSYNC** (it passed through one register too many). The
   standard starts them together. Fixed in `video_timing.v`.
2. The moving square stepped once per clock during reset (`frame_start` wasn't gated by
   reset), so it started at x = 84 instead of 4. Cosmetic; fixed.
3. Gowin's CLKDIV model only starts counting after a low-to-high step on `RESETN`. On the
   chip, `RESETN` is the PLL's lock signal, which does exactly that; the testbench now mimics it.

### 3.3 Build and hardware result

| | Value |
|---|---|
| Logic / registers | 2,046 (10 %) / 789, including the ESP32 benchmark |
| Pixel clock | needs 74.25 MHz, timing met up to 93.3 MHz |
| Benchmark clock | needs 27 MHz, met up to 83.9 MHz |
| ESP32 benchmark inside the HDMI build | echo 26 / 26 ✅ |
| **Monitor (4K, 27")** | **picture exactly as designed; monitor reports 1280×720 @ 60 Hz** ✅ |

The 4K monitor scales the picture itself: 3840 ÷ 1280 = 2160 ÷ 720 = 3, so each pixel is shown
as a clean 3×3 block.

```bash
DESIGN=hdmi fpga_fft/build.sh program          # build + load the HDMI design
iverilog -g2012 -s tb_hdmi -o /tmp/tb_hdmi fpga_fft/sim/tb_hdmi.v fpga_fft/src/hdmi/*.v \
    /Applications/GowinIDE.app/Contents/Resources/Gowin_EDA/IDE/simlib/gw2a/prim_sim.v
vvp /tmp/tb_hdmi +out=/tmp/hdmi_bits.txt && python fpga_fft/sim/check_hdmi.py /tmp/hdmi_bits.txt
```
