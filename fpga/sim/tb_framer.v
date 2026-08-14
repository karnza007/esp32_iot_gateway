// tb_framer.v — checks the v2 frame format and, above all, the overflow counter.
//
// An overflow counter that is itself wrong would silently invalidate every
// measurement in the load sweep, so it gets a positive control here: the drain
// is deliberately stalled, the testbench counts the drops independently, and the
// two numbers must agree.
//
//   iverilog -g2012 -o /tmp/tb_framer fpga/sim/tb_framer.v fpga/src/framer.v
//   vvp /tmp/tb_framer
//
// FRAME_SAMPLES is 8 here instead of 512 purely to keep the run short; the logic
// under test is identical.

`timescale 1ns/1ps
module tb_framer;

    localparam integer FRAME_SAMPLES = 8;
    localparam integer FIFO_DEPTH    = 64;
    localparam integer FRAME_BYTES   = 10 + 2*FRAME_SAMPLES + 2;   // 28
    localparam [15:0]  CFG           = 16'h0119;                   // NUM_CH=1, DIV=25

    reg         clk = 0, rst_n = 0;
    reg  [15:0] sample = 0;
    reg         sample_valid = 0;
    reg         tx_ready = 0;
    wire [7:0]  tx_data;
    wire        tx_valid;
    wire [15:0] ovf_count, seq_count;

    always #5 clk = ~clk;                      // 100 MHz sim clock (timing irrelevant)

    framer #(.FIFO_DEPTH(FIFO_DEPTH), .FRAME_SAMPLES(FRAME_SAMPLES)) dut (
        .clk(clk), .rst_n(rst_n),
        .sample(sample), .sample_valid(sample_valid),
        .cfg(CFG),
        .tx_data(tx_data), .tx_valid(tx_valid), .tx_ready(tx_ready),
        .ovf_count(ovf_count), .seq_count(seq_count)
    );

    // ------------------------------------------------------------------
    // collector — every byte the framer hands to the UART
    // ------------------------------------------------------------------
    reg  [7:0]  rx [0:4095];
    integer     rxn = 0;
    always @(posedge clk)
        if (tx_valid && tx_ready) begin
            rx[rxn] = tx_data;
            rxn     = rxn + 1;
        end

    // independent drop counter: peek at the DUT's own push-into-full condition
    integer drops = 0;
    always @(posedge clk)
        if (rst_n && dut.push && dut.full) drops = drops + 1;

    // ------------------------------------------------------------------
    integer errors = 0;
    integer i, k, base, s;
    integer exp_sum;
    reg [15:0] got;

    task check16(input [127:0] name, input [15:0] a, input [15:0] b);
        begin
            if (a !== b) begin
                $display("  FAIL %0s: got %04h expected %04h", name, a, b);
                errors = errors + 1;
            end
        end
    endtask

    task check8(input [127:0] name, input [7:0] a, input [7:0] b);
        begin
            if (a !== b) begin
                $display("  FAIL %0s: got %02h expected %02h", name, a, b);
                errors = errors + 1;
            end
        end
    endtask

    // deterministic, easy to recompute by hand
    function [15:0] pattern(input integer n);
        pattern = 16'h1234 + n * 16'h0111;
    endfunction

    // feed one sample into the framer
    task send_sample(input [15:0] v);
        begin
            @(posedge clk);
            sample       <= v;
            sample_valid <= 1'b1;
            @(posedge clk);
            sample_valid <= 1'b0;
            repeat (40) @(posedge clk);   // let the FSM emit the whole burst
        end
    endtask

    // verify the frame that starts at rx[base] for frame number `fnum`
    task check_frame(input integer base, input [15:0] fnum, input [15:0] exp_ovf,
                     input integer first_sample);
        begin
            check8("sync0", rx[base+0], 8'hAA);
            check8("sync1", rx[base+1], 8'h55);
            check8("sync2", rx[base+2], 8'hA5);
            check8("sync3", rx[base+3], 8'h5A);
            check16("seq", {rx[base+5], rx[base+4]}, fnum);
            check16("ovf", {rx[base+7], rx[base+6]}, exp_ovf);
            check16("cfg", {rx[base+9], rx[base+8]}, CFG);

            exp_sum = 0;
            for (s = 0; s < FRAME_SAMPLES; s = s + 1) begin
                got = pattern(first_sample + s);
                check8("payload_lo", rx[base+10+2*s],   got[7:0]);
                check8("payload_hi", rx[base+10+2*s+1], got[15:8]);
                exp_sum = (exp_sum + got[7:0] + got[15:8]) % 65536;
            end
            check16("checksum", {rx[base+FRAME_BYTES-1], rx[base+FRAME_BYTES-2]},
                    exp_sum[15:0]);
        end
    endtask

    // find the first sync word at or after `from` whose checksum validates
    function integer find_good_frame(input integer from);
        integer p, q, sum;
        reg [15:0] want;
        begin
            find_good_frame = -1;
            for (p = from; p <= rxn - FRAME_BYTES; p = p + 1) begin
                if (find_good_frame == -1 &&
                    rx[p]==8'hAA && rx[p+1]==8'h55 && rx[p+2]==8'hA5 && rx[p+3]==8'h5A) begin
                    sum = 0;
                    for (q = 0; q < 2*FRAME_SAMPLES; q = q + 1)
                        sum = (sum + rx[p+10+q]) % 65536;
                    want = {rx[p+FRAME_BYTES-1], rx[p+FRAME_BYTES-2]};
                    if (want == sum[15:0]) find_good_frame = p;
                end
            end
        end
    endfunction

    integer good;

    initial begin
        $dumpfile("/tmp/tb_framer.vcd");
        $dumpvars(0, tb_framer);

        repeat (5) @(posedge clk);
        rst_n    = 1'b1;
        tx_ready = 1'b1;                       // fast drain
        repeat (5) @(posedge clk);

        // ---------------- T1: three clean frames ----------------
        $display("T1: frame layout, seq, cfg, checksum (fast drain)");
        for (i = 0; i < 3*FRAME_SAMPLES; i = i + 1) send_sample(pattern(i));
        repeat (200) @(posedge clk);

        if (rxn < 3*FRAME_BYTES) begin
            $display("  FAIL: only %0d bytes emitted, expected >= %0d",
                     rxn, 3*FRAME_BYTES);
            errors = errors + 1;
        end else begin
            for (k = 0; k < 3; k = k + 1)
                check_frame(k*FRAME_BYTES, k[15:0], 16'd0, k*FRAME_SAMPLES);
        end
        if (errors == 0) $display("  ok  (%0d bytes, seq 0..2, ovf 0)", rxn);

        // ---------------- T2: overflow is counted ----------------
        $display("T2: stall the drain; every dropped byte must be counted");
        tx_ready = 1'b0;                       // UART stops accepting
        for (i = 3*FRAME_SAMPLES; i < 7*FRAME_SAMPLES; i = i + 1)
            send_sample(pattern(i));
        repeat (100) @(posedge clk);

        if (drops == 0) begin
            $display("  FAIL: stalled drain produced no drops - test is not exercising overflow");
            errors = errors + 1;
        end
        check16("ovf_count vs independent count", ovf_count, drops[15:0]);
        if (errors == 0)
            $display("  ok  (%0d bytes dropped, ovf_count = %0d)", drops, ovf_count);

        // ---------------- T3: ovf reaches the host in a header ----------------
        $display("T3: resume drain; a later frame header must carry ovf = %0d", drops);
        tx_ready = 1'b1;
        repeat (400) @(posedge clk);           // flush the pre-stall backlog first:
        rxn      = 0;                          // those frames were built BEFORE the
                                               // overflow and correctly carry ovf = 0
        for (i = 7*FRAME_SAMPLES; i < 11*FRAME_SAMPLES; i = i + 1)
            send_sample(pattern(i));
        repeat (200) @(posedge clk);

        good = find_good_frame(0);
        if (good < 0) begin
            $display("  FAIL: no checksum-valid frame after recovery");
            errors = errors + 1;
        end else begin
            check16("ovf in header", {rx[good+7], rx[good+6]}, drops[15:0]);
            if (errors == 0)
                $display("  ok  (frame at byte %0d, seq %0d, ovf %0d)",
                         good, {rx[good+5], rx[good+4]}, {rx[good+7], rx[good+6]});
        end

        // ---------------- verdict ----------------
        $display("");
        if (errors == 0) $display("tb_framer: PASS");
        else             $display("tb_framer: FAIL (%0d errors)", errors);
        $finish;
    end
endmodule
