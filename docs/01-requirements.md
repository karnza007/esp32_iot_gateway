# 01 — Requirements

## Purpose

Demonstrate an FPGA acting as a high-rate sensor front-end behind an ESP32-S3 gateway,
and **measure** the point at which each transport protocol stops being adequate.

The audio is a means, not the end. Audio is chosen because it produces a continuous,
uninterruptible, easily-scaled data stream whose corruption is both audible and
quantifiable — an ideal load for stressing a link.

## Functional requirements

| # | Requirement |
|---|-------------|
| F1 | The FPGA shall act as I2S master, generating BCLK and WS for the microphone. |
| F2 | The FPGA shall use a standard **64-BCLK** I2S frame (32 clocks per channel). |
| F3 | The FPGA shall read the full 24-bit channel word and truncate to the top 16 bits. |
| F4 | The sample rate shall be derived by integer division of the system clock, so it is exact and jitter-free for **any** divider value. |
| F5 | The sample rate shall be changeable by editing a single top-level parameter. |
| F6 | Data shall be framed with a sync word so a receiver can lock on mid-stream. |
| F7 | Each frame shall carry enough metadata for the host to detect and quantify loss. |
| F8 | The gateway shall forward frames without interpreting them, so it does not become a variable in the measurement. |
| F9 | The host shall display live waveform and spectrum, and report link statistics. |
| F10 | The transport shall be replaceable (UART → SPI → Wi-Fi) without changing the capture logic or the host analysis. |

## Non-functional requirements

| # | Requirement |
|---|-------------|
| N1 | Single clock domain in the FPGA; all asynchronous inputs synchronized. |
| N2 | No silent data loss — every discarded byte shall be counted. |
| N3 | Measurements shall be reproducible: parameters recorded in the data stream itself. |
| N4 | Loss shall be attributable to a stage (FPGA FIFO vs. gateway vs. host). |
| N5 | Modules shall be simulated before hardware bring-up. |

## Constraints

| # | Constraint | Source |
|---|-----------|--------|
| C1 | SCK ≤ 3.2 MHz → sample rate ≤ 46.875 kHz at a 24 MHz system clock | INMP441 datasheet |
| C2 | WS ≥ 7.8 kHz | INMP441 datasheet |
| C3 | UART 8N1 at 2 Mbaud = 200 kB/s usable | 10 bits per byte |
| C4 | ESP32-S3 UART + CH9102 bridge unreliable much beyond 2–3 Mbaud | practical limit |
| C5 | Tang Nano 4K has 2 PLLs; one is in use | GW1NSR-4C |
| C6 | Gowin PLLVR reset is **active high** | Gowin IP |

## Out of scope

- Audio quality as a product goal — the microphone is a load generator, not a feature.
- Real-time playback on the host.
- Compression of any kind; it would confound the throughput measurement.
