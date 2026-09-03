# Experiment M3-D — How fast can this UART chain actually go?

**Status:** planned
**Depends on:** M3 A/B/C complete — the knee is located at 100–103 % of capacity, the
instrument is proven in all three states, and the whole build/flash/capture loop is
automated.

---

## 1. Idea

M3 established *where* a UART link breaks relative to its own rating: **exactly at capacity,
and then as a cliff**. It did not establish **what that capacity can be raised to**.

Every M3 number was taken with link 1 at 2 Mbaud and link 2 at 921,600 or 2 Mbaud. Those
were inherited defaults, not measured limits. Before claiming SPI is necessary, the honest
question is: **how far can UART be pushed first?**

Three things are unknown and all three are measurable:

1. The highest rate **link 1** (FPGA → ESP32) can carry reliably.
2. The highest rate **link 2** (ESP32 → CH9102 → host) can carry reliably.
3. Whether **two microphones**, the most data this hardware can produce, can saturate a
   UART chain running at its own best speed.

If the answer to (3) is no, then "UART is not enough" is **not yet demonstrated by this
hardware**, and the report must say so plainly rather than assert it. That would make the
case for SPI rest on headroom and scalability rather than on measured failure — a weaker but
honest claim. If the answer is yes, the case is made by measurement.

## 2. Why raise link 1 before adding the second microphone

Two INMP441s at `BCLK_DIV = 8` offer **190,063 B/s**. Against a 2 Mbaud link that is **95 %**
— of *both* links at once, since they currently run at the same rate.

That is a badly designed experiment. With both links simultaneously at 95 %, a loss could
originate at either, and although `ovf` would still attribute it, the two constraints are
confounded: neither can be varied without the other being nearly as loaded.

Raising link 1 to 4 Mbaud puts it at **47.5 %** while link 2 stays at 95 %. **One binding
constraint, cleanly isolated.**

## 3. Hypotheses

> **H5 — link 1 at 4 Mbaud.** The FPGA can transmit and the ESP32 can receive 4,000,000 baud
> over the existing jumper wire with no loss at a light load (`BCLK_DIV = 25`, 30 kB/s,
> 7.6 % of capacity).
>
> *Falsifier:* frames fail to decode, or checksum/header errors appear at a load the link
> should carry trivially. That would indicate the ESP32's receiver or the wire itself, not
> throughput — a different limit, and a more interesting one.

> **H6 — link 1 has a ceiling below 8 Mbaud.** Sweeping `CLK_PER_BIT` 12 → 3 (2 → 8 Mbaud)
> at light load will find a rate above which frames stop decoding. The ESP32-S3's UART is
> specified to about 5 Mbaud, so the transition is expected between 4.8 and 6 Mbaud.
>
> *Falsifier:* it works at 8 Mbaud, in which case link 1 is not a constraint at all and the
> ceiling lies entirely on link 2.

> **H7 — link 2 has a ceiling above 2 Mbaud.** Sweeping `HOST_BAUD` 2 M → 6 M at light load
> will find the CH9102's usable ceiling. Its datasheet claims 6 Mbaud; the macOS driver may
> cap lower.
>
> *Falsifier:* 2 Mbaud is already the maximum, which would itself be the headline number —
> the bridge cannot deliver its rated speed.

> **H8 — two microphones cannot saturate the improved chain.** With link 1 and link 2 both
> at their measured maxima, 190,063 B/s will be comfortably carried, and **no amount of
> microphone data available to this project can overload it.**
>
> *Falsifier:* loss appears, which locates the real end-to-end ceiling and makes the case for
> SPI by direct measurement.

## 4. Test structure

```
  D1/D2: light load, the VARIABLE is link speed — this measures SIGNAL INTEGRITY,
         not throughput. At 30 kB/s neither link is remotely full; if frames stop
         decoding it is because the bits themselves stopped arriving correctly.

  INMP441 ─I2S─▶ FPGA ═══ link 1 ═══▶ ESP32 ═══ link 2 ═══▶ host
  BCLK_DIV=25     D1: 2M→8M swept          D2: 2M→6M swept
  30 kB/s         (CLK_PER_BIT 12→3)       (HOST_BAUD)
  fixed           D2: held at best         D1: held at 2M

  D3: both links at their measured best, the VARIABLE is DATA RATE
  2 × INMP441 ─▶ FPGA ─── link 1 ───▶ ESP32 ─── link 2 ───▶ host
   BCLK_DIV 25→8         best from D1              best from D2
   30 → 190 kB/s
```

**D1 and D2 are deliberately run at a load far below capacity.** A failure there cannot be
congestion; it can only be the receiver or the wire. That separation is the point.

## 5. Predictions

### D1 — link 1 (`CLK_PER_BIT`), light load

| `CLK_PER_BIT` | link 1 baud | capacity B/s | load at 30 kB/s | prediction |
|---|---|---|---|---|
| 12 | 2,000,000 | 200,000 | 15.2 % | works (established) |
| 8 | 3,000,000 | 300,000 | 10.1 % | works |
| **6** | **4,000,000** | **400,000** | **7.6 %** | **works — H5** |
| 5 | 4,800,000 | 480,000 | 6.3 % | marginal, near the ESP32's spec |
| 4 | 6,000,000 | 600,000 | 5.1 % | expected to fail |
| 3 | 8,000,000 | 800,000 | 3.8 % | expected to fail |

### D2 — link 2 (`HOST_BAUD`), light load

| `HOST_BAUD` | capacity B/s | prediction |
|---|---|---|
| 2,000,000 | 200,000 | works (established) |
| 3,000,000 | 300,000 | likely works |
| 4,000,000 | 400,000 | uncertain — CH9102 and macOS driver |
| 6,000,000 | 600,000 | at the datasheet limit |

### D3 — two channels at the best rates found

| channels | `BCLK_DIV` | offered B/s | % of link 1 @ 4 M | % of link 2 @ 2 M |
|---|---|---|---|---|
| 1 | 8 | 95,032 | 23.8 % | 47.5 % |
| **2** | **8** | **190,063** | **47.5 %** | **95.0 %** |

If D2 raises link 2 above 2 Mbaud, the 95 % column falls correspondingly and **H8 is
expected to hold** — two microphones will not be enough to break the chain.

## 6. Method notes

- **Both ends, always.** `CLK_PER_BIT` (`top.v`) and `FPGA_BAUD` (sketch) describe link 1;
  `HOST_BAUD` (sketch) and `--baud` (viewer) describe link 2. Each pair must change together
  and both must be **flashed**, not merely edited. `arduino-cli upload` does not compile —
  use `compile --upload`. This has already caused one wrong conclusion.
- **Increase the ESP32's RX buffer** before D1. The default `Serial1` receive buffer is 256
  bytes; at 400,000 B/s that is 640 µs of slack. Add `Serial1.setRxBufferSize(4096)` before
  `Serial1.begin(...)` so a scheduling hiccup in the pump loop cannot be mistaken for a
  link-speed limit.
- **Use `tools/probe_port.py` first** at each new rate. It reports the raw byte rate and
  whether any sync word is present, which separates "the wire is dead" from "the bytes are
  mangled" before the viewer is involved.
- **Failures are results.** A rate that does not work is a data point, not a setback. Record
  it in the table rather than retrying until it passes.

## 7. Results

*(fill in)*

### D1 — link 1 ceiling — **partial, interrupted**

**First pass (sync-word counting, MODE_DIAG, light load ~30 kB/s):**

| `CLK_PER_BIT` | baud | result |
|---|---|---|
| 12 | 2,000,000 | OK |
| 8 | 3,000,000 | OK |
| 6 | **4,000,000** | **OK — H5 held** |
| 5 | 4,800,000 | OK |
| 4 | 6,000,000 | OK |
| 3 | 8,000,000 | **LINK1 FAIL** (sync 0/s, 50 kB/s of garbage) |

**Then 8 Mbaud passed twice on re-test**, with the edits verified as applied. The boundary is
therefore **intermittent, not sharp** — and a marginal link is worse than a failed one,
because it works in a demo and quietly corrupts data in a measurement.

**Method revised.** Sync-word counting only asks "did any frame survive?"; a link with a rare
bit error still shows plenty of sync words while damaging payloads. Second pass runs
MODE_PUMP at the **highest data rate** (`BCLK_DIV = 8`, 95 kB/s — three times the bits) with
link 2 pinned at a known-good, 48 %-loaded 2 Mbaud, and counts **checksum and header errors
at the host**. Every error is then attributable to link 1.

**Second pass (error rate at 95 kB/s, 45 s per point):**

| link 1 baud | frames | bad payload | bad header | corrupt | verdict |
|---|---|---|---|---|---|
| 2,000,000 | 4044 | 0 | 0 | **0.000 %** | CLEAN |
| 4,000,000 | 4045 | 0 | 0 | **0.000 %** | CLEAN |
| 6,000,000 | 4048 | 0 | 0 | **0.000 %** | CLEAN |
| **8,000,000** | **8184 + 8184** | **0** | **0** | **0.000 %** | **CLEAN (two 90 s runs)** |
| **12,000,000** | **4044** | **0** | **0** | **0.000 %** | **CLEAN** (`CLK_PER_BIT = 2`) |

**Link 1 is clean at every rate tested, up to 12,000,000 baud** — 800,000 B/s, four times the
rate used throughout M3, with **zero errors in 16,368 frames** across two independent 90-second
runs.

**H6 is falsified.** It predicted link 1 would fail below 8 Mbaud, on the basis that the
ESP32-S3's UART is specified to about 5 Mbaud. It does not fail. The datasheet figure is
conservative, or applies to conditions this test does not reproduce.

**The earlier 8 Mbaud "failure" was a transient**, not a limit. It occurred on the first
attempt immediately after flashing, and never recurred in three subsequent runs totalling
over three minutes. Most likely the ESP32 had not settled when the capture began; the
two-second pause after flashing was evidently not always enough. Worth noting as a
methodological hazard: **a single failing run immediately after a reflash should be repeated
before it is believed.**

### D2 — link 2 ceiling — **no ceiling found**

Method revised to match D1: an error rate at full data rate, not sync counting. Link 1 pinned
at 6,000,000 baud (proven clean) and only 16 % loaded, so every error is attributable to
link 2.

| `HOST_BAUD` | capacity B/s | load | frames | bad payload | bad header | corrupt | verdict |
|---|---|---|---|---|---|---|---|
| 2,000,000 | 200,000 | 48 % | 4060 | 0 | 0 | **0.000 %** | CLEAN |
| 3,000,000 | 300,000 | 32 % | 4060 | 0 | 0 | **0.000 %** | CLEAN |
| 4,000,000 | 400,000 | 24 % | 4061 | 0 | 0 | **0.000 %** | CLEAN |
| **6,000,000** | **600,000** | **16 %** | **4061** | **0** | **0** | **0.000 %** | **CLEAN** |

**H7 held, and by a wide margin.** Link 2 was assumed for the whole of M3 to be limited to
921,600 baud — a value inherited from M1 and never measured. It runs cleanly at **6,000,000
baud, 6.5 times faster**, delivering 600,000 B/s with zero errors.

### The ceiling, bracketed

| `HOST_BAUD` | result | raw bytes arriving |
|---|---|---|
| 6,000,000 | **CLEAN** — 2667 frames, 0 errors | full rate |
| 6,500,000 | FAILS | **none** |
| 7,000,000 | FAILS | **none** |
| 7,500,000 | FAILS | **none** |
| 8,000,000 | FAILS | **none** |

**Zero bytes, not corrupted bytes.** That is a refusal, not signal degradation — so the
failure is not electrical.

### Which side refuses: a decisive test

With the ESP32 set to transmit at 6,500,000, the host was probed at several rates. If the
ESP32 were not transmitting, every probe would read zero. If it *is* transmitting, a
mismatched host rate must produce **garbage bytes, not silence**:

| host probe rate | bytes received |
|---|---|
| 6,500,000 | **0 B/s** |
| 6,000,000 | 47,853 B/s (garbage) |
| 4,000,000 | 46,885 B/s (garbage) |
| 2,000,000 | 22,386 B/s (garbage) |

**The ESP32 is transmitting perfectly well at 6.5 Mbaud.** The data is there. And asking
pyserial to open the port at that rate:

```
requested  6,000,000  ->  port reports 6,000,000   OK
requested  6,500,000  ->  REJECTED: OSError: [Errno 22] Invalid argument
requested  7,000,000  ->  REJECTED: OSError: [Errno 22] Invalid argument
requested  8,000,000  ->  REJECTED: OSError: [Errno 22] Invalid argument
requested 12,000,000  ->  REJECTED: OSError: [Errno 22] Invalid argument
```

**The limit is the macOS CH9102 driver, and it is exactly 6,000,000 baud.** The port cannot
be opened above it — this is a host software cap, not the bridge's electrical limit and not
the ESP32's. It coincides exactly with the CH9102's datasheet maximum of 6 Mbaud, so the
driver appears to enforce the spec rather than discover it.

**Highest usable link 2 rate: 6,000,000 baud = 600,000 B/s.**

### D3 — two channels

| channels | `BCLK_DIV` | offered B/s | drop % | ovf | verdict |
|---|---|---|---|---|---|
| | | | | | |

### Hypothesis outcomes

| | prediction | outcome |
|---|---|---|
| H5 | link 1 works at 4 Mbaud | ☑ **HELD** — 0.000 % corrupt over 4045 frames |
| H6 | link 1 fails below 8 Mbaud | ☒ **FALSIFIED** — clean at 12 Mbaud, the fastest a 24 MHz clock can produce. No ceiling found: link 1 is untestable further, not unbroken further. |
| H7 | link 2 exceeds 2 Mbaud | ☑ **HELD** — usable to 6 Mbaud, 6.5× the assumed limit; capped there by the macOS driver |
| H8 | 2 mics cannot saturate the improved chain | **very likely** — two mics are 24–32 % of the measured links |

### What D1 and D2 together mean

| | assumed for all of M3 | measured in M3-D | factor |
|---|---|---|---|
| link 1 | 2,000,000 baud | **≥ 12,000,000** (no failure found) | **6×** |
| link 2 | 921,600 baud | **6,000,000** (host driver cap) | **6.5×** |

Every M3 result was taken on a chain running at roughly a quarter to a sixth of what the
hardware will actually do. The knee measured in M3-C is real and correctly located — but it
is the knee of a link that was **needlessly slow**, not of UART as a technology.

**This makes H8 near-certain and it changes the project's conclusion.** Two INMP441s produce
190,063 B/s:

| against | load |
|---|---|
| link 1 at 12 Mbaud (1,200,000 B/s) | **15.8 %** |
| link 2 at 6 Mbaud (600,000 B/s) | **31.7 %** |

**The end-to-end UART ceiling for this system is 600,000 B/s**, set by the host's serial
driver rather than by any part of the hardware under study. That is the number the SPI
comparison must be measured against.

Saturating link 2 would need **6.4 channels** of 16-bit audio at 46,875 Hz — about **seven
INMP441s**. This project has two.

**Therefore: with this hardware, UART cannot be shown to fail.** The report must say so. The
case for SPI has to rest on headroom, scalability and cost-per-byte rather than on a measured
UART failure at audio rates — unless a synthetic load generator is added to push past what
microphones can produce.

## 8. Second-channel implementation (D3)

Hardware: a second INMP441 with **`L/R` → VDD**, sharing SCK, WS and SD with the first. No
new FPGA pins; the right-hand half of the existing 64-clock frame is already being generated
and is currently ignored.

`i2s_master_rx.v`: capture a second 24-bit word over `bit_cnt` 34…57 (the right slot's
`CAP_START + 32`), truncate to 16 bits, and emit both samples with one `sample_valid`.

`framer.v`: payload becomes interleaved L, R — 256 pairs per 1024-byte frame, so the frame
rate doubles while the frame size does not.

`top.v`: `NUM_CH = 2`, which the existing `cfg` field already carries to the host; the viewer
already reads the channel count and will need only its de-interleaving path added.

## 9. What this hands to M4

Whichever way H8 falls, M3-D produces the number the SPI comparison needs: **the measured
end-to-end ceiling of the UART chain, with each link's own limit identified separately.**

M4 then re-runs D3 over SPI. Since the capture logic, frame format and host analysis stay
identical, the difference between the two curves is the transport and nothing else.

**If H8 holds** — two microphones cannot break an optimised UART chain — that is worth
stating plainly. The argument for SPI becomes headroom and scalability (more channels, 24-bit
samples, lower CPU cost per byte) rather than a measured failure of UART at this scale. An
honest negative result is stronger than an overstated positive one.

---

## 10. D1 rerun at 54 MHz — **CEILING FOUND**

**2026-09-01** · `BCLK_DIV = 18` (46,875 Hz, 95 kB/s offered), link 2 pinned at a known-good
2 Mbaud and 48 % loaded, so every error is attributable to link 1. 45 s per point.

| `CLK_PER_BIT` | link 1 baud | capacity | frames | bad payload | bad header | lost | corrupt | verdict |
|---|---|---|---|---|---|---|---|---|
| 9 | 6,000,000 | 600 kB/s | 4044 | 0 | 0 | 0 | **0.000 %** | CLEAN |
| 8 | 6,750,000 | 675 kB/s | 4044 | 0 | 0 | 0 | **0.000 %** | CLEAN |
| 7 | 7,714,285 | 771 kB/s | 4041 | 0 | 0 | 0 | **0.000 %** | CLEAN |
| 6 | 9,000,000 | 900 kB/s | 4045 | 0 | 0 | 0 | **0.000 %** | CLEAN |
| 5 | 10,800,000 | 1,080 kB/s | 4045 | 0 | 0 | 0 | **0.000 %** | CLEAN |
| **4** | **13,500,000** | **1,350 kB/s** | **4045** | **0** | **0** | **0** | **0.000 %** | **CLEAN** |
| **3** | **18,000,000** | 1,800 kB/s | **3** | **3482** | **404** | **168** | **99.92 %** | **FAILING** |

**13,500,000 baud is the highest rate proven to work — 1,350,000 B/s. 18,000,000 fails.**

Stated precisely: 13.5 Mbaud is the fastest rate this system could *test successfully*, not
a measured breaking point. The true ceiling lies somewhere in `13.5 < ceiling <= 18`, and a
54 MHz clock divided by an integer offers nothing between those two values, so the interval
cannot be narrowed without changing the clock again.

Six consecutive rates with **zero errors in over 24,000 frames**, then near-total failure:
three intact frames out of 3889.

### The two failures are completely different in character

| | link 1 at 18 Mbaud | link 2 above 6 Mbaud |
|---|---|---|
| bytes arriving | **yes, at full rate** | **none at all** |
| frames intact | 3 of 3889 | — |
| nature | **graded** — bits mangled | **absolute** — port refused |
| cause | receiver or wire cannot resolve the bits | macOS driver returns `Errno 22` |

Link 2's limit is a **software refusal**: the port cannot be opened, so nothing is even
attempted. Link 1's is a **physical limit**: everything is attempted, and almost all of it
arrives wrong. A report should not describe these with the same word.

At 18 Mbaud the transmit pin toggles at up to 9 MHz on a jumper wire, and the ESP32-S3's
UART — clocked from 80 MHz — has only ~4.4 clock periods per bit to work with. Either could
be the binding constraint; separating them would need a scope on the wire, which is future
work rather than a claim to make now.

### The gap that cannot be closed at this clock

54 MHz divided by an integer gives 13.5 Mbaud (÷4) and 18 Mbaud (÷3) with **nothing in
between**. The ceiling is therefore bracketed to `13.5 < ceiling ≤ 18` and cannot be
narrowed further without changing the system clock again.

That is a fair place to stop: link 1 at 1,350 kB/s already carries **2.25× more than link 2's
600 kB/s cap**, so further precision on link 1 has no bearing on the chain's behaviour.

### A reporting bug this run exposed

The first summary read **111.5 % corrupt**, which is impossible. The denominator counted only
`frames_ok + checksum_errors`, omitting frames rejected for a bad header — which at 18 Mbaud
were 404 of them. Those frames *were* seen; their sync word was found. Corrected to
`ok + checksum_errors + header_errors`, the figure is **99.92 %**.

Worth noting because the bug was invisible at every other data point: with zero header errors
the two denominators are identical, so it only surfaced once a link failed badly enough to
corrupt headers. **A metric can be wrong for six clean measurements and only reveal it on the
seventh.**

## 11. Both links, characterised

| | measured limit | capacity | nature of the limit |
|---|---|---|---|
| **link 1** FPGA → ESP32 | **13.5 Mbaud proven, 18 fails** | **1,350,000 B/s** | physical — bits stop resolving |
| **link 2** ESP32 → host | **6 Mbaud** | **600,000 B/s** | software — macOS driver refuses to open the port |

**The chain's end-to-end ceiling is 600,000 B/s, set by link 2, and link 1 has 2.25× more
headroom than link 2 can use.**

Against that, two INMP441s at 46,875 Hz produce 190,063 B/s — **31.7 % of the ceiling**, and
14 % of what link 1 alone could carry. Neither link is this project's bottleneck at audio
rates, and the report should say so plainly rather than imply UART was outgrown.

The natural next experiment is the one that removes link 2's software cap entirely: the
ESP32-S3's **native USB**, which bypasses the CH9102 and its baud negotiation altogether.
