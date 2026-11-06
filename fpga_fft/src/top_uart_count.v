// top_uart_count.v — one-way speed test for the Tang Nano 20K's USB serial port (BL616):
// Mac -> FPGA only. The Mac sends the bytes 0, 1, 2, ... 255, 0, 1, ... on pin 70; the FPGA
// checks each one against the one it expects, so nothing has to travel back while the test runs.
// When the line has been quiet for 100 ms, the FPGA sends a 12-byte report on pin 69:
//   "RPT" | 0x00 | bytes received (32-bit LE) | bytes out of sequence (32-bit LE)
// and starts counting again. (A lost byte shows as one break in the sequence; a garbled byte as
// two; framing errors from uart_rx are counted as out of sequence too.)
//   27 MHz / CLK_PER_BIT: 27 -> 1 Mbaud, 18 -> 1.5 Mbaud, 9 -> 3 Mbaud.
//   DESIGN=count fpga_fft/build.sh     (load into SRAM only)
module top_uart_count #(
    parameter integer CLK_PER_BIT = 9
)(
    input  wire clk,          // 27 MHz crystal
    input  wire uart_rx,      // pin 70: from the Mac
    output wire uart_tx,      // pin 69: to the Mac
    output wire led0
);
    wire [7:0] d;
    wire       v, ferr;
    uart_rx #(.CLK_PER_BIT(CLK_PER_BIT)) u_rx (.clk(clk), .rst_n(1'b1), .rx(uart_rx),
                                              .rx_data(d), .rx_valid(v), .frame_err(ferr));
    reg [31:0] nbytes = 0, nbad = 0;
    reg [7:0]  expect = 0;
    reg [21:0] quiet = 0;                         // 2^21 clocks at 27 MHz = 78 ms
    reg        report = 1'b0;
    reg [3:0]  ri = 0;
    reg [95:0] rbuf = 0;
    reg  [7:0] txd = 0;
    reg        txv = 1'b0;
    wire       txr;
    uart_tx #(.CLK_PER_BIT(CLK_PER_BIT)) u_tx (.clk(clk), .rst_n(1'b1), .tx_data(txd), .tx_valid(txv),
                                              .tx_ready(txr), .tx(uart_tx));
    always @(posedge clk) begin
        txv <= 1'b0;
        if (v) begin
            nbytes <= nbytes + 1'b1;
            if (d != expect) nbad <= nbad + 1'b1;
            expect <= d + 1'b1;
            quiet  <= 0;
        end else if (ferr) begin
            nbad  <= nbad + 1'b1;
            quiet <= 0;
        end else if (!quiet[21]) quiet <= quiet + 1'b1;
        if (!report && quiet[21] && nbytes != 0) begin           // quiet: send the report
            rbuf   <= {nbad[31:24], nbad[23:16], nbad[15:8], nbad[7:0],
                       nbytes[31:24], nbytes[23:16], nbytes[15:8], nbytes[7:0],
                       8'h00, "T", "P", "R"};
            report <= 1'b1;  ri <= 0;
            nbytes <= 0;  nbad <= 0;  expect <= 0;
        end
        if (report && txr && !txv) begin
            txd  <= rbuf[7:0];  txv <= 1'b1;
            rbuf <= rbuf >> 8;  ri  <= ri + 1'b1;
            if (ri == 4'd11) report <= 1'b0;
        end
    end
    assign led0 = !v;
endmodule
