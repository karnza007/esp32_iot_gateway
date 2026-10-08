module top (input clk, input din, output reg dout);
    reg [63:0] sh = 0;
    always @(posedge clk) sh <= {sh[62:0], din ^ sh[63]};
    wire [15:0] a, b;
    ram_test u (.clk(clk), .we_a(sh[0]), .we_b(sh[1]), .addr_a(sh[11:2]), .addr_b(sh[21:12]),
                .din_a(sh[37:22]), .din_b(sh[53:38]), .dout_a(a), .dout_b(b));
    always @(posedge clk) dout <= ^{a, b};
endmodule
