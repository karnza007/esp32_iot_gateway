# 06 — Architecture

## Clock tree

```
27 MHz crystal (pin 45)
   └─▶ Gowin PLLVR  (IDIV ÷9, FBDIV ×8, reset active-high)
          └─▶ 24 MHz  ──┬─▶ i2s_master_rx : ÷N      → BCLK, ÷(64N) → WS/fs
                        └─▶ uart_tx       : ÷12     → 2 Mbaud
       lock ─────────────▶ combined with the reset button: rst_n = rst & pll_lock
```

Everything downstream of the PLL is a synchronous integer divide of a single 24 MHz
domain. There is exactly one clock domain in the design; the only asynchronous input is
`i2s_sd`, which is passed through a 2-flip-flop synchronizer.

## Module: `i2s_master_rx.v`

Standard Philips I2S master. The FPGA generates both clocks; the microphone only ever
drives data.

- **`div_cnt` 0 … N-1** produces BCLK: `i2s_sck = (div_cnt < ceil(N/2))`. With `N = 25`
  the duty is 13/12 ≈ 52 % — asymmetric, but far inside the INMP441's 50 ns minimum
  high/low time.
- **`bit_cnt` 0 … 63** advances once per BCLK period. `i2s_ws = (bit_cnt >= 32)`, so WS
  low is the first half of the frame = the **left** channel (L/R tied to GND).
- **Data capture** happens at `div_cnt == 6`, comfortably inside the BCLK high phase and
  well after the microphone's output has settled. Bits shift in MSB-first:
  `word24 <= {word24[22:0], sd_sync}`.
- **Capture window** is `bit_cnt ∈ [CAP_START, CAP_START+23]`. I2S specifies a one-BCLK
  delay after the WS edge, so nominally `CAP_START = 1`; simulation against known bit
  patterns (`A5A5`, `8000`, `7FFF`, `1234`) showed **`CAP_START = 2`** reproduces
  full-scale values exactly, and that is the committed default.
- **Truncation** to 16 bits: `sample <= word24[23:8]`, dropping the 8 LSBs. `sample_valid`
  pulses for one 24 MHz cycle at the end of the window.

The remaining ~39 BCLKs of the frame are still clocked out normally. The microphone
requires a full 64-clock frame; we simply ignore the part we do not need.

## Module: `framer.v`

Turns a stream of samples into a stream of bytes, and absorbs the rate mismatch.

- Counts samples 0 … 511. At index 0 it enqueues the sync word first, then the sample.
- Each sample is enqueued **low byte then high byte** (little-endian int16).
- A byte FIFO sits between the producer and `uart_tx`. Independent read and write
  pointers mean the producer and consumer run **concurrently** — this is what makes the
  stream continuous, and it is why a single FIFO suffices here. Ping-pong (double)
  buffering solves a different problem: block-at-a-time handoff to a DMA engine, which
  is where it will become relevant in the SPI milestone.
- Occupancy is `count = wptr - rptr`, which works correctly across pointer wrap because
  the pointers carry one extra bit beyond the address width.

**Sizing.** Current depth is 32 bytes. At the eventual worst case (`N = 8`, 2 channels)
the producer emits 4 bytes every 21.33 µs while the UART drains 1 byte every 5 µs — 20 µs
of drain per 21.33 µs of production, i.e. **94 % occupancy with very little slack**. The
sync burst has to fit in what is left. The instrumentation plan raises the depth to 64
and, more importantly, **counts** overflows instead of discarding data silently.

## Module: `uart_tx.v`

Four-state FSM: `IDLE → START → DATA → STOP`. Bit period is `CLK_PER_BIT = 12` cycles of
24 MHz = 2 Mbaud exactly. Data goes out LSB-first, 8N1, with a `tx_valid` / `tx_ready`
handshake so the framer never has to know the baud rate.

## Module: `top.v`

Instantiates the PLL, holds the rest of the design in reset until `pll_lock` asserts
(`rst_n = rst & pll_lock`), and wires `i2s_master_rx → framer → uart_tx`. Parameters that
define the experiment — the BCLK divider and the UART divider — are set here so a rate
sweep is a one-line edit at the top level.

## ESP32-S3 gateway

Deliberately dumb. `Serial1` reads the FPGA at 2 Mbaud on GPIO18; whatever arrives is
written verbatim to `Serial` (UART0 → CH9102 → host) at 921600. Because frames carry
their own sync word, the gateway needs no protocol knowledge and adds no framing of its
own — it is a pure byte pump, which keeps it out of the measurement as a variable.

Later milestones replace only this stage: SPI slave with DMA, then Wi-Fi UDP. The FPGA
and the host analysis stay identical, which is what makes the transport comparison fair.

## Host viewer

A background thread resynchronizes on the sync word, reads a fixed-size payload, and
publishes the latest frame under a lock. The matplotlib animation reads whatever is
current — deliberately **not** a queue, because for a live display a dropped frame is
better than a growing backlog. The FFT uses a Hann window normalized by the window sum,
so magnitudes are comparable across runs, and the magnitude axis is fixed (not
auto-scaled) so amplitude changes are visible rather than normalized away.
