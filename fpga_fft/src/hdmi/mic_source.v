// mic_source.v — INMP441 microphone in, 16-bit samples out, with a selectable gain.
//
//   INMP441 ─I2S─▶ i2s_master_rx (fpga/src, shared with the audio project) ─▶ 24-bit word
//                    ─▶ gain: pick 16 of the 24 bits ─▶ saturate ─▶ 16-bit sample
//
// CLOCKS: bit clock = 74.25 MHz / 77 = 964.3 kHz (the INMP441 allows 0.5-3.2 MHz);
// 64 bit clocks per frame -> 15,067.0 samples/s, so the screen spans 0-7.5 kHz (14.7 Hz per bar).
// 964 kHz is the bit clock the mic was proven clean with on pins 25/26/29 (top_mic_uart.v,
// 27 MHz / 28) and on the Tang Nano 4K (54 MHz / 56), 2026-10-21. 3.09 MHz (BCLK_DIV 24, the
// rate of tone_gen) was never seen working on this board.
//
// GAIN: see gain24.v (shared with relay_rx.v, the ESP32 path).
module mic_source #(
    parameter integer BCLK_DIV = 77
)(
    input  wire              clk,
    input  wire              rst,
    output wire              i2s_sck,
    output wire              i2s_ws,
    input  wire              i2s_sd,
    input  wire [2:0]        gain,
    output wire              valid,
    output wire signed [15:0] sample,
    output wire              clipped            // pulse: this sample was saturated
);
    wire [23:0] w24;
    wire        v24;
    i2s_master_rx #(.BCLK_DIV(BCLK_DIV)) u_rx (
        .clk(clk), .rst_n(~rst), .i2s_sck(i2s_sck), .i2s_ws(i2s_ws), .i2s_sd(i2s_sd),
        .sample(), .sample24(w24), .sample_valid(v24));

    gain24 u_gain (.clk(clk), .v_in(v24), .w_in(w24), .gain(gain),
                   .valid(valid), .sample(sample), .clipped(clipped));
endmodule
