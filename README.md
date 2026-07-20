# Multi-Protocol IoT Gateway for FPGA Platforms

> Capstone project. An FPGA captures real-time audio from a MEMS microphone and streams
> it to a host PC through an ESP32-S3 gateway — first over **UART**, then over **SPI**,
> so the two transports can be measured against each other under identical load.

**Status:** **Milestone 1 — UART path working (verified end-to-end).**
INMP441 → Tang Nano 4K → ESP32-S3 → Python live viewer. Measured 30,120 B/s on the
wire (15 kHz × 2 bytes), sync every 1028 bytes, real audio confirmed.

---

## Overview

The project answers a concrete engineering question: **when does a simple UART link stop
being good enough for streaming sensor data, and what exactly breaks first?**

An FPGA is a natural high-rate data source — it can sample and frame faster than a
general-purpose MCU link can carry. By steadily raising the audio data rate (higher
sample rate, more microphone channels) we push the UART path until it fails, measure
*where* and *how* it fails, then replace the transport with SPI and repeat the same
measurements. The audio itself is the payload; the transport comparison is the result.

## Signal chain

```
┌───────────┐  I2S   ┌──────────────────┐  UART   ┌───────────┐  USB-CDC  ┌──────────┐
│  INMP441  │ ─────▶ │  Tang Nano 4K    │ ──────▶ │ ESP32-S3  │ ────────▶ │  MacBook │
│ MEMS mic  │ SCK    │  GW1NSR-4C       │ 2 Mbaud │  gateway  │  921600   │  viewer  │
│  L/R→GND  │ WS  SD │  PLL 27→24 MHz   │  1 wire │ (pump)    │           │  Python  │
└───────────┘        └──────────────────┘         └───────────┘           └──────────┘
```

| Stage    | Hardware                  | Role                                                  |
|----------|---------------------------|-------------------------------------------------------|
| Sense    | INMP441 I2S MEMS mic      | 24-bit digital audio, left channel                    |
| Capture  | Tang Nano 4K (GW1NSR-4C)  | I2S master, truncate to 16-bit, frame, serialize      |
| Gateway  | ESP32-S3                  | Transparent UART → USB-CDC pump (later: SPI, Wi-Fi)   |
| Analyze  | MacBook Air               | Live waveform + FFT, drop/error statistics            |

## How it works

**Clocking.** A Gowin PLLVR turns the 27 MHz crystal into **24 MHz** (IDIV ÷9, FBDIV ×8).
Everything else is an exact integer divide of that:

```
fs   = 24 MHz / (64 × N)      BCLK = 24 MHz / N       UART = 24 MHz / 12 = 2 Mbaud
```

`N` is the only knob that sets the sample rate. `N = 25` gives the current 15.000 kHz.
Because it is a plain integer divide, **every** value of `N` is exact and jitter-free —
"round" rates like 15 kHz have no accuracy advantage over 31.25 kHz.

**Capture.** `i2s_master_rx.v` runs a textbook **64-BCLK I2S frame** (32 clocks per
channel). It reads the **full 24-bit left-channel word** MSB-first, then keeps the top
16 bits and discards the 8 LSBs. The capture window starts at `CAP_START = 2`, a value
validated by simulation against known bit patterns.

**Framing.** `framer.v` prepends a 4-byte sync word every 512 samples and pushes bytes
into a small FIFO that decouples the bursty producer from the steady UART drain.

**Transport.** `uart_tx.v` sends 8N1 at 2 Mbaud. The ESP32-S3 forwards bytes verbatim —
frames already carry their own sync, so the gateway needs no protocol awareness.

## Repository layout

```
fpga/          Gowin EDA project (i2s_capture.gprj) and Verilog sources
  src/         i2s_master_rx.v, framer.v, uart_tx.v, top.v, top.cst, gowin_pllvr/
  sim/         Icarus Verilog testbenches
firmware/      Arduino sketches for the ESP32-S3 gateway
  reference/   earlier experiments kept for comparison
host/          Python live viewer and analysis tools
docs/          requirements, architecture, protocol, roadmap, plans, diary
data/          measurement runs (CSV) — gitignored
tools/         helper scripts
```

## Quick start

**FPGA** — open `fpga/i2s_capture.gprj` in Gowin EDA, synthesize, place & route, program.

**ESP32-S3** — open `firmware/fpga_uart_bridge/fpga_uart_bridge.ino` in the Arduino IDE.
Board `ESP32S3 Dev Module`, **USB CDC On Boot: Disabled** (this board talks through a
CH9102 bridge, so `Serial` is UART0), upload speed 921600.

**Host**

```
cd ~/Capstone-Project
python3 -m venv .venv && source .venv/bin/activate
pip install -r requirements.txt
python host/inmp441_viewer.py          # auto-detects the wchusbserial port
```

## Wiring

| INMP441 | Tang Nano 4K | Note                          |
|---------|--------------|-------------------------------|
| VDD     | 3V3          |                               |
| GND     | GND          |                               |
| L/R     | GND          | selects the **left** channel  |
| SCK     | pin 39       | bit clock, FPGA drives        |
| WS      | pin 40       | word select, FPGA drives      |
| SD      | pin 41       | serial data, FPGA reads       |

| Tang Nano 4K | ESP32-S3 | Note                       |
|--------------|----------|----------------------------|
| pin 42 (TX)  | GPIO18   | UART, 2 Mbaud, 8N1         |
| GND          | GND      | **common ground required** |

## Roadmap

- **M1 — UART path (done).** Single channel, 15 kHz, 16-bit, live viewer.
- **M2 — Instrumentation (next).** Sequence numbers, FIFO overflow counters, payload
  checksum, host-side drop/error statistics. See
  [`docs/plans/step1-instrumentation.md`](docs/plans/step1-instrumentation.md).
- **M3 — Load sweep.** Add a second microphone; sweep `N` = 25 → 8 and record drop rate
  and SNR/THD at each point until the UART link saturates.
- **M4 — SPI transport.** Replace UART with SPI (FPGA master, ESP32-S3 DMA slave) and
  re-run the identical sweep for a direct comparison.
- **M5 — Wi-Fi.** Same frames over UDP, for the "gateway" half of the project.

Details in [`docs/04-roadmap.md`](docs/04-roadmap.md).

## Documentation

- [`docs/01-requirements.md`](docs/01-requirements.md) — what the system must do.
- [`docs/02-hardware.md`](docs/02-hardware.md) — boards, pinout, wiring, part limits.
- [`docs/03-protocol.md`](docs/03-protocol.md) — on-wire frame format.
- [`docs/04-roadmap.md`](docs/04-roadmap.md) — milestones with checkboxes.
- [`docs/06-architecture.md`](docs/06-architecture.md) — module-by-module design.
- [`docs/08-troubleshooting.md`](docs/08-troubleshooting.md) — problems hit and fixes.
- [`docs/plans/`](docs/plans/) — implementation plans awaiting review.
