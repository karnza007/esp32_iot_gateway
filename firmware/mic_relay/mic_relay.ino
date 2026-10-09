// mic_relay.ino — the ESP32-S3 reads the INMP441 and relays it to the Tang Nano 20K over UART.
//
// HDMI demo, step H3, "ESP32 relay" source: the mic's wiring to the ESP32 is proven, so the
// ESP32 collects the samples and the FPGA does the FFT and the display (fpga_fft/src/hdmi/
// relay_rx.v).
//
//   INMP441 VDD -> 3V3   GND -> GND   L/R -> GND   SCK -> GPIO4   WS -> GPIO5   SD -> GPIO6
//   ESP32 GPIO17 (TX) -> Tang Nano 20K pin 27   (the benchmark wire)
//
// PACKET, every 32 samples (48 kHz -> 1,500 packets/s):
//   B5 6A | seq | 32 x 24-bit sample, low byte first | sum16 of the 96 payload bytes (LE)
//   = 101 bytes. UART at 2,970,000 baud = 74.25 MHz / 25 on the FPGA side; the ESP32 makes it
//   to within 0.005 %. 1,500 x 101 x 10 bits = 1.52 Mbit/s: 51 % of the link.
// Serial0 (USB) prints a status line once a second: packets sent, the input level, and the
// correlation between neighbouring samples (real sound ~ +0.9..1, scrambled data ~ 0..0.5).
//
// Flash: arduino-cli compile --upload -b esp32:esp32:esp32s3:CDCOnBoot=cdc \
//            -p /dev/cu.wchusbserial* firmware/mic_relay
#include <Arduino.h>
#include <ESP_I2S.h>
#include "driver/gpio.h"

constexpr int PIN_SCK = 4, PIN_WS = 5, PIN_SD = 6, PIN_TX = 17, PIN_RX_UNUSED = 18;
constexpr uint32_t RATE = 48000, LINK_BAUD = 2970000;
constexpr int N = 32;
I2SClass i2s;
static int32_t raw[2 * N];
static uint8_t pkt[3 + 3 * N + 2];

void setup() {
  Serial0.begin(115200);
  Serial1.setTxBufferSize(4096);
  Serial1.begin(LINK_BAUD, SERIAL_8N1, PIN_RX_UNUSED, PIN_TX);
  i2s.setPins(PIN_SCK, PIN_WS, -1, PIN_SD);
  if (!i2s.begin(I2S_MODE_STD, RATE, I2S_DATA_BIT_WIDTH_32BIT, I2S_SLOT_MODE_STEREO)) {
    while (true) { Serial0.println("I2S start FAILED"); delay(1000); }
  }
  gpio_set_drive_capability((gpio_num_t)PIN_SCK, GPIO_DRIVE_CAP_0);   // softer edges
  gpio_set_drive_capability((gpio_num_t)PIN_WS, GPIO_DRIVE_CAP_0);
  gpio_pulldown_en((gpio_num_t)PIN_SD);                               // datasheet pull-down
  pkt[0] = 0xB5; pkt[1] = 0x6A;
  Serial0.printf("mic_relay: I2S 48 kHz on GPIO4/5/6 -> UART %lu baud on GPIO17\n",
                 (unsigned long)LINK_BAUD);
}

void loop() {
  static uint8_t seq = 0;
  static uint32_t sent = 0, t_last = 0;
  static double sq = 0, lag = 0;
  static uint32_t nsq = 0;
  static int32_t prev = 0;
  size_t want = sizeof raw, got = 0;
  while (got < want) got += i2s.readBytes((char *)raw + got, want - got);

  pkt[2] = seq++;
  uint16_t sum = 0;
  for (int i = 0; i < N; i++) {
    int32_t w = raw[2 * i] >> 8;                      // left slot: 24-bit signed sample
    uint8_t *p = pkt + 3 + 3 * i;
    p[0] = w; p[1] = w >> 8; p[2] = w >> 16;
    sum += p[0] + p[1] + p[2];
    int32_t s16 = w >> 8;                             // level on the 16-bit scale, for the log
    sq += (double)s16 * s16;
    lag += (double)s16 * prev;
    prev = s16;
    nsq++;
  }
  pkt[3 + 3 * N] = sum;
  pkt[4 + 3 * N] = sum >> 8;
  Serial1.write(pkt, sizeof pkt);
  sent++;

  if (millis() - t_last >= 1000) {
    t_last = millis();
    Serial0.printf("packets %lu  input rms %.1f (16-bit scale)  neighbour corr %+.3f\n",
                   (unsigned long)sent, nsq ? sqrt(sq / nsq) : 0.0, sq > 0 ? lag / sq : 0.0);
    sq = 0; lag = 0; nsq = 0;
  }
}
