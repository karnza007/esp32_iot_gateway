// top.v — INMP441 -> FPGA (I2S capture) -> UART -> ESP32 -> host
//
//   27 MHz xtal --> PLL 24 MHz --> i2s_master_rx --> framer --> uart_tx --> ESP32
//
// Everything below the PLL is a synchronous integer divide of one 24 MHz clock,
// so there is exactly one clock domain in the design. The datapath is held in
// reset until the button is released AND the PLL reports lock, so it never runs
// on an unstable clock.
//
// THE EXPERIMENT KNOBS LIVE HERE
//   BCLK_DIV   sets the sample rate: fs = 24 MHz / (64 * BCLK_DIV)
//   CLK_PER_BIT sets the UART baud:  baud = 24 MHz / CLK_PER_BIT
//   NUM_CH     number of microphone channels captured (1 today)
//
// Changing a sweep point is a one-line edit here. The values are also packed
// into `cfg` and transmitted in every frame header, so each captured data file
// records the conditions it was captured under and the host viewer can derive
// the sample rate on its own instead of being edited in lockstep.

module top_module #(
    // fs = 24 MHz / (64 * BCLK_DIV).  25:15.000k  20:18.750k  16:23.4375k
    //                                  12:31.250k  10:37.500k   8:46.875k (max)
    parameter integer BCLK_DIV    = 8,
    parameter integer CLK_PER_BIT = 12,   // 12 -> 2,000,000 baud
    parameter integer NUM_CH      = 1     // channels captured per frame
)(
    input  wire clk,         // 27 MHz crystal (pin 45)
    input  wire rst,         // active-low button (pressed = 0, pin 14)
    output wire i2s_sck,     // -> INMP441 SCK   (pin 39)
    output wire i2s_ws,      // -> INMP441 WS    (pin 40)
    input  wire i2s_sd,      // <- INMP441 SD    (pin 41)
    output wire uart_tx,     // -> ESP32 RX      (pin 42)
    output wire lock_out     // PLL lock, debug  (pin 43)
);
    // ---- PLL: 27 -> 24 MHz (IDIV /9, FBDIV x8; verified on a scope) ----
    wire clk24;
    wire pll_lock;
    Gowin_PLLVR your_instance_name(
        .clkout (clk24),
        .lock   (pll_lock),
        .reset  (~rst),      // PLLVR reset is active-HIGH
        .clkin  (clk)
    );
    assign lock_out = pll_lock;

    // datapath reset: run only when the button is released AND the PLL is locked
    wire rst_n = rst & pll_lock;

    // ---- configuration word echoed in every frame header ----
    //   [7:0]   BCLK_DIV   host computes fs = 24e6 / (64 * BCLK_DIV)
    //   [9:8]   NUM_CH
    //   [15:10] reserved, must read 0
    wire [15:0] cfg = {6'd0, NUM_CH[1:0], BCLK_DIV[7:0]};

    // ---- I2S capture ----
    wire [15:0] sample;
    wire        sample_valid;
    i2s_master_rx #(
        .BCLK_DIV  (BCLK_DIV),
        .CAP_START (2)
    ) u_i2s (
        .clk(clk24), .rst_n(rst_n),
        .i2s_sck(i2s_sck), .i2s_ws(i2s_ws), .i2s_sd(i2s_sd),
        .sample(sample), .sample_valid(sample_valid)
    );

    // ---- framing + loss instrumentation ----
    wire [7:0] tx_data;
    wire       tx_valid, tx_ready;
    framer #(
        .FIFO_DEPTH    (64),
        .FRAME_SAMPLES (512)
    ) u_framer (
        .clk(clk24), .rst_n(rst_n),
        .sample(sample), .sample_valid(sample_valid),
        .cfg(cfg),
        .tx_data(tx_data), .tx_valid(tx_valid), .tx_ready(tx_ready),
        .ovf_count(), .seq_count()          // status outputs, unused on hardware
    );

    // ---- serial transport ----
    uart_tx #(.CLK_PER_BIT(CLK_PER_BIT)) u_uart(
        .clk(clk24), .rst_n(rst_n),
        .tx_data(tx_data), .tx_valid(tx_valid), .tx_ready(tx_ready),
        .tx(uart_tx)
    );
endmodule
