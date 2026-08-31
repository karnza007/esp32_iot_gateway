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
| `run-n25-null-after.csv` | 49 | 1439 | 0 | 0.00 | 0 | 0 | 0 | 30,358 | 33 | OK |
| `m3-phase0-null-2M.csv` | 59 | 1736 | 0 | 0.00 | 0 | 0 | 0 | 30,337 | 15 | OK |
| `m3-A-div20.csv` | 130 | 4756 | 0 | 0.00 | 0 | 0 | 0 | 37,923 | 19 | OK |
| `m3-A-div16.csv` | 59 | 2713 | 0 | 0.00 | 0 | 0 | 0 | 47,430 | 24 | OK |
| `m3-A-div12.csv` | 59 | 3618 | 0 | 0.00 | 0 | 0 | 0 | 63,246 | 32 | OK |
| `m3-A-div10.csv` | 59 | 4341 | 0 | 0.00 | 0 | 0 | 0 | 75,887 | 38 | OK |
| `m3-A-div8.csv` | 59 | 5425 | 0 | 0.00 | 0 | 0 | 0 | 94,816 | 47 | OK |
| `m3-B-div25.csv` | 44 | 1294 | 0 | 0.00 | 0 | 0 | 0 | 30,385 | 33 | OK |
| `m3-B-div20.csv` | 44 | 1618 | 0 | 0.00 | 0 | 0 | 0 | 38,001 | 41 | OK |
| `m3-B-div16.csv` | 44 | 2025 | 0 | 0.00 | 0 | 0 | 0 | 47,556 | 52 | OK |
| `m3-B-div12.csv` | 44 | 2695 | 0 | 0.00 | 0 | 0 | 0 | 63,334 | 69 | OK |
| `m3-B-div10.csv` | 44 | 3236 | 0 | 0.00 | 0 | 0 | 0 | 76,032 | 82 | OK |
| `m3-B-div8.csv` | 59 | 3772 | 319 | 5.88 | 1335 | **0** | 1016 | 66,082 | 103 | **GATEWAY LOSS (ESP32/USB)** |
| `m3e-54MHz-null.csv` | 44 | 1303 | 0 | 0.00 | 0 | 0 | 0 | 30,557 | 15 | OK |

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


---

## M2-NULL-AFTER — recovery check

**2026-08-31** · `BCLK_DIV = 25`, link 1 restored to 2 Mbaud · raw: `data/run-n25-null-after.csv`

**Question.** After deliberately saturating the link for 211 seconds, does the system
return to exactly its previous behaviour? This closes the loop: it shows the overload
*caused* the readings and left nothing damaged behind.

**Result — PASS.**

```
  duration           49 s (48 one-second intervals)
  frames received    1439  (of 1439 expected)
  frames intact      1439
  frames lost        0     checksum errors 0     short frames 0
  FPGA overflow      0 bytes
  delivered wire     30,358 B/s   = 33 % of link 2
  verdict            OK   in all 48 intervals
```

**M2 is complete.** The instrument has now been demonstrated in all three states:

| state | run | result |
|-------|-----|--------|
| healthy | `run-n25-null.csv` | silent — 0 across every counter |
| overloaded | `run-positive-control.csv` | accurate — 5,379 B/s vs 5,352 predicted, 0.5 % |
| restored | `run-n25-null-after.csv` | silent again — 0 across every counter |

A detector that only ever reads zero proves nothing; one that reads zero, then the right
non-zero number, then zero again, is a working instrument. Every measurement in M3 rests
on this.

**Repeatability.** Three separate null runs (33 s, 49 s, and an earlier 191 s) measured the
wire rate at 30,348 / 30,358 / — B/s against 30,352 predicted. Spread under 0.04 %.


---

## M3-PHASE0 — link 2 raised to 2 Mbaud

**2026-08-31** · `BCLK_DIV = 25`, **link 2 = 2,000,000 baud**, one channel
· raw: `data/m3-phase0-null-2M.csv`

**Question.** Link 2 ran at 921,600 baud because that value was inherited from M1, never
chosen. Can the ESP32's UART0 and the CH9102 bridge actually sustain 2,000,000 baud? If
not, every M3 result would be contaminated by an undiagnosed ceiling.

**Result — PASS. The CH9102 sustains 2 Mbaud cleanly.**

```
  duration           59 s (59 one-second intervals)
  frames received    1736  (of 1736 expected)
  frames intact      1736
  frames lost 0      checksum errors 0      short frames 0      overflow 0
  delivered wire     30,337 B/s   = 15 % of link 1, 15 % of link 2
  verdict            OK   in all 59 intervals
```

Identical behaviour to 921,600, with the chain's ceiling more than doubled: link 2 goes
from 92,160 B/s to 200,000 B/s, matching link 1. **Both links are now 200,000 B/s and
neither is privileged as "the bottleneck".**

**Consequence for M3.** A single INMP441 tops out at 94,849 B/s (`BCLK_DIV = 8`, limited by
the microphone's own 3.2 MHz SCK ceiling), which is only **47 % of either link**. One
microphone can no longer saturate this chain — hence the three-phase design in
[`plans/m3-load-sweep.md`](plans/m3-load-sweep.md), which locates the same knee by raising
demand and by lowering capacity.

### A measurement bug this run exposed

The summary tool reported "33 % of link 2" for a run at 2 Mbaud, because link 2's capacity
was a **module-level constant** while it is in fact a **property of the run** — and M3
phase C sweeps it deliberately. Every phase C data point would have been mislabelled.

Fixed twice over:

- the viewer now records `link2_baud`, `bclk_div` and `channels` **in the CSV itself**, so
  a data file states the conditions it was captured under, exactly as the `cfg` field
  already does for the FPGA side;
- `summarize_run.py` reads those columns, falls back for older files, says so when it is
  falling back, and accepts `--link2-baud` to override.

Third time this project has been caught by the same class of error: **a parameter written
in one place and assumed in another.** The others were `CLK_PER_BIT`/`FPGA_BAUD` and
`SAMPLE_RATE` in the viewer. The fix each time is to make the data self-describing rather
than to remember harder.

---

## M3-A — sample-rate sweep with both links at 2 Mbaud

**2026-08-31** · `BCLK_DIV` 25 → 8, link 2 = 2,000,000 baud, one channel
· raw: `data/m3-A-div*.csv`

**Hypothesis H1.** With both links at 200,000 B/s, sweeping the sample rate over its full
range produces **no loss at any point**, because even the maximum single-channel rate is
only 47 % of capacity.

**Result — H1 HELD. Zero loss at every point.**

| `BCLK_DIV` | fs (Hz) | predicted B/s | observed B/s | error | lost | ovf | cksum | verdict |
|---|---|---|---|---|---|---|---|---|
| 25 | 15,000 | 30,352 | 30,337 | 0.05 % | 0 | 0 | 0 | OK |
| 20 | 18,750 | 37,939 | 37,923 | 0.04 % | 0 | 0 | 0 | OK |
| 16 | 23,438 | 47,424 | 47,430 | 0.01 % | 0 | 0 | 0 | OK |
| 12 | 31,250 | 63,232 | 63,246 | 0.02 % | 0 | 0 | 0 | OK |
| 10 | 37,500 | 75,879 | 75,887 | 0.01 % | 0 | 0 | 0 | OK |
| 8 | 46,875 | 94,849 | 94,816 | 0.03 % | 0 | 0 | 0 | OK |

**Worst error across a 3.1× range of data rates: 0.05 %.** Not one frame lost, not one byte
of overflow, not one checksum error, across roughly 23,600 frames.

This is deliberately the boring phase, and its value is exactly that: it establishes that
the FPGA capture, the frame format and the host analysis are all correct over the full
sample-rate range. Any loss seen in phase B is therefore attributable to the single setting
that changes there.

### The throughput independently confirms the sample rate

At `BCLK_DIV = 8`: 94,816 B/s ÷ 1036 bytes per frame = 91.52 frames/s × 512 samples =
**46,859 Hz** against a nominal 46,875 — agreement to **0.034 %**. The data rate is a direct
measurement of the sample rate, and it confirms the clock divider without a scope.

### FFT frequency resolution — not a fault

A 440 Hz tone read high at `BCLK_DIV = 8`. This is expected and is a property of the
transform, not of the link.

The FFT is 512-point, so bin spacing is `fs / 512`:

| fs (Hz) | bin spacing | nearest bin to 440 Hz | error |
|---|---|---|---|
| 15,000 | 29.30 Hz | 439.45 | −0.5 |
| 23,438 | 45.78 Hz | 457.76 | +17.8 |
| 31,250 | 61.04 Hz | 427.25 | −12.8 |
| 37,500 | 73.24 Hz | 439.45 | −0.5 |
| **46,875** | **91.55 Hz** | **457.76** | **+17.8** |

Raising the sample rate spreads the same 512 bins over a wider frequency range, so each bin
covers more hertz. At 46,875 Hz a peak can only be reported in 91.6 Hz steps — 440 Hz has
nowhere to land but the 457.8 Hz bin.

**Fixed by interpolating between bins.** A parabola fitted through the peak bin and its two
neighbours (on log magnitude) recovers the true frequency to a fraction of a bin:

| fs (Hz) | bin peak | interpolated | error |
|---|---|---|---|
| 15,000 | 439.45 | 440.04 | +0.04 |
| 23,438 | 457.76 | 439.41 | −0.59 |
| 31,250 | 427.25 | 440.86 | +0.86 |
| 37,500 | 439.45 | 440.04 | +0.04 |
| 46,875 | 457.76 | **438.76** | **−1.24** |

A 17.8 Hz quantisation error becomes 1.2 Hz. This matters beyond cosmetics: the SNR and THD
measurements planned for the fidelity work need the peak located accurately, not merely
quantised to the nearest bin. The title now reports the interpolated frequency, the raw bin,
and the resolution, so the distinction is visible rather than hidden.

---

## M3-B-div8 — the failure is attributed to the gateway

**2026-08-31** · `BCLK_DIV = 8` (46,875 Hz), **link 2 = 921,600 baud**, frame v3
· raw: `data/m3-B-div8.csv`

**Hypothesis H3.** At `BCLK_DIV = 8` the FPGA offers 95,032 B/s. Link 2 can carry 92,160
B/s, so data must be lost — but link 1 carries 200,000 B/s and is only 47.5 % loaded, so the
**FPGA's FIFO should never fill**. The loss must therefore be reported as
`GATEWAY LOSS (ESP32/USB)` with `ovf = 0`, not as `LINK SATURATED (FPGA FIFO)`.

*Falsifier: `ovf` climbs.*

**Result — H3 HELD.**

```
  duration           59 s (59 one-second intervals)
  frames received    5107  (of 5426 expected)
  frames intact      3772
  frames lost        319  -> drop rate 5.88 %
  checksum errors    1335 -> 26.14 % of received
  header errors      0
  FPGA overflow      0 bytes          <-- the FPGA discarded nothing
  short frames       1016  (130,702 payload bytes missing)
  bytes on the wire  87,103 B/s
  delivered payload  65,191 B/s
  verdict            GATEWAY LOSS (ESP32/USB)   in all 59 intervals
```

### Why this is the most important run so far

**The instrument can now discriminate in both directions.** Until now it had only ever been
demonstrated one way:

| condition | run | `ovf` | verdict | proven? |
|-----------|-----|-------|---------|---------|
| healthy | `run-n25-null` | 0 | `OK` | ✅ |
| FPGA-side loss | `run-positive-control` | 1,133,450 | `LINK SATURATED (FPGA FIFO)` | ✅ |
| **gateway-side loss** | **`m3-B-div8`** | **0** | **`GATEWAY LOSS (ESP32/USB)`** | ✅ **now** |

Two failure modes that look identical from the outside — audio with holes in it — are told
apart by a counter inside the FPGA. Everything M4 claims about SPI depends on this working.

### Where the data went

| | B/s | share |
|---|---|---|
| offered by the FPGA | 95,032 | 103.1 % of link 2 |
| arrived at the host | 87,103 | 94.5 % of link 2 |
| **never arrived** | **7,929** | **8.3 % of what was sent** |
| usable audio recovered | 66,082 | **69.5 % of what was sent** |

Two things worth noting.

**~~Link 2 tops out at ~94.5 % of its nominal capacity, not 100 %.~~ — WRONG, corrected by
M3-C.** This said 87,103 B/s arrived against a nominal 92,160 and attributed the shortfall to
gateway overhead. The metric was at fault, not the gateway: it counted only bytes inside
recognised frames and ignored bytes discarded during resynchronisation. Counting everything
that arrives gives **92,103 B/s — 99.9 % of nominal.** Phase C confirms this at every
saturated point (99.8–100.0 %). **A UART delivers essentially its full rated capacity;**
there is no hidden overhead, and the earlier claim should not be repeated.

**8.3 % of bytes lost costs 30.5 % of the audio.** Loss is not proportional to damage: a
frame with a single byte missing fails its checksum and is discarded whole. This is the same
collapse seen in M2-PC, in gentler form, and it is the strongest argument in the report for
why headroom matters rather than merely running "close to capacity".

### A note on comparing with the earlier v2 attempt

An earlier run of this same point (`m3-B-div8.v2-INVALID.csv.bak`) reported
`LINK SATURATED (FPGA FIFO)` and a phantom 65,536-byte overflow. Both were instrument
faults, now fixed (frame v3 + corrected verdict logic). The v3 run reports **0 header
errors**, so no header corruption went undetected this time — the numbers above can be
trusted in a way the earlier ones could not.

---

## M3-B — the controlled comparison

**2026-08-31** · `BCLK_DIV` 25 → 8 at **link 2 = 921,600 baud**, frame v3
· raw: `data/m3-B-div*.csv` · automated with `tools/sweep.sh`

**Hypothesis H2.** The identical FPGA sweep, with only link 2's baud rate changed, will lose
data at `BCLK_DIV = 8` and nowhere else. Since nothing else differs, the loss is caused by
link 2.

**Result — H2 HELD.** The same six FPGA configurations, run twice:

| `BCLK_DIV` | offered B/s | A: link 2 = 2 Mbaud | | B: link 2 = 921,600 | |
|---|---|---|---|---|---|
| | | **% of link 2** | **drop** | **% of link 2** | **drop** |
| 25 | 30,410 | 15 % | 0.00 % | 33 % | 0.00 % |
| 20 | 38,013 | 19 % | 0.00 % | 41 % | 0.00 % |
| 16 | 47,516 | 24 % | 0.00 % | 52 % | 0.00 % |
| 12 | 63,354 | 32 % | 0.00 % | 69 % | 0.00 % |
| 10 | 76,025 | 38 % | 0.00 % | **82 %** | 0.00 % |
| **8** | **95,032** | **48 %** | **0.00 %** | **103 %** | **5.88 %** |

**Twelve runs. One point loses data. It is the only point where demand exceeds capacity.**

### Why this is a controlled experiment rather than an observation

The FPGA bitstream at `BCLK_DIV = 8` is byte-identical in both columns. The microphone, the
wiring, the frame format, the host analysis and the ESP32 firmware are all unchanged. **A
single number differs: link 2's baud rate.** Change it back and the loss disappears; change
it again and the loss returns.

That is what licenses the causal claim. Without column A, "the link lost data at 46.875 kHz"
would be an observation with several possible explanations — the FPGA struggling at a 3 MHz
bit clock, the microphone misbehaving near its 3.2 MHz limit, the frame format failing at
speed. Column A rules all of those out: **the same FPGA configuration, at the same sample
rate, is perfectly clean when the gateway link is fast enough.**

### The knee is bracketed

| | offered | % of link 2 | result |
|---|---|---|---|
| `BCLK_DIV = 10` | 76,025 B/s | 82 % | clean |
| `BCLK_DIV = 8` | 95,032 B/s | 103 % | 5.88 % loss |

The transition lies between **82 % and 103 %** of nominal capacity — consistent with the
94.5 % ceiling measured directly at div8, where 87,103 B/s arrived against a nominal 92,160.
Phase C locates it precisely by lowering capacity against fixed demand, approaching the same
knee from the opposite direction.

### Automation

All of phase B after the first point was run by `tools/sweep.sh`: it edits `top.v`,
synthesises and places & routes through Gowin's `gw_sh`, programs the bitstream to SRAM via
`programmer_cli`, captures a run, and then **verifies that the `bclk_div` the FPGA reports in
the frame header matches what was asked for.**

That last check is not ceremony. This project has already lost a session to a stale bitstream
and mislabelled a data point by running a sweep point twice into one file. Both faults are
now structurally impossible: the data states its own configuration, and the script refuses a
run whose configuration disagrees with its filename.

(`gw_sh` needs Tcl 8.6 at `/Library/Frameworks`, which macOS 26 no longer ships. The Gowin
bundle carries its own copy, so `DYLD_FRAMEWORK_PATH` pointed at
`GowinIDE.app/.../IDE/lib` is enough — no system modification.)

---

## M3-C — the knee, located from the capacity side

**2026-08-31** · `BCLK_DIV = 8` fixed (demand 95,032 B/s), **link 2 swept 2,000,000 → 460,800**
· raw: `data/m3-C-baud*.csv` · automated with `tools/sweep_baud.sh`

**Hypothesis H4.** Holding demand fixed and lowering capacity will locate a knee at
**≈ 950,320 baud**, the point where capacity equals demand.

**Result — H4 HELD, and more sharply than predicted.**

| link 2 baud | capacity B/s | demand as % | arriving B/s | % of capacity | frame drop | checksum errors | usable audio | verdict |
|---|---|---|---|---|---|---|---|---|
| 2,000,000 | 200,000 | 47.5 % | 95,050 | 47.5 % | 0.00 % | 0.0 % | **100 %** | OK |
| 1,500,000 | 150,000 | 63.4 % | 95,045 | 63.4 % | 0.00 % | 0.0 % | **100 %** | OK |
| 1,200,000 | 120,000 | 79.2 % | 95,048 | 79.2 % | 0.00 % | 0.0 % | **100 %** | OK |
| 1,000,000 | 100,000 | 95.0 % | 95,074 | 95.1 % | 0.00 % | 0.0 % | **100 %** | OK |
| 975,000 | 97,500 | 97.5 % | 95,055 | 97.5 % | 0.00 % | 0.0 % | **100 %** | OK |
| **950,000** | **95,000** | **100.0 %** | 94,990 | 100.0 % | **0.00 %** | **0.0 %** | **100 %** | **OK** |
| **921,600** | **92,160** | **103.1 %** | 92,103 | 99.9 % | **5.50 %** | **26.1 %** | **70 %** | GATEWAY LOSS |
| 750,000 | 75,000 | 126.7 % | 75,023 | 100.0 % | 23.45 % | 100 % | **0 %** | GATEWAY LOSS |
| 460,800 | 46,080 | 206.2 % | 46,001 | 99.8 % | 55.70 % | 100 % | **0 %** | GATEWAY LOSS |

### The knee is at capacity, and it is a cliff

**At 100.0 % of nominal capacity the link is still perfect** — 3583 frames, zero lost, zero
corrupt. At 103.1 % it has lost 30 % of the audio. At 126.7 % it delivers **nothing usable at
all**.

| demand vs capacity | usable audio delivered |
|---|---|
| 100.0 % | 100 % |
| 103.1 % | 70 % |
| 126.7 % | 0 % |
| 206.2 % | 0 % |

**Three percent over capacity costs thirty percent of the payload. Twenty-seven percent over
costs all of it.** Loss is nowhere near proportional to overload, because a frame missing a
single byte fails its checksum and is discarded whole. This is the strongest argument in the
report for provisioning headroom rather than running "close to capacity" — the useful
capacity of the link is not 100 % of its rating, it is 100 % minus whatever margin protects
you from ever crossing it.

### A UART delivers its full rated capacity

Every saturated point carried **99.8–100.0 %** of `baud ÷ 10`. There is no measurable
gateway overhead: the ESP32 and the CH9102 keep the wire completely full and simply discard
what will not fit. This **corrects the M3-B finding above**, which claimed a 94.5 % ceiling
— that number came from a metric that ignored bytes skipped during resynchronisation.

### Both directions agree

| approach | what varied | knee located |
|---|---|---|
| A / B | demand, capacity fixed | between 82 % and 103 % |
| **C** | **capacity, demand fixed** | **between 100.0 % and 103.1 %** |

Phase C brackets it fifteen times more tightly, and its window sits inside phase B's. Two
experiments varying opposite quantities, agreeing on the same boundary — which is exactly
why the plan called for running it both ways rather than either alone.

`ovf = 0` at every single point. Link 1 never exceeded 47.5 %, and the FPGA discarded nothing
in any of the nine runs.