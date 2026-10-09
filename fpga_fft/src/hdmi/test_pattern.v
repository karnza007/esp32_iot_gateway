// test_pattern.v — H1 test picture for 1280x720.
//
//   rows   0-559  eight colour bars, 160 px each: white yellow cyan green magenta red blue black
//   rows 560-619  grey ramp, black at the left to white at the right (all 256 levels)
//   rows 640-679  a 40x40 white square moving 4 px per frame (proves the picture is live)
//   edges         a 1-pixel white border (proves nothing is cut off by the monitor)
// One clock of delay: rgb belongs to the slot that was on x/y one clock earlier.
module test_pattern (
    input  wire        clk,
    input  wire [11:0] x,
    input  wire [11:0] y,
    input  wire        de,
    input  wire        frame_start,
    output reg  [7:0]  r = 0,
    output reg  [7:0]  g = 0,
    output reg  [7:0]  b = 0
);
    reg [10:0] sq_x = 0;                       // left edge of the moving square
    always @(posedge clk)
        if (frame_start) sq_x <= (sq_x >= 1280 - 40 - 4) ? 11'd0 : sq_x + 11'd4;

    wire [2:0] bar = (x < 160) ? 3'd0 : (x < 320) ? 3'd1 : (x < 480) ? 3'd2 : (x < 640) ? 3'd3 :
                     (x < 800) ? 3'd4 : (x < 960) ? 3'd5 : (x < 1120) ? 3'd6 : 3'd7;
    reg [23:0] bar_rgb;
    always @* begin
        case (bar)                             // {red, green, blue}
            3'd0: bar_rgb = 24'hFFFFFF;        // white
            3'd1: bar_rgb = 24'hFFFF00;        // yellow
            3'd2: bar_rgb = 24'h00FFFF;        // cyan
            3'd3: bar_rgb = 24'h00FF00;        // green
            3'd4: bar_rgb = 24'hFF00FF;        // magenta
            3'd5: bar_rgb = 24'hFF0000;        // red
            3'd6: bar_rgb = 24'h0000FF;        // blue
            default: bar_rgb = 24'h000000;     // black
        endcase
    end
    wire [18:0] ramp_x = x * 8'd51;            // x * 51 / 256: 0 .. 254 across 1280 px
    wire [7:0]  grey   = ramp_x[15:8];

    wire border = (x == 0) || (x == 1279) || (y == 0) || (y == 719);
    wire square = (y >= 640) && (y < 680) && (x >= sq_x) && (x < sq_x + 40);

    always @(posedge clk) begin
        if (!de)              {r, g, b} <= 24'h000000;
        else if (border)      {r, g, b} <= 24'hFFFFFF;
        else if (y < 560)     {r, g, b} <= bar_rgb;
        else if (y >= 560 && y < 620) {r, g, b} <= {grey, grey, grey};
        else if (square)      {r, g, b} <= 24'hFFFFFF;
        else                  {r, g, b} <= 24'h000000;
    end
endmodule
