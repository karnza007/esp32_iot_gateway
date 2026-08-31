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

| `N` | BCLK | fs | 1-ch wire rate | % of link 1 | **% of link 2** |
|-----|------|----|----------------|-------------|-----------------|
| 25  | 960 kHz | 15.000 kHz  | 30.4 kB/s | 15 % | 33 % |
| 20  | 1.2 MHz | 18.750 kHz  | 37.9 kB/s | 19 % | 41 % |
| 16  | 1.5 MHz | 23.4375 kHz | 47.4 kB/s | 24 % | 51 % |
| 12  | 2.0 MHz | 31.250 kHz  | 63.2 kB/s | 32 % | 69 % |
| 10  | 2.4 MHz | 37.500 kHz  | 75.9 kB/s | 38 % | 82 % |
| **8** | **3.0 MHz** | **46.875 kHz** | **94.8 kB/s** | 47 % | **103 %** |

Wire rate = `fs / 512 x 1036` bytes/s (frame v2, one channel).

## THERE ARE TWO SERIAL LINKS, AND THE SECOND IS THE TIGHTER ONE

This was missed until hardware bring-up and it changes the experiment.

```
FPGA ──── link 1 ────▶ ESP32-S3 ──── link 2 ────▶ host
       UART 2 Mbaud              UART0 921600 baud
       = 200,000 B/s             -> CH9102 -> USB
                                 = 92,160 B/s     <-- the real ceiling
```

Both links are ordinary 8N1 UARTs, so both cost 10 bits per byte:

| link | baud | capacity |
|------|------|----------|
| 1. FPGA -> ESP32 (`CLK_PER_BIT` in `top.v`, `FPGA_BAUD` in the sketch) | 2,000,000 | 200,000 B/s |
| 2. ESP32 -> host (`Serial.begin()` in the sketch, `BAUD` in the viewer) | 921,600 | **92,160 B/s** |

Earlier documents quoted 200 kB/s as "the UART capacity". That is link 1 only. **The chain
saturates at 92 kB/s**, wherever the data has to pass through both.

### What this changes

- **A single microphone CAN saturate the chain.** At `BCLK_DIV = 8` one channel produces
  94.8 kB/s against a 92.2 kB/s ceiling — 103 %. No second microphone required.
- **The failure will be `GATEWAY LOSS (ESP32/USB)`, not `LINK SATURATED (FPGA FIFO)`.**
  The FPGA's FIFO drains happily into the 2 Mbaud link 1; the backlog forms inside the
  ESP32, which cannot push bytes out of link 2 fast enough. `ovf` should stay at 0 while
  `seq` gaps appear — precisely the distinction the instrumentation was built to make.
- **Link 2 can be raised later.** Either a higher `Serial.begin()` baud, or switching the
  ESP32-S3 to its native USB CDC (`USB CDC On Boot: Enabled`), which is not baud-limited at
  all. Doing that moves the bottleneck back to link 1 and is itself a result worth plotting.

With a second microphone the numbers double, so `BCLK_DIV = 8` two-channel would be
189.7 kB/s — 95 % of link 1 and 206 % of link 2.

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
