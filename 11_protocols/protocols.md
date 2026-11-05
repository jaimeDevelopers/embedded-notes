# 11. Protocols and Communications for Embedded Systems

Target: STM32F746ZG (NUCLEO-F746ZG), C, with a PC (Ubuntu, Python) at the other end. Prerequisites: chapter 7 (peripherals), chapter 10 (electrical side), chapter 5 (C).

**Verification note.** Register-level details and peripheral specifics (CAN, USB, Ethernet) are from memory of RM0385 and the ST middleware; code is illustrative, **not compiled or run on your board**. Always confirm with the reference manual and with a logic analyzer.

---

## 1. Thinking in layers

```
 Application   what the messages mean (commands, telemetry, files)
 Session       connections, retries, acknowledgements, sequence numbers
 Framing       where a message starts and ends (delimiters, length), integrity (CRC)
 Link          how bytes move between two nodes (UART, SPI, I2C, CAN, USB)
 Physical      voltages, connectors, cables (chapter 10)
```

Most firmware bugs in communications are **framing** (resync after garbage), **timeouts/retries**, **buffer overflows** and **concurrency** (ISR vs main), not the peripheral configuration.

### Design vocabulary

| Term | Meaning |
|---|---|
| Master/slave (controller/peripheral) | One side starts every exchange (SPI, I2C, Modbus) |
| Peer/multi-master | Any node may transmit (CAN, Ethernet) |
| Synchronous/asynchronous | Shared clock (SPI, I2C) vs agreed baud rate (UART) |
| Full/half duplex | Both directions at once vs alternating |
| Point-to-point/bus | Two nodes vs many on shared wires |
| Request-response/streaming/publish-subscribe | Interaction patterns |
| Idempotent | Repeating a request has no extra effect (essential with retries) |
| ACK/NACK, sequence number, timeout, retry, back-off | Reliability tools |

---

## 2. Framing, integrity and robust parsing

### 2.1 Framing methods

| Method | How | Pros | Cons |
|---|---|---|---|
| Fixed-size frames | Every message has the same length | Simplest | Inflexible, loses sync on a lost byte |
| **Length-prefixed** | `[len][payload]` | Efficient | One corrupted length breaks sync until a timeout/CRC check |
| **Delimiter + escaping** (SLIP, HDLC byte-stuffing) | Special byte ends a frame; escape it in data | Easy resync | Variable overhead |
| **COBS** (consistent overhead byte stuffing) | Removes all `0x00` bytes from data; `0x00` is the delimiter | Resync at every `0x00`, bounded overhead (≤ 1 byte per 254) | Slight CPU cost |
| Timing gaps (Modbus RTU: 3.5 character silence) | Idle line separates frames | No special bytes | Needs precise timers, fragile |
| Text lines (`\n`-terminated, AT commands, NMEA) | Human-readable | Easy to debug | Verbose, slower to parse |

Recommendation for custom links: **COBS + CRC16/CRC32**, with a version field and a sequence number.

### 2.2 Error detection

| Check | Strength | Use |
|---|---|---|
| Parity bit | 1 bit | UART legacy |
| Checksum (sum/XOR) | Weak (misses many errors) | Tiny, non-critical |
| **CRC-16** (CCITT, Modbus) | Good for frames up to a few hundred bytes | Standard choice |
| **CRC-32** | Better for large data | Files, firmware images |
| Hash/HMAC/signature | Integrity **and** authenticity | Security (chapter 16) |

CRC is for **accidents**, not attackers.

CRC-16/CCITT-FALSE (polynomial `0x1021`, init `0xFFFF`, no reflection):

```c
uint16_t crc16_ccitt(const uint8_t *d, size_t n)
{
    uint16_t crc = 0xFFFFu;
    while (n--) {
        crc ^= (uint16_t)(*d++) << 8;
        for (int i = 0; i < 8; i++) {
            crc = (crc & 0x8000u) ? (uint16_t)((crc << 1) ^ 0x1021u) : (uint16_t)(crc << 1);
        }
    }
    return crc;
}
```

CRC-16/MODBUS (reflected polynomial `0xA001`, init `0xFFFF`; sent **low byte first**):

```c
uint16_t crc16_modbus(const uint8_t *d, size_t n)
{
    uint16_t crc = 0xFFFFu;
    while (n--) {
        crc ^= *d++;
        for (int i = 0; i < 8; i++) { crc = (crc & 1u) ? (uint16_t)((crc >> 1) ^ 0xA001u) : (uint16_t)(crc >> 1); }
    }
    return crc;
}
```

Know the **CRC parameters** (width, polynomial, init, reflect in/out, xor out) of any CRC you use; "CRC-16" alone is ambiguous. Verify with the standard check string `"123456789"`: CRC-16/CCITT-FALSE gives `0x29B1`, CRC-16/MODBUS gives `0x4B37`.

### 2.3 COBS

```c
/* Encodes len bytes of 'in' into 'out'. out must hold at least len + len/254 + 1 bytes.
   Returns the encoded length (without the 0x00 delimiter, which the caller appends). */
size_t cobs_encode(const uint8_t *in, size_t len, uint8_t *out)
{
    size_t read = 0, write = 1, code_idx = 0;
    uint8_t code = 1;
    while (read < len) {
        if (in[read] == 0u) {
            out[code_idx] = code; code = 1; code_idx = write++; read++;
        } else {
            out[write++] = in[read++]; code++;
            if (code == 0xFFu) { out[code_idx] = code; code = 1; code_idx = write++; }
        }
    }
    out[code_idx] = code;
    return write;
}

/* Returns decoded length, or 0 on error. out needs room for the decoded data (<= len). */
size_t cobs_decode(const uint8_t *in, size_t len, uint8_t *out)
{
    size_t read = 0, write = 0;
    while (read < len) {
        uint8_t code = in[read];
        if (code == 0u || read + code > len) { return 0u; }
        read++;
        for (uint8_t i = 1; i < code; i++) { out[write++] = in[read++]; }
        if (code != 0xFFu && read < len) { out[write++] = 0u; }
    }
    return write;
}
```

(An empty payload encodes as the single byte `0x01`. Test both functions on the host against a known implementation, with fuzzing: chapter 14.)

### 2.4 A complete small protocol

Wire format, per frame:

```
 COBS( [ver:1][type:1][seq:1][len:1][payload: len bytes][crc16: 2 (little-endian, over ver..payload)] ) 0x00
```

Message types: `PING`, `PONG`, `GET_PARAM`, `SET_PARAM`, `PARAM_VALUE`, `TELEMETRY`, `LOG`, `ERROR`. Rules: unknown `ver` or `type` yields `ERROR`; every request carries a `seq` and the reply repeats it; requests are idempotent or deduplicated by `seq`; the maximum frame size is fixed.

Receiver as a state machine fed one byte at a time (from an ISR ring buffer or a DMA+IDLE drain):

```c
#define RX_MAX 128u

typedef struct {
    uint8_t  buf[RX_MAX];
    uint16_t n;
    bool     overflow;
} rx_frame_t;

typedef void (*frame_handler_t)(const uint8_t *msg, size_t len);

void rx_feed(rx_frame_t *r, uint8_t b, frame_handler_t on_frame)
{
    if (b != 0u) {                                   /* inside a frame */
        if (r->n < RX_MAX) { r->buf[r->n++] = b; } else { r->overflow = true; }
        return;
    }
    /* delimiter: a complete frame (or garbage) ended here */
    if (!r->overflow && r->n >= 6u) {                /* minimum encoded size, adjust */
        uint8_t msg[RX_MAX];
        size_t m = cobs_decode(r->buf, r->n, msg);
        if (m >= 6u) {
            uint16_t crc_rx = (uint16_t)(msg[m - 2] | ((uint16_t)msg[m - 1] << 8));
            if (crc16_ccitt(msg, m - 2u) == crc_rx && msg[0] == PROTO_VERSION) {
                on_frame(msg, m - 2u);
            }                                       /* else: count a CRC error, ignore */
        }
    }
    r->n = 0u; r->overflow = false;                 /* resynchronized at every delimiter */
}
```

Properties worth noticing: constant memory, no dynamic allocation, **self-resynchronizing** after any garbage, bad frames are dropped, handlers get only validated frames.

Reliability layer when needed: the sender stores the last request; if no reply within `T`, it retransmits (max N times, with back-off) and finally reports a failure. The receiver of a duplicate request (same `seq`) replays the previous reply instead of re-executing.

### 2.5 PC side in Python

```python
import serial, struct
from cobs import cobs                   # pip install cobs
import binascii

def crc16_ccitt(data: bytes) -> int:
    return binascii.crc_hqx(data, 0xFFFF)          # CCITT-FALSE: poly 0x1021, init 0xFFFF

def make_frame(msg_type: int, seq: int, payload: bytes = b"") -> bytes:
    body = struct.pack("<BBBB", 1, msg_type, seq, len(payload)) + payload
    body += struct.pack("<H", crc16_ccitt(body))
    return cobs.encode(body) + b"\x00"

with serial.Serial("/dev/ttyACM0", 115200, timeout=0.5) as s:
    s.write(make_frame(1, 7))                       # PING
    raw = s.read_until(b"\x00")[:-1]
    reply = cobs.decode(raw)
    print(reply.hex(), crc16_ccitt(reply[:-2]) == struct.unpack("<H", reply[-2:])[0])
```

(`binascii.crc_hqx(data, 0xFFFF)` implements CRC-16/CCITT-FALSE; verify against the check string above.)

---

## 3. UART / USART

### 3.1 Frame

```
idle(1) | start(0) | d0 ... d7 (LSB first) | [parity] | stop(1 or 2) | idle
```

Typical `8N1` at 115200 baud: 10 bits per byte, so **about 11.5 kB/s**. Both sides must agree on baud (error under ~2 %), data bits, parity and stop bits. The receiver samples in the middle of each bit (16x oversampling) and resynchronizes at the start bit.

### 3.2 Features of the STM32 USART

| Feature | Notes |
|---|---|
| Baud generator | `BRR = f_clk / baud` (16x oversampling) |
| Hardware flow control | RTS/CTS lines; or XON/XOFF in software |
| Driver Enable (DE) | Controls an RS-485 transceiver's direction automatically (`CR3.DEM`) |
| IDLE line detection | Interrupt when the line is quiet after a burst: ideal for variable-length messages with DMA |
| Receiver timeout, character match | Detect a delimiter or silence in hardware |
| LIN, IrDA, smartcard, synchronous mode | Specialty |
| Errors | Overrun (ORE), framing (FE), noise (NE), parity (PE): count them |

### 3.3 Receive strategies (increasing quality)

| Strategy | Pros | Cons |
|---|---|---|
| Polling `RXNE` | Trivial | Misses bytes if the loop is slow |
| Interrupt per byte into a ring buffer | Simple, robust at low rates | ISR load at high rates |
| **DMA circular + IDLE interrupt** | Minimal CPU, no byte loss, process whole bursts | More setup, cache coherency |
| DMA + half-transfer/complete interrupts | Fixed-size blocks | Latency for short messages |

Chapter 7 shows code for the first three. For high rates always check and **count overruns**.

### 3.4 RS-485

Half-duplex differential bus, up to 32+ nodes and ~1 km at low speed: one transceiver (MAX485/SN65HVD) with `DE/RE` controlled by firmware or by the USART's DE signal; **120 Ω termination at both ends** and bias resistors for the idle state. Protocol on top (Modbus RTU, custom): one master asks, one slave answers; slaves must keep the line released otherwise.

### 3.5 Console tips

Use `picocom -b 115200 /dev/ttyACM0`; `\r\n` line ends; remember `printf` buffering; and keep logging out of ISRs (chapters 5, 8).

---

## 4. SPI

### 4.1 Signals and modes

`SCK`, `MOSI` (controller out), `MISO` (controller in), `CS` (chip select, active low, one per device). Data moves **in both directions at once**: every transmitted byte also receives one.

| Mode | CPOL (idle clock) | CPHA (sampling edge) |
|---|---|---|
| 0 | 0 (low) | 0 (first/rising edge samples) |
| 1 | 0 | 1 (second/falling edge samples) |
| 2 | 1 (high) | 0 |
| 3 | 1 | 1 |

The device datasheet states the mode it needs and its **maximum clock**, **CS setup/hold times**, and whether data is MSB or LSB first. Mode 0 and 3 are the most common.

### 4.2 Typical transaction (register read)

```
CS low | command byte (address | read bit) | dummy/clock out N bytes | CS high
```

Many devices require CS to stay low for the whole transaction; some need a minimum CS-high time between transactions.

### 4.3 STM32 notes

- Configure `CPOL/CPHA`, baud divider (`BR`), 8-bit data size (`DS`), software NSS (`SSM`, `SSI`) and a GPIO for CS.
- On the F7 set `FRXTH` for 8-bit reads and access the data register with **byte-wide** reads/writes; 16-bit access with 8-bit frames sends two frames.
- Wait for `BSY = 0` before raising CS.
- Use DMA for blocks; check cache coherency (chapter 3).
- Fast SPI (tens of MHz) needs good layout and short wires; add series resistors (chapter 10).

### 4.4 Variants

Dual/Quad SPI (QSPI memory-mapped Flash on the F7), daisy-chained devices (shift registers, LED drivers), 3-wire SPI (shared data pin), SPI with data-ready/interrupt lines (sensors), and "SPI as a protocol" for displays (D/C pin).

### 4.5 Common SPI problems

| Symptom | Likely cause |
|---|---|
| All zeros or all ones | Wrong mode, no CS, MISO floating, no common ground |
| Data shifted by a bit | Wrong CPHA |
| Works slowly only | Wires too long, clock above the device limit |
| Works until another device is on the bus | Device not releasing MISO when CS is high |
| Random corruption | CS toggled early (BSY), ISR touching the same SPI without a lock |

---

## 5. I2C

### 5.1 Basics

Two open-drain lines, `SCL` and `SDA`, with pull-ups; each device has a **7-bit address** (or 10-bit). Speeds: 100 kHz (standard), 400 kHz (fast), 1 MHz (fast mode plus), 3.4 MHz (high speed).

Write transaction: `START | addr(7)+W | ACK | reg | ACK | data | ACK | STOP`.
Read transaction: `START | addr+W | ACK | reg | ACK | REPEATED START | addr+R | ACK | data | master NACK | STOP`.

| Concept | Notes |
|---|---|
| **7-bit vs 8-bit addresses** | Datasheets quote either; Linux/Zephyr/most HALs use the 7-bit form (e.g. `0x48`); some HALs expect it shifted left (`0x90`). Check which |
| ACK/NACK | A NACK after the address means no device (or busy); after data means "no more" |
| Clock stretching | A slave may hold SCL low to slow the master; the master must wait (support and timeouts) |
| Repeated start | Change direction without releasing the bus |
| Arbitration | Multi-master collision handling |
| **Bus stuck** | A slave holding SDA low after an interrupted transfer: clock SCL up to 9 times, then generate STOP |
| Pull-ups | From chapter 10: `Rp(max) = t_r / (0.8473 * C_bus)`, `Rp(min) = (VDD - 0.4 V)/3 mA` |
| SMBus/PMBus | Stricter I2C variants (timeouts, PEC CRC) |

### 5.2 STM32F7 specifics

The F7 I2C peripheral is the "new" type controlled by **`TIMINGR`** (prescaler, setup/hold, SCL high/low). Use the table in RM0385 for the I2C kernel clock you have, or STM32CubeMX's calculator, and record the value together with the clock assumption. Flow: set `SADD`, `NBYTES`, `RD_WRN`, `AUTOEND`, `START`; for each byte wait `TXIS`/`RXNE`; handle `NACKF`, `STOPF`, `BERR`, `ARLO`; always use timeouts.

```c
/* Bus recovery sketch: after a failed transfer, release the peripheral and clock the bus manually */
void i2c_bus_recover(GPIO_TypeDef *port, unsigned scl, unsigned sda)
{
    /* configure SCL as open-drain output, SDA as input with pull-up (plain GPIO) */
    for (int i = 0; i < 9 && !gpio_read(port, sda); i++) {
        gpio_clear(port, scl); delay_us(5);
        gpio_set(port, scl);   delay_us(5);
    }
    /* generate a STOP: SDA low then high while SCL high, then reinitialize the I2C peripheral */
}
```

### 5.3 Device drivers over I2C (pattern)

Write a `bus_t` abstraction (chapter 8) with `read_reg/write_reg`; drivers parse registers (watch **endianness** of 16-bit registers and signed values: two's complement); read all bytes of a multi-byte value in a single transaction (auto-increment) so the value does not change in between.

### 5.4 Scanner

```c
for (uint8_t a = 0x08; a < 0x78; a++) {
    if (i2c_probe(a) == ST_OK) { printf("found 0x%02X\r\n", a); }
}
```

(`i2cdetect -y 1` on Linux, `i2c scan` in the Zephyr shell, a logic analyzer decoder on the PC.)

---

## 6. CAN (and CAN FD)

### 6.1 Concepts

Multi-master, differential, **message-based** (no node addresses; messages have an **identifier** that also sets priority: lower ID wins arbitration without data loss). Frame: ID (11-bit standard or 29-bit extended), RTR/DLC, up to 8 data bytes (classic) or 64 (CAN FD), CRC, ACK. Hardware handles arbitration, bit stuffing, CRC and retransmission.

| Item | Notes |
|---|---|
| Bit rate | 125 kbit/s, 250, 500, 1 Mbit/s (classic); FD has faster data phase |
| **Bit timing** | `bit time = (1 + TS1 + TS2)` time quanta; `baud = f_can / (prescaler * (1 + TS1 + TS2))`; **sample point** `(1 + TS1) / (1 + TS1 + TS2)`, usually 80-87.5 % |
| Termination | 120 Ω at each end of the bus |
| Filters/masks | Hardware accept filters to reduce CPU load |
| Error handling | Error counters (TEC/REC) and states: error-active, error-passive, **bus-off** (recover deliberately) |
| Higher layers | CANopen, J1939, ISO-TP (multi-frame), UDS (diagnostics), proprietary |

Example (APB1 at 54 MHz, 500 kbit/s): prescaler 6, 18 time quanta (`TS1 = 14`, `TS2 = 3`): `54e6 / (6 * 18) = 500 kHz`, sample point `15/18 = 83 %`. Compute and check against the RM and the bus; use a tool that reports the real bit time.

The F746 has the **bxCAN** peripheral (CAN1-CAN3, with shared filter banks); a transceiver chip is required. On Linux use SocketCAN with a USB-CAN adapter and `can-utils`:

```bash
sudo ip link set can0 up type can bitrate 500000
candump can0
cansend can0 123#DEADBEEF
```

---

## 7. USB

### 7.1 Essentials

- **Host** (controller) vs **device** (peripheral); the STM32F746 has **OTG FS** (full-speed, 12 Mbit/s, integrated PHY) and **OTG HS** (high-speed 480 Mbit/s needs an external ULPI PHY); the Nucleo exposes the FS controller on its USB user connector (verify in UM1974).
- **Enumeration**: the host resets the device, reads **descriptors** (device, configuration, interface, endpoint, strings), assigns an address, selects a configuration. Wrong descriptors are the usual reason a device is not recognized.
- **Endpoint types**: control (EP0, setup), bulk (reliable, no latency guarantee), interrupt (small periodic), isochronous (audio/video, no retries).
- **Classes**: **CDC ACM** (virtual serial port: simplest way to get a fast console and data link), HID (keyboard/mouse/gamepads), MSC (mass storage), DFU (firmware update), audio, vendor-specific (WinUSB/libusb).
- Needs a **48 MHz clock** exact within tolerance (from PLLQ, chapter 7); ID and VBUS pins; D+/D- routing.
- Identifiers: **VID/PID** pairs: for development use test IDs or your own; selling products needs a USB-IF vendor ID or a sub-licensed PID (e.g. from pid.codes for open-source hardware).

### 7.2 Software stacks

| Stack | Notes |
|---|---|
| ST USB Device middleware (STM32Cube) | Included with the HAL; many examples |
| **TinyUSB** | Open-source, portable, device and host, STM32 support |
| Zephyr `usbd` | New device stack with CDC ACM, MSC, HID |
| RTOS vendor stacks | Azure RTOS USBX |

Typical first project: **CDC ACM echo**: the board appears as `/dev/ttyACM1` (separate from the ST-LINK's VCP), the PC sends text, firmware echoes it. Debug with `dmesg -w`, `lsusb -v`, Wireshark's USB capture (`usbmon`), and the logic analyzer for D+/D-.

---

## 8. Ethernet and TCP/IP

### 8.1 On the Nucleo-F746ZG

The F746 includes an Ethernet MAC; the board has an RJ45 and an external **PHY (RMII)**. You need the MAC driver, the PHY driver, a TCP/IP stack and memory for descriptors/buffers (placed in SRAM that DMA can reach; cache coherency matters: chapter 3, or use non-cacheable regions).

### 8.2 TCP/IP stacks

| Stack | Notes |
|---|---|
| **lwIP** | The standard lightweight stack: raw API (callbacks), netconn/sockets API (with an RTOS), `NO_SYS` mode for bare metal |
| Zephyr networking | IPv4/IPv6, sockets, DHCP, DNS, TLS, MQTT, HTTP |
| FreeRTOS+TCP, NetX Duo | Alternatives |

### 8.3 Concepts to know

```
MAC address / IP / subnet / gateway / DNS / DHCP
ARP, ICMP (ping), UDP (datagrams, no connection), TCP (stream, handshake, retransmit, windowing)
Ports: TCP/UDP 1-65535; client vs server; sockets
```

TCP is a **byte stream**, not messages: a single `send` of 100 bytes may arrive as 60 + 40; you must frame messages above it (length prefix or delimiter). UDP preserves datagram boundaries but not delivery or order.

Minimal sockets-style server flow (RTOS/sockets API):

```c
int s = socket(AF_INET, SOCK_STREAM, 0);
bind(s, (struct sockaddr *)&addr, sizeof addr);   /* port 7 for an echo service */
listen(s, 1);
for (;;) {
    int c = accept(s, NULL, NULL);
    char buf[128]; int n;
    while ((n = recv(c, buf, sizeof buf, 0)) > 0) { send(c, buf, n, 0); }
    close(c);
}
```

### 8.4 Tools

```bash
ping 192.168.1.50
nc 192.168.1.50 7                # type text, see the echo
nc -u 192.168.1.50 5000          # UDP
sudo tcpdump -i eth0 host 192.168.1.50
wireshark                        # GUI capture and analysis
iperf3 -c 192.168.1.50           # throughput
nmap -p 1-1024 192.168.1.50      # open ports
```

### 8.5 Application protocols

| Protocol | Notes |
|---|---|
| **MQTT** | Publish/subscribe through a **broker**; topics (`site/device/sensor`), QoS 0/1/2, retained messages, last-will; tiny overhead; ideal for IoT telemetry. Test with `mosquitto` (`mosquitto_pub`, `mosquitto_sub`) |
| **HTTP/REST** | Request/response; JSON; easy but heavier |
| **CoAP** | REST-like over UDP for constrained devices |
| **TLS** (mbedTLS, wolfSSL) | Encryption/authentication; needs RAM (tens of KB), entropy (TRNG), certificates, correct time/clock |
| **SNTP** | Time sync |
| **mDNS** | `device.local` names |
| **WebSocket**, **gRPC** | Specialized |

### 8.6 Practical advice

- Use **DHCP** by default, with a static fallback; show the obtained IP on the console.
- Size buffers deliberately; memory exhaustion (pbufs) is the usual failure mode: count drops.
- Never block the network thread; do heavy work in other tasks.
- Add timeouts to every socket operation and **keepalive** to detect dead peers.
- Keep security in mind from the start (chapter 16): do not expose unauthenticated control ports to a network.

---

## 9. Industrial and field protocols

### 9.1 Modbus

Master-slave, simple, very common in industry. Variants: **RTU** (binary over RS-485/RS-232, CRC-16 Modbus, frames delimited by 3.5 characters of silence), **ASCII**, **TCP** (MBAP header over TCP port 502, no CRC).

RTU frame: `[slave addr:1][function:1][data:n][CRC16 lo][CRC16 hi]`. Common functions: `0x03` read holding registers, `0x04` read input registers, `0x06` write single register, `0x10` write multiple registers, `0x01/0x05/0x0F` coils. Registers are 16-bit big-endian; addresses may be 0- or 1-based depending on documentation. Tools: `modpoll`, `pymodbus`, QModMaster.

### 9.2 Others to recognize

| Protocol | Context |
|---|---|
| CANopen, J1939, DeviceNet | CAN-based industrial and vehicle networks |
| PROFINET, EtherCAT, EtherNet/IP | Industrial Ethernet |
| LIN | Low-cost automotive single-wire bus (USART-based) |
| 1-Wire (DS18B20) | Single-pin sensors, timing-critical |
| DMX512, DALI | Lighting |
| NMEA 0183 | GPS text sentences over UART |
| SD/SDIO/SDMMC, eMMC | Storage (FAT, LittleFS) |

### 9.3 Wireless (overview)

BLE (GATT services, advertising, connection intervals), Wi-Fi (modules such as ESP32 as a co-processor via UART AT commands/SPI or as the main MCU), LoRa/LoRaWAN (long range, low rate), Zigbee/Thread/Matter (mesh), sub-GHz radios. Typically handled with a certified module or a vendor stack; read the radio's duty-cycle and regulatory limits.

---

## 10. Reliability patterns

- **Timeouts everywhere**; every wait ends.
- **Retries with limits and back-off**, then report failure and move to a safe state.
- **Sequence numbers** and idempotent commands; reject duplicates.
- **Flow control**: UART RTS/CTS, application-level credits, or windowed ACKs; never let a fast sender overflow a slow receiver.
- **Bounded buffers**, drop policy defined, drop counters exposed.
- **Resynchronization**: delimiter-based framing or timeouts that reset the parser.
- **Heartbeats** to detect dead links; **watchdog** coupled to progress.
- **Version** your protocol; ignore unknown optional fields; reject unknown critical ones.
- **Validate everything** from the wire: length fields, ranges, enums (never trust the length: check against the buffer).
- **Separate parsing from policy**: a pure parser function is testable and fuzzable on the PC (chapter 14).
- **Diagnostics**: counters for CRC errors, framing errors, overruns, timeouts, retransmits.
- **Security**: authenticate and encrypt when the network is not trusted (chapter 16).

---

## 11. Tools and techniques

| Need | Tool |
|---|---|
| See the bits on the wire | Logic analyzer with decoders (UART, SPI, I2C, CAN) |
| UART from the PC | `picocom`, `minicom`, `tio`, `pyserial`; `socat` to bridge serial and TCP |
| CAN on Linux | SocketCAN, `can-utils` (`candump`, `cansend`, `cangen`), `python-can` |
| USB analysis | `lsusb -v`, `dmesg`, Wireshark with `usbmon`, `libusb`/`pyusb` scripts |
| Network | `ping`, `nc`, `tcpdump`, Wireshark, `iperf3`, `nmap`, `scapy` |
| MQTT | `mosquitto` broker and clients, MQTT Explorer |
| Modbus | `modpoll`, `pymodbus`, QModMaster |
| Protocol simulation | Python scripts, mock devices on the PC with `socat` pty pairs |
| Fuzzing | libFuzzer/AFL++ on the parser (chapter 14) |

Virtual serial port pair for testing PC software without hardware:

```bash
socat -d -d pty,raw,echo=0 pty,raw,echo=0      # prints two /dev/pts/N; connect one program to each
```

---

## 12. Exercises

1. **CRC check**: implement `crc16_ccitt` and `crc16_modbus`, verify with the `"123456789"` check strings on the PC (C and Python), then compare with the STM32 CRC unit for CRC32.
2. **COBS**: implement encode/decode and test with round-trip, zero-heavy data, 254/255-byte runs, and random buffers under sanitizers.
3. **Frame parser**: build `rx_feed()` (section 2.4), feed it garbage, truncated frames, bad CRCs, oversize frames; show it recovers.
4. **UART protocol**: implement the protocol on the Nucleo's VCP with DMA+IDLE reception; write a Python client with request/response timeouts and retries; measure throughput and error counters.
5. **Overrun lab**: send data faster than the firmware handles; observe overruns; fix with DMA.
6. **SPI with a logic analyzer**: connect an SPI device or a loopback (MOSI to MISO); capture all four modes and decode them.
7. **I2C sensor**: read a sensor with your `bus_t` abstraction; scan the bus; measure rise times with and without different pull-ups.
8. **Bus recovery**: hold SDA low with a jumper mid-transfer, run the recovery routine, and verify the bus works again.
9. **CAN loopback**: use the bxCAN loopback/silent mode to test without a bus, then connect two nodes (or a USB-CAN adapter) and use `candump`.
10. **USB CDC**: implement a CDC echo with TinyUSB or the ST stack; check enumeration with `lsusb -v`.
11. **TCP echo server** with lwIP (or Zephyr), tested with `nc` and `wireshark`; add a length-prefixed message layer.
12. **MQTT**: publish telemetry to `mosquitto` and subscribe from the PC; test QoS 1 with a dropped connection.
13. **Modbus RTU slave** with a few holding registers and CRC; read it with `modpoll` through a USB-RS485 adapter.
14. **Fuzzing**: fuzz the parser with a libFuzzer harness and fix every crash.
15. **Protocol document**: write a one-page specification (framing, types, error handling, version) of your protocol, and implement a conformance test script.

---

## 13. Cheat sheet

| Bus | Wires | Speed | Topology | Addressing | Notes |
|---|---|---|---|---|---|
| UART | TX, RX (+RTS/CTS) | up to several Mbaud | Point to point | none | Async, needs baud agreement |
| RS-485 | A, B | up to ~10 Mbit/s (short) | Multi-drop | By protocol | Differential, termination, DE |
| SPI | SCK, MOSI, MISO, CS | up to tens of MHz | One master, many CS | CS pin | Full duplex, no ACK |
| I2C | SCL, SDA | 0.1-1 MHz | Multi-device bus | 7-bit address | Open-drain, pull-ups |
| CAN | CANH, CANL | up to 1 Mbit/s (FD more) | Multi-master bus | Message ID | Termination 120 Ω |
| USB FS | D+, D- | 12 Mbit/s | Host-device | Enumeration | 48 MHz clock |
| Ethernet | RMII + PHY | 10/100 Mbit/s | Switched | MAC/IP | TCP/IP stack |

```
Framing:        COBS + 0x00 delimiter, [ver][type][seq][len][payload][crc16]
UART throughput:  baud / 10 bytes/s (8N1)
I2C Rp:          Rp(max)=tr/(0.8473*Cb); Rp(min)=(Vdd-0.4)/3mA
CAN baud:        f_can/(prescaler*(1+TS1+TS2)) ; sample point (1+TS1)/(1+TS1+TS2)
Always:          timeouts, counters, resync, versioning, bounds checks
```

---

## 14. Where this leads

- **FreeRTOS** (chapter 12): tasks and queues around UART/CAN/network drivers; stream buffers for UART RX.
- **Python tooling** (chapter 17): clients, loggers, test fixtures.
- **Testing** (chapter 14): host tests, fuzzing, and HIL for protocols.
- **Security** (chapter 16): authenticated and encrypted links, TLS, signed updates.
- **Linux** (chapter 22): the other end of many embedded links (sockets, SocketCAN, serial).

## References

- NXP UM10204: I2C-bus specification; Motorola/Freescale SPI descriptions in device datasheets
- Bosch CAN specification; ISO 11898; *A Comprehensive Guide to CAN* (TI/NXP application notes)
- USB 2.0 specification; *USB Complete*, Jan Axelson; TinyUSB documentation: <https://docs.tinyusb.org>
- lwIP documentation: <https://www.nongnu.org/lwip/>
- COBS: Cheshire and Baker, *Consistent Overhead Byte Stuffing*
- Modbus organization specifications: <https://modbus.org>
- MQTT 3.1.1/5.0 specifications (OASIS); Eclipse Mosquitto
- Catalogue of CRC parameters: <https://reveng.sourceforge.io/crc-catalogue/>