// fpga_uart_bridge.ino — ESP32-S3 gateway between the FPGA and the host.
//
//   FPGA (Tang Nano 4K) pin 42 ──link 1──▶ ESP32-S3 GPIO18 (RX)
//   ESP32-S3 ──link 2 (UART0 → CH9102 → USB)──▶ host
//
// TWO LINKS, TWO BAUD RATES, EACH SET IN TWO PLACES:
//   link 1  FPGA -> ESP32 :  FPGA_BAUD here  ==  SYS_CLK_MHZ / CLK_PER_BIT in top.v
//   link 2  ESP32 -> host :  HOST_BAUD here  ==  --baud in inmp441_viewer.py
// A mismatch on either link makes every byte unreadable and looks exactly like a
// dead wire. Change both ends together, and remember editing is not uploading:
// `arduino-cli upload` alone re-flashes a cached binary — use `compile --upload`.
//
// Arduino IDE: ESP32S3 Dev Module, USB CDC On Boot: Disabled (Serial = UART0).

#include <Arduino.h>

// ---------------------------------------------------------------- configuration
constexpr int      FPGA_RX_PIN = 18;        // ESP32-S3 GPIO <- FPGA UART TX (pin 42)
constexpr int      FPGA_TX_PIN = 17;        // unused (no data back to the FPGA)
constexpr uint32_t FPGA_BAUD   = 2000000;   // link 1: must match SYS_CLK_MHZ / CLK_PER_BIT in top.v
constexpr uint32_t HOST_BAUD   = 2000000;   // link 2: must match --baud in inmp441_viewer.py

// 0 = pump (normal operation), 1 = diagnostic.
//
// WHY A DIAGNOSTIC MODE EXISTS
//   When a link is pushed past its speed limit, both failures look identical at
//   the host: bytes arrive and nothing decodes. The gateway forwards whatever it
//   received, faithfully — so if it received garbage it forwards garbage, and the
//   host cannot tell whether the garbage was created before or after this board.
//
//   The gateway is the only place that knows. In diagnostic mode it stops
//   forwarding, checks link 1 ITSELF by counting the FPGA's sync words, and
//   reports in short plain-text lines over link 2. A readable GWDIAG line is
//   proof that link 2 works, whatever link 1 is doing:
//
//     lines readable, sync counting up  ->  both links fine
//     lines readable, sync == 0         ->  LINK 1 has failed
//     no lines at all                   ->  LINK 2 has failed
//
//   Interleaving a heartbeat into the normal stream was considered and rejected:
//   each insertion splits the frame in flight, injecting ~3.4 % artificial loss
//   into every measurement.
constexpr int MODE_DIAG = 0;

// Link 1 can run at 400,000 B/s or more. The default 256-byte receive buffer is
// only ~640 us of slack at that rate, so a scheduling hiccup in the loop below
// would look exactly like a link-speed limit. 4 KB is ~10 ms.
constexpr size_t RX_BUFFER = 4096;

constexpr uint8_t SYNC[4] = {0xAA, 0x55, 0xA5, 0x5A};

static uint8_t buf[1024];

// diagnostic state
static uint32_t rx_bytes   = 0;    // bytes seen on link 1 since boot
static uint32_t sync_count = 0;    // FPGA sync words seen BY THIS BOARD
static uint8_t  matched    = 0;    // sync matcher state, carried across reads
static uint32_t hb         = 0;
static uint32_t last_ms    = 0;
static uint32_t last_bytes = 0;

void setup() {
  Serial.begin(HOST_BAUD);                  // link 2: UART0 -> CH9102 -> host
  Serial1.setRxBufferSize(RX_BUFFER);       // must precede begin()
  Serial1.begin(FPGA_BAUD, SERIAL_8N1, FPGA_RX_PIN, FPGA_TX_PIN);
  last_ms = millis();
}

void loop() {
  int n = Serial1.available();
  if (n > 0) {
    if (n > (int)sizeof(buf)) n = sizeof(buf);
    int r = Serial1.read(buf, n);
    if (r > 0) {
      if (MODE_DIAG) {
        rx_bytes += r;
        for (int i = 0; i < r; i++) {           // sync matcher, stateful across chunks
          if (buf[i] == SYNC[matched]) {
            if (++matched == 4) { sync_count++; matched = 0; }
          } else {
            matched = (buf[i] == SYNC[0]) ? 1 : 0;
          }
        }
      } else {
        Serial.write(buf, r);                   // pump: forward verbatim
      }
    }
  }

  if (MODE_DIAG) {
    uint32_t now = millis();
    if (now - last_ms >= 500) {
      uint32_t rate = (uint32_t)((rx_bytes - last_bytes) * 1000ULL / (now - last_ms));
      Serial.printf("GWDIAG hb=%lu rx=%lu sync=%lu rate=%lu baud1=%lu baud2=%lu\n",
                    (unsigned long)hb++, (unsigned long)rx_bytes,
                    (unsigned long)sync_count, (unsigned long)rate,
                    (unsigned long)FPGA_BAUD, (unsigned long)HOST_BAUD);
      last_ms = now;
      last_bytes = rx_bytes;
    }
  }
}
