// text_overlay.v — H4: draws the text and the kHz tick lines on top of the bar picture.
//
// The picture is a grid of 80 x 45 cells, 16x16 px each. For the pixel at (x, y):
//   cell     col = x / 16, row = y / 16  ->  rom_text: which character, which colour
//   glyph    row (y mod 16) / 2, column (x mod 16) / 2  ->  rom_font: is this pixel lit
// Each font pixel is drawn as a 2x2 block. Rows 1 and 42 change with the source: they are
// read from rows 45 + src and 48 + src (see gen_h4_text.py). A cell marked "live" takes its
// character from dyn (peak_readout.v) instead of the ROM.
//
// TIMING. bar_display gives the bar colour 2 clocks after x/y. This block takes 4:
//   clock 1: text ROM address (row/column)   clock 2: text ROM and tick ROM
//   clock 3: font ROM                        clock 4: final colour
// (The address has a clock of its own: computed and looked up in one clock, it missed
// 74.25 MHz by a hair.) The caller delays de/hs/vs by 4.
module text_overlay (
    input  wire        clk,
    input  wire [11:0] x, y,           // the same x/y that go into bar_display
    input  wire        de,
    input  wire [1:0]  src,
    input  wire [76:0] dyn,            // 11 live characters, char k at [7k+6:7k]
    input  wire [23:0] bar_rgb,        // bar_display's colour (2 clocks after x/y)
    output reg  [23:0] rgb = 24'h000000
);
    // ---- clock 1: which cell ----
    wire [5:0] row = y[9:4];
    wire [5:0] row_eff = (row == 6'd1)  ? 6'd45 + src :
                         (row == 6'd42) ? 6'd48 + src : row;
    reg [12:0] addr1 = 0;
    reg [11:0] x1 = 0, y1 = 0;
    reg        de1 = 1'b0;
    always @(posedge clk) begin addr1 <= {row_eff, x[10:4]}; x1 <= x; y1 <= y; de1 <= de; end

    // ---- clock 2: which character is in this cell; is there a tick line at this x ----
    wire [9:0] t_q;
    wire       tick_q;
    rom_text  u_text (.clk(clk), .addr(addr1), .q(t_q));
    rom_ticks u_tick (.clk(clk), .src(src), .x(x1), .q(tick_q));
    reg [11:0] x2 = 0, y2 = 0;
    reg        de2 = 1'b0;
    always @(posedge clk) begin x2 <= x1; y2 <= y1; de2 <= de1; end

    // ---- clock 3: the glyph row of that character ----
    wire [6:0] code = t_q[7] ? dyn[7 * t_q[3:0] +: 7] : t_q[6:0];
    wire [7:0] f_q;
    rom_font u_font (.clk(clk), .addr({code, y2[3:1]}), .q(f_q));
    wire plot2 = (x2 >= 12'd128) && (x2 < 12'd1152) && (y2 >= 12'd60) && (y2 < 12'd660);
    reg [2:0]  fx3 = 0;
    reg [1:0]  col3 = 0;
    reg        de3 = 1'b0, tick3 = 1'b0;
    reg [23:0] bar3 = 0;
    always @(posedge clk) begin
        fx3   <= x2[3:1];
        col3  <= t_q[9:8];
        de3   <= de2;
        tick3 <= tick_q && plot2;
        bar3  <= bar_rgb;                // 2 clocks after x/y in, so 3 here
    end

    // ---- clock 4: final colour. Text sits outside the plot, ticks go behind the bars ----
    wire lit = f_q[3'd7 - fx3];
    reg [23:0] text_rgb;
    always @(*)
        case (col3)
            2'd0: text_rgb = 24'hFFFFFF;    // title: white
            2'd1: text_rgb = 24'hB4B4B4;    // axis labels: light grey
            2'd2: text_rgb = 24'hFFD23C;    // peak readout: yellow
            default: text_rgb = 24'h50C8FF; // source and gain: cyan
        endcase
    always @(posedge clk)
        if (!de3)                         rgb <= 24'h000000;
        else if (lit)                     rgb <= text_rgb;
        else if (tick3 && bar3 == 24'h0)  rgb <= 24'h2A2A2A;   // tick: dimmer than the gridlines
        else                              rgb <= bar3;
endmodule
