# 04 — Roadmap

## M1 — UART path end-to-end ✅ done

- [x] PLL 27 → 24 MHz, verified on a scope
- [x] `i2s_master_rx.v` — 64-BCLK I2S master, 24-bit read, truncate to 16
- [x] `uart_tx.v` — 8N1 at 2 Mbaud
- [x] `framer.v` — sync word + byte FIFO
- [x] ESP32-S3 transparent UART → USB-CDC pump
- [x] Python live viewer: waveform + FFT, fixed magnitude axis
- [x] Verified live: 30,120 B/s, sync every 1028 bytes, real audio (ambient RMS ≈ 228)

## M2 — Instrumentation 🟨 built and simulated; hardware run pending

Design: [`05-instrumentation.md`](05-instrumentation.md) · Plan:
[`plans/step1-instrumentation.md`](plans/step1-instrumentation.md)

- [x] Frame v2: `seq`, `ovf`, `cfg`, payload checksum
- [x] FIFO depth 32 → 64, with a real overflow counter
- [x] `BCLK_DIV` exposed as a top-level parameter
- [x] Viewer parses the header, derives `fs` from `cfg`
- [x] Viewer reports drop rate / overflow / checksum errors / throughput, once per second
- [x] Stats appended to CSV in `data/` for later plotting
- [x] Simulation: `tb_framer` (format + overflow positive control) — PASS
- [x] Simulation: `tb_chain` (full datapath) at all six sweep points — PASS
- [x] Host parser verified offline against a synthetic lossy stream
- [ ] **Hardware null test at `BCLK_DIV = 25`**: zero drops, zero overflow, ~30.35 kB/s
- [ ] **Hardware positive control**: raise `CLK_PER_BIT`, confirm `ovf` climbs, then restore

## M3 — Load sweep ⬜

- [ ] Second INMP441 with L/R → VDD, sharing SCK/WS/SD; capture the right half of the
      existing 64-clock frame (`bit_cnt` 34…57)
- [ ] Interleaved L,R payload; `cfg` reports 2 channels
- [ ] Sweep `N` = 25, 16, 12, 10, 8 (15.000 → 46.875 kHz)
- [ ] At each point record: drop rate, overflow bytes, checksum errors, throughput
- [ ] With a 1 kHz reference tone, also record **SNR**, **THD**, **SINAD → ENOB**
- [ ] Raise UART to 4 Mbaud (÷6) and show the bottleneck moves off the FPGA
- [ ] Produce the drop-rate-vs-data-rate curve — the headline result

## M4 — SPI transport ⬜

- [ ] FPGA SPI master; ESP32-S3 SPI slave with DMA
- [ ] Ping-pong (double) buffering on the ESP32 side — block-at-a-time handoff, which is
      where double buffering is genuinely required (unlike the UART byte stream)
- [ ] Re-run the M3 sweep unchanged; overlay both curves
- [ ] Push past the UART ceiling: more channels, or full 24-bit samples

## M5 — Wi-Fi gateway ⬜

- [ ] ESP32-S3 sends the same frames over UDP
- [ ] `--udp` reader in the viewer
- [ ] Compare against the wired transports (throughput, loss, latency, jitter)

## Metrics glossary

Terminology used consistently across the docs and the report:

| Term | Meaning |
|------|---------|
| **Frame drop rate** | `frames_lost / frames_expected`, from gaps in `seq` |
| **Overflow count** | bytes discarded inside the FPGA FIFO; localizes loss to the link |
| **Integrity / BER** | did the bytes that arrived arrive *correct*? — checksum + UART framing errors |
| **Fidelity** | how good is the recovered audio — SNR, THD, SINAD, ENOB |
| **Throughput** | delivered bytes per second at the host, vs. offered rate at the FPGA |

Note that **"accuracy" is not a metric here**. A digital link does not degrade
gracefully: a byte either arrives correct or the frame is corrupt. What degrades is
*fidelity*, and it degrades because dropped samples create discontinuities that smear
energy across the spectrum — which is why SNR is measured alongside drop rate rather
than instead of it.
