// tb_sweep.v — sweep_player check: button presses in, I2S wires out, as the amplifier sees them.
//
// The testbench presses "toggle" at chosen sample frames (a frame = one sample = 64 x HALF
// clocks, counted from reset) and writes:
//   line 1: N_SWEEP N_QUIET, then the frames it pressed at;
//   line 2: one character per rising edge of BCLK (when the MAX98357A reads): '0' + {pa_en, ws, din}.
// check_sweep.py decodes the I2S words from line 2 alone and compares every sample with its own
// model of the player driven by the presses of line 1. The testbench itself checks:
//   - WS and DIN change only in the clock where BCLK falls;
//   - the BCLK period (2 x HALF clocks).
// Schedules (HALF = 1 so a sample takes 64 clocks, not 1536; the player counts in samples):
//   default  N_SWEEP 3000, N_QUIET 100: on -> 2.5 legs (up, down, half up) -> off (fade out) ->
//            on, cancelled in the 20 ms quiet -> on -> off during the fade in -> on again during
//            the fade out (turns round) -> off
//   +long    the real N_SWEEP 193359 / N_QUIET 967: on -> one whole up-and-down + a bit -> off
//   +short   HALF 24 (run with -P tb_sweep.HALF=24): the real bit clock over a few frames
//   iverilog -g2012 -s tb_sweep -o sw.vvp sim/tb_sweep.v src/hdmi/sweep_player.v src/hdmi/rom_sine.v
//   vvp sw.vvp +out=sweep.txt ; python sim/check_sweep.py sweep.txt
`timescale 1ns/1ps
module tb_sweep;
    parameter integer HALF = 1;
    parameter integer LONG = 0;                   // also selectable with +long
    reg clk = 1'b0;
    always #6.734 clk = ~clk;                     // 74.25 MHz
    reg rst = 1'b1, toggle = 1'b0;
    wire bclk, ws, din, pa_en, playing;
    reg  long_run = 0, short = 0;
    // two players, one per schedule length; only the selected one is recorded
    wire b0, w0, d0, p0, b1, w1, d1, p1, pl0, pl1;
    sweep_player #(.HALF(HALF), .N_SWEEP(3000), .N_QUIET(100)) dut_s (.clk(clk), .rst(rst),
        .toggle(toggle && !long_run), .bclk(b0), .ws(w0), .din(d0), .pa_en(p0), .playing(pl0));
    sweep_player #(.HALF(HALF)) dut_l (.clk(clk), .rst(rst),
        .toggle(toggle && long_run), .bclk(b1), .ws(w1), .din(d1), .pa_en(p1), .playing(pl1));
    assign {bclk, ws, din, pa_en, playing} = long_run ? {b1, w1, d1, p1, pl1} : {b0, w0, d0, p0, pl0};

    integer f, bad = 0, rises = 0, last_rise = 0, period_bad = 0, t = 0, frame = -1, i, idx = 0;
    integer sched [0:15];
    integer nsched = 0, n_sweep, n_quiet;
    reg bclk_q = 0, ws_q = 0, din_q = 0;
    reg [8*256-1:0] fname;
    wire frame_start = long_run ? (dut_l.cnt == 0) : (dut_s.cnt == 0);
    // frames are counted at clock 0 of each; a press is one clock long, at clock 1 of its frame
    // (the player acts on it at clock 8 of the same frame)
    always @(posedge clk) begin
        t = t + 1;
        toggle <= 1'b0;
        if (!rst && frame_start) begin
            frame = frame + 1;
            if (idx < nsched && frame == sched[idx]) begin toggle <= 1'b1;  idx = idx + 1; end
        end
        if ((ws !== ws_q || din !== din_q) && !(bclk_q && !bclk)) bad = bad + 1;
        if (!bclk_q && bclk) begin                // BCLK rising: the amplifier reads here
            if (rises > 1 && t - last_rise != 2 * HALF) period_bad = period_bad + 1;
            last_rise = t;  rises = rises + 1;
            if (!short) $fwrite(f, "%0d", {pa_en, ws, din});
        end
        bclk_q <= bclk;  ws_q <= ws;  din_q <= din;
    end
    initial begin
        short    = $test$plusargs("short");
        long_run = $test$plusargs("long") || LONG;
        if (long_run) begin
            n_sweep = 193359;  n_quiet = 967;  nsched = 2;
            sched[0] = 50;  sched[1] = 50 + 967 + 2 * 193359 + 20000;
        end else begin
            n_sweep = 3000;  n_quiet = 100;  nsched = 8;
            sched[0] = 50;      sched[1] = 50 + 100 + 7500;             // on; off in the 3rd leg
            sched[2] = 9000;    sched[3] = 9050;                        // on; cancelled in the quiet
            sched[4] = 9500;    sched[5] = 9500 + 100 + 300;            // on; off during the fade in
            sched[6] = 9500 + 100 + 300 + 150;                          // on again during the fade out
            sched[7] = 9500 + 100 + 300 + 150 + 4000;                   // off
        end
        if (!short && !$value$plusargs("out=%s", fname)) begin $display("usage: +out=<file>"); $finish; end
        if (!short) begin
            f = $fopen(fname, "w");
            $fwrite(f, "%0d %0d", n_sweep, n_quiet);
            for (i = 0; i < nsched; i = i + 1) $fwrite(f, " %0d", sched[i]);
            $fwrite(f, "\n");
        end
        repeat (10) @(posedge clk);
        rst <= 1'b0;
        if (short) begin
            repeat (64 * HALF * 8) @(posedge clk);
            $display("tb_sweep (HALF %0d): %0d bit clocks, period %0d clocks = %.3f MHz, %0d wrong periods, %0d changes off the falling edge; frame %0d clocks = %.1f Hz",
                     HALF, rises, 2 * HALF, 74.25 / (2 * HALF), period_bad, bad, 64 * HALF, 74.25e6 / (64 * HALF));
            $finish;
        end
        wait (idx == nsched);
        repeat (64 * HALF * 2) @(posedge clk);
        wait (!pa_en);
        repeat (64 * HALF * (n_quiet + 600)) @(posedge clk);
        $fclose(f);
        $display("tb_sweep (HALF %0d, %0s): %0d frames, %0d bit clocks, %0d wrong periods, %0d changes off the falling edge",
                 HALF, long_run ? "long" : "short schedule", frame, rises, period_bad, bad);
        $finish;
    end
endmodule
