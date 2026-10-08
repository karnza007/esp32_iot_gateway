# F1 sizing build:  cd fpga_fft/sizing && gw_sh sizing.tcl
set_device -name GW1NSR-4C GW1NSR-LV4CQN48PC6/I5
add_file ../src/fft/fft_1024.v
add_file sizing_top.v
add_file sizing.cst
add_file sizing.sdc
set_option -top_module sizing_top
set_option -output_base_name sizing
run all
