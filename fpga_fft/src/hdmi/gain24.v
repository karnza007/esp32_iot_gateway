// gain24.v — 24-bit microphone word in, 16-bit sample out, with a selectable gain.
//
// GAIN = how far down the 24-bit word the 16-bit window sits; each step is x2 (+6 dB):
//   gain 0: bits 23..8 (x1)    gain 4: bits 19..4 (x16, +24 dB)    gain 7: bits 16..1 (x128)
// Picking lower bits uses the microphone's real fine detail rather than multiplying a coarse
// 16-bit value. A sound too loud for 16 bits after the shift is saturated (held at the
// limit); spectrum.v then clamps to +-CLAMP. Shared by mic_source (direct INMP441) and
// relay_rx (INMP441 via the ESP32), so both behave identically.
module gain24 (
    input  wire              clk,
    input  wire              v_in,
    input  wire [23:0]       w_in,
    input  wire [2:0]        gain,
    output reg               valid = 1'b0,
    output reg signed [15:0] sample = 16'sd0,
    output reg               clipped = 1'b0     // pulse: this sample was saturated
);
    wire signed [23:0] s       = w_in;
    wire signed [23:0] shifted = s >>> (4'd8 - {1'b0, gain});
    always @(posedge clk) begin
        valid   <= v_in;
        clipped <= 1'b0;
        if (v_in) begin
            if (shifted > 24'sd32767)       begin sample <= 16'sd32767;  clipped <= 1'b1; end
            else if (shifted < -24'sd32768) begin sample <= -16'sd32768; clipped <= 1'b1; end
            else                                  sample <= shifted[15:0];
        end
    end
endmodule
