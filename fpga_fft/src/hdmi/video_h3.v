// video_h3.v — the H3/H4 chain: a sound source -> spectrum -> bars + text -> HDMI.
// H4 adds text_overlay (title, dB and kHz labels, tick lines) and peak_readout (the loudest
// frequency and its level), on top of the H3 bars.
//   src 0: tone_gen (the H2 test tone)
//   src 1: INMP441 wired to the FPGA, through mic_source
// (H3 also had src 2, the INMP441 on the ESP32 relayed over UART by relay_rx.v. It was taken
// out of the build on 2026-10-22: the direct mic works, so the relay is no longer needed.)
module video_h3 #(
    parameter integer CLAMP        = 32700,
    parameter integer MIC_BCLK_DIV = 52,     // mic bit clock = 74.25 MHz / this (see mic_source.v)
    parameter integer FLOOR_DB     = 80      // bottom of the dB scale: 80 or 100 (see spectrum.v)
)(
    input  wire       pclk, fclk, rst,
    input  wire [1:0] src,
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
    // the test tone runs at the microphone's sample rate: one sample per 64 bit clocks
    localparam integer   TONE_DIV = 64 * MIC_BCLK_DIV;
    localparam [63:0]    INC_1K   = ((64'd1000 * TONE_DIV) << 32) / 64'd74250000;   // 1 kHz step
    // the sweep step grows with the sample period, so 0 -> fs/2 always takes ~10 s (as in H2)
    localparam [63:0]    SWEEP    = (64'd4411 * TONE_DIV) / 64'd1536;
    tone_gen #(.SAMPLE_DIV(TONE_DIV), .SWEEP_STEP(SWEEP[31:0]), .INC2(INC_1K[31:0])) u_tone (
        .clk(pclk), .rst(rst), .valid(v_tone), .sample(s_tone));
    mic_source #(.BCLK_DIV(MIC_BCLK_DIV)) u_mic (.clk(pclk), .rst(rst), .i2s_sck(i2s_sck), .i2s_ws(i2s_ws), .i2s_sd(i2s_sd),
                       .gain(gain), .valid(v_mic), .sample(s_mic), .clipped(clip_mic));
    assign clipped = (src == 2'd1) ? clip_mic : 1'b0;

    wire signed [15:0] s       = (src == 2'd1) ? s_mic : s_tone;
    wire               s_valid = (src == 2'd1) ? v_mic : v_tone;

    wire       bar_we, bar_done;
    wire [8:0] bar_addr;
    wire [9:0] bar_h;
    spectrum #(.GAIN_SHIFT(0), .CLAMP(CLAMP), .FLOOR_DB(FLOOR_DB)) u_spec (
        .clk(pclk), .rst(rst), .s_valid(s_valid), .s_in(s),
        .bar_we(bar_we), .bar_addr(bar_addr), .bar_h(bar_h), .bar_done(bar_done),
        .overrun(overrun));

    wire [11:0] x, y;
    wire        de, hs, vs, fs;
    video_timing u_tim (.clk(pclk), .rst(rst), .x(x), .y(y), .de(de), .hs(hs), .vs(vs),
                        .frame_start(fs));
    wire [7:0] br, bg, bb;
    bar_display #(.FLOOR_DB(FLOOR_DB)) u_bars (.clk(pclk), .bar_we(bar_we), .bar_addr(bar_addr), .bar_h(bar_h),
                        .bar_done(bar_done), .x(x), .y(y), .de(de), .r(br), .g(bg), .b(bb));

    wire [76:0] dyn;
    peak_readout #(.MIC_BCLK_DIV(MIC_BCLK_DIV), .FLOOR_DB(FLOOR_DB)) u_peak (
        .clk(pclk), .rst(rst), .bar_we(bar_we), .bar_addr(bar_addr), .bar_h(bar_h),
        .bar_done(bar_done), .gain(gain), .dyn(dyn));
    wire [23:0] rgb;
    text_overlay u_text (.clk(pclk), .x(x), .y(y), .de(de), .src(src), .dyn(dyn),
                         .bar_rgb({br, bg, bb}), .rgb(rgb));

    // the final colour comes 4 clocks after x/y (text_overlay.v): sync signals are delayed by 4
    reg [2:0] d1 = 0, d2 = 0, d3 = 0, d4 = 0;
    always @(posedge pclk) begin d1 <= {de, hs, vs}; d2 <= d1; d3 <= d2; d4 <= d3; end

    hdmi_out u_out (.pclk(pclk), .fclk(fclk), .rst(rst), .r(rgb[23:16]), .g(rgb[15:8]), .b(rgb[7:0]),
                    .de(d4[2]), .hs(d4[1]), .vs(d4[0]),
                    .tmds_clk_p(tmds_clk_p), .tmds_clk_n(tmds_clk_n),
                    .tmds_d_p(tmds_d_p), .tmds_d_n(tmds_d_n));
endmodule
