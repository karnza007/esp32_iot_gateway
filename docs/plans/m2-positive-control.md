# Experiment M2-PC — Positive control for the overflow counter

**Status:** planned, not yet run
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

**Two host-side bugs found while attempting the first run (2026-08-31).** Both were in the
viewer, not the hardware, and both were caused by the same wrong assumption: that a
measurement run always contains at least one intact frame.

1. **Baud mismatch.** The FPGA was reprogrammed to 250,000 baud but the ESP32 sketch had
   only been *edited*, not *uploaded*, so it was still listening at 2,000,000. Every byte
   was misread and no sync word was ever found. `CLK_PER_BIT` and `FPGA_BAUD` describe the
   same wire and must always be flashed together — the same physical parameter configured
   in two places is a design weakness of the UART transport, and one that SPI partly avoids
   because the FPGA drives the clock and the receiver is not told the rate in advance.

2. **The viewer refused to start under saturation — the exact condition it was built to
   measure.** Startup waited for one checksum-valid frame before proceeding. At an 18 %
   byte-loss rate no frame is ever intact, so the program timed out and exited having
   reported nothing. The prediction table in §4 said `frames_ok ≈ 0` and the startup path
   contradicted it; the plan was right and the code was wrong.

   Fixed: a frame whose payload fails its checksum can still start the run if its **header**
   is plausible (`plausible_cfg()` sanity-checks `BCLK_DIV`, channel count and the reserved
   bits). Statistics are now reported before, and independently of, the audio plot, so the
   numbers appear even when there is no intact audio to draw. The failure message also
   distinguishes "no bytes at all" from "bytes arriving but mangled", which points straight
   at a baud mismatch.

   Regression test added: `tools/test_viewer_parser.py` now includes a fully-saturated
   stream in which **no** frame is intact, and asserts the reader still starts, still
   recovers `cfg`, and still returns the correct verdict.
