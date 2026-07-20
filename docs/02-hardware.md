# 02 — Hardware

## Boards and parts

| Part | Detail |
|------|--------|
| FPGA board | Tang Nano 4K, Gowin **GW1NSR-4C**, package QN48 (`GW1NSR-LV4CQN48PC6/I5`) |
| Crystal | 27 MHz on pin 45 |
| PLL | Gowin **PLLVR** IP, 27 → 24 MHz (IDIV ÷9, FBDIV ×8). Reset is **active-high**. Two PLLs available on this device; one is used. |
| Microphone | InvenSense **INMP441**, 24-bit I2S MEMS |
| Gateway | ESP32-S3 dev module, **CH9102** USB-UART bridge |
| Host | MacBook Air (macOS), Python 3.14 |

## INMP441 limits (from the datasheet)

| Parameter | Min | Max | Consequence |
|-----------|-----|-----|-------------|
| SCK (bit clock) | 0.5 MHz | **3.2 MHz** | caps the sample rate — see below |
| WS (frame rate) | 7.8 kHz | — | lower bound on `N` sweep |
| SCK high/low time | 50 ns | — | the ÷25 odd-divider duty (13/12, ~52 %) is fine |

**The 3.2 MHz SCK ceiling sets the maximum sample rate.** With a 24 MHz system clock and
a 64-BCLK frame, `BCLK = 24 MHz / N` must stay ≤ 3.2 MHz, so `N ≥ 8`:

| `N` | BCLK | fs = 24 MHz / (64·N) | 1 ch payload | 2 ch payload | % of 2 Mbaud UART |
|-----|------|----------------------|--------------|--------------|-------------------|
| 25  | 960 kHz | 15.000 kHz  | 30 kB/s   | 60 kB/s   | 30 % |
| 20  | 1.2 MHz | 18.750 kHz  | 37.5 kB/s | 75 kB/s   | 38 % |
| 16  | 1.5 MHz | 23.4375 kHz | 47 kB/s   | 94 kB/s   | 47 % |
| 12  | 2.0 MHz | 31.250 kHz  | 62.5 kB/s | 125 kB/s  | 63 % |
| 10  | 2.4 MHz | 37.500 kHz  | 75 kB/s   | 150 kB/s  | 75 % |
| **8** | **3.0 MHz** | **46.875 kHz** | 94 kB/s | **187.5 kB/s** | **94 %** |

UART capacity: 2,000,000 baud ÷ 10 bits per byte (8N1) = **200 kB/s** usable.

`N = 8` with two channels is the intended saturation point of the experiment.

## Pinout (`fpga/src/top.cst`)

| Signal | Pin | Direction | IO settings |
|--------|-----|-----------|-------------|
| `clk` | 45 | in | LVCMOS33, PULL_MODE=UP — 27 MHz crystal |
| `rst` | 14 | in | PULL_MODE=UP — onboard button S1, **active low** |
| `i2s_sck` | 39 | out | LVCMOS33, DRIVE=8 |
| `i2s_ws` | 40 | out | LVCMOS33, DRIVE=8 |
| `i2s_sd` | 41 | **in** | LVCMOS33, PULL_MODE=NONE |
| `uart_tx` | 42 | out | LVCMOS33, DRIVE=8 |
| `lock_out` | 43 | out | LVCMOS33, DRIVE=8 — PLL lock, for scope/LED |

## Wiring

```
INMP441            Tang Nano 4K              ESP32-S3
────────           ────────────              ────────
VDD  ────────────  3V3
GND  ────────────  GND  ──────────────────── GND      ← common ground, required
L/R  ────────────  GND        (left channel)
SCK  ────────────  pin 39
WS   ────────────  pin 40
SD   ────────────  pin 41
                   pin 42  ───────────────── GPIO18   (UART RX, 2 Mbaud 8N1)
```

Both boards are powered from the MacBook over separate USB cables. The common ground
between them is **not optional** — without it the UART receiver sees noise.

## Known bridge limits (why SPI comes later)

The FPGA can trivially generate 4 Mbaud (÷6) or 6 Mbaud (÷4) — it is an integer divide.
The practical ceiling lives downstream:

- ESP32-S3 UART receiver: reliable to roughly 2–3 Mbaud.
- CH9102 USB-serial bridge: similar range, and adds host-side buffering latency.

So when the link saturates, the FPGA is expected to be idle-capable while the gateway
side drops data. Distinguishing these two failure modes is the point of the
instrumentation in [`plans/step1-instrumentation.md`](plans/step1-instrumentation.md).
