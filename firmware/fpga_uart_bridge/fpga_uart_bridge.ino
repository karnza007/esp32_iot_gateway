// fpga_uart_bridge.ino — ESP32-S3 gateway between the FPGA and the host.
//
//   FPGA (Tang Nano 4K) pin 42 ──link 1──▶ ESP32-S3 GPIO18 (RX)
//   ESP32-S3 ──link 2──▶ host   (native USB by default; CH9102 still selectable)
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
constexpr uint32_t FPGA_BAUD   = 2000000;
constexpr uint32_t HOST_BAUD   = 2000000;   // link 2, CH9102 path only; USB has no baud

// Link 2 transport. Measured 2026-09-03 (docs/10-link2-transports.md):
//
//   CH9102 UART, best usable rate 4 Mbaud   390,031 B/s   0.0024 % lost
//   native USB                              969,619 B/s   0 lost in 29 MB
//
// Native USB is 2.5x faster and the only one of the two that lost nothing. The
// difference is structural, not a speed limit: a UART bridge has no back-pressure,
// so if the host is late those bytes are gone forever, whereas USB CDC makes the
// device wait. Every UART rate tested lost data at roughly one event every 7-10
// seconds REGARDLESS of throughput -- loss that tracks time, not bytes, which is
// the signature of a receiver being late rather than a link being full.
//
// It also deletes the baud-matching trap: there is no rate to agree on, and the
// CH9102 turned out to work only at 12 MHz / integer rates while reporting success
// at the others.
#define LINK2_UART0 0        // CH9102 bridge  -> /dev/cu.wchusbserial*
#define LINK2_USB   1        // native USB     -> /dev/cu.usbmodem*
constexpr int LINK2 = LINK2_USB;

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
static Print   *host = nullptr;     // link 2, whichever peripheral was selected

// diagnostic state
static uint32_t rx_bytes   = 0;    // bytes seen on link 1 since boot
static uint32_t sync_count = 0;    // FPGA sync words seen BY THIS BOARD
static uint8_t  matched    = 0;    // sync matcher state, carried across reads
static uint32_t hb         = 0;
static uint32_t last_ms    = 0;
static uint32_t last_bytes = 0;

void setup() {
  // Pick the peripheral by name rather than relying on the `Serial` alias, which
  // the core #defines to one or the other depending on the build options.
#if ARDUINO_USB_MODE && ARDUINO_USB_CDC_ON_BOOT
  if (LINK2 == LINK2_USB) { HWCDCSerial.begin(); host = &HWCDCSerial; }
  else                    { Serial0.begin(HOST_BAUD); host = &Serial0; }
#else
  Serial0.begin(HOST_BAUD); host = &Serial0;   // built without CDC on boot
#endif
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
        host->write(buf, r);                    // pump: forward verbatim
      }
    }
  }

  if (MODE_DIAG) {
    uint32_t now = millis();
    if (now - last_ms >= 500) {
      uint32_t rate = (uint32_t)((rx_bytes - last_bytes) * 1000ULL / (now - last_ms));
      host->printf("GWDIAG hb=%lu rx=%lu sync=%lu rate=%lu baud1=%lu baud2=%lu\n",
                    (unsigned long)hb++, (unsigned long)rx_bytes,
                    (unsigned long)sync_count, (unsigned long)rate,
                    (unsigned long)FPGA_BAUD, (unsigned long)HOST_BAUD);
      last_ms = now;
      last_bytes = rx_bytes;
    }
  }
}
