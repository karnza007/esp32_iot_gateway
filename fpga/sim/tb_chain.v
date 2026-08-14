// tb_chain.v — full datapath: I2S mic model -> i2s_master_rx -> framer -> uart_tx
//               -> UART decoder -> frame parser.
//
// This is the regression test that catches integration mistakes the per-module
// tests cannot: I2S bit alignment, byte order, and the frame layout all have to
// agree end to end before anything is programmed onto hardware.
//
//   iverilog -g2012 -o /tmp/tb_chain fpga/sim/tb_chain.v \
//            fpga/src/i2s_master_rx.v fpga/src/framer.v fpga/src/uart_tx.v
//   vvp /tmp/tb_chain
//
// The microphone model is a standard Philips I2S transmitter: it changes SD on
// the FALLING edge of SCK and delays the MSB by one bit clock after the WS edge.
// That one-clock delay is exactly what makes CAP_START = 2 the right capture
// phase, so this test also pins down that constant.

`timescale 1ns/1ps
module tb_chain #(
    // overridable so the whole sweep can be simulated:
    //   iverilog -Ptb_chain.BCLK_DIV=8 ...
    parameter integer BCLK_DIV = 25            // -> 960 kHz BCLK, 15 kHz fs
);

    localparam integer CLK_PER_BIT  = 12;      // -> 2 Mbaud
    localparam integer FRAME_SAMPLES = 8;      // 8 not 512, purely for run time
    localparam integer FRAME_BYTES  = 10 + 2*FRAME_SAMPLES + 2;
    localparam [15:0]  CFG          = {6'd0, 2'd1, BCLK_DIV[7:0]};

    localparam real    CLK_HALF  = 20.8333;                    // 24 MHz
    localparam real    BIT_TIME  = 2.0*CLK_HALF*CLK_PER_BIT;   // 500 ns @ 2 Mbaud

    reg clk = 0, rst_n = 0;
    always #CLK_HALF clk = ~clk;

    wire i2s_sck, i2s_ws, i2s_sd;
    wire [15:0] sample;
    wire        sample_valid;
    wire [7:0]  tx_data;
    wire        tx_valid, tx_ready;
    wire        uart_line;

    i2s_master_rx #(.BCLK_DIV(BCLK_DIV), .CAP_START(2)) u_i2s (
        .clk(clk), .rst_n(rst_n),
        .i2s_sck(i2s_sck), .i2s_ws(i2s_ws), .i2s_sd(i2s_sd),
        .sample(sample), .sample_valid(sample_valid)
    );

    framer #(.FIFO_DEPTH(64), .FRAME_SAMPLES(FRAME_SAMPLES)) u_framer (
        .clk(clk), .rst_n(rst_n),
        .sample(sample), .sample_valid(sample_valid),
        .cfg(CFG),
        .tx_data(tx_data), .tx_valid(tx_valid), .tx_ready(tx_ready),
        .ovf_count(), .seq_count()
    );

    uart_tx #(.CLK_PER_BIT(CLK_PER_BIT)) u_uart (
        .clk(clk), .rst_n(rst_n),
        .tx_data(tx_data), .tx_valid(tx_valid), .tx_ready(tx_ready),
        .tx(uart_line)
    );

    // ------------------------------------------------------------------
    // INMP441 model — standard I2S transmitter on the left slot
    // ------------------------------------------------------------------
    function [23:0] mic_pattern(input integer n);
        case (n % 4)
            0: mic_pattern = 24'hA5A5A5;   // -> sample A5A5
            1: mic_pattern = 24'h800000;   // -> sample 8000 (negative full scale)
            2: mic_pattern = 24'h7FFFFF;   // -> sample 7FFF (positive full scale)
            3: mic_pattern = 24'h123456;   // -> sample 1234
        endcase
    endfunction

    reg [31:0] shifter = 32'd0;
    reg        ws_d    = 1'b1;
    reg        sd_r    = 1'b0;
    integer    widx    = 0;
    assign i2s_sd = sd_r;

    always @(negedge i2s_sck) begin
        if (i2s_ws !== ws_d) begin
            ws_d <= i2s_ws;
            if (i2s_ws == 1'b0) begin              // left slot begins
                shifter <= {mic_pattern(widx), 8'h00};
                widx     = widx + 1;
            end else begin
                shifter <= 32'd0;                  // right channel: silence
            end
            sd_r <= 1'b0;                          // the one-BCLK I2S delay
        end else begin
            sd_r    <= shifter[31];
            shifter <= {shifter[30:0], 1'b0};
        end
    end

    // ------------------------------------------------------------------
    // UART receiver — re-arms only during the stop bit, so a data bit that
    // happens to look like a start bit cannot trigger a false frame.
    // ------------------------------------------------------------------
    reg [7:0] rx [0:2047];
    integer   rxn = 0;
    reg [7:0] b;
    integer   bk;

    initial begin
        forever begin
            @(negedge uart_line);
            #(BIT_TIME/2.0);                       // centre of the start bit
            if (uart_line === 1'b0) begin
                for (bk = 0; bk < 8; bk = bk + 1) begin
                    #(BIT_TIME);
                    b[bk] = uart_line;             // LSB first
                end
                #(BIT_TIME);                       // ride out the stop bit
                rx[rxn] = b;
                rxn     = rxn + 1;
            end
        end
    end

    // ------------------------------------------------------------------
    integer errors = 0;
    integer p, q, sum, base, s, fseq;
    reg [15:0] want, gotw;

    task check16(input [127:0] name, input [15:0] a, input [15:0] e);
        begin
            if (a !== e) begin
                $display("  FAIL %0s: got %04h expected %04h", name, a, e);
                errors = errors + 1;
            end
        end
    endtask

    initial begin
        repeat (10) @(posedge clk);
        rst_n = 1'b1;

        // let several complete frames go out
        #(4.0 * FRAME_SAMPLES * 64 * BCLK_DIV * 2.0 * CLK_HALF);

        $display("tb_chain: decoded %0d UART bytes", rxn);
        if (rxn < 2*FRAME_BYTES) begin
            $display("  FAIL: too few bytes decoded");
            errors = errors + 1;
        end

        // find the first checksum-valid frame
        base = -1;
        for (p = 0; p <= rxn - FRAME_BYTES; p = p + 1) begin
            if (base == -1 && rx[p]==8'hAA && rx[p+1]==8'h55 &&
                              rx[p+2]==8'hA5 && rx[p+3]==8'h5A) begin
                sum = 0;
                for (q = 0; q < 2*FRAME_SAMPLES; q = q + 1)
                    sum = (sum + rx[p+10+q]) % 65536;
                want = {rx[p+FRAME_BYTES-1], rx[p+FRAME_BYTES-2]};
                if (want == sum[15:0]) base = p;
            end
        end

        if (base < 0) begin
            $display("  FAIL: no checksum-valid frame found");
            errors = errors + 1;
        end else begin
            fseq = {rx[base+5], rx[base+4]};
            $display("  frame at byte %0d, seq %0d", base, fseq);
            check16("cfg", {rx[base+9], rx[base+8]}, CFG);
            check16("ovf", {rx[base+7], rx[base+6]}, 16'd0);

            // payload must be the top 16 bits of the mic words for this frame
            for (s = 0; s < FRAME_SAMPLES; s = s + 1) begin
                gotw = {rx[base+10+2*s+1], rx[base+10+2*s]};
                want = mic_pattern(fseq*FRAME_SAMPLES + s) >> 8;
                if (gotw !== want) begin
                    $display("  FAIL sample %0d: got %04h expected %04h", s, gotw, want);
                    errors = errors + 1;
                end
            end
            if (errors == 0)
                $display("  payload matches the mic model exactly (CAP_START=2 confirmed)");
        end

        $display("");
        if (errors == 0) $display("tb_chain: PASS");
        else             $display("tb_chain: FAIL (%0d errors)", errors);
        $finish;
    end
endmodule
