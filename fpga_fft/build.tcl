# Command-line build of the Gowin project:  fpga_fft/build.sh  (or: gw_sh build.tcl)
set_device -name GW2AR-18C GW2AR-LV18QN88C8/I7
add_file src/top.v
add_file src/uart_rx.v
add_file ../fpga/src/uart_tx.v
add_file src/top.cst
add_file src/top.sdc
set_option -top_module top
set_option -output_base_name fpga_fft
run all
