# Multi-Protocol IoT Gateway for FPGA Platforms

> Capstone project. An FPGA captures real-time audio from a MEMS microphone and streams
> it to a host PC through an ESP32-S3 gateway — first over **UART**, then over **SPI**,
> so the two transports can be measured against each other under identical load.

**Status:** **M1–M3 complete.** The chain works, reports its own losses honestly, and both
serial links have been characterised to their limits.

| link | proven limit | capacity | nature of the limit |
|------|--------------|----------|---------------------|
| 1. FPGA → ESP32 | **13.5 Mbaud** (18 Mbaud fails) | 1,350,000 B/s | physical — bits stop resolving |
| 2. ESP32 → host | **6 Mbaud** | 600,000 B/s | software — the macOS driver refuses to open the port |

End-to-end ceiling **600,000 B/s**, set by link 2. Two INMP441s produce 190,063 B/s — 31.7 %
of it — so **UART is not this project's bottleneck at audio rates**, and the case for SPI
rests on headroom and scalability rather than a measured failure.

Next: the ESP32-S3's **native USB**, which removes link 2's software cap entirely.

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
┌───────────┐  I2S   ┌──────────────────┐ link 1  ┌───────────┐  link 2   ┌──────────┐
│  INMP441  │ ─────▶ │  Tang Nano 4K    │ ──────▶ │ ESP32-S3  │ ────────▶ │  MacBook │
│ MEMS mic  │ SCK    │  GW1NSR-4C       │  UART   │  gateway  │  UART0 →  │  viewer  │
│  L/R→GND  │ WS  SD │  PLL 27→54 MHz   │ 2 Mbaud │  (pump)   │  CH9102   │  Python  │
└───────────┘        └──────────────────┘ 1 wire  └───────────┘  2 Mbaud  └──────────┘
                                                        │
                                                        └── native USB also present,
                                                            not yet used for data
```

| Stage    | Hardware                  | Role                                                  |
|----------|---------------------------|-------------------------------------------------------|
| Sense    | INMP441 I2S MEMS mic      | 24-bit digital audio, left channel                    |
| Capture  | Tang Nano 4K (GW1NSR-4C)  | I2S master, truncate to 16-bit, frame, serialize      |
| Gateway  | ESP32-S3                  | Transparent UART → USB-CDC pump (later: SPI, Wi-Fi)   |
| Analyze  | MacBook Air               | Live waveform + FFT, drop/error statistics            |

## How it works

**Clocking.** A Gowin PLLVR turns the 27 MHz crystal into **54 MHz** (IDIV ÷1, FBDIV ×2,
ODIV 16). Everything else is an exact integer divide of that:

```
fs = 54 MHz / (64 × N)     BCLK = 54 MHz / N     UART = 54 MHz / CLK_PER_BIT
```

`N` (`BCLK_DIV`) is the only knob that sets the sample rate; `N = 56` gives the current
15,067 Hz and `N = 18` the maximum 46,875 Hz (`BCLK` must stay under the INMP441's 3.2 MHz).
Because it is a plain integer divide, **every** value of `N` is exact and jitter-free —
"round" rates like 15 kHz have no accuracy advantage over 31.25 kHz.

The clock was 24 MHz through M1-M3 and was raised to 54 MHz so that link 1 could be tested
above 12 Mbaud; at 24 MHz the only rates available above 6 Mbaud were 8 and 12, which was too
coarse to locate a ceiling. **The system clock travels to the host inside every frame**, so
raising it cannot silently rescale a measurement.

**Capture.** `i2s_master_rx.v` runs a textbook **64-BCLK I2S frame** (32 clocks per
channel). It reads the **full 24-bit left-channel word** MSB-first, then keeps the top
16 bits and discards the 8 LSBs. The capture window starts at `CAP_START = 2`, a value
validated by simulation against known bit patterns.

**Framing.** `framer.v` emits a **1038-byte** frame per 512 samples: a 4-byte sync word, an
8-byte header (`seq`, `ovf`, `cfg`, and the header's own checksum), the payload, and a 2-byte
payload checksum. Bytes go through a 64-byte FIFO that decouples the bursty producer from the
steady UART drain — and every byte that FIFO has to discard is counted, so loss can never be
silent. Framing bytes hold reserved space in that FIFO, so under overload the link sacrifices
audio and stays measurable. See [`docs/05-instrumentation.md`](docs/05-instrumentation.md).

**Transport.** `uart_tx.v` sends 8N1 at 2 Mbaud. The ESP32-S3 forwards bytes verbatim —
frames already carry their own sync, so the gateway needs no protocol awareness.

## Repository layout

```
fpga/          Gowin EDA project (i2s_capture.gprj) and Verilog sources
  src/         i2s_master_rx.v, framer.v, uart_tx.v, top.v, top.cst, gowin_pllvr/
  sim/         Icarus Verilog testbenches; run_sims.sh runs them all
  build.tcl    command-line synthesis + place & route (gw_sh)
firmware/      Arduino sketches for the ESP32-S3 gateway
  reference/   earlier experiments kept for comparison
host/          inmp441_viewer.py — live viewer and link analyser
docs/          glossary, requirements, architecture, protocol, results, plans, diary
data/          measurement runs (CSV) — gitignored
tools/         summarize_run.py, probe_port.py, read_diag.py, sweep*.sh, split_runs.py
```

## Tools

| tool | what it does |
|------|--------------|
| `tools/summarize_run.py` | reduce a run CSV to the numbers that go in a report |
| `tools/probe_port.py` | raw byte rate and sync-word presence, before any parsing |
| `tools/read_diag.py` | read the gateway's own diagnostics; says which link failed |
| `tools/sweep.sh` | build, program and capture one point per `BCLK_DIV` |
| `tools/sweep_baud.sh` | same, sweeping link 2's baud instead |
| `tools/sweep_link.sh` | find each link's top speed as an error rate |
| `tools/split_runs.py` | repair a CSV that accidentally holds two runs |
| `tools/test_viewer_parser.py` | offline test of the host parser, no hardware |

## Quick start

**FPGA** — open `fpga/i2s_capture.gprj` in Gowin EDA, synthesize, place & route, program.

**ESP32-S3** — `firmware/fpga_uart_bridge/fpga_uart_bridge.ino`. Board `ESP32S3 Dev Module`,
**USB CDC On Boot: Disabled** (so `Serial` is UART0 → the CH9102 bridge), upload speed 921600.

From the command line, which is what the sweep scripts use:

```
arduino-cli compile --upload -b esp32:esp32:esp32s3 -p /dev/cu.wchusbserial... \
            firmware/fpga_uart_bridge
```

`compile --upload`, never bare `upload` — `upload` alone re-flashes a cached binary and will
silently ignore your edits.

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
- **M2 — Instrumentation (done).** Sequence numbers, FIFO overflow counters, payload and
  header checksums, host-side drop/error statistics, and a verdict naming the stage that lost
  the data. Proven in all three states: silent when healthy, accurate when overloaded (0.5 %
  error), silent again afterwards. See [`docs/05-instrumentation.md`](docs/05-instrumentation.md).
- **M3 — Load sweep (done).** Three phases: raise demand at fixed capacity, lower capacity at
  fixed demand, and characterise each link's top speed. The knee sits **exactly at capacity**
  and failure is a cliff — 3 % over costs 30 % of the audio, 27 % over costs all of it.
  See [`docs/09-results.md`](docs/09-results.md).
- **M3-D — Link limits (done).** Link 1 proven to 13.5 Mbaud; link 2 capped at 6 Mbaud by the
  macOS driver. See [`docs/plans/m3d-uart-limit.md`](docs/plans/m3d-uart-limit.md).
- **M3-F — Native USB (next).** Measure the ESP32-S3's built-in USB against the CH9102 path,
  to find the best route for link 2.
- **M4 — SPI transport.** Replace UART with SPI and re-run the identical sweep.
- **M5 — Wi-Fi.** Same frames over UDP, for the "gateway" half of the project.

Details in [`docs/04-roadmap.md`](docs/04-roadmap.md).

## Documentation

- [`docs/00-glossary.md`](docs/00-glossary.md) — **every term used in this project, explained.**
- [`docs/01-requirements.md`](docs/01-requirements.md) — what the system must do.
- [`docs/02-hardware.md`](docs/02-hardware.md) — boards, pinout, wiring, part limits.
- [`docs/03-protocol.md`](docs/03-protocol.md) — on-wire frame format.
- [`docs/04-roadmap.md`](docs/04-roadmap.md) — milestones with checkboxes.
- [`docs/05-instrumentation.md`](docs/05-instrumentation.md) — **how loss is measured and
  localised**: concept, block diagram, the three counters, and the simulation results.
- [`docs/06-architecture.md`](docs/06-architecture.md) — module-by-module design.
- [`docs/07-bringup.md`](docs/07-bringup.md) — **how to program the board and run the null test**.
- [`docs/08-troubleshooting.md`](docs/08-troubleshooting.md) — problems hit and fixes.
- [`docs/09-results.md`](docs/09-results.md) — **every hardware run that produced a number.**
- [`docs/plans/m3-load-sweep.md`](docs/plans/m3-load-sweep.md) — **the load sweep: hypotheses, predictions, procedure.**
- [`docs/plans/m3d-uart-limit.md`](docs/plans/m3d-uart-limit.md) — **how fast can the UART chain actually go?**
- [`docs/plans/`](docs/plans/) — implementation and experiment plans (idea, hypothesis,
  method, predictions, results).
- [`docs/reports/`](docs/reports/) — weekly progress reports, with a template.

## Simulation

Everything is simulated before it reaches hardware:

```
./fpga/sim/run_sims.sh          # needs: brew install icarus-verilog
```

`tb_framer` checks the frame format and puts the overflow counter through a positive
control (stall the drain, count the drops independently, demand agreement). `tb_chain`
runs the full datapath against a behavioural INMP441 model at every sample rate in the
planned sweep.
