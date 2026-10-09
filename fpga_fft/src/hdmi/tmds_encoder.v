// tmds_encoder.v — 8-bit colour to the 10-bit code HDMI/DVI sends (DVI 1.0, section 3.2).
//
// Why not send the 8 bits as they are? Two problems on a fast cable:
//   1. Many 0->1 / 1->0 transitions make noise and are hard to receive cleanly.
//      Step 1 rewrites the byte as a chain where each bit is XOR (or XNOR) of the
//      previous one, whichever gives fewer transitions. Bit 8 records which was used.
//   2. Long runs of more 1s than 0s (or the reverse) shift the signal's average level.
//      Step 2 keeps a running count of "1s minus 0s" sent so far and, when it leans one
//      way, sends the next word inverted to lean back. Bit 9 records the inversion.
// During blanking (de = 0) one of four fixed control words is sent instead; on the
// blue channel these carry HSYNC (c0) and VSYNC (c1).
// The receiver undoes both steps, so the colour arrives unchanged. Bit 0 is sent first.
module tmds_encoder (
    input  wire       clk,
    input  wire       rst,
    input  wire [7:0] d,           // colour byte
    input  wire       c0, c1,      // control bits, sent while de = 0
    input  wire       de,
    output reg  [9:0] q = 10'd0
);
    function [3:0] ones8(input [7:0] v);
        ones8 = v[0] + v[1] + v[2] + v[3] + v[4] + v[5] + v[6] + v[7];
    endfunction

    // step 1: transition-minimised word q_m
    wire [3:0] n1_d   = ones8(d);
    wire       use_xn = (n1_d > 4) || (n1_d == 4 && !d[0]);
    wire [8:0] q_m;
    assign q_m[0] = d[0];
    genvar i;
    generate
        for (i = 1; i < 8; i = i + 1) begin : chain
            assign q_m[i] = use_xn ? ~(q_m[i-1] ^ d[i]) : (q_m[i-1] ^ d[i]);
        end
    endgenerate
    assign q_m[8] = ~use_xn;

    // step 2: DC balance. cnt = running (1s - 0s) of what has been sent
    wire signed [4:0] n1_q = ones8(q_m[7:0]);
    wire signed [4:0] diff = n1_q - (5'sd8 - n1_q);      // 1s - 0s in q_m[7:0]
    reg  signed [4:0] cnt  = 5'sd0;

    always @(posedge clk) begin
        if (rst) begin
            q   <= 10'd0;
            cnt <= 5'sd0;
        end else if (!de) begin
            case ({c1, c0})
                2'b00: q <= 10'b1101010100;
                2'b01: q <= 10'b0010101011;
                2'b10: q <= 10'b0101010100;
                2'b11: q <= 10'b1010101011;
            endcase
            cnt <= 5'sd0;
        end else if (cnt == 0 || diff == 0) begin
            q   <= {~q_m[8], q_m[8], q_m[8] ? q_m[7:0] : ~q_m[7:0]};
            cnt <= q_m[8] ? cnt + diff : cnt - diff;
        end else if ((cnt > 0 && diff > 0) || (cnt < 0 && diff < 0)) begin
            q   <= {1'b1, q_m[8], ~q_m[7:0]};
            cnt <= cnt + (q_m[8] ? 5'sd2 : 5'sd0) - diff;
        end else begin
            q   <= {1'b0, q_m[8], q_m[7:0]};
            cnt <= cnt - (q_m[8] ? 5'sd0 : 5'sd2) + diff;
        end
    end
endmodule
