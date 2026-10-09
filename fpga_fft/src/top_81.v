// top_81.v — 81 MHz build: the PLL triples the 27 MHz crystal (pll_clk.v).
//   MHZ=81 fpga_fft/build.sh
// Everything outside the FPGA is unchanged: the UART still runs at 1 Mbaud
// (81 clocks per bit), so only the FFT's own speed changes.
module top_81 (
    input  wire       clk,         // 27 MHz crystal, pin 4 (a PLL input pin)
    input  wire       uart_rx,
    output wire       uart_tx,
    output wire [5:0] led
);
    wire clk81, locked;
    pll_clk #(.MULT(3), .ODIV(8)) u_pll (.clk27(clk), .clk_out(clk81), .locked(locked));

    fft_link #(.CLK_MHZ(81)) u_link (
        .clk(clk81), .clk_ok(locked), .uart_rx(uart_rx), .uart_tx(uart_tx), .led(led));
endmodule
