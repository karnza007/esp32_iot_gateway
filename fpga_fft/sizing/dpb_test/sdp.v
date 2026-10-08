// Semi-dual-port RAM: port A only writes, port B only reads.
module ram_test (input clk, input we_a, we_b, input [9:0] addr_a, addr_b,
                 input [15:0] din_a, din_b, output reg [15:0] dout_a, dout_b);
    reg [15:0] mem [0:1023];
    always @(posedge clk) if (we_a) mem[addr_a] <= din_a;
    always @(posedge clk) dout_b <= mem[addr_b];
    always @(posedge clk) dout_a <= 16'd0;
endmodule
