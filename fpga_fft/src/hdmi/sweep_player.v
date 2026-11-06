// sweep_player.v — plays a sine sweep through the board's MAX98357A amplifier, to demonstrate the
// spectrogram: the speaker's sound reaches the microphone and draws a zig-zag line. It is not
// connected to the mic -> FFT -> screen chain; the sweep reaches the spectrogram only by air.
//
// THE SOUND (defaults). The external button on pin 27 toggles it on and off (since 2026-11-06;
// the first version played one 4 s sweep per press):
//   on:   20 ms silence (amplifier waking up) -> fade in over 512 samples (10.6 ms) -> sweep up
//         200 Hz -> 4 kHz in 4.0 s, down 4 kHz -> 200 Hz in 4.0 s, up again, ... (linear,
//         amplitude AMP = 3277 = -20 dB of full scale)
//   off:  fade out over up to 512 samples, from wherever the sweep is -> 20 ms silence ->
//         amplifier off (PA_EN low), so there is no hiss in between.
//   A press during the 20 ms before the sound cancels it; a press while fading out turns it
//   back on (the fade turns round). Each "on" starts at 200 Hz going up.
//   On the spectrogram (5.9 s wide): a zig-zag between rows 9 and 184 (the dashed 4 kHz line),
//   174 columns per leg.
//
// THE TONE: a phase accumulator, as in tone_gen.v. Every sample, phase += step, and step goes up
// (or down) by SWEEP_STEP; the top 10 bits of the phase index one sine period in rom_sine. At
// the end of each leg (N_SWEEP samples) the step stays for one sample and the direction flips:
// the phase carries on, so the turns are smooth (no click). Steps run STEP_START ..
// STEP_START + (N_SWEEP - 1) x SWEEP_STEP = 200.0 .. 3,999.7 Hz; one up-and-down = 2 x N_SWEEP.
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
    input  wire toggle,                           // one-clock pulse: sound on <-> off
    output reg  bclk = 1'b0,
    output reg  ws   = 1'b0,
    output reg  din  = 1'b0,
    output wire pa_en,                            // amplifier on (high) from "on" to the end of "off"
    output wire playing                           // the sound is on, fades included (for an LED)
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

    // ---- sequence: idle -> quiet -> sound (up/down, until "off") -> fade out -> quiet -> idle ----
    localparam [2:0] IDLE = 3'd0, PRE = 3'd1, PLAY = 3'd2, STOP = 3'd3, POST = 3'd4;
    reg  [2:0]  st = IDLE;
    reg  [15:0] q = 0;                            // samples of quiet so far (PRE, POST)
    reg  [17:0] n = 0;                            // samples into the current leg
    reg         up = 1'b1;                        // the leg: 1 = rising
    reg  [31:0] ph = 0, step = 0;
    reg  [9:0]  env = 0;                          // fade: 0 .. 512
    wire        sounding = (st == PLAY) || (st == STOP);
    assign pa_en   = (st != IDLE);
    assign playing = sounding;

    // ---- the next sample, worked out early in each frame (clocks 4..8), sent from clock 0 ----
    wire signed [15:0] sine;
    rom_sine u_rom (.clk(clk), .addr(ph[31:22]), .q(sine));
    reg  [15:0]        g = 0;                     // AMP x env / 512
    reg  signed [31:0] prod = 0;
    reg  signed [15:0] nxt = 0, cur = 0;
    wire [25:0]        amp_env = AMP * env;
    reg                tog_seen = 1'b0;
    always @(posedge clk) begin
        if (toggle) tog_seen <= 1'b1;
        if (rst) begin
            st <= IDLE;  q <= 0;  nxt <= 0;  tog_seen <= 1'b0;
        end else begin
            if (cnt == 16'd4) g <= amp_env[24:9];                         // AMP x env / 512
            if (cnt == 16'd6) prod <= sine * $signed({1'b0, g});          // rom has answered
            if (cnt == 16'd8) begin
                nxt <= sounding ? prod[30:15] : 16'sd0;
                // step on to the next sample
                if (sounding) begin
                    ph <= ph + step;
                    if (n == N_SWEEP - 1) begin                           // end of a leg: turn
                        n  <= 0;
                        up <= ~up;
                    end else begin
                        n    <= n + 1'b1;
                        step <= up ? step + SWEEP_STEP : step - SWEEP_STEP;
                    end
                end
                case (st)
                    PRE:  if (q == N_QUIET - 1) begin
                              st <= PLAY;  ph <= 0;  step <= STEP_START;  n <= 0;  up <= 1'b1;
                              env <= 0;
                          end else q <= q + 1'b1;
                    PLAY: if (env != FADE) env <= env + 1'b1;
                    STOP: if (env == 0) begin st <= POST;  q <= 0; end
                          else env <= env - 1'b1;
                    POST: if (q == N_QUIET - 1) st <= IDLE;
                          else q <= q + 1'b1;
                    default: ;
                endcase
                if (tog_seen) begin                                       // the button
                    tog_seen <= 1'b0;
                    case (st)
                        IDLE, POST: begin st <= PRE;  q <= 0; end         // on
                        PRE:        st <= IDLE;                           // off before it began
                        PLAY:       st <= STOP;                           // off: fade out
                        STOP:       st <= PLAY;                           // on again: fade back in
                        default: ;
                    endcase
                end
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
