# 08 — Troubleshooting

Problems actually hit during bring-up, and what they turned out to be.

## ESP32 receives 0 bytes

**Symptom.** Diagnostic firmware reported `rx total = 0` despite the FPGA appearing to
run and a common ground being present.

**False lead.** Missing ground. Adding it changed nothing.

**Actual cause.** The FPGA was still running the **old bitstream**. The giveaway was
scoping pin 39 and reading **270 kHz** — which is 27 MHz ÷ 100, the divider from the
*previous* `PLL_test` debug design, not 960 kHz from the new I2S design. The project had
never been re-synthesized after the source change.

**Fix.** Re-synthesize, place & route, and reprogram. Data appeared immediately at
exactly 30,120 B/s.

**Lesson.** Before debugging the data path, scope a clock and confirm its frequency
matches the *current* design. A wrong-but-plausible frequency is strong evidence of a
stale bitstream.

## Captured samples are exactly half scale

**Symptom.** Simulation showed every sample equal to the expected value shifted right by
one bit.

**Cause.** Off-by-one in the I2S capture window. The standard specifies a one-BCLK delay
after the WS edge, but the effective alignment depends on where in the BCLK period the
data is sampled.

**Fix.** Swept `CAP_START` over 0…3 in simulation against known patterns (`A5A5`,
`8000`, `7FFF`, `1234`). **`CAP_START = 2`** reproduced full scale exactly. Committed as
the default.

**If it recurs on hardware** — a known 440 Hz or 1 kHz tone reading half amplitude —
try `CAP_START = 1` or `3` and reprogram. This is the usual ±1 I2S alignment tweak.

## Testbench decoded garbage from a correct DUT

**Symptom.** The UART decoder in the testbench produced wrong bytes while the design
under test was actually fine.

**Two separate bugs, both in the testbench.**
1. It sampled bit 1 instead of bit 0 — wrong start phase.
2. It re-armed mid-byte, so a data bit that looked like a start bit triggered a false
   frame.

**Fix.** Sample bit `k` at `p == 17 + 12·k`, store on bit 7, and re-arm at
`p == 17 + 12·8` — during the stop bit, where the line is guaranteed idle.

**Lesson.** When simulation disagrees with a design you believe is correct, suspect the
testbench's decoder before the DUT.

## Verilog mistakes worth remembering

| Mistake | Correct form |
|---------|--------------|
| `end module` | `endmodule` |
| `output wire` assigned inside `always` | declare `output reg`, or drive with `assign` |
| `always @(negedge rst)` with `if (rst)` | active-low: `negedge rst_n` + `if (!rst_n)`; active-high: `posedge rst` + `if (rst)` |
| PLL `.reset(lock_12)` | `.reset(~lock_12 \| ~rst_n)` — PLLVR reset is active **high** |
| `.lock(lock)` with `lock` undeclared | declare the wire, or connect to the real port |
| Module name / port typos (`bclk` vs `BLK_gen`, `.is2_clk`) | match declarations exactly |

## macOS environment notes

- `timeout` is not available by default — use the tool's own timeout (e.g. pyserial's).
- The ESP32-S3 board enumerates through **CH9102**, so the port is
  `/dev/cu.wchusbserial*` and `Serial` is UART0. Set **USB CDC On Boot: Disabled** in the
  Arduino IDE; enabling it points `Serial` at native USB instead and nothing arrives.
