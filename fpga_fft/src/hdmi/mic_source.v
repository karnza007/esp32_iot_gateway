// mic_source.v — INMP441 microphone in, 16-bit samples out, with a selectable gain.
//
//   INMP441 ─I2S─▶ i2s_master_rx (fpga/src, shared with the audio project) ─▶ 24-bit word
//                    ─▶ gain: pick 16 of the 24 bits ─▶ saturate ─▶ 16-bit sample
//
// CLOCKS: bit clock = 74.25 MHz / 26 = 2.856 MHz (the INMP441 allows 0.5-3.2 MHz);
// 64 bit clocks per frame -> 44,621.4 samples/s (the closest to 44.1 kHz: /27 gives 42,969),
// so the screen spans 0-22.3 kHz (43.6 Hz per bar).
// History on this board (pins 25/26/29): /77 = 15,067 Hz clean (2026-10-21), /39 = 29,748 Hz
// clean (2026-10-22). /24 = 3.09 MHz was never seen working, but that was before the wiring fix.
// The value actually used is set in video_h3.v (MIC_BCLK_DIV), which also feeds the peak
// readout and gen_h4_text.py (kHz axis).
//
// GAIN: see gain24.v.
module mic_source #(
    parameter integer BCLK_DIV = 26
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
