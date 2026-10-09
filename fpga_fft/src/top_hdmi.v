// top_hdmi.v — HDMI demo build (docs/plans/hdmi-demo.md). Step H1: colour test pattern.
//   DESIGN=hdmi fpga_fft/build.sh
//
//   27 MHz crystal ─▶ rPLL ×55÷4 ─▶ 371.25 MHz ─────────────▶ serializers only (fclk)
//                                       └─▶ CLKDIV ÷5 ─▶ 74.25 MHz (pclk) ─▶ the picture chain
//   27 MHz crystal ──────────────────────────────────────────▶ ESP32 UART benchmark (unchanged)
//
// The two halves share nothing but the crystal: the benchmark keeps working while the
// monitor shows the picture.
module top_hdmi (
    input  wire       clk,         // 27 MHz crystal, pin 4
    input  wire       uart_rx,     // ESP32 benchmark, unchanged
    output wire       uart_tx,
    output wire [5:0] led,
    output wire       tmds_clk_p, tmds_clk_n,
    output wire [2:0] tmds_d_p, tmds_d_n
);
    // ---- video clocks ----
    wire fclk, locked, pclk;
    pll_clk #(.MULT(55), .DIV(4), .ODIV(2)) u_pll (.clk27(clk), .clk_out(fclk), .locked(locked));
    CLKDIV #(.DIV_MODE("5")) u_div (.HCLKIN(fclk), .RESETN(locked), .CALIB(1'b0), .CLKOUT(pclk));

    // hold the picture chain in reset until the PLL has locked, plus 16 pixel clocks
    reg [4:0] vrst_cnt = 5'd0;
    always @(posedge pclk or negedge locked)
        if (!locked)            vrst_cnt <= 5'd0;
        else if (!vrst_cnt[4])  vrst_cnt <= vrst_cnt + 1'b1;
    wire vrst = !vrst_cnt[4];

    video_h1 u_video (.pclk(pclk), .fclk(fclk), .rst(vrst),
                      .tmds_clk_p(tmds_clk_p), .tmds_clk_n(tmds_clk_n),
                      .tmds_d_p(tmds_d_p), .tmds_d_n(tmds_d_n));

    // ---- ESP32 benchmark on the crystal, exactly as in top.v ----
    wire [5:0] led_link;
    fft_link #(.CLK_MHZ(27)) u_link (
        .clk(clk), .clk_ok(1'b1), .uart_rx(uart_rx), .uart_tx(uart_tx), .led(led_link));

    // LEDs (lit when low): 0-4 as in the benchmark, 5 = video PLL locked
    assign led = {~locked, led_link[4:0]};
endmodule
