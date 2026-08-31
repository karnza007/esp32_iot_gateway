# M3-E — Raising the FPGA system clock: purpose

**Status:** proposal, awaiting confirmation. Nothing changed yet.

---

## 1. The observation that prompts this

To test link 1 above 6 Mbaud at a 24 MHz system clock, `CLK_PER_BIT` must be 3 (8 Mbaud) or
2 (12 Mbaud). **Two clocks per bit is the last usable value** — one would not be a UART.

Is that actually a problem? Partly. Being precise about which parts are and are not:

**Not a problem.** The transmitter is synchronous, so at `CLK_PER_BIT = 2` each bit is
*exactly* two clock periods wide. There is no accumulating error and no drift. The bit rate
is as accurate at 12 Mbaud as at 2 Mbaud.

**Genuinely a problem, three ways.**

1. **Granularity.** Available rates are `24 MHz / n`. Above 6 Mbaud the only choices are
   **8 Mbaud** and **12 Mbaud** — nothing between. If 12 Mbaud fails and 8 Mbaud works, the
   ceiling can only be reported as "somewhere in a 4 Mbaud-wide gap". The measurement cannot
   be refined, however long it is run.
2. **Edge placement.** Every transition on the TX pin is quantised to one 41.7 ns clock
   period. At 12 Mbaud a bit *is* 83 ns, so **one clock is half a bit**. Any additional skew
   — board trace, level shifting, receiver sampling offset — is a large fraction of the eye.
   There is no margin to give away.
3. **Nowhere to go.** Oversampling, fractional-baud generation, or a receiver on the FPGA
   side all need several clocks per bit. At two, none is possible.

The same coarseness affects the I2S side. At `BCLK_DIV = 8`, `SAMPLE_PT = (8+1)/4 = 2`, so
the microphone's data is sampled 2 clocks into a 4-clock high phase. That works — it is
proven over the whole M3 sweep — but the sample point can only be placed to within 25 % of
the high phase. With a faster clock the same divider ratio is expressed in more clocks and
the sample lands closer to centre.

**So the answer to "do you agree?" is yes, with a correction:** the current design is not
*inaccurate* at two clocks per bit, it is *unrefinable*. That is the reason to change it.

## 2. Purpose

Raise the FPGA system clock so that:

- **the baud ceiling can be located, not bracketed.** Finer `CLK_PER_BIT` granularity means
  the transition between working and failing can be narrowed to a few hundred kbaud instead
  of a 4 Mbaud gap;
- **every rate tested keeps a comfortable number of clocks per bit**, so a failure is
  attributable to the link rather than to the transmitter's own timing quantisation;
- **the I2S sample point sits nearer the centre** of the bit-clock high phase at the fastest
  sample rates;
- **there is headroom for what comes next** — an SPI master, a synthetic load generator, and
  a second microphone channel all consume clock cycles that 24 MHz does not have spare.

## 3. Candidate clocks

The PLL is configured by `defparam` values in `fpga/src/gowin_pllvr/gowin_pllvr.v`, so the
ratio can be changed by editing that file — the IP does not have to be regenerated in the
GUI. Current setting: `IDIV_SEL=8` (÷9), `FBDIV_SEL=7` (×8) → **27 × 8/9 = 24 MHz**,
VCO 768 MHz.

| clock | PLL ratio | `BCLK_DIV` for 46.875 kHz | UART rates available |
|---|---|---|---|
| 24 MHz (now) | ×8 / ÷9 | 8 | 2, 3, 4, 4.8, 6, **8, 12** |
| **96 MHz** | **×32 / ÷9** | **32** | 2, 3, 4, 6, 8, **9.6, 10.7, 12, 13.7, 16** |
| 120 MHz | ×40 / ÷9 | 40 | 2, 4, 5, 6, 7.5, 8.6, 10, **12, 13.3, 15, 17** |
| 189 MHz | ×7 / ÷1 | 63 | very fine, but a large jump in timing risk |

**Recommendation: 96 MHz.**

- Exactly 4× the present clock, so every existing divider simply scales by 4 and every sample
  rate used so far stays exactly reachable (`BCLK_DIV` 25 → 100 for 15 kHz, 8 → 32 for
  46.875 kHz).
- At 12 Mbaud it gives **8 clocks per bit** instead of 2.
- Between 8 and 16 Mbaud it offers five distinct rates where 24 MHz offers one.
- The PLL settings are conservative: PFD stays at 3 MHz, VCO at 768 MHz — identical to today,
  only the feedback divider changes.

120 MHz is the stretch option if finer granularity turns out to matter; the timing risk is
modestly higher and the sample rates remain exact.

## 4. Risks, and how each is checked

| risk | check |
|---|---|
| **Timing closure.** The design must meet setup timing at the new clock. | Gowin's place & route reports achieved Fmax; build first, read the report, and only program if Fmax exceeds the target with margin. This is a build-time check, before any hardware is touched. |
| **PLL will not lock.** | `lock_out` is already routed to pin 43, and the datapath is held in reset until it asserts. A failure to lock is visible, not silent. |
| **A subtle change in I2S capture.** `CAP_START = 2` was validated at 24 MHz. It is expressed in bit clocks, not system clocks, so it should be unaffected — but "should" is not "is". | `tb_chain` runs the whole datapath against a microphone model at every divider; re-run it at the new clock before building. Then a hardware null test against the recorded baseline. |
| **Wider counters.** `div_cnt` sizing derives from `$clog2(BCLK_DIV)`, so it widens automatically; `uart_tx`'s timer likewise. | Simulation covers this; the sweep script already verifies that the `cfg` the FPGA reports matches what was requested. |
| **Everything downstream silently mis-scales.** The host computes `fs = 24e6 / (64 × BCLK_DIV)` from a **hardcoded 24 MHz**. | This is the one that would corrupt results quietly. The clock must become part of `cfg`, or the constant must change in lockstep — see below. |

## 5. The one change that must not be got wrong

`host/inmp441_viewer.py` contains `FPGA_CLK_HZ = 24_000_000` and derives the sample rate
from it. If the FPGA clock changes and that constant does not, **every sample rate, every
FFT axis and every throughput prediction is wrong by the ratio — silently, with no error
raised.**

This project has already been caught three times by a parameter written in one place and
assumed in another (`CLK_PER_BIT`/`FPGA_BAUD`, `SAMPLE_RATE`, link 2's baud). The fix each
time was to make the data self-describing. The same applies here: the system clock should
travel in the frame, not live as a constant on the host.

Cheapest correct approach: **widen `cfg`'s reserved bits to carry a clock code** (e.g. 0 =
24 MHz, 1 = 96 MHz, 2 = 120 MHz), which costs no extra bytes — bits 15:10 are currently
reserved and read zero. The host then computes `fs` from what the FPGA actually reports, and
an old bitstream sending code 0 to a new host still works.

## 6. What this does *not* change

The frame format, the host analysis, the ESP32 firmware, the experiment design and every
result already recorded. M3-A/B/C stand as measured; they were taken at 24 MHz and remain
valid at 24 MHz. This raises the *ceiling of what can be tested next*, and does not
retrospectively alter anything measured.

## 7. Proposed sequence

1. Finish the current sweep at 24 MHz (link 1 at 12 Mbaud, link 2 at 8/10/12 Mbaud) so the
   coarse ceiling is on record **before** anything changes.
2. Add the clock code to `cfg`; update the host to derive `fs` from it. Verify at 24 MHz that
   nothing changed — a null test against the existing baseline.
3. Edit the PLL to 96 MHz. Build. **Read the timing report. Stop if Fmax is not comfortably
   above 96 MHz.**
4. Re-run `run_sims.sh` at the new dividers.
5. Hardware null test at 15 kHz and compare against `run-n25-null.csv`: same throughput, same
   audio, zero errors.
6. Only then resume the baud sweep, now with fine granularity.

Steps 2 and 5 are the ones that protect the existing results. Step 3's timing report is the
gate — if the design does not close at 96 MHz, the answer is a lower clock, not a rebuild of
the datapath.
