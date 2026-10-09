// top_54.v — 54 MHz build: the PLL doubles the 27 MHz crystal.
//   MHZ=54 fpga_fft/build.sh
//
// THE PLL (Gowin rPLL primitive, the same block the IP Core Generator configures)
//   out = in x (FBDIV_SEL + 1) / (IDIV_SEL + 1) = 27 x 2 / 1 = 54 MHz
//   Inside, a VCO runs at out x ODIV_SEL = 54 x 16 = 864 MHz, inside the GW2AR-18C's
//   allowed range (500-1250 MHz), and is divided back down by 16.
//   LOCK goes high once the output is stable; the design is held in reset until then.
module top_54 (
    input  wire       clk,         // 27 MHz crystal, pin 4 (a PLL input pin)
    input  wire       uart_rx,
    output wire       uart_tx,
    output wire [5:0] led
);
    wire clk54, locked;
    rPLL #(
        .FCLKIN("27"),
        .IDIV_SEL(0),              // ÷1
        .FBDIV_SEL(1),             // ×2
        .ODIV_SEL(16),             // VCO = 864 MHz
        .DEVICE("GW2AR-18C")
    ) u_pll (
        .CLKIN(clk), .CLKFB(1'b0), .RESET(1'b0), .RESET_P(1'b0),
        .FBDSEL(6'd0), .IDSEL(6'd0), .ODSEL(6'd0),
        .PSDA(4'd0), .DUTYDA(4'd0), .FDLY(4'd0),
        .CLKOUT(clk54), .LOCK(locked), .CLKOUTP(), .CLKOUTD(), .CLKOUTD3());

    fft_link #(.CLK_MHZ(54)) u_link (
        .clk(clk54), .clk_ok(locked), .uart_rx(uart_rx), .uart_tx(uart_tx), .led(led));
endmodule
