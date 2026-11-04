// tb_h5_chain.v — spectrogram check through the real chain: test tone -> spectrum (Gowin FFT
// gate-level model) -> spectrogram_display. The classic spectrogram test: a sweeping tone must
// draw a straight rising line.
//
// The tone starts at bin 10 and rises 6 bins (3 rows) per 1024 samples; a second, fixed 1 kHz
// tone 40 dB quieter (bin 46, row 23) runs under it. With 50 % overlap (as on the board) there
// is an FFT every 512 samples, so the line rises 1.5 rows per column. A sample every 16 clocks instead of 3328
// keeps the run short; the bins are the same as on the board. After 40 blocks the picture
// memory is written out, one line per column (256 colour numbers, row 0 first), to
// +out=<file>; check_h5_chain.py checks the line.
//   iverilog -g2012 -s tb_h5_chain -o h5c.vvp sim/tb_h5_chain.v src/hdmi/{spectrum,tone_gen,
//            rom_sine,rom_hann,spectrogram_display,rom_spec}.v src/fft/fft_1024.vo prim_sim.v
`timescale 1ns/1ps
module tb_h5_chain;
    reg clk = 1'b0;
    always #6.734 clk = ~clk;                     // 74.25 MHz
    reg rst = 1'b1;
    GSR GSR (.GSRI(1'b1));

    wire signed [15:0] s;
    wire               s_valid;
    tone_gen #(.SAMPLE_DIV(16), .INC1_START(32'd41943040),       // bin 10
               .SWEEP_STEP(32'd24576),                           // 6 bins per 1024 samples
               .INC2(32'd192507086)) u_tone (                     // 1 kHz at 22,311 Hz
        .clk(clk), .rst(rst), .valid(s_valid), .sample(s));

    wire       bar_we, bar_done, overrun;
    wire [8:0] bar_addr;
    wire [9:0] bar_h;
    spectrum #(.GAIN_SHIFT(0), .CLAMP(32700), .FLOOR_DB(80), .OVERLAP(1)) u_spec (
        .clk(clk), .rst(rst), .s_valid(s_valid), .s_in(s),
        .bar_we(bar_we), .bar_addr(bar_addr), .bar_h(bar_h), .bar_done(bar_done),
        .overrun(overrun));
    wire [7:0] sr, sg, sb;
    spectrogram_display u_sgram (.clk(clk), .bar_we(bar_we), .bar_addr(bar_addr), .bar_h(bar_h),
                        .bar_done(bar_done), .x(12'd0), .y(12'd0), .de(1'b0), .r(sr), .g(sg), .b(sb));

    integer f, c, r, nblk = 0;
    reg [8*256-1:0] fname;
    initial begin
        if (!$value$plusargs("out=%s", fname)) begin $display("usage: +out=<file>"); $finish; end
        repeat (10) @(posedge clk);
        rst <= 1'b0;
    end
    always @(posedge clk) if (bar_done) begin
        nblk = nblk + 1;
        if (nblk == 40) begin
            repeat (8) @(posedge clk);
            f = $fopen(fname, "w");
            for (c = 0; c < 40; c = c + 1) begin
                for (r = 0; r < 256; r = r + 1) $fwrite(f, "%0d ", u_sgram.mem[{c[7:0], r[7:0]}]);
                $fwrite(f, "\n");
            end
            $fclose(f);
            $display("tb_h5_chain: 40 blocks, wcol %0d, overrun %b", u_sgram.wcol, overrun);
            $finish;
        end
    end
endmodule
