// fft_bench.ino — ESP32-S3 side of the FFT benchmark (docs/11-fft-benchmark.md).
//
// The host sends an int16 complex signal; this board runs ESP-DSP's 16-bit
// integer FFT on it, times it, and sends the spectrum back for scoring.
//
//   Mac (host/fft_bench.py) ──CH9102, 2 Mbaud──▶ Serial0 ──▶ dsps_fft2r_sc16
//                           ◀────────────────── result + cycle counts
//
// It is also the go-between for the FPGA (Tang Nano 20K, fpga_fft/src/top.v):
//
//   Mac ──2 Mbaud──▶ Serial0 ─▶ Serial1 GPIO17 ──1 Mbaud──▶ FPGA pin 27
//   Mac ◀─────────── Serial0 ◀─ Serial1 GPIO18 ◀──────────── FPGA pin 28
//
// THE FFT
//   dsps_fft2r_sc16 is ESP-DSP's radix-2 FFT on int16 data. On the S3 the header
//   maps it to dsps_fft2r_sc16_aes3, the version written for the S3's vector
//   (SIMD) instructions. It halves the data every stage -- (x + 0x7fff) >> 16
//   after a Q15 multiply -- so its output is FFT(x) / N, the same scaling as the
//   Gowin core's RS111. It leaves the result in bit-reversed order, so
//   dsps_bit_rev_sc16_ansi puts it back in natural order: the FPGA outputs natural
//   order, so that step belongs in a fair time comparison and is timed too.
//
// PROTOCOL (little-endian; host/fft_bench.py must match)
//   request   "FFTQ"  cmd:u8  log2n:u8  rsv:u16  payload  sum:u16
//   reply     "FFTR"  status:u8  log2n:u8  has_payload:u8  rsv:u8
//             fft_min:u32  fft_avg:u32  extra:u32  clk_mhz:u32  [payload]  sum:u16
//   cmd   'L' = run the FFT here (dsps_fft2r_sc16 -> the S3 SIMD version)
//         'A' = run the plain-C version (dsps_fft2r_sc16_ansi), same library
//         'E' = pass the signal to the FPGA, which echoes it back (F2; N = 1024 only)
//         'P' = ping (no payload either way)
//   payload   N x (re:int16, im:int16) = 4N bytes;  sum = byte sum of payload
//   fft_min/avg  cycles of the FFT, in clocks of clk_mhz (ESP32 CPU, or FPGA 27 MHz)
//   extra     'L'/'A': bit-reverse cycles.  FPGA commands: ESP32<->FPGA round trip, us
//   status    0 ok, 1 bad checksum, 2 bad size, 3 bad command, 4 FFT error,
//             5 FPGA did not reply, 6 data reached the FPGA corrupted,
//             7 FPGA's reply arrived corrupted, 8 FPGA rejected the command
//
// TIMING
//   The CPU cycle counter is read around each call. The FFT works in place, so
//   it runs REPEATS times, each on a fresh copy of the input; fft_min is the
//   cleanest run (no interrupt landed in it), fft_avg the typical one.
//
// Flash:  arduino-cli compile --upload -b esp32:esp32:esp32s3:CDCOnBoot=cdc \
//             -p /dev/cu.wchusbserial* firmware/fft_bench

#include <Arduino.h>
#include "esp_dsp.h"
#include "esp_cpu.h"

constexpr uint32_t HOST_BAUD = 2000000;        // CH9102: proven lossless at 2 Mbaud
constexpr int      MAX_LOG2N = 12;             // 4096, ESP-DSP's table limit
constexpr int      MAX_N     = 1 << MAX_LOG2N;
constexpr int      REPEATS   = 20;

// FPGA link: the FFT core is fixed at 1024 points; 27 MHz / 27 = 1 Mbaud exactly.
constexpr uint32_t FPGA_BAUD    = 1000000;
constexpr int      FPGA_RX_PIN  = 18;          // <- FPGA pin 28 (its TX)
constexpr int      FPGA_TX_PIN  = 17;          // -> FPGA pin 27 (its RX)
constexpr int      FPGA_LOG2N   = 10;
constexpr uint32_t FPGA_CLK_MHZ = 27;

// The S3's vector instructions load 16 bytes at a time and need 16-byte alignment.
alignas(16) static int16_t input[2 * MAX_N];
alignas(16) static int16_t work[2 * MAX_N];

static const uint8_t REQ_MAGIC[4] = {'F', 'F', 'T', 'Q'};
static const uint8_t REP_MAGIC[4] = {'F', 'F', 'T', 'R'};

static bool dsp_ready = false;

// Blocking read with a timeout, so a half-sent request can never wedge the board.
static bool read_exact(HardwareSerial &s, uint8_t *dst, size_t len, uint32_t timeout_ms = 2000) {
  uint32_t t0 = millis();
  size_t got = 0;
  while (got < len) {
    int a = s.available();
    if (a > 0) {
      got += s.read(dst + got, min((size_t)a, len - got));
      t0 = millis();                           // timeout is per stall, not total
    } else if (millis() - t0 > timeout_ms) {
      return false;
    }
  }
  return true;
}

static uint16_t byte_sum(const uint8_t *p, size_t len) {
  uint16_t s = 0;
  for (size_t i = 0; i < len; i++) s += p[i];
  return s;
}

static void put_u32(uint8_t *p, uint32_t v) {
  p[0] = v; p[1] = v >> 8; p[2] = v >> 16; p[3] = v >> 24;
}

static void reply(uint8_t status, uint8_t log2n, uint32_t fft_min, uint32_t fft_avg,
                  uint32_t extra, uint32_t clk_mhz, const int16_t *data, int n) {
  uint8_t hdr[24];
  memcpy(hdr, REP_MAGIC, 4);
  hdr[4] = status; hdr[5] = log2n; hdr[6] = data ? 1 : 0; hdr[7] = 0;
  put_u32(hdr + 8, fft_min);
  put_u32(hdr + 12, fft_avg);
  put_u32(hdr + 16, extra);
  put_u32(hdr + 20, clk_mhz);
  Serial0.write(hdr, sizeof hdr);
  size_t len = data ? 4 * (size_t)n : 0;
  if (len) Serial0.write((const uint8_t *)data, len);
  uint16_t s = data ? byte_sum((const uint8_t *)data, len) : 0;
  uint8_t tail[2] = {(uint8_t)s, (uint8_t)(s >> 8)};
  Serial0.write(tail, 2);
  Serial0.flush();
}

// Hunt for "FFTQ" byte by byte, so leftover junk on the line is skipped, not misread.
static bool find_magic() {
  uint8_t m = 0;
  uint32_t t0 = millis();
  while (millis() - t0 < 50) {
    if (!Serial0.available()) continue;
    uint8_t b = Serial0.read();
    m = (b == REQ_MAGIC[m]) ? m + 1 : (b == REQ_MAGIC[0] ? 1 : 0);
    if (m == 4) return true;
    t0 = millis();
  }
  return false;
}

// One request/reply with the FPGA (protocol: header of fpga_fft/src/top.v).
// Sends input[] (1024 points), receives into work[]. Returns a status code.
static uint8_t fpga_exchange(char cmd, uint32_t &cycles, uint32_t &round_us) {
  const size_t len = 4u << FPGA_LOG2N;
  while (Serial1.available()) Serial1.read();  // drop anything stale
  const uint8_t hdr[3] = {0xA5, 0x5A, (uint8_t)cmd};
  uint32_t t0 = micros();
  Serial1.write(hdr, 3);
  Serial1.write((const uint8_t *)input, len);

  uint8_t m = 0;                               // hunt for the reply's 5A A5
  uint32_t tw = millis();
  while (m < 2) {
    if (millis() - tw > 200) return 5;
    if (!Serial1.available()) continue;
    uint8_t b = Serial1.read();
    m = (b == (m ? 0xA5 : 0x5A)) ? m + 1 : (b == 0x5A ? 1 : 0);
  }
  uint8_t h[7], tail[2];                       // status, cycles:u32, rx_sum:u16
  if (!read_exact(Serial1, h, 7, 50)) return 5;
  if (h[0] == 0 && !read_exact(Serial1, (uint8_t *)work, len, 50)) return 5;
  if (!read_exact(Serial1, tail, 2, 50)) return 5;
  round_us = micros() - t0;
  cycles = h[1] | h[2] << 8 | h[3] << 16 | (uint32_t)h[4] << 24;
  if (h[0] != 0) return 8;
  if ((uint16_t)(h[5] | h[6] << 8) != byte_sum((const uint8_t *)input, len)) return 6;
  if ((uint16_t)(tail[0] | tail[1] << 8) != byte_sum((const uint8_t *)work, len)) return 7;
  return 0;
}

void setup() {
  Serial0.setRxBufferSize(4 * MAX_N + 64);     // a whole request fits: must precede begin()
  Serial0.setTxBufferSize(1024);
  Serial0.begin(HOST_BAUD);
  Serial1.setRxBufferSize((4 << FPGA_LOG2N) + 64);
  Serial1.begin(FPGA_BAUD, SERIAL_8N1, FPGA_RX_PIN, FPGA_TX_PIN);
  // Twiddle table for the largest size; every smaller size reuses it.
  dsp_ready = dsps_fft2r_init_sc16(NULL, MAX_N) == ESP_OK;
}

void loop() {
  if (!Serial0.available() || !find_magic()) return;

  uint8_t hdr[4];
  if (!read_exact(Serial0, hdr, 4)) return;
  uint8_t cmd = hdr[0], log2n = hdr[1];

  const uint32_t mhz = getCpuFrequencyMhz();
  const bool to_fpga = (cmd == 'E');
  if (cmd == 'P') { reply(dsp_ready ? 0 : 4, MAX_LOG2N, 0, 0, 0, mhz, nullptr, 0); return; }
  if (cmd != 'L' && cmd != 'A' && !to_fpga) { reply(3, log2n, 0, 0, 0, mhz, nullptr, 0); return; }
  if (log2n < 2 || log2n > MAX_LOG2N || (to_fpga && log2n != FPGA_LOG2N)) {
    reply(2, log2n, 0, 0, 0, mhz, nullptr, 0);
    return;
  }

  const int n = 1 << log2n;
  const size_t len = 4 * (size_t)n;
  uint8_t tail[2];
  if (!read_exact(Serial0, (uint8_t *)input, len) || !read_exact(Serial0, tail, 2)) return;
  if (byte_sum((uint8_t *)input, len) != (uint16_t)(tail[0] | tail[1] << 8)) {
    reply(1, log2n, 0, 0, 0, mhz, nullptr, 0);
    return;
  }

  if (to_fpga) {
    uint32_t cycles = 0, round_us = 0;
    uint8_t st = fpga_exchange(cmd, cycles, round_us);
    reply(st, log2n, cycles, cycles, round_us, FPGA_CLK_MHZ, st == 0 ? work : nullptr, n);
    return;
  }

  uint32_t best = UINT32_MAX;
  uint64_t total = 0;
  esp_err_t err = ESP_OK;
  for (int r = 0; r < REPEATS; r++) {
    memcpy(work, input, len);                  // fresh input every run: FFT is in place
    uint32_t c0 = esp_cpu_get_cycle_count();
    err = (cmd == 'A') ? dsps_fft2r_sc16_ansi(work, n) : dsps_fft2r_sc16(work, n);
    uint32_t c = esp_cpu_get_cycle_count() - c0;
    if (c < best) best = c;
    total += c;
  }
  uint32_t c0 = esp_cpu_get_cycle_count();
  dsps_bit_rev_sc16_ansi(work, n);             // to natural order, like the FPGA
  uint32_t bitrev = esp_cpu_get_cycle_count() - c0;

  reply(err == ESP_OK ? 0 : 4, log2n, best, (uint32_t)(total / REPEATS), bitrev, mhz, work, n);
}
