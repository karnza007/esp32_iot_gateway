// peak_readout.v — finds the loudest bar and turns it into text: "1002 Hz", "-23 dB".
//
// It watches the heights spectrum.v writes (one per bin per FFT) and finds the tallest of
// each FFT, skipping bins 0-1 (DC, which the window spreads into bin 1). Every 2^WIN_BITS
// clocks (0.23 s at 74.25 MHz: about 4 readings a second, slow enough to read) it shows the
// LATEST FFT's peak. (Keeping the tallest of the whole 0.23 s instead made the sweeping test
// tone read up to ~550 Hz behind: the first tall bar of the window won.) Conversion:
//   frequency  Hz = bin x fs / 1024, done as (bin x K + 2^15) >> 16 with K = fs x 64,
//              so the result is rounded to the nearest Hz. Accurate to one bin (fs/1024).
//   level      dB = height / (600 / FLOOR_DB) - FLOOR_DB   (spectrum.v: 0 dB at 600 px)
//              FLOOR_DB 80: 7.5 px per dB;  100: 6 px per dB
// Below -80 dB the frequency shows "---": the loudest thing is the noise floor. (With
// FLOOR_DB 80 that is any height of 0: everything below the floor.)
// The gain (0..7 steps of 6 dB) is shown as well. Output: 11 ASCII characters for
// text_overlay.v, character k at dyn[7k+6:7k]:
//   0-4  frequency, right-aligned     5-8  level, e.g. " -23"     9-10  gain, e.g. "24"
module peak_readout #(
    parameter integer MIC_BCLK_DIV = 26,   // must match mic_source.v
    parameter integer WIN_BITS     = 24,
    parameter integer FLOOR_DB     = 80    // must match spectrum.v: 80 or 100
)(
    input  wire        clk,
    input  wire        rst,
    input  wire        bar_we,
    input  wire [8:0]  bar_addr,
    input  wire [9:0]  bar_h,
    input  wire        bar_done,           // pulse: the FFT's 512 heights are all written
    input  wire [2:0]  gain,
    output reg  [76:0] dyn = {11{7'h20}}
);
    // K = fs x 64 (fs / 1024 x 2^16). Both sources (mic and test tone) run at the mic's rate.
    localparam [23:0] k = 74250000 / MIC_BCLK_DIV;             // fs = 74.25 MHz / (64 x div)

    // ---- 1. the tallest bar of each FFT; the latest one is shown every window ----
    reg [WIN_BITS-1:0] win = 0;
    reg [8:0] cur_bin = 0, blk_bin = 0, best_bin = 0;
    reg [9:0] cur_h = 0, blk_h = 0, best_h = 0;
    reg       go = 1'b0;
    always @(posedge clk) begin
        go <= 1'b0;
        if (rst) begin
            win <= 0; cur_h <= 0; cur_bin <= 0; blk_h <= 0; blk_bin <= 0;
        end else begin
            win <= win + 1'b1;
            if (bar_done) begin                      // this FFT is complete: keep its peak
                blk_h <= cur_h;  blk_bin <= cur_bin;
                cur_h <= 0;      cur_bin <= 0;
            end else if (bar_we && bar_addr >= 9'd2 && bar_h > cur_h) begin
                cur_h <= bar_h;  cur_bin <= bar_addr;
            end
            if (&win) begin
                best_h <= blk_h;  best_bin <= blk_bin;  go <= 1'b1;
            end
        end
    end

    // ---- 2. frequency -> 5 decimal digits, one digit per clock ----
    // n / 10 = (n x 52429) >> 19, exact for n < 43,690 (the largest here is 24,123)
    reg [31:0] prod = 0;
    reg [15:0] n = 0;
    reg [3:0]  dig [0:4];
    reg [2:0]  step = 0;            // 0 idle, 1 multiply done, 2..6 digits
    wire [15:0] q10 = (n * 32'd52429) >> 19;
    always @(posedge clk) begin
        if (go) begin
            prod <= best_bin * k;
            step <= 3'd1;
        end else if (step == 3'd1) begin
            n    <= (prod + 32'd32768) >> 16;
            step <= 3'd2;
        end else if (step != 3'd0) begin
            dig[3'd6 - step] <= n - q10 * 4'd10;     // ones first: dig[4] .. dig[0]
            n    <= q10;
            step <= (step == 3'd6) ? 3'd0 : step + 1'b1;
        end
    end

    // ---- 3. level and gain digits (small numbers: done directly) ----
    // m / 10 = (m x 205) >> 11, exact for m < 1029
    // lvl = round(height / px per dB):  80: round(2h / 15) = ((2h + 7) x 4369) >> 16
    //                                  100: round(h / 6)   = ((h + 3) x 10923) >> 16
    // Two clocks (lvl, then m), so the multiply and the digits are not in one clock: in one,
    // they missed 74.25 MHz. best_h changes 4 times a second, so the delay is invisible.
    reg  [6:0]  lvl = 0, m = 0;                                 // level is -m dB
    always @(posedge clk) begin
        lvl <= (FLOOR_DB == 80) ? (((best_h * 32'd2 + 32'd7) * 32'd4369) >> 16)
                                : (((best_h + 32'd3) * 32'd10923) >> 16);
        m   <= FLOOR_DB[6:0] - lvl;
    end
    wire [3:0]  m10  = (m * 32'd205) >> 11;
    wire [3:0]  m1   = m - m10 * 4'd10;
    wire [5:0]  gdb  = gain * 3'd6;                             // 0..42 dB
    wire [3:0]  g10  = (gdb * 32'd205) >> 11;
    wire [3:0]  g1   = gdb - g10 * 4'd10;

    function [6:0] digit(input [3:0] d); digit = 7'h30 + d; endfunction
    localparam [6:0] SP = 7'h20, MINUS = 7'h2D;

    always @(posedge clk) begin
        if (step == 3'd0) begin
            // frequency: leading zeros blank; "---" when the peak is below -80 dB
            if (best_h < ((FLOOR_DB == 80) ? 10'd1 : 10'd120)) begin
                dyn[34:0] <= {MINUS, MINUS, MINUS, SP, SP};     // chars 4..0 = "  ---"
            end else begin
                dyn[6:0]   <= (dig[0] != 0) ? digit(dig[0]) : SP;
                dyn[13:7]  <= (dig[0] != 0 || dig[1] != 0) ? digit(dig[1]) : SP;
                dyn[20:14] <= (dig[0] != 0 || dig[1] != 0 || dig[2] != 0) ? digit(dig[2]) : SP;
                dyn[27:21] <= (dig[0] != 0 || dig[1] != 0 || dig[2] != 0 || dig[3] != 0) ? digit(dig[3]) : SP;
                dyn[34:28] <= digit(dig[4]);
            end
            // level: "-100", " -23", "  -5", "   0"
            if (m == 7'd100)      dyn[62:35] <= {digit(0), digit(0), digit(1), MINUS};
            else if (m >= 7'd10)  dyn[62:35] <= {digit(m1), digit(m10), MINUS, SP};
            else if (m != 7'd0)   dyn[62:35] <= {digit(m1), MINUS, SP, SP};
            else                  dyn[62:35] <= {digit(0), SP, SP, SP};
        end
        dyn[76:63] <= {digit(g1), (g10 != 0) ? digit(g10) : SP};
    end
endmodule
