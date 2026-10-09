// video_h1.v — the H1 picture chain: timing -> test pattern -> HDMI output.
// Kept separate from the clocks so the simulation can drive it with its own clocks.
module video_h1 (
    input  wire       pclk, fclk, rst,
    output wire       tmds_clk_p, tmds_clk_n,
    output wire [2:0] tmds_d_p, tmds_d_n
);
    wire [11:0] x, y;
    wire        de, hs, vs, fs;
    video_timing u_tim (.clk(pclk), .rst(rst), .x(x), .y(y), .de(de), .hs(hs), .vs(vs),
                        .frame_start(fs));

    wire [7:0] r, g, b;
    test_pattern u_pat (.clk(pclk), .x(x), .y(y), .de(de), .frame_start(fs), .r(r), .g(g), .b(b));

    // the pattern takes one clock, so delay the sync signals by one to stay lined up
    reg de_d = 1'b0, hs_d = 1'b0, vs_d = 1'b0;
    always @(posedge pclk) {de_d, hs_d, vs_d} <= {de, hs, vs};

    hdmi_out u_out (.pclk(pclk), .fclk(fclk), .rst(rst), .r(r), .g(g), .b(b),
                    .de(de_d), .hs(hs_d), .vs(vs_d),
                    .tmds_clk_p(tmds_clk_p), .tmds_clk_n(tmds_clk_n),
                    .tmds_d_p(tmds_d_p), .tmds_d_n(tmds_d_n));
endmodule
