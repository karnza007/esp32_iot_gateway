// tb_h5_spec.v — spectrogram check: renders one whole 1280x720 frame of the spectrogram page.
//
// 300 fake FFT blocks are written into spectrogram_display exactly as spectrum.v writes them
// (512 heights, then bar_done). Block k has:
//   a diagonal line: bin 2k mod 512 at 0 dB (height 600)  -> white; a steep line below
//                    4 kHz (one bin per row), a shallow one above
//   a fixed tone:    bin 46 at -60 dB (height 150)        -> row 46
//   everything else: even bins (13b + 5k) mod 241, odd bins (7b + 3k) mod 61, so every
//                    height 0..240 shows up as the louder of a pair (sometimes the odd one),
//                    covering all 32 levels and each edge between them (0/1, every 7.5, 224/225)
// 300 > 256, so the memory has wrapped: the screen must show blocks 44..299, oldest at the left.
// After the next vertical blanking one frame is written as hex, one pixel per line, to
// +out=<file>; check_h5.py checks it.
//   iverilog -g2012 -s tb_h5_spec -o h5.vvp sim/tb_h5_spec.v src/hdmi/{video_timing,
//            spectrogram_display,rom_spec,peak_readout,text_overlay,rom_text,rom_font,rom_ticks}.v
`timescale 1ns/1ps
module tb_h5_spec;
    reg clk = 1'b0;
    always #6.734 clk = ~clk;                     // 74.25 MHz
    reg rst = 1'b1;

    wire [11:0] x, y;
    wire de, hs, vs, fs;
    video_timing u_tim (.clk(clk), .rst(rst), .x(x), .y(y), .de(de), .hs(hs), .vs(vs), .frame_start(fs));

    reg        bar_we = 1'b0, bar_done = 1'b0;
    reg [8:0]  bar_addr = 0;
    reg [9:0]  bar_h = 0;
    wire [7:0] sr, sg, sb;
    spectrogram_display u_sgram (.clk(clk), .bar_we(bar_we), .bar_addr(bar_addr), .bar_h(bar_h),
                        .bar_done(bar_done), .x(x), .y(y), .de(de), .r(sr), .g(sg), .b(sb));
    wire [76:0] dyn;
    peak_readout #(.MIC_BCLK_DIV(52), .WIN_BITS(12)) u_peak (
        .clk(clk), .rst(rst), .bar_we(bar_we), .bar_addr(bar_addr), .bar_h(bar_h),
        .bar_done(bar_done), .gain(3'd4), .dyn(dyn));
    wire [23:0] rgb;
    text_overlay u_text (.clk(clk), .x(x), .y(y), .de(de), .page(1'b1), .dyn(dyn),
                         .bar_rgb({sr, sg, sb}), .rgb(rgb));
    reg [2:0] d1 = 0, d2 = 0, d3 = 0, d4 = 0;
    always @(posedge clk) begin d1 <= {de, hs, vs}; d2 <= d1; d3 <= d2; d4 <= d3; end

    function [9:0] height(input integer k, input integer b);
        begin
            height = (b % 2) ? (7 * b + 3 * k) % 61 : (13 * b + 5 * k) % 241;
            if (b == 46) height = 150;
            if (b == (2 * k) % 512) height = 600;
        end
    endfunction

    integer f, k, b, n = 0;
    reg [8*256-1:0] fname;
    reg capture = 1'b0, written = 1'b0;
    always @(posedge clk) if (capture && d4[2]) begin $fwrite(f, "%06x\n", rgb); n = n + 1; end
    initial begin
        if (!$value$plusargs("out=%s", fname)) begin $display("usage: +out=<file>"); $finish; end
        f = $fopen(fname, "w");
        repeat (10) @(posedge clk);
        rst <= 1'b0;
        wait (written);
        // the scroll position is taken at the next blanking; then capture the following frame
        wait (y == 12'd720); wait (y == 12'd0 && x == 12'd0);
        @(posedge clk); capture <= 1'b1;
        wait (y == 12'd720);
        repeat (8) @(posedge clk);
        capture <= 1'b0;
        $display("tb_h5_spec: %0d pixels (want 921600); columns written %0d, start %0d", n,
                 300, u_sgram.start);
        $fclose(f);
        $finish;
    end

    initial begin
        wait (!rst);
        for (k = 0; k < 300; k = k + 1) begin
            for (b = 0; b < 512; b = b + 1) begin
                @(posedge clk); bar_we <= 1'b1; bar_addr <= b; bar_h <= height(k, b);
            end
            @(posedge clk); bar_we <= 1'b0; bar_done <= 1'b1;
            @(posedge clk); bar_done <= 1'b0;
            repeat (20) @(posedge clk);
        end
        written = 1'b1;
    end
endmodule
