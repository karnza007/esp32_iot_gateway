// tb_mic_uart.v — top_mic_uart end to end: INMP441 model -> FPGA -> UART line -> bytes.
//
// The whole top file runs at 27 MHz. A UART decoder on pin 28 writes every received byte to
// +out=<file> (one hex byte per line); check_mic_uart.py then parses the frames with the
// viewer's own cfg functions and checks the samples (mic) or the 1 kHz peak (tone).
// This testbench itself checks the mic bit clock (BCLK_DIV clocks), the sample spacing (64 x BCLK_DIV
// clocks = 10,044.6 Hz) and, in mic mode, the health LEDs.
//   iverilog -g2012 -s tb_mic_uart -P tb_mic_uart.SRC=1 ... ; vvp ... +out=bytes.txt
`timescale 1ns/1ps
module tb_mic_uart #(
    parameter integer SRC    = 1,         // 0 = test tone, 1 = microphone
    parameter integer FRAMES = 3,         // whole frames to capture
    parameter integer RAW    = 0,         // 1 = start in raw-bits mode
    parameter integer RIGHT  = 0,         // 1 = the mic model talks in the right half (L/R high)
    parameter integer BCLK_DIV = 42       // must match the run: the checks below count it
);
    reg clk = 1'b0;
    always #18.5185 clk = ~clk;           // 27 MHz

    wire sck, ws, sd, line;
    wire [5:0] led;
    top_mic_uart #(.START_SRC(SRC), .WIN_BITS(16), .LED_EN(1), .START_RAW(RAW), .BCLK_DIV(BCLK_DIV)) dut (
        .clk(clk), .i2s_sck(sck), .i2s_ws(ws), .i2s_sd(sd),
        .uart_tx(line), .btn(2'b00), .led(led)
    );

    // INMP441 model (from fpga/sim/tb_chain.v): standard I2S, left slot, known words
    function [23:0] word(input integer n);
        case (n % 10)
            0: word = 24'hA5A5A5;  1: word = 24'h800000;  2: word = 24'h7FFFFF;
            3: word = 24'h123456;  4: word = 24'h000123;  5: word = 24'hFFFEDC;
            6: word = 24'h001000;  7: word = 24'hFFF000;  8: word = 24'h00007F;
            9: word = 24'h400000;
        endcase
    endfunction
    reg [31:0] shifter = 0, w32;  reg ws_s = 1'b1;  reg ws_d = 1'b1;  reg sd_r = 1'b0;  integer widx = 0;
    assign sd = sd_r;
    // timed like the real INMP441: reads WS on the rising SCK edge, changes SD on the falling
    // edge, MSB out on the first falling edge after it has seen WS change
    always @(posedge sck) ws_s <= ws;
    always @(negedge sck) begin
        if (ws_s !== ws_d) begin
            ws_d <= ws_s;
            if (ws_s == RIGHT[0]) begin w32 = {word(widx), 8'h00}; sd_r <= w32[31]; shifter <= {w32[30:0], 1'b0}; widx = widx + 1; end
            else begin sd_r <= 1'b0; shifter <= 32'd0; end
        end else begin
            sd_r <= shifter[31];
            shifter <= {shifter[30:0], 1'b0};
        end
    end

    // bit clock and sample spacing, counted in 27 MHz clocks
    integer t_now = 0, t_sck = -1, t_smp = -1, sck_bad = 0, smp_bad = 0, nsmp = 0;
    always @(posedge clk) t_now = t_now + 1;
    always @(posedge sck) begin
        if (nsmp > 0 && t_now - t_sck != BCLK_DIV) sck_bad = sck_bad + 1;   // after start-up
        t_sck = t_now;
    end
    always @(posedge clk) if (dut.mic_valid) begin
        if (t_smp >= 0 && t_now - t_smp != 64 * BCLK_DIV) smp_bad = smp_bad + 1;
        t_smp = t_now;  nsmp = nsmp + 1;
    end

    // UART decoder, 1 Mbaud: 1000 ns per bit
    integer f, nbytes = 0, k;
    reg [7:0] b;
    reg [8*256-1:0] fname;
    initial begin
        if (!$value$plusargs("out=%s", fname)) begin $display("usage: +out=<file>"); $finish; end
        f = $fopen(fname, "w");
        forever begin
            @(negedge line);
            #500;
            if (line === 1'b0) begin
                for (k = 0; k < 8; k = k + 1) begin #1000; b[k] = line; end
                #1000;
                $fwrite(f, "%02x\n", b);
                nbytes = nbytes + 1;
            end
        end
    end

    // run until FRAMES whole frames (1038 bytes each) plus a margin are out
    initial begin
        wait (nbytes >= (FRAMES + 1) * 1038 + 20);
        $display("tb_mic_uart: src=%0s  %0d bytes  %0d samples  SCK period errors %0d (want %0d clocks)  sample gap errors %0d (want %0d)",
                 SRC ? "mic" : "tone", nbytes, nsmp, sck_bad, BCLK_DIV, smp_bad, 64 * BCLK_DIV);
        if (SRC && !RAW && !RIGHT)
            $display("tb_mic_uart: LEDs mic=%0d alive=%0d stuck_low=%0d stuck_high=%0d (want 1 1 0 0)",
                     !led[0], !led[1], !led[2], !led[3]);
        $fclose(f);
        $finish;
    end
endmodule
