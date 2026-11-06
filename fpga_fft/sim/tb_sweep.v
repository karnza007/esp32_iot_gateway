// tb_sweep.v — sweep_player check: one press, the whole sweep, as the amplifier would see it.
//
// At every rising edge of BCLK (when the MAX98357A reads) the testbench writes one character,
// '0' + {pa_en, ws, din}, to +out=<file>; check_sweep.py decodes the I2S words from that alone
// and compares every sample with its own model of the sweep. The testbench itself checks:
//   - WS and DIN change only in the clock where BCLK falls;
//   - the BCLK period (2 x HALF clocks) and the frame (32 bit clocks).
// HALF = 1 (the default here) runs the whole 4 s sweep at 64 clocks per sample instead of 1536;
// the sequence is counted in samples, so it is the same sweep. Run once with -P tb_sweep.HALF=24
// and +short to check the real bit clock (1.547 MHz) over a few frames.
//   iverilog -g2012 -s tb_sweep -o sw.vvp sim/tb_sweep.v src/hdmi/sweep_player.v src/hdmi/rom_sine.v
//   vvp sw.vvp +out=sweep.txt ; python sim/check_sweep.py sweep.txt
`timescale 1ns/1ps
module tb_sweep;
    parameter integer HALF = 1;
    reg clk = 1'b0;
    always #6.734 clk = ~clk;                     // 74.25 MHz
    reg rst = 1'b1, start = 1'b0;
    wire bclk, ws, din, pa_en, playing;
    sweep_player #(.HALF(HALF)) dut (.clk(clk), .rst(rst), .start(start), .bclk(bclk), .ws(ws),
                                      .din(din), .pa_en(pa_en), .playing(playing));

    integer f, bad = 0, rises = 0, last_rise = 0, period = 0, period_bad = 0, t = 0;
    reg bclk_q = 0, ws_q = 0, din_q = 0, pa_seen = 0, short = 0;
    reg [8*256-1:0] fname;
    always @(posedge clk) begin
        t = t + 1;
        // WS / DIN may only change together with BCLK falling
        if ((ws !== ws_q || din !== din_q) && !(bclk_q && !bclk)) bad = bad + 1;
        if (!bclk_q && bclk) begin                // BCLK rising: the amplifier reads here
            if (rises > 1 && t - last_rise != 2 * HALF) period_bad = period_bad + 1;
            last_rise = t;  rises = rises + 1;
            if (!short) $fwrite(f, "%0d", {pa_en, ws, din});
        end
        bclk_q <= bclk;  ws_q <= ws;  din_q <= din;
        if (pa_en) pa_seen <= 1'b1;
    end
    initial begin
        short = $test$plusargs("short");
        if (!short && !$value$plusargs("out=%s", fname)) begin $display("usage: +out=<file>"); $finish; end
        if (!short) f = $fopen(fname, "w");
        repeat (10) @(posedge clk);
        rst <= 1'b0;
        repeat (64 * HALF * 5 + 3) @(posedge clk);
        start <= 1'b1;  @(posedge clk);  start <= 1'b0;
        if (short) begin
            repeat (64 * HALF * 8) @(posedge clk);
            $display("tb_sweep (HALF %0d): %0d bit clocks, period %0d clocks = %.3f MHz, %0d wrong periods, %0d changes off the falling edge; frame %0d clocks = %.1f Hz",
                     HALF, rises, 2 * HALF, 74.25 / (2 * HALF), period_bad, bad, 64 * HALF, 74.25e6 / (64 * HALF));
            $finish;
        end
        wait (pa_seen);  wait (!pa_en);
        repeat (64 * HALF * 4) @(posedge clk);
        $fclose(f);
        $display("tb_sweep (HALF %0d): %0d bit clocks, %0d wrong periods, %0d changes off the falling edge",
                 HALF, rises, period_bad, bad);
        $finish;
    end
endmodule
