// tb_h6_wave.v — waveform-page check: renders one whole 1280x720 frame of display mode 2.
//
// A known wave goes into wave_display as the mic samples would (one sample every 16 clocks
// instead of 3,328, to keep the run short; the display counts samples, not time):
//   sample n = round(1600 sin(2 pi n / 37.3) + 300 sin(2 pi n / 7.1))
// 1600 is beyond the -40 dB edge (1311), so the peaks must be drawn red at the edges.
// Every sample fed is written to +samp=<file>; after two captures have been shown, one whole
// frame is written as hex, one pixel per line, to +out=<file>. check_h6.py finds where in the
// samples the shown capture starts and checks every pixel of the plot, the grid, the ticks and
// the labels.
//   iverilog -g2012 -s tb_h6_wave -o h6.vvp sim/tb_h6_wave.v src/hdmi/{video_timing,wave_display,
//            rom_wave,text_overlay,rom_text,rom_font,rom_ticks}.v
`timescale 1ns/1ps
module tb_h6_wave;
    reg clk = 1'b0;
    always #6.734 clk = ~clk;                     // 74.25 MHz
    reg rst = 1'b1;

    wire [11:0] x, y;
    wire de, hs, vs, fs;
    video_timing u_tim (.clk(clk), .rst(rst), .x(x), .y(y), .de(de), .hs(hs), .vs(vs), .frame_start(fs));

    reg               s_valid = 1'b0;
    reg signed [15:0] s = 0;
    wire [7:0] wr, wg, wb;
    wave_display u_wave (.clk(clk), .s_valid(s_valid), .s_in(s), .x(x), .y(y), .de(de),
                         .r(wr), .g(wg), .b(wb));
    wire [76:0] dyn = {11{7'h20}};                // live characters: spaces
    wire [23:0] rgb;
    text_overlay u_text (.clk(clk), .x(x), .y(y), .de(de), .page(2'd2), .dyn(dyn),
                         .bar_rgb({wr, wg, wb}), .rgb(rgb));
    reg [2:0] d1 = 0, d2 = 0, d3 = 0, d4 = 0;
    always @(posedge clk) begin d1 <= {de, hs, vs}; d2 <= d1; d3 <= d2; d4 <= d3; end

    // the wave
    integer n = 0, div = 0, fsamp;
    real    v;
    always @(posedge clk) begin
        s_valid <= 1'b0;
        if (!rst) begin
            div = div + 1;
            if (div == 16) begin
                div = 0;
                v = 1600.0 * $sin(2.0 * 3.14159265358979 * n / 37.3) + 300.0 * $sin(2.0 * 3.14159265358979 * n / 7.1);
                s <= $rtoi(v < 0 ? v - 0.5 : v + 0.5);
                s_valid <= 1'b1;
                $fwrite(fsamp, "%0d\n", $rtoi(v < 0 ? v - 0.5 : v + 0.5));
                n = n + 1;
            end
        end
    end

    integer f, npx = 0, swaps = 0;
    reg [8*256-1:0] fname, sname;
    reg capture = 1'b0, front_q = 1'b0;
    always @(posedge clk) begin
        front_q <= u_wave.front;
        if (u_wave.front != front_q) swaps = swaps + 1;
        if (capture && d4[2]) begin $fwrite(f, "%06x\n", rgb); npx = npx + 1; end
    end
    initial begin
        if (!$value$plusargs("out=%s", fname) || !$value$plusargs("samp=%s", sname)) begin
            $display("usage: +out=<file> +samp=<file>"); $finish;
        end
        f = $fopen(fname, "w");
        fsamp = $fopen(sname, "w");
        repeat (10) @(posedge clk);
        rst <= 1'b0;
        wait (swaps == 2);                        // a second capture is on screen from this frame
        wait (y == 12'd0 && x == 12'd0);
        @(posedge clk); capture <= 1'b1;
        wait (y == 12'd720);
        repeat (8) @(posedge clk);
        capture <= 1'b0;
        $display("tb_h6_wave: %0d pixels (want 921600); %0d samples fed; %0d swaps", npx, n, swaps);
        $fclose(f);  $fclose(fsamp);
        $finish;
    end
endmodule
