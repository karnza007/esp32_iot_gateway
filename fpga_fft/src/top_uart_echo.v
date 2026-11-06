// top_uart_echo.v — speed test for the Tang Nano 20K's USB serial port (the BL616 debugger chip).
// Whatever the Mac sends arrives on pin 70 and goes straight back out on pin 69, so
// host/uart_speed_test.py can compare what came back with what it sent, at several baud rates.
// No clock is involved: the FPGA is only a wire here. LED 0 lights while pin 70 is low (data).
//   DESIGN=echo fpga_fft/build.sh     (load into SRAM only; the demo in flash returns at power-on)
module top_uart_echo (
    input  wire clk,          // 27 MHz crystal, unused
    input  wire uart_rx,      // pin 70: from the Mac
    output wire uart_tx,      // pin 69: to the Mac
    output wire led0
);
    assign uart_tx = uart_rx;
    assign led0    = uart_rx;  // lit when low
endmodule
