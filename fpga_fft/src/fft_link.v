// fft_link.v — Tang Nano 20K side of the FFT benchmark (docs/11-fft-benchmark.md).
//
// Clock-independent: the top file picks the clock and passes CLK_MHZ.
//   top.v     27 MHz, straight from the crystal
//   top_54.v  54 MHz, from the PLL (27 MHz x 2)
//   top_81.v  81 MHz, from the PLL (27 MHz x 3)
// The UART stays at 1 Mbaud either way (CLK_MHZ clocks per bit).
//
// A frame engine that receives one 1024-point signal from the ESP32 into block RAM,
// optionally runs the Gowin FFT core on it, and sends the RAM back.
//   F2 'E' echo: proves the data path (UART in, RAM, UART out) with no FFT.
//   F3 'F' FFT:  the same path with the core in the middle.
//
//   ESP32 GPIO17 ──1 Mbaud──▶ pin 27 ─▶ uart_rx ─▶ frame engine ─▶ 1024×32 RAM ◀─┐
//   ESP32 GPIO18 ◀───────────  pin 28 ◀─ uart_tx ◀──────┘   │ samples      results │
//                                                         └─▶ fft_1024 ──────────┘
//
// ONE BUFFER FOR BOTH. The core first reads all 1024 inputs, then computes, then
// writes out results -- the phases never overlap for a single frame -- so results
// overwrite the samples in the same RAM. That saves 2 BSRAM blocks.
//
// FEEDING THE CORE (Gowin IPUG503, section 3.4 and Figure 6-1)
//   start  one-clock pulse, sampled only while the core is idle
//   sod    high for the cycle in which x(0) must be on xn_re/xn_im
//   ipd    high for every cycle that takes a sample; idx = that sample's number
//   opd    high for every cycle with a result on xk_re/xk_im; idx = its bin
//   eoud   high with the last result
// The RAM answers one clock after it is given an address, so while ipd is high it
// is already given idx + 1: the next sample is ready exactly when the core takes it.
//
// PROTOCOL (ESP32 <-> FPGA, little-endian; firmware/fft_bench must match)
//   request   A5 5A  cmd:u8  payload
//   reply     5A A5  status:u8  cycles:u32  rx_sum:u16  phase stamps:5 x u32  clk_mhz:u8
//             [payload]  tx_sum:u16
//   cmd       'E' echo: payload comes back unchanged
//             'F' FFT: payload comes back as its 1024-point FFT (natural order, ÷N)
//   payload   1024 x (re:int16, im:int16) = 4096 bytes, sent only when status = 0
//   status    0 ok, 1 bad command, 2 FFT never finished (watchdog, ~39 ms)
//   cycles    27 MHz clocks from 'start' to the last result (0 for echo)
//   rx_sum    byte sum of the payload as the FPGA RECEIVED it, so the ESP32 can tell
//             corruption on the way in from corruption on the way out (tx_sum)
//   stamps    TIME SPLIT of one FFT ('F' only, else 0). The cycle counter starts at 0
//             in the clock where 'start' is high; each stamp is the counter's value in
//             the first clock where that core signal is high:
//               sod   first sample taken        eod  last sample taken
//               busy rises (computing)          busy falls (done computing)
//               soud  first result out          (eoud = cycles - 1: last result out)
//             host/fft_bench.py turns them into setup / load / compute / unload.
//   clk_mhz   this design's clock, so the host can turn cycles into microseconds
//
//   If the request stops for 1 ms mid-frame (a lost byte), the frame is dropped
//   and the engine waits for the next A5 5A. The ESP32 sees no reply and says so.
//
// LEDs (active low): 0 heartbeat (design is loaded), 1 toggles per frame,
//   2 a frame timed out (sticky), 3 a UART framing error was seen (sticky),
//   4 receiving, 5 sending or computing.

module fft_link #(
    parameter integer CLK_MHZ = 27                // the clock below, in MHz
)(
    input  wire       clk,
    input  wire       clk_ok,      // high once the clock is stable (PLL locked)
    input  wire       uart_rx,     // from ESP32 GPIO17 (its TX)
    output wire       uart_tx,     // to ESP32 GPIO18 (its RX)
    output wire [5:0] led
);
    localparam integer CLK_PER_BIT = CLK_MHZ;     // CLK_MHZ clocks per bit = 1 Mbaud, exact
    localparam integer N           = 1024;
    localparam integer NB          = 4 * N;       // payload bytes
    localparam integer TIMEOUT     = CLK_MHZ * 1000;  // 1 ms of silence mid-frame

    // ---- reset: held until the clock is stable, then 128 more clocks ----
    reg [7:0] por = 8'd0;
    wire rst_n = por[7];
    always @(posedge clk)
        if (!clk_ok)     por <= 8'd0;
        else if (!rst_n) por <= por + 1'b1;

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

    // ---- frame engine states (the engine itself is further down) ----
    localparam [3:0] S_SYNC0 = 4'd0, S_SYNC1 = 4'd1, S_CMD = 4'd2, S_RX  = 4'd3,
                     S_PROC  = 4'd4, S_HDR   = 4'd5, S_PAY = 4'd6, S_SUM = 4'd7,
                     S_FFT   = 4'd8;
    localparam integer WATCHDOG = 1 << 20;        // 39 ms; a 1024-point FFT needs far less
    reg [3:0]  state   = S_SYNC0;

    // ---- FFT core (generated by the IP Core Generator: 1024 points, RS111) ----
    reg         fft_start = 1'b0;
    wire [9:0]  idx;
    wire [15:0] xk_re, xk_im;
    wire        sod, ipd, eod, busy, soud, opd, eoud;
    reg  [31:0] rd_q = 32'd0;
    fft_1024 u_fft (
        .clk(clk), .rst(~rst_n), .start(fft_start),
        .xn_re(rd_q[15:0]), .xn_im(rd_q[31:16]),
        .idx(idx), .xk_re(xk_re), .xk_im(xk_im),
        .sod(sod), .ipd(ipd), .eod(eod), .busy(busy),
        .soud(soud), .opd(opd), .eoud(eoud));

    // ---- signal buffer: one 32-bit word per point, {im, re} ----
    reg  [11:0] cnt = 12'd0;                      // payload byte index, in and out
    reg  [31:0] mem [0:N-1];
    reg         we = 1'b0;
    reg  [9:0]  wr_addr = 10'd0;
    reg  [31:0] wr_data = 32'd0;
    wire        in_fft  = (state == S_FFT);
    wire [9:0]  rd_addr = !in_fft ? cnt[11:2]     // UART: ready long before it is wanted
                        : ipd     ? idx + 1'b1    // core: one sample ahead (see header)
                        :           10'd0;        // x(0) waits for sod
    always @(posedge clk) begin
        if (we) mem[wr_addr] <= wr_data;
        rd_q <= mem[rd_addr];
    end

    // ---- frame engine ----
    reg [7:0]  cmd     = 8'd0;
    reg [7:0]  status  = 8'd0;
    reg [31:0] cycles  = 32'd0;
    reg [15:0] rx_sum  = 16'd0;
    reg [15:0] tx_sum  = 16'd0;
    reg [4:0]  hdr_idx = 5'd0;
    localparam [4:0] HDR_LAST = 5'd29;            // 30 header bytes: 2+1+4+2+5*4+1
    reg [31:0] t_sod = 0, t_eod = 0, t_brise = 0, t_bfall = 0, t_soud = 0;
    reg [4:0]  seen  = 5'd0;                      // which stamps are taken this frame
    reg [23:0] word    = 24'd0;                   // first three bytes of the current point
    reg [16:0] idle    = 17'd0;                   // clocks since the last received byte

    // header bytes, first byte in the lowest 8 bits
    localparam [7:0] CLK_BYTE = CLK_MHZ;
    wire [239:0] hdr_vec = {CLK_BYTE, t_soud, t_bfall, t_brise, t_eod, t_sod,
                            rx_sum, cycles, status, 8'hA5, 8'h5A};
    wire [7:0]   hdr_byte = hdr_vec[hdr_idx * 8 +: 8];

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
            state     <= S_SYNC0;
            fft_start <= 1'b0;
            tx_valid  <= 1'b0;
            we       <= 1'b0;
            idle     <= 17'd0;
        end else begin
            tx_valid <= 1'b0;
            we       <= 1'b0;
            idle     <= rx_valid ? 17'd0 : (idle == TIMEOUT ? idle : idle + 1'b1);
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
                        cmd    <= rx_data;
                        if (rx_data == "E" || rx_data == "F") state <= S_RX;
                        else begin
                            status  <= 8'd1;          // unknown command: reply, no payload
                            cycles  <= 32'd0;
                            hdr_idx <= 5'd0;
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
                S_PROC: begin
                    status  <= 8'd0;
                    cycles  <= 32'd0;
                    seen    <= 5'd0;
                    {t_sod, t_eod, t_brise, t_bfall, t_soud} <= 160'd0;
                    hdr_idx <= 5'd0;
                    if (cmd == "F") begin
                        fft_start <= 1'b1;            // one-clock pulse (cleared below)
                        state     <= S_FFT;
                    end else state <= S_HDR;          // echo: RAM goes back unchanged
                end
                S_FFT: begin                          // core loads, computes, unloads
                    fft_start <= 1'b0;
                    cycles    <= cycles + 1'b1;
                    // time split: note the counter at the first clock of each phase signal
                    if (sod  && !seen[0])            begin t_sod   <= cycles; seen[0] <= 1'b1; end
                    if (eod  && !seen[1])            begin t_eod   <= cycles; seen[1] <= 1'b1; end
                    if (busy && !seen[2])            begin t_brise <= cycles; seen[2] <= 1'b1; end
                    if (!busy && seen[2] && !seen[3]) begin t_bfall <= cycles; seen[3] <= 1'b1; end
                    if (soud && !seen[4])            begin t_soud  <= cycles; seen[4] <= 1'b1; end
                    if (opd) begin                    // each result to its own bin
                        we      <= 1'b1;
                        wr_addr <= idx;
                        wr_data <= {xk_im, xk_re};
                    end
                    if (eoud) state <= S_HDR;         // last result: cycles = start..eoud
                    else if (cycles == WATCHDOG) begin
                        status <= 8'd2;               // the core never finished
                        state  <= S_HDR;
                    end
                end
                S_HDR:
                    if (can_send) begin
                        tx_data  <= hdr_byte;
                        tx_valid <= 1'b1;
                        if (hdr_idx == HDR_LAST) begin
                            hdr_idx <= 5'd0;
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
                            hdr_idx   <= 5'd0;
                            frame_tog <= ~frame_tog;
                            state     <= S_SYNC0;     // uart_tx finishes the last byte alone
                        end else hdr_idx <= hdr_idx + 1'b1;
                    end
            endcase
        end
    end

    // ---- LEDs (the 20K's LEDs light when the pin is low) ----
    reg [25:0] beat = 26'd0;                      // ~0.8-1.2 s per blink at 27-81 MHz
    always @(posedge clk) beat <= beat + 1'b1;
    wire blink = (CLK_MHZ > 40) ? beat[25] : beat[24];
    wire receiving = in_frame;
    wire sending   = (state == S_HDR) || (state == S_PAY) || (state == S_SUM) || in_fft;
    assign led = ~{sending, receiving, ferr_seen, timeout_seen, frame_tog, blink};
endmodule
