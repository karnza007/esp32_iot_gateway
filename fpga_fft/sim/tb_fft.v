// tb_fft.v — simulate the Gowin FFT core with free tools (Icarus Verilog).
//
// The core's synthesis file (src/fft/fft_1024.v) is encrypted, so no free
// simulator can read it. But the IP generator also writes fft_1024.vo, an
// UNENCRYPTED gate-level model (LUTs, flip-flops, ALUs, block RAMs, multipliers
// wired together), and the IDE ships an unencrypted library that says how each of
// those building blocks behaves (IDE/simlib/gw2a/prim_sim.v). Together they let
// Icarus run the real core, gate by gate:
//
//   tb_fft.v + ../src/fft/fft_1024.vo + prim_sim.v ──iverilog──▶ vvp ──▶ results
//
// The testbench drives the core exactly as Gowin's manual (IPUG503 Figure 6-1)
// says, and independently of top.v: while ipd is high, xn = sample[idx].
//   +in=<file>   1024 lines of 8 hex digits, {im, re}   (written by fft_bench.py)
//   +out=<file>  the same format for the 1024 results, bin order (by idx)
// It prints the phase stamps the same way top.v measures them on the board.
`timescale 1ns/100ps
module tb_fft;
    reg clk = 1'b0;
    always #18.5 clk = ~clk;                       // 27 MHz, like the board

    reg         rst = 1'b1, start = 1'b0;
    reg  [31:0] sample [0:1023];
    reg  [31:0] result [0:1023];
    wire [9:0]  idx;
    wire [15:0] xk_re, xk_im;
    wire        sod, ipd, eod, busy, soud, opd, eoud;

    // The sample the core asks for. The #2 puts the change just after the clock
    // edge, as real wires would, so it is taken cleanly at the NEXT edge.
    wire [31:0] xn;
    assign #2 xn = sample[idx];

    // Gowin's library has every flip-flop listen to a chip-wide "global set/reset"
    // (GSR) block, found by name. On the chip it exists automatically; in
    // simulation it must be placed here, held inactive (GSRI = 1).
    GSR GSR (.GSRI(1'b1));

    fft_1024 dut (
        .clk(clk), .rst(rst), .start(start),
        .xn_re(xn[15:0]), .xn_im(xn[31:16]),
        .idx(idx), .xk_re(xk_re), .xk_im(xk_im),
        .sod(sod), .ipd(ipd), .eod(eod), .busy(busy),
        .soud(soud), .opd(opd), .eoud(eoud));

    // Stamps: cycle counter = 0 in the clock where start is high (as in top.v).
    // Everything is sampled mid-cycle (falling edge), when all signals are settled.
    integer cyc = -1, t_sod = -1, t_eod = -1, t_brise = -1, t_bfall = -1, t_soud = -1,
            t_eoud = -1, n_out = 0, k;
    reg [1023:0] seen_bin = 0;
    reg [8*256-1:0] fin, fout;

    always @(negedge clk) begin
        if (start) cyc = 0;
        else if (cyc >= 0) cyc = cyc + 1;
        if (cyc >= 0) begin
            if (sod  && t_sod   < 0) t_sod   = cyc;
            if (eod  && t_eod   < 0) t_eod   = cyc;
            if (busy && t_brise < 0) t_brise = cyc;
            if (!busy && t_brise >= 0 && t_bfall < 0) t_bfall = cyc;
            if (soud && t_soud  < 0) t_soud  = cyc;
            if (opd) begin
                result[idx] = {xk_im, xk_re};
                seen_bin[idx] = 1'b1;
                n_out = n_out + 1;
            end
            if (eoud && t_eoud < 0) t_eoud = cyc;
        end
    end

    initial begin
        if (!$value$plusargs("in=%s", fin) || !$value$plusargs("out=%s", fout)) begin
            $display("usage: vvp tb_fft +in=<file> +out=<file>");
            $finish;
        end
        $readmemh(fin, sample);
        for (k = 0; k < 1024; k = k + 1) result[k] = 32'hxxxxxxxx;
        // Inputs change just after a rising edge (#1), like a flip-flop output
        // would, so nothing that reads them on the falling edge can race them.
        repeat (20) @(posedge clk);
        #1 rst = 1'b0;
        repeat (20) @(posedge clk);
        #1 start = 1'b1;                           // one-clock pulse
        @(posedge clk);
        #1 start = 1'b0;
        fork
            begin wait (t_eoud >= 0); repeat (5) @(negedge clk); end
            begin repeat (100000) @(negedge clk); $display("TIMEOUT: eoud never came"); end
        join_any
        $writememh(fout, result);
        $display("STAMPS sod=%0d eod=%0d busy_rise=%0d busy_fall=%0d soud=%0d eoud=%0d total=%0d outputs=%0d bins_covered=%0d",
                 t_sod, t_eod, t_brise, t_bfall, t_soud, t_eoud, t_eoud + 1, n_out, $countones(seen_bin));
        $finish;
    end
endmodule
