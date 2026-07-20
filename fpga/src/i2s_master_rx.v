// i2s_master_rx.v — INMP441 I2S master receiver (standard Philips I2S)
//
// 24 MHz clock domain. Generates a standard 64-BCLK frame:
//   - BCLK (SCK) = 24 MHz / 25 = 960 kHz   (the "25" is the frequency divider,
//     NOT the BCLK count; the frame is the textbook 64 BCLK = 32 per channel)
//   - WS = 15.000 kHz, low = left channel (INMP441 L/R pin tied to GND)
//
// Reads the FULL 24-bit left-channel word (1 dummy + 24 data bits = first 25 BCLK
// of the 32-BCLK left slot), then truncates to the most-significant 16 bits.
module i2s_master_rx #(
    parameter integer CAP_START = 2  // bit_cnt of the MSB capture (I2S phase)
)(
    input  wire        clk,          // 24 MHz
    input  wire        rst_n,        // active-low reset
    // I2S to/from INMP441
    output wire        i2s_sck,      // bit clock -> mic
    output wire        i2s_ws,       // word select -> mic (0 = left)
    input  wire        i2s_sd,       // serial data <- mic
    // parallel sample out
    output reg  [15:0] sample,       // top 16 of the 24-bit left word (signed)
    output reg         sample_valid  // 1-cycle strobe at 15 kHz
);
    // ---- BCLK generation: divide 24 MHz by 25 -> 960 kHz ----
    reg  [4:0] div_cnt = 5'd0;                 // 0..24
    wire       period_end = (div_cnt == 5'd24);
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) div_cnt <= 5'd0;
        else        div_cnt <= period_end ? 5'd0 : (div_cnt + 1'b1);
    end
    assign i2s_sck = (div_cnt < 5'd13);        // high 13 / low 12  (~52% duty)

    // ---- bit counter: 64 BCLK per WS frame ----
    reg [5:0] bit_cnt = 6'd0;                  // 0..63
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n)            bit_cnt <= 6'd0;
        else if (period_end)   bit_cnt <= (bit_cnt == 6'd63) ? 6'd0 : (bit_cnt + 1'b1);
    end
    assign i2s_ws = (bit_cnt >= 6'd32);        // low for first 32 BCLK = left

    // ---- 2-FF synchronizer on SD (mic data is source-synchronous to our SCK) ----
    reg sd_meta = 1'b0, sd_sync = 1'b0;
    always @(posedge clk) begin
        sd_meta <= i2s_sd;
        sd_sync <= sd_meta;
    end

    // ---- capture full 24-bit word, MSB-first, then truncate ----
    // Sample SD mid-high-phase of SCK (div_cnt==6). With standard Philips I2S the MSB
    // lands at bit_cnt == CAP_START (=2, validated full-scale in simulation against a
    // standard-I2S mic model). The 24 data bits occupy bit_cnt = CAP_START .. CAP_START+23.
    // NOTE: if the live waveform looks halved or bit-shifted, nudge CAP_START by +/-1 —
    //       the usual I2S alignment tweak (CAP_START=1 gives exactly half scale).
    wire       sample_pt = (div_cnt == 5'd6);
    reg [23:0] word24    = 24'd0;
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            word24       <= 24'd0;
            sample       <= 16'd0;
            sample_valid <= 1'b0;
        end else begin
            sample_valid <= 1'b0;
            if (sample_pt && (bit_cnt >= CAP_START) && (bit_cnt <= CAP_START + 23))
                word24 <= {word24[22:0], sd_sync};       // shift MSB-first
            // latch after the 24th data bit has been captured this BCLK period
            if (period_end && (bit_cnt == CAP_START + 23)) begin
                sample       <= word24[23:8];            // keep MSB 16, drop low 8
                sample_valid <= 1'b1;
            end
        end
    end
endmodule
