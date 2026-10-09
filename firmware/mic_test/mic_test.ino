// mic_test.ino — is the INMP441 alive? Read it with the ESP32-S3's own I2S peripheral.
//
// Used when the microphone gave no data on the Tang Nano 20K (HDMI demo, step H3).
// The ESP32-S3 is the I2S master: it makes SCK and WS, and reads SD in BOTH time slots,
// so it also shows which slot the mic talks in (L/R at GND = left).
//
//   INMP441 VDD -> 3V3   GND -> GND   L/R -> GND
//           SCK -> GPIO4   WS -> GPIO5   SD -> GPIO6
//
// Twice a second it prints, per slot: RMS and peak level (on the same 16-bit scale the
// FPGA uses: the top 16 of the 24 bits), the share of non-zero words, and one raw word;
// for the left slot also the average (DC) and the correlation between neighbouring
// samples: real sound changes smoothly (close to +1), random garbage doesn't (close to 0).
// Every 4th report also lists 8 consecutive raw left words.
// Serial0 (the CH9102 USB port), 115200 baud.
//
// Flash: arduino-cli compile --upload -b esp32:esp32:esp32s3:CDCOnBoot=cdc \
//            -p /dev/cu.wchusbserial* firmware/mic_test
#include <Arduino.h>
#include <ESP_I2S.h>
#include "driver/gpio.h"

constexpr int PIN_SCK = 4, PIN_WS = 5, PIN_SD = 6;
constexpr uint32_t RATE = 48000;          // the INMP441 accepts 7.8-50 kHz frame rates
I2SClass i2s;
static int32_t buf[2 * 1024];             // interleaved left, right; 24-bit data in the top bits

void setup() {
  Serial0.begin(115200);
  delay(300);
  i2s.setPins(PIN_SCK, PIN_WS, -1, PIN_SD);  // no data out; data in on SD
  if (!i2s.begin(I2S_MODE_STD, RATE, I2S_DATA_BIT_WIDTH_32BIT, I2S_SLOT_MODE_STEREO)) {
    Serial0.println("I2S start FAILED");
    while (true) delay(1000);
  }
  // Signal-quality settings (after begin(), which configures the pins):
  //  - weakest output drive on SCK/WS: slower edges ring less on long jumper wires
  //  - pull-down on SD: the INMP441 lets SD float in the other channel's half (datasheet
  //    recommends a pull-down), so that half reads a clean 0 instead of noise
  gpio_set_drive_capability((gpio_num_t)PIN_SCK, GPIO_DRIVE_CAP_0);
  gpio_set_drive_capability((gpio_num_t)PIN_WS, GPIO_DRIVE_CAP_0);
  gpio_pulldown_en((gpio_num_t)PIN_SD);
  Serial0.println("mic_test: SCK=GPIO4 WS=GPIO5 SD=GPIO6, 48 kHz, 32-bit stereo, weak drive, SD pull-down");
}

void loop() {
  double sum[2] = {0, 0}, dc = 0, lag1 = 0;
  int32_t prev = 0;
  static uint32_t report = 0;
  int32_t first8[8] = {0};
  int32_t peak[2] = {0, 0}, raw[2] = {0, 0};
  uint32_t nz[2] = {0, 0}, n = 0;
  uint32_t t0 = millis();
  while (millis() - t0 < 500) {
    size_t got = i2s.readBytes((char *)buf, sizeof buf) / sizeof(int32_t);
    for (size_t i = 0; i + 1 < got; i += 2) {
      for (int ch = 0; ch < 2; ch++) {
        int32_t w = buf[i + ch];
        int32_t s16 = w >> 16;               // top 16 bits, like the FPGA at gain 0
        sum[ch] += (double)s16 * s16;
        if (abs(s16) > peak[ch]) peak[ch] = abs(s16);
        if (w != 0) { nz[ch]++; raw[ch] = w; }
        if (ch == 0) {
          dc += s16;
          lag1 += (double)s16 * prev;
          prev = s16;
          if (n < 8) first8[n] = w;
        }
      }
      n++;
    }
  }
  for (int ch = 0; ch < 2; ch++) {
    double rms = n ? sqrt(sum[ch] / n) : 0;
    Serial0.printf("%s rms %8.1f  peak %6ld  nonzero %5.1f%%  raw 0x%08lx  |", ch ? " RIGHT" : "LEFT ",
                   rms, (long)peak[ch], n ? 100.0 * nz[ch] / n : 0.0, (unsigned long)raw[ch]);
  }
  double ms = n ? sum[0] / n : 0;
  Serial0.printf("  DC %7.1f  neighbour corr %+.2f  (%lu frames)\n", n ? dc / n : 0.0,
                 ms > 0 ? (lag1 / n) / ms : 0.0, (unsigned long)n);
  if (++report % 4 == 0) {
    Serial0.print("   8 raw left words:");
    for (int i = 0; i < 8; i++) Serial0.printf(" %08lx", (unsigned long)first8[i]);
    Serial0.println();
  }
}
