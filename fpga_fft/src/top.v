// top.v — 27 MHz build: the board's crystal drives the design directly (no PLL).
//   fpga_fft/build.sh            (default)
module top (
    input  wire       clk,         // 27 MHz crystal, pin 4
    input  wire       uart_rx,     // from ESP32 GPIO17
    output wire       uart_tx,     // to ESP32 GPIO18
    output wire [5:0] led
);
    fft_link #(.CLK_MHZ(27)) u_link (
        .clk(clk), .clk_ok(1'b1), .uart_rx(uart_rx), .uart_tx(uart_tx), .led(led));
endmodule
