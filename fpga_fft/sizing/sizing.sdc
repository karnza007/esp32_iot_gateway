// judge timing as if clk ran at 54 MHz (the PLL rate the real design will use)
create_clock -name clk -period 18.519 [get_ports {clk}]
