// i2s_master_rx.v — INMP441 I2S master receiver (standard Philips I2S)
//
// Runs entirely in the 24 MHz domain and generates a textbook 64-BCLK frame
// (32 bit clocks per channel). The FPGA is the MASTER: it drives both clocks,
// the microphone only ever drives data.
//
//   BCLK (SCK) = 24 MHz / BCLK_DIV
//   WS         = BCLK / 64  =  24 MHz / (64 * BCLK_DIV)   <-- the sample rate
//
// SAMPLE RATE IS AN INTEGER DIVIDE, SO EVERY VALUE IS EXACT
//   BCLK_DIV  BCLK       fs           note
//        25   960 kHz    15.000 kHz   current default
//        16   1.5 MHz    23.4375 kHz
//        12   2.0 MHz    31.250 kHz
//        10   2.4 MHz    37.500 kHz
//         8   3.0 MHz    46.875 kHz   fastest the INMP441 allows (SCK max 3.2 MHz)
//   There is nothing special about "round" rates like 15 kHz — 31.25 kHz is
//   derived from the same crystal by the same integer divide and is exactly as
//   accurate and as jitter-free. Only the FFT axis label cares.
//
// WHAT IT READS
//   L/R on the microphone is tied to GND, so the LEFT channel occupies the first
//   half of the frame (WS low). We read the FULL 24-bit left word MSB-first, then
//   keep the top 16 bits and discard the low 8. The remaining ~39 bit clocks of
//   the frame are still generated normally — the INMP441 requires a complete
//   64-clock frame; we simply ignore the part we do not need.

module i2s_master_rx #(
    parameter integer BCLK_DIV  = 25, // 24 MHz / BCLK_DIV = bit clock (>= 8)
    parameter integer CAP_START = 2   // bit_cnt at which the MSB lands (I2S phase)
)(
    input  wire        clk,           // 24 MHz
    input  wire        rst_n,         // active-low reset
    // I2S to/from INMP441
    output wire        i2s_sck,       // bit clock -> mic
    output wire        i2s_ws,        // word select -> mic (0 = left)
    input  wire        i2s_sd,        // serial data <- mic
    // parallel sample out
    output reg  [15:0] sample,        // top 16 of the 24-bit left word (signed)
    output reg         sample_valid   // 1-cycle strobe, one per WS frame
);
    // ------------------------------------------------------------------
    // BCLK generation.
    // SCK_HIGH is the ceiling of BCLK_DIV/2, so odd dividers work too: with
    // BCLK_DIV = 25 the duty is 13 high / 12 low (~52 %), which is far inside
    // the INMP441's 50 ns minimum high and low time.
    // ------------------------------------------------------------------
    localparam integer DW        = $clog2(BCLK_DIV);
    localparam integer SCK_HIGH  = (BCLK_DIV + 1) / 2;   // high while div_cnt < this
    localparam integer SAMPLE_PT = (BCLK_DIV + 1) / 4;   // middle of the high phase

    reg  [DW-1:0] div_cnt = 0;
    wire          period_end = (div_cnt == BCLK_DIV-1);

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) div_cnt <= 0;
        else        div_cnt <= period_end ? 0 : (div_cnt + 1'b1);
    end

    assign i2s_sck = (div_cnt < SCK_HIGH);

    // ------------------------------------------------------------------
    // bit counter — 64 BCLK per WS frame, WS low for the first 32 = left
    // ------------------------------------------------------------------
    reg [5:0] bit_cnt = 6'd0;
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n)          bit_cnt <= 6'd0;
        else if (period_end) bit_cnt <= bit_cnt + 1'b1;   // 6 bits: wraps 63 -> 0
    end
    assign i2s_ws = (bit_cnt >= 6'd32);

    // ------------------------------------------------------------------
    // 2-flip-flop synchroniser on SD — the only asynchronous input in the
    // whole design. Everything else is one synchronous 24 MHz domain.
    // ------------------------------------------------------------------
    reg sd_meta = 1'b0, sd_sync = 1'b0;
    always @(posedge clk) begin
        sd_meta <= i2s_sd;
        sd_sync <= sd_meta;
    end

    // ------------------------------------------------------------------
    // Capture 24 bits MSB-first, then truncate to 16.
    //
    // SD is sampled at SAMPLE_PT — the middle of the SCK high phase, well after
    // the microphone's output has settled. I2S nominally puts the MSB one BCLK
    // after the WS edge, but the effective alignment also depends on where in
    // the period we sample; a simulation sweep against known patterns (A5A5,
    // 8000, 7FFF, 1234) showed CAP_START = 2 reproduces full scale exactly.
    //
    // If a known tone ever reads at half amplitude on hardware, nudge CAP_START
    // by +/-1 — that is the usual off-by-one I2S alignment tweak, and it is
    // independent of BCLK_DIV.
    // ------------------------------------------------------------------
    wire       sample_pt = (div_cnt == SAMPLE_PT);
    reg [23:0] word24    = 24'd0;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            word24       <= 24'd0;
            sample       <= 16'd0;
            sample_valid <= 1'b0;
        end else begin
            sample_valid <= 1'b0;
            if (sample_pt && (bit_cnt >= CAP_START) && (bit_cnt <= CAP_START + 23))
                word24 <= {word24[22:0], sd_sync};        // shift in, MSB first
            // latch once the 24th data bit of this frame has been captured
            if (period_end && (bit_cnt == CAP_START + 23)) begin
                sample       <= word24[23:8];             // keep MSB 16, drop low 8
                sample_valid <= 1'b1;
            end
        end
    end
endmodule
