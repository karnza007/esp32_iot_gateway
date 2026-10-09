// hdmi_out.v — colour + sync in, four differential HDMI pin pairs out.
//
//   blue  (+ HSYNC, VSYNC) ─ encoder ─ 10 bits ─ OSER10 ─ TLVDS_OBUF ─ data 0  (pins 35/36)
//   green                  ─ encoder ─ 10 bits ─ OSER10 ─ TLVDS_OBUF ─ data 1  (pins 37/38)
//   red                    ─ encoder ─ 10 bits ─ OSER10 ─ TLVDS_OBUF ─ data 2  (pins 39/40)
//   pixel clock            ─ 1111100000         ─ OSER10 ─ TLVDS_OBUF ─ clock   (pins 33/34)
//
// OSER10 is Gowin's serializer, built into the pin's I/O block: it takes 10 bits once
// per pixel (PCLK, 74.25 MHz) and sends them one by one, D0 first, on both edges of
// FCLK (371.25 MHz = 5 x PCLK, two bits per FCLK period = 10 bits per pixel). Only these
// four blocks run at FCLK. TLVDS_OBUF drives each bit as a differential pair (P and N).
// The clock lane sends 5 ones then 5 zeros per pixel: a square wave at the pixel rate.
module hdmi_out (
    input  wire       pclk,        // pixel clock, 74.25 MHz
    input  wire       fclk,        // 5 x pixel clock, 371.25 MHz
    input  wire       rst,
    input  wire [7:0] r, g, b,
    input  wire       de, hs, vs,
    output wire       tmds_clk_p, tmds_clk_n,
    output wire [2:0] tmds_d_p, tmds_d_n
);
    wire [9:0] q_b, q_g, q_r;
    tmds_encoder enc_b (.clk(pclk), .rst(rst), .d(b), .c0(hs),   .c1(vs),   .de(de), .q(q_b));
    tmds_encoder enc_g (.clk(pclk), .rst(rst), .d(g), .c0(1'b0), .c1(1'b0), .de(de), .q(q_g));
    tmds_encoder enc_r (.clk(pclk), .rst(rst), .d(r), .c0(1'b0), .c1(1'b0), .de(de), .q(q_r));

    wire [9:0] word [0:3];
    assign word[0] = q_b;
    assign word[1] = q_g;
    assign word[2] = q_r;
    assign word[3] = 10'b1111100000;

    wire [3:0] ser;
    genvar k;
    generate
        for (k = 0; k < 4; k = k + 1) begin : lane
            OSER10 u_ser (
                .Q(ser[k]),
                .D0(word[k][0]), .D1(word[k][1]), .D2(word[k][2]), .D3(word[k][3]), .D4(word[k][4]),
                .D5(word[k][5]), .D6(word[k][6]), .D7(word[k][7]), .D8(word[k][8]), .D9(word[k][9]),
                .PCLK(pclk), .FCLK(fclk), .RESET(rst));
        end
    endgenerate

    TLVDS_OBUF buf_d0  (.I(ser[0]), .O(tmds_d_p[0]), .OB(tmds_d_n[0]));
    TLVDS_OBUF buf_d1  (.I(ser[1]), .O(tmds_d_p[1]), .OB(tmds_d_n[1]));
    TLVDS_OBUF buf_d2  (.I(ser[2]), .O(tmds_d_p[2]), .OB(tmds_d_n[2]));
    TLVDS_OBUF buf_clk (.I(ser[3]), .O(tmds_clk_p),  .OB(tmds_clk_n));
endmodule
