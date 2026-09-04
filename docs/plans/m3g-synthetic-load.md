# M3-G — Synthetic load generator: saturating the real protocol

**Status:** proposed, awaiting confirmation. Nothing written yet.

---

## 1. Why

Every link has now been characterised **in isolation**:

| | capacity | how it was measured |
|---|---|---|
| link 1 (FPGA → ESP32) | 1,350,000 B/s | error rate at 95 kB/s, sweeping the baud |
| link 2 (ESP32 → host) | 969,619 B/s | a byte-blast from the ESP32, no FPGA involved |

Neither measurement used the **actual protocol**. The blast test sent a bare counter with no
sync words, no headers, no checksums and no FIFO. The link-1 sweep sent real frames but only
95 kB/s of them — 7 % of that link.

**So the frame format, the FIFO, the overflow counter and the attribution logic have never
been exercised at saturation end to end.** M3 tried to, and could not: audio tops out at
190 kB/s with two microphones, which is 19 % of link 2.

The generator removes the microphone from the equation.

## 2. What it is

A second source of `sample` / `sample_valid`, selected by a top-level parameter, that
produces a **counting pattern at a configurable rate**. Everything downstream — framer,
FIFO, header, both checksums, UART, gateway, host parser — stays byte-for-byte identical.

```
                        GEN_MODE = 0
  INMP441 ─I2S─▶ i2s_master_rx ──┐
                                  ├──▶ sample / sample_valid ──▶ framer ──▶ uart_tx ──▶ ...
             sample_gen ─────────┘         (unchanged from here on)
                        GEN_MODE = 1
```

`sample_gen.v` is about thirty lines: a counter that divides the system clock by `GEN_DIV`
to make `sample_valid`, and a 16-bit value that increments once per sample.

**Rate:** `fs = 54 MHz / GEN_DIV`, so the offered rate is **continuous**. No 3.2 MHz
microphone ceiling, and no `BCLK_DIV ≥ 17` constraint — any integer divider works, which is
what makes a proper curve possible.

## 3. What the payload buys us

The samples are a 16-bit counter, so the host can check that **every sample is exactly one
more than the last, across frame boundaries as well as within a frame.**

That is a second, independent loss measurement standing beside `seq`:

| measurement | what it counts | granularity |
|---|---|---|
| `seq` gaps | whole frames that never arrived | 512 samples |
| `ovf` | bytes the FPGA discarded | 1 byte |
| **sample counter** | **individual samples lost anywhere** | **1 sample** |

When two independent mechanisms agree, both are probably right — the same argument that made
the M2 positive control convincing, where `ovf` and `bytes_missing` matched to 0.000 %.

## 4. Telling the host it is synthetic

`cfg` has no spare bits: `[7:0]` is `BCLK_DIV`, `[9:8]` channels, `[15:10]` the clock code.

Rather than widen the frame again, use the **unused channel-count value 3**. `NUM_CH` is 1 or
2 for real microphones; 3 is otherwise meaningless, so `cfg[9:8] = 3` reads as "payload is a
counter, not audio". Costs nothing, breaks nothing, and an older host simply sees an
implausible channel count and says so.

The host does not need `GEN_DIV` — it can measure the delivered rate directly, and the
offered rate is known from the divider we set.

## 5. The experiment

Two configurations, chosen so that **each one saturates a different link**, exercising both
halves of the attribution logic at full load with the real protocol.

### Config 1 — link 1 is the constraint

Link 1 at 2 Mbaud (200,000 B/s), link 2 on native USB (969,619 B/s, nearly 5× more). The
FPGA's FIFO must overflow first.

| offered | `GEN_DIV` | fs (Hz) | wire B/s | prediction |
|---|---|---|---|---|
| 25 % | 2190 | 24,658 | 49,989 | clean |
| 50 % | 1095 | 49,315 | 99,979 | clean |
| 75 % | 730 | 73,973 | 149,968 | clean |
| 90 % | 608 | 88,816 | 180,060 | clean |
| **100 %** | **547** | **98,720** | **200,140** | **the knee** |
| 110 % | 498 | 108,434 | 219,832 | `ovf` rising, `LINK SATURATED (FPGA FIFO)` |
| 150 % | 365 | 147,945 | 299,936 | heavy loss |

### Config 2 — link 2 is the constraint

Link 1 raised to 13.5 Mbaud (1,350,000 B/s, its proven ceiling), link 2 on native USB
(969,619 B/s). Now the FPGA has ample headroom and the gateway must give way first.

| offered | `GEN_DIV` | fs (Hz) | wire B/s | prediction |
|---|---|---|---|---|
| 25 % | 452 | 119,469 | 242,205 | clean |
| 50 % | 226 | 238,938 | 484,410 | clean |
| 75 % | 151 | 357,616 | 725,010 | clean |
| 90 % | 125 | 432,000 | 875,812 | clean |
| **100 %** | **113** | **477,876** | **968,819** | **the knee** |
| 110 % | 103 | 524,272 | 1,062,879 | loss with **`ovf` = 0**, `GATEWAY LOSS` |
| 150 % | 75 | 720,000 | 1,459,688 | heavy loss |

## 6. Hypotheses

> **H9 — the knee is at capacity, again.** Both configurations will be clean to 100 % of the
> binding link's measured capacity and lose data past it, reproducing the M3-C result with a
> load that is generated rather than sampled.
>
> *Falsifier:* loss appears well below 100 %, which would mean the protocol itself (the
> header burst, the FIFO, the checksum) costs capacity that the isolated measurements missed.

> **H10 — attribution is correct at real saturation.** Config 1 reads
> `LINK SATURATED (FPGA FIFO)` with `ovf` rising; config 2 reads `GATEWAY LOSS (ESP32/USB)`
> with `ovf` at 0.
>
> *Falsifier:* either verdict appears in the wrong configuration. This has been tested before,
> but never with both links carrying more than 200 kB/s.

> **H11 — the two loss measures agree.** Samples missing according to the payload counter
> will match samples missing according to `seq` gaps and `bytes_missing`, within the
> granularity of each.
>
> *Falsifier:* they disagree, which would mean one of them has been wrong all along — and
> every earlier number would need revisiting.

## 7. Verification before hardware

- `tb_gen.v`: the generator alone — correct rate, counter increments once per `sample_valid`.
- `tb_chain.v` re-run in generator mode: the frame payload must be the counter sequence,
  proving the mux did not disturb the datapath.
- The existing audio path must still pass unchanged with `GEN_MODE = 0` — the whole point is
  that nothing downstream changes.
- Host: extend `tools/test_viewer_parser.py` with a synthetic stream containing a deliberate
  sample-level gap.

## 8. Cost

| | |
|---|---|
| `fpga/src/sample_gen.v` | ~30 lines |
| `top.v` | a parameter, a mux, `NUM_CH = 3` in `cfg` |
| `host/inmp441_viewer.py` | verify the counter when `cfg[9:8] == 3` |
| `tools/sweep_gen.sh` | drive the two sweeps |
| run time | 14 points × (62 s + 45 s) ≈ **25 minutes** |

Roughly an hour including the simulation work.

## 9. What it hands to M4

The SPI comparison currently has a weak baseline: **UART never failed under audio load.**
Comparing SPI against a transport that was never stressed would show "SPI is also fine".

With the generator, both transports get a load that genuinely saturates them, measured with
the identical frame format and the identical host analysis. The difference between the two
curves is then the transport and nothing else — which is the whole point of the project.
