// tb_h3_mic.v — H3 check: INMP441 model -> mic_source at 74.25 MHz, all 8 gains at once.
//
// The INMP441 model is the one from fpga/sim/tb_chain.v (standard I2S, left slot): it sends
// a list of known 24-bit words. Eight mic_source copies (gain 0..7) run in lockstep from
// the same reset and all read the same SD wire; copy 0's SCK/WS clock the model.
// Writes "word s0 s1 ... s7" per frame (+out=<file>); check_h3.py checks the gains and
// saturation, and this testbench checks the bit clock and sample rate itself.
`timescale 1ns/1ps
module tb_h3_mic;
    reg clk = 1'b0;
    always #6.734 clk = ~clk;                     // 74.25 MHz
    reg rst = 1'b1;

    wire [7:0] sck, ws, valid;
    wire signed [15:0] smp [0:7];
    wire       sd;
    genvar g;
    generate
        for (g = 0; g < 8; g = g + 1) begin : m
            mic_source #(.BCLK_DIV(24)) u (.clk(clk), .rst(rst), .i2s_sck(sck[g]), .i2s_ws(ws[g]),
                .i2s_sd(sd), .gain(g[2:0]), .valid(valid[g]), .sample(smp[g]), .clipped());
        end
    endgenerate

    // INMP441 model (from tb_chain.v), driven by copy 0's clocks
    function [23:0] word(input integer n);
        case (n % 10)
            0: word = 24'hA5A5A5;  1: word = 24'h800000;  2: word = 24'h7FFFFF;
            3: word = 24'h123456;  4: word = 24'h000123;  5: word = 24'hFFFEDC;
            6: word = 24'h001000;  7: word = 24'hFFF000;  8: word = 24'h00007F;
            9: word = 24'h400000;
        endcase
    endfunction
    reg [31:0] shifter = 0;  reg ws_d = 1'b1;  reg sd_r = 1'b0;  integer widx = 0;
    assign sd = sd_r;
    always @(negedge sck[0]) begin
        if (ws[0] !== ws_d) begin
            ws_d <= ws[0];
            if (ws[0] == 1'b0) begin shifter <= {word(widx), 8'h00}; widx = widx + 1; end
            else               shifter <= 32'd0;
            sd_r <= 1'b0;
        end else begin
            sd_r <= shifter[31];
            shifter <= {shifter[30:0], 1'b0};
        end
    end

    // rates: clocks per SCK period and per sample
    integer f, nfr = 0, t_now = 0, t_last = -1, gap_bad = 0, sck_bad = 0, t_sck = -1, k;
    always @(posedge clk) t_now = t_now + 1;
    always @(posedge sck[0]) begin
        if (nfr > 0 && t_now - t_sck != 24) sck_bad = sck_bad + 1;   // after start-up
        t_sck = t_now;
    end
    reg [8*256-1:0] fname;
    always @(posedge clk) if (valid[0]) begin
        if (t_last >= 0 && t_now - t_last != 1536) gap_bad = gap_bad + 1;
        t_last = t_now;
        if (valid !== 8'hFF) begin $display("FAIL: copies out of step"); $finish; end
        // the word whose bits just finished: widx was advanced at the start of its slot
        $fwrite(f, "%0d", word(widx - 1));
        for (k = 0; k < 8; k = k + 1) $fwrite(f, " %0d", smp[k]);
        $fwrite(f, "\n");
        nfr = nfr + 1;
        if (nfr == 40) begin
            $display("tb_h3_mic: %0d frames; SCK period errors %0d (want 24 clocks); sample gap errors %0d (want 1536)",
                     nfr, sck_bad, gap_bad);
            $fclose(f);
            $finish;
        end
    end
    initial begin
        if (!$value$plusargs("out=%s", fname)) begin $display("usage: +out=<file>"); $finish; end
        f = $fopen(fname, "w");
        repeat (10) @(posedge clk);
        #1 rst = 1'b0;
    end
endmodule
