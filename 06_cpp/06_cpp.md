# 6. C++ for Embedded Systems

Target: Cortex-M7 (STM32F746ZG), `arm-none-eabi-g++` 14, newlib-nano, baseline `-std=c++17`.

Prerequisites: chapter 0 (toolchain, startup, `.init_array`), chapter 2 (CMake), chapter 3 (Cortex-M), chapter 5 (C for embedded). C++ keeps everything from C, so this chapter only covers **what C++ adds, what it costs, and what to turn off**.

---

## 1. Why C++ on a microcontroller

The promise is **zero-overhead abstraction**: you do not pay for what you do not use, and what you do use is no slower than the hand-written C equivalent. In embedded work the gains are:

| Gain | How |
|---|---|
| Type safety | `enum class`, strong types, templates instead of `void *` and macros |
| Compile-time work | `constexpr` tables, `static_assert`, templates: the computation happens on your PC, not on the chip |
| Resource safety | RAII: a lock or peripheral is released when the scope ends, on every path |
| Encapsulation | Classes with private state instead of file-level globals |
| Reuse without macros | Templates for drivers, ring buffers, register access |
| Testability | Templates and interfaces make hardware-free host tests easy |

And the risks, which are the reason embedded C++ has a reputation:

| Risk | Cause |
|---|---|
| Large code size | Exceptions, RTTI, `iostream`, `std::string`/`std::vector`, template bloat |
| Hidden heap use | `new`, `std::function`, `std::string`, `std::vector`, `std::shared_ptr` |
| Hidden code at startup | Global constructors run **before `main`**, possibly before hardware is ready |
| Non-determinism | Exceptions, dynamic allocation, virtual dispatch you did not intend |
| Footguns with hardware | `volatile` rules differ, name mangling breaks ISR names |

The working style: **use C++ as "C with classes, templates, `constexpr`, and RAII"**, with exceptions, RTTI and dynamic allocation switched off.

### Language versions

| Standard | Notable features for embedded |
|---|---|
| C++11 | `auto`, lambdas, `constexpr`, `enum class`, `nullptr`, `override`/`final`, `static_assert`, `<cstdint>`, `<array>`, `<atomic>`, `<type_traits>`, move semantics |
| C++14 | Relaxed `constexpr` (loops, locals), generic lambdas, `0b1010` binary literals, digit separators `1'000'000` |
| **C++17** | `if constexpr`, `inline` variables, structured bindings, fold expressions, `std::optional`, `std::variant`, `std::string_view`, CTAD, `[[nodiscard]]`, `constexpr` lambdas, `constexpr std::array` access |
| C++20 | Concepts, `consteval`, `constinit`, `std::span`, `<bit>` (`std::bit_cast`, `std::popcount`), designated initializers, `<=>`, `[[likely]]`. **Deprecates** compound assignment and `++` on `volatile` |
| C++23 | `std::expected`, `std::to_underlying`, `std::unreachable`, `if consteval`, `static operator()` |

GCC 14 supports up to C++23 for the language; the library subset available on `arm-none-eabi` is what newlib's libstdc++ ships (no threads, no filesystem, no `<regex>` worth using). This chapter assumes C++17 and notes where C++20/23 help.

---

## 2. Toolchain setup

### Install

```bash
sudo apt install gcc-arm-none-eabi binutils-arm-none-eabi libnewlib-arm-none-eabi libstdc++-arm-none-eabi-newlib
arm-none-eabi-g++ --version
arm-none-eabi-g++ -print-multi-lib
ls /usr/lib/arm-none-eabi/include/c++/        # libstdc++ headers
```

If linking fails with missing `libstdc++`, the `libstdc++-arm-none-eabi-newlib` package is the first thing to check.

### The compile and link flags that matter

| Flag | Purpose |
|---|---|
| `-std=c++17` (CMake: `CMAKE_CXX_STANDARD 17`, `CMAKE_CXX_EXTENSIONS OFF` for strict ISO) | Language level |
| `-fno-exceptions` | No exception tables or unwinding. `throw`/`try` become compile errors. Biggest single saving |
| `-fno-rtti` | No `typeid`/`dynamic_cast` and no type-info objects |
| `-fno-threadsafe-statics` | Function-local statics are initialized without lock guards (`__cxa_guard_*`). Single-threaded or controlled init only |
| `-fno-use-cxa-atexit` | Global destructors use `atexit` instead of `__cxa_atexit` (avoids needing `__dso_handle`) |
| `-fno-asynchronous-unwind-tables` | No `.eh_frame`/`.ARM.exidx` for nothing |
| `-ffunction-sections -fdata-sections` with `-Wl,--gc-sections` | Drop unused code (templates, unused methods) |
| `-Os` | Size optimization |
| `--specs=nano.specs` | Also selects the **nano libstdc++** (`libstdc++_nano.a`), smaller |
| `-Wl,--print-memory-usage` | See Flash/RAM use after every build |

Warnings worth adding for C++:

```
-Wall -Wextra -Wshadow -Wconversion -Wold-style-cast -Wnon-virtual-dtor
-Woverloaded-virtual -Wsuggest-override -Wundef -Wdouble-promotion -Wnull-dereference
```

### Linking must use the C++ driver

`arm-none-eabi-g++` links `libstdc++` and `libsupc++` automatically. Linking C++ objects with `arm-none-eabi-gcc` gives `undefined reference to __cxa_...` / `operator new`. CMake chooses the C++ driver for a target that has any `.cpp` source. If a target has only C++ in libraries, set `LINKER_LANGUAGE CXX`.

### Support file for the bare-metal runtime

Create `src/cxx_support.cpp`. You may need only some of these, depending on what you use:

```cpp
#include <cstdlib>
#include <cstddef>

extern "C" {

/* Needed if any class has a pure virtual function and you want to control what happens
   if one is ever called (libsupc++ also provides one, but it pulls in terminate handling). */
void __cxa_pure_virtual()
{
    for (;;) { }
}

/* Only needed if you register global destructors with __cxa_atexit.
   With -fno-use-cxa-atexit you usually do not need it. */
void *__dso_handle = nullptr;

}   /* extern "C" */

/* If you want to keep malloc/free out of the image: stub operator delete.
   Needed by virtual destructors ("deleting destructors"), even if you never call delete. */
void operator delete(void *) noexcept { }
void operator delete(void *, std::size_t) noexcept { }

/* Optional: make a forbidden `new` fail loudly instead of pulling the heap */
void *operator new(std::size_t)
{
    for (;;) { }          /* trap in the debugger: any `new` is a design error here */
}

/* Replaces the default terminate handler that demangles the exception name.
   Saves tens of KB by not pulling the demangler and stdio. */
namespace __gnu_cxx {
void __verbose_terminate_handler() { for (;;) { } }
}
```

Notes:

- Overriding `operator new`/`delete` is the way to *prove* no heap is used: you get a link or run-time trap if something allocates.
- Test the size effect of the `__verbose_terminate_handler` trick with `arm-none-eabi-size` before and after; it is a well-known one, but verify with your toolchain.
- If you actually use a heap, remove the `new`/`delete` stubs and let libstdc++'s versions (which call `malloc`/`free`) link.

### What the linker script must contain

Constructors of global objects are called through `__libc_init_array`, which walks the `.init_array` section. Your linker script (from chapter 0) already has it:

```ld
.preinit_array : { PROVIDE_HIDDEN(__preinit_array_start = .); KEEP(*(.preinit_array*)) PROVIDE_HIDDEN(__preinit_array_end = .); } >FLASH
.init_array    : { PROVIDE_HIDDEN(__init_array_start = .);    KEEP(*(SORT(.init_array.*))) KEEP(*(.init_array*)) PROVIDE_HIDDEN(__init_array_end = .); } >FLASH
.fini_array    : { PROVIDE_HIDDEN(__fini_array_start = .);    KEEP(*(SORT(.fini_array.*))) KEEP(*(.fini_array*)) PROVIDE_HIDDEN(__fini_array_end = .); } >FLASH
```

and the startup must call `__libc_init_array()` before `main` (ST's startup does). If constructors never run, check both. Verify:

```bash
arm-none-eabi-readelf -S build/blink.elf | grep init_array
arm-none-eabi-nm -C build/blink.elf | grep -E "__libc_init_array|__init_array"
```

---

## 3. CMake for C++

Toolchain file additions (chapter 2 style):

```cmake
set(CMAKE_CXX_COMPILER arm-none-eabi-g++)
set(CMAKE_CXX_FLAGS_DEBUG_INIT   "-Og -g3")
set(CMAKE_CXX_FLAGS_RELEASE_INIT "-Os -DNDEBUG")
```

`CMakeLists.txt`:

```cmake
cmake_minimum_required(VERSION 3.16...4.2)
project(blink C CXX ASM)

set(CMAKE_CXX_STANDARD 17)
set(CMAKE_CXX_STANDARD_REQUIRED ON)
set(CMAKE_CXX_EXTENSIONS OFF)             # -std=c++17 instead of gnu++17

add_executable(blink
  src/main.cpp
  src/cxx_support.cpp
  src/drivers/uart.c                       # C and C++ files can be mixed
  boards/stm32f746/vendor/system_stm32f7xx.c
  boards/stm32f746/vendor/startup_stm32f746xx.s)

# C++-only flags: use ';' between flags inside a generator expression (no spaces!)
target_compile_options(blink PRIVATE
  $<$<COMPILE_LANGUAGE:CXX>:-fno-exceptions;-fno-rtti;-fno-threadsafe-statics;-fno-use-cxa-atexit;-fno-asynchronous-unwind-tables>
  $<$<COMPILE_LANGUAGE:CXX>:-Wold-style-cast;-Wnon-virtual-dtor;-Woverloaded-virtual;-Wsuggest-override>)

target_link_options(blink PRIVATE
  ${ARCH_FLAGS}
  -T${LINKER_SCRIPT}
  --specs=nano.specs --specs=nosys.specs
  -Wl,--gc-sections -Wl,--print-memory-usage)
```

Generator-expression spacing: `$<$<CONFIG:Debug>:-Og -g3>` with a space is split by CMake into two arguments and breaks. Use `$<$<CONFIG:Debug>:-Og;-g3>` or quote it.

Keep `.c` files as `.c`: they are compiled by the C compiler with C rules. Only rename to `.cpp` if you intend to adopt C++ rules (section 12).

---

## 4. What costs what

| Feature | Flash/RAM cost | Verdict |
|---|---|---|
| Classes, methods, `static` members, namespaces | None | Use freely |
| Inline functions, `constexpr`, `static_assert` | None (or less code) | Use freely |
| `enum class`, `auto`, `nullptr`, range-for, `override`/`final` | None | Use freely |
| Templates | Code per instantiation; none if unused | Use, but watch bloat |
| Lambdas (non-capturing, or capturing used as templates) | None | Use |
| `std::array`, `std::optional`, `std::variant`, `std::string_view`, `std::span`, `std::bitset` | Header-only, small | Use |
| `<type_traits>`, `<utility>`, `<algorithm>`, `<numeric>`, `<cstdint>`, `<atomic>`, `<bit>` | Small | Use |
| Constructors of globals/statics | Runs before `main`; small | Use with care (section 7) |
| Virtual functions | 4-byte vptr per object + vtable in Flash + indirect call | OK where you want runtime polymorphism |
| `new`/`delete`, `std::vector`, `std::string`, `std::map`, `std::list` | Heap + `malloc` + often tens of KB | Avoid, or use fixed-capacity versions |
| `std::function` | May allocate; type-erased call | Avoid; use templates or function pointers |
| `std::shared_ptr`, `std::make_shared` | Heap + atomic refcount | Avoid |
| Exceptions | Unwind tables + runtime (tens of KB) | Disable |
| RTTI (`typeid`, `dynamic_cast`) | Type-info objects | Disable |
| `iostream` | Huge (locales, static init) | Never |
| `<thread>`, `<mutex>`, `<future>`, `<regex>`, `<filesystem>`, `thread_local` | Not usable on bare metal | Never |
| `std::string` formatting `std::to_string`, `<sstream>` | Heap, locale | Avoid; use `snprintf` or hand-written |

Measure, do not guess: build once, then

```bash
arm-none-eabi-size build/blink.elf
arm-none-eabi-nm -C --size-sort -S build/blink.elf | tail -20     # -C demangles C++ names
```

Add a feature, rebuild, compare. If Flash jumps by more than expected, `nm -C --size-sort` points to the culprit.

---

## 5. Classes, RAII, and resource safety

### A class is a struct with rules

```cpp
class Led {
public:
    explicit Led(unsigned pin) : pin_(pin) { }
    void on()  const { GPIOB->BSRR = 1U << pin_; }
    void off() const { GPIOB->BSRR = 1U << (pin_ + 16U); }
private:
    unsigned pin_;
};
```

`sizeof(Led)` is 4 bytes, the same as a plain `uint32_t`. Methods are ordinary functions with an extra `this` argument. No hidden cost.

### Rules of good style

- `explicit` on single-argument constructors, to forbid accidental conversions.
- `const` methods for anything that does not change the object.
- `= delete` to forbid copying of objects that own hardware: `Uart(const Uart &) = delete;`
- `noexcept` on functions that cannot fail (with `-fno-exceptions` it is documentation and sometimes a small code-size gain).
- Prefer composition to inheritance.
- `final` on classes and methods not meant to be overridden (lets the compiler devirtualize).

### RAII: acquire in the constructor, release in the destructor

A critical section guard (compare with the C version in chapter 5):

```cpp
class IrqLock {
public:
    IrqLock() : primask_(__get_PRIMASK()) { __disable_irq(); }
    ~IrqLock() { __set_PRIMASK(primask_); }
    IrqLock(const IrqLock &) = delete;
    IrqLock &operator=(const IrqLock &) = delete;
private:
    std::uint32_t primask_;
};

void add_sample(std::uint32_t v)
{
    IrqLock lock;                 /* interrupts masked here */
    sum_ += v;
    ++count_;
}                                 /* restored on every exit path: return, early return, ... */
```

In C, forgetting to restore PRIMASK on one `return` is a classic bug. Here the compiler cannot forget. At `-Os` the guard compiles to the same few instructions you would have written by hand.

Other RAII uses: enabling a peripheral clock for a scope, chip-select assertion for an SPI transaction, "disable DMA, restore it afterwards", scope timers (`DWT->CYCCNT` difference printed in the destructor).

### Statics and namespaces instead of singletons

A peripheral exists once. Do not build a Singleton class; use a namespace, a `static` instance, or a class with only `static` members:

```cpp
namespace uart3 {
    void init(std::uint32_t baud);
    void write(const char *s);
}
```

Or create the single instance in `main` and pass it by reference (dependency injection), which is what makes testing possible (section 11).

---

## 6. `constexpr`, `static_assert`, and compile-time computation

### Move work to compile time

```cpp
constexpr std::uint32_t kPclk1   = 16'000'000U;       /* digit separator (C++14) */
constexpr std::uint32_t kBaud    = 115'200U;

constexpr std::uint32_t brr(std::uint32_t clk, std::uint32_t baud)
{
    return (clk + baud / 2U) / baud;                   /* rounded */
}
static_assert(brr(kPclk1, kBaud) == 139U, "unexpected UART divisor");

USART3->BRR = brr(kPclk1, kBaud);                      /* a constant; no division on the chip */
```

### Tables generated by the compiler

```cpp
#include <array>
#include <cstdint>

constexpr std::array<std::uint32_t, 256> make_crc32_table()
{
    std::array<std::uint32_t, 256> t{};
    for (std::uint32_t i = 0; i < 256U; ++i) {
        std::uint32_t c = i;
        for (int k = 0; k < 8; ++k) { c = (c & 1U) ? (0xEDB88320U ^ (c >> 1)) : (c >> 1); }
        t[i] = c;
    }
    return t;
}
inline constexpr auto kCrcTable = make_crc32_table();   /* in Flash (.rodata); no startup code */
```

Verify it is in Flash: `arm-none-eabi-nm -C -S build/blink.elf | grep kCrcTable` shows type `R` (read-only). If it shows `B`/`D` it is in RAM and was not constant-initialized.

### What is `constexpr`, `consteval`, `constinit`

| Keyword | Meaning |
|---|---|
| `constexpr` | May be evaluated at compile time; guaranteed if used in a constant context |
| `consteval` (C++20) | **Must** be evaluated at compile time |
| `constinit` (C++20) | A variable that is constant-initialized (no dynamic init) but still mutable |
| `static_assert` | Compile-time check with a message |
| `if constexpr` (C++17) | Branch chosen at compile time; the other branch is not even compiled |

`constinit` is the safe tool against the static-initialization-order problem (section 7): it guarantees that a global is initialized by the linker, not by startup code.

### User-defined literals and strong types for units

```cpp
struct Milliseconds { std::uint32_t value; };
struct Hertz        { std::uint32_t value; };

constexpr Milliseconds operator""_ms(unsigned long long v) { return {static_cast<std::uint32_t>(v)}; }
constexpr Hertz        operator""_Hz(unsigned long long v) { return {static_cast<std::uint32_t>(v)}; }

void delay(Milliseconds t);
delay(500_ms);                 /* delay(500) cannot be confused with microseconds or ticks */
```

Mixing up microseconds and milliseconds, or Hz and kHz, is a classic firmware bug; strong types remove it at no run-time cost.

### Bitmask `enum class`

```cpp
enum class Flag : std::uint8_t { None = 0, Rx = 1U << 0, Tx = 1U << 1, Error = 1U << 2 };

constexpr Flag operator|(Flag a, Flag b)
{ return static_cast<Flag>(static_cast<std::uint8_t>(a) | static_cast<std::uint8_t>(b)); }
constexpr bool has(Flag set, Flag f)
{ return (static_cast<std::uint8_t>(set) & static_cast<std::uint8_t>(f)) != 0U; }

Flag f = Flag::Rx | Flag::Error;
if (has(f, Flag::Error)) { /* ... */ }
```

An `enum class` does not convert to `int` implicitly and has its own scope, so `Flag::Rx` cannot collide with another enum's `Rx`.

---

## 7. Startup, constructors and static initialization

### What happens before `main`

```
Reset_Handler
  ├─ copy .data, zero .bss
  ├─ SystemInit()
  ├─ __libc_init_array()  ──►  runs every function in .init_array  = constructors of your global objects
  └─ main()
```

For each global/static object with a non-trivial constructor, the compiler places a pointer to an initialization function in `.init_array`.

### Dangers

1. **Hardware not ready.** Constructors run before `main`. If `Uart uart3;` has a constructor that writes to USART registers, the clock tree may not be set up, and the peripheral clock is not enabled yet: bus fault or silent failure.
2. **Initialization order between files is unspecified** (the *static initialization order fiasco*). Object A in `a.cpp` may use object B from `b.cpp` before B is constructed.
3. **Code you did not write runs before `main`**, which makes startup behavior harder to reason about and debug.

### Rules

- **Constructors must not touch hardware.** They only store configuration. Put hardware setup in `init()` called from `main`.
- Prefer **`constexpr` constructors** with `constexpr`/`constinit` globals: the object is built by the linker with no startup code at all.

```cpp
class Pin {
public:
    constexpr Pin(std::uint32_t base, unsigned n) : base_(base), n_(n) { }
    void init();                       /* hardware access here, called from main */
private:
    std::uint32_t base_;
    unsigned      n_;
};

constinit Pin led{GPIOB_BASE, 7};       /* C++20; in C++17 use constexpr + inline */
```

- Static local objects (`static Foo f;` inside a function) are initialized the first time the function runs (construct-on-first-use). That avoids the order problem; with `-fno-threadsafe-statics` there are no guard calls (only safe if no interrupt or second thread can race the first call).
- Global destructors never run on a firmware that never exits. Keep destructors trivial where possible.

### Verifying

```bash
arm-none-eabi-nm -C build/blink.elf | grep -i "_GLOBAL__sub_I"      # one entry per TU with dynamic init
arm-none-eabi-objdump -s -j .init_array build/blink.elf             # the table itself
```

If you see no `_GLOBAL__sub_I_*` symbols, the compiler constant-initialized everything: ideal. In gdb, `break __libc_init_array` then `finish` lets you step through constructors.

---

## 8. Templates for hardware

### Register access without macros

```cpp
#include <cstdint>

template <std::uintptr_t Addr>
struct Reg32 {
    static std::uint32_t read()                 { return *reinterpret_cast<volatile std::uint32_t *>(Addr); }
    static void write(std::uint32_t v)          { *reinterpret_cast<volatile std::uint32_t *>(Addr) = v; }
    static void set(std::uint32_t mask)         { write(read() | mask); }
    static void clear(std::uint32_t mask)       { write(read() & ~mask); }
    static void modify(std::uint32_t mask, std::uint32_t value) { write((read() & ~mask) | (value & mask)); }
};

using Gpiob_Odr = Reg32<0x40020414UL>;
Gpiob_Odr::set(1U << 7);
```

Everything is `static` and inlined: this compiles to the same `ldr/orr/str` as the C version, and the address is a template parameter, so the compiler knows it at compile time. `reinterpret_cast` cannot be used in a `constexpr` context, so the pointer is created inside the function body (a normal, inlinable function).

### A GPIO pin as a type

```cpp
#include <cstdint>
#include "stm32f7xx.h"

template <std::uintptr_t Base, unsigned Pin>
class GpioOut {
    static_assert(Pin < 16U, "pin number must be 0..15");
    static constexpr unsigned kPortIndex = (Base - GPIOA_BASE) / 0x400U;     /* A=0, B=1, ... */
    static GPIO_TypeDef *regs() { return reinterpret_cast<GPIO_TypeDef *>(Base); }
public:
    static void init()
    {
        RCC->AHB1ENR = RCC->AHB1ENR | (RCC_AHB1ENR_GPIOAEN << kPortIndex);    /* clock first */
        (void)RCC->AHB1ENR;                                                   /* read back */
        regs()->MODER = (regs()->MODER & ~(3U << (Pin * 2U))) | (1U << (Pin * 2U));
    }
    static void on()     { regs()->BSRR = 1U << Pin; }
    static void off()    { regs()->BSRR = 1U << (Pin + 16U); }
    static void toggle() { regs()->ODR = regs()->ODR ^ (1U << Pin); }
};

using LedBlue = GpioOut<GPIOB_BASE, 7>;       /* LD2 */

int main()
{
    LedBlue::init();
    for (;;) { LedBlue::toggle(); /* ... */ }
}
```

What the template gives you:

- `GpioOut<GPIOB_BASE, 16>` fails to compile (`static_assert`).
- The clock-enable bit is computed at compile time from the port address (the `GPIOxEN` bits are consecutive from bit 0).
- No object, no pointer, no RAM: `LedBlue::toggle()` is a few instructions. Check with `arm-none-eabi-objdump -d` or Compiler Explorer.
- Writing `regs()->ODR ^= ...` would also work in C++17, but in **C++20 compound assignment on `volatile` is deprecated** (`-Wvolatile`), so write `x = x ^ y`. The CMSIS macros `SET_BIT`/`MODIFY_REG` use compound assignment and can produce these warnings in C++20; use C++17 or avoid those macros in C++.

### Policy-based design: swap behavior at compile time

```cpp
template <typename Led, typename Clock>
class Blinker {
public:
    void tick()
    {
        if (Clock::elapsed_ms(last_) >= period_ms_) { last_ += period_ms_; Led::toggle(); }
    }
private:
    std::uint32_t last_ = 0;
    std::uint32_t period_ms_ = 500;
};
```

`Blinker<LedBlue, SysTickClock>` uses the real hardware; `Blinker<FakeLed, FakeClock>` compiles on your PC for tests (section 11). No virtual calls, no interface objects.

### CRTP: static polymorphism

```cpp
template <typename Derived>
class Driver {
public:
    void start() { static_cast<Derived *>(this)->do_start(); }   /* resolved at compile time */
};
class Spi : public Driver<Spi> { public: void do_start() { /* ... */ } };
```

Use when you want a common interface without the vtable.

### Concepts (C++20): readable constraints

```cpp
template <typename T>
concept OutputPin = requires { T::init(); T::on(); T::off(); T::toggle(); };

template <OutputPin Pin>
void blink_once() { Pin::on(); Pin::off(); }
```

A wrong type gives a one-line error instead of a page of template noise.

### Template bloat

Each distinct set of template arguments produces its own code. `Reg32<A>` and `Reg32<B>` are inlined away, so there is no cost; but a large template class instantiated for ten types can add up. Mitigations:

- Put the type-independent part in a non-template base class (compiled once).
- Use `-Os`, `-ffunction-sections`, `--gc-sections`.
- Look at `nm -C --size-sort`: templates appear with their arguments in the name.

---

## 9. Containers and the standard library

### Safe to use (no heap, header-only, tiny)

| Header | Use |
|---|---|
| `<cstdint>`, `<cstddef>`, `<climits>`, `<limits>` | Types and limits |
| `<array>` | Fixed-size array with `size()`, iterators, bounds-known; same layout as `T[N]` |
| `<span>` (C++20) | Non-owning view of contiguous data (pointer + length) |
| `<string_view>` (C++17) | Non-owning view of text |
| `<optional>` | "Maybe a value" without a sentinel; stored inline |
| `<variant>` | Type-safe union (use with `std::visit`; check code size) |
| `<bitset>` | Fixed-size bit sets |
| `<type_traits>`, `<utility>`, `<tuple>`, `<functional>`'s `std::invoke`, `<iterator>` | Templates |
| `<algorithm>`, `<numeric>` | `std::sort`, `std::find`, `std::copy`, `std::accumulate` (no allocation; `std::sort` is bigger than you think) |
| `<atomic>` | `std::atomic<uint32_t>` is lock-free on the M7 |
| `<bit>` (C++20) | `std::bit_cast`, `std::popcount`, `std::countl_zero`, `std::byteswap` (C++23) |
| `<cmath>`, `<cstring>`, `<cstdio>` | As in C (use `sqrtf`, `std::sqrt(float)`) |

Replace C arrays plus separate length with `std::array`/`std::span`:

```cpp
std::size_t checksum(std::span<const std::uint8_t> data)    /* C++20 */
{
    std::size_t s = 0;
    for (std::uint8_t b : data) { s += b; }
    return s;
}
std::array<std::uint8_t, 8> buf{};
checksum(buf);                                               /* pointer and size travel together */
```

### Avoid or replace

| Standard | Why | Alternative |
|---|---|---|
| `std::vector`, `std::string`, `std::map`, `std::list`, `std::deque`, `std::unordered_*` | Heap allocation, fragmentation, exceptions on failure | **Embedded Template Library (ETL)**: `etl::vector<T,N>`, `etl::string<N>`, `etl::map`, `etl::queue`, all fixed-capacity |
| `std::function` | Type erasure may allocate; call overhead | Template parameter, function pointer + `void *ctx`, `etl::delegate` |
| `std::shared_ptr`, `std::make_shared` | Heap + atomic reference count | Static objects, references, `std::unique_ptr` with a custom deleter if needed |
| `iostream`, `<sstream>`, `std::to_string` | Code size, heap, locale | `snprintf` into a buffer; a small custom formatter |
| `<chrono>` clocks (`system_clock`) | Need a time source | `std::chrono::duration` types are fine for units |
| `<thread>`, `<mutex>`, `<condition_variable>`, `<future>` | No OS | Your RTOS wrappers |
| `<random>` | Large | A small PRNG you write, or hardware RNG |
| `std::regex`, `<filesystem>`, `<locale>` | Huge or no OS | Do not use |

ETL (<https://www.etlcpp.com>) is a header-only library designed for this: fixed capacity, no heap, compatible interfaces with the STL, plus state machines, message routers, callbacks and more.

### A fixed-capacity ring buffer as a template

```cpp
#include <array>
#include <atomic>
#include <cstddef>

template <typename T, std::size_t N>
class RingBuffer {
    static_assert(N != 0U && (N & (N - 1U)) == 0U, "N must be a power of two");
public:
    bool push(const T &v)                          /* producer (e.g. ISR) */
    {
        const std::size_t h = head_.load(std::memory_order_relaxed);
        const std::size_t n = (h + 1U) & (N - 1U);
        if (n == tail_.load(std::memory_order_acquire)) { return false; }   /* full */
        buf_[h] = v;
        head_.store(n, std::memory_order_release);
        return true;
    }
    bool pop(T &out)                               /* consumer (e.g. main loop) */
    {
        const std::size_t t = tail_.load(std::memory_order_relaxed);
        if (t == head_.load(std::memory_order_acquire)) { return false; }   /* empty */
        out = buf_[t];
        tail_.store((t + 1U) & (N - 1U), std::memory_order_release);
        return true;
    }
private:
    std::array<T, N>        buf_{};
    std::atomic<std::size_t> head_{0};
    std::atomic<std::size_t> tail_{0};
};

static RingBuffer<std::uint8_t, 128> rx_queue;
```

This is the C version of chapter 5 with proper atomics: correct for one producer and one consumer, any `T`, no heap, size known at compile time. The acquire/release stores emit a `DMB` on ARMv7-M, which is cheap and gives correctness that does not depend on a single core.

---

## 10. Inheritance and virtual functions

### What `virtual` costs

```cpp
struct Stream {
    virtual ~Stream() = default;
    virtual int write(const std::uint8_t *data, std::size_t len) = 0;
};
class UartStream final : public Stream { int write(const std::uint8_t *d, std::size_t n) override; };
```

- Each object gets a hidden **vptr** (4 bytes).
- Each class gets one **vtable** in Flash (`.rodata`).
- A call through a base reference does: load vptr, load function address, indirect branch (a few cycles; defeats inlining).
- A virtual destructor generates a "deleting destructor" that references `operator delete`, so you need the stub from section 2 even if you never `delete`.
- Pure virtual functions need `__cxa_pure_virtual` (section 2).

### When it is the right tool

- A handful of driver instances behind a common interface (`Stream`, `Display`, `SensorBase`), chosen at runtime.
- Callbacks into user code (`on_event()`).

When the concrete type is known at compile time, prefer **templates/CRTP** (section 8), or `final` classes so the compiler can bypass the vtable.

### Interface plus implementation, no heap

```cpp
UartStream uart_stream;                         /* static object */
void log_to(Stream &out) { out.write(msg, len); }
log_to(uart_stream);                            /* pass by reference: no pointers, no new */
```

### Placement new and static pools

Constructing an object in memory you provide (an array in the right section) instead of the heap:

```cpp
alignas(Sensor) static std::uint8_t sensor_storage[sizeof(Sensor)];
Sensor *s = new (sensor_storage) Sensor(args);      /* needs #include <new>; calls the constructor only */
s->~Sensor();                                       /* destroy explicitly when done */
```

`std::optional<Sensor>` or an `etl::pool` gives the same with less ceremony.

---

## 11. Callbacks, lambdas, state, errors

### Callbacks without `std::function`

```cpp
class Callback {
public:
    using Fn = void (*)(void *);
    constexpr Callback() = default;
    constexpr Callback(Fn fn, void *ctx) : fn_(fn), ctx_(ctx) { }

    template <typename T, void (T::*Method)()>
    static Callback bind(T &obj)
    {
        return Callback{ [](void *c) { (static_cast<T *>(c)->*Method)(); }, &obj };
    }
    void operator()() const { if (fn_ != nullptr) { fn_(ctx_); } }
private:
    Fn    fn_  = nullptr;
    void *ctx_ = nullptr;
};

struct Heartbeat { void tick() { LedBlue::toggle(); } } hb;
Callback cb = Callback::bind<Heartbeat, &Heartbeat::tick>(hb);
cb();
```

Eight bytes (function pointer + context), no heap, one indirect call. A **non-capturing lambda** converts to a plain function pointer, so it works with C-style APIs too:

```cpp
timer_set_callback([](void *) { LedBlue::toggle(); }, nullptr);
```

Lambdas passed to **function templates** are free (inlined):

```cpp
template <typename F> void repeat(unsigned n, F f) { for (unsigned i = 0; i < n; ++i) { f(i); } }
repeat(4, [](unsigned i) { printf("%u\r\n", i); });
```

### State machines

```cpp
enum class State : std::uint8_t { Idle, WaitAck, Run, Error };

class Protocol {
public:
    void on_event(Event ev)
    {
        switch (state_) {
        case State::Idle:    if (ev == Event::Start)   { send_request(); state_ = State::WaitAck; } break;
        case State::WaitAck: if (ev == Event::Ack)     { state_ = State::Run; }
                             else if (ev == Event::Timeout) { state_ = State::Error; } break;
        case State::Run:     /* ... */ break;
        case State::Error:   /* ... */ break;
        }
    }
private:
    State state_ = State::Idle;
};
```

`enum class` plus `-Wswitch` warns about unhandled states. `std::variant<Idle, Running, Failed>` with `std::visit` is the typed alternative: more expressive, but check the code size.

### Error handling without exceptions

```cpp
enum class Status : std::uint8_t { Ok, Timeout, Busy, Invalid };

[[nodiscard]] Status uart_send(std::span<const std::uint8_t> data, Milliseconds timeout);

if (uart_send(buf, 100_ms) != Status::Ok) { /* handle */ }
```

- `[[nodiscard]]` makes the compiler warn if a caller ignores the result.
- `std::optional<T>` for "value or nothing".
- `std::expected<T, E>` (C++23, GCC 12+ with `-std=c++23`) for "value or error code":

```cpp
std::expected<std::uint16_t, Status> adc_read(unsigned channel);
if (auto v = adc_read(3)) { use(*v); } else { handle(v.error()); }
```

- With `-fno-exceptions`, `throw` does not compile and a library function that would throw calls `std::terminate` instead. Make sure that ends in your own handler (record state, reset).

### Attributes

`[[nodiscard]]`, `[[maybe_unused]]`, `[[fallthrough]]`, `[[noreturn]]`, `[[deprecated]]`, `[[likely]]`/`[[unlikely]]` (C++20); GCC ones with `[[gnu::always_inline]]`, `[[gnu::section(".dtcm")]]`, `[[gnu::weak]]`, `[[gnu::used]]`.

---

## 12. Mixing C and C++

### ISRs and startup symbols must be `extern "C"`

C++ **mangles** function names (`_Z16SysTick_Handlerv`). The vector table in the startup file references the plain name `SysTick_Handler`. If your C++ handler is mangled, the weak default wins and your handler **silently never runs**:

```cpp
extern "C" void SysTick_Handler()                /* correct: C linkage */
{
    sys::tick_ms = sys::tick_ms + 1U;
}
```

Same for anything called from C or assembly (`_write`, `_sbrk`, `HardFault_Handler`, `SystemInit`, `__libc_init_array` is already C).

### Headers shared between C and C++

```c
#ifdef __cplusplus
extern "C" {
#endif

void led_init(void);
int  uart_write(const char *s, unsigned len);

#ifdef __cplusplus
}
#endif
```

CMSIS and ST device headers already contain these guards.

### Differences that bite when moving C code to C++

| C | C++ |
|---|---|
| `void *` converts to any pointer implicitly | Needs `static_cast` |
| Compound literals `(struct s){...}` | Not standard (GCC accepts as extension) |
| Designated initializers in any order, with `[index] =` | C++20: only in declaration order, no array designators |
| VLAs, flexible array members, `restrict`, `_Static_assert` | Not available (use `static_assert`, `__restrict`) |
| `char` literal `'a'` has type `int` | Type `char` |
| `const` globals have external linkage | Internal linkage (use `extern` or `inline constexpr`) |
| Implicit conversions between enum and int | `enum class` forbids; plain `enum` int→enum is an error |
| Narrowing in `{}` allowed | Error: `uint8_t b{300};` |
| `volatile` compound ops fine | Deprecated in C++20 |
| Anonymous structs in unions | Extension only |
| Using `new` as a variable name... | `new`, `class`, `template`, `namespace`, `delete`, `this` are keywords |

Practical advice: compile existing C files as C and call them from C++ through `extern "C"` headers. Only convert a file to C++ when you want the benefits.

---

## 13. A complete example: the earlier blink and tick, in C++

`src/main.cpp`

```cpp
#include <cstdint>
#include "stm32f7xx.h"

namespace sys {
inline volatile std::uint32_t tick_ms = 0;              /* C++17 inline variable: one definition */

inline std::uint32_t now_ms() { return tick_ms; }

struct Timeout {
    explicit Timeout(std::uint32_t period) : period_(period), last_(now_ms()) { }
    bool expired()                                      /* wrap-safe */
    {
        if (static_cast<std::uint32_t>(now_ms() - last_) >= period_) { last_ += period_; return true; }
        return false;
    }
private:
    std::uint32_t period_;
    std::uint32_t last_;
};
}   // namespace sys

extern "C" void SysTick_Handler()                       /* C linkage: matches the vector table */
{
    sys::tick_ms = sys::tick_ms + 1U;
}

template <std::uintptr_t Base, unsigned Pin>
class GpioOut {
    static_assert(Pin < 16U, "pin must be 0..15");
    static constexpr unsigned kPort = (Base - GPIOA_BASE) / 0x400U;
    static GPIO_TypeDef *r() { return reinterpret_cast<GPIO_TypeDef *>(Base); }
public:
    static void init()
    {
        RCC->AHB1ENR = RCC->AHB1ENR | (RCC_AHB1ENR_GPIOAEN << kPort);
        (void)RCC->AHB1ENR;
        r()->MODER = (r()->MODER & ~(3U << (Pin * 2U))) | (1U << (Pin * 2U));
    }
    static void toggle() { r()->ODR = r()->ODR ^ (1U << Pin); }
};

using LedBlue = GpioOut<GPIOB_BASE, 7>;                 /* LD2 */

int main()
{
    LedBlue::init();
    SysTick_Config(SystemCoreClock / 1000U);            /* 1 ms tick */

    sys::Timeout blink{500U};
    for (;;) {
        if (blink.expired()) { LedBlue::toggle(); }
        __WFI();
    }
}
```

Points to check after building:

- `arm-none-eabi-size` and `nm -C --size-sort`: no `operator new`, no `__cxa_*`, no `malloc`.
- `arm-none-eabi-objdump -d build/blink.elf | grep -A12 "<main>"`: the whole `toggle()` is inlined into the loop.
- `arm-none-eabi-nm build/blink.elf | grep SysTick_Handler`: the **unmangled** name is the one defined (`T SysTick_Handler`), not the weak alias.
- `-fno-exceptions -fno-rtti`: make sure `arm-none-eabi-readelf -S` has no `.ARM.extab`/`.gcc_except_table` growth.

Not compiled or tested by me on your board; treat it as a template and check against your header (`GPIOA_BASE`, `RCC_AHB1ENR_GPIOAEN`).

### Unit testing the logic on the PC

The pin and clock come in as template parameters, so a host test substitutes fakes:

```cpp
// tests/test_blinker.cpp  (host build, plain g++)
#include <cassert>
#include <cstdint>

struct FakeLed   { static inline int toggles = 0; static void toggle() { ++toggles; } };
struct FakeClock { static inline std::uint32_t now = 0; static std::uint32_t now_ms() { return now; } };

template <typename Led, typename Clock>
class Blinker {
public:
    void tick()
    {
        if (static_cast<std::uint32_t>(Clock::now_ms() - last_) >= 500U) { last_ += 500U; Led::toggle(); }
    }
private:
    std::uint32_t last_ = 0;
};

int main()
{
    Blinker<FakeLed, FakeClock> b;
    FakeClock::now = 499; b.tick(); assert(FakeLed::toggles == 0);
    FakeClock::now = 500; b.tick(); assert(FakeLed::toggles == 1);
}
```

```bash
g++ -std=c++17 -Wall -Wextra -fsanitize=address,undefined tests/test_blinker.cpp -o /tmp/t && /tmp/t
```

For bigger suites use Catch2, doctest or GoogleTest with CTest in a separate host CMake project (section 16 of chapter 5).

---

## 14. Design guidelines for embedded C++

1. **No heap by default.** Provide a trapping `operator new` (section 2) so any allocation is caught immediately.
2. **Constructors do not touch hardware.** `init()` is called from `main` in a known order.
3. **Everything that can be `constexpr` is `constexpr`**; everything that can be checked at compile time is (`static_assert`).
4. **Types express units and meaning**: `Milliseconds`, `Hertz`, `enum class` states and flags, not bare `uint32_t`.
5. **Hardware is accessed through small abstractions** (templates for register and pin access), so application logic never mentions `GPIOB->ODR`.
6. **Dependency injection over singletons**: pass the dependency (`Led &`, `Stream &`) or a template parameter. This is what makes host tests possible.
7. **Compile-time polymorphism (templates, CRTP) first, virtual only when the type really varies at run time.**
8. **No exceptions, no RTTI, no `iostream`, no dynamic containers.** Use fixed-capacity containers (`std::array`, ETL).
9. **ISRs are `extern "C"`, tiny, and communicate through atomics, ring buffers or a small event queue.**
10. **Measure.** After every new feature: `size`, `nm -C --size-sort`, and a look at the disassembly of the hot path.
11. **Keep C for C's strengths**: vendor code, startup, small drivers can stay in C, called through `extern "C"`.

### Common coding standards

MISRA C++:2023 (successor of MISRA C++:2008, based on C++17), AUTOSAR C++14 guidelines, and the free **C++ Core Guidelines** (<https://isocpp.github.io/CppCoreGuidelines/>), together with `clang-tidy` checks such as `cppcoreguidelines-*`, `modernize-*`, `bugprone-*`, `performance-*`.

---

## 15. Problems you will meet, and fixes

| Symptom | Cause | Fix |
|---|---|---|
| `undefined reference to operator delete(void*)` | A class with a virtual destructor references the deleting destructor | Provide the stubs (section 2) or link libstdc++'s |
| `undefined reference to __cxa_pure_virtual` | Pure virtual functions without libsupc++ linked | Define it (section 2), and link with `g++` |
| `undefined reference to __dso_handle` / `__cxa_atexit` | Global with non-trivial destructor | `-fno-use-cxa-atexit`, or define `__dso_handle` |
| `undefined reference to _exit`, `_sbrk` | Syscalls | `nosys.specs`, or your own implementation |
| `undefined reference to std::...` / `__gxx_personality_v0` | Linked with `gcc` instead of `g++`, or exceptions still enabled somewhere | Link as C++, add `-fno-exceptions` to every C++ file |
| Interrupt handler never runs, device stuck in `Default_Handler` | Handler is C++ (mangled name) | `extern "C"` |
| Code size explodes (+40 KB or more) | `iostream`, `std::string`, `std::vector`, exceptions, demangler | `nm -C --size-sort`; remove the feature; override `__verbose_terminate_handler` |
| Global object contains zeros / garbage at start | Constructors did not run (`.init_array` missing from linker script, or startup does not call `__libc_init_array`) | Check `readelf -S` and the startup code |
| Crash or fault before `main` | A global constructor touches hardware that is not ready | Move to `init()` |
| `-Wvolatile` warnings | Compound assignment or `++` on `volatile` in C++20 | Use `x = x | y`, or compile with C++17 |
| `invalid conversion from void*` | C-style code compiled as C++ | `static_cast`, or keep the file as C |
| `narrowing conversion` error | `uint8_t b{x};` with a wider `x` | Explicit cast |
| `multiple definition` of a global in a header | C++ header defines a variable | `inline` variable (C++17) or `extern` |
| `thread-safe static initializer` symbols appear | Missing `-fno-threadsafe-statics` | Add the flag |
| Linker error mentioning `libstdc++_nano` | Missing package | Install `libstdc++-arm-none-eabi-newlib` |
| `std::function`-heavy code allocates | Type erasure | Replace with templates or function pointers |
| Template error pages | Missing constraint | C++20 concepts, or `static_assert` with a message |
| Breakpoint in a template function hits many places | One function body per instantiation | Expected; use `bt` to see the type arguments |

---

## 16. Lab exercises

PC:

1. **Zero overhead check**: compile `Led::on()` as a class method, as a template, and as a C macro at `-Os`. Compare the assembly (godbolt, `ARM GCC (none-eabi)`).
2. **`constexpr` table**: generate a CRC or sine table at compile time; confirm with `nm` it lands in `.rodata`, and compare the CRC against your Python script from chapter 0.
3. **`static_assert` as a safety net**: make a template that rejects invalid pin numbers, and show the compile error.
4. **RAII**: write `IrqLock`-like guards for a fake critical section on the PC (count enter/exit) and confirm they balance on every return path.
5. **Strong types**: write `Milliseconds` and `Hertz`; make sure `delay(500)` fails to compile.
6. **Template mocks**: write the `Blinker<Led, Clock>` host test and extend it (wrap-around of the 32-bit tick).
7. **Ring buffer test**: test `RingBuffer<T, N>` including wrap-around, full and empty, with sanitizers.

Board:

8. **Hello C++**: change `main.c` to `main.cpp` with `extern "C"` ISR and blink; check `size` against the C version.
9. **Measure features**: add one at a time, rebuild and note the Flash growth: `std::array` loop, `std::optional`, `std::variant`+`visit`, a virtual call, `snprintf`, `std::string`, `std::vector`, an exception. Build a table.
10. **Prove no heap**: provide the trapping `operator new` and verify the project still links and runs.
11. **Constructor trap**: write a global object whose constructor writes to a peripheral register before the clock is enabled; read the fault in CFSR and fix it with `init()`.
12. **Static-init order**: create two globals in different files where one uses the other in its constructor; observe the failure; fix with `constinit` or construct-on-first-use.
13. **Mangling trap**: remove `extern "C"` from `SysTick_Handler`, see the tick stop, and find why with `nm`.
14. **Template GPIO**: write `GpioOut`/`GpioIn`, port the LED and button code to it, and compare the disassembly with the C version.
15. **Callback**: implement `Callback::bind`, call a member function from the SysTick handler, check there is no heap use.
16. **State machine**: rewrite a C `switch` state machine with `enum class`, `-Wswitch`, and host tests.
17. **ETL**: add ETL as a submodule or `extern/` folder, use `etl::vector<uint8_t, 64>` and `etl::string<32>`, and compare size with the `std::` versions.
18. **C++20/23 try-out**: switch to `-std=c++20`, observe `-Wvolatile` warnings, try `std::span`, `std::bit_cast`, concepts, and `std::expected` with `-std=c++23`.

---

## 17. Cheat sheet

### Flags

```
Compile (C++): -std=c++17 -fno-exceptions -fno-rtti -fno-threadsafe-statics -fno-use-cxa-atexit
               -fno-asynchronous-unwind-tables -ffunction-sections -fdata-sections -Os
Link:          --specs=nano.specs --specs=nosys.specs -Wl,--gc-sections -Wl,--print-memory-usage
```

### Do and don't

| Do | Don't |
|---|---|
| `constexpr`, `static_assert`, `enum class`, templates, RAII, `std::array`, `std::span`, `std::optional` | `new`, `std::vector`, `std::string`, `std::function`, `iostream`, exceptions, RTTI |
| `extern "C"` for ISRs and C interop | Touch hardware in constructors |
| `init()` from `main` | Rely on global initialization order |
| `[[nodiscard]]` on status returns | Use `volatile` compound assignment in C++20 |
| Measure with `size` and `nm -C --size-sort` | Assume "it's free" without looking |

### Commands

```bash
arm-none-eabi-nm -C --size-sort -S build/blink.elf | tail -20     # biggest symbols, demangled
arm-none-eabi-size build/blink.elf
arm-none-eabi-c++filt _ZN3Led2onEv                                 # demangle a name
arm-none-eabi-readelf -S build/blink.elf | grep -E "init_array|ARM.ex|gcc_except"
arm-none-eabi-nm -C build/blink.elf | grep -E "operator new|malloc|__cxa"
```

---

## 18. Where this leads

- **Peripheral chapters** (clock tree and PLL, GPIO, UART with interrupts and DMA, timers, ADC): rewritten with templates and `constexpr` computation of dividers.
- **Architecture patterns**: layered HAL, driver interfaces (virtual or template), event queues, dependency injection and host tests, building on sections 8 to 11 and 14.
- **RTOS**: FreeRTOS and Zephyr integrate with C++ through `extern "C"` hooks, and RAII wrappers for mutexes and queues are a good exercise.
- **Libraries worth studying**: **ETL** (containers, state machines), **modm** (C++ HAL generator for STM32), **Kvasir/other register libraries**, **mp-units** (units library).

## References

- *Effective Modern C++*, Scott Meyers
- *Real-Time C++*, Christopher Kormanyos
- *C++ Core Guidelines*, Stroustrup and Sutter: <https://isocpp.github.io/CppCoreGuidelines/>
- Jason Turner, *Rich Code for Tiny Computers* (CppCon talk) and the *C++ Weekly* series
- Embedded Template Library: <https://www.etlcpp.com>
- modm: <https://modm.io>
- cppreference.com (language and library, with freestanding notes)
- GCC manual: *C++ Dialect Options*, *Code Gen Options* (`info gcc`)
- Compiler Explorer: <https://godbolt.org> (select `ARM GCC (none-eabi)`)