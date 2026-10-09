// pll_clk.v — multiply the 27 MHz crystal with the GW2AR-18C's rPLL block.
//
//   out = 27 MHz x MULT          (rPLL: FBDIV_SEL = MULT - 1, IDIV_SEL = 0, i.e. ÷1)
//   VCO = out x ODIV, and must stay inside 500-1250 MHz for this chip:
//     MULT 2 (54 MHz): ODIV 16 -> VCO 864 MHz
//     MULT 3 (81 MHz): ODIV  8 -> VCO 648 MHz   (16 would be 1296: too fast)
//   locked goes high once the output is stable.
// This is the same block Gowin's IP Core Generator configures; using it directly
// just skips the GUI.
module pll_clk #(
    parameter integer MULT = 2,
    parameter integer ODIV = 16
)(
    input  wire clk27,
    output wire clk_out,
    output wire locked
);
    rPLL #(
        .FCLKIN("27"),
        .IDIV_SEL(0),
        .FBDIV_SEL(MULT - 1),
        .ODIV_SEL(ODIV),
        .DEVICE("GW2AR-18C")
    ) u_rpll (
        .CLKIN(clk27), .CLKFB(1'b0), .RESET(1'b0), .RESET_P(1'b0),
        .FBDSEL(6'd0), .IDSEL(6'd0), .ODSEL(6'd0),
        .PSDA(4'd0), .DUTYDA(4'd0), .FDLY(4'd0),
        .CLKOUT(clk_out), .LOCK(locked), .CLKOUTP(), .CLKOUTD(), .CLKOUTD3());
endmodule
