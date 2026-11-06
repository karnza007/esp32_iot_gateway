// i2s_tx.v — I2S output to the board's MAX98357A amplifier (2026-11-06; the output part of the
// archived sweep_player.v, unchanged; pins as in Sipeed's TangNano-20K-example/audio).
//
//   frame = one sample = 64 x HALF clocks: 74.25 MHz / 1536 = 48,339.8 Hz for HALF = 24
//   BCLK  = clk / (2 x HALF) = 1.547 MHz, 32 bit clocks per frame (16 bits left, 16 right)
//   WS    = low for the left channel. Philips format: WS changes one bit clock before the MSB.
//   DIN   = the same sample on left and right, MSB first. WS and DIN change when BCLK falls;
//           the amplifier reads them when it rises, half a bit clock (323 ns) later.
//   bit k of a frame (k = 0..31):
//     k = 0       WS -> 0 (left), DIN = right-channel LSB of the previous sample
//     k = 1..16   DIN = left  bits 15..0
//     k = 16      WS -> 1 (right)
//     k = 17..31  DIN = right bits 15..1   (bit 0 is sent at k = 0 of the next frame)
//
// At the start of each frame `sample` is taken in and `req` pulses for one clock: the source
// then has a whole frame to put the next sample on `sample`.
module i2s_tx #(
    parameter integer HALF = 24                   // clocks per half bit clock
)(
    input  wire               clk,
    input  wire               rst,
    input  wire signed [15:0] sample,
    output reg                req  = 1'b0,        // one clock per frame: `sample` was taken
    output reg                bclk = 1'b0,
    output reg                ws   = 1'b0,
    output reg                din  = 1'b0
);
    reg  [15:0] hcnt = 0;                         // 0 .. HALF-1 within a half bit clock
    reg  [5:0]  half = 0;                         // half bit clocks: 0 .. 63
    always @(posedge clk) begin
        if (rst) begin
            hcnt <= 0;  half <= 0;
        end else begin
            hcnt <= (hcnt == HALF - 1) ? 16'd0 : hcnt + 1'b1;
            if (hcnt == HALF - 1) half <= half + 1'b1;
        end
    end
    wire       edge_now = (hcnt == 0);            // a bit-clock edge starts this clock
    wire       falling  = edge_now && !half[0];   // even halves: BCLK low (falls at the start)
    wire [4:0] k        = half[5:1];              // bit number in the frame

    reg signed [15:0] cur = 0;
    always @(posedge clk) begin
        req <= 1'b0;
        if (rst) begin
            bclk <= 1'b0;  ws <= 1'b0;  din <= 1'b0;
        end else if (edge_now) begin
            bclk <= half[0];                      // halves 0, 2, ...: low; 1, 3, ...: high
            if (falling) begin
                ws <= (k >= 5'd16);
                if (k == 5'd0) begin
                    din <= cur[0];                // previous sample's right-channel LSB
                    cur <= sample;
                    req <= 1'b1;
                end else if (k <= 5'd16)
                    din <= cur[16 - k];
                else
                    din <= cur[32 - k];
            end
        end
    end
endmodule
