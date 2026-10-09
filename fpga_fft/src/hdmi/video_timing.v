// video_timing.v — pixel and line counters for one video format (default: 720p60).
//
// A frame is more than the visible picture. After every line and every frame comes
// invisible "blanking" time, where the sync pulses tell the monitor "new line" (HSYNC)
// and "new frame" (VSYNC). The totals are fixed by the standard (CEA-861 for 720p),
// which is how the monitor recognises the format:
//
//   per line:   1280 visible + 110 front porch + 40 sync + 220 back porch = 1650 slots
//   per frame:   720 visible +   5 front porch +  5 sync +  20 back porch =  750 lines
//   74.25 MHz / (1650 x 750) = 60.00 frames per second
//
// Outputs are registered together, so x/y/de/hs/vs always describe the same slot.
module video_timing #(
    parameter integer H_ACT = 1280, H_FP = 110, H_SYNC = 40, H_BP = 220,
    parameter integer V_ACT = 720,  V_FP = 5,   V_SYNC = 5,  V_BP = 20,
    parameter         HS_POS = 1'b1,  VS_POS = 1'b1        // sync pulse polarity: 1 = active high
)(
    input  wire        clk,            // pixel clock
    input  wire        rst,
    output reg  [11:0] x = 0,          // current slot, 0 .. H_TOT-1 (visible while < H_ACT)
    output reg  [11:0] y = 0,          // current line, 0 .. V_TOT-1
    output reg         de = 1'b0,      // "data enable": inside the visible picture
    output reg         hs = 1'b0,
    output reg         vs = 1'b0,
    output reg         frame_start = 1'b0   // one-clock pulse on the first slot of a frame
);
    localparam integer H_TOT = H_ACT + H_FP + H_SYNC + H_BP;
    localparam integer V_TOT = V_ACT + V_FP + V_SYNC + V_BP;

    reg [11:0] h = 0, v = 0;
    always @(posedge clk) begin
        if (rst) begin
            h <= 0;
            v <= 0;
        end else if (h == H_TOT - 1) begin
            h <= 0;
            v <= (v == V_TOT - 1) ? 12'd0 : v + 1'b1;
        end else
            h <= h + 1'b1;
    end

    // VSYNC starts and ends at the same slot as an HSYNC (on lines V_ACT+V_FP and
    // V_ACT+V_FP+V_SYNC), as the standard has it; both are registered together below.
    localparam integer HS0 = H_ACT + H_FP, VS0 = V_ACT + V_FP, VS1 = V_ACT + V_FP + V_SYNC;
    wire vs_now = (v > VS0 || (v == VS0 && h >= HS0)) && (v < VS1 || (v == VS1 && h < HS0));

    always @(posedge clk) begin
        x  <= h;
        y  <= v;
        de <= (h < H_ACT) && (v < V_ACT);
        hs <= ((h >= HS0) && (h < HS0 + H_SYNC)) ? HS_POS : ~HS_POS;
        vs <= vs_now ? VS_POS : ~VS_POS;
        frame_start <= !rst && (h == 0) && (v == 0);
    end
endmodule
