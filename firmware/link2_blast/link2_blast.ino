// link2_blast.ino — measure link 2's real capacity, one transport at a time.
//
// WHAT THIS MEASURES, AND WHY IT IS SEPARATE FROM THE AUDIO PATH
//   Link 2 is the ESP32 -> host connection. Its capacity has to be known before we
//   can say whether it, or link 1, or neither, limits the chain. But the loudest
//   thing we can put into it is two INMP441s at 190 kB/s, which is only ~16 % of
//   what native USB should manage. Audio simply cannot fill it.
//
//   So this sketch removes the FPGA from the picture entirely and generates its own
//   load: it writes a counting pattern as fast as the chosen link will accept, and
//   the HOST measures how much actually arrives. Nothing else runs.
//
// TWO OUTPUTS, CHOSEN BY NAME -- NOT BY THE `Serial` ALIAS
//   The ESP32-S3 has several independent serial peripherals. In the Arduino core
//   (esp32 3.3.11, cores/esp32/HardwareSerial.h) they are separate objects:
//
//     Serial0       hardware UART0 on pins 43/44 -> CH9102 chip -> /dev/cu.wchusbserial*
//     Serial1       hardware UART1, any pins (GPIO18 here) -> the FPGA
//     HWCDCSerial   the chip's built-in USB Serial/JTAG -> /dev/cu.usbmodem*
//
//   `Serial` is only an ALIAS. The core does, literally:
//
//     #if ARDUINO_USB_CDC_ON_BOOT
//       #if ARDUINO_USB_MODE
//         #define Serial HWCDCSerial      // native USB
//       #else
//         #define Serial USBSerial        // TinyUSB
//       #endif
//     #else
//       #define Serial Serial0            // UART0 -> CH9102
//     #endif
//
//   `Serial0` is declared unconditionally, and `HWCDCSerial` whenever the board is
//   built with USB CDC On Boot = Enabled in hardware-CDC mode. So building with
//   CDCOnBoot=cdc gives us BOTH objects in one binary, and this sketch picks one by
//   name. That is the whole answer to "how do you separate the data": you do not
//   separate a stream, you write to a different peripheral.
//
// BUILD
//   arduino-cli compile --upload -b esp32:esp32:esp32s3:CDCOnBoot=cdc \
//               -p /dev/cu.wchusbserial... firmware/link2_blast
//   Uploading still happens over UART0, so the flashing port does not change.

#include <Arduino.h>

// ---------------------------------------------------------------- configuration
#define TARGET_UART0 0        // CH9102 bridge  -> /dev/cu.wchusbserial*
#define TARGET_USB   1        // native USB     -> /dev/cu.usbmodem*

constexpr int      BLAST_TARGET = TARGET_USB;
constexpr uint32_t UART0_BAUD   = 2000000;
constexpr size_t   CHUNK        = 512;       // bytes per write() call

// Throttle, so two transports can be compared AT THE SAME DATA RATE.
//
// The first comparison was unfair: the CH9102 was tested at 200 kB/s and native
// USB at 962 kB/s, so USB was carrying 4.8x more. It lost 1.92 % under host load
// and the UART lost nothing -- but that cannot separate "USB is more fragile" from
// "anything near its ceiling is more fragile".
//
// 0 = flat out. Otherwise, wait until the next CHUNK is due, so the offered rate
// is TARGET_BPS regardless of what the link could manage.
constexpr uint32_t TARGET_BPS = 0;

// The pattern counts modulo 251, NOT 256.
//
// It has to be self-checking: the host knows every byte must be exactly one more
// than the last, so a discontinuity is loss and the size of the jump says how many
// bytes went missing. Speed without integrity is not a measurement -- this project
// has already seen a link carry its full byte rate while delivering zero usable
// frames.
//
// But a byte counter wrapping at 256 is blind to a loss of exactly 256 bytes, or
// 512, or 1024 -- the sequence looks perfectly continuous across it. Those are
// precisely the sizes serial buffers come in, so the blind spot sits exactly where
// the losses would be. 251 is prime: a loss is invisible only if it is a multiple
// of 251, and no buffer is. The pattern stays self-aligning (each byte still says
// what the next must be), so there is no phase to recover.
// 16-BIT COUNTER, little-endian, two bytes per step.
//
// The mod-251 byte counter proved the loss existed but could not size it: a loss
// of L bytes read as L mod 251, so 128 and 379 were indistinguishable. That
// ambiguity is exactly what stops us choosing between the two hypotheses --
//
//   H-A  the CH9102's UART FIFO overflows because the host is late
//        -> the chunk size should scale with the data rate
//   H-B  a USB transfer is occasionally lost
//        -> the chunk should be a multiple of 64 bytes and rate-independent
//
// -- so the counter is widened. Losses up to 131,070 bytes are now sized exactly.
// The value repeats every 65536 steps = 131072 bytes, far beyond any plausible
// single event.
static uint16_t next_val = 0;
static uint8_t  buf[CHUNK];

static Stream *out = nullptr;

void setup() {
  for (size_t i = 0; i < CHUNK; i += 2) { buf[i] = 0; buf[i+1] = 0; }  // refilled in loop()

  if (BLAST_TARGET == TARGET_USB) {
#if ARDUINO_USB_MODE && ARDUINO_USB_CDC_ON_BOOT
    HWCDCSerial.begin();
    out = &HWCDCSerial;
#else
#error "TARGET_USB needs CDCOnBoot=cdc (USB CDC On Boot: Enabled) in hardware CDC mode"
#endif
  } else {
    Serial0.begin(UART0_BAUD);
    out = &Serial0;
  }
}

static uint32_t next_due_us = 0;

void loop() {
  if (TARGET_BPS) {
    const uint32_t period = (uint32_t)((1000000ULL * CHUNK) / TARGET_BPS);
    uint32_t now = micros();
    if ((int32_t)(next_due_us - now) > 0) return;      // not yet time
    next_due_us = (next_due_us == 0 ? now : next_due_us) + period;
  }
  // Refill with the continuing sequence, then hand the whole chunk over. write()
  // blocks until the link accepts it, so the loop runs exactly as fast as link 2
  // allows -- which is the quantity being measured. No timing is done here on
  // purpose: the device can only see how fast its own buffer drains, whereas the
  // host sees what actually arrived, and the host is what the viewer will be.
  for (size_t i = 0; i < CHUNK; i += 2) {
    buf[i]     = (uint8_t)(next_val & 0xFF);       // little-endian
    buf[i + 1] = (uint8_t)(next_val >> 8);
    next_val++;
  }
  out->write(buf, CHUNK);
}
