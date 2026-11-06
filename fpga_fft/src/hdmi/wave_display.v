// wave_display.v — the third screen (2026-11-06): the microphone's raw waveform, like an
// oscilloscope, on the 1280x720 picture. Display mode 2 (S1 cycles spectrogram -> bars -> waveform).
//
// WHAT IT SHOWS. The same 16-bit samples the FFT gets (after the S2 gain), 1,024 of them =
// 45.9 ms at 22,310.7 Hz (one FFT block), 1 px per sample across x 128..1151.
// Height: y 148..659 (512 px, the spectrogram's box), centre y 403. The edges are the peak of a
// tone that reads -40 dB on the bars / spectrogram scale: +-1311 (a full-scale sine reads
// -12.04 dB there; louder than -40 dB is rare in the room). Each sample becomes a pixel offset
//   off = sample x 800 / 4096 (rounded down) = sample x 256 / 1311, limited to -256 .. 255,
// drawn at y = 403 - off. A sample beyond the edges is drawn at the edge, in red.
// Grid (from rom_wave.v, made by gen_h4_text.py): the centre line, the -50 dB (+-414) and
// -60 dB (+-131) tone peaks, and the edges; tick marks below the plot every 5 ms.
//
// CAPTURE. Like an oscilloscope's trigger, so a steady tone stands still: a capture starts at
// a sample where the signal crosses 0 going up (previous < 0, this >= 0), or anyway after 1,024
// samples without one. The 1,024 samples go into the back half of a double buffer; the halves
// swap in vertical blanking (as bar_display), then the next capture is armed. About 20 new
// pictures per second.
//
// MEMORY. 2 x 1,024 offsets x 9 bits = 1 block RAM.
//
// DRAWING. Each column draws a vertical line from the previous column's height to its own, so
// steep parts of the wave stay joined. Two clocks of delay from x/y to colour (memory read,
// then compare), like bar_display.
module wave_display (
    input  wire               clk,
    input  wire               s_valid,         // one-clock pulse per new sample
    input  wire signed [15:0] s_in,
    input  wire [11:0]        x, y,
    input  wire               de,
    output reg  [7:0]         r = 0, g = 0, b = 0
);
    localparam integer X0 = 128, X1 = 1152, Y_TOP = 148, Y_BOT = 660, YC = 403;

    reg signed [8:0] mem [0:2047];                 // {half, sample} -> offset
    reg              front = 1'b0;                 // the half on screen

    // ---- capture: sample -> offset (2 clocks), then the trigger / capture sequence ----
    reg signed [15:0] s1 = 0;
    reg               v1 = 1'b0, v2 = 1'b0, neg2 = 1'b0;
    reg signed [26:0] prod = 0;                    // sample x 800
    always @(posedge clk) begin
        v1 <= s_valid;  if (s_valid) s1 <= s_in;
        v2 <= v1;       prod <= s1 * $signed(11'sd800);  neg2 <= s1[15];
    end
    wire signed [14:0] off_full = prod[26:12];     // sample x 800 / 4096, rounded down
    wire signed [8:0]  off = (off_full > 15'sd255)  ? 9'sd255  :
                             (off_full < -15'sd256) ? -9'sd256 : off_full[8:0];

    localparam [1:0] ARM = 2'd0, CAP = 2'd1, DONE = 2'd2;
    reg  [1:0] st = ARM;
    reg  [9:0] widx = 0, tcnt = 0;
    reg        prev_neg = 1'b0;
    wire       trig = (prev_neg && !neg2) || (tcnt == 10'd1023);   // rising through 0, or timeout
    wire       we   = v2 && ((st == ARM && trig) || st == CAP);
    wire [9:0] wa   = (st == ARM) ? 10'd0 : widx;
    always @(posedge clk) begin
        if (we) mem[{~front, wa}] <= off;
        if (v2) begin
            prev_neg <= neg2;
            case (st)
                ARM: if (trig) begin widx <= 10'd1;  st <= CAP; end
                     else tcnt <= tcnt + 1'b1;
                CAP: begin
                         widx <= widx + 1'b1;
                         if (widx == 10'd1023) st <= DONE;
                     end
                default: ;
            endcase
        end
        if (st == DONE && x == 12'd0 && y == 12'd720) begin   // first blanking line: swap
            front <= ~front;  st <= ARM;  tcnt <= 0;
        end
    end

    // ---- read (clock 1) ----
    wire [11:0] xr = x - X0;
    reg  signed [8:0] q = 0;
    reg  [11:0] x1 = 0, y1 = 0;
    reg         de1 = 1'b0;
    always @(posedge clk) begin
        q <= mem[{front, xr[9:0]}];
        x1 <= x;  y1 <= y;  de1 <= de;
    end

    // ---- colour (clock 2) ----
    reg  signed [8:0] qp = 0;                      // the previous column's offset
    always @(posedge clk) qp <= q;
    wire signed [8:0]  prev = (x1 == X0) ? q : qp;
    wire        [11:0] yc = YC - {{3{q[8]}}, q};    // this column's height
    wire        [11:0] yp = YC - {{3{prev[8]}}, prev};
    wire        [11:0] lo = (yc < yp) ? yc : yp;
    wire        [11:0] hi = (yc < yp) ? yp : yc;
    wire in_plot = (x1 >= X0) && (x1 < X1) && (y1 >= Y_TOP) && (y1 < Y_BOT);
    wire trace   = in_plot && (y1 >= lo) && (y1 <= hi);
    wire clip    = (q == 9'sd255) || (q == -9'sd256);  // at an edge: -40 dB or beyond
    wire grid, tick;
    wave_grid  u_grid (.x(x1), .y(y1), .q(grid));
    wave_ticks u_tick (.x(x1), .y(y1), .q(tick));
    always @(posedge clk) begin
        if (!de1)                   {r, g, b} <= 24'h000000;
        else if (trace && clip)     {r, g, b} <= 24'hFF4040;   // beyond -40 dB: red
        else if (trace)             {r, g, b} <= 24'h00DC5A;   // the wave: green, as the bars
        else if (in_plot && grid)   {r, g, b} <= 24'h464646;   // grid: as the bars' gridlines
        else if (tick)              {r, g, b} <= 24'h808080;   // time ticks below the plot
        else                        {r, g, b} <= 24'h000000;
    end
endmodule
