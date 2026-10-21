// top_mic_uart.v — microphone check on the Tang Nano 20K, no PLL, no HDMI.
//
//   INMP441 ─I2S─▶ i2s_master_rx ─┐
//                                 ├─(S1 picks)─▶ framer ─▶ uart_tx ─pin 28─▶ ESP32 GPIO18
//   1 kHz test tone (tone_gen) ───┘                 (fpga_uart_bridge) ─USB─▶ inmp441_viewer.py
//
// Everything runs on the 27 MHz crystal directly, so there is no PLL to go wrong:
//   mic bit clock  27 MHz / 28        = 964.3 kHz   (INMP441 allows 0.5-3.2 MHz)
//   sample rate    27 MHz / 28 / 64   = 15,067.0 Hz
// 964 kHz / 15,067 Hz is exactly what the Tang Nano 4K uses (54 MHz / 56), where this mic was
// clean on 2026-10-21; matching it leaves the board as the only difference. (BCLK_DIV 42 =
// 10,044.6 Hz on pins 73-76 gave scrambled words, 2026-10-14..18.)
//   UART           27 MHz / 27        = 1 Mbaud     (2 Mbaud would need 13.5 clocks per bit)
// (BCLK_DIV 12 = 2.25 MHz was tried while chasing the shifted-word problem; the cause was WS
// changing at the SCK rising edge, fixed in i2s_master_rx.v.)
// The frames are the audio project's v3 format (framer.v), so the ESP32 forwards them
// unchanged and the viewer reads the sample rate from the header's cfg word.
//
// S1 switches the source: the test tone proves the FPGA -> ESP32 -> PC link on its own, the
// microphone is the thing under test. The design starts on the tone.
//
// S2 switches RAW-BITS mode on/off: a built-in logic analyser for the SD wire. Instead of
// samples, the FPGA sends all 64 SD bits of every WS frame (both halves), sampled exactly
// where i2s_master_rx samples them, as four 16-bit words, first bit in the MSB:
//   word 0 = bits 0-15 (WS low, left)   word 1 = bits 16-31   word 2 = bits 32-47 (WS high,
//   right)   word 3 = bits 48-63.  Bit k is what i2s_master_rx sees at bit_cnt k, so the left
//   mic word is bits 1-24 and a right-channel word would be bits 33-56.
// The header's channel field reads 2 in this mode, and every UART frame (512 words) holds
// exactly 128 whole WS frames: the change of mode waits for the end of a WS frame and restarts
// the framer there. 4 words x fs: 80 kB/s of the 100 kB/s link at
// BCLK_DIV 42; raw-bits mode needs BCLK_DIV >= 42 (at 12 it would need 281 kB/s; at the
// current 28, 120 kB/s: frames are lost, so build with BCLK_DIV 42 to use it). host/sd_raw.py
// reads it.
//
// LEDs (lit = on), only when LED_EN = 1 (default 0: all off). The mic is checked all the time, whichever source is being sent; each
// check covers the last 0.31 s (2^23 clocks):
//   LED0  mic selected (off = test tone)
//   LED1  mic data alive: words that are neither all-0 nor all-1 are arriving
//   LED2  SD stuck low: every word was 000000
//   LED3  SD stuck high: every word was FFFFFF
//   LED4  toggles once per frame sent (about 20 per second, so it looks dim)
//   LED5  heartbeat, about 1.6 blinks per second: the design is running
module top_mic_uart #(
    parameter integer BCLK_DIV      = 28,     // fs = 27 MHz / (64 * BCLK_DIV)
    parameter integer CLK_PER_BIT   = 27,     // 1 Mbaud; must match FPGA_BAUD in the bridge
    parameter integer FRAME_SAMPLES = 512,
    parameter integer START_SRC     = 0,      // 0 = test tone, 1 = microphone
    parameter integer WIN_BITS      = 23,     // LED check window, 2^WIN_BITS clocks
    parameter integer LED_EN        = 0,      // 0 = all LEDs off, 1 = the indicators below
    parameter integer START_RAW     = 0       // 1 = start in raw-bits mode (simulation)
)(
    input  wire       clk,        // 27 MHz crystal, pin 4
    output wire       i2s_sck,    // -> INMP441 SCK, pin 76
    output wire       i2s_ws,     // -> INMP441 WS,  pin 74
    input  wire       i2s_sd,     // <- INMP441 SD,  pin 75
    output wire       uart_tx,    // -> ESP32-S3 GPIO18, pin 28
    input  wire [1:0] btn,        // S1 pin 88 (source), S2 pin 87 (raw-bits mode)
    output wire [5:0] led         // pins 15..20, lit when low
);
    // ---- power-on reset: hold everything for 255 clocks after configuration ----
    reg [7:0] por = 8'd0;
    always @(posedge clk) if (!(&por)) por <= por + 1'b1;
    wire rst_n = &por;

    // ---- the frame header's cfg word (fpga/src/top.v explains the fields) ----
    //   [7:0] BCLK_DIV, [9:8] 1 channel (2 = raw-bits mode), [15:10] clock code. The code is
    //   MHz/6, and 27 is not a multiple of 6, so code 63 means "27 MHz" (inmp441_viewer.py).
    localparam [5:0]  CLK_CODE_27 = 6'd63;
    reg               raw = (START_RAW != 0);
    wire       [15:0] cfg = {CLK_CODE_27, raw ? 2'd2 : 2'd1, BCLK_DIV[7:0]};

    // ---- microphone ----
    wire [15:0] mic_sample;
    wire [23:0] mic_word;
    wire        mic_valid;
    i2s_master_rx #(.BCLK_DIV(BCLK_DIV), .CAP_START(1)) u_i2s (
        .clk(clk), .rst_n(rst_n),
        .i2s_sck(i2s_sck), .i2s_ws(i2s_ws), .i2s_sd(i2s_sd),
        .sample(mic_sample), .sample24(mic_word), .sample_valid(mic_valid)
    );

    // ---- test tone: 1 kHz, amplitude 4096, at the microphone's sample rate ----
    //   tone_gen's tone 1 is switched off (step 0 stays at sine(0) = 0); tone 2 is the
    //   1 kHz tone: step = 1000 Hz / fs x 2^32, fs = 27 MHz / (64 x BCLK_DIV).
    localparam [63:0] TONE_STEP = ((64'd1000 * 64 * BCLK_DIV) << 32) / 64'd27000000;
    wire        tone_valid;
    wire signed [15:0] tone_sample;
    tone_gen #(
        .SAMPLE_DIV (64 * BCLK_DIV),
        .INC1_START (32'd0),
        .SWEEP_STEP (32'd0),
        .INC2       (TONE_STEP[31:0]),
        .AMP2       (16'd4096)
    ) u_tone (
        .clk(clk), .rst(~rst_n), .valid(tone_valid), .sample(tone_sample)
    );

    // ---- source select (S1) ----
    wire [1:0] pressed;
    buttons u_btn (.clk(clk), .btn(btn), .pressed(pressed));
    reg src_mic = (START_SRC != 0);
    always @(posedge clk) if (pressed[0]) src_mic <= ~src_mic;

    // ---- raw-bits mode (S2): the SD wire, bit by bit ----
    //   The same counters, synchroniser and sample point as i2s_master_rx, started by the same
    //   reset, so they run in lockstep with it: bit index k here = its bit_cnt k.
    localparam integer SAMPLE_PT = (BCLK_DIV + 1) / 4;
    reg [5:0]  r_div = 6'd0, r_bit = 6'd0;
    wire       r_end = (r_div == BCLK_DIV - 1);
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin r_div <= 6'd0; r_bit <= 6'd0; end
        else begin
            r_div <= r_end ? 6'd0 : r_div + 1'b1;
            if (r_end) r_bit <= r_bit + 1'b1;
        end
    end
    reg sd_m = 1'b0, sd_s = 1'b0;
    always @(posedge clk) begin sd_m <= i2s_sd; sd_s <= sd_m; end
    reg [15:0] r_sh = 16'd0, raw_word = 16'd0;
    reg        raw_valid = 1'b0;
    always @(posedge clk) begin
        raw_valid <= 1'b0;
        if (r_div == SAMPLE_PT) r_sh <= {r_sh[14:0], sd_s};
        if (r_end && r_bit[3:0] == 4'd15) begin            // 16 bits done: one word
            raw_word  <= r_sh;                             // bit 15 went in at SAMPLE_PT
            raw_valid <= 1'b1;
        end
    end
    // S2 toggles the mode at the end of a WS frame and restarts the framer there
    reg raw_req = 1'b0, fr_rst = 1'b0;
    always @(posedge clk) begin
        fr_rst <= 1'b0;
        if (pressed[1]) raw_req <= 1'b1;
        if (raw_req && r_end && r_bit == 6'd63) begin
            raw <= ~raw;  raw_req <= 1'b0;  fr_rst <= 1'b1;
        end
    end

    wire [15:0] sample       = raw ? raw_word  : src_mic ? mic_sample : tone_sample;
    wire        sample_valid = raw ? raw_valid : src_mic ? mic_valid  : tone_valid;

    // ---- framing + UART (the audio project's modules, unchanged) ----
    wire [7:0]  tx_data;
    wire        tx_valid, tx_ready;
    wire [15:0] seq;
    framer #(.FIFO_DEPTH(64), .FRAME_SAMPLES(FRAME_SAMPLES)) u_framer (
        .clk(clk), .rst_n(rst_n & ~fr_rst),
        .sample(sample), .sample_valid(sample_valid), .cfg(cfg),
        .tx_data(tx_data), .tx_valid(tx_valid), .tx_ready(tx_ready),
        .ovf_count(), .seq_count(seq)
    );
    uart_tx #(.CLK_PER_BIT(CLK_PER_BIT)) u_uart (
        .clk(clk), .rst_n(rst_n),
        .tx_data(tx_data), .tx_valid(tx_valid), .tx_ready(tx_ready),
        .tx(uart_tx)
    );

    // ---- microphone health, per window ----
    reg [WIN_BITS-1:0] win = 0;
    reg any_live = 1'b0, all_zero = 1'b1, all_ones = 1'b1, any_word = 1'b0;
    reg show_live = 1'b0, show_low = 1'b0, show_high = 1'b0;
    always @(posedge clk) begin
        win <= win + 1'b1;
        if (&win) begin                     // end of window: show it, start the next
            show_live <= any_live;
            show_low  <= any_word & all_zero;
            show_high <= any_word & all_ones;
            any_live <= 1'b0;  all_zero <= 1'b1;  all_ones <= 1'b1;  any_word <= 1'b0;
        end else if (mic_valid) begin
            any_word <= 1'b1;
            if (mic_word != 24'h000000) all_zero <= 1'b0;
            if (mic_word != 24'hFFFFFF) all_ones <= 1'b0;
            if (mic_word != 24'h000000 && mic_word != 24'hFFFFFF) any_live <= 1'b1;
        end
    end

    reg [23:0] hb = 0;
    always @(posedge clk) hb <= hb + 1'b1;

    assign led = LED_EN ? ~{hb[23], seq[0], show_high, show_low, show_live, src_mic} : 6'b111111;
endmodule
