# build.tcl — command-line synthesis + place & route.
#   run from the fpga/ directory:  gw_sh build.tcl
# Output: fpga/impl/pnr/i2s_capture.fs
set_device -name GW1NSR-4C GW1NSR-LV4CQN48PC6/I5
add_file src/gowin_pllvr/gowin_pllvr.v
add_file src/i2s_master_rx.v
add_file src/framer.v
add_file src/uart_tx.v
add_file src/top.v
add_file src/top.cst
set_option -top_module top_module
set_option -output_base_name i2s_capture
run all
