# Command-line build of the Gowin project:  fpga_fft/build.sh  (MHZ=54 or 81 for the PLL builds)
# build.sh passes TOP (top / top_54) and SDC; defaults are the 27 MHz build.
if {![info exists TOP]} { set TOP top }
if {![info exists SDC]} { set SDC src/top.sdc }
if {![info exists CST]} { set CST src/top.cst }
set_device -name GW2AR-18C GW2AR-LV18QN88C8/I7
add_file src/$TOP.v
add_file src/fft_link.v
add_file src/pll_clk.v
add_file src/uart_rx.v
add_file src/fft/fft_1024.v
add_file ../fpga/src/uart_tx.v
add_file ../fpga/src/i2s_master_rx.v
add_file ../fpga/src/framer.v
add_file $CST
foreach f [glob -nocomplain src/hdmi/*.v] { add_file $f }
add_file $SDC
set_option -top_module $TOP
set_option -output_base_name fpga_fft
# pins 54-56 (the MAX98357A amplifier, HDMI build) are the SSPI configuration port unless freed;
# Sipeed's own audio example does the same. Configuration here is over JTAG, so SSPI is unused.
set_option -use_sspi_as_gpio 1
run all
