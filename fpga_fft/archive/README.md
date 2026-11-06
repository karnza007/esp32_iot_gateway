# fpga_fft/archive

Kept for reference, not part of any build (`build.tcl` only adds `src/` and `src/hdmi/`).

| File | What | Last used |
|---|---|---|
| `sweep_player.v` | demo sweep through the MAX98357A: 200 Hz <-> 4 kHz, 4 s each way, plus tones at 1.5x and 2x (-12 dB); the pin-27 button toggled it | git tag `demo-sweep` (`a80d8a3`), weekly report 2026-11-08 §15-17 |
| `tb_sweep.v`, `check_sweep.py` | its tests: I2S wires decoded, every sample compared with a model | same |

Replaced on 2026-11-06 by music from the Mac over the Tang's USB serial port (`src/hdmi/audio_rx.v`,
`src/hdmi/i2s_tx.v`; I2S output taken from `sweep_player.v`). To run the old tests from the repo
root of `fpga_fft`: `iverilog -g2012 -s tb_sweep -o sw.vvp archive/tb_sweep.v archive/sweep_player.v
src/hdmi/rom_sine.v && vvp sw.vvp +out=sweep.txt && python archive/check_sweep.py sweep.txt`.
To rebuild the board as it was: `git checkout demo-sweep`.
