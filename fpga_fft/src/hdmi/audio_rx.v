// audio_rx.v — music from the Mac over the Tang Nano 20K's own USB cable (2026-11-06).
//
//   Mac (host/play_song.py) --USB--> BL616 debugger chip --UART pin 70--> this module
//   this module --UART pin 69--> BL616 --USB--> Mac        (credits and status, a few bytes)
//
// LINK. 8N1 at clk / CLK_PER_BIT: 74.25 MHz / 25 = 2.97 Mbaud (the Mac opens the port at
// 3 Mbaud; 1 % apart). Measured on this board: Mac -> FPGA loses nothing (the BL616 makes the Mac
// wait) and carries 170 KB/s in writes of 512 bytes or more; FPGA -> Mac is clean at low rates.
//
// PACKET (69 bytes):  B5 6A | seq | 32 samples, 16-bit, low byte first | sum16, low byte first
//   sum16 = the 64 sample bytes added up, mod 65536. seq counts 0..254; seq 255 is RESET:
//   empty the buffer and stop (the samples in it are ignored); answered with "R".
//   Samples are 24,170 Hz (half the output rate), mono: 755 packets/s = 52 KB/s.
//
// BUFFER. 2,048 samples (85 ms) in one block RAM pair. A packet's samples are written as they
// arrive but only kept ("committed") if its sum16 is right; a bad packet is dropped whole. A
// packet that does not fit is dropped too (cannot happen while the Mac respects the credits).
//
// CREDITS. The Mac may send 1,536 samples after a RESET, then 256 more for every "C" this
// module sends; it sends one "C" for every 256 samples played. So the buffer never overflows and
// the FPGA's own clock sets the pace of the whole chain. After every 16th "C" a status follows:
//   "S" | bad sums | seq gaps | dropped (no room) | underruns       (each counts to 255 and stops)
//
// PLAYING. Starts when the buffer holds 1,024 samples. The output (i2s_tx, 48,339.8 Hz) asks for
// a sample every frame; each received sample x is used for two: x[n], then (x[n] + x[n+1]) / 2,
// so the 24,170 Hz music plays at 48,340 Hz without steps. If the buffer runs empty while
// playing, the last sample is held and an underrun is counted; after 4,096 frames (85 ms) empty
// it stops (the song has ended) and the output returns to 0.
// pa_en: on while there is data or music, and for 100 ms after.
module audio_rx #(
    parameter integer CLK_PER_BIT = 25,           // 74.25 MHz / 25 = 2.97 Mbaud
    parameter integer HANG        = 4833          // frames PA_EN stays on after the music: 100 ms
)(
    input  wire               clk,
    input  wire               rst,
    input  wire               rx,                 // pin 70
    output wire               tx,                 // pin 69
    input  wire               req,                // from i2s_tx: a new output frame has begun
    output reg  signed [15:0] sample = 0,         // to i2s_tx
    output wire               pa_en,
    output wire               playing,
    output reg                trouble = 1'b0      // one-clock pulse: a bad packet, a gap or an underrun
);
    // ---- UART ----
    wire [7:0] rd;
    wire       rv, rferr;
    uart_rx #(.CLK_PER_BIT(CLK_PER_BIT)) u_rx (.clk(clk), .rst_n(!rst), .rx(rx),
                                              .rx_data(rd), .rx_valid(rv), .frame_err(rferr));
    reg  [7:0] txd = 0;
    reg        txv = 1'b0;
    wire       txr;
    uart_tx #(.CLK_PER_BIT(CLK_PER_BIT)) u_tx (.clk(clk), .rst_n(!rst), .tx_data(txd), .tx_valid(txv),
                                              .tx_ready(txr), .tx(tx));

    // ---- buffer: 2,048 x 16; pointers one bit wider than the address ----
    reg signed [15:0] mem [0:2047];
    reg  [11:0] wptr = 0, rptr = 0;               // committed write, read
    reg  [11:0] wtmp = 0;                         // write position inside the current packet
    wire [11:0] level = wptr - rptr;

    // ---- packet parser ----
    localparam [2:0] P_SYNC1 = 3'd0, P_SYNC2 = 3'd1, P_SEQ = 3'd2, P_DATA = 3'd3,
                     P_SUML = 3'd4, P_SUMH = 3'd5;
    reg  [2:0]  ps = P_SYNC1;
    reg  [7:0]  seq = 0, last_seq = 8'd254, lo = 0, sum_lo = 0;
    reg  [5:0]  nb = 0;                           // payload byte 0..63
    reg  [15:0] sum = 0;
    reg         drop = 1'b0, have_seq = 1'b0;
    reg         do_reset = 1'b0;                  // pulse: a good RESET packet
    reg  [7:0]  n_bad = 0, n_gap = 0, n_drop = 0, n_und = 0;
    reg         t_rx = 1'b0;                      // trouble from the parser
    always @(posedge clk) begin
        do_reset <= 1'b0;  t_rx <= 1'b0;
        if (rst) begin
            ps <= P_SYNC1;  wptr <= 0;  wtmp <= 0;  have_seq <= 1'b0;
            n_bad <= 0;  n_gap <= 0;  n_drop <= 0;
        end else begin
            if (rferr) ps <= P_SYNC1;             // a broken byte: look for the next packet
            else if (rv) case (ps)
                P_SYNC1: if (rd == 8'hB5) ps <= P_SYNC2;
                P_SYNC2: ps <= (rd == 8'h6A) ? P_SEQ : (rd == 8'hB5) ? P_SYNC2 : P_SYNC1;
                P_SEQ:   begin
                             seq <= rd;  nb <= 0;  sum <= 0;  wtmp <= wptr;
                             drop <= (12'd2048 - level) < 12'd32;      // no room for 32 more
                             ps <= P_DATA;
                         end
                P_DATA:  begin
                             sum <= sum + rd;
                             if (!nb[0]) lo <= rd;
                             else begin
                                 if (!drop && seq != 8'd255) mem[wtmp[10:0]] <= {rd, lo};
                                 wtmp <= wtmp + 1'b1;
                             end
                             nb <= nb + 1'b1;
                             if (nb == 6'd63) ps <= P_SUML;
                         end
                P_SUML:  begin sum_lo <= rd;  ps <= P_SUMH; end
                P_SUMH:  begin
                             ps <= P_SYNC1;
                             if ({rd, sum_lo} != sum) begin
                                 if (n_bad != 8'hFF) n_bad <= n_bad + 1'b1;
                                 t_rx <= 1'b1;
                             end else if (seq == 8'd255) begin
                                 do_reset <= 1'b1;                   // the player empties the buffer
                                 have_seq <= 1'b0;
                                 n_bad <= 0;  n_gap <= 0;  n_drop <= 0;
                             end else if (drop) begin
                                 if (n_drop != 8'hFF) n_drop <= n_drop + 1'b1;
                                 t_rx <= 1'b1;
                             end else begin
                                 wptr <= wtmp;                       // keep the packet
                                 if (have_seq && seq != ((last_seq == 8'd254) ? 8'd0 : last_seq + 1'b1)) begin
                                     if (n_gap != 8'hFF) n_gap <= n_gap + 1'b1;
                                     t_rx <= 1'b1;
                                 end
                                 last_seq <= seq;  have_seq <= 1'b1;
                             end
                         end
                default: ps <= P_SYNC1;
            endcase
        end
    end

    // ---- player: two output frames per received sample ----
    reg         play = 1'b0, phase = 1'b0, rd_pend = 1'b0, empty_hold = 1'b0;
    reg  signed [15:0] a = 0, b = 0, q = 0;
    reg  [12:0] empty_cnt = 0;
    reg  [12:0] hang = 0;
    reg  [7:0]  pops = 0;                         // samples played since the last credit
    reg         credit = 1'b0;                    // pulse: 256 more played
    wire signed [16:0] avg = a + b;
    always @(posedge clk) q <= mem[rptr[10:0]];
    always @(posedge clk) begin
        credit <= 1'b0;  trouble <= t_rx;
        if (rst || do_reset) begin
            play <= 1'b0;  phase <= 1'b0;  rd_pend <= 1'b0;  a <= 0;  b <= 0;  sample <= 0;
            empty_cnt <= 0;  pops <= 0;  empty_hold <= 1'b0;
            if (rst) begin rptr <= 0;  n_und <= 0;  hang <= 0; end
            else begin rptr <= wptr;  n_und <= 0; end          // RESET: drop what is buffered
        end else begin
            if (!play && level >= 12'd1024) begin           // start: a = 0 fades in over one step
                play <= 1'b1;  phase <= 1'b0;  empty_cnt <= 0;  empty_hold <= 1'b0;
            end
            if (req) begin
                if (!play) sample <= 0;
                else if (!phase) begin
                    sample <= a;  phase <= 1'b1;
                end else begin
                    sample <= avg[16:1];  phase <= 1'b0;
                    a <= b;
                    rd_pend <= 1'b1;                        // q (mem[rptr]) is ready next clock
                end
            end
            if (rd_pend) begin
                rd_pend <= 1'b0;
                if (level != 0) begin
                    b <= q;  rptr <= rptr + 1'b1;  empty_cnt <= 0;  empty_hold <= 1'b0;
                    pops <= pops + 1'b1;
                    if (pops == 8'd255) credit <= 1'b1;
                end else begin                              // nothing to play: hold b
                    if (!empty_hold) begin
                        empty_hold <= 1'b1;
                        if (n_und != 8'hFF) n_und <= n_und + 1'b1;
                        trouble <= 1'b1;
                    end
                end
            end
            if (play && req && level == 0) begin
                if (empty_cnt == 13'd4095) begin            // 85 ms with nothing: the song ended
                    play <= 1'b0;  a <= 0;  b <= 0;  sample <= 0;
                end else empty_cnt <= empty_cnt + 1'b1;
            end
            if (play || level != 0) hang <= HANG[12:0];
            else if (req && hang != 0) hang <= hang - 1'b1;
        end
    end
    assign playing = play;
    assign pa_en   = play || level != 0 || hang != 0;

    // ---- answers to the Mac: "R" after a reset, "C" per 256 played, "S" + 4 counters every 16 C ----
    reg        want_r = 1'b0;
    reg  [3:0] want_c = 0;                        // credits not sent yet
    reg  [3:0] c16 = 0;                           // credits sent since the last status
    reg  [2:0] s_i = 0;                           // status bytes still to send (5 = "S" + 4)
    reg  [31:0] s_buf = 0;
    always @(posedge clk) begin
        txv <= 1'b0;
        if (rst) begin
            want_r <= 1'b0;  want_c <= 0;  c16 <= 0;  s_i <= 0;
        end else begin
            if (do_reset) begin want_r <= 1'b1;  want_c <= 0;  c16 <= 0;  s_i <= 0; end
            if (credit && want_c != 4'hF) want_c <= want_c + 1'b1;
            if (txr && !txv) begin
                if (want_r) begin
                    txd <= "R";  txv <= 1'b1;  want_r <= 1'b0;
                end else if (s_i != 0) begin                // finish a status first
                    txd <= (s_i == 3'd5) ? "S" : s_buf[31:24];
                    if (s_i != 3'd5) s_buf <= s_buf << 8;
                    txv <= 1'b1;  s_i <= s_i - 1'b1;
                end else if (want_c != 0) begin
                    txd <= "C";  txv <= 1'b1;
                    want_c <= want_c - 1'b1 + (credit ? 1'b1 : 1'b0);
                    c16 <= c16 + 1'b1;
                    if (c16 == 4'd15) begin
                        s_i <= 3'd5;  s_buf <= {n_bad, n_gap, n_drop, n_und};
                    end
                end
            end
        end
    end
endmodule
