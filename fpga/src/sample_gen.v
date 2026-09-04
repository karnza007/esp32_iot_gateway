// sample_gen.v — a synthetic sample source, so the link can be filled.
//
// WHY THIS EXISTS
//   Every link-1 measurement so far ran at 95 kB/s down a link carrying 200 kB/s
//   or more -- about 7 % load. That proved the BITS survive at high baud rates. It
//   never asked whether link 1 loses data when it is actually FULL, which is how
//   link 2 turned out to fail: ~130 bytes vanishing every few seconds, at a rate
//   that did not depend on throughput.
//
//   Filling link 1 needs ~200 kB/s. One INMP441 produces 95 kB/s and two produce
//   190. There is no third microphone. So the load has to be generated.
//
// WHAT IT PRODUCES
//   `sample` is a plain 16-bit counter, incrementing once per `sample_valid`. That
//   makes the payload self-checking end to end: the host knows every sample must be
//   exactly one more than the last, ACROSS frame boundaries as well as within a
//   frame. It gives a third, independent loss measurement to set beside `seq` gaps
//   (whole frames) and `ovf` (bytes discarded inside the FPGA) -- and at a finer
//   granularity than either.
//
//   Everything downstream is untouched: same framer, same FIFO, same header, same
//   two checksums, same UART. Only where the samples come from changes.
//
// RATE
//   fs = SYS_CLK / GEN_DIV, so the offered rate is continuous -- no 3.2 MHz
//   microphone ceiling and no BCLK_DIV >= 17 constraint.
//
//   GEN_DIV should be a multiple of 64. The frame header has no spare bits, so the
//   rate is reported to the host through the existing BCLK_DIV field as GEN_DIV/64:
//   the host's fs = SYS_CLK / (64 * field) then works out to SYS_CLK / GEN_DIV
//   exactly, and the capture file stays self-describing without widening the frame.

module sample_gen #(
    parameter integer GEN_DIV = 3584          // 54 MHz / 3584 = 15,067 Hz (audio rate)
)(
    input  wire        clk,
    input  wire        rst_n,
    output reg  [15:0] sample,
    output reg         sample_valid
);
    localparam integer DW = $clog2(GEN_DIV);

    reg [DW-1:0] cnt = 0;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            cnt          <= 0;
            sample       <= 16'd0;
            sample_valid <= 1'b0;
        end else begin
            sample_valid <= 1'b0;
            if (cnt == GEN_DIV-1) begin
                cnt          <= 0;
                sample       <= sample + 1'b1;   // updated on the same edge as
                sample_valid <= 1'b1;            // sample_valid, so the framer
            end else begin                       // latches the new value
                cnt <= cnt + 1'b1;
            end
        end
    end
endmodule
