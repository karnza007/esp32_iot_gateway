// bar_display.v — draws the 512 bar heights on the 1280x720 picture.
//
// LAYOUT
//   bars:      x 128..1151 (512 bars x 2 px), bottom at y = 660, up to 600 px tall
//   gridlines: every 20 dB = 120 px: y = 60 (0 dB), 180, 300, 420, 540, 660 (-100 dB)
//
// DOUBLE BUFFER. The heights live in two halves of one memory. The spectrum side writes a
// whole new set into the back half; when it's complete, the halves swap during the next
// vertical blanking (when no visible line is being drawn), so the screen never shows a
// half-old, half-new spectrum.
//
// Two clocks of delay from x/y to colour (memory read, then compare); the caller delays
// de/hs/vs by the same amount.
module bar_display (
    input  wire        clk,
    input  wire        bar_we,
    input  wire [8:0]  bar_addr,
    input  wire [9:0]  bar_h,
    input  wire        bar_done,
    input  wire [11:0] x, y,
    input  wire        de,
    output reg  [7:0]  r = 0, g = 0, b = 0
);
    localparam integer X0 = 128, X1 = 1152, Y_BOT = 660;

    reg [9:0] mem [0:1023];
    reg front = 1'b0, pending = 1'b0;
    always @(posedge clk) begin
        if (bar_we) mem[{~front, bar_addr}] <= bar_h;
        if (bar_done) pending <= 1'b1;
        if (pending && x == 0 && y == 12'd720) begin   // first blanking line: swap
            front   <= ~front;
            pending <= 1'b0;
        end
    end

    wire [11:0] xb = x - 12'd128;                       // X0
    reg  [9:0]  h_q = 0;
    reg  [11:0] x1 = 0, y1 = 0;
    reg         de1 = 0;
    always @(posedge clk) begin
        h_q <= mem[{front, xb[9:1]}];                   // the bar under this pixel
        x1  <= x;  y1 <= y;  de1 <= de;
    end

    wire in_x   = (x1 >= X0) && (x1 < X1);
    wire in_bar = in_x && (y1 < Y_BOT) && (y1 + h_q >= Y_BOT);
    wire grid   = in_x && (y1 == 60 || y1 == 180 || y1 == 300 || y1 == 420 || y1 == 540 || y1 == 660);
    always @(posedge clk) begin
        if (!de1)        {r, g, b} <= 24'h000000;
        else if (in_bar) {r, g, b} <= 24'h00DC5A;       // bars: green
        else if (grid)   {r, g, b} <= 24'h464646;       // gridlines: dark grey
        else             {r, g, b} <= 24'h000000;
    end
endmodule
