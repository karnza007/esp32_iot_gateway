// mic_stream.ino — the INMP441 read by the ESP32-S3, streamed to the Mac in the FPGA's frame
// format (docs/03-protocol.md, v3), so host/inmp441_viewer.py shows it unchanged.
//
// Used to check the microphone on its own (HDMI demo, step H3): live waveform + spectrum.
//
//   INMP441 VDD -> 3V3   GND -> GND   L/R -> GND
//           SCK -> GPIO4   WS -> GPIO5   SD -> GPIO6
//
// Sample rate 46,875 Hz: the viewer derives fs from the frame's cfg word, and this rate is
// one an FPGA build used (24 MHz / 64 / 8), so cfg = 24 MHz clock, BCLK_DIV 8, 1 channel.
// Sample = top 16 of the 24-bit left word, as on the FPGA.
// Frame: AA 55 A5 5A | seq | ovf=0 | cfg | hdrsum | 512 x int16 | checksum   (1038 bytes)
// Serial0 (CH9102), 2 Mbaud: 95 kB/s of the 200 kB/s available.
//
// Flash: arduino-cli compile --upload -b esp32:esp32:esp32s3:CDCOnBoot=cdc \
//            -p /dev/cu.wchusbserial* firmware/mic_stream
// View:  python host/inmp441_viewer.py
#include <Arduino.h>
#include <ESP_I2S.h>
#include "driver/gpio.h"

constexpr int PIN_SCK = 4, PIN_WS = 5, PIN_SD = 6;
constexpr uint32_t RATE = 46875;
constexpr uint16_t CFG  = (4u << 10) | (1u << 8) | 8u;   // 24 MHz code, 1 channel, BCLK_DIV 8
I2SClass i2s;
static int32_t raw[2 * 512];                               // left, right interleaved
static uint8_t frame[1038];

static void put16(uint8_t *p, uint16_t v) { p[0] = v; p[1] = v >> 8; }

void setup() {
  Serial0.setTxBufferSize(4096);
  Serial0.begin(2000000);
  i2s.setPins(PIN_SCK, PIN_WS, -1, PIN_SD);
  if (!i2s.begin(I2S_MODE_STD, RATE, I2S_DATA_BIT_WIDTH_32BIT, I2S_SLOT_MODE_STEREO)) {
    while (true) delay(1000);
  }
  gpio_set_drive_capability((gpio_num_t)PIN_SCK, GPIO_DRIVE_CAP_0);   // softer edges
  gpio_set_drive_capability((gpio_num_t)PIN_WS, GPIO_DRIVE_CAP_0);
  gpio_pulldown_en((gpio_num_t)PIN_SD);                               // datasheet pull-down
  frame[0] = 0xAA; frame[1] = 0x55; frame[2] = 0xA5; frame[3] = 0x5A;
}

void loop() {
  static uint16_t seq = 0;
  size_t want = sizeof raw, got = 0;
  while (got < want) got += i2s.readBytes((char *)raw + got, want - got);
  put16(frame + 4, seq++);
  put16(frame + 6, 0);                                     // no FIFO overflow here
  put16(frame + 8, CFG);
  uint16_t hs = 0;
  for (int i = 4; i < 10; i++) hs += frame[i];
  put16(frame + 10, hs);
  uint16_t cs = 0;
  for (int i = 0; i < 512; i++) {
    int16_t s = raw[2 * i] >> 16;                          // left slot, top 16 of 24 bits
    put16(frame + 12 + 2 * i, (uint16_t)s);
    cs += frame[12 + 2 * i] + frame[13 + 2 * i];
  }
  put16(frame + 1036, cs);
  Serial0.write(frame, sizeof frame);
}
