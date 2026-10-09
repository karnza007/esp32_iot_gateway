// top_54.v — 54 MHz build: the PLL doubles the 27 MHz crystal (pll_clk.v).
//   MHZ=54 fpga_fft/build.sh
// Everything outside the FPGA is unchanged: the UART still runs at 1 Mbaud
// (54 clocks per bit), so only the FFT's own speed changes.
module top_54 (
    input  wire       clk,         // 27 MHz crystal, pin 4 (a PLL input pin)
    input  wire       uart_rx,
    output wire       uart_tx,
    output wire [5:0] led
);
    wire clk54, locked;
    pll_clk #(.MULT(2), .ODIV(16)) u_pll (.clk27(clk), .clk_out(clk54), .locked(locked));

    fft_link #(.CLK_MHZ(54)) u_link (
        .clk(clk54), .clk_ok(locked), .uart_rx(uart_rx), .uart_tx(uart_tx), .led(led));
endmodule
