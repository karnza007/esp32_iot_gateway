# Experiment M3 — Load sweep: where does the UART chain actually break?

**Status:** planned
**Depends on:** M2 complete — the instrument is proven silent when healthy, accurate when
overloaded (0.5 % error), and silent again afterwards.

---

## 1. Idea

The project's central claim is that a UART gateway stops being adequate at some data rate,
and that SPI fixes it. So far that is an assertion. M3 turns it into a measured curve:
**how much data is lost, as a function of how much data is offered.**

The measuring instrument is now trustworthy, so the numbers it produces can be believed.

## 2. First: why was link 2 at 921,600 baud?

It was inherited, not chosen. 921,600 is a conventional "safely fast" rate for USB-serial
bridges, picked in M1 before anyone had worked out what data rate the system would need.
It was never justified by a measurement — and it turned out to be **less than half** of
link 1's 200,000 B/s, making it the true ceiling of the whole chain without anyone
noticing until bring-up.

Raising it to 2,000,000 baud makes both links 200,000 B/s, which is the right thing to do:
the experiment should measure **what UART can do**, not what an arbitrary default allowed.

**But it changes the experiment**, and this must be stated plainly:

| link 2 | capacity | max demand from ONE microphone | saturates? |
|--------|----------|-------------------------------|------------|
| 921,600 baud | 92,160 B/s | 94,849 B/s at `BCLK_DIV=8` | **yes, 103 %** |
| 2,000,000 baud | 200,000 B/s | 94,849 B/s at `BCLK_DIV=8` | **no, only 47 %** |

With both links at 2 Mbaud, **one INMP441 cannot saturate anything.** The microphone's own
3.2 MHz SCK limit caps it at 46.875 kHz, and that is only 47 % of the link.

That is not a dead end. It is a controlled experiment, run from both directions.

## 3. Hypotheses

> **H1 — headroom.** With link 2 at 2 Mbaud, sweeping `BCLK_DIV` from 25 to 8 will produce
> **no loss at any point**, because even the maximum single-channel rate is only 47 % of
> capacity.
>
> *Falsifier:* loss appears somewhere in the sweep. That would mean something other than
> raw capacity limits the chain — buffer sizes, interrupt latency, or the CH9102 failing to
> sustain 2 Mbaud — and finding it would be a more interesting result than H1 holding.

> **H2 — attribution.** With link 2 returned to 921,600, the identical FPGA sweep will lose
> data at `BCLK_DIV = 8` and nowhere else. Since only link 2 changed, the loss is caused by
> link 2.
>
> *Falsifier:* loss at the same points in both sweeps, or at `BCLK_DIV > 8`.

> **H3 — the verdict discriminates.** That loss will be reported as
> **`GATEWAY LOSS (ESP32/USB)`**, not `LINK SATURATED (FPGA FIFO)`, because link 1 is only
> 47 % loaded and the FPGA's FIFO never fills.
>
> *Falsifier:* `ovf` climbs. This is the **most valuable test in M3** — the
> `GATEWAY LOSS` verdict has never once fired, and until it does, the instrument's ability
> to tell the two failure modes apart is unproven in one direction.

> **H4 — capacity is measurable.** Holding `BCLK_DIV = 8` and lowering link 2's baud will
> locate a knee at **≈ 948,500 baud**, the point where capacity equals the 94,849 B/s
> demand.
>
> *Falsifier:* the knee is materially below 948,500 — which would mean the ESP32 or the
> CH9102 cannot deliver its nominal baud, and **that number is the real argument for SPI.**

## 4. Test structure

```
                  PHASE A & B: the variable is DATA RATE
  INMP441 ──I2S──▶ FPGA ─── link 1 ───▶ ESP32 ─── link 2 ───▶ host
   BCLK_DIV         2 Mbaud, fixed              A: 2 Mbaud
   25→8            = 200,000 B/s                B: 921,600
   ▲                                            ▲
   └── swept ───────────────────────────────────┘ one change between A and B

                  PHASE C: the variable is LINK CAPACITY
  INMP441 ──I2S──▶ FPGA ─── link 1 ───▶ ESP32 ═══ link 2 ═══▶ host
   BCLK_DIV = 8     2 Mbaud, fixed          2M→1.5M→1.2M→1M→921k→750k→500k
   fixed                                         ▲ swept
```

Phases A/B and phase C approach the same curve from opposite directions — one raises
demand against fixed capacity, the other lowers capacity against fixed demand. **If both
locate the same knee, the result is far stronger than either alone.**

Held constant throughout: `CLK_PER_BIT = 12`, `NUM_CH = 1`, `FIFO_DEPTH = 64`,
`HDR_RESERVE = 16`, frame format v2, one INMP441 on the left channel, 60 s per point.

## 5. Predictions

### Phase 0 — does link 2 even work at 2 Mbaud?

`BCLK_DIV = 25`, link 2 = 2,000,000. This is a null test at the new baud, run **before**
anything else: if the CH9102 cannot sustain 2 Mbaud, every later result would be
contaminated. Expect all counters 0 and 30,352 B/s, exactly as at 921,600.

*If this fails, it is not a setback — it is H4's falsifier arriving early, and it is the
strongest possible motivation for SPI.*

### Phase A — sweep `BCLK_DIV`, link 2 at 2 Mbaud

| `BCLK_DIV` | fs (Hz) | wire B/s | % link 1 | % link 2 | predicted |
|---|---|---|---|---|---|
| 25 | 15,000 | 30,352 | 15.2 | 15.2 | clean |
| 20 | 18,750 | 37,939 | 19.0 | 19.0 | clean |
| 16 | 23,438 | 47,424 | 23.7 | 23.7 | clean |
| 12 | 31,250 | 63,232 | 31.6 | 31.6 | clean |
| 10 | 37,500 | 75,879 | 37.9 | 37.9 | clean |
| 8 | 46,875 | 94,849 | 47.4 | 47.4 | clean |

Expected outcome: **a flat line at zero loss.** Unexciting, and that is the point — it
establishes that the FPGA and the frame format work correctly across a 3× range of sample
rates, so any loss seen in phase B is attributable to the one thing that changed.

### Phase B — identical sweep, link 2 at 921,600

| `BCLK_DIV` | wire B/s | % link 2 | predicted |
|---|---|---|---|
| 25 | 30,352 | 32.9 | clean |
| 20 | 37,939 | 41.2 | clean |
| 16 | 47,424 | 51.5 | clean |
| 12 | 63,232 | 68.6 | clean |
| 10 | 75,879 | 82.3 | clean — but the closest approach without failing |
| **8** | **94,849** | **102.9** | **LOSS, verdict `GATEWAY LOSS (ESP32/USB)`, `ovf` = 0** |

### Phase C — fix `BCLK_DIV = 8`, lower link 2's baud

Demand is 94,849 B/s throughout.

| link 2 baud | capacity B/s | demand as % | predicted |
|---|---|---|---|
| 2,000,000 | 200,000 | 47.4 | clean |
| 1,500,000 | 150,000 | 63.2 | clean |
| 1,200,000 | 120,000 | 79.0 | clean |
| 1,000,000 | 100,000 | 94.8 | marginal — expect the first losses here |
| **948,500** | **94,850** | **100.0** | **the predicted knee** |
| 921,600 | 92,160 | 102.9 | loss |
| 750,000 | 75,000 | 126.5 | heavy loss |
| 500,000 | 50,000 | 189.7 | severe; expect ~0 usable audio, as M2-PC showed |

**In every phase `ovf` should stay at 0.** Link 1 never exceeds 47 %, so the FPGA's FIFO
should never fill. Any non-zero `ovf` falsifies H3 and needs investigating before the
results can be trusted.

## 6. Procedure

Each point is 60 s. One setting changes at a time.

```bash
# --- changing BCLK_DIV (phases A and B) -------------------------------------
#   edit fpga/src/top.v, then Gowin: Place & Route -> Program
#   the ESP32 does NOT need re-uploading: BCLK_DIV does not affect either baud

# --- changing link 2 baud (between phases, and phase C) ----------------------
#   edit HOST_BAUD in firmware/fpga_uart_bridge/fpga_uart_bridge.ino
#   Arduino IDE: Upload
#   then pass the same number to the viewer with --baud

# --- capture one point -------------------------------------------------------
source .venv/bin/activate
python host/inmp441_viewer.py --no-plot --seconds 60 --baud 2000000 \
       --csv data/m3-A-div25.csv
python tools/summarize_run.py data/m3-A-div25.csv

# --- all points at once, once collected --------------------------------------
python tools/summarize_run.py --markdown data/m3-*.csv
```

`--no-plot` for every sweep point: no rendering competing with the serial reader, and a
clean CSV per point. Use the plot only for spot checks.

**Naming:** `data/m3-<phase>-<setting>.csv`, e.g. `m3-A-div8.csv`, `m3-B-div8.csv`,
`m3-C-baud1000000.csv`.

**Commit each sweep point deliberately**, naming its settings in the message. M2 ended with
a deliberately-broken configuration swept into a commit by a routine `git add -A`; the same
mistake here would silently mislabel a data point.

## 7. Results

*(fill in from `summarize_run.py --markdown`)*

### Phase 0 — link 2 at 2 Mbaud, null

| run | s | frames ok | lost | drop % | cksum err | ovf bytes | short | wire B/s | verdict |
|-----|---|-----------|------|--------|-----------|-----------|-------|----------|---------|
| | | | | | | | | | |

### Phase A — sweep `BCLK_DIV`, link 2 = 2 Mbaud

| run | s | frames ok | lost | drop % | cksum err | ovf bytes | short | wire B/s | verdict |
|-----|---|-----------|------|--------|-----------|-----------|-------|----------|---------|
| | | | | | | | | | |

### Phase B — sweep `BCLK_DIV`, link 2 = 921,600

| run | s | frames ok | lost | drop % | cksum err | ovf bytes | short | wire B/s | verdict |
|-----|---|-----------|------|--------|-----------|-----------|-------|----------|---------|
| | | | | | | | | | |

### Phase C — `BCLK_DIV = 8`, sweep link 2 baud

| run | s | frames ok | lost | drop % | cksum err | ovf bytes | short | wire B/s | verdict |
|-----|---|-----------|------|--------|-----------|-----------|-------|----------|---------|
| | | | | | | | | | |

### Hypothesis outcomes

| | prediction | outcome |
|---|---|---|
| H1 headroom | no loss anywhere in phase A | ☐ held ☐ falsified |
| H2 attribution | loss only at `BCLK_DIV=8` in phase B | ☐ held ☐ falsified |
| H3 verdict | `GATEWAY LOSS (ESP32/USB)`, `ovf` = 0 | ☐ held ☐ falsified |
| H4 knee | ≈ 948,500 baud | ☐ held ☐ falsified, measured ______ |

## 8. What M3 hands to M4

Whatever the numbers turn out to be, M3 produces the two things the SPI milestone needs:

1. **A measured ceiling for the UART chain** — a number, with a method, not a datasheet
   figure.
2. **An attributed failure** — which stage ran out of capacity first, demonstrated rather
   than assumed.

M4 re-runs this identical sweep over SPI and overlays the curves. Because the FPGA capture
logic, the frame format and the host analysis all stay unchanged, the comparison isolates
the transport — which is the whole point of the project.

## 9. Open question worth deciding before phase C

If phase C's knee lands well below 948,500 baud, the shortfall is inside the ESP32 or the
CH9102 and we will not be able to say which from the host alone. A byte counter on the
ESP32 (bytes in from link 1 vs bytes out to link 2) would separate them, at the cost of
the "dumb pump" property that currently keeps the gateway out of the measurement.

Deferred until the data shows whether it is needed.
