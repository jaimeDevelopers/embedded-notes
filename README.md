# Embedded Systems Notes: Index and Reading Guide

Notes written for an STM32 (NUCLEO-F746ZG) learning path on Ubuntu, from the toolchain up to Linux, RTOSes, security, and hardware. All chapters are Markdown; code blocks are meant to be **read, adapted and verified** (most were **not compiled on your board**: see the verification note at the top of each chapter).

---

## 1. Chapters

| # | File | Topic |
|---|---|---|
| 00 | `00_toolchain.md` | Compilation stages, ELF, linker scripts, startup, newlib, CRC, reproducible builds |
| 01 | `01_make.md` | GNU Make in full, with an STM32 Makefile |
| 02 | `02_cmake.md` | CMake: targets, toolchain files, presets, VS Code |
| 03 | `03_cortex_m.md` | Registers, modes, memory model, NVIC, faults, SysTick, FPU, MPU, caches, Thumb-2 intro |
| 04 | `04_debugging.md` | ST-LINK, OpenOCD, GDB, Cortex-Debug, post-mortem, logging |
| 05 | `05_c.md` | Embedded C: types, `volatile`, UB, atomicity, patterns |
| 06 | `06_cpp.md` | Embedded C++: RAII, `constexpr`, templates, what to disable |
| 07 | `07_peripherals.md` | Clocks, GPIO/EXTI, UART/DMA, timers, ADC, SPI/I2C, watchdog (register level) |
| 08 | `08_architecture.md` | Layers, HAL design, execution models, FSMs, tests, bootloader overview |
| 09 | `09_zephyr.md` | Zephyr RTOS: west, Kconfig, devicetree, kernel, tips and tricks |
| 10 | `10_electronics.md` | Electronics, datasheets, schematics, instruments, hardware debugging |
| 11 | `11_protocols.md` | Framing/CRC/COBS, UART, SPI, I2C, CAN, USB, Ethernet, MQTT, Modbus |
| 12 | `12_freertos.md` | FreeRTOS in depth on the Cortex-M7 |
| 13 | `13_control_dsp.md` | Sampling, filters, FFT, PID, estimation, CMSIS-DSP |
| 14 | `14_testing_quality.md` | Unit/HIL tests, coverage, static analysis, fuzzing, CI |
| 15 | `15_low_power.md` | Power modes, measurement, battery design |
| 16 | `16_bootloader_security.md` | Flash, bootloaders, OTA, secure boot, security practices |
| 17 | `17_python_tools.md` | Python tooling: serial, ELF/map parsing, code generation, HIL |
| 18 | `18_assembly.md` | Thumb-2 assembly, reading compiler output |
| 19 | `19_advanced_toolchain.md` | Advanced CMake, linker scripts, binary tools |
| 20 | `20_rust_embedded.md` | Embedded Rust with Embassy and probe-rs |
| 21 | `21_pcb_design.md` | PCB design with KiCad |
| 22 | `22_embedded_linux.md` | Embedded Linux: Buildroot, Yocto, userspace hardware access |
| 90 | `90_appendix_linux_terminal.md` | Terminal, shortcuts, tmux, git, serial tools |
| 91 | `91_appendix_glossary.md` | Glossary of terms and acronyms |

---

## 2. Suggested reading paths

### 2.1 Core path (what to do first, in order)

```
00 toolchain → 01 make → 02 cmake → 03 cortex_m → 04 debugging → 05 C → 07 peripherals → 08 architecture
```

Practice each chapter's exercises on the Nucleo before moving on. Keep a repository with one **compiling example per chapter** (`examples/`).

### 2.2 By goal

| Goal | Chapters |
|---|---|
| Get a firmware project building and flashing | 00, 01, 02, 04 |
| Understand crashes and faults | 03, 04, 18 |
| Write robust drivers | 05, 07, 10, 11, 14 |
| Build a product-quality firmware | 08, 12 or 09, 14, 15, 16, 17 |
| Algorithms and sensing | 13, 17, 10 |
| Connectivity | 11, 16, 22 |
| Hardware design | 10, 21, 15 |
| Alternative languages and platforms | 06 (C++), 20 (Rust), 09 (Zephyr), 22 (Linux) |
| Daily productivity | 90 (terminal), 17 (Python), 02/19 (build) |

### 2.3 Dependency map (what to read before what)

```
 00 → 01 → 02 → 19
 00 → 03 → 04 → 18
 03 → 05 → 06 / 20
 03 + 05 → 07 → 11 → 16
 05 + 07 → 08 → 12 / 09 → 14 → 15
 10 → 21 ; 10 → 11 ; 13 → 17
 22 relies on 00, 02, 03, 07, 11
```

---

## 3. Conventions used in the notes

- **Target**: STM32F746ZG (Cortex-M7, single-precision FPU, 1 MB Flash, 320 KB RAM), NUCLEO-F746ZG board, Ubuntu host.
- **Toolchain**: `arm-none-eabi-gcc` (or the Zephyr SDK / Rust toolchain in their chapters), CMake 4.x, OpenOCD, `gdb-multiarch`.
- Registers and names from **CMSIS device headers** (`stm32f7xx.h`).
- **Verification notes** at the top of chapters: facts come from the author's memory of manuals, official documentation checked at the time of writing, or ST/vendor material. **Always confirm in RM0385, the datasheet, the errata and UM1974**.
- File and cross-reference style: "chapter N" refers to the numbers in the table above.
- Hardware facts noted as "verify": FPU type of the F746 (single precision), pin and alternate-function numbers, DMA request mapping, timer and ADC details, Nucleo solder bridges and jumpers (UM1974).

### Known corrections applied so far

- In generator expressions, **separate flags with `;`, not spaces**: `$<$<CONFIG:Debug>:-Og;-g3>`.
- The F746 FPU is **single precision**: use `-mfpu=fpv5-sp-d16`; `float` to `double` promotion in `printf` produces `vcvt.f64.f32`, which faults.
- `cbz`/`cbnz` branch **forward only**.
- `st-flash` needs `--reset` for the program to start; the Zephyr default runner for this board is STM32CubeProgrammer (use `-r openocd`).

---

## 4. How to keep and publish the notes

```bash
./organize_notes.sh          # copies and renames files into notes/ (see the script)
cd notes && git init && git add . && git commit -m "Embedded notes"
./build_book.sh html         # single-page HTML (no LaTeX needed)
./build_book.sh odt          # ODT for LibreOffice
./build_book.sh pdf          # PDF via XeLaTeX (needs texlive-xetex and DejaVu fonts)
```

Suggested repository layout:

```
embedded-notes/
├── notes/                    # the Markdown chapters
├── examples/                 # one compiling project per chapter (to be written as you practice)
│   ├── 00_toolchain/  01_make/  02_cmake/  03_cortex_m/ ...
├── tools/                    # scripts from chapters 17 and 19
└── build/                    # generated book (ignored by git)
```

Keep **examples that compile** as the source of truth: copy code from them into the notes, not the other way around.

---

## 5. Maintenance checklist for the notes

- When a command fails on your machine, **fix the note** (and add the error and its cause to the troubleshooting table of that chapter).
- Add **dates and versions** next to tool-specific instructions (Zephyr, Rust crates, KiCad, Yocto) and revisit them every few months.
- Move verified code from the notes into `examples/` and mark chapters as "verified on the board".
- Keep a short **"what I got wrong"** log per chapter: it is the fastest way to learn.
- Re-read the ISR/volatile/atomicity rules (chapters 3, 5, 12) before every project.

---

## 6. What is not covered (candidates for later)

- Specific middleware: lwIP and TLS integration in depth, FatFS/LittleFS, LVGL (graphics), USB stacks (beyond overview).
- Wireless (BLE/Wi-Fi/LoRa) design in depth; sensors catalog; motor control (FOC) implementation details.
- Safety standards process (IEC 61508, ISO 26262, IEC 62304): only mentioned.
- Mechanical/enclosure design, manufacturing test, certification (CE/FCC) in depth.
- Other MCU families (nRF, RP2040, ESP32) and RISC-V.

A good next step is **one real project** using the whole stack (a data logger or a sensor node), with CI, tests, an update path and a PCB revision: it exposes everything the notes leave abstract.
