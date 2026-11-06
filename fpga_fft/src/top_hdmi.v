// top_hdmi.v — HDMI demo build (docs/plans/hdmi-demo.md). Step H3: live microphone spectrum.
//
// CONTROLS (the board's two buttons, and one external button)
//   pin 88 button (S1): display mode  bars <-> spectrogram   (starts on the spectrogram since
//                       2026-11-06, on bars before; until 2026-11-04 S1 switched mic <-> test
//                       tone). The mic is on pins 25/26/29.
//   pin 87 button (S2): gain +6 dB, 0 -> +42 dB, then back to 0     (starts at 0 dB: the top
//                       16 of the mic's 24 bits)
//   pin 27, external button to 3.3 V (internal pull-down; 2026-11-06): play the demo sweep,
//                       200 Hz -> 4 kHz in 4 s, through the board's MAX98357A amplifier
//                       (sweep_player.v; I2S on pins 56 BCLK, 55 WS, 54 DIN, 51 PA_EN)
// LEDs (lit when low), with LED_DIAG = 1:
//   2 = mic: SD wire active (seen high and low in the last 56 ms)
//   4 = trouble: the FFT overran (last 56 ms)
//   5 = video PLL locked
//   0 = display mode: on = spectrogram, off = bars
//   1 = the demo sweep is playing
//   3 = unused (off)
//   DESIGN=hdmi fpga_fft/build.sh
//
//   27 MHz crystal ─▶ rPLL ×55÷4 ─▶ 371.25 MHz ─────────────▶ serializers only (fclk)
//                                       └─▶ CLKDIV ÷5 ─▶ 74.25 MHz (pclk) ─▶ mic, FFT, bars, picture
//
// The ESP32 UART FFT benchmark (fft_link.v, pins 27/28) was built in here too until
// 2026-10-29. The demo never used it, so it was taken out; it has its own build (top.v:
// fpga_fft/build.sh with no DESIGN).
module top_hdmi #(
    parameter integer   CLAMP      = 32700, // input limit before the FFT (see spectrum.v)
    parameter [2:0]     GAIN_START = 3'd0,  // microphone gain at power-up: 0 dB (top 16 bits)
    parameter           LED_DIAG   = 1'b1   // 1: LEDs show input health (header)
)(
    input  wire       clk,         // 27 MHz crystal, pin 4
    output wire [5:0] led,
    output wire       i2s_sck,     // INMP441 SCK, pin 25
    output wire       i2s_ws,      // INMP441 WS,  pin 26
    input  wire       i2s_sd,      // INMP441 SD,  pin 29
    input  wire [1:0] btn,         // [0] = pin 88 (display mode), [1] = pin 87 (gain)
    input  wire       play_btn,    // pin 27, external button to 3.3 V: 1 while pressed
    output wire       hp_bck,      // MAX98357A BCLK,  pin 56
    output wire       hp_ws,       // MAX98357A LRCLK, pin 55
    output wire       hp_din,      // MAX98357A DIN,   pin 54
    output wire       pa_en,       // MAX98357A on,    pin 51
    output wire       tmds_clk_p, tmds_clk_n,
    output wire [2:0] tmds_d_p, tmds_d_n
);
    // ---- video clocks ----
    wire fclk, locked, pclk;
    pll_clk #(.MULT(55), .DIV(4), .ODIV(2)) u_pll (.clk27(clk), .clk_out(fclk), .locked(locked));
    CLKDIV #(.DIV_MODE("5")) u_div (.HCLKIN(fclk), .RESETN(locked), .CALIB(1'b0), .CLKOUT(pclk));

    // hold the picture chain in reset until the PLL has locked, plus 16 pixel clocks
    reg [4:0] vrst_cnt = 5'd0;
    always @(posedge pclk or negedge locked)
        if (!locked)            vrst_cnt <= 5'd0;
        else if (!vrst_cnt[4])  vrst_cnt <= vrst_cnt + 1'b1;
    wire vrst = !vrst_cnt[4];

    // buttons -> display mode and gain
    wire [1:0] pressed;
    buttons u_btn (.clk(pclk), .btn(btn), .pressed(pressed));
    reg       mode    = 1'b1;                       // 0 = bars, 1 = spectrogram (at power-up)
    reg [2:0] gain    = GAIN_START;
    always @(posedge pclk) begin
        if (pressed[0]) mode    <= ~mode;
        if (pressed[1]) gain    <= gain + 1'b1;          // wraps 7 -> 0
    end

    // external button -> the demo sweep through the speaker
    wire [1:0] pressed_x;
    buttons u_btn_x (.clk(pclk), .btn({1'b0, play_btn}), .pressed(pressed_x));
    wire sweep_on;
    sweep_player u_sweep (.clk(pclk), .rst(vrst), .start(pressed_x[0]),
                          .bclk(hp_bck), .ws(hp_ws), .din(hp_din), .pa_en(pa_en),
                          .playing(sweep_on));

    wire overrun, clipped;
    video_h3 #(.CLAMP(CLAMP)) u_video (
                      .pclk(pclk), .fclk(fclk), .rst(vrst), .mode(mode), .gain(gain),
                      .i2s_sck(i2s_sck), .i2s_ws(i2s_ws), .i2s_sd(i2s_sd),
                      .overrun(overrun), .clipped(clipped),
                      .tmds_clk_p(tmds_clk_p), .tmds_clk_n(tmds_clk_n),
                      .tmds_d_p(tmds_d_p), .tmds_d_n(tmds_d_n));

    // ---- diagnostics for the LEDs (LED_DIAG = 1; meanings in the header) ----
    // Each 56 ms window (2^22 clocks) records what happened; the LEDs show the last window.
    reg sd_m = 0, sd_s = 0;
    always @(posedge pclk) begin sd_m <= i2s_sd; sd_s <= sd_m; end
    reg [21:0] win = 0;
    reg seen_hi = 0, seen_lo = 0, seen_nz = 0, show_hi = 0, show_lo = 0, show_nz = 0;
    reg seen_bad = 0, show_bad = 0;
    always @(posedge pclk) begin
        win <= win + 1'b1;
        if (win == 0) begin
            {show_hi, show_lo, show_nz, show_bad} <= {seen_hi, seen_lo, seen_nz, seen_bad};
            {seen_hi, seen_lo, seen_nz, seen_bad} <= 4'b0000;
        end else begin
            if (sd_s)  seen_hi <= 1'b1;
            if (!sd_s) seen_lo <= 1'b1;
            if (u_video.u_mic.valid && u_video.u_mic.sample != 0) seen_nz <= 1'b1;
            if (overrun) seen_bad <= 1'b1;
        end
    end

    // LEDs (lit when low): see the header.
    assign led = LED_DIAG ? {~locked, ~show_bad, 1'b1, ~(show_hi & show_lo),
                             ~sweep_on, ~mode}
                          : {~locked, ~overrun, 1'b1, ~gain};
endmodule
