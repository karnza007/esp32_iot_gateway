# 05 — Instrumentation: measuring how much data the link loses, and where

**Status:** implemented, simulated, not yet run on hardware
**Milestone:** M2
**Files:** `fpga/src/framer.v`, `fpga/src/i2s_master_rx.v`, `fpga/src/uart_tx.v`,
`fpga/src/top.v`, `fpga/sim/tb_framer.v`, `fpga/sim/tb_chain.v`,
`host/inmp441_viewer.py`

---

## 1. Overview in one paragraph

The FPGA now stamps every frame it sends with three extra numbers: a **frame number**,
a **count of bytes it had to throw away**, and a **checksum of the audio**. The host reads
those numbers and can therefore say, once per second, exactly how much data went missing,
whether what arrived was intact, and — the part that matters — **which piece of hardware
lost it**. Nothing about the audio changed. What changed is that failure is now a number
instead of a complaint.

---

## 2. Why we built it

### The problem with the old design

Version 1 of the frame was a 4-byte sync word followed by 1024 bytes of audio. It worked,
and it was verified running at 30,120 bytes per second. But it had a blind spot.

Inside the FPGA there is a small buffer (a FIFO) between the part that builds bytes and
the UART that sends them. If bytes arrive at that buffer faster than the UART can drain
it, the buffer fills up and **the extra bytes are simply discarded**. Nothing recorded it.
On the host side, the viewer would notice its byte stream no longer lined up, scan forward
until it found the next sync word, and carry on — displaying audio that was subtly wrong,
with no indication that anything had been lost.

That is fine when the link is running at 15 % capacity, which is where it has been. It
becomes fatal the moment we do the actual experiment.

### The experiment this enables

The plan is to raise the data rate step by step until the UART link breaks, then replace
it with SPI and show the improvement. The deliverable is a curve: **data rate on the x
axis, loss on the y axis.**

You cannot plot a curve of something you cannot measure. Without these counters, running
at the highest rate would produce the observation *"the audio sounds bad"*. With them, it
produces *"at 187.5 kB/s we lost 3.7 % of frames, all of them inside the FPGA's own
buffer."* The first is an anecdote. The second is a result.

### The question the counters actually answer

There is a subtler reason, and it is the one that justifies the whole SPI milestone.

When data goes missing, there are **two completely different possible culprits**:

- The **FPGA's buffer overflowed** — the UART wire itself is the bottleneck.
- The **FPGA was fine**, but the ESP32 or the USB bridge could not keep up — the wire had
  spare capacity and something downstream dropped the data.

These look identical from the host: audio with holes in it. They have opposite fixes. And
distinguishing them is precisely the argument for moving to SPI, so the report needs
evidence, not a guess. The `ovf` counter is what separates them: it is incremented **inside
the FPGA**, so a non-zero value is a confession from the FPGA that the loss happened there.

---

## 3. Block diagram

Where the new logic sits in the existing datapath:

```
   INMP441                     TANG NANO 4K  (one 24 MHz clock domain)
  ┌─────────┐   I2S    ┌────────────────────────────────────────────────────┐
  │  MEMS   │  SCK ◀───┤                                                      │
  │  mic    │  WS  ◀───┤  i2s_master_rx          framer.v            uart_tx  │
  │ L/R→GND │  SD  ───▶│  ┌──────────────┐   ┌──────────────────┐  ┌────────┐ │
  └─────────┘          │  │ 64-BCLK I2S  │   │ ① build bytes    │  │  8N1   │ │
                       │  │ read 24 bit  │──▶│   header+payload │  │ 2 Mbaud│ │
                       │  │ keep top 16  │ 1 │   +checksum      │  │        │ │
                       │  │              │sam│        │         │  │        │ │
                       │  │ BCLK_DIV ────┼───┼─▶ ② FIFO 64×8 ───┼─▶│        │─┼──▶ ESP32
                       │  └──────────────┘   │        │         │  └────────┘ │   GPIO18
                       │                     │   full? ──▶ ovf++ │             │
                       │                     └──────────────────┘             │
                       └────────────────────────────────────────────────────┘
                                                     │
                                  ┌──────────────────┘  1036-byte frames
                                  ▼
                        ┌───────────────────┐        ┌────────────────────────┐
                        │     ESP32-S3      │  USB   │  inmp441_viewer.py     │
                        │  byte pump only   │───────▶│  check sync + checksum │
                        │  (no protocol     │  CDC   │  seq gaps → drop rate  │
                        │   knowledge)      │        │  ovf delta → where     │
                        └───────────────────┘        │  → verdict + CSV       │
                                                     └────────────────────────┘
```

**Three things are new**, all shaded conceptually as "instrumentation":

1. In `framer.v`: the counters and the wider header/trailer.
2. In `top.v`: the sweep parameters, packed into a `cfg` word that ships with every frame.
3. In the viewer: the statistics engine and the verdict.

The ESP32 is deliberately untouched. It stays a dumb byte pump so that it cannot become a
hidden variable in the measurement.

---

## 4. Concept — the three new numbers, in plain terms

### `seq` — the frame number (detects loss)

Every frame is numbered: 0, 1, 2, 3, … The host remembers the last number it saw. If it
receives frame 9 right after frame 5, then frames 6, 7 and 8 never arrived — **three
frames lost.** That is the entire mechanism, and it is the only way to detect loss at all,
because a lost frame leaves no trace of itself.

It is a 16-bit number, so it wraps back to 0 after 65535. At ~29 frames per second that is
a 37-minute cycle, far longer than any loss burst we could confuse it with.

### `ovf` — the FPGA's own confession (localises the loss)

Inside the FPGA, every time a byte is pushed into a buffer that is already full, that byte
is dropped **and a counter goes up by one**. The counter is cumulative and never resets, so
the host just watches it climb.

This is the field that answers *"whose fault is it?"*:

| `ovf` | frames missing? | what it means |
|-------|-----------------|---------------|
| 0 | no | healthy |
| **rising** | yes | the FPGA's buffer overflowed → **the UART link is saturated** |
| 0 | yes | the FPGA kept up → **the ESP32 or USB bridge dropped it** |
| 0 | no, but bad checksums | electrical/signal problem, not a speed problem |

### `checksum` — the receipt (detects corruption)

The FPGA adds up all 1024 audio bytes and sends the total. The host adds them up again and
compares. Match → the frame is intact. Mismatch → something was corrupted or dropped
mid-frame, and the frame is counted as an error and not plotted.

Think of it as writing the total on the outside of an envelope of banknotes. The recipient
counts the contents; if the totals disagree, something happened, even though you cannot
tell *which* note went missing.

**Why it is worth 2 bytes:** loss and corruption are different failures with different
causes. Frames that never arrive point to a throughput problem. Frames that arrive mangled
point to a wiring or signal-integrity problem. Without a checksum you cannot tell your
advisor which one you are looking at.

*(Honest limitation: an additive sum is weak. If one byte rises by 5 and another falls by
5, the total is unchanged and the error slips through. A CRC-16 would catch that, at the
cost of more logic. The failure mode we actually expect — dropped or mangled bytes — is
caught reliably by a plain sum, so a sum is what we built.)*

### `cfg` — the frame describes its own conditions

The frame also carries the settings it was captured under: the clock divider and the
channel count. Two payoffs:

- The host **computes the sample rate itself** (`fs = 24 MHz / (64 × BCLK_DIV)`), so
  changing a sweep point is a one-line edit in the Verilog and the Python needs no change.
  Previously the two had to be edited in lockstep, which is exactly the kind of thing that
  silently corrupts a data set.
- Every recorded run is **self-describing**. A CSV from three weeks ago still says what it
  was measuring.

---

## 5. Frame format (v2)

```
 byte:  0    1    2    3  │ 4  5 │ 6  7 │ 8  9 │ 10 ............ 1033 │ 1034 1035
       ┌────┬────┬────┬────┼──────┼──────┼──────┼─────────────────────┼───────────┐
       │ AA │ 55 │ A5 │ 5A │ seq  │ ovf  │ cfg  │  512 × int16 LE     │ checksum  │
       └────┴────┴────┴────┴──────┴──────┴──────┴─────────────────────┴───────────┘
        └──── sync ─────┘   └──── header ──────┘  └──── payload ─────┘  └ trailer ┘
                                                                                    
        total 1036 bytes                      all multi-byte fields little-endian
```

| Field | Size | Meaning |
|-------|------|---------|
| `sync` | 4 | `AA 55 A5 5A` — lets a receiver lock on mid-stream |
| `seq` | 2 | frame counter, wraps at 65536 |
| `ovf` | 2 | cumulative FIFO overflow **bytes**, saturating at 65535 |
| `cfg` | 2 | `[7:0]` = `BCLK_DIV`, `[9:8]` = channels, `[15:10]` reserved (0) |
| `payload` | 1024 | 512 audio samples, int16 little-endian |
| `checksum` | 2 | sum of the 1024 payload bytes, mod 65536 |

**Overhead:** the header and trailer cost 12 bytes out of 1036 = **1.16 %** (up from
0.39 % in v1). At 15 kHz the wire rate becomes 30,352 B/s, up from the 30,120 B/s measured
previously — a difference small enough not to move the saturation point meaningfully.

---

## 6. How we built it — technical detail

### 6.1 `framer.v` — the producer state machine

The frame is emitted by a 15-state machine that pushes **one byte per clock cycle** at
24 MHz:

```
 IDLE ──sample_valid, and this is sample #0──▶ SY0 SY1 SY2 SY3   (4 sync bytes)
   │                                            │
   │                                            ▼
   │                                          SQ0 SQ1  OV0 OV1  CF0 CF1   (6 header)
   │                                            │
   │◀── sample #1..511 ────────────────────────┤
   ▼                                            ▼
  LO ──▶ HI ──┬── not the last sample ──▶ IDLE
              └── sample #511 ──▶ CK0 ──▶ CK1 ──▶ IDLE   (2 checksum bytes)
```

So a normal sample costs 2 cycles; the first sample of a frame costs 12 (10 header bytes
plus its own 2). Since the shortest sample period in the whole sweep is 512 clock cycles,
there is never a risk of one sample's burst colliding with the next.

**Header snapshotting.** `seq` and `ovf` are copied into `hdr_seq` / `hdr_ovf` the moment a
frame starts, and the header bytes are emitted from those copies. Without this, an overflow
occurring between the low and high byte of `ovf` would emit a torn value that never existed.
The semantics are therefore precise and stateable: **`ovf` is the overflow count as of the
first byte of this frame.**

**Checksum accumulation.** `sum_q` is zeroed at frame start and accumulates each payload
byte as it is pushed. Because Verilog's non-blocking assignment updates `sum_q` at the end
of the `HI` state, the value is already final by the time `CK0` reads it — no extra cycle
needed.

One deliberate subtlety: **a dropped byte is still added to the checksum.** The checksum is
a sum of what we *intended* to send. So a mid-frame drop shows up twice — as a short frame
(the host resynchronises) and as a checksum mismatch. Both signals are wanted; silence is
the only unacceptable outcome.

### 6.2 The overflow counter

```verilog
end else if (push) begin
    if (!full) begin
        mem[wptr[AW-1:0]] <= push_byte;
        wptr              <= wptr + 1'b1;
    end else if (ovf_q != 16'hFFFF) begin
        ovf_q <= ovf_q + 1'b1;          // dropped, but counted
    end
end
```

Three deliberate choices:

- **Saturating, not wrapping.** A pegged `0xFFFF` unambiguously means "massively
  overflowing". A wrapping counter could roll back to a small, innocent-looking number and
  make a catastrophic run look mild.
- **Sticky, never cleared.** The host plots the delta between frames. A counter the host
  could reset would create a race over who owns the value.
- **Counts bytes, not events.** Bytes are what the throughput budget is denominated in, so
  the number is directly comparable to the data rate.

### 6.3 FIFO depth — the honest arithmetic

The FIFO absorbs the difference between a **bursty producer** and a **steady drain**.

At the hardest planned sweep point (`BCLK_DIV = 8`, two channels):

| quantity | value |
|----------|-------|
| sample period | 21.333 µs = 512 clocks @ 24 MHz |
| bytes produced per sample period | 4 (two 16-bit channels) |
| UART time per byte | 10 bit periods × 12 clocks = 120 clocks = 5.0 µs |
| bytes drainable per sample period | 512 / 121 ≈ **4.23** |
| **slack** | ≈ **0.23 bytes per sample period** |

So the link runs at roughly **94 % utilisation**. When the 10-byte header burst lands, the
FIFO level jumps and then drains off at 0.23 bytes per sample period — about **43 sample
periods, ≈ 0.9 ms, to recover**. Peak occupancy during that window is around **14 bytes**.

**Which means 32 bytes would in fact have been sufficient.** We went to 64 anyway, and the
reason is honest insurance rather than necessity: at 94 % utilisation the slack is thin
enough that any small unmodelled effect — handshake overhead, a slightly different framing
when the second channel is added — could push it negative for a stretch, and on this device
the extra 32 bytes cost essentially nothing. Since the depth must stay **frozen across the
entire sweep** for the data points to be comparable, it is worth over-provisioning once now
rather than discovering a problem at sweep point four and having to redo points one to three.

**An important conceptual point:** FIFO depth only buffers *transients*. If the average
production rate exceeds the average drain rate, no depth is enough — the buffer merely
delays the inevitable. The FIFO is not a fix for saturation; the counters are there to
report saturation honestly when it happens.

The depth is a parameter (`FIFO_DEPTH`), and pointer widths derive from it via `$clog2`, so
the module is correct for any power-of-two depth.

### 6.4 `i2s_master_rx.v` — parameterised sample rate

The bit-clock divider was a hardcoded `25`. It is now the parameter `BCLK_DIV`, with the
two derived constants computed rather than written out:

```verilog
localparam integer SCK_HIGH  = (BCLK_DIV + 1) / 2;   // ceiling: odd dividers work
localparam integer SAMPLE_PT = (BCLK_DIV + 1) / 4;   // middle of the high phase
```

`SCK_HIGH` rounds up so odd dividers produce a valid, slightly asymmetric clock (with
`BCLK_DIV = 25`: 13 high / 12 low, ~52 % duty — far inside the INMP441's 50 ns minimum).
`SAMPLE_PT` places the data sample in the middle of the high phase for every divider in the
sweep:

| `BCLK_DIV` | high phase | sample at | fs |
|---|---|---|---|
| 25 | 0…12 | 6 | 15.000 kHz |
| 16 | 0…7 | 4 | 23.4375 kHz |
| 12 | 0…5 | 3 | 31.250 kHz |
| 10 | 0…4 | 2 | 37.500 kHz |
| 8 | 0…3 | 2 | 46.875 kHz |

`CAP_START = 2` is unchanged and is independent of `BCLK_DIV` — it is a phase offset
measured in bit clocks, not in system clocks.

**Why the sample rate need not be a round number.** `fs = 24 MHz / (64 × BCLK_DIV)` is a
plain integer divide of a crystal. Every value of `BCLK_DIV` gives an exact, jitter-free
rate. 31.25 kHz is derived by the same mechanism as 15 kHz and is exactly as accurate. Only
the label on the FFT axis cares — and since `cfg` now carries `BCLK_DIV` to the host, even
that takes care of itself.

### 6.5 `uart_tx.v` — a timer that can be slowed down

The bit timer was a fixed 4 bits, which caps `CLK_PER_BIT` at 15. It is now sized by
`$clog2(CLK_PER_BIT)`. This is not cosmetic: the **positive control test** for the overflow
counter works by setting `CLK_PER_BIT` very high, starving the drain, and confirming the
counter reacts. A counter that never fires is indistinguishable from a counter that is
broken, and that test needs a slow UART to exist.

### 6.6 `top.v` — the experiment knobs in one place

```verilog
module top_module #(
    parameter integer BCLK_DIV    = 25,   // fs = 24 MHz / (64 * BCLK_DIV)
    parameter integer CLK_PER_BIT = 12,   // baud = 24 MHz / CLK_PER_BIT
    parameter integer NUM_CH      = 1
) ( ... );

wire [15:0] cfg = {6'd0, NUM_CH[1:0], BCLK_DIV[7:0]};
```

A sweep point is now a single-line edit at the top of one file, and the value travels with
the data automatically. No pin changes; `top.cst` is untouched.

---

## 7. Simulation results

Both testbenches pass. Run them with `./fpga/sim/run_sims.sh`.

### `tb_framer.v` — format and counters

```
T1: frame layout, seq, cfg, checksum (fast drain)
  ok  (84 bytes, seq 0..2, ovf 0)
T2: stall the drain; every dropped byte must be counted
  ok  (48 bytes dropped, ovf_count = 48)
T3: resume drain; a later frame header must carry ovf = 48
  ok  (frame at byte 0, seq 7, ovf 48)

tb_framer: PASS
```

- **T1** checks every byte of three consecutive frames against the format table: sync,
  `seq` incrementing, `cfg`, all 16 payload bytes, and the checksum computed independently.
- **T2** is the positive control. The drain is stalled, the testbench counts drops itself by
  watching the DUT's push-into-full condition, and that independent count must equal
  `ovf_count`. **48 = 48.**
- **T3** proves the number reaches the host: after recovery, a checksum-valid frame carries
  `ovf = 48` in its header, and `seq` continued correctly across the outage.

*(T3 initially failed, correctly. The first checksum-valid frame after recovery was one
that had been built* before *the overflow and was still sitting in the FIFO — it truthfully
reported `ovf = 0`. The test was measuring the wrong frame, not the design. Fixed by
flushing the backlog before starting the capture.)*

### `tb_chain.v` — the whole datapath, at every sweep point

A behavioural INMP441 model (standard Philips I2S: data changes on the falling SCK edge,
MSB delayed one bit clock after the WS edge) feeds the real capture, framing and UART
logic. A UART decoder recovers the bytes, and the frame is parsed and compared against the
model's known words.

```
  BCLK_DIV=25  fs=  15.0000 kHz  tb_chain: PASS
  BCLK_DIV=20  fs=  18.7500 kHz  tb_chain: PASS
  BCLK_DIV=16  fs=  23.4375 kHz  tb_chain: PASS
  BCLK_DIV=12  fs=  31.2500 kHz  tb_chain: PASS
  BCLK_DIV=10  fs=  37.5000 kHz  tb_chain: PASS
  BCLK_DIV=8   fs=  46.8750 kHz  tb_chain: PASS
```

The payload matches the mic model **exactly** at every rate — `A5A5`, `8000`, `7FFF`,
`1234` — which simultaneously confirms the I2S bit alignment (`CAP_START = 2`), the
little-endian byte order, and the whole frame layout end to end.

The UART decoder in the testbench re-arms only during the stop bit, so a data bit that
happens to look like a start bit cannot trigger a false frame — the bug that previously
made a correct design look broken (see [`08-troubleshooting.md`](08-troubleshooting.md)).

### Host parser — offline test

The viewer's statistics engine was tested against a synthetic stream containing a
deliberate 3-frame gap, a reported overflow of 7 bytes, and one corrupted frame:

```
frames_ok = 5   frames_lost = 3   checksum_err = 1
ovf_delta = 7   drop_rate = 33.3%
verdict   = LINK SATURATED (FPGA FIFO)
fs derived from cfg = 15000.0 Hz, channels = 1
```

All values as expected, including the sample rate derived from `cfg` rather than hardcoded.

---

## 8. How to run it

**Simulate first** (no hardware needed):

```bash
cd ~/Capstone-Project
./fpga/sim/run_sims.sh
```

**Synthesise and program:** open `fpga/i2s_capture.gprj` in Gowin EDA, synthesise, place &
route, program. To change a sweep point, edit the parameter defaults at the top of
`fpga/src/top.v` and re-synthesise.

> Re-synthesise **and** re-program after every source edit. A stale bitstream once cost a
> full debugging session on this project — the giveaway was a clock reading 270 kHz when
> the design called for 960 kHz.

**ESP32-S3:** unchanged. `firmware/fpga_uart_bridge/fpga_uart_bridge.ino`, board
`ESP32S3 Dev Module`, **USB CDC On Boot: Disabled**.

**Host:**

```bash
source .venv/bin/activate
python host/inmp441_viewer.py                                   # live plot + stats
python host/inmp441_viewer.py --csv data/run-n25.csv            # also log to CSV
python host/inmp441_viewer.py --no-plot --seconds 60 --csv data/run-n8.csv
```

Once per second it prints:

```
  29 ok     0 lost (  0.00%)  ovf     0 (tot     0)  cksum   0    30.35 kB/s  [OK]
```

`--no-plot` is the mode to use for the actual sweep: no rendering overhead competing with
the serial reader, and a clean CSV per sweep point.

---

## 9. What to expect on hardware

**Null test at `BCLK_DIV = 25`** (today's rate — the point is to prove the instrumentation
changed nothing):

- 29.3 frames/s, **30,352 B/s** (up from 30,120 because of the 12 extra bytes per frame)
- zero drops, zero overflow, zero checksum errors, verdict `OK`
- audio identical to before

**Positive control:** raise `CLK_PER_BIT` (say to 48, a quarter of the baud rate) and
re-synthesise. `ovf` must climb, drops must appear, and the verdict must read
`LINK SATURATED (FPGA FIFO)`. Then restore `CLK_PER_BIT = 12` and confirm the null test
again. This proves the counters actually fire; without it, a broken counter and a healthy
link look the same.

---

## 10. What is deliberately not here

- **A second microphone channel.** That is M3. The frame already reports channel count in
  `cfg`, so the format does not need to change for it.
- **A CRC instead of a sum.** Considered and rejected for now — see §4.
- **Byte counting on the ESP32.** It would localise loss even more precisely (FPGA→ESP32
  link vs. ESP32→host link), but it breaks the "dumb pump" property that keeps the gateway
  out of the measurement. `ovf` plus `seq` already separates the two failure modes we care
  about. Revisit only if the data demands it.
