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

## v2 — implemented and simulated (current)

Full design write-up: [`05-instrumentation.md`](05-instrumentation.md).
Implemented in `fpga/src/framer.v`; parsed by `host/inmp441_viewer.py`.

| Offset | Size | Field | Meaning |
|--------|------|-------|---------|
| 0 | 4 | `sync` | `AA 55 A5 5A`, unchanged |
| 4 | 2 | `seq` | frame counter, uint16 LE, free-running and wrapping |
| 6 | 2 | `ovf` | cumulative FIFO overflow byte count, uint16 LE, saturating |
| 8 | 2 | `cfg` | `[7:0]` = `N` divider, `[9:8]` = channel count, `[15:10]` reserved |
| 10 | 1024 | `payload` | 512 × int16 LE audio samples |
| 1034 | 2 | `checksum` | 16-bit additive sum of the payload bytes, LE |

Frame = **1036 bytes**.

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
