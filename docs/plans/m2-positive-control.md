# Experiment M2-PC — Positive control for the overflow counter

**Status:** first attempt run 2026-08-31 — it FOUND A REAL DESIGN FLAW; re-run pending
**Date planned:** 2026-08-31
**Depends on:** M2 null test (PASS, `data/run-n25-null.csv`)

---

## 1. Idea

The instrumentation added in M2 reports how many bytes the FPGA had to throw away. So far
that counter has only ever read **0**, across two hardware runs totalling nearly four
minutes.

A reading of 0 is ambiguous. It means either:

- **nothing was lost** — the healthy case, or
- **the counter is dead** — stuck, mis-wired, or optimised away in synthesis.

Those two are indistinguishable from the data collected so far, and the entire M3 load
sweep depends on telling them apart. A dead counter would report `ovf = 0` during genuine
saturation, and the viewer would blame the ESP32 for loss the FPGA actually caused.

So: **overload the link deliberately and check that the counter reacts.**

This is a *positive control* — a test whose job is to make a detector fire, confirming it
can fire at all. It is the complement of the null test, which confirmed the detector stays
quiet when it should.

## 2. Hypothesis

> **H1.** If the FPGA's UART is slowed below the rate at which the framer produces bytes,
> the FIFO will fill, bytes will be discarded, and `ovf` will increase at a rate equal to
> the shortfall between production and drain.
>
> **H2.** The host will attribute the loss to the FPGA, reporting the verdict
> `LINK SATURATED (FPGA FIFO)` — not `GATEWAY LOSS (ESP32/USB)`.

**H0 (what would falsify this):** `ovf` stays at 0 while frames are visibly lost. That
would mean the counter does not work and every M3 measurement would be untrustworthy.

## 3. Method

One variable changes: the speed of **link 1** (FPGA → ESP32). Everything else is held at
the null-test configuration.

| Setting | Null test | This test |
|---------|-----------|-----------|
| `BCLK_DIV` (`fpga/src/top.v`) | 25 | 25 — unchanged |
| Sample rate | 15.000 kHz | 15.000 kHz — unchanged |
| **`CLK_PER_BIT` (`fpga/src/top.v`)** | **12** | **96** |
| **`FPGA_BAUD` (ESP32 sketch)** | **2000000** | **250000** |
| `Serial.begin` (link 2) | 921600 | 921600 — unchanged |

`CLK_PER_BIT` and `FPGA_BAUD` describe the same wire and **must always be changed
together**; if they disagree the ESP32 decodes noise and the test measures nothing.

```
                        THE VARIABLE                     held constant
   INMP441 ──I2S──▶ FPGA ═══ link 1 ═══▶ ESP32-S3 ─── link 2 ───▶ host
   15 kHz            │      250,000 baud              921,600 baud
   unchanged         │      = 25,000 B/s              = 92,160 B/s
                     │           ▲
                     │           │  demand is 30,352 B/s
                  framer FIFO    │  supply is  25,000 B/s
                  64 bytes       │  ── deficit 5,352 B/s ──▶ must overflow
                     │
                     └─▶ ovf counter increments once per discarded byte
```

**Arithmetic.** Link 1 carries `250,000 baud / 10 bits per byte = 25,000 B/s`. The framer
produces `15,000 / 512 x 1036 = 30,352 B/s`. The FIFO can absorb a transient, never a
sustained deficit, so it must saturate and discard the difference.

## 4. Predictions

| Quantity | Predicted | Basis |
|----------|-----------|-------|
| `ovf` growth | **~5,350 bytes/s** | 30,352 − 25,000 |
| `ovf` wrap period | ~12 s | 65536 / 5352 |
| bytes lost per frame | ~183 of 1036 (18 %) | 5352 / 29.3 frames per second |
| **`frames_ok`** | **near 0** | see below |
| checksum errors | ~25–29 per second | almost every frame is hit |
| resync events | high | frames arrive short, so alignment is lost each time |
| delivered payload | **~0 B/s** | no frame survives intact |
| **verdict** | **`LINK SATURATED (FPGA FIFO)`** | `ovf` rising |

**`frames_ok ≈ 0` is a PASS, not a failure.** A sustained 18 % byte loss spread across
every frame means essentially no frame arrives intact. Zero usable audio delivered is the
correct and expected outcome of overloading the link this hard — and "0 B/s of usable audio
at 83 % of required capacity" is itself a reportable result.

## 5. Pass criteria

The test passes if **all three** hold:

1. `ovf` climbs steadily — the counter can count.
2. Verdict reads `LINK SATURATED (FPGA FIFO)` — the loss is attributed to the FPGA.
3. Restoring `CLK_PER_BIT = 12` / `FPGA_BAUD = 2000000` returns the system to a clean null
   test — the overload was the cause, and nothing was damaged.

The test **fails** if `ovf` stays at 0 while frames are lost. Stop and debug before M3.

## 6. Procedure

```bash
# 1. edits are already applied; confirm them
grep -n 'CLK_PER_BIT = ' fpga/src/top.v                     # expect 96
grep -n 'FPGA_BAUD '  firmware/fpga_uart_bridge/fpga_uart_bridge.ino   # expect 250000

# 2. Gowin: Place & Route, then Program
# 3. Arduino IDE: upload the sketch

# 4. capture 60 s
source .venv/bin/activate
python host/inmp441_viewer.py --csv data/run-positive-control.csv

# 5. reduce to reportable numbers
python tools/summarize_run.py data/run-positive-control.csv

# 6. restore and re-verify
git checkout -- fpga/src/top.v firmware/fpga_uart_bridge/fpga_uart_bridge.ino
#    rebuild + reprogram both, then:
python host/inmp441_viewer.py --csv data/run-n25-null-after.csv
python tools/summarize_run.py data/run-n25-null-after.csv
```

## 7. Results

*(fill in after the run; paste the `summarize_run.py` output)*

| run | s | frames ok | lost | drop % | cksum err | ovf bytes | resync | wire B/s | % link2 | verdict |
|-----|---|-----------|------|--------|-----------|-----------|--------|----------|---------|---------|
| | | | | | | | | | | |

**Observed vs predicted `ovf` rate:** ______ B/s (predicted 5,350)

**Verdict correct?** ☐ yes ☐ no

**Restored null test clean?** ☐ yes ☐ no

## 8. Notes / deviations

The first attempt did not produce the predicted numbers. It produced something better: it
found a fault that would have made the entire M3 sweep unmeasurable.

### 8.1 Baud mismatch (operator error, quickly found)

The FPGA was reprogrammed to 250,000 baud but the ESP32 sketch had only been *edited*, not
*uploaded*, so it still listened at 2,000,000. Every byte was misread.

`CLK_PER_BIT` and `FPGA_BAUD` describe the same wire and must always be flashed together.
**One physical parameter configured in two places is a design weakness of the UART
transport** — one that SPI partly removes, because the FPGA drives the clock and the
receiver is never told the rate in advance.

### 8.2 The viewer refused to run under saturation

Startup waited for one checksum-valid frame. At an 18 % byte-loss rate no frame is ever
intact, so the viewer timed out having reported nothing — it refused to run in exactly the
condition it exists to measure. §4 of this plan predicted `frames_ok ≈ 0`; the code
contradicted the plan.

Fixed: a frame with a corrupt payload can start the run if its **header** is plausible, and
statistics are now reported independently of whether there is any audio to draw.

### 8.3 THE REAL FINDING: under sustained overload the framing destroys itself

With the baud rates matched, a raw port probe (`tools/probe_port.py`) showed:

```
  bytes received   126,976 in 5.1 s  ->  24,957 B/s
  sync words found 0
```

**24,957 B/s is exactly link 1's capacity** — the link was working perfectly and running
flat out. Yet in five seconds **not one sync word arrived**.

The cause is a priority inversion in `framer.v`:

| | |
|---|---|
| UART byte time at 250 kbaud | 10 × 96 = **960 clocks** |
| I2S sample period at `BCLK_DIV=25` | 64 × 25 = **1600 clocks** |
| drain capacity per sample period | 1600 / 960 = **1.67 bytes** |
| production per sample period | **2 bytes** |
| deficit | 0.33 bytes per sample → **the FIFO sits permanently full** |

The header is pushed as **10 bytes in 10 consecutive clock cycles**. During those 10
cycles the UART drains 10/960 = **0.01 bytes**. No space is created, so the entire header —
sync word included — is discarded on **every single frame**.

The audio bytes survive because they trickle in two at a time, spread over 1600 cycles.
So the stream degrades in exactly the wrong direction: **the payload survives and the
framing dies.** The receiver can then never lock on, never read `seq`, `ovf` or `cfg`, and
the loss becomes unmeasurable at precisely the moment it matters most.

### 8.4 Fix: framing bytes get reserved FIFO space

`framer.v` now classifies every push as framing or audio (`push_hdr`). Audio bytes are
refused once occupancy reaches `FIFO_DEPTH - HDR_RESERVE` (48 of 64); framing bytes may use
the full depth. `HDR_RESERVE = 16` covers the 10-byte header plus the 2-byte checksum with
margin.

The stream now degrades the right way round: **audio is sacrificed, framing is not.**

Regression test `tb_framer` T4 reproduces the hardware condition — a sustained drain slow
enough that the deficit exceeds the FIFO depth — and requires the sync words to survive:

```
T4: sustained overload — sync words must still get through
  161 bytes out, 62 dropped, 8 sync words (8 frames offered)     HDR_RESERVE = 16  -> PASS
  175 bytes out, 48 dropped, 4 sync words (8 frames offered)     HDR_RESERVE = 0   -> FAIL
```

The test genuinely discriminates: half the frames lose their sync word without the fix.

### 8.5 Host: frames are now delimited by the sync word, not by a fixed length

Because overload makes frames arrive **short**, a fixed-length read after each sync would
run past the next sync word, swallow a frame, and report the overrun as loss that never
happened. The reader now splits the stream on sync words, so **the length of each frame is
itself a measurement**: `bytes_missing = 1036 − observed`, which cross-checks directly
against the `ovf` field in the header.

New reported quantities: `frames_short` and `bytes_missing`.

### 8.6 What this is worth

This is the strongest result the project has produced so far, and it came from a test whose
only job was to check that a counter could count:

> A naive framer loses its own framing before it loses its data. Under sustained overload
> the header — the part that makes loss measurable — is the part most likely to be
> discarded, because it is pushed as a burst into a permanently-full buffer. Measured on
> hardware: 24,957 B/s of audio delivered and zero sync words in five seconds. Giving
> framing bytes reserved buffer space inverts the priority, so the link degrades by losing
> audio while remaining measurable.

### 8.7 Re-run required

`framer.v` changed, so the FPGA must be re-synthesised and re-programmed before the
positive control can be completed. The predictions in §4 stand, with one addition:
`frames_short` should be ~29/s and `bytes_missing` ~5,350 B/s, matching the `ovf` rate.
