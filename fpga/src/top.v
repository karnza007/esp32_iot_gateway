// top.v — INMP441 -> FPGA (I2S capture) -> UART -> ESP32 -> host
//
//   27 MHz xtal --> PLL 54 MHz --> i2s_master_rx --> framer --> uart_tx --> ESP32
//
// Everything below the PLL is a synchronous integer divide of one 54 MHz clock,
// so there is exactly one clock domain in the design. The datapath is held in
// reset until the button is released AND the PLL reports lock, so it never runs
// on an unstable clock.
//
// THE EXPERIMENT KNOBS LIVE HERE
//   BCLK_DIV   sets the sample rate: fs = SYS_CLK / (64 * BCLK_DIV)
//   CLK_PER_BIT sets the UART baud:  baud = SYS_CLK / CLK_PER_BIT
//   NUM_CH     number of microphone channels captured (1 today)
//
// Changing a sweep point is a one-line edit here. The values are also packed
// into `cfg` and transmitted in every frame header, so each captured data file
// records the conditions it was captured under and the host viewer can derive
// the sample rate on its own instead of being edited in lockstep.

module top_module #(
    // System clock in MHz, as produced by the PLL. Travels to the host in `cfg`
    // so the sample rate is derived from what the FPGA REPORTS, never from a
    // constant the host assumes. Three separate bugs in this project came from a
    // value written in one place and assumed in another; this closes the last one.
    parameter integer SYS_CLK_MHZ = 54,
    // fs = SYS_CLK / (64 * BCLK_DIV).  At 54 MHz:
    //   56:15.067k  40:21.094k  28:30.134k  24:35.156k  20:42.188k  18:46.875k (max)
    // BCLK = SYS_CLK / BCLK_DIV must stay <= 3.2 MHz (INMP441), so BCLK_DIV >= 17.
    parameter integer BCLK_DIV    = 56,
    parameter integer CLK_PER_BIT = 27,   // 54 MHz / 27 = 2,000,000 baud
    parameter integer NUM_CH      = 1,    // channels captured per frame
    // Synthetic load. GEN_MODE=1 replaces the microphone with a counter at
    // fs = SYS_CLK / GEN_DIV, so the link can be driven to saturation -- audio
    // cannot: one INMP441 makes 95 kB/s against a 200 kB/s link. Everything
    // downstream is unchanged. GEN_DIV must be a multiple of 64 so the rate can be
    // reported through the existing BCLK_DIV field as GEN_DIV/64.
    parameter integer GEN_MODE    = 0,
    parameter integer GEN_DIV     = 3584  // 54 MHz / 3584 = 15,067 Hz, the audio rate
)(
    input  wire clk,         // 27 MHz crystal (pin 45)
    input  wire rst,         // active-low button (pressed = 0, pin 14)
    output wire i2s_sck,     // -> INMP441 SCK   (pin 39)
    output wire i2s_ws,      // -> INMP441 WS    (pin 40)
    input  wire i2s_sd,      // <- INMP441 SD    (pin 41)
    output wire uart_tx,     // -> ESP32 RX      (pin 42)
    output wire lock_out     // PLL lock, debug  (pin 43)
);
    // ---- PLL: 27 -> 54 MHz (IDIV /1, FBDIV x2, ODIV 16 -> VCO 864 MHz) ----
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
    //   [7:0]   BCLK_DIV   host computes fs = SYS_CLK / (64 * BCLK_DIV)
    //   [9:8]   NUM_CH, or 3 = "payload is a counter, not audio"
    //   [15:10] clock code = SYS_CLK_MHZ / 6    (24 -> 4, 54 -> 9, 96 -> 16)
    //                        0 means "legacy bitstream, assume 24 MHz"
    //   6 MHz units, not 12: 54 MHz is not a multiple of 12, and picking the
    //   coarser unit first would have silently reported 48 MHz for a 54 MHz build.
    localparam [5:0] CLK_CODE = SYS_CLK_MHZ / 6;
    // In synthetic mode the channel field carries 3 -- a value no real microphone
    // configuration produces -- so the host knows to verify the payload as a
    // counter rather than plot it as audio. The rate field carries GEN_DIV/64, so
    // the host's fs formula still yields the true sample rate.
    localparam [1:0] CH_CODE   = (GEN_MODE != 0) ? 2'd3 : NUM_CH[1:0];
    localparam [7:0] RATE_CODE = (GEN_MODE != 0) ? (GEN_DIV/64) : BCLK_DIV[7:0];
    wire [15:0] cfg = {CLK_CODE, CH_CODE, RATE_CODE};

    // ---- I2S capture ----
    wire [15:0] mic_sample;
    wire        mic_valid;
    i2s_master_rx #(
        .BCLK_DIV  (BCLK_DIV),
        .CAP_START (2)
    ) u_i2s (
        .clk(clk24), .rst_n(rst_n),
        .i2s_sck(i2s_sck), .i2s_ws(i2s_ws), .i2s_sd(i2s_sd),
        .sample(mic_sample), .sample_valid(mic_valid)
    );

    // ---- synthetic source, for driving the link to saturation ----
    wire [15:0] gen_sample;
    wire        gen_valid;
    sample_gen #(.GEN_DIV(GEN_DIV)) u_gen (
        .clk(clk24), .rst_n(rst_n),
        .sample(gen_sample), .sample_valid(gen_valid)
    );

    wire [15:0] sample       = (GEN_MODE != 0) ? gen_sample : mic_sample;
    wire        sample_valid = (GEN_MODE != 0) ? gen_valid  : mic_valid;

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
