// True dual-port RAM: BOTH ports can read AND write -- what the FFT core needs.
// Normal mode: a port either writes or reads in a given clock.
module ram_test (input clk, input we_a, we_b, input [9:0] addr_a, addr_b,
                 input [15:0] din_a, din_b, output reg [15:0] dout_a, dout_b);
    reg [15:0] mem [0:1023];
    always @(posedge clk) if (we_a) mem[addr_a] <= din_a; else dout_a <= mem[addr_a];
    always @(posedge clk) if (we_b) mem[addr_b] <= din_b; else dout_b <= mem[addr_b];
endmodule
