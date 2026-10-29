// tb_h4_frame.v — H4 check: renders one whole 1280x720 frame with the text overlay.
//
// A fake spectrum (noise floor around -75 dB, a peak at bin 46 = 1002 Hz at -23 dB at the
// mic's 22,311 Hz, a smaller one at bin 92) is written into bar_display and peak_readout
// exactly as spectrum.v writes it.
// After the readout has updated and the bars have swapped in, one frame of the final colour
// (what hdmi_out receives) is written as hex, one pixel per line, to +out=<file>;
// check_h4.py turns it into a PNG and checks the readout text.
//   iverilog -g2012 -s tb_h4_frame -o h4.vvp sim/tb_h4_frame.v src/hdmi/{video_timing,
//            bar_display,peak_readout,text_overlay,rom_text,rom_font,rom_ticks}.v
`timescale 1ns/1ps
module tb_h4_frame;
    reg clk = 1'b0;
    always #6.734 clk = ~clk;                     // 74.25 MHz
    reg rst = 1'b1;

    wire [11:0] x, y;
    wire de, hs, vs, fs;
    video_timing u_tim (.clk(clk), .rst(rst), .x(x), .y(y), .de(de), .hs(hs), .vs(vs), .frame_start(fs));

    reg        bar_we = 1'b0, bar_done = 1'b0;
    reg [8:0]  bar_addr = 0;
    reg [9:0]  bar_h = 0;
    wire [7:0] br, bg, bb;
    bar_display u_bars (.clk(clk), .bar_we(bar_we), .bar_addr(bar_addr), .bar_h(bar_h),
                        .bar_done(bar_done), .x(x), .y(y), .de(de), .r(br), .g(bg), .b(bb));
    wire [76:0] dyn;
    peak_readout #(.MIC_BCLK_DIV(52), .WIN_BITS(12)) u_peak (
        .clk(clk), .rst(rst), .bar_we(bar_we), .bar_addr(bar_addr), .bar_h(bar_h),
        .bar_done(bar_done), .gain(3'd4), .dyn(dyn));
    wire [23:0] rgb;
    text_overlay u_text (.clk(clk), .x(x), .y(y), .de(de), .src(2'd1), .dyn(dyn),
                         .bar_rgb({br, bg, bb}), .rgb(rgb));
    reg [2:0] d1 = 0, d2 = 0, d3 = 0, d4 = 0;
    always @(posedge clk) begin d1 <= {de, hs, vs}; d2 <= d1; d3 <= d2; d4 <= d3; end

    // the fake spectrum
    function [9:0] height(input integer b);
        begin
            height = 150 + ((b * 37) % 23);                     // floor around -75 dB
            if (b == 0 || b == 1) height = 560;                 // DC: must be ignored
            if (b >= 44 && b <= 48) height = 462 - 60 * (b > 46 ? b - 46 : 46 - b);
            if (b >= 91 && b <= 93) height = 380 - 50 * (b > 92 ? b - 92 : 92 - b);
        end
    endfunction

    integer f, k, n = 0;
    reg [8*256-1:0] fname;
    reg capture = 1'b0;
    always @(posedge clk) if (capture && d4[2]) begin $fwrite(f, "%06x\n", rgb); n = n + 1; end
    initial begin
        if (!$value$plusargs("out=%s", fname)) begin $display("usage: +out=<file>"); $finish; end
        f = $fopen(fname, "w");
        repeat (10) @(posedge clk);
        rst <= 1'b0;
        // the bars swap in at the next blanking; then capture the whole following frame
        wait (y == 12'd720); wait (y == 12'd0 && x == 12'd0);
        @(posedge clk); capture <= 1'b1;
        wait (y == 12'd720);
        repeat (8) @(posedge clk);
        capture <= 1'b0;
        $display("tb_h4_frame: %0d pixels (want 921600); live text \"%s|%s|%s\"", n,
                 chars(0, 5), chars(5, 4), chars(9, 2));
        $fclose(f);
        $finish;
    end

    // a new spectrum every 2,000 clocks, as spectrum.v sends one per FFT block (the readout
    // window here is 4,096 clocks, so every window sees at least one)
    initial begin
        wait (!rst);
        forever begin
            for (k = 0; k < 512; k = k + 1) begin
                @(posedge clk); bar_we <= 1'b1; bar_addr <= k; bar_h <= height(k);
            end
            @(posedge clk); bar_we <= 1'b0; bar_done <= 1'b1;
            @(posedge clk); bar_done <= 1'b0;
            repeat (1486) @(posedge clk);
        end
    end

    // live characters as a string, for the log
    function [8*5-1:0] chars(input integer first, input integer cnt);
        integer i;
        begin
            chars = 0;
            for (i = 0; i < cnt; i = i + 1) chars = {chars[8*4-1:0], 1'b0, dyn[7 * (first + i) +: 7]};
        end
    endfunction
endmodule
