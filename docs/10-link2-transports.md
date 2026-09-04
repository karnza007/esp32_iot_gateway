# 10 — Link 2: three transports measured

**2026-09-03** · `firmware/link2_blast` + `tools/measure_link2.py`
10 s per transport for the first comparison; 30 s per point for the lossless sweep

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


---

## The lossless sweep — 30 s per point, pattern counting modulo 251

The first comparison ranked the transports. It could not say where the CH9102 path stops
being *clean*, which is a different and more useful number. Nine UART rates and native USB,
30 s each.

**The pattern was changed from a byte counter to modulo 251 first.** A counter wrapping at
256 is blind to a loss of exactly 256 bytes, or 512, or 1024 — and those are precisely the
sizes serial buffers come in, so the blind spot sat exactly where the losses would be. 251 is
prime; no buffer size is a multiple of it. Every figure below is a real measurement rather
than a lower bound.

| baud | throughput | % of nominal | discontinuities | bytes lost | loss |
|---|---|---|---|---|---|
| 921,600 | 92,608 B/s | 100.5 % | 4 | 456 | 0.0163 % |
| 1,000,000 | 100,378 B/s | 100.4 % | 4 | 565 | 0.0187 % |
| 1,500,000 | 150,252 B/s | 100.2 % | 4 | 486 | 0.0108 % |
| 2,000,000 | 198,924 B/s | 99.5 % | 4 | 589 | 0.0099 % |
| **2,500,000** | 247,876 B/s | 99.2 % | 3,440,875 | — | **GARBAGE — 94 % of bytes wrong** |
| 3,000,000 | 296,028 B/s | 98.7 % | 7 | 918 | 0.0103 % |
| **4,000,000** | **390,031 B/s** | 97.5 % | **3** | **287** | **0.0024 %** ← best |
| **5,000,000** | 0 B/s | 0 % | — | — | **NO DATA AT ALL** |
| 6,000,000 | 577,156 B/s | 96.2 % | 794 | 100,070 | **0.5729 %** |
| **native USB** | **969,619 B/s** | — | **0** | **0** | **LOSSLESS** |

### The CH9102 only works at 12 MHz ÷ an integer

Two rates failed completely, and they are not the fast ones — 2.5 Mbaud produced garbage
while 3 and 4 Mbaud were fine, and 5 Mbaud produced nothing while 6 Mbaud worked. That
ordering rules out a speed limit.

| baud | 12 MHz ÷ baud | integer? | result |
|---|---|---|---|
| 1,000,000 | 12.000 | yes | works |
| 1,500,000 | 8.000 | yes | works |
| 2,000,000 | 6.000 | yes | works |
| **2,500,000** | **4.800** | **no** | **garbage** |
| 3,000,000 | 4.000 | yes | works |
| 4,000,000 | 3.000 | yes | works |
| **5,000,000** | **2.400** | **no** | **nothing** |
| 6,000,000 | 2.000 | yes | works |

**Every rate that worked divides 12 MHz by an integer. Both that failed do not.** 921,600 is
the apparent exception at 13.021, but `12 MHz / 13 = 923,077` is 0.16 % off — well inside a
UART receiver's tolerance — whereas 4.8 and 2.4 are not close to anything.

The bridge's baud generator evidently derives from a 12 MHz reference, and for an
unreachable divisor it settles on a neighbouring one, leaving the two ends disagreeing.
**The driver reports success in every case** — `ser.baudrate` reads back exactly what was
requested at 2.5 M and 5 M — so nothing warns you. The link simply delivers garbage, or
silence.

*(Presented as the explanation the data strongly supports, not as a datasheet fact: the
CH9102's reference clock was inferred from these nine measurements, not read from
documentation.)*

### No UART rate was lossless

Every working rate lost something. But the shape of it matters:

- **From 921,600 to 4,000,000 the loss is a floor, not a slope** — 3 to 7 discontinuities per
  30 s regardless of rate, and *lowest at the fastest working rate*. A constant number of
  events per unit time, independent of data volume, does not look like link stress; it looks
  like the host being descheduled and the driver's buffer overrunning. It is probably a
  property of the measuring setup rather than of the bridge.
- **6,000,000 breaks that pattern decisively** — 794 discontinuities and 0.57 %, roughly 80×
  the floor and clearly rate-dependent. That is the link failing, not the host.

**Best usable UART rate: 4,000,000 baud** — 390,031 B/s at 0.0024 % loss, the lowest of every
rate tested. Not 6 Mbaud, which the driver permits but which loses 240× more.

### Native USB is the only clean transport

Zero discontinuities across **29,097,984 bytes**. On the same measuring setup that showed a
0.01 % floor at every UART rate, native USB showed nothing at all — which suggests the floor
really is in the UART path rather than in the host, and strengthens rather than weakens the
comparison.

| | best usable rate | throughput | loss |
|---|---|---|---|
| CH9102 UART | 4,000,000 baud | 390,031 B/s | 0.0024 % |
| **native USB** | no rate to set | **969,619 B/s** | **0** |

**2.5× the throughput, and the only transport that lost nothing.**

### A bug this run exposed in the measuring tool

The 5 Mbaud point first reported **`LOSSLESS`** while receiving **zero bytes** — no data means
no discontinuities, and the verdict logic had no case for it. Corrected to distinguish
`NO DATA`, `GARBAGE` (bytes arriving but not following the pattern) and `LOSSY`.

Worth noting because it is the same class of mistake as the 111 % corruption figure in
M3-D §10: **a metric that is only exercised by success will not be tested by success.** Both
bugs surfaced only when a link failed in a way the tool had not anticipated.


---

## Decision: link 2 is now native USB

Adopted 2026-09-03. `firmware/fpga_uart_bridge` selects the peripheral by name
(`LINK2 = LINK2_USB`), the viewer prefers `/dev/cu.usbmodem*`, and every sweep script builds
with `CDCOnBoot=cdc`. The CH9102 path remains selectable with a one-line change.

**Verification — the audio chain over native USB:**

```
cfg=0x2538  sys_clk=54 MHz  BCLK_DIV=56  channels=1  fs=15066.9643 Hz

  duration           44 s
  frames received    1302  (of 1302 expected)
  frames intact      1302
  frames lost 0   checksum 0   header 0   overflow 0   resync 0
  delivered wire     30,578 B/s   = 15 % of link 1, 3 % of link 2
  verdict            OK   in all 44 intervals
```

Identical audio, identical rate, and link 2 now sits at **3 % load instead of 15 %**.

### Why this is the right choice for link 2, in one place

| | CH9102 UART | native USB |
|---|---|---|
| best usable throughput | 390,031 B/s (at 4 Mbaud) | **969,619 B/s** |
| loss at that rate | 0.0024 % | **0** |
| lossless at any rate? | **no** — every rate tested lost data | **yes** |
| rates that work | only 12 MHz ÷ integer; others fail silently | not applicable |
| configuration to keep in sync | two constants, both ends | **none** |
| back-pressure | **none** — a late receiver loses data permanently | built in — a late receiver costs latency |
| extra hardware in the path | the CH9102 bridge | none |

**2.5× the throughput, no loss, no rate to agree on, and one less chip in the path.** The
CH9102 was only ever translating UART to USB; removing it removes the translation and the
translation's limits.

### The one honest qualification

UART is not inherently lossy — **UART *without flow control* is.** RTS/CTS would let a late
receiver stall the sender instead of losing bytes. Those lines are not wired between the
ESP32 and the CH9102 on this board, and the FPGA link does not use them either, so this was
not testable here. The measured claim is therefore: *every UART configuration available to
this project lost data; native USB did not.*

---

## CORRECTION (2026-09-03, later the same day)

**The loss reported earlier in this document did not reproduce once the measuring tools were
fixed. Two claims are withdrawn.**

### What was claimed, and what is true

| claimed earlier | actually |
|---|---|
| "no UART rate was lossless — 0.01 % floor at every rate" | **not reproducible.** Nine controlled runs, every rate, idle and under heavy load: lossless |
| "USB CDC has back-pressure, so it cannot lose data" | one run lost 1.92 % in whole 64-byte packets; it did not recur under identical conditions |

### Every controlled measurement, after the fixes

| transport | rate | host | result |
|---|---|---|---|
| CH9102 | 92 kB/s | idle | LOSSLESS |
| CH9102 | 200 kB/s | idle | LOSSLESS |
| CH9102 | 390 kB/s | idle | LOSSLESS |
| native USB | 962 kB/s | idle | LOSSLESS |
| CH9102 | 200 kB/s | **heavy load** | LOSSLESS |
| CH9102 | 390 kB/s | **heavy load** | LOSSLESS |
| native USB | 441 kB/s | **heavy load** | LOSSLESS |
| native USB | 962 kB/s | **heavy load** | **LOSSY 1.92 %** |
| native USB | 962 kB/s | **heavy load** | LOSSLESS — same test, repeated |

**One lossy run in nine, unexplained and unreproduced.**

### The three tool bugs that manufactured the original result

Each produced a plausible-looking number rather than an error:

| bug | what it did | only visible when |
|---|---|---|
| counter wrapped at 251 | a 256- or 512-byte loss read as continuous; real losses mis-sized | losses were multiples of 251 |
| 16-bit counter, no alignment | reading one byte late made every step look like a 510-byte loss — reported 99.6 % corrupt | the byte phase happened to be odd |
| zero bytes scored as `LOSSLESS` | a completely dead link reported perfect | the link carried nothing at all |

Compounding them, the early runs reflashed the ESP32 between every point and ran while the
machine was compiling bitstreams — so the host was heavily loaded during the very
measurements used to characterise the link.

**A measuring instrument that fails loudly is harmless. These failed quietly, with numbers
that looked like results.** The same shape as the 111 % corruption figure in M3-D §10 and the
`resyncs` counter in M2: a metric only exercised by success is not tested by success.

### What survives

> With corrected tooling, every transport tested was lossless in 30-second runs, at every
> usable rate, idle and under heavy host load.

**Transports here differ in capacity, not in reliability.** At this project's data rates —
30 kB/s today, 190 kB/s with two microphones — loss is not a differentiator and should not be
used as one.

### The decision stands, on different grounds

Native USB remains the right choice for link 2, for the reasons that held up:

- **2.5× the throughput** — 962 kB/s against the CH9102's best usable 390 kB/s
- **no baud rate to keep synchronised** between two files, a trap that cost this project two
  debugging sessions
- **only rates of 12 MHz ÷ an integer work on the CH9102**, and the driver reports success at
  the others — a genuine hazard, independently confirmed
- **one less chip in the path**

Not "because UART loses data". That claim did not survive contact with a corrected instrument.
