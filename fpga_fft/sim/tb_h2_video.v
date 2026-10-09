// tb_h2_video.v — H2 check, screen side: bar heights -> one full 1280x720 frame of pixels.
//
// Loads 512 heights (+bars=<file>, "bin height" per line) through bar_display's write port,
// signals "done", waits for the swap in vertical blanking, then records every visible pixel
// of the next frame as rrggbb (+out=<file>). check_h2.py compares it with the layout.
`timescale 1ns/1ps
module tb_h2_video;
    reg clk = 1'b0;
    always #6.734 clk = ~clk;
    reg rst = 1'b1;

    wire [11:0] x, y;
    wire        de, hs, vs, fs;
    video_timing u_tim (.clk(clk), .rst(rst), .x(x), .y(y), .de(de), .hs(hs), .vs(vs),
                        .frame_start(fs));
    reg        bar_we = 0, bar_done = 0;
    reg [8:0]  bar_addr = 0;
    reg [9:0]  bar_h = 0;
    wire [7:0] r, g, b;
    bar_display u_bars (.clk(clk), .bar_we(bar_we), .bar_addr(bar_addr), .bar_h(bar_h),
                        .bar_done(bar_done), .x(x), .y(y), .de(de), .r(r), .g(g), .b(b));
    reg de1 = 0, de2 = 0;                          // the same 2-clock delay as video_h2.v
    always @(posedge clk) begin de1 <= de; de2 <= de1; end

    reg [9:0] heights [0:511];
    integer fin, fo, k, a, h, npix = 0, rec = 0;
    reg [8*256-1:0] fbars, fout;
    always @(posedge clk) if (rec == 2 && de2) begin
        $fwrite(fo, "%02h%02h%02h\n", r, g, b);
        npix = npix + 1;
    end
    initial begin
        if (!$value$plusargs("bars=%s", fbars) || !$value$plusargs("out=%s", fout)) begin
            $display("usage: +bars=<file> +out=<file>"); $finish;
        end
        fin = $fopen(fbars, "r");
        for (k = 0; k < 512; k = k + 1) begin
            if ($fscanf(fin, "%d %d\n", a, h) != 2) begin $display("bad bars file"); $finish; end
            heights[a] = h;
        end
        fo = $fopen(fout, "w");
        repeat (10) @(posedge clk);
        #1 rst = 1'b0;
        for (k = 0; k < 512; k = k + 1) begin      // write all heights, then "done"
            @(posedge clk); #1 bar_we = 1; bar_addr = k; bar_h = heights[k];
        end
        @(posedge clk); #1 bar_we = 0; bar_done = 1;
        @(posedge clk); #1 bar_done = 0;
        wait (u_bars.front == 1'b1);              // swapped during vertical blanking
        rec = 1;
        wait (y == 0 && x == 0);                  // next frame begins
        @(posedge clk); rec = 2;
        wait (npix == 1280 * 720);
        $fclose(fo);
        $display("tb_h2_video: wrote %0d pixels", npix);
        $finish;
    end
endmodule
