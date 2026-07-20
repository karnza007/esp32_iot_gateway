// framer.v — pack samples into the on-wire frame and feed the UART.
//
// Frame protocol (matches inmp441_viewer.py):
//   every 512 samples:  4-byte sync  AA 55 A5 5A
//   each sample:        2 bytes, little-endian int16  (low byte, then high byte)
//
// A small byte FIFO decouples the burst (sync + sample = 6 bytes) from the UART.
module framer (
    input  wire        clk,
    input  wire        rst_n,
    input  wire [15:0] sample,
    input  wire        sample_valid,
    // to uart_tx
    output reg  [7:0]  tx_data,
    output reg         tx_valid,
    input  wire        tx_ready
);
    // ---------------- byte FIFO (depth 32) ----------------
    reg  [7:0] mem [0:31];
    reg  [5:0] wptr = 6'd0;            // 6-bit pointers (extra bit for full/empty)
    reg  [5:0] rptr = 6'd0;
    wire [5:0] count = wptr - rptr;
    wire       full  = (count >= 6'd32);
    wire       empty = (count == 6'd0);

    reg        push;
    reg  [7:0] push_byte;

    // ---------------- producer: push bytes on sample_valid ----------------
    localparam [2:0] P_IDLE=3'd0, P_S0=3'd1, P_S1=3'd2, P_S2=3'd3,
                     P_S3=3'd4, P_LO=3'd5, P_HI=3'd6;
    reg  [2:0] pstate = P_IDLE;
    reg [15:0] sreg   = 16'd0;
    reg  [8:0] scount = 9'd0;          // sample index 0..511

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            pstate <= P_IDLE; sreg <= 16'd0; scount <= 9'd0;
            push <= 1'b0; push_byte <= 8'd0;
        end else begin
            push <= 1'b0;
            case (pstate)
                P_IDLE: if (sample_valid) begin
                            sreg   <= sample;
                            pstate <= (scount == 9'd0) ? P_S0 : P_LO;
                        end
                P_S0: begin push <= 1'b1; push_byte <= 8'hAA; pstate <= P_S1; end
                P_S1: begin push <= 1'b1; push_byte <= 8'h55; pstate <= P_S2; end
                P_S2: begin push <= 1'b1; push_byte <= 8'hA5; pstate <= P_S3; end
                P_S3: begin push <= 1'b1; push_byte <= 8'h5A; pstate <= P_LO; end
                P_LO: begin push <= 1'b1; push_byte <= sreg[7:0];  pstate <= P_HI; end
                P_HI: begin push <= 1'b1; push_byte <= sreg[15:8];
                            scount <= (scount == 9'd511) ? 9'd0 : (scount + 1'b1);
                            pstate <= P_IDLE; end
                default: pstate <= P_IDLE;
            endcase
        end
    end

    // ---------------- FIFO write ----------------
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) wptr <= 6'd0;
        else if (push && !full) begin
            mem[wptr[4:0]] <= push_byte;
            wptr           <= wptr + 1'b1;
        end
    end

    // ---------------- consumer: drain FIFO into UART ----------------
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            tx_valid <= 1'b0; tx_data <= 8'd0; rptr <= 6'd0;
        end else begin
            if (tx_valid && tx_ready) begin      // byte accepted by UART
                tx_valid <= 1'b0;
                rptr     <= rptr + 1'b1;
            end else if (!tx_valid && !empty) begin
                tx_data  <= mem[rptr[4:0]];
                tx_valid <= 1'b1;
            end
        end
    end
endmodule
