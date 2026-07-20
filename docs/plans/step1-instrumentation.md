# Plan — Step 1: Instrumentation

**Status:** awaiting review
**Milestone:** M2
**Prerequisite for:** M3 (load sweep), M4 (SPI comparison)

---

## 1. Why this comes first

The rate sweep in M3 is meant to produce a **drop-rate-vs-data-rate curve**. Right now
that measurement is impossible: the 32-byte FIFO in `framer.v` discards bytes silently
when it fills, and the host viewer simply resynchronizes on the next sync word. A run at
`N = 8` would look like "the audio sounds bad" rather than "we lost 3.7 % of frames, all
of them inside the FPGA FIFO."

Every number the capstone report needs — drop rate, where loss occurs, whether the FPGA
or the gateway is at fault — depends on counters that do not exist yet. So they get built
before the rate goes up, and they get validated at the **current** rate where we already
know the answer is zero.

## 2. Frame format v2

Current v1 frame is 4-byte sync + 1024-byte payload = 1028 bytes.

| Offset | Size | Field | Type | Meaning |
|--------|------|-------|------|---------|
| 0 | 4 | `sync` | — | `AA 55 A5 5A`, unchanged |
| 4 | 2 | `seq` | uint16 LE | frame counter, free-running, wraps at 65536 |
| 6 | 2 | `ovf` | uint16 LE | cumulative FIFO overflow **byte** count, saturating at 65535 |
| 8 | 2 | `cfg` | uint16 LE | `[7:0]` = `N`, `[9:8]` = channel count, `[15:10]` reserved (0) |
| 10 | 1024 | `payload` | 512 × int16 LE | audio samples |
| 1034 | 2 | `checksum` | uint16 LE | additive sum of the 1024 payload bytes, mod 2^16 |

**Frame = 1036 bytes.** Header overhead rises from 0.39 % to 1.16 % — negligible against
the throughput we are measuring, and it does not shift the saturation point meaningfully.

**Design notes**

- `seq` wraps. The host computes the gap modulo 65536, which is correct as long as fewer
  than 65536 consecutive frames are lost — at ~29 frames/s that is a 37-minute blackout,
  far beyond any realistic loss burst.
- `ovf` is **sticky and monotonic**, never cleared. The host plots deltas. Saturating
  rather than wrapping means a pegged 65535 is unambiguous ("massively overflowing")
  instead of aliasing back to a small number.
- `cfg` is sampled from top-level parameters at elaboration, not hardcoded in `framer.v`.
  This makes each captured CSV self-describing: the sweep point is recorded in the data.
- The checksum is a plain additive sum, not CRC. It cannot detect reordering and is weak
  against certain multi-error patterns, but it costs one adder and it catches the failure
  mode we actually expect (dropped or corrupted bytes inside a frame). A CRC-16 is a
  reasonable upgrade later if integrity turns out to be interesting on its own.

## 3. FPGA changes — `fpga/src/`

### `framer.v`

- **Depth 32 → 64 bytes.** Pointers widen 6 → 7 bits. Justification: at the eventual
  worst case (`N = 8`, 2 channels) the producer emits 4 bytes per 21.33 µs while the UART
  drains 1 byte per 5 µs — 94 % occupancy. The 10-byte header burst must fit in the
  remaining slack, and 32 bytes leaves no margin for the burst plus jitter.
- **`seq_q[15:0]`** — increments once per completed frame, at the same point the sample
  index wraps 511 → 0.
- **`ovf_q[15:0]`** — increments (saturating) each time a push is attempted while `full`.
  Critically, the byte is still *counted* even though it is *dropped*.
- **`sum_q[15:0]`** — additive checksum accumulated over payload bytes as they are
  enqueued; reset at the start of each frame.
- **Emission order** per frame: `sync(4) → seq(2) → ovf(2) → cfg(2) → payload(1024) →
  checksum(2)`.
- The header snapshot (`seq`, `ovf`) is latched at frame start so a mid-frame overflow
  is reported in the *next* frame rather than corrupting the current header. This makes
  the semantics unambiguous: "`ovf` as of the beginning of this frame."
- New port `cfg_i[15:0]`, driven from `top.v`.

### `i2s_master_rx.v`

- Expose the BCLK divider as a parameter `BCLK_DIV` (currently the literal `25`) so a
  sweep point is a one-line change at the top level.
- The half-period comparison becomes `i2s_sck = (div_cnt < (BCLK_DIV+1)/2)` so odd and
  even dividers both work.
- `CAP_START = 2` unchanged — it is validated and independent of `BCLK_DIV`.

### `top.v`

- Parameters `BCLK_DIV = 25`, `NUM_CH = 1`.
- Assemble `cfg = {6'b0, NUM_CH[1:0], BCLK_DIV[7:0]}` and pass it to `framer`.
- No pin changes; `top.cst` is untouched.

## 4. Host changes — `host/inmp441_viewer.py`

- Parse the 10-byte header and 2-byte trailer.
- Derive `SAMPLE_RATE = 24e6 / (64 × N)` from `cfg` instead of the hardcoded constant.
  The FFT axis then follows the sweep automatically.
- Verify the checksum; count mismatches, and **do not** plot a corrupt frame.
- Maintain and print once per second:
  - **frame drop rate** — from `seq` gaps
  - **FPGA overflow** — delta of `ovf` per interval
  - **checksum error rate** — bad frames / frames received
  - **delivered throughput** — bytes/s at the host
  - **resync events** — how often the sync scan had to run
- Append each one-second line to `data/run-<timestamp>.csv` for later plotting.
- Surface the diagnostic explicitly in the status line, since it is the actual result:

  | `ovf` | `seq` gaps | printed verdict |
  |-------|-----------|-----------------|
  | 0 | none | `OK` |
  | > 0 | present | `LINK SATURATED (FPGA FIFO)` |
  | 0 | present | `GATEWAY LOSS (ESP32/USB)` |
  | 0 | none, checksum errors | `SIGNAL INTEGRITY` |

## 5. Simulation — `fpga/sim/`

`tb_framer.v`, run under Icarus Verilog (`iverilog -g2012`):

1. **Header layout** — feed a known sample sequence; assert the emitted byte stream
   matches the v2 table byte-for-byte.
2. **Checksum** — assert the trailer equals the independently computed sum of the payload.
3. **Sequence** — assert `seq` increments by exactly 1 per frame and wraps correctly.
4. **Overflow** — hold `tx_ready` low to stall the UART, then assert that `ovf` equals
   the number of bytes the testbench knows were dropped. This is the test that matters;
   an overflow counter that is itself wrong would silently invalidate every M3 result.
5. **Regression** — re-run the existing full-chain test (mic model → UART decode) against
   v2 and confirm the payload is bit-identical to v1.

## 6. Hardware verification

1. **Null test at `N = 25`.** Program and run at today's rate. Expect **0 drops, 0
   overflow, 0 checksum errors**, ~31 kB/s, and audio identical to before. This proves
   the instrumentation did not itself introduce loss.
2. **Positive control.** Deliberately raise `CLK_PER_BIT` so the UART runs far too slow
   for the sample rate. Expect `ovf` to climb and the drop rate to track it, with the
   verdict reading `LINK SATURATED (FPGA FIFO)`. A counter that never fires is
   indistinguishable from a counter that is broken — this test removes that ambiguity.
3. **Restore** `CLK_PER_BIT = 12` and re-confirm the null test.

## 7. Acceptance criteria

- [ ] All five simulation checks pass.
- [ ] Null test at `N = 25`: zero drops, zero overflow, zero checksum errors, sustained.
- [ ] Positive control: counters respond and the verdict string is correct.
- [ ] A CSV lands in `data/` with one row per second and a parseable header.
- [ ] `docs/03-protocol.md` v2 section promoted from "proposed" to "implemented".

## 8. Open questions for review

1. **Checksum — keep or drop?** It costs a little logic and 2 bytes per frame. It is the
   only way to separate *integrity* from *loss*. Recommendation: **keep** — the
   distinction is worth a paragraph in the report.
2. **FIFO depth 64 — enough?** 64 is comfortable for the 10-byte header burst at 94 %
   occupancy. Going to 128 costs almost nothing on this device. Recommendation: 64, and
   revisit if the positive-control test shows overflow at rates we expected to survive.
3. **`seq` width.** 16 bits is ample at 29 frames/s. Left as-is.
4. **Should the ESP32 also count?** Adding a byte counter on the gateway would let us
   localize loss even more precisely (FPGA → ESP32 link vs. ESP32 → host link). It breaks
   the "dumb pump" property slightly. Recommendation: **defer** — the `ovf` + `seq`
   combination already distinguishes the two failure modes we care about.
