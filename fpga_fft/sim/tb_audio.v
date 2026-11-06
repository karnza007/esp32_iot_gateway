// tb_audio.v — audio_rx + i2s_tx with a model of the Mac (host/play_song.py) on the serial line.
//
// The Mac model: sends RESET (seq 255), waits for "R", may then send 1,536 samples, and sends 256
// more (8 packets back to back) for each "C" it reads, after a random delay of up to
// +maxdelay=<clocks> (default 150,000: about 12 ms of music at this test's speed). Its bit time is
// 1 % shorter than the FPGA's, as on the board (3 Mbaud against 2.97). +bad=<k> corrupts one
// byte of packet k. The music: x[n] = round(3000 sin(2 pi n / 37.7) + 700 sin(2 pi n / 5.3)) + 1.
// To keep the run short: HALF = 4 (256 clocks per output frame instead of 1,536) and
// CLK_PER_BIT = 8 (instead of 25); the ratios stay close to the board's.
// Written to +out=<file>:
//   line 1: N, the bad packet (-1 if none), and the FPGA's counters at the end:
//           bad sums, seq gaps, dropped, underruns; the most samples ever buffered; credits read
//   line 2: the samples sent, in order
// and to +bits=<file>: one character per BCLK rising edge, '0' + {pa_en, ws, din}.
// check_audio.py decodes the bits and checks them against line 2.
//   iverilog -g2012 -s tb_audio -o au.vvp sim/tb_audio.v src/hdmi/audio_rx.v src/hdmi/i2s_tx.v
//            src/uart_rx.v ../fpga/src/uart_tx.v
`timescale 1ns/1ps
module tb_audio;
    localparam integer HALF = 4, CPB = 8, N = 6016;           // 188 whole packets
    localparam real    CLK_NS = 13.468;
    localparam real    MAC_BIT = CPB * CLK_NS * 0.99;           // the Mac's bit time, 1 % short
    reg clk = 1'b0;
    always #6.734 clk = ~clk;                                   // 74.25 MHz
    reg rst = 1'b1;

    reg  mac_tx = 1'b1;
    wire fpga_tx, req, bclk, ws, din, pa_en, playing, trouble;
    wire signed [15:0] smp;
    audio_rx #(.CLK_PER_BIT(CPB), .HANG(200)) dut (.clk(clk), .rst(rst), .rx(mac_tx), .tx(fpga_tx),
        .req(req), .sample(smp), .pa_en(pa_en), .playing(playing), .trouble(trouble));
    i2s_tx #(.HALF(HALF)) u_i2s (.clk(clk), .rst(rst), .sample(smp), .req(req),
        .bclk(bclk), .ws(ws), .din(din));

    // ---- the Mac: sending ----
    task send_byte(input [7:0] v);
        integer i;
        begin
            mac_tx = 1'b0;  #(MAC_BIT);
            for (i = 0; i < 8; i = i + 1) begin mac_tx = v[i];  #(MAC_BIT); end
            mac_tx = 1'b1;  #(MAC_BIT);
        end
    endtask
    integer x [0:N-1];
    integer bad_pkt = -1, maxdelay = 150000;
    task send_packet(input [7:0] seq, input integer first, input integer corrupt);
        integer i, v;
        reg [15:0] sum;
        reg [7:0] b;
        begin
            send_byte(8'hB5);  send_byte(8'h6A);  send_byte(seq);
            sum = 0;
            for (i = 0; i < 32; i = i + 1) begin
                v = (seq == 8'd255) ? 0 : x[first + i];
                b = v[7:0];   sum = sum + b;  send_byte(b);
                b = v[15:8];  sum = sum + b;  send_byte((corrupt && i == 5) ? b ^ 8'h10 : b);
            end
            send_byte(sum[7:0]);  send_byte(sum[15:8]);
        end
    endtask

    // ---- the Mac: reading "R", "C", "S" + 4 ----
    integer credits_read = 0, got_r = 0, s_left = 0;
    integer credit = 0;                                         // samples the Mac may still send
    reg [7:0] rb;
    integer k;
    initial begin
        forever begin
            @(negedge fpga_tx);
            repeat (CPB + CPB / 2) @(posedge clk);
            for (k = 0; k < 8; k = k + 1) begin rb[k] = fpga_tx;  repeat (CPB) @(posedge clk); end
            if (s_left > 0) s_left = s_left - 1;
            else if (rb == "R") got_r = 1;
            else if (rb == "C") begin credit = credit + 256;  credits_read = credits_read + 1; end
            else if (rb == "S") s_left = 4;
        end
    end

    // ---- recording ----
    integer f, maxlevel = 0;
    reg bclk_q = 0;
    reg [8*256-1:0] fname, bname;
    always @(posedge clk) begin
        if (!bclk_q && bclk) $fwrite(f, "%0d", {pa_en, ws, din});
        bclk_q <= bclk;
        if (dut.level > maxlevel && dut.level < 12'd2049) maxlevel = dut.level;
    end

    // watchdog: a good run ends after about 7 million clocks
    initial begin
        #(40_000_000 * CLK_NS);
        $display("tb_audio: TIMEOUT (stuck)");
        $finish;
    end

    integer n, p, i, seed = 1;
    initial begin
        if (!$value$plusargs("out=%s", fname) || !$value$plusargs("bits=%s", bname)) begin
            $display("usage: +out=<file> +bits=<file>"); $finish;
        end
        if ($value$plusargs("bad=%d", bad_pkt)) ;
        if ($value$plusargs("maxdelay=%d", maxdelay)) ;
        if ($value$plusargs("seed=%d", seed)) ;
        for (i = 0; i < N; i = i + 1)
            x[i] = $rtoi(3000.0 * $sin(2.0 * 3.14159265358979 * i / 37.7)
                         + 700.0 * $sin(2.0 * 3.14159265358979 * i / 5.3) + 1000.5) - 1000 + 1;
        f = $fopen(bname, "w");
        repeat (20) @(posedge clk);
        rst <= 1'b0;
        repeat (100) @(posedge clk);
        send_packet(8'd255, 0, 0);                              // RESET
        wait (got_r);
        credit = 1536;
        n = 0;  p = 0;
        while (n < N) begin
            wait (credit >= 256 || N - n < 256 && credit >= N - n);
            repeat ($urandom(seed) % (maxdelay + 1)) @(posedge clk);
            seed = seed + 1;
            for (i = 0; i < 8 && n < N; i = i + 1) begin
                send_packet(p % 255, n, p == bad_pkt);
                n = n + 32;  p = p + 1;  credit = credit - 32;
            end
        end
        wait (!playing);
        repeat (64 * HALF * 300) @(posedge clk);
        $fclose(f);
        f = $fopen(fname, "w");
        $fwrite(f, "%0d %0d %0d %0d %0d %0d %0d %0d\n", N, bad_pkt, dut.n_bad, dut.n_gap, dut.n_drop,
                dut.n_und, maxlevel, credits_read);
        for (i = 0; i < N; i = i + 1) $fwrite(f, "%0d ", x[i]);
        $fwrite(f, "\n");
        $fclose(f);
        $display("tb_audio: %0d samples in %0d packets; counters bad %0d gap %0d drop %0d und %0d; max buffered %0d; credits %0d",
                 N, p, dut.n_bad, dut.n_gap, dut.n_drop, dut.n_und, maxlevel, credits_read);
        $finish;
    end
endmodule
