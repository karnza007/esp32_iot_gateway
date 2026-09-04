// tb_gen.v — the synthetic source: correct rate, and a counter that never skips.
//   iverilog -g2012 -o /tmp/tb_gen fpga/sim/tb_gen.v fpga/src/sample_gen.v
`timescale 1ns/1ps
module tb_gen;
    localparam integer GEN_DIV = 64;          // small, so the run is short
    reg clk = 0, rst_n = 0;
    wire [15:0] sample;
    wire        sample_valid;
    always #5 clk = ~clk;

    sample_gen #(.GEN_DIV(GEN_DIV)) dut (
        .clk(clk), .rst_n(rst_n), .sample(sample), .sample_valid(sample_valid));

    integer pulses = 0, errors = 0, gap = 0, last_gap = -1;
    reg [15:0] prev = 16'hFFFF;
    reg        seen = 1'b0;

    always @(posedge clk) begin
        if (rst_n) begin
            if (sample_valid) begin
                pulses = pulses + 1;
                if (seen) begin
                    if (sample !== prev + 16'd1) begin
                        $display("  FAIL: counter jumped %04h -> %04h", prev, sample);
                        errors = errors + 1;
                    end
                    if (last_gap != -1 && gap != last_gap) begin
                        $display("  FAIL: interval changed %0d -> %0d", last_gap, gap);
                        errors = errors + 1;
                    end
                    last_gap = gap;
                end
                prev = sample; seen = 1'b1; gap = 0;
            end else if (seen) gap = gap + 1;
        end
    end

    initial begin
        repeat (5) @(posedge clk);
        rst_n = 1'b1;
        repeat (GEN_DIV*40) @(posedge clk);
        $display("tb_gen: %0d pulses, interval %0d cycles (expect %0d)",
                 pulses, last_gap + 1, GEN_DIV);
        if (last_gap + 1 !== GEN_DIV) begin
            $display("  FAIL: wrong rate"); errors = errors + 1;
        end
        if (pulses < 30) begin $display("  FAIL: too few pulses"); errors = errors + 1; end
        // Verilog has no string ternary -- the conditional operator returned a
        // numeric value and printed it as digits. Use a plain if/else.
        if (errors == 0) $display("tb_gen: PASS");
        else             $display("tb_gen: FAIL (%0d errors)", errors);
        $finish;
    end
endmodule
