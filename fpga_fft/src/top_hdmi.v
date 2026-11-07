// top_hdmi.v — HDMI demo build (docs/plans/hdmi-demo.md). Step H3: live microphone spectrum.
//
// CONTROLS (the board's two buttons, and one external button)
//   pin 88 button (S1): next display mode, in turn  spectrogram -> bars -> waveform -> spectrogram
//                       (starts on the spectrogram; the waveform screen since 2026-11-06, before
//                       that bars <-> spectrogram; until 2026-11-04 S1 switched mic <-> test
//                       tone). The mic is on pins 25/26/29.
//   pin 87 button (S2): gain +6 dB, 0 -> +42 dB, then back to 0     (starts at 0 dB: the top
//                       16 of the mic's 24 bits)
//   pin 27, external button to 3.3 V (internal pull-down): auto-rotate on <-> frozen. On (at
//                       power-up), the display moves to the next mode every 6 s (10 s until
//                       2026-11-07); S1 also restarts the 6 s. (Until 2026-11-06 this button
//                       played the demo sweep,
//                       now in fpga_fft/archive/, git tag demo-sweep.)
// MUSIC (2026-11-06): host/play_song.py on the Mac -> the Tang's own USB cable (BL616 serial
//   port) -> pin 70 -> audio_rx.v -> i2s_tx.v -> the board's MAX98357A (pins 56 BCLK, 55 WS,
//   54 DIN, 51 PA_EN); credits and status go back to the Mac on pin 69.
// LEDs (lit when low), with LED_DIAG = 1:
//   2 = mic: SD wire active (seen high and low in the last 56 ms)
//   4 = trouble: the FFT overran, or the music had a bad packet, a gap or an underrun (last 56 ms)
//   5 = video PLL locked
//   0 = display mode: on = spectrogram
//   3 = display mode: on = waveform        (0 and 3 both off = bars)
//   1 = auto-rotate on
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
    input  wire       rot_btn,     // pin 27, external button to 3.3 V: 1 while pressed
    input  wire       uart_rx,     // pin 70: from the Mac (BL616 USB serial)
    output wire       uart_tx,     // pin 69: to the Mac
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
    // external button (pin 27) -> auto-rotate on / frozen
    wire [1:0] pressed_x;
    buttons u_btn_x (.clk(pclk), .btn({1'b0, rot_btn}), .pressed(pressed_x));
    localparam [29:0] ROT_CLOCKS = 30'd445_500_000;  // 6 s at 74.25 MHz
    reg [1:0]  mode    = 2'd1;                       // 0 = bars, 1 = spectrogram (power-up), 2 = waveform
    reg [2:0]  gain    = GAIN_START;
    reg        rot_on  = 1'b1;
    reg [29:0] rot_cnt = 0;
    wire       next    = pressed[0] || (rot_on && rot_cnt == ROT_CLOCKS - 1);
    always @(posedge pclk) begin
        if (next)         mode <= (mode == 2'd1) ? 2'd0 : (mode == 2'd0) ? 2'd2 : 2'd1;
        if (pressed[1])   gain <= gain + 1'b1;           // wraps 7 -> 0
        if (pressed_x[0]) rot_on <= ~rot_on;
        rot_cnt <= (next || pressed_x[0]) ? 30'd0 : rot_cnt + 1'b1;
    end

    // music from the Mac -> the speaker (not connected to the measuring chain)
    wire               a_req, a_trouble, a_playing;
    wire signed [15:0] a_sample;
    audio_rx #(.CLK_PER_BIT(25)) u_audio (.clk(pclk), .rst(vrst), .rx(uart_rx), .tx(uart_tx),
                     .req(a_req), .sample(a_sample), .pa_en(pa_en), .playing(a_playing),
                     .trouble(a_trouble));
    i2s_tx #(.HALF(24)) u_i2s (.clk(pclk), .rst(vrst), .sample(a_sample), .req(a_req),
                     .bclk(hp_bck), .ws(hp_ws), .din(hp_din));

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
            if (overrun || a_trouble) seen_bad <= 1'b1;
        end
    end

    // LEDs (lit when low): see the header.
    assign led = LED_DIAG ? {~locked, ~show_bad, ~(mode == 2'd2), ~(show_hi & show_lo),
                             ~rot_on, ~(mode == 2'd1)}
                          : {~locked, ~overrun, 1'b1, ~gain};
endmodule
