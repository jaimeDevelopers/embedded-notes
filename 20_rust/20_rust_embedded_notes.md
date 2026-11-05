# 20. Embedded Rust on the STM32F746ZG

Rust is the most serious alternative to C/C++ for new embedded projects: memory safety without a garbage collector, a modern build tool, and a fast-growing ecosystem. This chapter is an **orientation and a starting kit**, not a full Rust course. Basic Rust knowledge (ownership, borrowing, traits, `Result`) helps; if you are new, read *The Rust Programming Language* first.

Prerequisites: chapters 3 (Cortex-M), 4 (debugging), 5-6 (C/C++), 7 (peripherals), 8 (architecture).

**Verification note.** The Rust embedded ecosystem moves fast: crate versions, feature names, and APIs change often. The commands below were checked against current documentation conventions (probe-rs, Embassy, defmt), but **crate versions and the exact `embassy-stm32` feature names must be copied from the Embassy repository's `examples/stm32f7` for the release you use**. The code here is illustrative and **not run on your board**. The STM32F7 family is better supported in Embassy than in some older HALs; confirm that your exact chip (`stm32f746zg`) is listed in the version you pick.

---

## 1. Why Rust, and the honest trade-offs

| Strength | Meaning for firmware |
|---|---|
| **Memory safety** | No use-after-free, no buffer overflows or data races in safe code: large classes of bugs from chapter 5 disappear at compile time |
| **Ownership of peripherals** | A peripheral exists once as a value; passing it around moves ownership: no two drivers can use the same UART by accident |
| **Zero-cost abstractions** | Generics and traits compile to code as small as hand-written C |
| **Modern tooling** | `cargo` builds, tests, formats (`rustfmt`), lints (`clippy`), manages dependencies reproducibly (`Cargo.lock`) |
| **Strong types** | Units, state machines as types (**type-state**), exhaustive `match` on enums |
| **Good error handling** | `Result`/`Option` and `?` instead of ignored return codes |
| **Testing** | `cargo test` on the host for `no_std` libraries; `defmt-test`/`embedded-test` on target |
| **Safety certification path** | Qualified toolchains exist (for example Ferrocene for ISO 26262/IEC 61508) |

| Costs and limits | Meaning |
|---|---|
| Learning curve | Ownership/borrowing and lifetimes take weeks to feel natural |
| `unsafe` is still needed | Registers, DMA, linker symbols, interrupts need `unsafe` blocks (kept small and wrapped) |
| Ecosystem maturity | Younger than C/C++: vendor SDKs, RTOS support, and certified libraries are thinner; STM32F7 coverage depends on the HAL/PAC |
| Compile times | Slower than C, especially with many dependencies |
| Binary size | Comparable to C in release with the right profile; debug builds are large |
| Existing code | You cannot reuse your C libraries without FFI (section 10) |
| Hiring and tooling inertia | Fewer engineers; IDE/debug integration improving (probe-rs, rust-analyzer) |

A pragmatic path: write **new, self-contained components** (parsers, protocol stacks, algorithms) in Rust and keep a C/C++ base, or start a new product fully in Rust if the ecosystem covers your hardware.

---

## 2. The ecosystem map

| Layer | Crates | Role |
|---|---|---|
| Core runtime | `cortex-m`, `cortex-m-rt` | Access to core registers (NVIC, SysTick, `asm::wfi`), startup, vector table, `#[entry]`, exception handlers |
| **PAC** (Peripheral Access Crate) | `stm32-metapac` (used by Embassy), `stm32f7` (svd2rust-generated) | Type-safe access to every register generated from SVD |
| **HAL** | **`embassy-stm32`** (async, all STM32 families), `stm32f7xx-hal` (community, blocking, less maintained) | Drivers: GPIO, UART, SPI, I2C, timers, ADC, DMA |
| Traits | **`embedded-hal`** (1.0), `embedded-hal-async`, `embedded-io` | Driver-portable interfaces (like your HAL layer in chapter 8) |
| Concurrency | **Embassy executor** (async/await tasks), **RTIC** (interrupt-driven, priority-based), or `cortex-m` + `critical-section` | Structured concurrency |
| Timing | `embassy-time` | `Timer::after`, `Instant`, `Duration`, `Ticker` |
| Logging | **`defmt`** + `defmt-rtt` | Compressed, deferred formatting over RTT: tiny and fast |
| Panic | `panic-probe` (prints and halts for the debugger), `panic-halt`, `panic-reset` | What happens on `panic!` |
| Collections | **`heapless`** (`Vec`, `String`, `spsc::Queue`...), `static_cell` | `no_std` fixed-capacity containers, no heap |
| Sync | `critical-section`, `embassy-sync` (channels, mutexes, signals) | Safe sharing |
| Drivers | Many `embedded-hal` crates for sensors, displays, memories | Reuse across HALs |
| Tooling | **`probe-rs`** (`cargo flash`, `cargo embed`, `probe-rs run`), `flip-link`, `cargo-binutils`, `cargo-bloat` | Flash, debug, RTT, stack overflow protection, size analysis |
| Testing | `embedded-test`, `defmt-test`, host `cargo test` | Tests on target and host |

Other notable pieces: **RTIC** (real-time interrupt-driven concurrency), **Hubris/Tock** (Rust OSes), **Zephyr Rust** (experimental), and `esp-hal` for Espressif.

---

## 3. Setup on Ubuntu

```bash
# Rust toolchain manager
curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs | sh
source "$HOME/.cargo/env"

rustup update stable
rustup target add thumbv7em-none-eabihf         # Cortex-M7 with FPU, hard-float ABI
rustup component add llvm-tools-preview rustfmt clippy rust-src

# Tooling
cargo install --locked probe-rs-tools           # probe-rs, cargo-flash, cargo-embed (needs libudev: sudo apt install libudev-dev pkg-config)
cargo install flip-link                         # stack-overflow protection linker wrapper
cargo install cargo-binutils cargo-bloat cargo-generate

probe-rs list                                   # lists connected probes (the ST-LINK of your Nucleo)
probe-rs chip list | grep -i STM32F746          # chip names probe-rs knows
```

Target notes:

- **`thumbv7em-none-eabihf`** is the standard target for Cortex-M4F/M7F: Thumb-2, ARMv7E-M, hard-float using the **single-precision FPU** (matching the F746's SP FPU, chapter 3). `thumbv7em-none-eabi` is the soft-float variant. (Double-precision M7 parts need extra target features, which matters only for the F76x/F77x and H7.)
- `llvm-tools-preview` provides `objdump`, `size`, `nm` via `cargo objdump` etc.
- udev rules for the ST-LINK are the same as before (chapter 4); probe-rs documents its own rules file if needed.

---

## 4. First project with Embassy (blink and logging)

### 4.1 Start from the official example

The most reliable way to get a working skeleton for **your exact chip and release** is to copy Embassy's example for the STM32F7 family:

```bash
git clone https://github.com/embassy-rs/embassy.git
ls embassy/examples/                          # stm32f7, stm32f4, ...
cp -r embassy/examples/stm32f7 my_f7_blinky   # then adapt Cargo.toml (paths to crates) and the chip features
```

Edit three things (the Embassy documentation stresses all three):

1. `Cargo.toml`: the **`embassy-stm32` chip feature** must be your chip (`stm32f746zg`).
2. `.cargo/config.toml`: the runner `probe-rs run --chip STM32F746ZGTx` (the **probe-rs chip name**).
3. `memory.x` (if used): Flash/RAM sizes.

### 4.2 Project layout

```
my_f7_blinky/
├── .cargo/config.toml
├── Cargo.toml
├── build.rs            # adds the linker scripts (link.x, defmt.x)
├── memory.x            # only if the HAL does not provide it ("memory-x" feature)
└── src/main.rs
```

`.cargo/config.toml`:

```toml
[target.thumbv7em-none-eabihf]
runner = "probe-rs run --chip STM32F746ZGTx"
# runner = "probe-rs run --chip STM32F746ZGTx --connect-under-reset"    # if the debug pins are reused

[build]
target = "thumbv7em-none-eabihf"

[env]
DEFMT_LOG = "info"
```

`Cargo.toml` (sketch: versions and feature names **must be taken from the example of your Embassy release**):

```toml
[package]
name = "blinky"
version = "0.1.0"
edition = "2021"

[dependencies]
embassy-stm32    = { version = "*", features = ["defmt", "stm32f746zg", "unstable-pac", "memory-x", "time-driver-any", "exti"] }
embassy-executor = { version = "*", features = ["arch-cortex-m", "executor-thread", "defmt"] }
embassy-time     = { version = "*", features = ["defmt", "tick-hz-32_768"] }
cortex-m         = { version = "0.7", features = ["inline-asm", "critical-section-single-core"] }
cortex-m-rt      = "0.7"
defmt            = "1.0"
defmt-rtt        = "1.0"
panic-probe      = { version = "1.0", features = ["print-defmt"] }

[profile.dev]
opt-level = 1            # debug builds at opt-level 0 can be too slow/large for embedded
debug = 2
[profile.release]
opt-level = "s"          # or "z"
lto = true
codegen-units = 1
debug = 2                # debug info does not go to Flash
panic = "abort"
```

(`"*"` is a placeholder: **pin real versions**; keep `Cargo.lock` in git for applications. Feature lists differ between releases.)

`build.rs`:

```rust
fn main() {
    println!("cargo:rustc-link-arg-bins=--nmagic");
    println!("cargo:rustc-link-arg-bins=-Tlink.x");
    println!("cargo:rustc-link-arg-bins=-Tdefmt.x");
}
```

`src/main.rs`:

```rust
#![no_std]
#![no_main]

use defmt::*;
use embassy_executor::Spawner;
use embassy_stm32::gpio::{Level, Output, Speed};
use embassy_time::Timer;
use {defmt_rtt as _, panic_probe as _};

#[embassy_executor::main]
async fn main(_spawner: Spawner) {
    let p = embassy_stm32::init(Default::default());   // clock and peripherals; returns ownership of all peripherals
    info!("start");

    let mut led = Output::new(p.PB7, Level::Low, Speed::Low);   // LD2 (blue) on the Nucleo
    loop {
        led.toggle();
        Timer::after_millis(500).await;                 // non-blocking: the CPU sleeps; other tasks can run
    }
}
```

```bash
cargo build --release
cargo run --release              # builds, flashes with probe-rs, shows defmt logs over RTT, Ctrl+C to stop
cargo size --release -- -A       # section sizes (cargo-binutils)
```

Concept checklist:

- `#![no_std]` (no standard library: only `core`), `#![no_main]` (the runtime provides `main` via the executor/`#[entry]`).
- `embassy_stm32::init` configures clocks (default config: HSI; set PLL, `Config { rcc: ... }` for 216 MHz: see the Embassy example for your family) and returns a `Peripherals` struct: **each peripheral is a separate value you can move once**.
- `Output::new(p.PB7, ...)` takes the pin by value: afterwards nobody else can use PB7 (compile error).
- `async fn` tasks run on the **executor**, cooperatively: `await` yields to other tasks; when all tasks wait, the executor sleeps the core with `WFI`: low power by design (chapter 15).

### 4.3 Debugging, logging, and RTT

- `defmt` logs (`info!`, `warn!`, `error!`, `debug!`, `trace!`, `assert!`) are **encoded** (string table stays on the host) and sent over **RTT** through the debug probe: very low overhead, usable in interrupts.
- `DEFMT_LOG=debug cargo run` changes the level at build time.
- `panic-probe` prints the panic message (and a backtrace with `print-defmt`) and triggers a breakpoint/halt for the debugger.
- **VS Code**: install the **probe-rs-debugger** extension and `rust-analyzer`; `launch.json` entries use `"type": "probe-rs-debug"` with `chip`, `coreConfigs` (`programBinary`, `rttEnabled`); `cargo embed` is an alternative with `Embed.toml` (chip, RTT, GDB server).
- `probe-rs gdb`/`probe-rs attach`, and the classic OpenOCD + `gdb-multiarch` flow of chapter 4 work with the same ELF.
- **HardFault**: `cortex-m-rt` lets you define `#[exception] unsafe fn HardFault(ef: &ExceptionFrame) -> !` to log the stacked frame (chapter 3).
- **`flip-link`** makes the stack grow **down into a guard area instead of the `.bss`/`.data`**: a stack overflow becomes a HardFault instead of silent corruption. Enable with `rustflags = ["-C", "linker=flip-link"]` in `.cargo/config.toml`.

---

## 5. Language concepts that matter on microcontrollers

### 5.1 Ownership applied to hardware

```rust
let p = embassy_stm32::init(Default::default());    // p owns all peripherals (singleton, taken once)
let led = Output::new(p.PB7, Level::Low, Speed::Low);   // PB7 moved into `led`
// p.PB7 can no longer be used here: compile-time protection against double configuration
```

Sharing a peripheral among tasks is explicit: put it in a `Mutex`/`Channel` (Embassy sync) or give one task ownership and send it messages (the "gatekeeper" of chapter 8/12, enforced by the compiler).

### 5.2 Type-state

A pin's mode is part of its **type**: `Output<'_>`, `Input<'_>`, `Flex`. You cannot call `set_high()` on an input; you convert with a call that consumes the old value. The same idea models "UART not yet configured" vs "configured" so that invalid sequences do not compile.

### 5.3 `unsafe` in embedded Rust

`unsafe` is needed for: raw register pointers (wrapped by the PAC), `static mut`, linker symbols, DMA buffers, interrupt handlers sharing state, FFI. Rules: keep `unsafe` blocks **tiny**, wrap them in a **safe API with documented invariants**, avoid `static mut` (use `StaticCell`, `Mutex<RefCell<...>>` from `critical-section`, atomics, or `embassy-sync`), and use `// SAFETY:` comments.

```rust
use core::cell::RefCell;
use critical_section::Mutex;

static COUNTER: Mutex<RefCell<u32>> = Mutex::new(RefCell::new(0));

fn tick() {
    critical_section::with(|cs| { *COUNTER.borrow(cs).borrow_mut() += 1; });   // interrupt-safe update
}
```

### 5.4 `no_std` and allocation

Without an allocator there is no `Vec`/`String`/`Box`. Use **`heapless`** containers with compile-time capacity:

```rust
use heapless::{Vec, String};
let mut buf: Vec<u8, 64> = Vec::new();
buf.push(0xAA).unwrap();                         // returns Err when full: you must handle it
let mut s: String<32> = String::new();
use core::fmt::Write;
write!(s, "v={}", 42).unwrap();
```

An allocator (`embedded-alloc`) is possible but defeats the predictability goals; prefer static allocation (chapters 8, 12).

### 5.5 Error handling

```rust
#[derive(Debug, defmt::Format)]
enum Error { Timeout, Crc, Bus }

fn read_sensor(bus: &mut impl embedded_hal::i2c::I2c) -> Result<i16, Error> {
    let mut b = [0u8; 2];
    bus.write_read(0x48, &[0x00], &mut b).map_err(|_| Error::Bus)?;
    Ok(i16::from_be_bytes(b))
}
```

`Result` and `?` replace the `status_t` + `RETURN_IF_ERR` macro pattern of chapter 8; the compiler warns if you ignore a `Result` (`#[must_use]`).

### 5.6 Generics and traits as a HAL

Write a driver against `embedded-hal` traits and it runs on any HAL (STM32, nRF, RP2040, host test fakes), mirroring the interface/fake design of chapter 8:

```rust
pub struct Tmp<I2C> { i2c: I2C, addr: u8 }
impl<I2C: embedded_hal::i2c::I2c> Tmp<I2C> {
    pub fn new(i2c: I2C, addr: u8) -> Self { Self { i2c, addr } }
    pub fn read_milli_c(&mut self) -> Result<i32, I2C::Error> {
        let mut b = [0u8; 2];
        self.i2c.write_read(self.addr, &[0], &mut b)?;
        Ok((i16::from_be_bytes(b) as i32) * 1000 / 256)
    }
}
```

`embedded-hal-mock` or a hand-written fake implementing the trait lets you test the driver with `cargo test` on the PC.

---

## 6. Concurrency models

### 6.1 Embassy (async/await)

```rust
use embassy_executor::Spawner;
use embassy_sync::{blocking_mutex::raw::CriticalSectionRawMutex, channel::Channel};

static EVENTS: Channel<CriticalSectionRawMutex, u32, 8> = Channel::new();

#[embassy_executor::task]
async fn sensor_task() {
    loop {
        EVENTS.send(read_adc()).await;             // waits if the channel is full
        embassy_time::Timer::after_millis(100).await;
    }
}

#[embassy_executor::task]
async fn logger_task() {
    loop {
        let v = EVENTS.receive().await;
        defmt::info!("sample {}", v);
    }
}

#[embassy_executor::main]
async fn main(spawner: Spawner) {
    let _p = embassy_stm32::init(Default::default());
    spawner.spawn(sensor_task()).unwrap();          // exact spawn API changed between releases
    spawner.spawn(logger_task()).unwrap();
}
```

Properties: tasks are **state machines compiled from `async fn`** (no per-task stack; one shared stack), cooperative within an executor, with **interrupt executors** for higher-priority work (multiple executors at different interrupt priorities give preemption between executors). Peripheral async drivers (UART with DMA, I2C, SPI, EXTI input waiting) turn interrupts into `await` points, so the code reads linearly (compare with callbacks and ISR flags in chapter 7).

Rules: never block (use `.await` or `embassy_time::block_for` only for tiny delays), keep tasks small, handle `Result`s, avoid long computations without yielding.

### 6.2 RTIC

A framework where tasks are bound to interrupts, with compile-time **priority-based resource sharing** (Stack Resource Policy): deadlock-free and data-race-free by construction, with zero runtime overhead beyond `BASEPRI` manipulation. Fits hard-real-time designs with hardware-timed tasks. (RTIC v2 syntax differs from v1: consult the book.)

### 6.3 RTOS or `critical-section` only

You can also use FreeRTOS or Zephyr from Rust through bindings (experimental), or write a superloop with interrupts using `critical-section::Mutex` and `heapless::spsc::Queue`, as in chapters 5 and 8.

---

## 7. Peripherals with Embassy (patterns)

```rust
// UART with DMA, async
use embassy_stm32::{bind_interrupts, peripherals, usart::{self, Config, Uart}};
bind_interrupts!(struct Irqs { USART3 => usart::InterruptHandler<peripherals::USART3>; });

let mut uart = Uart::new(p.USART3, p.PD9 /*RX*/, p.PD8 /*TX*/, Irqs, p.DMA1_CH3, p.DMA1_CH1, Config::default()).unwrap();
uart.write(b"hello\r\n").await.unwrap();
let mut buf = [0u8; 8];
uart.read(&mut buf).await.unwrap();
```

```rust
// Button via EXTI, awaiting the edge
use embassy_stm32::exti::ExtiInput;
use embassy_stm32::gpio::Pull;
let mut button = ExtiInput::new(p.PC13, p.EXTI13, Pull::None);
button.wait_for_rising_edge().await;
```

```rust
// ADC read (API differs by release)
use embassy_stm32::adc::Adc;
let mut adc = Adc::new(p.ADC1);
let raw: u16 = adc.blocking_read(&mut p.PA3);
```

The exact **signatures change between Embassy releases** (DMA channel arguments, interrupt binding macros, ADC API). Use the `examples/stm32f7` and `examples/stm32f4` sources for your release as the reference, and the docs at <https://docs.embassy.dev/embassy-stm32/>. Start from those examples instead of from memory.

---

## 8. Build, size, and testing

### 8.1 Cargo workflow

```bash
cargo fmt && cargo clippy -- -D warnings           # format and lint (clippy catches many mistakes)
cargo build --release
cargo size --release -- -A                          # sections (cargo-binutils)
cargo bloat --release -n 20                         # largest functions
cargo bloat --release --crates                      # size per crate
cargo nm --release | less
cargo objdump --release -- -d -S | less             # disassembly with source
cargo doc --open                                    # docs of your crate and dependencies
```

Profile tips: `opt-level = "s"` or `"z"` for size, `lto = true`, `codegen-units = 1`, `panic = "abort"`; avoid heavy formatting (`core::fmt`) in size-critical code (`defmt` is far smaller than `core::fmt`/`println!`); watch generics bloat.

### 8.2 Testing

- **Host unit tests** for `#![no_std]` libraries: put logic in a library crate with `#![cfg_attr(not(test), no_std)]` and run `cargo test` on the PC (parsers, state machines, filters, CRC): the same seam idea as chapters 8 and 14. Property tests with `proptest`, fuzzing with `cargo fuzz` (libFuzzer) on parsers (chapter 14).
- **On-target tests**: **`embedded-test`** together with `probe-rs run` flashes the test binaries, runs them on the board and reports results as a libtest-compatible runner (set the runner in `.cargo/config.toml`, add `harness = false` and the linker argument in `build.rs`). `defmt-test` is another option.
- **HIL**: use the same `pytest` approach of chapter 14 with the device's CLI/logs.

### 8.3 CI

```yaml
- uses: dtolnay/rust-toolchain@stable
  with: { targets: thumbv7em-none-eabihf, components: "clippy, rustfmt" }
- run: cargo fmt --check && cargo clippy --target thumbv7em-none-eabihf -- -D warnings
- run: cargo build --release --target thumbv7em-none-eabihf
- run: cargo test --lib                  # host tests for the no_std library crate
```

Cache `~/.cargo` and `target/`; commit `Cargo.lock`; use `cargo deny` / `cargo audit` for dependency licenses and vulnerabilities (SBOM-friendly, chapter 16).

---

## 9. Cortex-M7 and STM32F7 specifics

- **FPU**: the `hf` target enables hardware float; the runtime (`cortex-m-rt` with the `fpu` handling) enables CPACR before use in recent versions: if you see UNDEFINSTR/NOCP, check that the FPU is enabled in startup and that you did not use `f64` (software emulation on an SP FPU, as in chapter 3).
- **Caches and DMA**: the same cache-coherency rules apply (chapter 3): non-cacheable DMA buffers via MPU or explicit clean/invalidate with `cortex_m::peripheral::SCB` methods (`clean_dcache_by_slice`, `invalidate_dcache_by_slice`), buffers aligned to 32 bytes (`#[repr(align(32))]`).
- **Clock config**: Embassy's `Config` has an `rcc` section (HSE, PLL multipliers, prescalers) for 216 MHz: copy the F7 example and adjust for the Nucleo (8 MHz bypass, chapter 7).
- **Linker script**: `cortex-m-rt` uses `memory.x` for `FLASH`/`RAM` regions (`FLASH : ORIGIN = 0x08000000, LENGTH = 1024K`, `RAM : ORIGIN = 0x20000000, LENGTH = 320K`); extra regions (ITCM, DTCM) need custom sections in a linker script fragment.
- **Interrupt priorities**: NVIC priority bits (4 on STM32), and Embassy interrupt executors assign priorities explicitly; the same BASEPRI/priority-group concepts as chapters 3 and 12.
- **Debug pins**: use `--connect-under-reset` if the firmware reconfigures SWD pins or sleeps (chapter 4).

---

## 10. Mixing C and Rust

### 10.1 Calling C from Rust

```rust
extern "C" { fn crc16_ccitt(data: *const u8, len: usize) -> u16; }

pub fn crc(data: &[u8]) -> u16 {
    unsafe { crc16_ccitt(data.as_ptr(), data.len()) }       // SAFETY: pointer and length come from a valid slice
}
```

Generate bindings with **`bindgen`** and build C sources with the **`cc`** crate from `build.rs` (use your toolchain's `arm-none-eabi-gcc` as the C compiler). Useful to reuse vendor HAL/RTOS code during a migration.

### 10.2 Calling Rust from C

```toml
# Cargo.toml
[lib]
crate-type = ["staticlib"]
```

```rust
#![no_std]
#[no_mangle]
pub extern "C" fn rs_checksum(data: *const u8, len: usize) -> u32 {
    let s = unsafe { core::slice::from_raw_parts(data, len) };
    s.iter().fold(0u32, |a, &b| a.wrapping_add(b as u32))
}
#[panic_handler]
fn panic(_: &core::panic::PanicInfo) -> ! { loop {} }
```

Link the produced `libxxx.a` into your CMake firmware (`target_link_libraries`) and declare the function in a C header (`cbindgen` generates headers). This lets you port **one module at a time** (a parser, a protocol) into an existing C project. Take care with `panic` handling (never unwind across FFI: `panic = "abort"`), `repr(C)` for shared structs, and allocator choices.

---

## 11. When to choose what (summary)

| Situation | Suggestion |
|---|---|
| Learning, vendor SDK-heavy product | C/C++ (this series) |
| New component with complex parsing/concurrency | Rust library crate, tested on the host, called from C via FFI |
| New product, ecosystem covers the MCU, team willing to invest | Embassy or RTIC in Rust |
| Need certified RTOS/middleware today | C/C++ with a certified RTOS (or check Rust-qualified toolchains) |
| Very small MCU, hand-tuned code | C |
| You want a platform with drivers and OS services | Zephyr (chapter 9) |

---

## 12. Exercises

1. **Install and verify**: set up Rust, `probe-rs`, `flip-link`; run `probe-rs list` and `probe-rs chip list | grep STM32F746`.
2. **Blinky**: copy Embassy's `examples/stm32f7`, adjust chip features/runner, blink LD2 and print `defmt` logs.
3. **Read the binary**: `cargo size`, `cargo bloat`, `cargo objdump`; compare the blinky's size with your C version.
4. **Button**: await EXTI edges on PC13 and toggle an LED; add debounce with `Timer::after`.
5. **UART**: async echo over USART3 (the ST-LINK VCP), then a request/response loop using the frame protocol of chapter 11 implemented as a `no_std` library crate with host tests.
6. **Tasks and channels**: sensor task producing ADC values to a logger task through `embassy_sync::channel::Channel`; count drops under load.
7. **Interrupt executor**: run a high-priority control task in an interrupt executor and a low-priority logging task in the thread executor; measure jitter on a GPIO.
8. **Panic and fault handling**: trigger a `panic!`, an index out of bounds, and a HardFault handler logging the frame; inspect with `probe-rs` and gdb.
9. **Stack overflow**: provoke it with and without `flip-link`; compare behavior.
10. **Driver generic over `embedded-hal`**: write an I2C sensor driver with a fake bus implementing the trait, tested with `cargo test`.
11. **Fuzzing**: `cargo fuzz` your COBS decoder against the C one (via FFI) with differential testing.
12. **FFI**: call your C `crc16_ccitt` from Rust, then expose a Rust function to C and link it into the CMake project of chapter 2.
13. **On-target tests**: add `embedded-test` and run a test on the Nucleo.
14. **Port a chapter 8 module** (event queue or table-driven state machine) to Rust and compare size, safety checks, and effort.

---

## 13. Cheat sheet

```
Setup     rustup target add thumbv7em-none-eabihf ; cargo install --locked probe-rs-tools flip-link
Config    .cargo/config.toml: runner = "probe-rs run --chip STM32F746ZGTx", target = "thumbv7em-none-eabihf"
Crates    embassy-stm32 (feature stm32f746zg) + embassy-executor + embassy-time + defmt + defmt-rtt + panic-probe + cortex-m-rt
Run       cargo run --release   (flash + RTT logs)    cargo size / bloat / objdump
Key ideas ownership of peripherals ; async tasks + await ; defmt logging ; heapless containers ; Result + ? ; small unsafe
Test      host: cargo test (no_std lib crates), proptest, cargo fuzz ; target: embedded-test + probe-rs
Mixed     extern "C" + bindgen + cc ; staticlib + cbindgen ; panic = "abort"
Check     copy versions/features from embassy/examples/stm32f7 for your release
```

---

## 14. Where this leads

- **Embassy book and docs** for the executor, time driver, and peripherals; **RTIC book** for the interrupt-driven model.
- **Embedded Rust Book**, **Discovery book**, **The Embedonomicon** (how the runtime, linker script and `no_std` work).
- **Async I/O at scale**: networking with `embassy-net`, USB with `embassy-usb`, BLE with `trouble`.
- **Certification and safety**: qualified Rust toolchains (Ferrocene), Rust for safety-critical coding guidelines.
- **Python tooling** (chapter 17): the same test harnesses and log analysis around Rust firmware.

## References

- The Embedded Rust Book: <https://docs.rust-embedded.org/book/>
- Embassy: <https://embassy.dev> and <https://github.com/embassy-rs/embassy> (see `examples/`)
- probe-rs: <https://probe.rs>; defmt: <https://defmt.ferrous-systems.com>; flip-link; `cortex-m-rt`; `embedded-hal`
- RTIC: <https://rtic.rs>; `heapless`; `embedded-test`
- *The Rust Programming Language* (free online); *The Embedonomicon*; *Rust for Embedded C Programmers*
- Ferrous Systems training materials; Ferrocene (qualified compiler)
