// uart_rx.v — 8N1 UART receiver
//
//   baud = clk / CLK_PER_BIT.  At 27 MHz, CLK_PER_BIT = 27 -> 1,000,000 baud exactly.
//
// HOW IT READS A BYTE
//   The line idles high. A falling edge is a possible start bit: wait half a bit to
//   reach its middle and check it is still low (a short glitch is ignored). From
//   there every full bit period lands in the middle of the next bit, which is
//   where the signal is most stable: 8 data bits (LSB first), then the stop bit,
//   which must be high or the byte is reported as a framing error.
//
//      ‾‾‾‾\____/‾‾‾‾\____/ ... ‾‾‾‾‾‾‾‾
//       idle start  d0    d1      stop
//               ^     ^     ^       ^      sample points (middle of each bit)
//
// The rx pin comes from another board with its own clock, so it passes through
// two flip-flops first (a synchroniser) before any logic looks at it.

module uart_rx #(
    parameter integer CLK_PER_BIT = 27
)(
    input  wire       clk,
    input  wire       rst_n,
    input  wire       rx,          // serial line (idle high)
    output reg  [7:0] rx_data,     // received byte, valid while rx_valid is high
    output reg        rx_valid,    // one-clock pulse per good byte
    output reg        frame_err    // one-clock pulse: stop bit was low (byte dropped)
);
    localparam integer TW   = $clog2(CLK_PER_BIT);
    localparam integer HALF = CLK_PER_BIT / 2;

    reg rx_s1 = 1'b1, rx_s2 = 1'b1;                  // synchroniser
    always @(posedge clk) begin
        rx_s1 <= rx;
        rx_s2 <= rx_s1;
    end

    localparam [1:0] IDLE = 2'd0, START = 2'd1, DATA = 2'd2, STOP = 2'd3;
    reg [1:0]    state = IDLE;
    reg [TW-1:0] tcnt  = 0;
    reg [2:0]    bidx  = 3'd0;
    reg [7:0]    shift = 8'd0;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            state     <= IDLE;
            tcnt      <= 0;
            bidx      <= 3'd0;
            rx_valid  <= 1'b0;
            frame_err <= 1'b0;
        end else begin
            rx_valid  <= 1'b0;
            frame_err <= 1'b0;
            case (state)
                IDLE:
                    if (!rx_s2) begin
                        tcnt  <= 0;
                        state <= START;
                    end
                START:                                     // to the middle of the start bit
                    if (tcnt == HALF - 1) begin
                        tcnt  <= 0;
                        bidx  <= 3'd0;
                        state <= rx_s2 ? IDLE : DATA;      // high again = glitch, not a start
                    end else tcnt <= tcnt + 1'b1;
                DATA:
                    if (tcnt == CLK_PER_BIT - 1) begin
                        tcnt  <= 0;
                        shift <= {rx_s2, shift[7:1]};      // LSB arrives first
                        if (bidx == 3'd7) state <= STOP;
                        else              bidx  <= bidx + 1'b1;
                    end else tcnt <= tcnt + 1'b1;
                STOP:
                    if (tcnt == CLK_PER_BIT - 1) begin
                        tcnt  <= 0;
                        state <= IDLE;                     // half a bit early: room for the next start
                        if (rx_s2) begin
                            rx_data  <= shift;
                            rx_valid <= 1'b1;
                        end else frame_err <= 1'b1;
                    end else tcnt <= tcnt + 1'b1;
            endcase
        end
    end
endmodule
