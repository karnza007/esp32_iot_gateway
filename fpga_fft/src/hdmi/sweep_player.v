// sweep_player.v — plays a sine sweep through the board's MAX98357A amplifier, to demonstrate the
// spectrogram: the speaker's sound reaches the microphone and draws a rising line.
//
// THE SOUND (defaults; one press of the external button on pin 27 starts it, a press while it
// plays starts it again):
//   20 ms silence (amplifier waking up) -> 4.0 s sweep, 200 Hz -> 4 kHz, linear, amplitude AMP
//   (3277 = -20 dB of full scale), faded in and out over 512 samples (10.6 ms) so it does not
//   click -> 20 ms silence -> amplifier off (PA_EN low), so there is no hiss between sweeps.
//   On the spectrogram: 174 columns (4 s), rows 9 -> 184: a straight line from the bottom up to
//   the dashed 4 kHz line.
//
// THE TONE: a phase accumulator, as in tone_gen.v. Every sample, phase += step and step +=
// SWEEP_STEP; the top 10 bits of the phase index one sine period in rom_sine.
//   f = step / 2^32 x fs.   fs = 74.25 MHz / (64 x HALF) = 48,339.8 Hz for HALF = 24.
//
// I2S OUT (the board's MAX98357A; pins as in Sipeed's TangNano-20K-example/audio):
//   BCLK  = clk / (2 x HALF) = 1.547 MHz, 32 bit clocks per sample (16 bits left, 16 right)
//   WS    = fs; low = left channel. Philips format: WS changes one bit clock before the MSB.
//   DIN   = the same sample on left and right, MSB first. WS and DIN change when BCLK falls;
//           the amplifier reads them when it rises, half a bit clock (323 ns) later.
//   bit k of a frame (k = 0..31; frame = 64 x HALF clocks):
//     k = 0       WS -> 0 (left), DIN = right-channel LSB of the previous sample
//     k = 1..16   DIN = left  bits 15..0
//     k = 16      WS -> 1 (right)
//     k = 17..31  DIN = right bits 15..1   (bit 0 is sent at k = 0 of the next frame)
module sweep_player #(
    parameter integer HALF       = 24,            // clocks per half bit clock
    parameter [31:0]  STEP_START = 32'd17769885,  // 200 Hz
    parameter [31:0]  SWEEP_STEP = 32'd1746,      // per sample: 200 Hz -> 4 kHz in N_SWEEP
    parameter integer N_SWEEP    = 193359,        // samples: 4.0 s
    parameter integer N_QUIET    = 967,           // samples of silence before and after: 20 ms
    parameter [15:0]  AMP        = 16'd3277       // peak, of 32767: -20 dB
)(
    input  wire clk,
    input  wire rst,
    input  wire start,                            // one-clock pulse: (re)start the sweep
    output reg  bclk = 1'b0,
    output reg  ws   = 1'b0,
    output reg  din  = 1'b0,
    output wire pa_en,                            // amplifier on (high) from start to the end
    output wire playing                           // the sweep itself (for an LED)
);
    localparam integer FRAME = 64 * HALF;         // clocks per sample
    localparam integer FADE  = 512;               // samples; a power of two (env >> 9 below)

    // ---- frame timing: position in the frame, bit number, bit-clock edges ----
    reg  [15:0] cnt = 0;                          // 0 .. FRAME-1
    reg  [15:0] hcnt = 0;                         // 0 .. HALF-1 within a half bit clock
    reg  [5:0]  half = 0;                         // half bit clocks: 0 .. 63
    always @(posedge clk) begin
        if (rst) begin
            cnt <= 0;  hcnt <= 0;  half <= 0;
        end else begin
            cnt  <= (cnt == FRAME - 1) ? 16'd0 : cnt + 1'b1;
            hcnt <= (hcnt == HALF - 1) ? 16'd0 : hcnt + 1'b1;
            if (hcnt == HALF - 1) half <= half + 1'b1;
        end
    end
    wire       edge_now = (hcnt == 0);            // a bit-clock edge starts this clock
    wire       falling  = edge_now && !half[0];   // even halves: BCLK low (falls at the start)
    wire [4:0] k        = half[5:1];              // bit number in the frame

    // ---- sequence: idle -> quiet -> sweep -> quiet -> idle ----
    localparam [1:0] IDLE = 2'd0, PRE = 2'd1, PLAY = 2'd2, POST = 2'd3;
    reg  [1:0]  st = IDLE;
    reg  [17:0] n = 0;                            // samples into the current part
    reg  [31:0] ph = 0, step = 0;
    reg  [9:0]  env = 0;                          // fade: 0 .. 512
    assign pa_en   = (st != IDLE);
    assign playing = (st == PLAY);

    // ---- the next sample, worked out early in each frame (clocks 4..8), sent from clock 0 ----
    wire signed [15:0] sine;
    rom_sine u_rom (.clk(clk), .addr(ph[31:22]), .q(sine));
    reg  [15:0]        g = 0;                     // AMP x env / 512
    reg  signed [31:0] prod = 0;
    reg  signed [15:0] nxt = 0, cur = 0;
    wire [25:0]        amp_env = AMP * env;
    reg                start_seen = 1'b0;
    always @(posedge clk) begin
        if (start) start_seen <= 1'b1;
        if (rst) begin
            st <= IDLE;  n <= 0;  nxt <= 0;  start_seen <= 1'b0;
        end else begin
            if (cnt == 16'd4) g <= amp_env[24:9];                         // AMP x env / 512
            if (cnt == 16'd6) prod <= sine * $signed({1'b0, g});          // rom has answered
            if (cnt == 16'd8) begin
                nxt <= (st == PLAY) ? prod[30:15] : 16'sd0;
                // step on to the next sample
                n <= n + 1'b1;
                case (st)
                    IDLE: n <= 0;
                    PRE:  if (n == N_QUIET - 1) begin
                              st <= PLAY;  n <= 0;  ph <= 0;  step <= STEP_START;  env <= 0;
                          end
                    PLAY: begin
                              ph   <= ph + step;
                              step <= step + SWEEP_STEP;
                              // fade in over the first 512 samples, out over the last 512
                              if (n + 1 >= N_SWEEP - FADE)  env <= (env == 0) ? 10'd0 : env - 1'b1;
                              else if (env != FADE)         env <= env + 1'b1;
                              if (n == N_SWEEP - 1) begin st <= POST;  n <= 0; end
                          end
                    POST: if (n == N_QUIET - 1) begin st <= IDLE;  n <= 0; end
                endcase
                if (start_seen) begin st <= PRE;  n <= 0;  start_seen <= 1'b0; end
            end
        end
    end

    // ---- I2S out ----
    always @(posedge clk) begin
        if (rst) begin
            bclk <= 1'b0;  ws <= 1'b0;  din <= 1'b0;
        end else if (edge_now) begin
            bclk <= half[0];                      // halves 0, 2, ...: low; 1, 3, ...: high
            if (falling) begin
                ws <= (k >= 5'd16);
                if (k == 5'd0) begin
                    din <= cur[0];                // previous sample's right-channel LSB
                    cur <= nxt;
                end else if (k <= 5'd16)
                    din <= cur[16 - k];
                else
                    din <= cur[32 - k];
            end
        end
    end
endmodule
