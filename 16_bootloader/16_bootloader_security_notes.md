# 16. Bootloaders, Over-the-Air Updates, and Embedded Security

Prerequisites: chapter 0 (CRC, startup, linker), chapter 3 (VTOR, reset), chapter 8 (bootloader overview), chapter 11 (protocols), chapter 14 (testing).

**Verification and safety note.** Flash programming, option bytes and read-out protection can **brick a board** (RDP level 2 is irreversible). Code below is illustrative, **not run on your board**; register names come from memory of RM0385 and must be checked. Test on a spare board, keep the SWD path available, and **never enable RDP level 2 while learning**. This chapter is engineering guidance, not a security certification or legal advice.

---

## 1. Why a bootloader

A bootloader is a small program that runs first, decides what to run, and (optionally) updates the main application. Reasons:

- **Field updates** without a debugger (UART, USB, CAN, Ethernet, wireless).
- **Integrity checks** before running code (CRC, signature).
- **Recovery**: a corrupted application must not brick the device.
- **Security**: only authentic images run; keys and secrets stay protected.
- **Production**: factory programming, calibration data, serial numbers.

Without any of these, the debugger and `st-flash` are enough (the earlier chapters).

---

## 2. How an STM32F7 boots

### 2.1 Boot sources

At reset the core reads the **initial SP and reset vector from the boot address**. On the STM32F7 the boot address is set by **BOOT0 pin** and option bytes (`BOOT_ADD0` / `BOOT_ADD1`):

| BOOT0 | Boots from (default settings) |
|---|---|
| 0 | User flash at `0x08000000` (via the AXIM bus; the same flash is aliased at `0x00200000` on the ITCM bus) |
| 1 | System memory: **ST's ROM bootloader** (UART/USB DFU/CAN/I2C/SPI depending on device: see **AN2606** for the F74x/F75x entry pins and supported interfaces) |

(On the Nucleo, BOOT0 is wired low by default, jumper/solder bridge options exist: UM1974.)

### 2.2 The ROM bootloader (system memory)

ST's built-in bootloader can program flash over UART, USB DFU, CAN, I2C or SPI **without** any firmware of yours: useful for recovery and for factory programming. Examples:

```bash
sudo apt install dfu-util
dfu-util -l                                            # list DFU devices (BOOT0=1, USB cable to the OTG FS port)
dfu-util -a 0 -s 0x08000000:leave -D build/blink.bin   # program and run
```

or `STM32CubeProgrammer` (GUI/CLI). It does not verify signatures: **disable/limit it in secure products** (RDP, boot configuration).

### 2.3 Your own bootloader

```
0x08000000  [ bootloader ]   starts first, checks images, jumps
0x08010000  [ settings   ]   boot flags, counters, config (two copies)
0x08020000  [ application ]  header + vector table + code
```

The application is a normal program linked at its own address, with its own vector table.

---

## 3. Flash organization and programming

### 3.1 STM32F746 flash facts

- 1 MB in **sectors of different sizes**: 4 x 32 KB (`0x08000000`-`0x0801FFFF`), 1 x 128 KB (`0x08020000`), 3 x 256 KB (`0x08040000`, `0x08080000`, `0x080C0000`).
- You can only **write 1 → 0** by programming; to get 1s back you must **erase a whole sector** (everything becomes `0xFF`).
- Erase is slow (up to seconds for a 256 KB sector) and endurance is limited (about 10 000 cycles: check the datasheet).
- The F746 has a **single flash bank**: while erasing or programming, **code execution from flash stalls** (interrupt handlers in flash cannot run). Run the flash driver and any critical ISR from **RAM/ITCM** (`.ramfunc`, chapter 19) or accept the stall.
- The programming parallelism (`PSIZE`: x8, x16, x32, x64) depends on the supply voltage range (x32 at 2.7-3.6 V).
- **Option bytes** hold RDP level, write protection, boot addresses, BOR level, watchdog options; changing them needs a separate unlock and `OPTSTRT`, and some changes trigger a system reset.

### 3.2 Flash driver sketch (verify every register and bit in RM0385)

```c
#include "stm32f7xx.h"
#include <stdbool.h>

static bool flash_wait(void) { uint32_t t = 2000000u; while (FLASH->SR & FLASH_SR_BSY) { if (--t == 0u) return false; } return true; }

static void flash_unlock(void)
{
    if (FLASH->CR & FLASH_CR_LOCK) {
        FLASH->KEYR = 0x45670123u;                  /* key 1 */
        FLASH->KEYR = 0xCDEF89ABu;                  /* key 2 */
    }
}
static void flash_lock(void) { FLASH->CR |= FLASH_CR_LOCK; }

/* Erase sector number 0..7 (F746 layout). Place this function in RAM (e.g. __attribute__((section(".ramfunc")))) */
bool flash_erase_sector(unsigned sector)
{
    flash_unlock();
    if (!flash_wait()) { return false; }
    FLASH->CR = (FLASH->CR & ~(FLASH_CR_SNB | FLASH_CR_PSIZE))
              | FLASH_CR_SER | (sector << FLASH_CR_SNB_Pos) | FLASH_CR_PSIZE_1;   /* PSIZE x32 */
    FLASH->CR |= FLASH_CR_STRT;
    bool ok = flash_wait();
    FLASH->CR &= ~FLASH_CR_SER;
    flash_lock();
    return ok && !(FLASH->SR & (FLASH_SR_WRPERR | FLASH_SR_PGAERR | FLASH_SR_PGPERR | FLASH_SR_ERSERR));
}

/* Program 32-bit words; address must be word aligned and the target erased */
bool flash_program(uint32_t addr, const uint32_t *data, size_t words)
{
    flash_unlock();
    FLASH->CR = (FLASH->CR & ~FLASH_CR_PSIZE) | FLASH_CR_PSIZE_1 | FLASH_CR_PG;
    for (size_t i = 0; i < words; i++) {
        if (!flash_wait()) { break; }
        *(volatile uint32_t *)(addr + 4u * i) = data[i];
        __DSB();
    }
    bool ok = flash_wait();
    FLASH->CR &= ~FLASH_CR_PG;
    flash_lock();
    return ok;
}
```

Rules: clear error flags before starting (`FLASH->SR = ...` write 1 to clear), **verify by reading back** after programming, check the sector is erased before programming, never program the same word twice without an erase, **never run flash operations from the sector being modified** (code in the same flash stalls), disable data cache effects by invalidating (`SCB_InvalidateDCache_by_Addr` for the region) if the D-cache is on, and make power loss during these operations survivable (section 5).

Alternatives: STM32 HAL's `HAL_FLASH_Unlock/Program/Erase` or Zephyr's flash driver and `flash_map` API; read how they handle `PSIZE` and errors.

---

## 4. Application image format

### 4.1 Header

```c
#define IMAGE_MAGIC 0x31574346u            /* "FCW1" little-endian */

typedef struct __attribute__((packed)) {
    uint32_t magic;
    uint16_t header_version;               /* layout of this header */
    uint16_t header_size;
    uint32_t image_size;                   /* bytes of the image following the header */
    uint32_t load_addr;                    /* where the vector table must be (for sanity checks) */
    uint32_t fw_version;                   /* major<<24 | minor<<16 | patch<<8 | build */
    uint32_t min_version;                  /* anti-rollback floor (optional) */
    uint8_t  git_hash[8];
    uint32_t crc32;                        /* over the image bytes (not the header) */
    uint8_t  signature[64];                /* ECDSA/Ed25519 signature (section 8), optional */
    uint32_t header_crc;                   /* over the header up to this field */
} image_header_t;
```

Design rules:

- **Fixed, versioned layout**, little-endian, all fields explicit-width.
- **Header placed in front of the vector table** (the app is linked at `ORIGIN + sizeof(header)`, with `VTOR` pointing to the vector table after the header, 512-byte aligned).
- Validate **everything** before use: magic, sizes within bounds, address ranges, CRC, version policy.
- The **header is written last** (after the image bytes are programmed and verified): an interrupted update leaves a missing header, not a half-valid image.

### 4.2 Linking the application at an offset

In the application's linker script:

```ld
MEMORY { FLASH (rx) : ORIGIN = 0x08020200, LENGTH = 896K - 0x200 ; RAM (xrw) : ORIGIN = 0x20000000, LENGTH = 320K }
```

(`0x08020000` is the start of the application sector; the first `0x200` bytes hold the header; the vector table sits right after.) In `system_stm32f7xx.c` set `USER_VECT_TAB_ADDRESS` and `VECT_TAB_OFFSET` (or `SCB->VTOR = APP_VECTORS`) so interrupts use the application's table. The bootloader's own linker script places it at `0x08000000` with `LENGTH = 64K`.

### 4.3 Building and stamping the image

```python
#!/usr/bin/env python3
# tools/make_image.py : build the final image = header + firmware binary
import argparse, struct, zlib

MAGIC = 0x31574346
p = argparse.ArgumentParser()
p.add_argument("bin_in"); p.add_argument("bin_out")
p.add_argument("--version", required=True, help="major.minor.patch")
p.add_argument("--load-addr", type=lambda x: int(x, 0), default=0x08020200)
a = p.parse_args()

fw = open(a.bin_in, "rb").read()
fw += b"\xFF" * (-len(fw) % 4)                                      # pad to a word
major, minor, patch = (int(x) for x in a.version.split("."))
version = (major << 24) | (minor << 16) | (patch << 8)

hdr_wo_crc = struct.pack("<IHHIIII8sI64s",
    MAGIC, 1, 0x200, len(fw), a.load_addr, version, 0, b"\0" * 8,
    zlib.crc32(fw) & 0xFFFFFFFF, b"\0" * 64)
header = hdr_wo_crc + struct.pack("<I", zlib.crc32(hdr_wo_crc) & 0xFFFFFFFF)
header += b"\xFF" * (0x200 - len(header))                            # pad header to 0x200 bytes
open(a.bin_out, "wb").write(header + fw)
print(f"{a.bin_out}: {len(fw)} bytes, version {a.version}")
```

(Use **zlib's CRC-32** here: it matches `zlib.crc32` on the PC and a standard software CRC-32 in the bootloader. The STM32 hardware CRC unit uses a different configuration (chapter 0); pick one definition and test it with the same vectors on both sides.) In CMake, run the script as a `POST_BUILD` step (chapter 2/19) and flash the resulting file at `0x08020000` with `st-flash` or OpenOCD.

---

## 5. Bootloader design

### 5.1 What it does at each reset

```
 reset ─► init minimal hardware (clock, GPIO, UART) ─► read boot state (settings)
        ├─ update requested? ─► receive new image ─► verify ─► program ─► mark pending ─► reset
        ├─ validate slot(s): header magic, sizes, CRC (+ signature)
        ├─ choose image (highest valid version / active slot / rollback target)
        ├─ trial boot counter, start watchdog
        └─ jump to application (section 5.4)
```

The bootloader should be **small, simple, rarely changed** and **very well tested**: it is the one component you cannot update in the field (unless it updates itself, which is risky).

### 5.2 Layouts

| Layout | Description | Pros/Cons |
|---|---|---|
| **Single slot + staging** | App area plus a download area; on update, copy the staged image over the app | Needs full image size twice; copy can be interrupted: keep the staging copy until verified |
| **A/B slots** | Two app slots; boot the active one, update the inactive one, then switch | Safe rollback, no copying; costs 2x flash; both must be linkable (position-independent code, or two images linked at different addresses) |
| **Swap with scratch** (MCUboot) | Images swap sector by sector | Allows linking the app once; complex; sector sizes matter (F7's uneven sectors complicate this) |
| **Direct update (overwrite)** | Erase and write the app in place | Simple but unsafe: an interruption leaves no app (acceptable only with a recovery path, e.g. the ROM DFU) |

### 5.3 Power-fail safety and state machine

Principles:

1. **Never erase the only good image** until the new one is fully written and verified.
2. **Write the "commit" marker last** (header or boot flag) and make it a single small write.
3. **Two copies of the boot state** with counters/CRC, so a torn write is detected (alternate which copy is written; the valid one with the higher counter wins).
4. **Trial boot**: after an update the bootloader marks the new image "pending/testing"; the application must **confirm** (set "confirmed") after it has proven healthy (e.g., connected to the server, passed self-test). If the watchdog resets before confirmation, or the boot count exceeds a limit, the bootloader **rolls back** to the previous image.

```
 states:   CONFIRMED(A) ──update downloaded to B──► PENDING(B) ──app confirms──► CONFIRMED(B)
                                                       │ reset before confirm / too many boots
                                                       └────────► ROLLBACK ──► CONFIRMED(A)
```

5. **Test with power cuts at every step** (automate with a controllable power supply or a reset at random moments).

### 5.4 Jumping to the application

```c
typedef void (*app_entry_t)(void);

void bootloader_jump(uint32_t vector_table)
{
    uint32_t sp = *(volatile uint32_t *)vector_table;
    uint32_t pc = *(volatile uint32_t *)(vector_table + 4u);

    if ((sp & 0xFFF00000u) != 0x20000000u || (pc & 0xFF000000u) != 0x08000000u) { return; }  /* sanity */

    __disable_irq();
    SysTick->CTRL = 0u; SysTick->LOAD = 0u; SysTick->VAL = 0u;
    for (unsigned i = 0; i < 8u; i++) { NVIC->ICER[i] = 0xFFFFFFFFu; NVIC->ICPR[i] = 0xFFFFFFFFu; }
    /* put used peripherals back to reset state (RCC->xxxRSTR) and disable their clocks */
    SCB_DisableDCache(); SCB_DisableICache();          /* flushes and disables (clean first if needed) */
    __set_CONTROL(0u);                                 /* MSP, privileged */
    SCB->VTOR = vector_table;
    __DSB(); __ISB();
    __set_MSP(sp);
    ((app_entry_t)pc)();                               /* does not return */
}
```

The application's startup must not assume the bootloader left anything initialized: reinitialize clocks, caches, and peripherals (or take over cleanly). Pass small data (reason for boot, update request flag) through a reserved RAM area (`.noinit`, chapter 4) or a retained backup register.

### 5.5 Transport for updates

| Transport | Protocol notes |
|---|---|
| **UART** | Simple custom protocol (chapter 11: frames, CRC, ACK per block) or standard XMODEM-1K/YMODEM; flow control; resumable blocks |
| **USB DFU** | Standard device class; `dfu-util` on the PC; easy to ship |
| **USB MSC** (drag-and-drop file) | Needs a FAT view of the flash; user friendly |
| **CAN** (ISO-TP/UDS) | Automotive/industrial |
| **Ethernet/Wi-Fi** | HTTP(S), MQTT, CoAP; TLS; download in chunks with Range requests |
| **BLE** | DFU services |
| **SD card** | Copy a file from a card and verify |

Design the transfer with: **block numbers and CRC per block**, resume after interruption, a final **whole-image verification**, size limits, timeouts, and an **authenticated** source (sections 7 and 8).

### 5.6 Existing solutions (prefer them over your own for products)

| Option | Notes |
|---|---|
| **MCUboot** | Open-source secure bootloader: image signing (`imgtool`), swap/direct-xip/overwrite modes, rollback, encrypted images; the standard in Zephyr (chapter 9); also usable bare-metal |
| **STM32 SBSFU / X-CUBE-SBSFU** | ST's secure boot and secure firmware update package (check the families it supports) |
| **ST ROM bootloader (AN2606)** | Programming over UART/USB/CAN/I2C/SPI |
| **TinyUF2, Black Magic, others** | Community bootloaders |
| **Memfault, Mender, RAUC, SWUpdate** | OTA frameworks (more for Linux, but concepts apply) |

Rule: **do not invent your own cryptography or signature scheme**; use well-reviewed libraries and designs.

---

## 6. Over-the-air (OTA) update design

An OTA system includes more than the bootloader:

```
 Build/CI ─► sign ─► publish (server/CDN, manifest with version, hash, size, signature)
   Device: check version/manifest ─► download (resumable) ─► verify ─► stage ─► reboot ─► trial boot ─► confirm/rollback ─► report status
```

Concerns:

- **Authenticity and integrity**: signature verified **on the device** before booting; HTTPS/TLS protects the channel but does not replace signatures.
- **Rollback protection**: reject older/vulnerable versions via a monotonic version counter.
- **Compatibility**: hardware revision, bootloader version, minimum version path (do not skip required migrations); versioned settings formats and migration code.
- **Delta updates** (binary diff: bsdiff, heatshrink-compressed) save bandwidth but add complexity.
- **Storage budget**: A/B needs 2x flash; use external flash or compression when too tight.
- **Power and connectivity**: do not start an update with a low battery; resume partial downloads.
- **Staged rollout and telemetry**: update a few devices first; report success/failure and versions; ability to halt a bad rollout.
- **Fleet identity**: unique device ID and per-device credentials (section 9.4).
- **Testing**: update from every previous release to the new one; interrupted updates; corrupted images; wrong signature; rollback; low-memory conditions (chapter 14 fuzzing and HIL).

---

## 7. Security fundamentals

### 7.1 Think in threats

| Property | Question |
|---|---|
| **Confidentiality** | Can someone read secrets/firmware? |
| **Integrity** | Can data/code be modified undetected? |
| **Authenticity** | Is it really from the claimed source (firmware, commands, server)? |
| **Availability** | Can the device be knocked offline (DoS, bricking)? |
| Non-repudiation, privacy | Logs, personal data handling |

Build a **threat model**: assets (firmware IP, keys, user data, safety function), attackers (remote over the network, local with physical access, supply chain), attack surfaces (debug port, bootloader, communication interfaces, update path, external memory, side channels), and mitigations proportional to the risk. Perfect security does not exist: raise the cost of attack above the value.

### 7.2 Cryptographic building blocks

| Primitive | Examples | Use |
|---|---|---|
| **Hash** | SHA-256 (SHA-3) | Integrity digest; part of signatures |
| **MAC / HMAC** | HMAC-SHA256, CMAC-AES | Integrity + authenticity with a **shared secret** |
| **Symmetric cipher / AEAD** | AES-GCM, ChaCha20-Poly1305 | Confidentiality + integrity of data |
| **Asymmetric signature** | **ECDSA P-256, Ed25519**, RSA-2048+ | Authenticity with a **public key on the device** (private key stays at the vendor) |
| **Key agreement** | ECDH (X25519, P-256) | Session keys |
| **KDF** | HKDF, PBKDF2 | Derive keys |
| **RNG** | Hardware TRNG (the F746 has an RNG peripheral needing the 48 MHz clock) | Keys, nonces, challenges |

Rules:

- **Signatures for firmware**: the device holds only the public key; compromise of a device does not let attackers sign firmware. A symmetric MAC would require the same secret in every device (one extracted key breaks the fleet).
- **Never reuse a nonce/IV** with the same key (AES-GCM breaks catastrophically).
- Use **constant-time comparison** for MACs/hashes (`memcmp` leaks timing).
- Use vetted libraries: **mbedTLS**, **wolfSSL**, **TinyCrypt**, **Monocypher**, ST's crypto accelerators/libraries (the F756/F77x have a hardware crypto/hash unit; the F746 does not have the CRYP peripheral: check your part number).
- **Do not roll your own** crypto or protocol; follow standards (TLS 1.2/1.3, DTLS, COSE/CBOR).
- **Key sizes and lifetimes**: plan for key rotation and revocation.
- Protect **private keys** in an HSM, a hardware token, or at least an access-controlled CI secret store; never commit keys to git.

### 7.3 Secure boot (chain of trust)

```
 immutable root (ROM / locked first-stage bootloader with the public key)
        ─► verifies signature of stage 2 (bootloader/updater)
              ─► verifies signature of the application
                    ─► application runs
```

Requirements: the first stage must be **unmodifiable** (write-protected flash sectors, RDP) and contain the **public key** (or its hash); verification must be **mandatory** (no code path boots an unverified image); check **version/rollback**, and avoid TOCTOU (time-of-check vs time-of-use): verify the image in place and run exactly what was verified, or copy then verify then run.

Signing flow with MCUboot's `imgtool` (example):

```bash
imgtool keygen -k signing-key.pem -t ecdsa-p256
imgtool sign --key signing-key.pem --header-size 0x200 --align 8 --version 1.2.3 --slot-size 0x40000 \
             build/app.bin build/app-signed.bin
imgtool getpub -k signing-key.pem          # emits the public key as C for the bootloader
```

(Option names vary by version: read `imgtool --help`.)

### 7.4 Memory and flash protection on the STM32F7

| Feature | Purpose |
|---|---|
| **RDP (read-out protection)** | Level 0: none. **Level 1**: debug access to flash blocked; going back to level 0 **mass-erases** the flash. **Level 2**: debug and ROM bootloader disabled, **irreversible**: do not use while developing |
| **Write protection (nWRP option bytes)** | Protect the bootloader sectors from erase/program |
| **PCROP** (proprietary code read-out protection) | Marks sectors as execute-only data (code can execute but not be read as data): check availability and options on your F7 device |
| **MPU** (chapter 3) | Execute-never on RAM, protect the bootloader/stack, restrict peripherals |
| **Disable debug** | RDP level 1+ or software-controlled debug disable; physical access still permits fault injection and chip-level attacks |
| Backup SRAM/registers, tamper detection (RTC tamper pins) | Store/erase keys on tamper |
| Unique ID (96-bit at a fixed system-memory address) | Device identity (not secret) |
| TRNG | Entropy |

Remember: **RDP raises the bar but does not make a chip unbreakable**; known attacks on various vendors' read-out protection exist (voltage/clock glitching, debug-port tricks). For high-value secrets use a **secure element** (ATECC608, SE050, OPTIGA) or an MCU with TrustZone/secure boot/OTP key storage (STM32L5/U5/H5, nRF53/91, etc.).

### 7.5 Secure coding for firmware

- **Validate all external input**: lengths, ranges, enums; never trust a length field (chapter 11); check integer overflow before allocation or copying (`if (len > max - offset)` instead of `offset + len > max`).
- No `strcpy/sprintf/gets`; use bounded functions and check truncation; avoid format strings from external data.
- Use **fixed buffers with explicit bounds**; avoid recursion and VLAs.
- Treat **debug interfaces and test commands** as attack surface: disable or authenticate in production builds.
- **Compiler hardening**: `-Wall -Wextra -Wformat=2 -Wconversion`, `-fstack-protector-strong` (needs `__stack_chk_guard` initialized from the RNG and `__stack_chk_fail`), `-D_FORTIFY_SOURCE=2` (limited without a full libc), MPU W^X (no execute from RAM), `-fno-common`, stack-usage limits. (Control-flow integrity features like BTI/PAC exist on newer Armv8.1-M cores, not the M7.)
- **Least privilege**: unprivileged threads with the MPU for risky components (parsers, network stack), RTOS memory protection.
- **Secrets**: not in source or in the repository; not in plain text logs; zeroize key buffers after use (use `explicit_bzero`/volatile writes so the compiler does not optimize it away).
- **Fuzz** every parser and update/handshake code (chapter 14).
- **Time**: certificate validation needs correct time or an alternative (monotonic counters, pinned keys).
- **Rate limiting and authentication** on commands (a UART console that allows `reboot` or `dump flash` on a deployed device is a vulnerability).

### 7.6 Network security

- **TLS 1.2/1.3** with certificate validation against a **pinned CA/public key**; mutual TLS (client certificates) for device identity; **never disable certificate verification**.
- MQTT over TLS, HTTPS, CoAP over DTLS/OSCORE; avoid plaintext protocols on untrusted networks.
- Protect against replay (nonces, counters, timestamps).
- Provision unique credentials per device; **no shared default passwords**.
- Minimize open ports; disable services you do not need; keep libraries updated.

### 7.7 Supply chain and lifecycle

- **SBOM** (software bill of materials: SPDX/CycloneDX): list every component and version; the EU Cyber Resilience Act and similar regulations are making them standard for products sold in those markets.
- Track vulnerabilities (**CVEs**) of your dependencies (NVD, vendor advisories, Dependabot/OSV scanners) and have a **patch process** (this is what the OTA infrastructure is for).
- **Reproducible builds** and signed releases; protect the CI/CD and signing keys (a compromised build server is the shortest path to a compromised fleet).
- Pin dependencies (hashes/commits); review third-party code you vendor.
- **Vulnerability disclosure** policy (`security.txt`, contact), end-of-life/support period declared.
- Standards to know: **IEC 62443** (industrial), **PSA Certified** and **SESIP** (IoT security evaluation), **ETSI EN 303 645** (consumer IoT), **NIST** guidance, OWASP IoT/Embedded Application Security, and the CRA (Europe). Check which apply to your product and market.

### 7.8 Provisioning and production

- Factory flow: program the bootloader, set **option bytes** (write protection, RDP) as the **last** step, write **per-device identity** (keys/certificates, serial number) into protected storage, run a self-test, log the result.
- STM32CubeProgrammer CLI examples (verify options):

```bash
STM32_Programmer_CLI -c port=SWD -w build/bootloader.bin 0x08000000 -v
STM32_Programmer_CLI -c port=SWD -w build/app-signed.bin 0x08020000 -v -rst
# option bytes (DANGEROUS: RDP changes; do not try level 2 on a development board)
STM32_Programmer_CLI -c port=SWD -ob displ
```

- Keep **secrets out of the production line's logs**; use an HSM or a secure signing service for per-device credentials.

---

## 8. Putting it together: a minimal secure update path

1. **Image**: header + firmware, `fw_version`, SHA-256 hash, **Ed25519 or ECDSA P-256 signature** by the vendor key (CI signs release builds).
2. **Bootloader (write-protected)** with the public key embedded: on boot it validates slots (header, hash, signature, version ≥ stored minimum), picks the highest valid confirmed image, runs trial boots, supports rollback, and disables unneeded interfaces.
3. **Update client in the application**: downloads the new image over TLS in chunks, writes it to the inactive slot, requests the bootloader to verify and switch, and **confirms** after health checks.
4. **Counters**: monotonic **anti-rollback** counter stored in protected flash/backup domain/secure element.
5. **Production**: write-protect the bootloader sectors, set RDP level 1 (or higher where justified), keep a recovery procedure.
6. **Tests**: unit tests of header parsing, signature checking with known test vectors (RFC 8032 for Ed25519), fuzzing, power-cut tests at every step, rollback test, wrong-key test.

---

## 9. Exercises

Safe ones first (use a spare board; avoid RDP level 2):

1. **Boot flow**: use `arm-none-eabi-objdump` and gdb to inspect the vector table (SP and reset vector) and verify what the core loads at reset (chapter 3).
2. **DFU**: put the Nucleo in ROM DFU mode (BOOT0 high; check the board's jumper/solder bridge) and program the blink binary with `dfu-util`.
3. **Flash driver**: implement `flash_erase_sector` and `flash_program` (from RAM), program a pattern in a spare sector, read it back, check the error flags with deliberately bad addresses.
4. **Image tool**: write `make_image.py`, link the application at `0x08020200`, flash the header+image and verify the header in gdb (`x/16wx 0x08020000`).
5. **Bootloader v1**: bootloader at `0x08000000` that validates the header and CRC and jumps to the app; test with a corrupted image (must not jump) and with a valid one.
6. **Jump correctness**: have the app print `SCB->VTOR` and check interrupts (SysTick, UART) work after the jump.
7. **UART update**: add an update mode (a button at boot or a command) that receives a framed, CRC-checked image (chapter 11), writes it to a staging area, verifies it, and switches.
8. **Power-cut test**: automate resets (relay or a controllable USB hub) during every phase of the update and prove the device always boots a valid image.
9. **A/B with trial boot**: add a confirmed flag and a boot counter; make the app confirm only after a self-test; verify rollback by keeping the app from confirming.
10. **Signatures on the PC first**: with Python (`cryptography` or `pynacl`) sign an image with Ed25519; verify it with a C library (Monocypher/TinyCrypt/mbedTLS) on the PC using test vectors.
11. **Signatures on the target**: port the verifier to the bootloader, measure verification time and code size; reject images signed with another key.
12. **MCUboot**: build a Zephyr app with MCUboot (chapter 9), sign with `imgtool`, update over serial with `mcumgr`, and test rollback.
13. **Option bytes (careful)**: read the option bytes with CubeProgrammer, then enable **write protection** on the bootloader sectors on a spare board and confirm that a flash write to them fails.
14. **RDP level 1 experiment** (spare board, understand that going back erases the chip): enable it, try to read flash through the debugger, then revert and observe the mass erase.
15. **Parser fuzzing**: fuzz the update protocol parser and the header validator (chapter 14).
16. **Threat model**: write a one-page threat model for a hypothetical product based on the Nucleo (assets, attackers, surfaces, mitigations, residual risks).

---

## 10. Cheat sheet

```
Boot:  BOOT0=0 → flash @0x08000000 ; BOOT0=1 → ROM bootloader (DFU/UART/CAN…)
Flash: erase by SECTOR (sector 4 128 KB; 5-7 256 KB), program 1→0 only, single bank: code stalls, run flash ops from RAM
Image: header(magic, size, version, crc, signature) + vector table 512B-aligned ; header written LAST
Update: never erase the only good image ; commit marker last ; trial boot + confirm + rollback ; test power cuts
Jump:  disable IRQs, stop SysTick, clear NVIC, reset peripherals, disable caches, set VTOR, set MSP, call reset vector
Security: sign with asymmetric keys (public key on device) ; anti-rollback ; RDP L1 + write-protect bootloader ; no RDP L2 while learning
         no custom crypto ; constant-time compares ; validate all input ; secrets never in git ; SBOM ; patch process
```

| Question | Answer |
|---|---|
| How to avoid bricking on interrupted updates? | A/B or staging, verify, commit marker last, rollback, power-cut tests |
| CRC or signature? | CRC for accidents, signature for authenticity (attackers) |
| Where do keys live? | Public key in the protected bootloader; private key in an HSM/secured CI |
| Can I trust RDP? | It raises the bar, not absolute: use secure elements/TrustZone MCUs for high-value secrets |
| Own bootloader or MCUboot? | MCUboot or a vendor solution for products; own bootloader for learning or simple cases |

---

## 11. Where this leads

- **Testing** (chapter 14): fuzz and HIL for update and security paths.
- **Python tooling** (chapter 17): image tools, signing scripts, update clients.
- **Advanced toolchain** (chapter 19): linker scripts for images, `.ramfunc`, post-build signing in CMake.
- **Embedded Linux** (chapter 22): secure boot chains and OTA frameworks (RAUC, SWUpdate, Mender).
- **Standards and certification**: IEC 62443, PSA Certified, CRA readiness.

## References

- ST AN2606: STM32 microcontroller system memory boot mode (per-device boot interfaces)
- ST RM0385: Embedded Flash memory interface, Option bytes, RDP; PM0253 (core)
- ST X-CUBE-SBSFU documentation; STM32CubeProgrammer user manual
- MCUboot documentation: <https://docs.mcuboot.com>; `imgtool`, `mcumgr`
- *Embedded Systems Security*, David Kleidermacher; OWASP Embedded Application Security Project
- RFC 8032 (Ed25519), FIPS 186-5 (ECDSA), RFC 8446 (TLS 1.3), NIST SP 800-38D (GCM)
- Memfault *Interrupt* blog: bootloader and OTA articles; <https://interrupt.memfault.com>
- EU Cyber Resilience Act, IEC 62443, PSA Certified: check the current texts for your market
