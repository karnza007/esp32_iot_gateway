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

*(pending — plan: [`plans/m2-positive-control.md`](plans/m2-positive-control.md))*
