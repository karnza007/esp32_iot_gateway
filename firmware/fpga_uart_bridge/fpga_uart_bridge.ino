// fpga_uart_bridge.ino — transparent UART -> USB-CDC pump for the INMP441 demo.
//
//   FPGA (Tang Nano 4K) pin 42 ──UART 2,000,000 8N1──▶ ESP32-S3 GPIO18 (RX)
//   ESP32-S3 ──USB-CDC──▶ host  inmp441_viewer.py
//
// The FPGA already emits complete framed packets (4-byte sync AA 55 A5 5A + 512
// little-endian int16 samples), so this firmware just forwards bytes verbatim.
//
// Arduino IDE setup:
//   Board:            ESP32S3 Dev Module
//   USB CDC On Boot:  Disabled  <-- this board talks through a CH9102 UART bridge,
//                                   so `Serial` = UART0 (the wchusbserial port).
//   Upload Speed:     921600
// Wiring: FPGA pin 42 -> ESP32 GPIO18, and a common GND between the two boards.

#include <Arduino.h>

constexpr int      FPGA_RX_PIN = 18;        // ESP32-S3 GPIO <- FPGA UART TX (pin 42)
constexpr int      FPGA_TX_PIN = 17;        // unused (no data back to the FPGA)
constexpr uint32_t FPGA_BAUD   = 2000000;   // must match uart_tx (24 MHz / CLK_PER_BIT)

static uint8_t buf[1024];

void setup() {
  Serial.begin(921600);                     // UART0 -> CH9102 -> host (must match viewer BAUD)
  Serial1.begin(FPGA_BAUD, SERIAL_8N1, FPGA_RX_PIN, FPGA_TX_PIN);
}

void loop() {
  int n = Serial1.available();
  if (n > 0) {
    if (n > (int)sizeof(buf)) n = sizeof(buf);
    int r = Serial1.read(buf, n);
    if (r > 0) {
      Serial.write(buf, r);
    }
  }
}
