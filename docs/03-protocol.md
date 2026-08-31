# 03 — On-wire protocol

## v1 — superseded by v2 (kept for reference)

```
┌──────────────┬────────────────────────────────┐
│ AA 55 A5 5A  │ 512 × int16 little-endian      │
│  4 bytes     │ 1024 bytes                     │
└──────────────┴────────────────────────────────┘
frame = 1028 bytes, emitted once per 512 samples
```

- Sample = the **top 16 bits** of the microphone's 24-bit left-channel word.
- At 15 kHz this is 30,120 B/s — measured and confirmed on the host.
- The receiver resynchronizes by scanning bytes until it matches the 4-byte sync.

**Limitation:** loss is invisible. If the FIFO overflows or the USB bridge drops bytes,
the viewer resynchronizes on the next sync word and shows slightly wrong audio with no
indication that anything went missing. This is exactly what v2 fixes.

## v2 — superseded by v3

Full design write-up: [`05-instrumentation.md`](05-instrumentation.md).
Implemented in `fpga/src/framer.v`; parsed by `host/inmp441_viewer.py`.

| Offset | Size | Field | Meaning |
|--------|------|-------|---------|
| 0 | 4 | `sync` | `AA 55 A5 5A`, unchanged |
| 4 | 2 | `seq` | frame counter, uint16 LE, free-running and wrapping |
| 6 | 2 | `ovf` | cumulative FIFO overflow byte count, uint16 LE, free-running (wraps) |
| 8 | 2 | `cfg` | `[7:0]` = `N` divider, `[9:8]` = channel count, `[15:10]` reserved |
| 10 | 1024 | `payload` | 512 × int16 LE audio samples |
| 1034 | 2 | `checksum` | 16-bit additive sum of the payload bytes, LE |

Frame = **1036 bytes**.

## v3 — current: the header gets its own checksum

| Offset | Size | Field |
|--------|------|-------|
| 0 | 4 | `sync` |
| 4 | 2 | `seq` |
| 6 | 2 | `ovf` |
| 8 | 2 | `cfg` |
| **10** | **2** | **`hdrsum` — additive sum of bytes 4…9** |
| 12 | 1024 | `payload` |
| 1036 | 2 | `checksum` — additive sum of the payload |

Frame = **1038 bytes**.

**Why two checksums rather than one over everything.** Under saturation the payload is
routinely destroyed while the header survives, because framing bytes hold reserved FIFO
space. A single checksum spanning both would mark every header unusable precisely when its
`seq` and `ovf` are most needed. Checking each region separately keeps the header usable
while the payload is not.

**Why the header needs checking at all.** Measured on hardware 2026-08-31: with 24.6 % of
frames failing their payload checksum, a corrupted `ovf` field injected a phantom
**65,536-byte** overflow — a 16-bit counter cannot produce that in one step, but a garbage
reading followed by a true one sums to exactly 2^16 through modulo arithmetic. Corrupted
`seq` values inflate apparent frame loss the same way. Neither is detectable without
`hdrsum`.

A frame whose header fails `hdrsum` is counted as a `header_error` and its `seq`/`ovf` are
discarded. It is **not** counted as a lost frame — it arrived; it was unreadable.

### What each field buys us

- **`seq`** — the host computes `expected - received` to get a **frame drop rate**.
  Without it, loss is unmeasurable.
- **`ovf`** — increments inside the FPGA whenever a byte is pushed into a full FIFO.
  Sticky and monotonic, so the host can plot it directly. This field localizes the
  failure: `ovf > 0` means the **UART link itself** is saturated.
- **`cfg`** — lets the viewer derive `fs = 24e6 / (64 × N)` on its own, so a rate sweep
  needs zero Python edits between runs. Also self-documents captured data files.
- **`checksum`** — separates **integrity** (bytes arrived corrupted) from **loss**
  (bytes never arrived). These are different failure modes with different causes and
  the report needs to tell them apart.

### The key diagnostic

| `ovf` | `seq` gaps | Interpretation |
|-------|-----------|----------------|
| 0 | none | healthy |
| **> 0** | present | FPGA FIFO overflowing — **the UART link is the bottleneck** |
| 0 | present | FPGA kept up; the **ESP32 or USB bridge** is dropping — motivates SPI |
| 0 | none, but checksum errors | electrical/signal-integrity problem, not throughput |

This table is the experimental result the whole project is built to produce.
