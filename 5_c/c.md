# 5. C for Embedded Systems

Target: Cortex-M7 (STM32F746ZG), `arm-none-eabi-gcc` 14, newlib-nano, `-std=gnu11`.

Prerequisites: chapter 0 (toolchain, sections, startup), chapter 3 (Cortex-M: memory map, exceptions), chapter 4 (debugging). This chapter is about the **language rules that matter when your code touches hardware**: what the compiler may assume, what it may change, and what you must tell it.

---

## 1. The mental model

C is a thin layer over the machine, but it is defined by an **abstract machine**, not by your CPU. The compiler is allowed to transform your program in any way that keeps the *observable behavior* of that abstract machine. Observable behavior is:

1. Accesses to `volatile` objects (in order).
2. Data written to files/streams at exit.
3. Input/output behavior of interactive devices.

Everything else (variable accesses, loops, ordering of independent operations) can be reordered, merged, cached in registers or deleted. This is why the same code behaves differently at `-O0` and `-Os`, and why hardware access needs `volatile`.

Three rules that explain most embedded C bugs:

1. **If the standard says "undefined behavior", the optimizer may assume it never happens.** Your bug is not "a wrong result"; the compiler may remove the check or the loop.
2. **The compiler does not know about interrupts, DMA, or hardware.** It assumes a variable changes only when your code changes it, unless you say `volatile`/atomic.
3. **Sizes, signedness and alignment are implementation choices.** Know the ones of your toolchain (next section).

### Standards and dialects

| Option | Meaning |
|---|---|
| `-std=c11` | ISO C11, strict |
| `-std=gnu11` | C11 plus GNU extensions (`typeof`, `__attribute__`, statement expressions, binary literals). CMake's `CMAKE_C_STANDARD 11` gives this by default |
| `-std=c17`, `gnu17` | Bug-fix revision of C11 |
| `-std=c23` | Newer GCC versions (`bool`, `nullptr`, `constexpr`, `#embed`...) |

### Hosted vs freestanding

Embedded code is usually **freestanding**: no OS, so `main` is called by your startup and only some headers are guaranteed (`<stdint.h>`, `<stddef.h>`, `<stdbool.h>`, `<limits.h>`, `<float.h>`, `<stdarg.h>`, `<iso646.h>`, `<stdalign.h>`, `<stdnoreturn.h>`). With newlib you additionally have `<stdio.h>`, `<string.h>`, `<stdlib.h>`, `<math.h>`, but their OS-dependent parts (`_write`, `_sbrk`) are yours to provide.

---

## 2. Types and sizes on Cortex-M

### Sizes with `arm-none-eabi-gcc`

| Type | Size | Notes |
|---|---|---|
| `char` | 1 | **Unsigned by default on ARM** (differs from x86 where it is signed) |
| `short` | 2 | |
| `int` | 4 | |
| `long` | 4 | (8 on 64-bit Linux!) |
| `long long` | 8 | Not atomic, slower |
| pointer | 4 | |
| `float` | 4 | FPU (single precision) |
| `double` | 8 | Software on a single-precision FPU |
| `size_t` | 4 | `unsigned int` |
| `enum` | 4 | By default `int` sized. `-fshort-enums` changes the ABI: avoid |

### Always use fixed-width types for data and registers

```c
#include <stdint.h>
#include <stdbool.h>
#include <stddef.h>

uint8_t  u8;   int8_t  i8;
uint16_t u16;  int16_t i16;
uint32_t u32;  int32_t i32;
uint64_t u64;  int64_t i64;
uintptr_t addr;          /* integer wide enough for a pointer */
size_t    n;
bool      flag;          /* 1 byte; 0 or 1 */
```

Gotcha in newlib: `uint32_t` is `unsigned long`, not `unsigned int`. So `printf("%u", some_uint32)` triggers `-Wformat`, and `%lu` is correct. Portable form:

```c
#include <inttypes.h>
printf("clock = %" PRIu32 " Hz\r\n", SystemCoreClock);
printf("addr  = 0x%08" PRIx32 "\r\n", addr32);
```

### Integer promotions and conversions (source of many silent bugs)

- Any operand smaller than `int` is promoted to `int` before arithmetic:

```c
uint8_t a = 200, b = 100;
uint8_t c = a + b;          /* computed as int 300, then truncated to 44 */
if (a + b > 255) { }        /* TRUE: the sum is an int */
```

- Mixing signed and unsigned of the same rank converts to **unsigned**:

```c
int      s = -1;
unsigned u = 1;
if (s < u) { }              /* FALSE: s becomes 4294967295 */
```

- `~` on a small unsigned type promotes first:

```c
uint8_t x = 0x0F;
if (~x == 0xF0) { }         /* FALSE: ~x is int 0xFFFFFFF0 */
if ((uint8_t)~x == 0xF0) { }  /* TRUE */
```

- Narrowing assignments truncate silently. `-Wconversion` reports them.

### Literals and suffixes

| Literal | Type |
|---|---|
| `5` | `int` |
| `5u`, `5U` | `unsigned int` |
| `5UL` | `unsigned long` (same size as `unsigned` here) |
| `5ULL` | `unsigned long long` |
| `0x80000000` | `unsigned int` (does not fit `int`) |
| `1.0` | `double` |
| `1.0f` | `float` |

**`1 << 31` is undefined behavior** (shifting into the sign bit of an `int`). Write `1u << 31` or `1UL << 31`. The CMSIS headers do this for you (`(3UL << 20)`).

### Signedness rules

- **Unsigned overflow wraps** (defined): `uint32_t` arithmetic is modulo 2^32. This is why timeouts written as `(uint32_t)(now - start) >= interval` work across wrap-around.
- **Signed overflow is undefined behavior.** The compiler may assume it never happens.
- Right shift of a negative signed value is implementation-defined (arithmetic on GCC). Left shift of negative is UB.
- Shift count must be `0 <= n < width`; otherwise undefined.
- Division by zero is UB; `INT_MIN / -1` overflows (UB).

---

## 3. Bit manipulation

### The five operations

```c
x |=  (1u << n);          /* set bit n      */
x &= ~(1u << n);          /* clear bit n    */
x ^=  (1u << n);          /* toggle bit n   */
if (x & (1u << n)) { }    /* test bit n     */
x = (x & ~MASK) | (value << POS);   /* write a field */
```

### Helper macros (parenthesize everything)

```c
#define BIT(n)            (1UL << (n))
#define MASK(width)       ((1UL << (width)) - 1UL)
#define FIELD_GET(x, pos, width)       (((x) >> (pos)) & MASK(width))
#define FIELD_SET(x, pos, width, val)  \
    (((x) & ~(MASK(width) << (pos))) | (((uint32_t)(val) & MASK(width)) << (pos)))
```

CMSIS device headers already provide `SET_BIT`, `CLEAR_BIT`, `READ_BIT`, `MODIFY_REG`, `WRITE_REG`, `READ_REG` and constants named `<PERIPH>_<REG>_<FIELD>_Pos` and `_Msk`:

```c
MODIFY_REG(GPIOB->MODER, GPIO_MODER_MODER7_Msk, (1UL << GPIO_MODER_MODER7_Pos));
```

### Read-modify-write hazards

`REG |= bit` compiles to load, OR, store. An interrupt between load and store that changes the same register is lost. Use atomic set/reset registers when they exist (`GPIOx->BSRR`) or wrap in a critical section.

```c
GPIOB->BSRR = BIT(7);              /* set PB7: atomic */
GPIOB->BSRR = BIT(7 + 16);         /* reset PB7: atomic */
```

### Useful built-ins

```c
__builtin_clz(x)         /* count leading zeros (CLZ instruction) */
__builtin_ctz(x)         /* count trailing zeros (RBIT + CLZ) */
__builtin_popcount(x)    /* number of set bits (library call on M7) */
__builtin_bswap32(x)     /* byte swap (REV) */
__builtin_expect(c, 1)   /* branch hint */
__builtin_unreachable()  /* tell the optimizer this path cannot occur (be sure!) */
```

Power-of-two checks and alignment:

```c
#define IS_POW2(x)        ((x) != 0 && (((x) & ((x) - 1)) == 0))
#define ALIGN_UP(x, a)    (((x) + ((a) - 1)) & ~((a) - 1))
```

### Endianness

The Cortex-M is little-endian. Network protocols are usually big-endian. Do **not** cast a byte buffer to a struct pointer to parse it (alignment, padding, endianness, aliasing). Serialize explicitly:

```c
static inline uint32_t get_be32(const uint8_t *p)
{
    return ((uint32_t)p[0] << 24) | ((uint32_t)p[1] << 16) | ((uint32_t)p[2] << 8) | p[3];
}
static inline void put_be32(uint8_t *p, uint32_t v)
{
    p[0] = (uint8_t)(v >> 24); p[1] = (uint8_t)(v >> 16); p[2] = (uint8_t)(v >> 8); p[3] = (uint8_t)v;
}
```

---

## 4. Storage: where variables live

| Declaration | Storage duration | Where it ends up |
|---|---|---|
| Local, `int x;` | Automatic | Stack (or register) |
| Global, `int x = 5;` | Static | `.data` (initial value stored in Flash, copied to RAM at startup) |
| Global, `int x;` | Static | `.bss` (zeroed at startup) |
| `static` local, `static int n;` | Static | `.bss` or `.data`, but name visible only in the function |
| `const` global with constant initializer | Static | `.rodata` (Flash) |
| String literal `"abc"` | Static | `.rodata` (Flash) |
| `malloc`'d | Allocated | Heap (RAM, grows up from `_end`) |

Facts to remember:

- A `static` or global variable without initializer is **zero-initialized** before `main` (by the `.bss` clearing in startup). An automatic (local) variable is **not**: reading it uninitialized is undefined behavior.
- A `const` **global/static** goes to Flash and costs no RAM. A `const` **local** array is copied to the stack on each call unless you also make it `static`:

```c
void f(void)
{
    const uint8_t table_stack[256] = { ... };         /* copied to the stack every call! */
    static const uint8_t table_flash[256] = { ... };  /* lives in Flash only */
}
```

- Unlike AVR, Cortex-M has one address space: no `PROGMEM`. A `const` array in Flash is read with a normal pointer.
- `static` on a global/function means **internal linkage**: private to the `.c` file. Use it by default, and expose only what the header declares.
- `extern` declares without defining. A definition belongs in exactly one `.c`. Defining a variable in a header gives `multiple definition` link errors.

Linker placement control:

```c
__attribute__((section(".noinit")))  uint32_t survives_reset;   /* not zeroed by startup */
__attribute__((section(".dtcm")))    uint32_t fast_var;         /* needs matching linker section */
__attribute__((aligned(32)))         uint8_t  dma_buf[256];     /* cache-line aligned */
```

---

## 5. `volatile`

`volatile` tells the compiler: this object can change (or reading it can have effects) in ways it cannot see, so **every access in the source must happen, in source order**, relative to other volatile accesses.

### When you need it

1. **Memory-mapped registers** (CMSIS declares them `volatile`; `GPIOB->ODR` already is).
2. **Variables shared between an ISR and main code.**
3. **Memory written by DMA** or other hardware.
4. Variables you want the debugger to see updated, during bring-up.

### The classic bug

```c
bool ready = false;                      /* written by an ISR */
void ISR(void) { ready = true; }

int main(void)
{
    while (!ready) { }                   /* compiler: "ready never changes here" */
    ...                                  /* at -O1+ this can become an infinite loop, or load once */
}
```

Fix:

```c
volatile bool ready = false;
```

Without `volatile`, GCC loads `ready` once (before the loop) and spins on the register value. It works at `-O0` and breaks at `-Os`: the textbook "works in debug, fails in release".

### Reading a register can be an event

Reading some registers clears flags or pops FIFOs (`USART->RDR`, status registers with read-to-clear). A `volatile` read is a real side effect. To discard a value without the compiler removing the read:

```c
(void)USART3->RDR;
(void)RCC->AHB1ENR;       /* read-back after enabling a clock */
```

### `const volatile`

For a register you must read but never write (status, input data):

```c
const volatile uint32_t *const IDR = &GPIOB->IDR;   /* pointer to read-only volatile, constant pointer */
```

### What `volatile` does NOT do

- It does **not** make an access atomic. `volatile uint64_t x; x++;` is several instructions.
- It does **not** make `counter++` atomic: still load, add, store.
- It does **not** order accesses relative to **non-volatile** accesses, and it does not insert hardware barriers. For ordering with DMA, caches or peripherals use `__DMB()/__DSB()` and cache maintenance.
- It does **not** protect against another core or against DMA coherency issues with the D-cache.

### Where to put `volatile`

```c
volatile uint32_t *reg = (volatile uint32_t *)0x40020414u;   /* pointer to volatile data */
uint32_t *volatile p;                                        /* volatile pointer (rarely what you want) */
typedef struct { volatile uint32_t CR, SR, DR; } dev_t;       /* every field volatile */
```

Passing a volatile object to `memcpy` discards the qualifier (undefined behavior in principle). For MMIO use explicit loops with volatile accesses.

---

## 6. Pointers and arrays

### Basics that bite

```c
uint32_t arr[4];
uint32_t *p = arr;        /* array decays to a pointer to its first element */
p + 1;                    /* advances by sizeof(uint32_t) = 4 bytes, not 1 */

void f(uint32_t a[4])     /* a is really uint32_t *a */
{
    sizeof(a);            /* 4 (pointer size), not 16! Pass the length separately */
}
```

- `sizeof(arr)/sizeof(arr[0])` works only on a real array, not on a parameter:

```c
#define ARRAY_SIZE(a)  (sizeof(a) / sizeof((a)[0]))
```

- Pointer arithmetic is defined only inside an array (and one past its end). Comparing or subtracting unrelated pointers is UB.
- Returning the address of a local variable is UB (dangling):

```c
int *bad(void) { int x = 5; return &x; }     /* stack frame is gone after return */
```

### Pointers to hardware

```c
#define GPIOB_ODR   (*(volatile uint32_t *)0x40020414UL)
GPIOB_ODR ^= (1UL << 7);

/* CMSIS style: a struct laid over the peripheral */
typedef struct {
    volatile uint32_t MODER, OTYPER, OSPEEDR, PUPDR, IDR, ODR, BSRR, LCKR, AFR[2];
} GPIO_TypeDef;
#define GPIOB ((GPIO_TypeDef *)0x40020400UL)
GPIOB->ODR ^= (1UL << 7);
```

The struct form lets the compiler compute offsets, and one pointer can address several registers.

### NULL on Cortex-M

`NULL` is address 0, which **is a valid address** on many Cortex-M parts (ITCM or a boot alias). Dereferencing it may not fault. For serious projects, set up an MPU region at address 0 to trap it (chapter 3).

### Function pointers

Heavily used in embedded: vector tables, callbacks, driver "ops" tables, state machines.

```c
typedef void (*callback_t)(void *ctx);

void timer_set_callback(callback_t cb, void *ctx);

static void on_tick(void *ctx) { uint32_t *count = ctx; (*count)++; }
```

The `void *ctx` argument avoids global variables: the caller passes its own state and gets it back in the callback.

Function pointer arrays (command tables, state handlers):

```c
typedef struct { const char *name; void (*handler)(int argc, char **argv); } command_t;
static const command_t commands[] = { {"led", cmd_led}, {"adc", cmd_adc} };
```

Address bit 0 must be 1 (Thumb) for function pointers; the compiler and linker handle it. Never hand-craft a function address (see chapter 3, INVSTATE).

### Strict aliasing and type punning

GCC assumes pointers to different types do not alias (enabled at `-O2`, `-O3`, `-Os`):

```c
float f = 1.0f;
uint32_t bits = *(uint32_t *)&f;      /* UB: violates strict aliasing */
```

Correct ways to reinterpret bits:

```c
uint32_t bits;
memcpy(&bits, &f, sizeof bits);       /* compiles to a single register move */

union { float f; uint32_t u; } conv = { .f = 1.0f };   /* union punning is allowed in C (not C++) */
uint32_t bits2 = conv.u;
```

Accessing through `char *`/`uint8_t *` is always allowed.

### Alignment

A `uint32_t *` must point to a 4-byte-aligned address when used with `LDM/STM/LDRD/VLDM`; plain `LDR` works unaligned on M7 unless trapped. Casting `uint8_t *` buffers to `uint32_t *` is both an alignment and an aliasing problem. Use `memcpy` or aligned buffers:

```c
_Alignas(4) uint8_t buf[64];
```

---

## 7. Structs, unions, enums, bitfields

### Layout, padding and alignment

```c
struct a { uint8_t x; uint32_t y; uint8_t z; };   /* sizeof = 12: padding after x and after z */
struct b { uint32_t y; uint8_t x; uint8_t z; };   /* sizeof = 8: order members large to small */
```

Check at compile time:

```c
_Static_assert(sizeof(struct b) == 8, "struct b size changed");
_Static_assert(offsetof(struct b, x) == 4, "layout changed");
```

### Packed structs

```c
struct __attribute__((packed)) frame { uint8_t id; uint32_t value; uint16_t crc; };   /* 7 bytes */
```

- Taking a pointer to a packed member can produce an unaligned pointer and `-Waddress-of-packed-member`. Access members directly, or `memcpy` them out.
- Packed layout does not fix endianness. Serialize protocol fields explicitly (section 3) when exact wire format matters.

### Unions

Useful to view the same bytes in several ways (register images, frames):

```c
typedef union {
    uint32_t raw;
    struct { uint8_t b0, b1, b2, b3; };       /* anonymous struct (C11) */
} word_t;
```

### Enums

```c
typedef enum { STATE_IDLE, STATE_RUN, STATE_ERROR, STATE_COUNT } state_t;
```

- Enumerators are `int` constants. The enum type itself is implementation-defined (4 bytes here).
- A trailing `_COUNT` member gives you array sizes and range checks.
- `-Wswitch` warns when a `switch` over an enum misses a case: do not add a `default:` if you want that protection.

### Bitfields: avoid them for hardware

```c
struct { uint32_t en:1; uint32_t mode:2; uint32_t :5; uint32_t div:8; } cr;
```

The standard leaves bit order, allocation unit and straddling **implementation-defined**; accesses may be done with byte/halfword widths (wrong for registers that require 32-bit access), and they are non-atomic RMW. Prefer masks and shifts for hardware registers and wire formats. Bitfields are fine for private flags inside RAM structs.

### Initializers

```c
static const gpio_config_t cfg = {
    .pin   = 7,
    .mode  = GPIO_OUT,
    .speed = GPIO_LOW,
};                                    /* designated initializers: unmentioned fields are zero */

uint8_t buf[16] = {0};                /* zero the array */
uint8_t table[] = { [3] = 1, [7] = 2 };
```

---

## 8. The preprocessor

### Macro pitfalls

```c
#define SQUARE(x)  x * x
SQUARE(a + 1)             /* a + 1 * a + 1 : wrong */

#define SQUARE(x)  ((x) * (x))
SQUARE(i++)               /* i++ evaluated twice: undefined behavior */
```

Rules: parenthesize the whole macro and every parameter, and never pass expressions with side effects. For functions-in-disguise prefer `static inline`:

```c
static inline uint32_t square(uint32_t x) { return x * x; }
```

Multi-statement macros:

```c
#define LED_ON()   do { GPIOB->BSRR = BIT(7); } while (0)
if (x) LED_ON(); else foo();      /* works correctly because of do/while(0) */
```

### Conditional compilation

```c
#if defined(STM32F746xx)
  ...
#elif defined(STM32F411xE)
  ...
#else
  #error "Unsupported device"
#endif

#ifdef NDEBUG
  #define LOG(...)  ((void)0)
#else
  #define LOG(...)  printf(__VA_ARGS__)
#endif
```

`-Wundef` warns when `#if` uses an undefined macro (typo protection). Prefer `#if FEATURE` with values 0/1 defined in config headers over `#ifdef`, and put compile-time configuration in one `config.h`.

### Include guards

```c
#ifndef LED_H
#define LED_H
...
#endif /* LED_H */
```

(`#pragma once` also works with GCC but is not standard.) A header should be **self-contained**: it includes what it needs, and only **declares** (no variable definitions, no non-`static` function bodies).

### Stringification, token pasting, X-macros

```c
#define STR(x)     #x
#define CAT(a, b)  a##b

#define STATE_LIST(X) X(IDLE) X(RUN) X(ERROR)

typedef enum {
#define X(n) STATE_##n,
    STATE_LIST(X)
#undef X
    STATE_COUNT
} state_t;

static const char *state_name[] = {
#define X(n) #n,
    STATE_LIST(X)
#undef X
};
```

The X-macro keeps an enum and its names in sync from one list.

### Predefined macros

`__FILE__`, `__LINE__`, `__func__` (not a macro; a string), `__DATE__`, `__TIME__` (affect reproducibility), `__GNUC__`, `__ARM_ARCH`, `__ARM_FP`, `__VFP_FP__`, `__SOFTFP__`, `__thumb2__`. List the ones for your flags:

```bash
arm-none-eabi-gcc -mcpu=cortex-m7 -mthumb -mfpu=fpv5-sp-d16 -mfloat-abi=hard -dM -E - < /dev/null | sort
```

### `_Generic` and `typeof`

```c
#define abs_val(x) _Generic((x), int: abs, long: labs, float: fabsf, double: fabs)(x)
```

`typeof` (GNU) enables safe min/max:

```c
#define MIN(a, b) ({ typeof(a) _a = (a); typeof(b) _b = (b); _a < _b ? _a : _b; })
```

---

## 9. Functions

### Declarations and linkage

```c
/* module.h */
void module_init(void);              /* (void), not (): () means "unspecified arguments" in C */
int  module_read(uint8_t *buf, size_t len);

/* module.c */
static int helper(int x) { ... }     /* private to this file */
```

Compile with `-Wstrict-prototypes -Wmissing-prototypes` to catch declarations without prototypes.

### `static inline`

For small functions in headers: `static inline` avoids link errors and lets the compiler inline. `-Os` may still choose not to inline; use `__attribute__((always_inline))` only when you have measured.

### Useful attributes (GCC)

| Attribute | Use |
|---|---|
| `weak` | Overridable definition (default handlers, optional hooks) |
| `alias("other")` | Another name for the same function (`Default_Handler`) |
| `used` | Keep the symbol even if unreferenced (`-gc-sections`) |
| `section(".name")` | Place in a chosen linker section |
| `aligned(n)` | Alignment of the object |
| `packed` | No padding |
| `noinline`, `always_inline` | Inlining control |
| `noreturn` | The function never returns (`_Noreturn` in C11) |
| `naked` | No prologue/epilogue: assembly bodies only |
| `unused` | Silence unused warnings |
| `format(printf, 1, 2)` | Make `-Wformat` check your own printf-like function |
| `cold`, `hot` | Placement and optimization hints |
| `nonnull`, `pure`, `const` | Optimization hints (careful: wrong claims = wrong code) |

### Recursion, stack and VLAs

- Avoid recursion unless depth is provably bounded. Each call uses at least the frame (saved registers, locals).
- Avoid **variable-length arrays** and `alloca`: unbounded stack use with no failure report.
- Large locals (`char buf[1024]`) are a common stack overflow cause. Make them `static` or pass them in.
- Measure: `-fstack-usage` writes `.su` files; `-Wstack-usage=512` warns.
- `main` never returns in firmware: end with `for (;;)`.

### Passing and returning

- AAPCS: first four 32-bit args in R0-R3; a `float` in S0 (hard ABI); structs larger than 4 bytes are returned through a hidden pointer. Passing small structs by value is fine, large ones by `const` pointer.
- A function that can fail should return a status, with results in out-parameters:

```c
typedef enum { OK = 0, ERR_TIMEOUT, ERR_BUSY, ERR_INVALID } status_t;
status_t uart_send(const uint8_t *data, size_t len, uint32_t timeout_ms);
```

---

## 10. Undefined, unspecified and implementation-defined behavior

| Category | Meaning | Example |
|---|---|---|
| **Undefined (UB)** | The standard imposes no requirements. Anything can happen | Signed overflow, out-of-bounds, null deref, uninitialized read |
| **Unspecified** | One of several valid behaviors, not documented | Order of evaluation of function arguments |
| **Implementation-defined** | The compiler must document it | `char` signedness, right shift of negatives, `sizeof(int)` |

### Common UB in embedded code

```c
int a[4]; a[4] = 0;                 /* out of bounds write */
int x = INT_MAX; x + 1;             /* signed overflow */
int i = 0; a[i] = i++;              /* unsequenced modification */
1 << 32;  1 << 31;  -1 << 1;        /* invalid shifts */
int *p = NULL; *p;                  /* null dereference */
int u; use(u);                      /* uninitialized automatic */
*(uint32_t *)&f;                    /* aliasing violation */
free(p); p[0];                      /* use after free */
char *s = "abc"; s[0] = 'x';        /* modifying a string literal (in Flash: bus fault) */
```

### How UB shows up

```c
int check(int x) { return x + 1 > x; }
```

At `-O2` this can compile to `return 1`: the compiler assumes `x + 1` never overflows. A bounds check written after the access can also be deleted, because the access "proved" the index was valid.

Also: a loop with a non-constant condition and **no side effects** may be assumed to terminate (C11 6.8.5). A loop waiting for a non-volatile variable that only an ISR changes can be removed. Use `volatile`.

### Tools to find it

- Compile warnings: `-Wall -Wextra -Wconversion -Wshadow -Wcast-align -Wnull-dereference`.
- Run the **pure logic** on your PC with sanitizers: `gcc -g -O1 -fsanitize=address,undefined test.c module.c` (works for code that does not touch hardware).
- Compare behavior at `-O0` and `-O2`: a difference almost always means UB or a missing `volatile`.
- Static analyzers: `cppcheck`, `clang-tidy`, GCC `-fanalyzer` (noisy but useful).

---

## 11. Interrupts, shared data and atomicity

### What is atomic on Cortex-M

- Aligned 8/16/32-bit **loads and stores** are single instructions, so an interrupt cannot split them.
- `x++`, `x += n`, `x |= m` are **not** atomic (load, modify, store).
- 64-bit accesses (`uint64_t`, `double`) are **not** atomic: two 32-bit transfers.
- `LDREX/STREX` give atomic read-modify-write for 8/16/32 bits. There is no 64-bit exclusive access on ARMv7-M.

### Four patterns

**1. Flag from ISR to main (single writer):**

```c
static volatile bool rx_ready;
void USART3_IRQHandler(void) { ... rx_ready = true; }
...
if (rx_ready) { rx_ready = false; process(); }
```

**2. Counter incremented in an ISR, read in main:** a 32-bit aligned read is atomic. A 64-bit counter is not: take a critical section or retry-read.

```c
uint32_t hi1, lo, hi2;
do { hi1 = g_hi; lo = g_lo; hi2 = g_hi; } while (hi1 != hi2);
uint64_t now = ((uint64_t)hi1 << 32) | lo;
```

**3. Critical section** (nested-safe, from chapter 3):

```c
uint32_t s = __get_PRIMASK(); __disable_irq();
shared_struct.a = x; shared_struct.b = y;      /* multi-field update */
__set_PRIMASK(s);
```

**4. Single-producer, single-consumer ring buffer** (ISR produces, main consumes): lock-free when each index has one writer.

```c
#define RB_SIZE 128u                               /* power of two */
typedef struct {
    uint8_t           data[RB_SIZE];
    volatile uint32_t head;                        /* written only by producer */
    volatile uint32_t tail;                        /* written only by consumer */
} ring_t;

static inline bool rb_put(ring_t *r, uint8_t b)    /* producer (ISR) */
{
    uint32_t h = r->head, next = (h + 1u) & (RB_SIZE - 1u);
    if (next == r->tail) return false;             /* full */
    r->data[h] = b;
    __asm volatile("" ::: "memory");               /* compiler barrier: store data before publishing head */
    r->head = next;
    return true;
}

static inline bool rb_get(ring_t *r, uint8_t *b)   /* consumer (main) */
{
    uint32_t t = r->tail;
    if (t == r->head) return false;                /* empty */
    *b = r->data[t];
    __asm volatile("" ::: "memory");
    r->tail = (t + 1u) & (RB_SIZE - 1u);
    return true;
}
```

It is correct on a single core because each index is written by one side and the barrier stops the compiler from reordering the data store past the index update. With two consumers or two producers you need a lock or atomics.

### C11 atomics

```c
#include <stdatomic.h>

static atomic_uint_fast32_t events;
atomic_fetch_or(&events, 1u << 3);          /* ISR */
uint32_t e = atomic_exchange(&events, 0);   /* main: read and clear atomically */
```

On the M7 these are lock-free (`LDREX/STREX`) for up to 32 bits. 64-bit atomics need libatomic and are not lock-free.

### ISR rules (summary)

Short; clear the peripheral flag; shared variables `volatile` or atomic; no `printf`/`malloc`; avoid long loops; know your priority relative to SysTick (chapter 3).

---

## 12. Memory management

### Prefer static allocation

- No fragmentation, no allocation failures at run time, and the map file shows the real RAM use.
- `malloc` in newlib-nano works through `_sbrk` and your `_Min_Heap_Size`. If you use it, check the return value, free in a defined order and never in an ISR.
- Fixed-size **memory pools** give predictable allocation:

```c
typedef struct block { struct block *next; } block_t;
static block_t *free_list;
void pool_init(void *mem, size_t block_size, size_t count);
void *pool_alloc(void);
void pool_free(void *p);
```

### `memcpy`, `memset`, strings

- `memcpy` assumes **no overlap** (use `memmove` otherwise). Newlib's implementations are fast and use LDM/STM; they need valid, mostly aligned pointers.
- `memcmp` on structs compares padding bytes: do not use it for equality of structs.
- `strncpy` does **not** guarantee a terminating NUL and pads with zeros. Prefer:

```c
size_t n = snprintf(dst, sizeof dst, "%s", src);
if (n >= sizeof dst) { /* truncated */ }
```

- `snprintf` returns the length that **would** have been written; compare with the buffer size.
- Avoid `sprintf`, `strcpy`, `strcat`, `gets` (no bounds), and `atoi` (no error reporting); use `strtol`/`strtoul` with an end-pointer check.
- `printf` pulls a lot of code. With `nano.specs` plus `-u _printf_float` expect roughly 10 KB extra for `%f`.

### Initialization order

Globals with constant initializers are placed by the linker (no code runs). Globals initialized with function calls are not allowed in C (they are in C++, where constructors run in `__libc_init_array`).

---

## 13. Working with peripherals

### Three layers, from low to high

| Style | Example | Trade-off |
|---|---|---|
| Raw registers | `GPIOB->BSRR = BIT(7);` | Smallest, you must know the reference manual |
| CMSIS device header | `GPIOB->MODER`, `RCC_AHB1ENR_GPIOBEN` | Names and masks checked by the compiler |
| HAL/LL | `HAL_GPIO_WritePin(...)` | Portable across STM32, larger, hides details |

You wrote the first two; keep the HAL for later when you know what it hides.

### A driver written in the CMSIS style

`led.h`

```c
#ifndef LED_H
#define LED_H

void led_init(void);
void led_on(void);
void led_off(void);
void led_toggle(void);

#endif /* LED_H */
```

`led.c`

```c
#include "led.h"
#include "stm32f7xx.h"

#define LED_PIN   7u                         /* LD2 blue on PB7 */

void led_init(void)
{
    SET_BIT(RCC->AHB1ENR, RCC_AHB1ENR_GPIOBEN);   /* 1. enable the clock first */
    (void)READ_BIT(RCC->AHB1ENR, RCC_AHB1ENR_GPIOBEN);   /* 2. read back: ensure it took effect */

    MODIFY_REG(GPIOB->MODER, 3UL << (LED_PIN * 2u), 1UL << (LED_PIN * 2u));   /* 3. output mode */
}

void led_on(void)     { GPIOB->BSRR = 1UL << LED_PIN; }
void led_off(void)    { GPIOB->BSRR = 1UL << (LED_PIN + 16u); }
void led_toggle(void) { GPIOB->ODR ^= 1UL << LED_PIN; }   /* RMW: fine if only main touches it */
```

### Register access rules

1. **Enable the peripheral clock first** (`RCC->...ENR`), then read it back. A write to a peripheral with its clock off gives a bus fault or is ignored (chapter 3).
2. Write only the fields you mean to change: `MODIFY_REG` with mask and value.
3. Know each field's access type from the reference manual: read/write, **write-1-to-clear** (assigning 1 clears; use `=` not `|=`), **read-to-clear**, write-only, reserved (keep reset value).
4. Prefer set/reset registers (`BSRR`) to read-modify-write on shared registers.
5. Configure, then enable (set `UE`/`EN`/`ADON` last).
6. Respect timing requirements: some registers need waiting for a ready flag before the next step (`while (!(RCC->CR & RCC_CR_HSERDY)) {}` with a **timeout**).
7. Never hard-code magic numbers: use names from the device header or your own constants.

Timeouts:

```c
uint32_t start = millis();
while (!(RCC->CR & RCC_CR_HSERDY)) {
    if ((uint32_t)(millis() - start) > 100u) { return ERR_TIMEOUT; }
}
```

### Debouncing a button (typical task)

```c
bool button_pressed(void)
{
    static uint8_t  stable;
    static uint32_t last_change;
    static bool     last_raw;

    bool raw = (GPIOC->IDR & BIT(13)) != 0;        /* B1 user button on PC13 */
    uint32_t now = millis();
    if (raw != last_raw) { last_raw = raw; last_change = now; }
    if ((uint32_t)(now - last_change) >= 20u && stable != raw) {
        stable = raw;
        return raw;                                 /* report on the stable edge */
    }
    return false;
}
```

(Verify the button pin and its polarity in the board user manual; this is the pattern, not a pinout reference.)

---

## 14. Structure and patterns for real firmware

### Module = header + source

- The header is the **interface**: types, constants, function declarations. The source holds the implementation and `static` state.
- Hide internals: expose an **opaque type**, or at least do not expose globals.

```c
/* uart.h */
typedef struct uart uart_t;                      /* opaque: layout hidden */
uart_t *uart_get(int index);
status_t uart_write(uart_t *u, const uint8_t *data, size_t len);
```

### Configuration structs and instances

```c
typedef struct {
    USART_TypeDef *regs;
    uint32_t       baud;
    IRQn_Type      irq;
} uart_config_t;

static const uart_config_t uart3_cfg = { USART3, 115200u, USART3_IRQn };
```

`const` config tables stay in Flash and make adding a second UART trivial.

### Driver "ops" tables (polymorphism in C)

```c
typedef struct {
    status_t (*init)(void *ctx);
    status_t (*read)(void *ctx, uint8_t *buf, size_t len);
    status_t (*write)(void *ctx, const uint8_t *buf, size_t len);
} stream_ops_t;

typedef struct { const stream_ops_t *ops; void *ctx; } stream_t;
```

The same upper layer works with UART, SPI, a USB endpoint or a test stub.

### State machines

```c
typedef enum { S_IDLE, S_WAIT_ACK, S_RUN, S_ERROR } state_t;

static state_t state = S_IDLE;

void fsm_step(event_t ev)
{
    switch (state) {
    case S_IDLE:     if (ev == EV_START) { send_request(); state = S_WAIT_ACK; } break;
    case S_WAIT_ACK: if (ev == EV_ACK)   { state = S_RUN; }
                     else if (ev == EV_TIMEOUT) { state = S_ERROR; } break;
    case S_RUN:      ... break;
    case S_ERROR:    ... break;
    }
}
```

Keep transitions in one place, no blocking inside states (use timeouts and events), and enable `-Wswitch`.

### Superloop with a tick

```c
int main(void)
{
    board_init();
    uint32_t last = millis();
    for (;;) {
        if ((uint32_t)(millis() - last) >= 1000u) { last += 1000u; led_toggle(); }
        if (button_event_pending())                { handle_button(); }
        uart_poll();
        __WFI();                                      /* sleep until the next interrupt */
    }
}
```

Never use `delay()` busy loops in the superloop: they block everything else.

### Error handling

- Return a `status_t`, check it, and decide at one level what a failure means.
- `ASSERT()` for programmer errors (cannot happen), error codes for runtime failures (can happen).
- Defensive defaults: switch `default:` cases to a safe state; initialize all variables.

### Coding standards

MISRA C (industry standard for safety, paid document), CERT C (free), and the Linux kernel style for readability. Even without a certificate: no `goto` abuse, one return type convention, braces on every `if`, no side effects inside conditions, explicit casts, and no unreachable code.

### Using C from C++

A header meant for both:

```c
#ifdef __cplusplus
extern "C" {
#endif

void led_init(void);

#ifdef __cplusplus
}
#endif
```

---

## 15. Floating point in C

- With a **single-precision** FPU (F746), `float` is hardware and `double` is software. A `double` expression can silently slow code by 10-50x.
- Literals are `double` unless suffixed: write `0.5f`, `3.3f`.
- `float` passed to a variadic function (`printf`) is **promoted to `double`**:

```c
float v = adc_read_vbat();
printf("VBAT = %.2f V\r\n", v);        /* promotes to double: a software conversion on an SP FPU */
printf("VBAT = %.2f V\r\n", (double)v);  /* same, explicit */
```

- Needs `-Wl,-u,_printf_float` with newlib-nano, or nothing prints.
- Math functions: use the `f` variants (`sqrtf`, `sinf`, `fabsf`, `fmaxf`). `sqrtf` becomes a single `vsqrt.f32`.
- `-Wdouble-promotion` finds accidental `float` to `double`; `-fsingle-precision-constant` treats unsuffixed literals as float.
- `-ffast-math` removes NaN/Inf handling and strict ordering: fast but breaks `isnan` and IEEE assumptions.
- Never compare floats with `==`: use a tolerance `fabsf(a - b) < eps`.
- Converting `float` to an integer **truncates** toward zero; `float` to `int` of an out-of-range value is undefined.
- An FPU has context: first use sets `CONTROL.FPCA`, and interrupts then stack S0-S15. Heavy float math in ISRs costs.

### Fixed point as an alternative

Q-format (e.g. Q16.16) stores `value * 65536` in an `int32_t`:

```c
typedef int32_t q16_16_t;
#define Q16(x)           ((q16_16_t)((x) * 65536.0f))
static inline q16_16_t q16_mul(q16_16_t a, q16_16_t b) { return (q16_16_t)(((int64_t)a * b) >> 16); }
static inline q16_16_t q16_div(q16_16_t a, q16_16_t b) { return (q16_16_t)(((int64_t)a << 16) / b); }
```

Useful on cores without an FPU or for deterministic arithmetic. The M7 has `SMULL`, `SDIV` and DSP instructions that make this fast.

---

## 16. Warnings, analysis and testing

### Recommended compile flags for your own code

```
-Wall -Wextra -Wshadow -Wconversion -Wdouble-promotion -Wformat=2 -Wundef
-Wstrict-prototypes -Wmissing-prototypes -Wcast-align -Wnull-dereference
-Wstack-usage=1024
```

- Apply `-Wconversion` and `-Wshadow` to **your** sources, not to vendor code (use per-target or per-file options; mark vendor headers as `SYSTEM`).
- `-Werror` only for your code, and only after the build is warning-free.
- Avoid `-ffreestanding -fno-builtin` while linking newlib: they disable optimizations of `memcpy`/`printf`.

### Static analysis

```bash
cppcheck --enable=warning,style,performance --std=c11 src/
clang-tidy src/*.c -- -std=gnu11 -Iextern/cmsis_core/Include
```

### Testing pure logic on your PC

Separate hardware access from logic (ring buffer, parser, state machine, CRC, fixed-point math) and test the logic on the PC with sanitizers:

```cmake
# tests/CMakeLists.txt (host build, no cross toolchain)
cmake_minimum_required(VERSION 3.16...4.2)
project(host_tests C)
add_executable(test_ring test_ring.c ../src/lib/ring.c)
target_include_directories(test_ring PRIVATE ../src/lib)
target_compile_options(test_ring PRIVATE -g -O1 -Wall -Wextra -fsanitize=address,undefined)
target_link_options(test_ring PRIVATE -fsanitize=address,undefined)
```

```bash
cmake -S tests -B build-host && cmake --build build-host && ./build-host/test_ring
```

A hardware abstraction layer (HAL) boundary makes this possible: the same `ring.c` compiles for the board and for the PC.

### Seeing what the compiler did

```bash
arm-none-eabi-gcc -mcpu=cortex-m7 -mthumb -mfpu=fpv5-sp-d16 -mfloat-abi=hard -Os -S -fverbose-asm foo.c
arm-none-eabi-objdump -S -d build/blink.elf | less
```

Try these and read the result:

1. `while (!ready) {}` with and without `volatile` at `-Os`.
2. `x + 1 > x` for `int` and `unsigned`.
3. A `switch` with dense cases (jump table) vs sparse cases (compare chain).
4. A `uint8_t` add (see the `uxtb` truncation).
5. `printf("%f", f)` (see the `vcvt.f64.f32` promotion).
6. A bitfield assignment vs a mask-and-shift.

Compiler Explorer (godbolt.org) with `ARM GCC (none-eabi)` is perfect for this.

---

## 17. Common bugs table

| Bug | Why | Fix |
|---|---|---|
| Works at `-O0`, fails at `-Os` | Missing `volatile`, UB, uninitialized variable | Compare builds, add `volatile`, `-Wall -Wextra`, sanitizers on host logic |
| Loop never exits though ISR sets the flag | Non-volatile flag cached in a register | `volatile` or atomic |
| Counter loses updates | Non-atomic `++` shared with ISR | Critical section or atomic |
| 64-bit value occasionally wrong | Torn read | Critical section or double-read loop |
| `uint8_t` math gives unexpected result | Integer promotion | Cast intermediate, mask, or use wider type |
| `if (~x == ...)` always false | `~` promotes to `int` | Cast back to the narrow type |
| `1 << 31` weird | Signed shift into sign bit | `1UL << 31` |
| Comparison with `size_t` or `uint32_t` misbehaves with negatives | Signed/unsigned mix | Use the same signedness; `-Wsign-compare` |
| `sizeof(param)` returns 4 | Array parameter is a pointer | Pass the length |
| Strange values on a `const` local table | Copied to the stack each call (stack use) | `static const` |
| Hard fault on string write | String literal is in Flash | Use a `char[]` array |
| `printf("%u", uint32_t)` warns | `uint32_t` is `unsigned long` | `%lu` or `PRIu32` |
| `%f` prints nothing | nano printf has no float support | `-Wl,-u,_printf_float` |
| `multiple definition of x` | Variable defined in a header | `extern` in header, definition in one `.c` |
| `undefined reference` after adding a file | Source not in the build list | Add to `add_executable`/`target_sources` |
| Peripheral does nothing, or bus fault | Clock not enabled | `RCC->xxxENR` first, read back |
| Interrupt fires continuously | Peripheral flag not cleared | Clear the source flag in the ISR |
| Handler never called | Wrong handler name (`SysTick_handler`) | Match the vector table name exactly |
| Random crash with `printf("%f")` | Stack too small | Raise `_Min_Stack_Size`, paint and measure the stack |
| Packed struct crash | Unaligned `LDM`/`LDRD` access to a member | `memcpy` the member out |
| Variable not zero at start though global | Startup did not clear `.bss`, or it is in `.noinit` | Check `_sbss/_ebss` and the section |
| Linker warning "uses variable-size enums" | Mixed `-fshort-enums` | Do not use `-fshort-enums` |

---

## 18. Lab exercises

Do the PC ones with plain `gcc`, then the board ones.

PC:

1. **Sizes**: print `sizeof` of every basic type and `char` signedness. Compare with the Cortex-M list in section 2 (use `arm-none-eabi-gcc` plus `-dM -E` to see `__SIZEOF_*__`).
2. **Promotions**: reproduce the `uint8_t a + b`, `~x`, and signed/unsigned comparison surprises.
3. **UB**: compile `x + 1 > x` at `-O0` and `-O2` and compare the assembly. Add `-fsanitize=undefined` and watch it report the overflow.
4. **Bit helpers**: write `BIT`, `MASK`, `FIELD_GET/SET` and test them with `assert`.
5. **Ring buffer**: implement section 11 and test single-threaded, then stress it with two threads (it is only guaranteed on a single core with an ISR; discuss why).
6. **Parser**: write a function that decodes a big-endian frame from a byte buffer, with CRC check, and fuzz it with random buffers under `-fsanitize=address,undefined`.
7. **State machine**: implement a protocol FSM and write tests for every transition.

Board:

8. **Volatile**: reproduce the "flag never seen" bug with a SysTick-set flag at `-Os`, then fix it. Read the disassembly before and after.
9. **Registers**: write `led.c`, `button.c`, `systick.c` using only masks from `stm32f7xx.h`. Verify with the Peripherals panel.
10. **Atomicity**: increment one 32-bit counter from SysTick and main, count lost updates, fix with `irq_save/restore` and then with `atomic_fetch_add`.
11. **Torn read**: make a `uint64_t` timestamp updated in an ISR and read it from main until you catch an inconsistent value; fix it.
12. **Stack and `static const`**: compare stack use of a `const` local table vs `static const` with `-fstack-usage`.
13. **Float**: print `float` values, add `-Wdouble-promotion`, and find every `f64` instruction in `objdump -d`.
14. **Timeouts**: replace every unbounded `while (!flag)` with a timeout using `millis()`, and force a failure by leaving a clock disabled.
15. **Assert**: add `ASSERT` to a driver, trigger it, and see it in the debugger.
16. **Host tests in CMake**: build `ring.c` for both the board and a host test target.

---

## 19. Cheat sheet

### Rules of thumb

- Use `stdint.h` types; `1UL`/`1u` for bit masks; `%lu` or `PRIu32` for `uint32_t`.
- `volatile` for registers, ISR-shared variables, DMA buffers. It is **not** atomicity or ordering.
- Read-modify-write on shared data needs a critical section, atomics, or `BSRR`-style registers.
- Clocks first, read back, then configure, then enable.
- `static` everything that is private; `static const` for Flash tables; `static inline` for small helpers.
- Never trust: signed overflow, shifts, uninitialized locals, out-of-bounds, aliasing casts.
- Compare `-O0` and `-Os` when something is odd.
- Avoid `malloc`, recursion, VLAs, and large stack arrays.
- Timeouts on every wait, wrap-safe time comparisons.
- Use `float` and `f`-suffixed literals; mind `printf` promotion.

### Quick reference

| Task | Code |
|---|---|
| Set / clear / toggle / test bit | `x \|= BIT(n)`, `x &= ~BIT(n)`, `x ^= BIT(n)`, `x & BIT(n)` |
| Write a field | `MODIFY_REG(REG, MASK, VAL)` |
| Atomic GPIO set/reset | `GPIOx->BSRR = BIT(n)` / `BIT(n + 16)` |
| Array length | `sizeof(a) / sizeof((a)[0])` |
| Compile-time check | `_Static_assert(cond, "msg")` |
| Reinterpret bits | `memcpy` or union |
| Wrap-safe timeout | `(uint32_t)(now - start) >= timeout` |
| Critical section | `s = __get_PRIMASK(); __disable_irq(); ... __set_PRIMASK(s);` |
| Discard a volatile read | `(void)REG;` |
| Align a DMA buffer | `__attribute__((aligned(32)))` |
| Keep a symbol | `__attribute__((used))` |
| Weak default | `__attribute__((weak))` |

---

## 20. Where this leads

- **C++ for embedded** (next): what you can keep (RAII, templates, `constexpr`, type-safe registers) and what to turn off (exceptions, RTTI, dynamic allocation), on the same toolchain.
- **Peripheral chapters**: clock tree/PLL, GPIO, UART with interrupts and DMA, timers, ADC, using the patterns here.
- **Architecture patterns**: layers, HAL boundaries, drivers with ops tables, event loops, and testability, built from section 14.
- **Testing**: host-side unit tests of pure logic with sanitizers (section 16), then hardware-in-the-loop with the scripts from chapter 4.

## References

- *The C Programming Language*, Kernighan and Ritchie
- ISO/IEC 9899:2011 (C11) working draft (N1570), free online
- SEI CERT C Coding Standard (free): <https://wiki.sei.cmu.edu/confluence/display/c>
- MISRA C:2012 (paid)
- GCC manual: *C Extensions* (attributes, built-ins), *Warning Options*, *Optimize Options* (`info gcc`)
- *Making Embedded Systems*, Elecia White
- *Embedded Artistry* articles on volatile, atomics, and memory barriers
- Compiler Explorer: <https://godbolt.org>