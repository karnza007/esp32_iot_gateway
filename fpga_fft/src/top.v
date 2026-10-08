// top.v — Tang Nano 20K side of the FFT benchmark (docs/11-fft-benchmark.md).
//
// F2 (this version): a frame engine that receives one 1024-point signal from the
// ESP32, stores it in block RAM, and sends it straight back. It proves the whole
// data path -- UART in, RAM, UART out -- before the FFT core goes in between (F3).
//
//   ESP32 GPIO17 ──1 Mbaud──▶ pin 27 ─▶ uart_rx ─▶ frame engine ─▶ 1024×32 RAM
//   ESP32 GPIO18 ◀───────────  pin 28 ◀─ uart_tx ◀───────┘ (read back in order)
//
// PROTOCOL (ESP32 <-> FPGA, little-endian; firmware/fft_bench must match)
//   request   A5 5A  cmd:u8  payload
//   reply     5A A5  status:u8  cycles:u32  rx_sum:u16  [payload]  tx_sum:u16
//   cmd       'E' echo: payload comes back unchanged
//   payload   1024 x (re:int16, im:int16) = 4096 bytes, sent only when status = 0
//   status    0 ok, 1 bad command
//   cycles    clock cycles the processing took (0 for echo; the FFT time in F3)
//   rx_sum    byte sum of the payload as the FPGA RECEIVED it, so the ESP32 can tell
//             corruption on the way in from corruption on the way out (tx_sum)
//
//   If the request stops for 1 ms mid-frame (a lost byte), the frame is dropped
//   and the engine waits for the next A5 5A. The ESP32 sees no reply and says so.
//
// LEDs (active low): 0 heartbeat (design is loaded), 1 toggles per frame,
//   2 a frame timed out (sticky), 3 a UART framing error was seen (sticky),
//   4 receiving, 5 sending.

module top (
    input  wire       clk,         // 27 MHz crystal
    input  wire       uart_rx,     // from ESP32 GPIO17 (its TX)
    output wire       uart_tx,     // to ESP32 GPIO18 (its RX)
    output wire [5:0] led
);
    localparam integer CLK_PER_BIT = 27;          // 27 MHz / 27 = 1 Mbaud, exact
    localparam integer N           = 1024;
    localparam integer NB          = 4 * N;       // payload bytes
    localparam integer TIMEOUT     = 27_000;      // 1 ms of silence mid-frame

    // ---- power-on reset: hold everything for 128 clocks after configuration ----
    reg [7:0] por = 8'd0;
    wire rst_n = por[7];
    always @(posedge clk) if (!rst_n) por <= por + 1'b1;

    // ---- UART ----
    wire [7:0] rx_data;
    wire       rx_valid, frame_err;
    uart_rx #(.CLK_PER_BIT(CLK_PER_BIT)) u_rx (
        .clk(clk), .rst_n(rst_n), .rx(uart_rx),
        .rx_data(rx_data), .rx_valid(rx_valid), .frame_err(frame_err));

    reg  [7:0] tx_data  = 8'd0;
    reg        tx_valid = 1'b0;
    wire       tx_ready;
    uart_tx #(.CLK_PER_BIT(CLK_PER_BIT)) u_tx (
        .clk(clk), .rst_n(rst_n), .tx_data(tx_data), .tx_valid(tx_valid),
        .tx_ready(tx_ready), .tx(uart_tx));

    // ---- signal buffer: one 32-bit word per point, {im, re} ----
    reg  [11:0] cnt = 12'd0;                      // payload byte index, in and out
    reg  [31:0] mem [0:N-1];
    reg         we = 1'b0;
    reg  [9:0]  wr_addr = 10'd0;
    reg  [31:0] wr_data = 32'd0;
    reg  [31:0] rd_q = 32'd0;
    always @(posedge clk) begin
        if (we) mem[wr_addr] <= wr_data;
        rd_q <= mem[cnt[11:2]];                   // ready long before the UART wants it
    end

    // ---- frame engine ----
    localparam [2:0] S_SYNC0 = 3'd0, S_SYNC1 = 3'd1, S_CMD = 3'd2, S_RX = 3'd3,
                     S_PROC  = 3'd4, S_HDR   = 3'd5, S_PAY = 3'd6, S_SUM = 3'd7;
    reg [2:0]  state   = S_SYNC0;
    reg [7:0]  status  = 8'd0;
    reg [31:0] cycles  = 32'd0;
    reg [15:0] rx_sum  = 16'd0;
    reg [15:0] tx_sum  = 16'd0;
    reg [3:0]  hdr_idx = 4'd0;
    reg [23:0] word    = 24'd0;                   // first three bytes of the current point
    reg [14:0] idle    = 15'd0;                   // clocks since the last received byte

    reg [7:0] hdr_byte;
    always @* begin
        case (hdr_idx)
            4'd0:    hdr_byte = 8'h5A;
            4'd1:    hdr_byte = 8'hA5;
            4'd2:    hdr_byte = status;
            4'd3:    hdr_byte = cycles[7:0];
            4'd4:    hdr_byte = cycles[15:8];
            4'd5:    hdr_byte = cycles[23:16];
            4'd6:    hdr_byte = cycles[31:24];
            4'd7:    hdr_byte = rx_sum[7:0];
            default: hdr_byte = rx_sum[15:8];
        endcase
    end

    reg [7:0] pay_byte;
    always @* begin
        case (cnt[1:0])
            2'd0: pay_byte = rd_q[7:0];
            2'd1: pay_byte = rd_q[15:8];
            2'd2: pay_byte = rd_q[23:16];
            2'd3: pay_byte = rd_q[31:24];
        endcase
    end

    // A byte is handed to uart_tx as a one-clock tx_valid pulse while it is idle.
    wire can_send = tx_ready && !tx_valid;
    wire in_frame = (state == S_SYNC1) || (state == S_CMD) || (state == S_RX);

    reg frame_tog = 1'b0, timeout_seen = 1'b0, ferr_seen = 1'b0;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            state    <= S_SYNC0;
            tx_valid <= 1'b0;
            we       <= 1'b0;
            idle     <= 15'd0;
        end else begin
            tx_valid <= 1'b0;
            we       <= 1'b0;
            idle     <= rx_valid ? 15'd0 : (idle == TIMEOUT ? idle : idle + 1'b1);
            if (frame_err) ferr_seen <= 1'b1;

            if (in_frame && idle == TIMEOUT) begin
                state        <= S_SYNC0;              // lost byte: drop the frame
                timeout_seen <= 1'b1;
            end else case (state)
                S_SYNC0:
                    if (rx_valid && rx_data == 8'hA5) state <= S_SYNC1;
                S_SYNC1:
                    if (rx_valid)
                        state <= (rx_data == 8'h5A) ? S_CMD :
                                 (rx_data == 8'hA5) ? S_SYNC1 : S_SYNC0;
                S_CMD:
                    if (rx_valid) begin
                        cnt    <= 12'd0;
                        rx_sum <= 16'd0;
                        if (rx_data == "E") state <= S_RX;
                        else begin
                            status  <= 8'd1;          // unknown command: reply, no payload
                            cycles  <= 32'd0;
                            hdr_idx <= 4'd0;
                            state   <= S_HDR;
                        end
                    end
                S_RX:
                    if (rx_valid) begin
                        rx_sum <= rx_sum + rx_data;
                        word   <= {rx_data, word[23:8]};
                        if (cnt[1:0] == 2'd3) begin   // 4th byte: the point is complete
                            we      <= 1'b1;
                            wr_addr <= cnt[11:2];
                            wr_data <= {rx_data, word};
                        end
                        if (cnt == NB - 1) begin
                            cnt   <= 12'd0;
                            state <= S_PROC;
                        end else cnt <= cnt + 1'b1;
                    end
                S_PROC: begin                         // F3: the FFT runs here
                    status  <= 8'd0;
                    cycles  <= 32'd0;
                    hdr_idx <= 4'd0;
                    state   <= S_HDR;
                end
                S_HDR:
                    if (can_send) begin
                        tx_data  <= hdr_byte;
                        tx_valid <= 1'b1;
                        if (hdr_idx == 4'd8) begin
                            hdr_idx <= 4'd0;
                            tx_sum  <= 16'd0;
                            state   <= (status == 8'd0) ? S_PAY : S_SUM;
                        end else hdr_idx <= hdr_idx + 1'b1;
                    end
                S_PAY:
                    if (can_send) begin
                        tx_data  <= pay_byte;
                        tx_valid <= 1'b1;
                        tx_sum   <= tx_sum + pay_byte;
                        if (cnt == NB - 1) begin
                            cnt   <= 12'd0;
                            state <= S_SUM;
                        end else cnt <= cnt + 1'b1;
                    end
                S_SUM:
                    if (can_send) begin
                        tx_data  <= hdr_idx[0] ? tx_sum[15:8] : tx_sum[7:0];
                        tx_valid <= 1'b1;
                        if (hdr_idx[0]) begin
                            hdr_idx   <= 4'd0;
                            frame_tog <= ~frame_tog;
                            state     <= S_SYNC0;     // uart_tx finishes the last byte alone
                        end else hdr_idx <= hdr_idx + 1'b1;
                    end
            endcase
        end
    end

    // ---- LEDs (the 20K's LEDs light when the pin is low) ----
    reg [24:0] beat = 25'd0;                      // 2^25 / 27 MHz = 1.2 s per blink
    always @(posedge clk) beat <= beat + 1'b1;
    wire receiving = in_frame;
    wire sending   = (state == S_HDR) || (state == S_PAY) || (state == S_SUM);
    assign led = ~{sending, receiving, ferr_seen, timeout_seen, frame_tog, beat[24]};
endmodule
