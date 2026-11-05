# Glossary of Terms and Acronyms

Alphabetical within sections. The last column points to the chapter where the term is explained in more detail. "STM32F7" means the family of the NUCLEO-F746ZG.

---

## 1. Toolchain, build, and linking

| Term | Meaning | Ch. |
|---|---|---|
| **ABI / EABI** | Application Binary Interface: calling convention, data layout and register use that all object files must follow (ARM EABI for bare metal) | 0, 3 |
| **AAPCS** | Arm Procedure Call Standard: `r0-r3` args, `r4-r11` callee-saved, 8-byte stack alignment | 3, 18 |
| **ar / archive (`.a`)** | Static library: archive of object files; the linker pulls only the members it needs | 0 |
| **assembler (`as`)** | Translates assembly to machine code (object file) | 0, 18 |
| **bin / hex / ELF / S-record** | Output formats: raw bytes (no addresses); Intel HEX and S-record (with addresses); ELF (sections, symbols, debug info) | 0 |
| **BitBake** | Yocto's build engine that executes recipes | 22 |
| **Buildroot** | Simple embedded Linux build system based on Kconfig and Make | 22 |
| **BSP** | Board Support Package: startup, drivers, clock and pin configuration for a board | 8 |
| **CMake** | Build-system generator (Makefiles/Ninja) driven by `CMakeLists.txt` | 2, 19 |
| **CMSIS** | Arm's Cortex Microcontroller Software Interface Standard: core headers and device headers | 3, 7 |
| **compile_commands.json** | Database of compiler commands used by clangd, clang-tidy | 2, 19 |
| **crt0 / startup code** | Code run at reset: sets up stack, copies `.data`, zeroes `.bss`, calls `main` | 0, 18 |
| **DWARF** | Debug information format stored in `.debug_*` sections | 0, 4 |
| **ELF** | Executable and Linkable Format: sections, segments, symbols | 0 |
| **GCC / Clang** | C/C++ compilers (`arm-none-eabi-gcc`) | 0 |
| **generator expression** | CMake `$<...>` evaluated at generate time (`$<TARGET_FILE:t>`, `$<CONFIG:Debug>`) | 2, 19 |
| **gc-sections** | Linker option removing unused sections (with `-ffunction-sections -fdata-sections`) | 0 |
| **Kconfig** | Configuration language (Linux, Zephyr, Buildroot): `CONFIG_*` symbols | 9, 22 |
| **LMA / VMA** | Load address (where stored) vs virtual/run address (where it executes); `.data` has LMA in Flash and VMA in RAM | 0 |
| **linker script (`.ld`)** | Describes memory regions and where each section goes | 0, 19 |
| **LTO** | Link-time optimization across translation units | 19 |
| **Make / Makefile** | Dependency-driven build tool | 1 |
| **map file** | Linker output listing symbol addresses and the origin of each byte | 0, 19 |
| **multilib** | Libraries compiled for several CPU/FPU/ABI variants (`v7e-m+fp/hard`) | 0 |
| **newlib / newlib-nano** | C library for bare metal; nano is smaller (no `%f` by default) | 0, 5 |
| **nosys.specs** | Linker spec providing empty system-call stubs | 0 |
| **Ninja** | Fast build tool, a common CMake backend | 2 |
| **objcopy / objdump / readelf / nm / size** | Binutils for converting, disassembling, inspecting ELF files | 0 |
| **preset (CMake)** | `CMakePresets.json` configuration of configure/build/test | 2, 19 |
| **reproducible build** | Same inputs produce the same binary (`SOURCE_DATE_EPOCH`, `-ffile-prefix-map`) | 0, 19 |
| **section** | Named block of an object file: `.text`, `.rodata`, `.data`, `.bss` | 0 |
| **toolchain file** | CMake file selecting the cross compiler and system | 2 |
| **west** | Zephyr's workspace and command tool | 9 |
| **Yocto / Poky / OpenEmbedded** | Framework for building custom Linux distributions | 22 |

---

## 2. Cortex-M core and memory

| Term | Meaning | Ch. |
|---|---|---|
| **APB / AHB / AXI** | Buses connecting core, memory and peripherals (APB slow, AHB fast, AXI high performance) | 3, 7 |
| **ART Accelerator** | ST's flash prefetch/cache for zero-wait-state execution | 3, 7 |
| **BASEPRI** | Register masking interrupts at or below a priority value | 3, 12 |
| **bit-banding** | Alias region for bit access (Cortex-M3/M4); **not on M7** | 3 |
| **BusFault / MemManage / UsageFault / HardFault** | Fault exceptions; HardFault is the catch-all/escalation | 3 |
| **CFSR / HFSR / BFAR / MMFAR** | Fault status and address registers | 3, 4 |
| **CONTROL** | Register selecting privilege and stack (nPRIV, SPSEL, FPCA) | 3 |
| **CPACR** | Coprocessor access control: enables the FPU | 3 |
| **D-cache / I-cache** | Cortex-M7 L1 data/instruction caches | 3 |
| **DTCM / ITCM** | Tightly coupled data/instruction memories, zero wait states | 3, 19 |
| **DWT** | Data Watchpoint and Trace: cycle counter, watchpoints | 3, 4 |
| **EXC_RETURN** | Special LR value returned from handlers (`0xFFFFFFF9`, `0xFFFFFFFD`, ...) | 3 |
| **FPB** | Flash Patch and Breakpoint unit: hardware breakpoints | 3, 4 |
| **FPU / FPv5** | Floating-point unit; F746 is single precision (`-mfpu=fpv5-sp-d16`) | 0, 3 |
| **handler mode / thread mode** | Exception processing vs normal execution | 3 |
| **ICSR / VECTACTIVE** | Interrupt control and state register; active exception number | 3 |
| **IPSR / xPSR** | Program status registers (flags, T bit, exception number) | 3 |
| **ITM / SWO** | Instrumentation trace and the single-wire output pin | 3, 4 |
| **MPU** | Memory protection unit | 3 |
| **MSP / PSP** | Main and process stack pointers | 3 |
| **NMI** | Non-maskable interrupt | 3 |
| **NOCP / UNDEFINSTR / INVSTATE** | UsageFault causes: FPU off, invalid instruction, bad Thumb state | 3 |
| **NVIC** | Nested Vectored Interrupt Controller | 3 |
| **PendSV / SVC / SysTick** | System exceptions: context switch, system call, timer tick | 3, 12 |
| **PRIGROUP** | Priority grouping (preempt vs sub-priority bits) | 3, 12 |
| **PRIMASK / FAULTMASK** | Registers masking interrupts | 3 |
| **SCB** | System Control Block: VTOR, CFSR, CPACR... | 3 |
| **stacking / lazy stacking** | Hardware saving of registers on exceptions; FPU context saved lazily | 3 |
| **tail-chaining** | Back-to-back exception handling without unstack/restack | 3 |
| **Thumb / Thumb-2** | Instruction set of Cortex-M (16/32-bit mix) | 3, 18 |
| **TCM** | Tightly coupled memory | 3 |
| **VTOR** | Vector table offset register | 3, 16 |
| **WFI / WFE** | Wait for interrupt / event (sleep instructions) | 3, 15 |

---

## 3. STM32 peripherals and clocks

| Term | Meaning | Ch. |
|---|---|---|
| **ADC** | Analog-to-digital converter (12-bit on the F7) | 7, 10 |
| **AF (alternate function)** | Pin mapped to a peripheral signal (AF7 = USART3) | 7 |
| **BOR / PVD** | Brown-out reset / programmable voltage detector | 10, 15 |
| **BRR** | USART baud rate register | 7 |
| **BSRR** | GPIO bit set/reset register (atomic) | 5, 7 |
| **bxCAN** | STM32's CAN controller | 11 |
| **CRC unit** | Hardware CRC-32 | 0, 16 |
| **DBGMCU** | Debug MCU configuration (freeze peripherals while halted) | 4, 7 |
| **DMA** | Direct memory access controller | 7 |
| **EXTI** | External interrupt/event controller | 7 |
| **HSE / HSI / LSE / LSI** | High/low-speed external/internal oscillators | 7 |
| **IDD jumper (JP6)** | Nucleo current measurement jumper | 10, 15 |
| **IWDG / WWDG** | Independent / window watchdogs | 7 |
| **MCO** | Microcontroller clock output pin | 7 |
| **Over-drive** | F7 mode needed above 180 MHz | 7 |
| **PLL (M, N, P, Q)** | Clock multiplier: `VCO = in/M*N`, `SYSCLK = VCO/P`, `48 MHz = VCO/Q` | 7 |
| **PWM / TIMx / ARR / PSC / CCR** | Timers: auto-reload, prescaler, capture/compare | 7, 13 |
| **RCC** | Reset and clock control | 7 |
| **RDP** | Read-out protection (levels 0, 1, 2) | 16 |
| **RTC** | Real-time clock | 15 |
| **SPI / I2C / USART / CAN / USB / ETH** | Communication peripherals | 7, 11 |
| **SYSCFG** | System configuration controller (EXTI routing) | 7 |
| **VBAT / VDDA / VCAP** | Backup supply, analog supply, internal regulator capacitor pins | 10 |

---

## 4. Debugging and testing

| Term | Meaning | Ch. |
|---|---|---|
| **ASan / UBSan / MSan / TSan** | Address/UB/Memory/Thread sanitizers | 5, 14 |
| **CMock / Unity / Ceedling** | C test tools: mocks, framework, runner | 14 |
| **coverage (statement/branch/MC-DC)** | Measure of code executed by tests | 14 |
| **Cortex-Debug** | VS Code extension for ARM debugging | 4 |
| **defmt / RTT** | Efficient logging format / Real-Time Transfer channel | 20 |
| **fault injection** | Forcing errors in tests | 14 |
| **fuzzing** | Random/mutated input testing (libFuzzer, AFL++) | 14 |
| **GDB / gdbserver / gdb-multiarch** | Debugger and remote debugging pieces | 4, 22 |
| **HIL** | Hardware-in-the-loop test | 14 |
| **OpenOCD** | Open On-Chip Debugger (GDB server for ST-LINK, J-Link, CMSIS-DAP) | 4 |
| **post-mortem** | Analyzing a crash after the fact (fault record in `.noinit`) | 4 |
| **probe-rs** | Rust-based flashing/debugging tool | 20 |
| **semihosting** | I/O through the debugger (`BKPT`); faults without a debugger | 4 |
| **SWD / JTAG** | Debug interfaces (2-wire / 4-wire) | 4 |
| **ST-LINK** | ST's debug probe (on the Nucleo) | 4 |
| **stack painting** | Filling the stack with a pattern to measure usage | 4 |
| **test double (stub/fake/mock)** | Substitutes for dependencies | 8, 14 |
| **twister / ztest / native_sim** | Zephyr's test runner, framework, and PC simulator | 9 |
| **watchpoint** | Debugger stop on data access | 4 |

---

## 5. Language and programming concepts

| Term | Meaning | Ch. |
|---|---|---|
| **atomic** | Operation that cannot be interrupted/split (C11 `<stdatomic.h>`) | 5, 6 |
| **CRTP** | Curiously recurring template pattern (static polymorphism) | 6 |
| **constexpr / consteval / constinit** | Compile-time evaluation features of C++ | 6 |
| **critical section** | Code protected from concurrent access (masking interrupts or a lock) | 5, 8, 12 |
| **designated initializer** | C99 `{ .field = value }` | 5 |
| **Qm.n / fixed point** | Integers representing fractions | 5, 13 |
| **RAII** | Resource acquisition is initialization (C++ scope-bound resources) | 6 |
| **strict aliasing** | Rule that accesses through incompatible pointer types are UB | 5 |
| **type-state** | Encoding states in types (Rust/C++) | 20 |
| **UB (undefined behavior)** | Code the standard gives no meaning to; the optimizer may assume it never happens | 5 |
| **vtable / vptr** | Virtual function table / pointer in C++ objects | 6 |
| **volatile** | Qualifier: every access must happen; not atomic, no ordering vs non-volatile | 5 |

---

## 6. RTOS and architecture

| Term | Meaning | Ch. |
|---|---|---|
| **active object** | Concurrency pattern: object with its own queue and thread | 8 |
| **deadlock** | Tasks waiting forever on each other | 12 |
| **event queue** | FIFO of events decoupling producers from consumers | 8 |
| **FreeRTOS / Zephyr / RTX / ThreadX** | RTOS and platform choices | 9, 12 |
| **gatekeeper task** | Single task owning a resource | 12 |
| **HAL (own) / vendor HAL / LL** | Hardware abstraction layers | 7, 8 |
| **ISR / top half / bottom half** | Interrupt service routine and deferred processing | 8 |
| **priority inversion / inheritance** | Low-priority task blocking a high one / the fix | 12 |
| **rate-monotonic scheduling** | Shorter period gets higher priority | 12 |
| **state machine (FSM/HSM)** | Behavior model with states and transitions | 8 |
| **tickless idle** | Stopping the periodic tick while idle | 12, 15 |
| **work queue** | Deferred work executed in thread context (Zephyr `k_work`) | 9 |

---

## 7. Protocols and communications

| Term | Meaning | Ch. |
|---|---|---|
| **ACK / NACK** | Acknowledgement / negative acknowledgement | 11 |
| **bit timing (CAN)** | Time quanta, TS1, TS2, sample point | 11 |
| **CAN / CAN FD** | Controller Area Network | 11 |
| **CDC ACM / HID / MSC / DFU** | USB device classes | 11, 16 |
| **COBS** | Consistent Overhead Byte Stuffing (framing with `0x00` delimiter) | 11 |
| **CRC (CCITT, Modbus, CRC-32)** | Cyclic redundancy checks (parameters must be exact) | 11 |
| **DHCP / DNS / ARP / TCP / UDP** | Network protocols | 11 |
| **I2C (SCL/SDA, Rp)** | Two-wire bus with pull-ups | 10, 11 |
| **lwIP** | Lightweight TCP/IP stack | 11 |
| **Modbus (RTU/TCP)** | Industrial master/slave protocol | 11 |
| **MQTT (QoS)** | Publish/subscribe IoT protocol | 11 |
| **RS-232 / RS-485** | Serial line standards | 10, 11 |
| **SPI (CPOL/CPHA)** | Synchronous serial bus modes | 11 |
| **SocketCAN** | Linux CAN API | 11, 22 |
| **TLS** | Transport Layer Security | 11, 16 |

---

## 8. Electronics and PCB

| Term | Meaning | Ch. |
|---|---|---|
| **BOM / CPL / Gerber / Excellon** | Bill of materials / component placement / PCB layer files / drill files | 21 |
| **brown-out** | Supply dropping below the operating minimum | 10, 15 |
| **decoupling (bypass) capacitor** | Local capacitor reducing supply noise | 10, 21 |
| **DRC / ERC** | Design / electrical rules check | 21 |
| **ESD / TVS** | Electrostatic discharge / transient voltage suppressor | 10, 21 |
| **FT pin** | 5 V tolerant pin | 10 |
| **LDO / buck / boost** | Linear / step-down / step-up regulators | 10, 15 |
| **MOSFET (N/P, logic-level)** | Transistor used as a switch | 10 |
| **open-drain / push-pull** | Output types | 10 |
| **pull-up / pull-down** | Resistors defining an idle level | 10 |
| **RC time constant** | `tau = R*C` | 10 |
| **SB (solder bridge)** | Configuration links on boards like the Nucleo | 10 |
| **stack-up** | Layer structure of a PCB | 21 |
| **via / net class / courtyard / footprint** | PCB layout terms | 21 |

---

## 9. Control and DSP

| Term | Meaning | Ch. |
|---|---|---|
| **aliasing / Nyquist** | Frequency folding when sampling too slowly; `fs > 2*fmax` | 13 |
| **anti-windup** | PID integrator protection when the output saturates | 13 |
| **biquad** | Second-order IIR filter section | 13 |
| **CMSIS-DSP** | Optimized DSP library for Cortex-M | 13 |
| **EMA** | Exponential moving average | 13 |
| **FFT** | Fast Fourier transform | 13 |
| **FIR / IIR** | Finite / infinite impulse response filters | 13 |
| **FOC** | Field-oriented control for motors | 13 |
| **PID** | Proportional-integral-derivative controller | 13 |
| **SNR / ENOB** | Signal-to-noise ratio / effective number of bits | 10, 13 |

---

## 10. Security and updates

| Term | Meaning | Ch. |
|---|---|---|
| **anti-rollback** | Preventing installation of older versions | 16 |
| **A/B slots** | Two firmware slots for safe updates | 8, 16 |
| **CRA (Cyber Resilience Act)** | EU regulation for products with digital elements | 16, 22 |
| **ECDSA / Ed25519 / RSA** | Digital signature algorithms | 16 |
| **HMAC / AEAD / AES-GCM** | Message authentication / authenticated encryption | 16 |
| **MCUboot** | Open-source secure bootloader | 9, 16 |
| **OTA** | Over-the-air update | 16 |
| **PCROP / write protection** | Flash protection options | 16 |
| **SBOM** | Software bill of materials | 14, 16 |
| **secure boot / chain of trust** | Verifying each stage before running it | 16 |
| **TrustZone / secure element / TPM** | Hardware security features | 16 |

---

## 11. Zephyr, Rust, Linux

| Term | Meaning | Ch. |
|---|---|---|
| **alias / chosen / overlay (devicetree)** | App-level names / system selections / board modifications | 9 |
| **bindgen / cbindgen / cc crate** | Rust-C interop tools | 20 |
| **dm-verity** | Kernel verified read-only filesystem | 22 |
| **Embassy / RTIC** | Rust embedded async framework / interrupt-driven framework | 20 |
| **FIT image / U-Boot / TF-A** | Signed boot image format / bootloader / secure firmware | 22 |
| **heapless** | Rust no-alloc collections | 20 |
| **libgpiod / SPI dev / IIO** | Linux userspace hardware access | 22 |
| **PAC / HAL / embedded-hal** | Rust peripheral access crate / hardware layer / driver traits | 20 |
| **PREEMPT_RT** | Real-time Linux kernel preemption model | 22 |
| **RAUC / SWUpdate / Mender** | Linux update frameworks | 22 |
| **sysbuild** | Zephyr multi-image build | 9, 16 |

---

## 12. Units and common values

| Item | Value |
|---|---|
| STM32F746 Flash / RAM | 1 MB / 320 KB (DTCM 64 KB, SRAM1 240 KB, SRAM2 16 KB, ITCM 16 KB) |
| Flash base | `0x08000000` (AXIM), `0x00200000` (ITCM alias) |
| RAM base | `0x20000000` (DTCM), `0x20010000` (SRAM1), `0x2004C000` (SRAM2) |
| Peripheral base | `0x40000000` (APB1), `0x40010000` (APB2), `0x40020000` (AHB1) |
| Core peripherals | `0xE000E000` (SCS: SysTick `0xE000E010`, NVIC `0xE000E100`, SCB `0xE000ED00`) |
| System clock (max) | 216 MHz (APB1 54 MHz, APB2 108 MHz) |
| Typical UART baud and byte time | 115200, 8N1 ≈ 86.8 µs per bit-frame byte (≈ 11.5 kB/s) |
| 12-bit ADC LSB at 3.3 V | 0.806 mV |
| Common CRC check values (`"123456789"`) | CRC-16/CCITT-FALSE `0x29B1`, CRC-16/MODBUS `0x4B37`, CRC-32 (IEEE) `0xCBF43926` |
