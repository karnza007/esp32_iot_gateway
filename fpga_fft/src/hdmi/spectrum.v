// spectrum.v — samples in, 512 bar heights out (one per FFT bin, in screen pixels).
//
//   sample ─▶ gain ─▶ clamp ─▶ x Hann window ─▶ ping-pong buffer ─▶ Gowin FFT ─▶ re² + im²
//                                              (2 x 1024 samples)              ─▶ dB ─▶ bar height
//
// TIMING (74.25 MHz clock, one sample every 1536 clocks = 48.3 kHz):
//   collecting 1024 samples  = 1,572,864 clocks = 21.2 ms
//   FFT on a full block      =     7,190 clocks = 0.097 ms  (0.5 % of the time available)
//   heights                  = computed one bin per clock while the FFT unloads, +6 clocks
// The buffer has two halves: while the FFT reads the full half, new samples fill the other,
// so no sample is ever lost and the FFT is always finished long before the next block.
//
// GAIN and CLAMP are parameters to tune for the real microphone (H3):
//   GAIN_SHIFT  multiply the input by 2^GAIN_SHIFT (quiet sounds need a boost)
//   CLAMP       limit the input to +-CLAMP before the FFT. The Gowin core wraps around when
//               values sit near -32768 (benchmark, report §5B); 32700 keeps clear of that.
//
// HEIGHT: 6 px per dB, 0 dB (a bin of 32767, the largest possible) at 600 px,
// -100 dB at 0 px. With P = re² + im²:  height = 60 log10(P) + 58.15 = 18.06 log2(P) + 58.15.
// log2(P) is found from the position of P's top 1 bit plus a 32-entry table for the
// fraction, in 1/32 steps (L = 32 log2 P); then height = (289 L + 29773) / 512.
module spectrum #(
    parameter integer GAIN_SHIFT = 0,
    parameter integer CLAMP      = 32700
)(
    input  wire              clk,
    input  wire              rst,
    input  wire              s_valid,
    input  wire signed [15:0] s_in,
    output reg               bar_we = 1'b0,        // one height per clock while the FFT unloads
    output reg  [8:0]        bar_addr = 0,         // bin 0..511
    output reg  [9:0]        bar_h = 0,            // 0..600 px
    output reg               bar_done = 1'b0,      // pulse: all 512 heights of a block written
    output reg               overrun = 1'b0        // sticky: a block arrived while the FFT was busy
);
    // ---- 1. gain, clamp, window, store ----
    wire signed [31:0] gained = $signed(s_in) <<< GAIN_SHIFT;
    localparam signed [15:0] CL = CLAMP;
    wire signed [15:0] clamped = (gained >  CLAMP) ?  CL :
                                 (gained < -CLAMP) ? -CL : gained[15:0];
    reg  [9:0]  widx = 0;
    reg         wbank = 1'b0;
    wire [15:0] hann;
    rom_hann u_hann (.clk(clk), .addr(widx), .q(hann));   // ready long before the next sample

    reg signed [31:0] prod = 0;
    reg               p_valid = 1'b0;
    reg [15:0] buf_mem [0:2047];                  // two halves of 1024 windowed samples
    reg        block_ready = 1'b0, ready_bank = 1'b0;
    always @(posedge clk) begin
        p_valid     <= s_valid;
        prod        <= clamped * $signed({1'b0, hann});
        block_ready <= 1'b0;
        if (rst) begin
            widx <= 0; wbank <= 1'b0;
        end else if (p_valid) begin
            buf_mem[{wbank, widx}] <= prod[30:15];   // x window / 32768
            widx <= widx + 1'b1;
            if (widx == 10'd1023) begin               // a half is full: hand it to the FFT
                block_ready <= 1'b1;
                ready_bank  <= wbank;
                wbank       <= ~wbank;
            end
        end
    end

    // ---- 2. FFT (driven exactly as in fft_link.v: sample idx while ipd, idx+1 ahead) ----
    reg         fft_start = 1'b0, running = 1'b0, rbank = 1'b0;
    wire [9:0]  idx;
    wire [15:0] xk_re, xk_im;
    wire        sod, ipd, eod, busy, soud, opd, eoud;
    reg  [15:0] rd_q = 0;
    always @(posedge clk) rd_q <= buf_mem[{rbank, ipd ? idx + 10'd1 : 10'd0}];

    fft_1024 u_fft (
        .clk(clk), .rst(rst), .start(fft_start),
        .xn_re(rd_q), .xn_im(16'd0),
        .idx(idx), .xk_re(xk_re), .xk_im(xk_im),
        .sod(sod), .ipd(ipd), .eod(eod), .busy(busy),
        .soud(soud), .opd(opd), .eoud(eoud));

    always @(posedge clk) begin
        fft_start <= 1'b0;
        if (rst) running <= 1'b0;
        else if (block_ready) begin
            if (running) overrun <= 1'b1;
            else begin
                rbank     <= ready_bank;
                fft_start <= 1'b1;
                running   <= 1'b1;
            end
        end else if (eoud) running <= 1'b0;
    end

    // ---- 3. power, log2, height: a pipeline, one bin per clock ----
    // stage 1: keep bins 0..511 (513..1023 are the mirror image for a real input)
    reg               v1 = 0;  reg [8:0] a1 = 0;  reg signed [15:0] re1 = 0, im1 = 0;
    // stage 2: squares          stage 3: sum
    reg               v2 = 0;  reg [8:0] a2 = 0;  reg [31:0] sq_re = 0, sq_im = 0;
    reg               v3 = 0;  reg [8:0] a3 = 0;  reg [31:0] pw = 0;
    // stage 4: L = 32 log2(P)   stage 5: height
    reg               v4 = 0;  reg [8:0] a4 = 0;  reg [9:0] L = 0;  reg zero4 = 0;
    reg               last3 = 0, last4 = 0, last5 = 0;

    function [4:0] top_bit(input [31:0] p);       // index of the highest 1 (p > 0)
        integer k;
        begin
            top_bit = 0;
            for (k = 0; k < 32; k = k + 1) if (p[k]) top_bit = k;
        end
    endfunction
    function [4:0] log2_frac(input [4:0] m);       // round(32 log2(1 + m/32)), m = 0..31
        case (m)
            0: log2_frac = 0;  1: log2_frac = 1;  2: log2_frac = 3;  3: log2_frac = 4;
            4: log2_frac = 5;  5: log2_frac = 7;  6: log2_frac = 8;  7: log2_frac = 9;
            8: log2_frac = 10;  9: log2_frac = 11;  10: log2_frac = 13;  11: log2_frac = 14;
            12: log2_frac = 15;  13: log2_frac = 16;  14: log2_frac = 17;  15: log2_frac = 18;
            16: log2_frac = 19;  17: log2_frac = 20;  18: log2_frac = 21;  19: log2_frac = 22;
            20: log2_frac = 22;  21: log2_frac = 23;  22: log2_frac = 24;  23: log2_frac = 25;
            24: log2_frac = 26;  25: log2_frac = 27;  26: log2_frac = 27;  27: log2_frac = 28;
            28: log2_frac = 29;  29: log2_frac = 30;  30: log2_frac = 31;  31: log2_frac = 31;
            default: log2_frac = 0;
        endcase
    endfunction

    wire [4:0]  e  = top_bit(pw);
    wire [31:0] nm = pw << (5'd31 - e);            // top 1 bit moved to bit 31
    wire [19:0] hx = 20'd289 * L + 20'd29773;

    always @(posedge clk) begin
        v1 <= opd && (idx < 10'd512);  a1 <= idx[8:0];  re1 <= xk_re;  im1 <= xk_im;
        v2 <= v1;  a2 <= a1;  sq_re <= re1 * re1;  sq_im <= im1 * im1;
        v3 <= v2;  a3 <= a2;  pw <= sq_re + sq_im;
        v4 <= v3;  a4 <= a3;  zero4 <= (pw == 0);  L <= {e, 5'd0} + log2_frac(nm[30:26]);
        bar_we   <= v4;
        bar_addr <= a4;
        bar_h    <= zero4 ? 10'd0 : (hx[19:9] > 11'd600) ? 10'd600 : hx[18:9];
        last3 <= v2 && (a2 == 9'd511);  last4 <= last3;  last5 <= last4;
        bar_done <= last5;
    end
endmodule
