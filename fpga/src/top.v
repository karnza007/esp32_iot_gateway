// top.v — INMP441 -> FPGA (I2S capture) -> UART -> ESP32
//
//   27 MHz xtal -> PLL 24 MHz -> i2s_master_rx -> framer -> uart_tx -> ESP32 RX
//
// The datapath is held in reset until the button is released AND the PLL is locked,
// so it only runs on a stable 24 MHz clock.
module top_module(
    input  wire clk,         // 27 MHz crystal (pin 45)
    input  wire rst,         // active-low button (pressed = 0, pin 14)
    output wire i2s_sck,     // -> INMP441 SCK   (pin 39)
    output wire i2s_ws,      // -> INMP441 WS    (pin 40)
    input  wire i2s_sd,      // <- INMP441 SD    (pin 41)
    output wire uart_tx,     // -> ESP32 RX      (pin 42)
    output wire lock_out     // PLL lock, debug  (pin 43)
);
    // ---- PLL: 27 -> 24 MHz (verified IP) ---
    wire clk24;
    wire pll_lock;
    Gowin_PLLVR your_instance_name(
        .clkout (clk24),
        .lock   (pll_lock),
        .reset  (~rst),      // PLLVR reset is active-high
        .clkin  (clk)
    );
    assign lock_out = pll_lock;

    // datapath reset: run only when button released (rst=1) and PLL locked
    wire rst_n = rst & pll_lock;

    // ---- I2S capture ----
    wire [15:0] sample;
    wire        sample_valid;
    i2s_master_rx u_i2s(
        .clk(clk24), .rst_n(rst_n),
        .i2s_sck(i2s_sck), .i2s_ws(i2s_ws), .i2s_sd(i2s_sd),
        .sample(sample), .sample_valid(sample_valid)
    );

    // ---- framer + UART ----
    wire [7:0] tx_data;
    wire       tx_valid, tx_ready;
    framer u_framer(
        .clk(clk24), .rst_n(rst_n),
        .sample(sample), .sample_valid(sample_valid),
        .tx_data(tx_data), .tx_valid(tx_valid), .tx_ready(tx_ready)
    );

    uart_tx #(.CLK_PER_BIT(12)) u_uart(   // 24 MHz / 12 = 2 Mbaud
        .clk(clk24), .rst_n(rst_n),
        .tx_data(tx_data), .tx_valid(tx_valid), .tx_ready(tx_ready),
        .tx(uart_tx)
    );
endmodule
