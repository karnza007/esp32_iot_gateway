// mic_source.v — INMP441 microphone in, 16-bit samples out, with a selectable gain.
//
//   INMP441 ─I2S─▶ i2s_master_rx (fpga/src, shared with the audio project) ─▶ 24-bit word
//                    ─▶ gain: pick 16 of the 24 bits ─▶ saturate ─▶ 16-bit sample
//
// CLOCKS: bit clock = 74.25 MHz / 24 = 3.09 MHz (the INMP441 allows up to 3.2 MHz);
// 64 bit clocks per frame -> 48,339.8 samples/s, the same rate as tone_gen.
//
// GAIN = how far down the 24-bit word the 16-bit window sits; each step is x2 (+6 dB):
//   gain 0: bits 23..8 (x1, what the audio project uses)      gain 4: bits 19..4 (x16, +24 dB)
//   gain 7: bits 16..1 (x128, +42 dB)
// Choosing lower bits uses the microphone's real fine detail, rather than just multiplying
// a coarse 16-bit value. A loud sound that no longer fits in 16 bits is saturated (held at
// the limit); spectrum.v then clamps to +-CLAMP before the FFT.
module mic_source #(
    parameter integer BCLK_DIV = 24
)(
    input  wire              clk,
    input  wire              rst,
    output wire              i2s_sck,
    output wire              i2s_ws,
    input  wire              i2s_sd,
    input  wire [2:0]        gain,
    output reg               valid = 1'b0,
    output reg signed [15:0] sample = 16'sd0,
    output reg               clipped = 1'b0     // pulse: this sample was saturated
);
    wire [23:0] w24;
    wire        v24;
    i2s_master_rx #(.BCLK_DIV(BCLK_DIV)) u_rx (
        .clk(clk), .rst_n(~rst), .i2s_sck(i2s_sck), .i2s_ws(i2s_ws), .i2s_sd(i2s_sd),
        .sample(), .sample24(w24), .sample_valid(v24));

    wire signed [23:0] s       = w24;
    wire signed [23:0] shifted = s >>> (4'd8 - {1'b0, gain});
    always @(posedge clk) begin
        valid   <= v24;
        clipped <= 1'b0;
        if (v24) begin
            if (shifted > 24'sd32767)       begin sample <= 16'sd32767;  clipped <= 1'b1; end
            else if (shifted < -24'sd32768) begin sample <= -16'sd32768; clipped <= 1'b1; end
            else                                  sample <= shifted[15:0];
        end
    end
endmodule
