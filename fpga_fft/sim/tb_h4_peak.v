// tb_h4_peak.v — H4 check: test tone -> spectrum (Gowin FFT gate-level model) -> peak_readout.
//
// The same chain as on the board, with a sample every 16 clocks instead of 1664 to keep the
// run short. Tones are set as phase steps per sample (fractions of the sample rate), so the
// FFT bins and the readout's text are exactly what the board shows at 44,621 Hz.
//   SWEEP = 0: tone 1 fixed at 3,000 Hz -> bin 68.85 -> the readout must say "3007" (bin 69)
//   SWEEP = 1: tone 1 glides up one bin per FFT block; at every readout the bin shown must lie
//              in the range the tone covered during the latest FFT whose bars are complete
// The readout window is 2^16 clocks (4 blocks here) instead of 2^24.
`timescale 1ns/1ps
module tb_h4_peak #(parameter integer SWEEP = 0);
    reg clk = 1'b0;
    always #6.734 clk = ~clk;                     // 74.25 MHz
    reg rst = 1'b1;
    GSR GSR (.GSRI(1'b1));

    localparam real FS = 74250000.0 / (64 * 26);                  // the board's sample rate
    localparam [31:0] STEP_3K = 3000.0 / FS * 4294967296.0;       // 3 kHz
    wire signed [15:0] s;
    wire               s_valid;
    tone_gen #(.SAMPLE_DIV(16), .INC1_START(SWEEP ? 32'd41943040 : STEP_3K),   // sweep: from bin 10
               .SWEEP_STEP(SWEEP ? 32'd4096 : 32'd0),                          // 1 bin per 1024 samples
               .INC2(32'd96253543)) u_tone (                                    // 1 kHz at 44,621 Hz
        .clk(clk), .rst(rst), .valid(s_valid), .sample(s));

    wire       bar_we, bar_done, overrun;
    wire [8:0] bar_addr;
    wire [9:0] bar_h;
    spectrum #(.GAIN_SHIFT(0), .CLAMP(32700)) u_spec (
        .clk(clk), .rst(rst), .s_valid(s_valid), .s_in(s),
        .bar_we(bar_we), .bar_addr(bar_addr), .bar_h(bar_h), .bar_done(bar_done),
        .overrun(overrun));
    wire [76:0] dyn;
    peak_readout #(.MIC_BCLK_DIV(26), .WIN_BITS(16)) u_peak (
        .clk(clk), .rst(rst), .bar_we(bar_we), .bar_addr(bar_addr), .bar_h(bar_h),
        .bar_done(bar_done), .src(2'd0), .gain(3'd0), .dyn(dyn));

    function [8*5-1:0] hz_text(input dummy);
        integer i;
        begin
            hz_text = 0;
            for (i = 0; i < 5; i = i + 1) hz_text = {hz_text[8*4-1:0], 1'b0, dyn[7 * i +: 7]};
        end
    endfunction

    // the tone's bins during the latest block whose bars are complete: a block's range is
    // noted when its samples are all in (block_ready) and becomes "shown" at its bar_done
    integer nread = 0, bad = 0, tone_bin_start = 0, pend_start = 0, pend_end = 0;
    integer blk_start_bin = 0, blk_end_bin = 0;
    always @(posedge clk) begin
        if (u_spec.block_ready) begin
            pend_start = tone_bin_start;  pend_end = u_tone.inc1 >> 22;
            tone_bin_start = u_tone.inc1 >> 22;
        end
        if (bar_done) begin blk_start_bin = pend_start; blk_end_bin = pend_end; end
    end
    always @(posedge clk) if (u_peak.go) begin
        repeat (8) @(posedge clk);                 // conversion takes 6 clocks
        nread = nread + 1;
        if (nread >= 2) begin                      // the first window may hold no complete FFT
            if (SWEEP) begin
                if (u_peak.best_bin < blk_start_bin || u_peak.best_bin > blk_end_bin) bad = bad + 1;
                $display("  readout %0d: bin %0d \"%s Hz\"  (latest block: tone bins %0d..%0d; tone now %0d)",
                         nread, u_peak.best_bin, hz_text(0), blk_start_bin, blk_end_bin, u_tone.inc1 >> 22);
            end else begin
                if (hz_text(0) != " 3007") bad = bad + 1;
                $display("  readout %0d: bin %0d \"%s Hz\"  (want bin 69, \" 3007\")", nread, u_peak.best_bin, hz_text(0));
            end
        end
        if (nread == 7) begin
            $display("tb_h4_peak: SWEEP=%0d  %0d readouts checked, %0d wrong, overrun=%b  %s",
                     SWEEP, nread - 1, bad, overrun, (bad == 0 && !overrun) ? "PASS" : "FAIL");
            $finish;
        end
    end

    initial begin
        repeat (20) @(posedge clk);
        #1 rst = 1'b0;
        #20_000_000 $display("TIMEOUT"); $finish;
    end
endmodule
