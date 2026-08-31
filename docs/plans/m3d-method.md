# M3-D method — telling the two links apart when either might be the one failing

**Status:** proposed, awaiting confirmation

---

## The problem this solves

D1 and D2 test each link's maximum speed at a load far below capacity, so a failure can only
be the receiver or the wire. But **both failures look identical at the host**:

| what actually failed | what the host sees |
|---|---|
| link 1 too fast — the ESP32 misreads the FPGA | bytes arrive, nothing decodes |
| link 2 too fast — the host misreads the ESP32 | bytes arrive, nothing decodes |

The ESP32 forwards whatever it received, faithfully. If it received garbage, it forwards
garbage, and the host cannot tell whether the garbage was created before or after the
gateway.

**The gateway is the only place that knows.** It sits between the two links and sees link 1's
data before link 2 touches it.

## The fix: a diagnostic mode in the gateway

The sketch gains a compile-time mode.

**`MODE_PUMP`** — today's behaviour, unchanged. Used for all real measurements.

**`MODE_DIAG`** — the ESP32 stops forwarding and instead **validates link 1 itself**, then
reports over link 2 in plain text, twice a second:

```
GWDIAG hb=42 rx=1520384 sync=1467 rate=30352 baud1=4000000 baud2=2000000
```

- `rx` — bytes received on link 1 since boot
- `sync` — how many times the FPGA's sync word `AA 55 A5 5A` was seen **by the ESP32**
- `rate` — link 1 byte rate the ESP32 measured
- `baud1` / `baud2` — the rates it is configured for, so the line is self-describing

Short plain-text lines, no framing to lose, no interleaving with FPGA data. A line either
arrives readable or it does not.

## How this discriminates

| `GWDIAG` lines readable? | `sync` count | conclusion |
|---|---|---|
| yes | ≈ expected frame rate | **both links fine at these rates** |
| **yes** | **≈ 0** | **link 1 has failed** — the ESP32 is fine and is telling us it cannot read the FPGA |
| **no** | — | **link 2 has failed** — the gateway is unreachable |

The middle row is the one that matters, and it is only possible because the report comes from
the gateway itself. A readable `GWDIAG` line **is** proof that link 2 works, whatever link 1
is doing.

## Why not interleave a heartbeat into the normal stream

Considered and rejected. Inserting a 16-byte gateway packet into the pumped byte stream
splits whichever FPGA frame is in flight, so every heartbeat destroys one frame. At one per
second against ~29 frames/s that is **3.4 % artificial loss injected into every
measurement** — the instrument would be corrupting the thing it measures.

A separate mode costs one recompile per sweep point, which is already automated, and costs
the measurement nothing.

## Procedure

**D1 — link 1's ceiling.** Link 2 held at 2,000,000 (known good). `BCLK_DIV = 25`, ~7 % load.
For `CLK_PER_BIT` in 12, 8, 6, 5, 4, 3:

1. set `CLK_PER_BIT` in `top.v` and `FPGA_BAUD` in the sketch (both describe link 1)
2. build the FPGA, program to SRAM
3. compile + upload the sketch in `MODE_DIAG`
4. read `GWDIAG` lines for 10 s
5. classify: both fine / link 1 failed / link 2 failed

**D2 — link 2's ceiling.** Link 1 held at the best rate D1 found. For `HOST_BAUD` in
2 M, 3 M, 4 M, 6 M: same loop, changing only `HOST_BAUD` and the viewer's `--baud`.

**D3 — the real measurement.** Back to `MODE_PUMP`, both links at their measured best, then
sweep `BCLK_DIV` 25 → 8 with one channel, and again with two once the second microphone is
wired.

## Changes required

| file | change |
|---|---|
| `firmware/.../fpga_uart_bridge.ino` | add `MODE_DIAG`; raise `Serial1` RX buffer to 4096 |
| `tools/sweep_link.sh` | new — drives D1/D2, parses `GWDIAG`, classifies each point |
| `host/inmp441_viewer.py` | unchanged |
| `fpga/src/*` | unchanged for D1/D2; second channel only for D3 |

## What could still go wrong, and how it will show

- **The ESP32's pump loop, not the link, is the limit.** Guarded by raising the RX buffer to
  4096 bytes before D1; if `rx` keeps up but `sync` drops, that is a decode failure, not a
  buffer overrun.
- **A rate the CH9102 silently rounds.** `GWDIAG` carries `baud2`, so a line that arrives
  with the wrong `baud2` value would reveal it.
- **A stale binary.** `arduino-cli compile --upload` throughout — never bare `upload`.
