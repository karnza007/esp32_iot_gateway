// relay_rx.v — microphone samples relayed by the ESP32-S3 over UART -> 24-bit words.
//
// Used when the INMP441 is wired to the ESP32 (its I2S is proven on that wiring) instead of
// directly to the FPGA. The ESP32 (firmware/mic_relay) reads the mic at 48 kHz and sends:
//
//   B5 6A | seq | 32 samples x 3 bytes (24-bit, low byte first) | sum16 of the 96 bytes
//   101 bytes per packet, 1,500 packets/s, at 2.97 Mbaud = 74.25 MHz / 25 (51 % of the link)
//
// A packet is stored, its sum checked, and only then are its 32 samples released, one
// every GAP clocks (the window ROM in spectrum.v needs a few clocks between samples). A
// packet with a wrong sum is dropped whole, never shown. Release takes 32 x GAP = 512
// clocks; the next packet's header alone takes 3 bytes x 250 clocks, so its payload never
// overwrites samples still being released. A packet that stalls for 1 ms is abandoned.
module relay_rx #(
    parameter integer CLK_PER_BIT = 25,
    parameter integer GAP         = 16
)(
    input  wire        clk,
    input  wire        rst,
    input  wire        rx,
    output reg         valid = 1'b0,          // one pulse per released sample
    output reg  [23:0] word = 24'd0,
    output reg         pkt_ok = 1'b0,         // pulse per good packet
    output reg         pkt_bad = 1'b0         // pulse per packet with a wrong sum
);
    localparam integer NB = 96;               // payload bytes
    localparam integer TIMEOUT = 74_250;      // 1 ms

    wire [7:0] b;
    wire       bv;
    uart_rx #(.CLK_PER_BIT(CLK_PER_BIT)) u_rx (.clk(clk), .rst_n(~rst), .rx(rx),
        .rx_data(b), .rx_valid(bv), .frame_err());

    reg [7:0]  pbuf [0:NB-1];
    reg [2:0]  st = 0;
    reg [6:0]  n = 0;
    reg [15:0] sum = 0;
    reg [7:0]  ck_lo = 0;
    reg [16:0] idle = 0;
    localparam [2:0] S_SY0 = 0, S_SY1 = 1, S_SEQ = 2, S_PAY = 3, S_CK0 = 4, S_CK1 = 5;

    // release of a checked packet: 32 samples, one every GAP clocks
    reg        rel = 1'b0;
    reg [4:0]  ri = 0;
    reg [7:0]  gap_cnt = 0;

    always @(posedge clk) begin
        valid   <= 1'b0;
        pkt_ok  <= 1'b0;
        pkt_bad <= 1'b0;
        idle    <= bv ? 17'd0 : (idle == TIMEOUT ? idle : idle + 1'b1);
        if (rst) begin
            st <= S_SY0; rel <= 1'b0;
        end else begin
            if (st != S_SY0 && idle == TIMEOUT) st <= S_SY0;
            else if (bv) case (st)
                S_SY0: if (b == 8'hB5) st <= S_SY1;
                S_SY1: st <= (b == 8'h6A) ? S_SEQ : (b == 8'hB5) ? S_SY1 : S_SY0;
                S_SEQ: begin n <= 0; sum <= 0; st <= S_PAY; end   // seq: room for loss counting
                S_PAY: begin
                    pbuf[n] <= b;
                    sum     <= sum + b;
                    n       <= n + 1'b1;
                    if (n == NB - 1) st <= S_CK0;
                end
                S_CK0: begin ck_lo <= b; st <= S_CK1; end
                S_CK1: begin
                    st <= S_SY0;
                    if ({b, ck_lo} == sum) begin
                        pkt_ok <= 1'b1;
                        rel <= 1'b1; ri <= 0; gap_cnt <= 0;
                    end else pkt_bad <= 1'b1;
                end
                default: st <= S_SY0;
            endcase

            if (rel) begin
                if (gap_cnt == 0) begin
                    word  <= {pbuf[3 * ri + 2], pbuf[3 * ri + 1], pbuf[3 * ri]};
                    valid <= 1'b1;
                    if (ri == 5'd31) rel <= 1'b0;
                    ri <= ri + 1'b1;
                end
                gap_cnt <= (gap_cnt == GAP - 1) ? 8'd0 : gap_cnt + 1'b1;
            end
        end
    end
endmodule
