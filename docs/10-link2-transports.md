# 10 — Link 2: three transports measured

**2026-09-03** · `firmware/link2_blast` + `tools/measure_link2.py` · 10 s per transport

---

## Why this was measured separately from the audio

Link 2 is the ESP32 → host connection. Its capacity had to be known before the chain's
bottleneck could be named — but **audio cannot load it**. Two INMP441s at their maximum
46,875 Hz produce 190,063 B/s, roughly a sixth of what native USB turned out to manage. Any
measurement made with audio would only have shown the link idling.

So the FPGA was taken out of the picture. The ESP32 generates its own load: an incrementing
byte written as fast as the chosen link accepts. The host counts what arrives over a fixed
wall-clock interval **and verifies the sequence**, so the result is a throughput figure with
an integrity figure attached.

### Why the host does the timing

The usual published method — including the one this test was modelled on — times N writes on
the microcontroller with `micros()` and a `flush()`. That measures how fast the **device's own
buffer drains**, which over a short burst is partly just the buffer absorbing it, and it
cannot tell whether the data arrived at all.

Here the host is both the clock and the witness. That matters because this project has
already recorded a link **carrying its full rated byte rate while delivering zero usable
frames** (M2-PC). Speed without integrity is not a measurement.

---

## Results

| transport | throughput | % of nominal | bytes lost in 10 s | integrity |
|---|---|---|---|---|
| CH9102 bridge @ 2,000,000 baud | 199,797 B/s | **99.9 %** | 256 | 0.013 % |
| CH9102 bridge @ 6,000,000 baud | 579,875 B/s | 96.6 % | 16,896 | **0.29 %** |
| **native USB (USB Serial/JTAG)** | **988,789 B/s** | — | **0** | **clean** |

**Native USB is 1.71× the fastest CH9102 rate, and it is the only one of the three that lost
nothing.**

### Three things the numbers say

**A UART does achieve its rated capacity.** At 2 Mbaud the bridge delivered 99.9 % of
`baud ÷ 10`. This confirms from a second direction the correction made in M3-C: there is no
hidden framing overhead in a UART, and the earlier "94.5 % ceiling" claim was a metric
artefact, not a property of the hardware.

**But its *rated* capacity is not its *usable* capacity.** At 6 Mbaud the same bridge reached
96.6 % of nominal while dropping **0.29 % of the stream** — 16,896 bytes in ten seconds. The
6 Mbaud cap is therefore doubly misleading: the macOS driver refuses anything above it, and
the link is already shedding data at it. The honest usable figure for the CH9102 path is
below 580 kB/s, not the 600 kB/s its baud rate advertises.

**USB CDC has no baud rate, and that is the point.** Nothing was configured to 989 kB/s; that
is simply what the transport does. There is no rate to negotiate, no pair of constants to
keep in step, and no driver table to be refused by — which removes the exact failure mode
that cost this project two debugging sessions.

### Measurement limitation, stated plainly

The pattern is an 8-bit counter, so **a loss of exactly 256 bytes (or any multiple) is
invisible** — the sequence appears continuous across it. Every loss figure above is therefore
a **lower bound**. A wider counter would remove the ambiguity and is worth doing if the exact
loss rate at 6 Mbaud ever matters. It does not change the ranking: zero detected
discontinuities across 9.9 MB is strong evidence that native USB lost nothing.

---

## What this does to the chain

| link | capacity | measured how |
|---|---|---|
| link 1 — FPGA → ESP32 | **1,350,000 B/s** | proven clean at 13.5 Mbaud; 18 Mbaud fails |
| link 2 — CH9102 path | 579,875 B/s | driver-capped at 6 Mbaud, and lossy there |
| **link 2 — native USB** | **988,789 B/s** | **no configured limit; this is what it does** |

Switching link 2 to native USB raises the chain's ceiling from **600 kB/s to 989 kB/s, a 65 %
improvement, for no hardware change and no cost** — the connector is already on the board and
was already enumerating.

Link 2 remains the binding constraint, but only just: 989 kB/s against link 1's 1,350 kB/s.

### And it makes the honest conclusion sharper

Two INMP441s produce 190,063 B/s — **19 % of the improved ceiling**. Saturating it would take
about **eleven microphone channels**.

This project has two. **The transport is not the bottleneck for audio at this scale, and the
report should say so directly.** The case for SPI rests on headroom, channel count and
cost-per-byte — not on a measured failure of UART or USB, because at audio rates neither
failed.

---

## Recommendation

**Move link 2 to native USB for the remaining milestones.** It is faster, it is the only
lossless option measured, it costs nothing, and it deletes the baud-matching trap that has
already caused two failures in this project.

The one thing it changes is framing: the gateway stops being a "UART bridge" and becomes a
USB device. That is arguably more honest about what it always was — the CH9102 was only ever
translating to USB anyway, and translating it badly.
