// the board's own 27 MHz crystal, no PLL (docs/plans/fft-benchmark.md §4)
create_clock -name clk -period 37.037 [get_ports {clk}]
