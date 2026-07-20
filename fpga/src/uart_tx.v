// uart_tx.v — simple 8N1 UART transmitter
// At 24 MHz with CLK_PER_BIT=12 -> 2,000,000 baud (exact).
module uart_tx #(
    parameter integer CLK_PER_BIT = 12
)(
    input  wire       clk,
    input  wire       rst_n,
    input  wire [7:0] tx_data,    // byte to send (sampled when tx_valid & tx_ready)
    input  wire       tx_valid,   // assert for one accepted handshake
    output reg        tx_ready,   // high when idle (can accept a byte)
    output reg        tx          // serial line (idle high)
);
    localparam [1:0] IDLE = 2'd0, START = 2'd1, DATA = 2'd2, STOP = 2'd3;
    reg [1:0] state = IDLE;
    reg [3:0] tcnt  = 4'd0;       // bit timer 0..CLK_PER_BIT-1
    reg [2:0] bidx  = 3'd0;       // data bit index 0..7
    reg [7:0] data  = 8'd0;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            state    <= IDLE;
            tx       <= 1'b1;
            tx_ready <= 1'b1;
            tcnt     <= 4'd0;
            bidx     <= 3'd0;
            data     <= 8'd0;
        end else begin
            case (state)
                IDLE: begin
                    tx       <= 1'b1;
                    tx_ready <= 1'b1;
                    if (tx_valid) begin
                        data     <= tx_data;
                        tx_ready <= 1'b0;
                        tcnt     <= 4'd0;
                        state    <= START;
                    end
                end
                START: begin
                    tx <= 1'b0;                       // start bit
                    if (tcnt == CLK_PER_BIT-1) begin
                        tcnt  <= 4'd0;
                        bidx  <= 3'd0;
                        state <= DATA;
                    end else tcnt <= tcnt + 1'b1;
                end
                DATA: begin
                    tx <= data[bidx];                 // LSB-first
                    if (tcnt == CLK_PER_BIT-1) begin
                        tcnt <= 4'd0;
                        if (bidx == 3'd7) state <= STOP;
                        else              bidx  <= bidx + 1'b1;
                    end else tcnt <= tcnt + 1'b1;
                end
                STOP: begin
                    tx <= 1'b1;                        // stop bit
                    if (tcnt == CLK_PER_BIT-1) begin
                        tcnt     <= 4'd0;
                        tx_ready <= 1'b1;
                        state    <= IDLE;
                    end else tcnt <= tcnt + 1'b1;
                end
                default: state <= IDLE;
            endcase
        end
    end
endmodule
