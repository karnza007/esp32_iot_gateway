// tb_hdmi.v — H1 check: simulate the picture chain down to the bits on the HDMI pins.
//
//   371.25 MHz (testbench) ─▶ Gowin CLKDIV ÷5 ─▶ 74.25 MHz ─▶ video_h1 ─▶ 4 serial lanes
//
// Uses Gowin's own simulation models of CLKDIV and OSER10 (IDE/simlib/gw2a/prim_sim.v),
// so the serializers behave as on the chip. Every bit that leaves the 4 lanes is written
// to +out=<file> as one hex digit: bit 3 = clock lane, bits 2..0 = data lanes 2..0.
// check_hdmi.py then decodes that stream like a monitor would and checks the picture.
// Runs two frames plus a few lines (~33.4 ms of simulated time, ~2.5 min): the checker
// uses the complete frame between the first and second VSYNC.
`timescale 1ps/1ps
module tb_hdmi;
    reg fclk = 1'b0;
    always #1347 fclk = ~fclk;                 // 2 x 1347 ps = 371.2 MHz

    reg rst = 1'b1;
    reg locked = 1'b0;                         // stands in for the PLL's LOCK, as in top_hdmi.v
    initial #20000 locked = 1'b1;              // (CLKDIV needs this low-to-high step to start)
    wire pclk;
    GSR GSR (.GSRI(1'b1));                     // Gowin's global set/reset, inactive
    CLKDIV #(.DIV_MODE("5")) u_div (.HCLKIN(fclk), .RESETN(locked), .CALIB(1'b0), .CLKOUT(pclk));

    wire       clk_p, clk_n;
    wire [2:0] d_p, d_n;
    video_h1 dut (.pclk(pclk), .fclk(fclk), .rst(rst),
                  .tmds_clk_p(clk_p), .tmds_clk_n(clk_n), .tmds_d_p(d_p), .tmds_d_n(d_n));

    integer f, nbits = 0;
    reg [8*256-1:0] fname;
    reg sampling = 1'b0;
    // a new bit leaves on every FCLK edge; sample each one 400 ps after the edge
    always @(fclk) if (sampling) begin
        #400;
        $fwrite(f, "%h", {clk_p, d_p});
        nbits = nbits + 1;
        if (nbits % 2000 == 0) $fwrite(f, "\n");
        if (clk_n !== ~clk_p || d_n !== ~d_p) begin
            $display("FAIL: N side is not the inverse of P at bit %0d", nbits);
            $finish;
        end
    end

    initial begin
        if (!$value$plusargs("out=%s", fname)) begin
            $display("usage: vvp tb_hdmi +out=<file>");
            $finish;
        end
        f = $fopen(fname, "w");
        repeat (20) @(posedge pclk);
        #1 rst = 1'b0;
        sampling = 1'b1;
        repeat (1650 * 1502) @(posedge pclk);  // two frames (2 x 750 lines) + 2 lines
        $fclose(f);
        $display("tb_hdmi: wrote %0d bits per lane", nbits);
        $finish;
    end
endmodule
