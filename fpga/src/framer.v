// framer.v — pack samples into the on-wire frame, count losses, feed the UART.
//
// FRAME FORMAT v2 (1036 bytes, emitted once per 512 samples)
// ----------------------------------------------------------------------------
//   off  size  field      meaning
//     0     4  sync       AA 55 A5 5A          — receiver locks on to this
//     4     2  seq        uint16 LE            — frame counter, wraps at 65536
//     6     2  ovf        uint16 LE            — cumulative FIFO overflow BYTES
//     8     2  cfg        uint16 LE            — [7:0]=BCLK_DIV, [9:8]=channels
//    10  1024  payload    512 x int16 LE       — audio samples
//  1034     2  checksum   uint16 LE            — additive sum of payload bytes
// ----------------------------------------------------------------------------
//
// WHY THE EXTRA FIELDS EXIST
//   v1 was 4-byte sync + payload only. When the link saturated, bytes vanished and
//   the receiver simply resynchronised on the next sync word — loss was invisible.
//   Every number this project needs to report (drop rate, and WHERE the loss
//   happened) comes from these three counters:
//     seq       lets the host see gaps                       -> frame drop rate
//     ovf       says the loss happened HERE, in this FIFO    -> link saturated
//     checksum  says the bytes that DID arrive were mangled  -> signal integrity
//   If seq has gaps but ovf is 0, the FPGA kept up and the ESP32/USB side dropped.
//   That single distinction is the justification for moving to SPI later.
//
// STRUCTURE
//                 producer FSM              byte FIFO            consumer
//   sample  --->  builds header +   --->    64 x 8, absorbs  --->  hands bytes
//   (1 per        payload + trailer         the 10-byte           to uart_tx on
//    frame        1 byte per clock          header burst          tx_ready
//    period)      (bursty)                                        (steady)
//
// The FIFO is what makes the stream continuous: independent read and write
// pointers let the bursty producer and the steady UART run at the same time.
// A single FIFO is sufficient here — ping-pong (double) buffering solves a
// different problem (block-at-a-time handoff to a DMA engine), which is where
// it will be needed on the ESP32 side in the SPI milestone.
//
// OVERFLOW SEMANTICS (deliberate)
//   If a byte is pushed while the FIFO is full, the byte is DROPPED and ovf is
//   incremented. The checksum still includes the dropped byte, because it is a
//   sum of what we INTENDED to send — so a mid-frame drop shows up twice: as a
//   short frame (the host resynchronises) and as a checksum mismatch. Both are
//   wanted. Silent loss is the one thing that is not acceptable.

module framer #(
    parameter integer FIFO_DEPTH = 64,      // bytes; must be a power of two
    parameter integer FRAME_SAMPLES = 512
)(
    input  wire        clk,
    input  wire        rst_n,
    // from i2s_master_rx
    input  wire [15:0] sample,
    input  wire        sample_valid,
    // build-time configuration, echoed into every frame header
    input  wire [15:0] cfg,
    // to uart_tx
    output reg  [7:0]  tx_data,
    output reg         tx_valid,
    input  wire        tx_ready,
    // debug / status (optional, safe to leave unconnected)
    output wire [15:0] ovf_count,
    output wire [15:0] seq_count
);
    // ------------------------------------------------------------------
    // address width for the FIFO; pointers carry ONE EXTRA BIT so that
    // count = wptr - rptr distinguishes "empty" from "full" across wrap.
    // ------------------------------------------------------------------
    localparam integer AW = $clog2(FIFO_DEPTH);         // 6 for depth 64

    reg  [7:0]    mem [0:FIFO_DEPTH-1];
    reg  [AW:0]   wptr = 0;                             // AW+1 bits wide
    reg  [AW:0]   rptr = 0;
    wire [AW:0]   count = wptr - rptr;
    wire          full  = (count >= FIFO_DEPTH);
    wire          empty = (count == 0);

    reg           push;
    reg  [7:0]    push_byte;
    reg  [15:0]   ovf_q = 16'd0;                       // see "FIFO write" below

    // ------------------------------------------------------------------
    // producer FSM — one byte per clock, 24 MHz, so the whole 10-byte
    // header burst is emitted in 10 cycles. The FIFO absorbs it.
    // ------------------------------------------------------------------
    localparam [3:0] P_IDLE = 4'd0,
                     P_SY0  = 4'd1,  P_SY1 = 4'd2,  P_SY2 = 4'd3,  P_SY3 = 4'd4,
                     P_SQ0  = 4'd5,  P_SQ1 = 4'd6,      // seq  lo, hi
                     P_OV0  = 4'd7,  P_OV1 = 4'd8,      // ovf  lo, hi
                     P_CF0  = 4'd9,  P_CF1 = 4'd10,     // cfg  lo, hi
                     P_LO   = 4'd11, P_HI  = 4'd12,     // sample lo, hi
                     P_CK0  = 4'd13, P_CK1 = 4'd14;     // checksum lo, hi

    reg  [3:0]  pstate = P_IDLE;
    reg [15:0]  sreg   = 16'd0;                  // sample being serialised
    reg [15:0]  sum_q  = 16'd0;                  // running payload checksum
    reg [15:0]  seq_q  = 16'd0;                  // frame counter
    reg [15:0]  hdr_seq = 16'd0;                 // header snapshots, latched at
    reg [15:0]  hdr_ovf = 16'd0;                 // frame start so they cannot
                                                 // change between their two bytes
    reg [$clog2(FRAME_SAMPLES):0] scount = 0;    // sample index 0 .. N-1

    assign seq_count = seq_q;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            pstate  <= P_IDLE;
            sreg    <= 16'd0;
            sum_q   <= 16'd0;
            seq_q   <= 16'd0;
            hdr_seq <= 16'd0;
            hdr_ovf <= 16'd0;
            scount  <= 0;
            push    <= 1'b0;
            push_byte <= 8'd0;
        end else begin
            push <= 1'b0;                        // default: no push this cycle
            case (pstate)
                // ---- wait for a sample -------------------------------------
                P_IDLE: if (sample_valid) begin
                            sreg <= sample;
                            if (scount == 0) begin
                                hdr_seq <= seq_q;      // freeze header values
                                hdr_ovf <= ovf_q;
                                sum_q   <= 16'd0;      // checksum covers payload only
                                pstate  <= P_SY0;
                            end else begin
                                pstate  <= P_LO;
                            end
                        end

                // ---- 4-byte sync word --------------------------------------
                P_SY0: begin push <= 1'b1; push_byte <= 8'hAA; pstate <= P_SY1; end
                P_SY1: begin push <= 1'b1; push_byte <= 8'h55; pstate <= P_SY2; end
                P_SY2: begin push <= 1'b1; push_byte <= 8'hA5; pstate <= P_SY3; end
                P_SY3: begin push <= 1'b1; push_byte <= 8'h5A; pstate <= P_SQ0; end

                // ---- seq / ovf / cfg, little-endian ------------------------
                P_SQ0: begin push <= 1'b1; push_byte <= hdr_seq[7:0];  pstate <= P_SQ1; end
                P_SQ1: begin push <= 1'b1; push_byte <= hdr_seq[15:8]; pstate <= P_OV0; end
                P_OV0: begin push <= 1'b1; push_byte <= hdr_ovf[7:0];  pstate <= P_OV1; end
                P_OV1: begin push <= 1'b1; push_byte <= hdr_ovf[15:8]; pstate <= P_CF0; end
                P_CF0: begin push <= 1'b1; push_byte <= cfg[7:0];      pstate <= P_CF1; end
                P_CF1: begin push <= 1'b1; push_byte <= cfg[15:8];     pstate <= P_LO;  end

                // ---- one sample: low byte then high byte -------------------
                P_LO: begin
                          push      <= 1'b1;
                          push_byte <= sreg[7:0];
                          sum_q     <= sum_q + sreg[7:0];     // checksum accumulates
                          pstate    <= P_HI;
                      end
                P_HI: begin
                          push      <= 1'b1;
                          push_byte <= sreg[15:8];
                          sum_q     <= sum_q + sreg[15:8];
                          if (scount == FRAME_SAMPLES-1) begin
                              scount <= 0;
                              pstate <= P_CK0;               // frame complete
                          end else begin
                              scount <= scount + 1'b1;
                              pstate <= P_IDLE;
                          end
                      end

                // ---- 2-byte checksum trailer ------------------------------
                // sum_q was updated by P_HI's non-blocking assignment, so it is
                // already final by the time this state runs.
                P_CK0: begin push <= 1'b1; push_byte <= sum_q[7:0];  pstate <= P_CK1; end
                P_CK1: begin push <= 1'b1; push_byte <= sum_q[15:8];
                             seq_q  <= seq_q + 1'b1;         // next frame's number
                             pstate <= P_IDLE; end

                default: pstate <= P_IDLE;
            endcase
        end
    end

    // ------------------------------------------------------------------
    // FIFO write + overflow counter
    // A byte pushed into a full FIFO is lost — but it is COUNTED, which is
    // the entire point of this revision. The counter saturates rather than
    // wrapping, so a pegged 0xFFFF unambiguously means "massively overflowing"
    // instead of aliasing back to a small, innocent-looking number.
    // ------------------------------------------------------------------
    assign ovf_count = ovf_q;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            wptr  <= 0;
            ovf_q <= 16'd0;
        end else if (push) begin
            if (!full) begin
                mem[wptr[AW-1:0]] <= push_byte;
                wptr              <= wptr + 1'b1;
            end else if (ovf_q != 16'hFFFF) begin
                ovf_q <= ovf_q + 1'b1;                 // dropped, but counted
            end
        end
    end

    // ------------------------------------------------------------------
    // consumer — hand one byte at a time to uart_tx
    // ------------------------------------------------------------------
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            tx_valid <= 1'b0;
            tx_data  <= 8'd0;
            rptr     <= 0;
        end else begin
            if (tx_valid && tx_ready) begin           // byte accepted by the UART
                tx_valid <= 1'b0;
                rptr     <= rptr + 1'b1;
            end else if (!tx_valid && !empty) begin
                tx_data  <= mem[rptr[AW-1:0]];
                tx_valid <= 1'b1;
            end
        end
    end
endmodule
