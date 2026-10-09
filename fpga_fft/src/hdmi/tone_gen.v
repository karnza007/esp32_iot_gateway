// tone_gen.v — test signal for H2: a sweeping tone plus a fixed quiet 1 kHz tone.
//
// It produces samples at the same rate the microphone will (one every SAMPLE_DIV clocks:
// 74.25 MHz / 1536 = 48,339.8 Hz), so in H3 the microphone simply replaces this block.
//
// Each tone is a "phase accumulator": a 32-bit counter that adds a fixed step per sample
// and wraps around; its top 10 bits index one sine period in rom_sine. A bigger step
// means a higher frequency:  f = step / 2^32 x 48,339.8 Hz.
//   tone 1: amplitude 16383 (half scale); its step grows by SWEEP_STEP every sample, so
//           it glides from 0 Hz to just under 24 kHz in about 10 s, then starts again
//   tone 2: 1 kHz (step 88,849,424), amplitude AMP2 = 164 = 1/100 of tone 1 (-40 dB)
module tone_gen #(
    parameter integer SAMPLE_DIV = 1536,
    parameter [31:0]  INC1_START = 32'd0,          // tone 1's starting step
    parameter [31:0]  SWEEP_STEP = 32'd4411,       // 0 = tone 1 stays fixed
    parameter [31:0]  INC1_MAX   = 32'd2132386187, // 24 kHz: back to the start beyond this
    parameter [31:0]  INC2       = 32'd88849424,   // 1 kHz
    parameter [15:0]  AMP2       = 16'd164         // tone 2 amplitude (tone 1 is 16383)
)(
    input  wire              clk,
    input  wire              rst,
    output reg               valid = 1'b0,         // one-clock pulse per new sample
    output reg signed [15:0] sample = 16'sd0
);
    reg [15:0] div = 0;
    reg [31:0] ph1 = 0, ph2 = 0, inc1 = INC1_START;
    reg [2:0]  st = 0;
    reg [9:0]  addr = 0;
    wire signed [15:0] sine;
    rom_sine u_rom (.clk(clk), .addr(addr), .q(sine));

    reg signed [15:0] s1 = 0;
    reg signed [31:0] p2 = 0;
    always @(posedge clk) begin
        valid <= 1'b0;
        if (rst) begin
            div <= 0; ph1 <= 0; ph2 <= 0; inc1 <= INC1_START; st <= 0;
        end else begin
            div <= (div == SAMPLE_DIV - 1) ? 16'd0 : div + 1'b1;
            case (st)                                  // one shared ROM, read twice per sample
                3'd0: if (div == 0) begin addr <= ph1[31:22]; st <= 3'd1; end
                3'd1: st <= 3'd2;                      // ROM answers one clock later
                3'd2: begin s1 <= sine >>> 1; addr <= ph2[31:22]; st <= 3'd3; end
                3'd3: st <= 3'd4;
                3'd4: begin p2 <= sine * $signed({1'b0, AMP2}); st <= 3'd5; end
                3'd5: begin
                    sample <= s1 + p2[30:15];          // tone 1 + tone 2
                    valid  <= 1'b1;
                    ph1  <= ph1 + inc1;                // step both tones to the next sample
                    ph2  <= ph2 + INC2;
                    inc1 <= (inc1 + SWEEP_STEP > INC1_MAX) ? INC1_START : inc1 + SWEEP_STEP;
                    st   <= 3'd0;
                end
                default: st <= 3'd0;
            endcase
        end
    end
endmodule
