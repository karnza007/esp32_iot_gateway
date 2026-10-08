// sizing_top.v — F1 only: how big is the FFT core plus ONE 1024 x 32 buffer, and does
// it meet 54 MHz? Pseudo-random data in, every output folded into one pin, so the
// synthesiser cannot delete anything. Not a functional design.
module sizing_top (
    input  wire clk,
    input  wire rst,          // active-low button, like the audio project
    output reg  dbg
);
    reg [31:0] lfsr = 32'hACE1_2468;
    always @(posedge clk) lfsr <= {lfsr[30:0], lfsr[31] ^ lfsr[21] ^ lfsr[1] ^ lfsr[0]};

    // the shared input/output buffer: 1024 complex samples x 32 bits
    reg  [31:0] buffer [0:1023];
    reg  [31:0] rd;
    reg  [9:0]  addr = 0;
    wire [9:0]  idx;
    wire [15:0] xk_re, xk_im;
    wire sod, ipd, eod, busy, soud, opd, eoud;

    always @(posedge clk) begin
        addr <= addr + 1'b1;
        if (opd) buffer[idx] <= {xk_re, xk_im};
        else     buffer[addr] <= lfsr;
        rd <= buffer[addr ^ lfsr[9:0]];
    end

    fft_1024 u_fft (
        .idx(idx), .xk_re(xk_re), .xk_im(xk_im),
        .sod(sod), .ipd(ipd), .eod(eod), .busy(busy),
        .soud(soud), .opd(opd), .eoud(eoud),
        .xn_re(rd[31:16]), .xn_im(rd[15:0]),
        .start(lfsr[3] & lfsr[17] & ~busy), .clk(clk), .rst(~rst)
    );

    always @(posedge clk) dbg <= ^{rd, xk_re, xk_im, idx, sod, ipd, eod, busy, soud, opd, eoud};
endmodule
