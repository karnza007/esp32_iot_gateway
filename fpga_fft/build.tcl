# Command-line build of the Gowin project:  fpga_fft/build.sh  (MHZ=54 or 81 for the PLL builds)
# build.sh passes TOP (top / top_54) and SDC; defaults are the 27 MHz build.
if {![info exists TOP]} { set TOP top }
if {![info exists SDC]} { set SDC src/top.sdc }
set_device -name GW2AR-18C GW2AR-LV18QN88C8/I7
add_file src/$TOP.v
add_file src/fft_link.v
add_file src/pll_clk.v
add_file src/uart_rx.v
add_file src/fft/fft_1024.v
add_file ../fpga/src/uart_tx.v
add_file src/top.cst
add_file $SDC
set_option -top_module $TOP
set_option -output_base_name fpga_fft
run all
