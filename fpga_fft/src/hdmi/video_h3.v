// video_h3.v — the H3 chain: microphone (or the H2 test tone) -> spectrum -> bars -> HDMI.
//   use_mic = 1: INMP441 through mic_source (with gain); 0: tone_gen, as in H2
module video_h3 #(
    parameter integer CLAMP = 32700
)(
    input  wire       pclk, fclk, rst,
    input  wire       use_mic,
    input  wire [2:0] gain,
    output wire       i2s_sck, i2s_ws,
    input  wire       i2s_sd,
    output wire       overrun,
    output wire       clipped,
    output wire       tmds_clk_p, tmds_clk_n,
    output wire [2:0] tmds_d_p, tmds_d_n
);
    wire signed [15:0] s_tone, s_mic;
    wire               v_tone, v_mic;
    tone_gen   u_tone (.clk(pclk), .rst(rst), .valid(v_tone), .sample(s_tone));
    mic_source u_mic  (.clk(pclk), .rst(rst), .i2s_sck(i2s_sck), .i2s_ws(i2s_ws), .i2s_sd(i2s_sd),
                       .gain(gain), .valid(v_mic), .sample(s_mic), .clipped(clipped));
    wire signed [15:0] s       = use_mic ? s_mic : s_tone;
    wire               s_valid = use_mic ? v_mic : v_tone;

    wire       bar_we, bar_done;
    wire [8:0] bar_addr;
    wire [9:0] bar_h;
    spectrum #(.GAIN_SHIFT(0), .CLAMP(CLAMP)) u_spec (
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
    reg [2:0] d1 = 0, d2 = 0;
    always @(posedge pclk) begin d1 <= {de, hs, vs}; d2 <= d1; end

    hdmi_out u_out (.pclk(pclk), .fclk(fclk), .rst(rst), .r(r), .g(g), .b(b),
                    .de(d2[2]), .hs(d2[1]), .vs(d2[0]),
                    .tmds_clk_p(tmds_clk_p), .tmds_clk_n(tmds_clk_n),
                    .tmds_d_p(tmds_d_p), .tmds_d_n(tmds_d_n));
endmodule
