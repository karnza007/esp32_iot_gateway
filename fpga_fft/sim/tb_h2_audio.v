// tb_h2_audio.v — H2 check, audio side: tone -> gain/clamp/window -> FFT -> bar heights.
//
// The FFT is Gowin's gate-level model (fft_1024.vo + prim_sim.v), as in tb_fft.v. To keep
// the run short, a sample comes every 16 clocks instead of 1536; frequencies are set as
// phase steps per sample, so the spectrum is the same. Tone 1 is fixed exactly on bin 200
// (no sweep), tone 2 is the usual 1 kHz at -40 dB.
// Dumps (for check_h2.py): every input sample, the windowed block the 2nd FFT used, that
// FFT's 1024 outputs, and the 512 bar heights it produced.
`timescale 1ns/1ps
module tb_h2_audio;
    reg clk = 1'b0;
    always #6.734 clk = ~clk;                     // 74.25 MHz
    reg rst = 1'b1;
    GSR GSR (.GSRI(1'b1));

    wire signed [15:0] s;
    wire               s_valid;
    tone_gen #(.SAMPLE_DIV(16), .INC1_START(32'd838860800), .SWEEP_STEP(32'd0)) u_tone (
        .clk(clk), .rst(rst), .valid(s_valid), .sample(s));

    wire       bar_we, bar_done, overrun;
    wire [8:0] bar_addr;
    wire [9:0] bar_h;
    spectrum #(.GAIN_SHIFT(0), .CLAMP(32700)) u_spec (
        .clk(clk), .rst(rst), .s_valid(s_valid), .s_in(s),
        .bar_we(bar_we), .bar_addr(bar_addr), .bar_h(bar_h), .bar_done(bar_done),
        .overrun(overrun));

    integer fs, fw, fx, fb, nblk = 0, nfft = 0, k;
    reg done = 1'b0;                              // stops the loggers once the files are closed
    reg [8*256-1:0] dir;
    always @(posedge clk) if (s_valid && !done) $fwrite(fs, "%0d\n", s);
    always @(posedge clk) if (u_spec.fft_start) begin
        nfft = nfft + 1;
        if (nfft == 2)
            for (k = 0; k < 1024; k = k + 1)
                $fwrite(fw, "%0d\n", $signed(u_spec.buf_mem[{u_spec.ready_bank, k[9:0]}]));
    end
    always @(posedge clk) if (nfft == 2 && u_spec.opd && !done)
        $fwrite(fx, "%0d %0d %0d\n", u_spec.idx, $signed(u_spec.xk_re), $signed(u_spec.xk_im));
    always @(posedge clk) if (nblk == 1 && bar_we) $fwrite(fb, "%0d %0d\n", bar_addr, bar_h);
    always @(posedge clk) if (bar_done) nblk = nblk + 1;
    // stop after the 2nd FFT's LAST output (bins 512-1023 come after the heights are done)
    always @(posedge clk) if (nfft == 2 && u_spec.eoud) begin
        repeat (8) @(posedge clk);
        done = 1'b1;
        $display("tb_h2_audio: 2 blocks done, overrun=%b", overrun);
        $fclose(fs); $fclose(fw); $fclose(fx); $fclose(fb);
        $finish;
    end

    initial begin
        if (!$value$plusargs("dir=%s", dir)) begin $display("usage: +dir=<folder>"); $finish; end
        fs = $fopen({dir, "/samples.txt"}, "w");
        fw = $fopen({dir, "/windowed.txt"}, "w");
        fx = $fopen({dir, "/fft.txt"}, "w");
        fb = $fopen({dir, "/bars.txt"}, "w");
        repeat (20) @(posedge clk);
        #1 rst = 1'b0;
        #20_000_000 $display("TIMEOUT"); $finish;
    end
endmodule
