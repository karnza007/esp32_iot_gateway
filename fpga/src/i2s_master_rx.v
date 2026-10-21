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
    parameter integer CAP_START = 1   // bit_cnt at which the MSB lands (I2S phase)
)(
    input  wire        clk,           // 24 MHz
    input  wire        rst_n,         // active-low reset
    // I2S to/from INMP441
    output wire        i2s_sck,       // bit clock -> mic
    output wire        i2s_ws,        // word select -> mic (0 = left)
    input  wire        i2s_sd,        // serial data <- mic
    // parallel sample out
    output reg  [15:0] sample,        // top 16 of the 24-bit left word (signed)
    output reg  [23:0] sample24,      // the full 24-bit left word (HDMI demo: gain picks from it)
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

    // SCK and WS leave the chip from FLIP-FLOPS, never straight from a comparison.
    // `div_cnt < SCK_HIGH` is a small logic circuit whose inputs (the counter bits) arrive
    // a little apart; while they settle, its output can flick to the wrong value for a
    // nanosecond or two. Inside the FPGA nobody looks at that moment, but on a pin the
    // microphone sees it as an extra SCK edge, counts one bit too many, and its words
    // arrive shifted. Measured on the Tang Nano 20K, 2026-10-14: words like -64 and -128
    // instead of +-1 in a quiet room; worse at BCLK_DIV 12 than 42; changed with the pin.
    // A flip-flop changes once per clock, cleanly. Each one is loaded with the value the
    // comparison WILL have after this clock edge (from div_next / bit_next), so the pins
    // switch at exactly the same clock edges as before -- only without glitches.
    wire [DW-1:0] div_next = period_end ? {DW{1'b0}} : (div_cnt + 1'b1);
    reg           sck_q    = 1'b1;           // div_cnt = 0 after reset -> SCK high
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) sck_q <= 1'b1;
        else        sck_q <= (div_next < SCK_HIGH);
    end
    assign i2s_sck = sck_q;

    // ------------------------------------------------------------------
    // bit counter — 64 BCLK per WS frame, WS low for the first 32 = left
    // ------------------------------------------------------------------
    reg [5:0] bit_cnt = 6'd0;
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n)          bit_cnt <= 6'd0;
        else if (period_end) bit_cnt <= bit_cnt + 1'b1;   // 6 bits: wraps 63 -> 0
    end
    // WS changes on the FALLING edge of SCK, half a bit before the bit boundary, as the I2S
    // standard requires: the microphone reads WS on the RISING edge, so WS must already be
    // steady there. It used to change at the bit boundary, i.e. exactly AT a rising edge;
    // whether the mic then saw the old or the new WS came down to nanoseconds of wiring, so
    // its words started a bit early or late (Tang Nano 20K, 2026-10-14). The ESP32's I2S
    // hardware does it the standard way, which is why the same mic was clean there.
    // At the falling edge during bit k, WS takes the value for bit k+1: high for 32..63.
    wire [5:0] bit_after = bit_cnt + 1'b1;   // wraps 63 -> 0
    reg        ws_q      = 1'b0;             // a flip-flop, for the same reason as SCK
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n)                      ws_q <= 1'b0;
        else if (div_next == SCK_HIGH)   ws_q <= bit_after[5];   // SCK falls after this edge
    end
    assign i2s_ws = ws_q;

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
    // the microphone's output has settled. Standard I2S timing: WS changes on the
    // falling edge in the last bit of a slot, the mic sees it at the next rising edge
    // (start of bit 0), drives the MSB from the falling edge in bit 0, and the MSB is
    // read during bit 1 -> CAP_START = 1. (It was 2 while WS changed at the rising
    // edge; the simulations' mic model now reads WS on the rising edge like the real
    // one, so they check this.)
    // ------------------------------------------------------------------
    wire       sample_pt = (div_cnt == SAMPLE_PT);
    reg [23:0] word24    = 24'd0;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            word24       <= 24'd0;
            sample       <= 16'd0;
            sample24     <= 24'd0;
            sample_valid <= 1'b0;
        end else begin
            sample_valid <= 1'b0;
            if (sample_pt && (bit_cnt >= CAP_START) && (bit_cnt <= CAP_START + 23))
                word24 <= {word24[22:0], sd_sync};        // shift in, MSB first
            // latch once the 24th data bit of this frame has been captured
            if (period_end && (bit_cnt == CAP_START + 23)) begin
                sample       <= word24[23:8];             // keep MSB 16, drop low 8
                sample24     <= word24;
                sample_valid <= 1'b1;
            end
        end
    end
endmodule
