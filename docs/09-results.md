# 09 — Results log

Every hardware run that produced a number, newest last. Raw CSVs are in `data/`
(gitignored — they are per-machine); the reduced numbers live here and are committed.

Reduce a run with:

```bash
.venv/bin/python tools/summarize_run.py data/<file>.csv            # readable
.venv/bin/python tools/summarize_run.py --markdown data/*.csv      # table rows
```

The first one-second interval of every run is skipped by default: the viewer joins a
stream already in progress, so it always shows a startup resync that reflects when you
pressed enter, not a property of the link.

---

## Reference capacities

| link | baud | capacity | note |
|------|------|----------|------|
| 1. FPGA → ESP32 | 2,000,000 | 200,000 B/s | set by `CLK_PER_BIT` + `FPGA_BAUD` |
| 2. ESP32 → host | 921,600 | **92,160 B/s** | set by `Serial.begin` + viewer `BAUD` — **the chain's real ceiling** |

Wire rate for one channel: `fs / 512 × 1036` B/s.

---

## Summary table

| run | s | frames ok | lost | drop % | cksum err | ovf bytes | resync | wire B/s | % link2 | verdict |
|-----|---|-----------|------|--------|-----------|-----------|--------|----------|---------|---------|
| `run-n25-null.csv` | 33 | 959 | 0 | 0.00 | 0 | 0 | 0 | 30,348 | 33 | OK |
| `run-positive-control.csv` | 211 | 0 | 0 | 0.00 | 6175 | 1,133,450 | 6175 | 0 | 0 | LINK SATURATED (FPGA FIFO) |

---

## M2-NULL — instrumentation null test

**2026-08-31** · `BCLK_DIV = 25` (15.000 kHz), link 1 @ 2 Mbaud, one channel
· raw: `data/run-n25-null.csv`

**Question.** Does the M2 instrumentation change anything about a link already known to
work? It should not: at 15 kHz the chain runs at 33 % of its tightest link.

**Result — PASS.**

```
  duration           33 s (32 one-second intervals)
  frames received    959  (of 959 expected)
  frames intact      959
  frames lost        0  -> drop rate 0.00 %
  checksum errors    0  -> 0.00 % of received
  FPGA overflow      0 bytes  (0 B/s discarded)
  resync events      0  (0 bytes skipped)
  delivered payload  29,997 B/s
  delivered wire     30,348 B/s   = 15 % of link 1, 33 % of link 2
  verdict            OK
```

**Reading it.**

- **30,348 B/s measured against 30,352 B/s predicted** — 0.01 % error. The frame format,
  the sample rate and the clock divider all agree with the arithmetic.
- Zero loss, zero corruption, zero overflow across 959 consecutive frames.
- The 8 extra bytes of the v2 frame are visible: M1 measured 30,120 B/s on the wire for the
  same audio. `payload_Bps` is 29,997 in both, because the audio itself did not change.
- An earlier run of this same test (191 s, before the metric fixes) was also clean.

**What it does not prove.** That the overflow counter works. It has never left zero.
That is what M2-PC is for.

---

## M2-PC — positive control

**2026-08-31** · `BCLK_DIV = 25` (15.000 kHz), **link 1 slowed to 250 kbaud**, one channel
· raw: `data/run-positive-control.csv` · plan:
[`plans/m2-positive-control.md`](plans/m2-positive-control.md)

**Question.** The overflow counter had never read anything but 0. Can it count at all, and
does the host attribute the loss to the right stage? Deliberately starve link 1 to 25,000
B/s against a 30,352 B/s demand and require the instrument to react.

**Result — PASS on every criterion.**

```
  duration           211 s (206 one-second intervals)
  frames received    6175  (of 6175 expected)
  frames intact      0
  frames lost        0  -> drop rate 0.00 %
  checksum errors    6175  -> 100.00 % of received
  FPGA overflow      1,133,450 bytes  (5,379 B/s discarded)
  short frames       6175  (1,133,450 payload bytes missing)
  resync events      0  (0 bytes skipped)
  bytes on the wire  24,981 B/s   (everything that arrived, intact or not)
  delivered payload  0 B/s        (usable audio only)
  verdict            LINK SATURATED (FPGA FIFO)   in all 206 intervals
```

### Predicted vs observed

| quantity | predicted | observed | error |
|----------|-----------|----------|-------|
| overflow rate | 5,352 B/s | **5,379 B/s** | **0.5 %** |
| frame rate | 29.30 /s | **29.30 /s** | **0.0 %** |
| bytes missing per frame | 183 | **184** | **0.5 %** |
| bytes arriving on link 1 | 25,000 B/s | **24,981 B/s** | 0.1 % |
| usable audio delivered | 0 B/s | **0 B/s** | — |

Every prediction in §4 of the plan was written **before** the run and matched to within
0.5 %.

### The three things this proves

**1. The overflow counter works.** It went from a lifetime total of 0 to 1,133,450 bytes,
at a rate matching the arithmetic shortfall to 0.5 %.

**2. Two independent measurements agree exactly.**

| measurement | where it comes from | total |
|-------------|--------------------|-------|
| `ovf` | a counter **inside the FPGA**, incremented per discarded byte | 1,133,450 |
| `bytes_missing` | the **host**, from the length of each sync-delimited frame | 1,133,450 |

**Agreement to 0.000 %.** These share no code and no mechanism: one is Verilog counting
its own drops, the other is Python measuring how short each arriving frame is. That they
land on the same number is strong evidence both are correct.

**3. The wrapping counter decision was right.** The 16-bit `ovf` field wrapped **17 times**
during the run and the host tracked the true total through every wrap. The saturating
version this replaced would have pegged at 65,535 after 12 seconds and then reported a
per-interval delta of **zero** — flipping the verdict to `GATEWAY LOSS (ESP32/USB)` and
blaming the wrong component for the remaining 199 seconds.

### Reading the shape of the failure

- **`frames lost = 0`.** Not one frame header went missing in 211 seconds. This is the
  header-reservation fix working: framing bytes hold priority over audio, so the link stays
  measurable while overloaded. Before the fix, *zero* sync words arrived in five seconds.
- **`frames intact = 0`, `checksum errors = 100 %`.** Every frame arrived and every payload
  was damaged. Exactly the predicted shape: an 18 % byte deficit spread across all frames
  means no frame escapes.
- **`delivered payload = 0 B/s` while 24,981 B/s crosses the wire.** At 82 % of required
  capacity the link delivers **no usable audio at all**. Throughput does not degrade
  gracefully here — it collapses. Worth a sentence in the report: a link at 82 % of demand
  is not "82 % as good", it is useless.

### What it does not prove

Only that the FPGA-side detection works. The `GATEWAY LOSS (ESP32/USB)` verdict has never
fired and is still unproven — M3 at `BCLK_DIV = 8` should be the first test that triggers
it, since one channel at 94.8 kB/s exceeds link 2's 92.2 kB/s ceiling while leaving link 1
less than half loaded.
