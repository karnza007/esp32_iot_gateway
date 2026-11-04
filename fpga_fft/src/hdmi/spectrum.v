// spectrum.v — samples in, 512 bar heights out (one per FFT bin, in screen pixels).
//
//   sample ─▶ gain ─▶ clamp ─▶ ring buffer ─▶ x Hann window ─▶ Gowin FFT ─▶ re² + im²
//                              (2048 raw samples)  (as the FFT reads)         ─▶ dB ─▶ bar height
//
// OVERLAP. Each FFT takes the latest 1024 samples. OVERLAP = 0: a new FFT every 1024 samples
// (blocks side by side). OVERLAP = 1: every 512 samples, so each block is half the previous
// one and half new (50 % overlap): twice as many FFTs, and a sound at the edge of one block
// (where the window fades it out) is in the middle of the next. Because a sample is used twice,
// at different window positions, the buffer keeps raw samples and the window is applied as
// the FFT reads them. (Until 2026-11-04 the window was applied when storing, into two halves
// of 1024; OVERLAP = 0 gives exactly the same blocks as that.)
//
// TIMING (74.25 MHz clock; H2: one sample every 1536 clocks = 48.3 kHz):
//   collecting 1024 samples  = 1,572,864 clocks = 21.2 ms   (H4 at 22,311 Hz: 45.9 ms;
//                                                            with OVERLAP, 512: 22.9 ms)
//   FFT on a full block      =     7,190 clocks = 0.097 ms  (0.4 % of H4's 22.9 ms)
//   heights                  = computed one bin per clock while the FFT unloads, +8 clocks
// The ring holds 2048 samples: while the FFT reads the latest 1024, new samples go into the
// other half, so no sample is ever lost and the FFT is always finished long before the next
// block.
//
// GAIN and CLAMP are parameters to tune for the real microphone (H3):
//   GAIN_SHIFT  multiply the input by 2^GAIN_SHIFT (quiet sounds need a boost)
//   CLAMP       limit the input to +-CLAMP before the FFT. The Gowin core wraps around when
//               values sit near -32768 (benchmark, report §5B); 32700 keeps clear of that.
//
// HEIGHT: 0 dB (a bin of 32767, the largest possible) at 600 px, -FLOOR_DB at 0 px; anything
// quieter than the floor is 0 px. With P = re² + im², dB = 10 log10(P) - 90.31, and
//   FLOOR_DB = 100 (H2):  6   px per dB: height = 60 log10(P) + 58.15
//   FLOOR_DB =  80 (H4):  7.5 px per dB: height = 75 log10(P) - 77.32
// log2(P) is found from the position of P's top 1 bit plus a 32-entry table for the
// fraction, in 1/32 steps (L = 32 log2 P); then height = (HX_MUL L + HX_OFF) / 512:
//   100: (289 L + 29773) / 512        80: (361 L - 39587) / 512, below 0 -> 0
// Only these two floors are provided. Kept to 20-bit unsigned arithmetic (subtract and
// compare instead of signed numbers): 32-bit signed maths here barely met 74.25 MHz.
module spectrum #(
    parameter integer GAIN_SHIFT = 0,
    parameter integer CLAMP      = 32700,
    parameter integer FLOOR_DB   = 100,    // bottom of the scale: 100 or 80 dB below full scale
    parameter integer OVERLAP    = 0       // 1: a new FFT every 512 samples (50 % overlap)
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
    // ---- 1. gain, clamp, store in the ring ----
    wire signed [31:0] gained = $signed(s_in) <<< GAIN_SHIFT;
    localparam signed [15:0] CL = CLAMP;
    wire signed [15:0] clamped = (gained >  CLAMP) ?  CL :
                                 (gained < -CLAMP) ? -CL : gained[15:0];
    localparam integer HOP = OVERLAP ? 512 : 1024;    // samples between FFTs

    reg signed [15:0] c_q = 0;
    reg               c_valid = 1'b0;
    reg [15:0] buf_mem [0:2047];                  // ring of 2048 raw samples
    reg [10:0] wptr = 0;                          // where the next sample goes
    reg [9:0]  hop_cnt = 0;                       // samples since the last block
    reg        filled = 1'b0;                     // the first 1024 samples are in
    reg        block_ready = 1'b0;
    reg [10:0] ready_base = 0;                    // ring position of the block's first sample
    always @(posedge clk) begin
        c_valid     <= s_valid;
        c_q         <= clamped;
        block_ready <= 1'b0;
        if (rst) begin
            wptr <= 0; hop_cnt <= 0; filled <= 1'b0;
        end else if (c_valid) begin
            buf_mem[wptr] <= c_q;
            wptr    <= wptr + 1'b1;
            hop_cnt <= (hop_cnt == HOP - 1) ? 10'd0 : hop_cnt + 1'b1;
            if (wptr == 11'd1023) filled <= 1'b1;
            if (hop_cnt == HOP - 1 && (filled || wptr == 11'd1023)) begin
                block_ready <= 1'b1;              // the latest 1024 samples: hand them to the FFT
                ready_base  <= wptr - 11'd1023;
            end
        end
    end

    // ---- 2. window + FFT (driven exactly as in fft_link.v: sample idx while ipd, idx+1 ahead).
    // The sample and its window value are read together, one clock ahead; their product goes
    // straight into the FFT (x window / 32768, as the old store-time window did).
    reg         fft_start = 1'b0, running = 1'b0;
    reg  [10:0] rbase = 0;
    wire [9:0]  idx;
    wire [15:0] xk_re, xk_im;
    wire        sod, ipd, eod, busy, soud, opd, eoud;
    wire [9:0]  ridx = ipd ? idx + 10'd1 : 10'd0;
    reg  signed [15:0] rd_q = 0;
    wire [15:0] hann;
    always @(posedge clk) rd_q <= buf_mem[rbase + {1'b0, ridx}];
    rom_hann u_hann (.clk(clk), .addr(ridx), .q(hann));
    wire signed [31:0] prod = rd_q * $signed({1'b0, hann});

    fft_1024 u_fft (
        .clk(clk), .rst(rst), .start(fft_start),
        .xn_re(prod[30:15]), .xn_im(16'd0),
        .idx(idx), .xk_re(xk_re), .xk_im(xk_im),
        .sod(sod), .ipd(ipd), .eod(eod), .busy(busy),
        .soud(soud), .opd(opd), .eoud(eoud));

    always @(posedge clk) begin
        fft_start <= 1'b0;
        if (rst) running <= 1'b0;
        else if (block_ready) begin
            if (running) overrun <= 1'b1;
            else begin
                rbase     <= ready_base;
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
    // stage 4a: top bit e + the 5 bits below it   stage 4b: L = 32 log2(P)
    // stage 5: HX_MUL x L   stage 6: height
    // (4a/4b were one stage until 2026-11-04: find top bit -> shift -> table -> add was 19 cells
    //  in a row, 13.2 ns of a 13.5 ns clock. Split, each half is about half a clock.)
    reg               v4a = 0; reg [8:0] a4a = 0; reg [4:0] e4 = 0, m4 = 0; reg zero4a = 0;
    reg               v4 = 0;  reg [8:0] a4 = 0;  reg [9:0] L = 0;  reg zero4 = 0;
    reg               v5 = 0;  reg [8:0] a5 = 0;  reg [19:0] hm = 0;  reg zero5 = 0;
    reg               last3 = 0, last4a = 0, last4 = 0, last5 = 0, last6 = 0;

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
    localparam [9:0]  HX_MUL = (FLOOR_DB == 80) ? 10'd361 : 10'd289;
    localparam [19:0] HX_ADD = (FLOOR_DB == 80) ? 20'd0 : 20'd29773;
    localparam [19:0] HX_SUB = (FLOOR_DB == 80) ? 20'd39587 : 20'd0;
    wire        below = hm < HX_SUB;                  // quieter than the floor
    wire [19:0] hx    = hm - HX_SUB;

    always @(posedge clk) begin
        v1 <= opd && (idx < 10'd512);  a1 <= idx[8:0];  re1 <= xk_re;  im1 <= xk_im;
        v2 <= v1;  a2 <= a1;  sq_re <= re1 * re1;  sq_im <= im1 * im1;
        v3 <= v2;  a3 <= a2;  pw <= sq_re + sq_im;
        v4a <= v3; a4a <= a3; zero4a <= (pw == 0); e4 <= e;  m4 <= nm[30:26];
        v4 <= v4a; a4 <= a4a; zero4 <= zero4a;     L <= {e4, 5'd0} + log2_frac(m4);
        v5 <= v4;  a5 <= a4;  zero5 <= zero4;  hm <= HX_MUL * L + HX_ADD;   // < 2^19 for any L
        bar_we   <= v5;
        bar_addr <= a5;
        bar_h    <= (zero5 || below) ? 10'd0 : (hx[19:9] > 11'd600) ? 10'd600 : hx[18:9];
        last3 <= v2 && (a2 == 9'd511);  last4a <= last3;  last4 <= last4a;  last5 <= last4;  last6 <= last5;
        bar_done <= last6;
    end
endmodule
