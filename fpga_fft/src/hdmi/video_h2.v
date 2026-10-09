// video_h2.v — the H2 chain: test tone -> spectrum -> bars on the 720p picture -> HDMI.
module video_h2 #(
    parameter integer GAIN_SHIFT = 0,
    parameter integer CLAMP      = 32700
)(
    input  wire       pclk, fclk, rst,
    output wire       overrun,
    output wire       tmds_clk_p, tmds_clk_n,
    output wire [2:0] tmds_d_p, tmds_d_n
);
    wire signed [15:0] s;
    wire               s_valid;
    tone_gen u_tone (.clk(pclk), .rst(rst), .valid(s_valid), .sample(s));

    wire       bar_we, bar_done;
    wire [8:0] bar_addr;
    wire [9:0] bar_h;
    spectrum #(.GAIN_SHIFT(GAIN_SHIFT), .CLAMP(CLAMP)) u_spec (
        .clk(pclk), .rst(rst), .s_valid(s_valid), .s_in(s),
        .bar_we(bar_we), .bar_addr(bar_addr), .bar_h(bar_h), .bar_done(bar_done),
        .overrun(overrun));

    wire [11:0] x, y;
    wire        de, hs, vs, fs;
    video_timing u_tim (.clk(pclk), .rst(rst), .x(x), .y(y), .de(de), .hs(hs), .vs(vs),
                        .frame_start(fs));

    wire [7:0] r, g, b;
    bar_display u_bars (.clk(pclk), .bar_we(bar_we), .bar_addr(bar_addr), .bar_h(bar_h),
                        .bar_done(bar_done), .x(x), .y(y), .de(de), .r(r), .g(g), .b(b));

    // bar_display takes two clocks: delay the sync signals by two to stay lined up
    reg [2:0] d1 = 0, d2 = 0;
    always @(posedge pclk) begin d1 <= {de, hs, vs}; d2 <= d1; end

    hdmi_out u_out (.pclk(pclk), .fclk(fclk), .rst(rst), .r(r), .g(g), .b(b),
                    .de(d2[2]), .hs(d2[1]), .vs(d2[0]),
                    .tmds_clk_p(tmds_clk_p), .tmds_clk_n(tmds_clk_n),
                    .tmds_d_p(tmds_d_p), .tmds_d_n(tmds_d_n));
endmodule
