# 00 — Glossary

Every term used in this project that is not plain English, with what it means **here**.

---

## Testing vocabulary

**Null test** — a test whose *correct answer is zero*. "Null" describes the **expected
result**, not the input. The input is completely real: real microphone, real audio, real
hardware. You run the system in a condition you already know is healthy and confirm the
error counters all read 0. If they do not, the thing you just changed broke something.
*Ours: run at 15 kHz where the link is only 33 % loaded, and require 0 lost, 0 overflow,
0 corrupted.*

**Positive control** — the opposite test: deliberately cause the fault so the detector
must fire. Proves the detector *can* fire at all. A smoke alarm that has never gone off
might be working, or might have a dead battery — you cannot tell without lighting a match.
*Ours: slow the UART until the FPGA is forced to discard bytes, and require the overflow
counter to climb.*

**Regression test** — re-running an old test after a change, to confirm the change did not
break something that used to work. A null test is often used as one.

**Hypothesis / falsifier** — a statement of what you expect *and* what observation would
prove you wrong. "The counter will climb" is a hypothesis; "the counter stays at 0 while
frames are lost" is its falsifier. A claim with no falsifier is not a hypothesis.

**Baseline** — the known-good measurement every later measurement is compared against.

---

## Signal chain

**I2S** (Inter-IC Sound) — the 3-wire digital audio protocol between the microphone and
the FPGA: a bit clock, a left/right select, and a data line.

**BCLK / SCK** — *bit clock*. One tick per bit of audio. The FPGA generates it.

**WS / LRCLK** — *word select*. Says whether the current bits belong to the left or right
channel. One full cycle of WS = one sample period, so **WS frequency = the sample rate**.

**SD** — *serial data*. The microphone's output; the only line the FPGA reads.

**UART** — a plain two-wire serial link (we only use one direction). Sends one byte as
10 bits: 1 start + 8 data + 1 stop. So **capacity in bytes/s = baud ÷ 10**.

**Baud** — bits per second on a UART wire. 2,000,000 baud = 200,000 bytes/s.

**8N1** — 8 data bits, No parity, 1 stop bit. The UART format we use.

**USB-CDC** — USB pretending to be a serial port; that is why the ESP32 shows up as
`/dev/cu.*` on your Mac.

---

## Inside the FPGA

**FPGA** — a chip whose logic you define. Yours is a Gowin GW1NSR-4C on a Tang Nano 4K.

**Verilog** — the language that logic is written in.

**Synthesis / Place & Route** — turning Verilog into a real circuit layout on the chip.
Roughly "compiling". Nothing you edit takes effect until this is re-run.

**Bitstream** (`.fs`) — the output file that is loaded onto the FPGA. *A stale bitstream —
running an old one while reading new source — has already cost this project a full
debugging session.*

**PLL** — a circuit that multiplies a clock frequency. Ours turns the board's 27 MHz
crystal into 24 MHz.

**FIFO** (First In, First Out) — a small buffer between a part that produces data in bursts
and a part that consumes it steadily. Independent read and write pointers let both run at
once; that is what keeps the stream continuous. Ours holds 64 bytes.

**Ping-pong / double buffering** — a *different* technique: two buffers, fill one while the
other is being emptied. Needed for block-at-a-time transfers (DMA). **Not** needed for our
byte-at-a-time UART, but will be for SPI.

**Clock domain** — a region of logic driven by one clock. Ours has exactly one (24 MHz).

**Synchroniser** — two flip-flops that safely bring an outside signal into a clock domain.

**Parameter** — a Verilog constant you can change in one place, e.g. `BCLK_DIV`.

---

## The frame

**Frame** — one packet: 4-byte sync + 6-byte header + 1024 bytes of audio + 2-byte
checksum = **1036 bytes**, sent once per 512 samples.

**Sync word** — the fixed pattern `AA 55 A5 5A` that marks a frame's start, so a receiver
can find its place mid-stream.

**Resync** — scanning forward to find the next sync word after losing alignment.

**`seq`** — the frame counter. Gaps in it = frames lost.

**`ovf`** — how many bytes the FPGA's FIFO had to throw away. Non-zero = *the FPGA* lost it.

**`cfg`** — the settings the frame was captured under, so the host can work out the sample
rate itself and every saved file is self-describing.

**Checksum** — all 1024 audio bytes added up. Receiver re-adds and compares. Detects
*corruption*, as opposed to `seq` which detects *absence*.

**Little-endian** — low byte first. `0x1234` goes on the wire as `34 12`.

**Payload rate vs wire rate** — payload = audio bytes only; wire = audio + framing.
At 15 kHz: 30,000 vs 30,352 B/s. **Compare wire rate against link capacity**, not payload.

---

## Measurement

**Drop rate** — frames lost ÷ frames expected. The headline number.

**Integrity** — did the bytes that arrived arrive *correct*? (checksum)

**Fidelity** — how good the recovered audio is: SNR, THD, ENOB. Different from integrity.

**"Accuracy" is not used here.** A digital link does not degrade gracefully — a byte is
either right or the frame is corrupt. Use *integrity* and *fidelity* instead.

**FFT** — turns a waveform into a spectrum: which frequencies are present. Lets you confirm
a 440 Hz tone reads as 440 Hz.

**Saturation** — demand exceeds capacity. A FIFO can absorb a *transient* overload; nothing
absorbs a *sustained* one.

---

## Milestones

| | |
|---|---|
| **M1** | make the chain work at all — done |
| **M2** | make it report its own failures honestly — nearly done |
| **M3** | raise the rate until it breaks; plot loss vs data rate |
| **M4** | replace UART with SPI, repeat M3, compare |
| **M5** | same frames over Wi-Fi |
