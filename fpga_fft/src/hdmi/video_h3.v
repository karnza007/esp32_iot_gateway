// video_h3.v — the H3 chain: a sound source -> spectrum -> bars -> HDMI.
//   src 0: tone_gen (the H2 test tone)
//   src 1: INMP441 wired to the FPGA, through mic_source
//   src 2: INMP441 wired to the ESP32, relayed over UART (relay_rx)
// Both microphone paths go through the same gain24 block, so gain behaves identically.
module video_h3 #(
    parameter integer CLAMP = 32700
)(
    input  wire       pclk, fclk, rst,
    input  wire [1:0] src,
    input  wire       relay_in,       // UART from the ESP32 (pin 27, shared with the benchmark)
    output wire       pkt_ok, pkt_bad,
    input  wire [2:0] gain,
    output wire       i2s_sck, i2s_ws,
    input  wire       i2s_sd,
    output wire       overrun,
    output wire       clipped,
    output wire       tmds_clk_p, tmds_clk_n,
    output wire [2:0] tmds_d_p, tmds_d_n
);
    wire signed [15:0] s_tone, s_mic;
    wire               v_tone, v_mic, clip_mic;
    tone_gen   u_tone (.clk(pclk), .rst(rst), .valid(v_tone), .sample(s_tone));
    mic_source u_mic  (.clk(pclk), .rst(rst), .i2s_sck(i2s_sck), .i2s_ws(i2s_ws), .i2s_sd(i2s_sd),
                       .gain(gain), .valid(v_mic), .sample(s_mic), .clipped(clip_mic));
    assign clipped = (src == 2'd1) ? clip_mic : (src == 2'd2) ? clip_rel : 1'b0;
    wire [23:0]        w_rel;
    wire               v_rel24, v_rel, clip_rel;
    wire signed [15:0] s_rel;
    relay_rx u_relay (.clk(pclk), .rst(rst), .rx(relay_in), .valid(v_rel24), .word(w_rel),
                      .pkt_ok(pkt_ok), .pkt_bad(pkt_bad));
    gain24   u_relgain (.clk(pclk), .v_in(v_rel24), .w_in(w_rel), .gain(gain),
                        .valid(v_rel), .sample(s_rel), .clipped(clip_rel));

    wire signed [15:0] s       = (src == 2'd1) ? s_mic : (src == 2'd2) ? s_rel : s_tone;
    wire               s_valid = (src == 2'd1) ? v_mic : (src == 2'd2) ? v_rel : v_tone;

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
