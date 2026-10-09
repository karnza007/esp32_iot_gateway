// tb_h3_relay.v — H3 check, ESP32 relay path: UART packets -> relay_rx -> 24-bit samples.
//
// Packets are sent at the baud the ESP32 actually produces (80 MHz / 26.9375 = 2,969,838,
// 0.005 % below the FPGA's 2.97 M). Sequence:
//   3 good packets, 1 with one payload byte corrupted, 1 good, 1 that stops halfway and
//   stays silent for 1.2 ms, 2 good.
// Pass: exactly the samples of the 6 good packets come out, in order, and the counts of
// good/bad packets are 6/1 (the half packet is abandoned, not counted).
`timescale 1ns/1ps
module tb_h3_relay;
    reg clk = 1'b0;
    always #6.734 clk = ~clk;                      // 74.25 MHz
    reg rst = 1'b1, line = 1'b1;
    wire        valid, pkt_ok, pkt_bad;
    wire [23:0] word;
    relay_rx dut (.clk(clk), .rst(rst), .rx(line), .valid(valid), .word(word),
                  .pkt_ok(pkt_ok), .pkt_bad(pkt_bad));

    localparam real BIT = 1.0e9 / 2969838.0;       // ns per bit, as the ESP32 sends it
    task send_byte(input [7:0] v);
        integer i;
        begin
            line = 1'b0; #(BIT);
            for (i = 0; i < 8; i = i + 1) begin line = v[i]; #(BIT); end
            line = 1'b1; #(BIT);
        end
    endtask

    function [23:0] sample(input integer p, input integer i);   // a varied, signed pattern
        sample = (p * 32 + i) * 24'h03A5F1 ^ (i[0] ? 24'h800000 : 24'h000000);
    endfunction

    reg [23:0] expq [0:1023];
    integer nexp = 0, nget = 0, nbad_words = 0, nok = 0, nbad = 0;
    always @(posedge clk) begin
        if (pkt_ok) nok = nok + 1;
        if (pkt_bad) nbad = nbad + 1;
        if (valid) begin
            if (nget >= nexp || word !== expq[nget]) begin
                nbad_words = nbad_words + 1;
                if (nbad_words <= 3) $display("  word %0d: got %06h, expected %06h", nget, word, expq[nget]);
            end
            nget = nget + 1;
        end
    end

    task send_packet(input integer p, input integer corrupt, input integer stop_after);
        integer i, k;
        reg [15:0] s;
        reg [23:0] w;
        begin
            s = 0;
            send_byte(8'hB5); send_byte(8'h6A); send_byte(p[7:0]);
            for (i = 0; i < 32; i = i + 1) begin
                w = sample(p, i);
                for (k = 0; k < 3; k = k + 1) begin
                    s = s + w[8*k +: 8];
                    if (stop_after >= 0 && 3 * i + k == stop_after) disable send_packet;
                    send_byte((corrupt && i == 5 && k == 1) ? w[8*k +: 8] ^ 8'h10 : w[8*k +: 8]);
                end
                if (!corrupt) begin expq[nexp] = w; nexp = nexp + 1; end
            end
            send_byte(s[7:0]); send_byte(s[15:8]);
        end
    endtask

    integer q;
    initial begin
        repeat (10) @(posedge clk);
        #1 rst = 1'b0;
        #2000;
        for (q = 0; q < 3; q = q + 1) send_packet(q, 0, -1);
        send_packet(3, 1, -1);                      // corrupted byte -> dropped
        send_packet(4, 0, -1);
        nexp = nexp;                                // the half packet adds nothing:
        begin : half
            integer save;
            save = nexp;
            send_packet(5, 0, 40);                  // stops after 40 payload bytes
            nexp = save;                            // its first samples were queued: undo
        end
        #1_200_000;                                 // 1.2 ms of silence: abandoned
        send_packet(6, 0, -1);
        send_packet(7, 0, -1);
        #20000;
        $display("tb_h3_relay: %0d samples out, %0d expected, %0d wrong; good packets %0d (want 6), bad %0d (want 1)",
                 nget, nexp, nbad_words, nok, nbad);
        if (nget == nexp && nbad_words == 0 && nok == 6 && nbad == 1) $display("tb_h3_relay: PASS");
        else $display("tb_h3_relay: FAIL");
        $finish;
    end
endmodule
