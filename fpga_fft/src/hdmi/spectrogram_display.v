// spectrogram_display.v — draws the spectrogram (layout A) on the 1280x720 picture.
//
// LAYOUT
//   plot:          x 128..1151, y 148..659 (1024 x 512 px). Time runs left -> right (newest
//                  column at the right edge), frequency bottom -> top (0 -> fs/2).
//   one point:     4 px wide (one FFT) x 2 px tall (two FFT bins). 256 columns = 5.9 s with
//                  50 % overlap (an FFT every 512 samples), 11.7 s without
//   colour scale:  x 1168..1183, y 148..659: white (32 px) at the top, then the 30 colours,
//                  16 px each, -50 dB at the top down to -80 dB
//   tick marks:    left of the plot (every 1 kHz) and below it (every 1 s; 2 s without
//                  overlap), from spec_ticks
//
// WRITING. spectrum.v sends 512 bar heights per FFT (bar_we/bar_addr/bar_h, then bar_done),
// the same stream bar_display gets. Each pair of bins (2r, 2r+1) becomes row r: the louder of
// the two, turned into a level 0..31, one per dB (the height scale is 7.5 px per dB, -80 dB at
// height 0, so dB = height / 7.5 - 80):
//   0       height 0: -80 dB or quieter                  -> black
//   1..30   -80 .. -51 dB, level = height / 7.5 + 1      -> viridis, dark purple .. yellow
//   31      -50 dB or louder (height 225 and up)         -> white
// (Until 2026-11-06: 16 levels of 5 dB, -80..0 dB, inferno colours, 4 bits.)
// The 256 rows of one FFT are one column of the picture memory: 256 columns x 256 rows x
// 5 bits, kept as two memories, 4 bits (16 block RAMs) + 1 bit (4 block RAMs), so the tool
// does not round the width up to 8 bits (32 block RAMs). After bar_done the next FFT goes
// into the next column, overwriting the oldest one.
//
// SCROLLING. Nothing is moved: the screen reads the picture starting at the oldest column,
// `start`, which is updated only in vertical blanking, so a frame never shows two positions.
// The column being written during a frame is the oldest one (screen column 0, the left edge);
// it is drawn black so its half-written state never shows.
//
// Two clocks of delay from x/y to colour (memory read, then colour), like bar_display.
module spectrogram_display (
    input  wire        clk,
    input  wire        bar_we,
    input  wire [8:0]  bar_addr,
    input  wire [9:0]  bar_h,
    input  wire        bar_done,
    input  wire [11:0] x, y,
    input  wire        de,
    output reg  [7:0]  r = 0, g = 0, b = 0
);
    localparam integer X0 = 128, X1 = 1152, Y_TOP = 148, Y_BOT = 660;
    localparam integer SX0 = 1168, SX1 = 1184;            // colour scale

    reg [3:0] mem_lo [0:65535];                           // {column, row} -> level bits 3..0
    reg       mem_hi [0:65535];                           //                  level bit 4

    // ---- write: pairs of bins -> one level per row (3 clocks) ----
    reg [9:0] h_even = 0;
    reg       vA = 1'b0, doneA = 1'b0;  reg [7:0] rowA = 0;  reg [9:0] hA = 0;
    reg       vB = 1'b0, doneB = 1'b0;  reg [7:0] rowB = 0;  reg [4:0] lvlB = 0;
    reg [7:0] wcol = 0;                                   // the column being written
    wire [19:0] prod = hA * 10'd547;                      // height / 7.5 = height x 547 / 2^12
                                                          // (exact, rounded down, for height < 225)
    always @(posedge clk) begin
        if (bar_we && !bar_addr[0]) h_even <= bar_h;
        vA <= bar_we && bar_addr[0];  rowA <= bar_addr[8:1];  doneA <= bar_done;
        hA <= (bar_h > h_even) ? bar_h : h_even;          // the louder bin of the pair
        vB <= vA;  rowB <= rowA;  doneB <= doneA;
        lvlB <= (hA == 10'd0)   ? 5'd0  :
                (hA >= 10'd225) ? 5'd31 : prod[16:12] + 5'd1;
        if (vB) begin
            mem_lo[{wcol, rowB}] <= lvlB[3:0];
            mem_hi[{wcol, rowB}] <= lvlB[4];
        end
        if (doneB) wcol <= wcol + 1'b1;
    end

    // ---- read: the oldest column is shown at the left ----
    reg [7:0] start = 0;
    always @(posedge clk)
        if (x == 0 && y == 12'd720) start <= wcol;         // first blanking line

    wire [11:0] xr = x - X0;
    wire [11:0] yr = (Y_BOT - 1) - y;
    wire [15:0] ra = {start + xr[9:2], yr[8:1]};
    reg  [3:0]  q_lo = 0;
    reg         q_hi = 1'b0;
    wire [4:0]  q = {q_hi, q_lo};
    reg  [11:0] x1 = 0, y1 = 0;
    reg         de1 = 1'b0;
    always @(posedge clk) begin
        q_lo <= mem_lo[ra];
        q_hi <= mem_hi[ra];
        x1 <= x;  y1 <= y;  de1 <= de;
    end

    // ---- colour ----
    wire        in_y     = (y1 >= Y_TOP) && (y1 < Y_BOT);
    wire        in_plot  = in_y && (x1 >= X0 + 4) && (x1 < X1);      // screen column 0 stays black
    wire        in_scale = in_y && (x1 >= SX0) && (x1 < SX1);
    wire [11:0] ys       = y1 - Y_TOP;
    wire [4:0]  s_idx    = (ys[8:4] < 5'd2) ? 5'd31 : 5'd0 - ys[8:4];  // white, then 30 .. 1
    wire [23:0] c_plot, c_scale;
    spec_colour u_cp (.i(q), .rgb(c_plot));
    spec_colour u_cs (.i(s_idx), .rgb(c_scale));
    wire        tick;
    spec_ticks  u_tk (.x(x1), .y(y1), .q(tick));
    always @(posedge clk) begin
        if (!de1)          {r, g, b} <= 24'h000000;
        else if (in_plot)  {r, g, b} <= c_plot;
        else if (in_scale) {r, g, b} <= c_scale;
        else if (tick)     {r, g, b} <= 24'h808080;
        else               {r, g, b} <= 24'h000000;
    end
endmodule
