# 07 — Bring-up: where the code lives, how to program it, and the null test

Everything needed to get the M2 bitstream onto the board and confirm it is healthy.

---

## 1. Where everything lives

```
~/Capstone-Project/
│
├── fpga/                        ← the FPGA half
│   ├── i2s_capture.gprj         ← OPEN THIS IN GOWIN  (was PLL_test.gprj)
│   ├── src/
│   │   ├── top.v                ← the knobs: BCLK_DIV, CLK_PER_BIT, NUM_CH
│   │   ├── top.cst              ← pin assignments (don't touch)
│   │   ├── i2s_master_rx.v      ← talks to the microphone
│   │   ├── framer.v             ← builds frames, counts lost bytes
│   │   ├── uart_tx.v            ← sends bytes to the ESP32
│   │   └── gowin_pllvr/         ← the 27 -> 24 MHz PLL IP
│   ├── sim/                     ← testbenches; run_sims.sh runs them all
│   └── impl/                    ← created by Gowin on first build (gitignored)
│                                   the bitstream lands in impl/pnr/*.fs
│
├── firmware/fpga_uart_bridge/   ← the ESP32-S3 sketch (unchanged since M1)
│
├── host/inmp441_viewer.py       ← the viewer + link analyser
│
├── data/                        ← measurement CSVs land here (gitignored)
├── docs/                        ← this file and the rest
└── .venv/                       ← Python environment
```

**One rule:** the old copies at `~/FPGA_project/PLL_test` and `~/I2S_test` still exist and
are now out of date. Open `~/Capstone-Project/fpga/i2s_capture.gprj`, never the old
`PLL_test.gprj`, or the two will silently diverge.

---

## 2. Programming the FPGA

### Step 1 — open the project

Launch **GowinIDE**, then `File > Open Project`, and choose:

```
~/Capstone-Project/fpga/i2s_capture.gprj
```

Confirm the Design panel lists six files: `gowin_pllvr.v`, `i2s_master_rx.v`, `framer.v`,
`uart_tx.v`, `top.v`, `top.cst`.

### Step 2 — set the rate (only when changing a sweep point)

Open `fpga/src/top.v`. The first three lines of the module are the entire experiment:

```verilog
parameter integer BCLK_DIV    = 25,   // sample rate: fs = 24 MHz / (64 * BCLK_DIV)
parameter integer CLK_PER_BIT = 12,   // UART baud  = 24 MHz / CLK_PER_BIT
parameter integer NUM_CH      = 1
```

For the null test leave all three exactly as they are.

### Step 3 — build

In the Process panel, double-click **Place & Route**. That runs synthesis first, then
place & route. Wait for both to show a green tick.

The bitstream appears at `fpga/impl/pnr/i2s_capture.fs`.

### Step 4 — program

Plug the Tang Nano 4K in, then click the **Programmer** icon (or `Tools > Programmer`).

- **Series:** GW1NSR
- **Device:** GW1NSR-4C
- **Access Mode:** `Embedded Flash Mode`
- **Operation:** `embFlash Erase, Program`  — survives a power cycle
  *(`SRAM Program` also works and is faster, but is lost when power is removed)*
- **File:** `fpga/impl/pnr/i2s_capture.fs`

Click **Program/Configure**.

### Command line alternative (optional, not yet tried on this machine)

The IDE ships a CLI at
`/Applications/GowinIDE.app/Contents/Resources/Gowin_EDA/Programmer/bin/programmer_cli`:

```bash
programmer_cli -d GW1NSR-4C -r 5 --fsFile fpga/impl/pnr/i2s_capture.fs
```

`-r 5` is `embFlash Erase, Program`; `-r 2` is `SRAM Program`. Use the GUI if this does not
detect the cable — the Tang Nano 4K uses a BL702 USB-JTAG bridge rather than an FTDI chip,
and the GUI is the path already proven to work on this board.

### The rule that already cost a debugging session

**Re-run Place & Route AND re-program after every source edit.** Editing a `.v` file does
nothing on its own. Previously a whole session was lost to a stale bitstream; the giveaway
was a scope reading 270 kHz on the bit clock when the design called for 960 kHz — 270 kHz
was 27 MHz / 100, a divider from a design that had been replaced days earlier.

If something behaves impossibly, **scope pin 39 first.** It must read **960 kHz** with
`BCLK_DIV = 25`. Any other frequency means the chip is not running the code you are reading.

---

## 3. The null test

### What a null test is

A test whose correct answer is **nothing happened**.

You do not run it to discover something new. You run it to prove that a change you just
made did *not* break anything — by putting the system back in a condition you already know
the answer to, and checking you still get that answer.

### Why this one matters

M2 added counting machinery to a link that was already working. Two things could have gone
wrong, and they look identical from the outside:

1. The counters are wrong and will report nonsense during the real experiment.
2. The counters are fine, but the extra logic itself slowed the datapath enough to cause
   real loss — in which case every future measurement is contaminated by the measuring
   instrument.

So: run at **exactly the old settings** — `BCLK_DIV = 25`, 15 kHz, one channel — where you
already know from M1 that the link is only 15 % loaded and loses nothing. Any loss the
viewer reports at this rate is the instrumentation's fault, not the link's.

It also establishes the **baseline row** of your results table. Every later sweep point is
read against this one.

### Running it

```bash
cd ~/Capstone-Project
source .venv/bin/activate
python host/inmp441_viewer.py --csv data/run-n25-null.csv
```

Leave it for at least a minute.

### What passing looks like

```
  29 ok     0 lost (  0.00%)  ovf     0 (tot     0)  cksum   0    30.35 kB/s  [OK]
  29 ok     0 lost (  0.00%)  ovf     0 (tot     0)  cksum   0    30.35 kB/s  [OK]
```

| Field | Required | Why |
|-------|----------|-----|
| `ok` | ~29 per second | 15000 samples/s ÷ 512 per frame = 29.3 frames/s |
| `lost` | **0** | no gaps in the sequence numbers |
| `ovf` | **0** | the FPGA never had to discard a byte |
| `cksum` | **0** | nothing arrived corrupted |
| throughput | **~30.35 kB/s** | 29.3 frames/s × 1036 bytes |
| verdict | **`OK`** | |

The waveform and spectrum should look exactly as they did in M1 — quiet room flat, tap the
mic and it spikes, whistle and the peak follows your pitch.

### About that 30.35 vs the old 30.12

M1 measured **30,120 B/s**. This will read **30,352 B/s**. That rise is expected and is not
a fault: v2 frames are 1036 bytes instead of 1028, because of the 6-byte header and 2-byte
checksum. 29.3 × 1036 = 30,352. Seeing the old number instead would mean the board is still
running the M1 bitstream.

### If it fails

| Symptom | Most likely cause |
|---------|-------------------|
| No frames at all | stale bitstream, or `USB CDC On Boot` is Enabled on the ESP32 (must be **Disabled**) |
| Throughput reads 30.12 kB/s | old M1 bitstream still on the chip — re-run Place & Route |
| `ovf` climbing at 15 kHz | real problem: the link is only 15 % loaded, so this should be impossible |
| Checksum errors, no drops | wiring or signal integrity — check the common ground |
| Drops but `ovf` = 0 | ESP32/USB side dropping. Interesting, but should not happen this slow |

---

## 4. The positive control (do this straight after)

The null test proves the counters do not fire when they should not. It cannot prove they
fire when they should — a counter permanently stuck at zero passes the null test perfectly.

So break the link on purpose:

1. In `fpga/src/top.v`, set `CLK_PER_BIT = 48`. That is 500 kbaud instead of 2 Mbaud —
   a quarter of the throughput, far too slow for 15 kHz audio.
2. Re-run Place & Route, re-program.
3. Run the viewer. **The ESP32 sketch must also change to match**: edit
   `firmware/fpga_uart_bridge/fpga_uart_bridge.ino` and set `FPGA_BAUD` to `500000`,
   then re-upload — otherwise the ESP32 reads garbage and you learn nothing about the FIFO.

Expected:

```
  12 ok   17 lost ( 58.62%)  ovf  9421 (tot  9421)  cksum   4   12.43 kB/s  [LINK SATURATED (FPGA FIFO)]
```

The exact numbers do not matter. What matters is that **`ovf` climbs** and the verdict reads
`LINK SATURATED (FPGA FIFO)` — proving the counter is alive and correctly blames the FPGA
buffer rather than the gateway.

Then set `CLK_PER_BIT` back to `12`, restore `FPGA_BAUD` to `2000000`, re-program both, and
confirm the null test passes again. Only then is M2 finished and M3 safe to start.
