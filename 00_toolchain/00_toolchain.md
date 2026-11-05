# 0. The Embedded Toolchain: from C source to a running STM32

Target used in all examples: **STM32F746ZG** (NUCLEO-F746ZG), Cortex-M7, `arm-none-eabi-gcc`, newlib-nano, Ubuntu.

Goal of this chapter: after reading it, nothing between `main.c` and the blinking LED should feel like magic.

```
 main.c ──► preprocessor ──► compiler ──► assembler ──► main.o ─┐
 uart.c ──► ...                                         uart.o ─┤
 startup.s ─────────────────────────────────► startup.o ─────────┼─► LINKER ─► blink.elf ─► objcopy ─► blink.bin ─► flash
 libc.a, libgcc.a, libnosys.a ───────────────────────────────────┤        ▲
 linker script (.ld) ────────────────────────────────────────────┘        │
                                                              memory map (Flash/RAM)
```

---

## 1. What is a toolchain

A toolchain is the set of programs that turn source code into a binary for a target machine.

| Tool | Role |
|---|---|
| `arm-none-eabi-gcc` | Driver: runs preprocessor, compiler, assembler and linker |
| `cc1` (internal) | The actual C compiler |
| `arm-none-eabi-as` | Assembler |
| `arm-none-eabi-ld` | Linker (normally called through gcc) |
| `arm-none-eabi-ar` | Creates static libraries (`.a`) |
| `arm-none-eabi-objcopy` | Converts formats (ELF to BIN/HEX) |
| `arm-none-eabi-objdump` | Disassembler and section viewer |
| `arm-none-eabi-readelf` | Inspects ELF files |
| `arm-none-eabi-nm` | Lists symbols |
| `arm-none-eabi-size` | Section sizes |
| `arm-none-eabi-addr2line` | Address to source line |
| `arm-none-eabi-gdb` | Debugger |
| newlib / newlib-nano | The C library |
| libgcc | Compiler support routines (soft division, soft-float, etc.) |

Install on Ubuntu:

```bash
sudo apt install gcc-arm-none-eabi binutils-arm-none-eabi libnewlib-arm-none-eabi gdb-multiarch
arm-none-eabi-gcc --version
arm-none-eabi-gcc -print-multi-lib        # supported CPU/FPU/ABI combinations
arm-none-eabi-gcc -print-search-dirs      # where it looks for libs and specs
```

### What `arm-none-eabi` means

`<arch>-<vendor>-<os/abi>` style triplet:

- `arm`: target architecture.
- `none`: no operating system (bare metal).
- `eabi`: Embedded Application Binary Interface. It defines how functions pass arguments, how structs are laid out, and how registers are used. All object files and libraries must agree on it.

Compare with your PC compiler, `x86_64-linux-gnu-gcc`, which targets Linux.

### Hosted vs freestanding

- **Hosted**: there is an OS, `main` is called by a runtime, `printf` and files work.
- **Freestanding**: no OS. Only a few headers are guaranteed (`<stdint.h>`, `<stddef.h>`, `<stdbool.h>`, `<limits.h>`...).

On a microcontroller with newlib you are in a middle ground: you use the C library, but you provide the "OS" parts (syscalls such as `_write`, `_sbrk`) yourself. That is why you normally do **not** use `-ffreestanding` or `-fno-builtin` when you link newlib.

---

## 2. The four compilation stages

Take `main.c`:

```c
#include <stdint.h>
#define LED_PIN 7
int main(void) { return LED_PIN; }
```

### Stage 1: preprocessor

Expands `#include`, `#define`, `#if`, removes comments. Output is still C.

```bash
arm-none-eabi-gcc -E main.c -o main.i
```

Useful to see exactly what a macro or a header expanded to. Add `-dM` to dump every defined macro:

```bash
arm-none-eabi-gcc -mcpu=cortex-m7 -mfpu=fpv5-sp-d16 -mfloat-abi=hard -dM -E - < /dev/null | grep -i -E "fp|vfp"
```

### Stage 2: compiler

Translates preprocessed C into assembly for the target CPU. Optimizations happen here.

```bash
arm-none-eabi-gcc -mcpu=cortex-m7 -mthumb -Os -S main.c -o main.s
```

### Stage 3: assembler

Assembly to machine code in an **object file** (relocatable, addresses not final yet).

```bash
arm-none-eabi-gcc -mcpu=cortex-m7 -mthumb -c main.c -o main.o
```

(`-c` runs stages 1 to 3.) A `.s` file also goes through this stage; a `.S` (capital) goes through the preprocessor first. With gcc you can force it with `-x assembler-with-cpp`.

### Stage 4: linker

Combines all object files and libraries, resolves symbols, assigns final addresses using the linker script, and writes the ELF.

```bash
arm-none-eabi-gcc main.o uart.o startup.o -mcpu=cortex-m7 -mthumb -T link.ld -o blink.elf
```

### Seeing everything gcc does

```bash
arm-none-eabi-gcc -v ...        # show the commands gcc runs internally
arm-none-eabi-gcc -### ...      # show them WITHOUT running
arm-none-eabi-gcc -save-temps -c main.c   # keep main.i, main.s, main.o
```

---

## 3. Target flags: CPU, Thumb, FPU, float ABI

```
-mcpu=cortex-m7  -mthumb  -mfpu=fpv5-sp-d16  -mfloat-abi=hard
```

| Flag | Meaning |
|---|---|
| `-mcpu=cortex-m7` | Instruction set and scheduling for the M7 (ARMv7E-M) |
| `-mthumb` | Generate Thumb/Thumb-2 code. Cortex-M **only** runs Thumb; ARM state does not exist |
| `-mfpu=...` | Which floating-point unit the code may use |
| `-mfloat-abi=soft` | All float math through library calls; no FPU instructions |
| `-mfloat-abi=softfp` | Uses FPU instructions, but passes args in integer registers |
| `-mfloat-abi=hard` | Uses FPU instructions and passes floats in FPU registers (fastest) |

### The FPU of your chip matters (a real bug you hit)

| Chip family | FPU | Flag |
|---|---|---|
| STM32F722/F723/F745/F746/F756 | single precision | `-mfpu=fpv5-sp-d16` |
| STM32F76x/F77x, STM32H7 | double precision | `-mfpu=fpv5-d16` |

Always confirm in your chip's reference manual and datasheet.

What happened in this project: with `-mfpu=fpv5-d16` on an F746, `printf("%.2f", f)` promoted the `float` to `double` (C rule for variadic functions) and the compiler emitted `vcvt.f64.f32`. A double-precision instruction on a single-precision FPU raised **UsageFault UNDEFINSTR**, escalated to **HardFault**. The faulting instruction was found with:

```
(gdb) x/wx 0xE000ED28        # CFSR = 0x00010000 -> bit 16 = UNDEFINSTR
(gdb) x/8wx $sp              # stacked frame: [6] = PC of the faulting instruction
(gdb) x/6i <that address>
```

Rules:

- The flags must be **identical at compile and link time**. The linker uses them to pick the right library variant.
- With `-mfloat-abi=hard`, the FPU must be **enabled at runtime** before any FPU instruction. At reset it is disabled. `SystemInit` does it:

```c
SCB->CPACR |= (3UL << 20) | (3UL << 22);   /* CP10 and CP11 full access */
__DSB(); __ISB();
```

- Missing enable gives CFSR bit 19 **NOCP**. Wrong FPU flag gives bit 16 **UNDEFINSTR**.
- Avoid accidental `double` math: use `3.3f` literals, `-fsingle-precision-constant`, and `-Wdouble-promotion` to warn on every float to double promotion.

### Multilib: how the right libc is chosen

```bash
arm-none-eabi-gcc -mcpu=cortex-m7 -mthumb -mfpu=fpv5-sp-d16 -mfloat-abi=hard -print-multi-directory
# thumb/v7e-m+fp/hard
```

Library variants live in directories such as `thumb/v7e-m+fp/hard` (single precision) or `thumb/v7e-m+dp/hard` (double precision). The linker log earlier showed `.../thumb/v7e-m+dp/hard/libc.a` when `fpv5-d16` was used. If compile flags and link flags differ, you can end up linking a library built for another ABI.

---

## 4. Object files and the ELF format

### Sections you will always see

| Section | Contents | Lives in |
|---|---|---|
| `.isr_vector` | Vector table | Flash |
| `.text` | Code | Flash |
| `.rodata` | `const` data, string literals | Flash |
| `.data` | Initialized globals/statics (`int x = 5;`) | Stored in Flash, **runs in RAM** |
| `.bss` | Zero-initialized globals/statics (`int y;`) | RAM only (no space in the file) |
| `.init_array` / `.fini_array` | Pointers to constructors/destructors | Flash |
| `.ARM.exidx` / `.ARM.extab` | Unwind tables (C++ exceptions, backtraces) | Flash |
| `.debug_*` | DWARF debug info | Only in the ELF, not loaded |
| `._user_heap_stack` | Reserves heap and stack space (check) | RAM |

### Two addresses per section

- **VMA** (virtual memory address): where the section lives **at runtime**.
- **LMA** (load memory address): where it is **stored** in the image.

For `.text` they are equal. For `.data` they differ: LMA is in Flash, VMA is in RAM. The startup code copies Flash to RAM. This is the single most important idea in the linker script.

### The inspection toolbox

```bash
# Section sizes
arm-none-eabi-size build/blink.elf
#    text    data     bss     dec     hex filename
#    8604     100    1908   10612    2974 blink.elf
# Flash used = text + data.   RAM used = data + bss (+ heap/stack).

arm-none-eabi-size -A build/blink.elf         # per section
arm-none-eabi-readelf -S build/blink.elf      # section headers
arm-none-eabi-readelf -l build/blink.elf      # program headers (LMA/VMA per segment)
arm-none-eabi-readelf -h build/blink.elf      # ELF header (entry point)
arm-none-eabi-objdump -h build/blink.elf      # sections with VMA and LMA
arm-none-eabi-nm -S --size-sort -C build/blink.elf | tail -20   # biggest symbols
arm-none-eabi-objdump -d build/blink.elf      # disassembly
arm-none-eabi-objdump -S -d build/blink.elf   # disassembly interleaved with source (needs -g)
arm-none-eabi-addr2line -e build/blink.elf -f 0x08001ba0   # address to function and line
arm-none-eabi-readelf -S build/blink.elf | grep debug_line # are there debug symbols?
```

### Symbol types in `nm`

| Letter | Meaning |
|---|---|
| `T` / `t` | Code (global / local) |
| `D` / `d` | Initialized data |
| `B` / `b` | `.bss` |
| `R` / `r` | Read-only data |
| `W` / `w` | Weak symbol |
| `U` | Undefined (needs resolving at link time) |
| `A` | Absolute (linker-script symbols such as `_estack`) |

### ELF vs BIN vs HEX

| Format | Has addresses | Has symbols | Use |
|---|---|---|---|
| `.elf` | yes | yes | Debugging, OpenOCD `program`, analysis |
| `.hex` (Intel HEX) | yes | no | Many programmers and bootloaders |
| `.bin` | **no** (raw bytes) | no | `st-flash write file.bin 0x08000000` (you supply the address) |

```bash
arm-none-eabi-objcopy -O binary blink.elf blink.bin
arm-none-eabi-objcopy -O ihex   blink.elf blink.hex
```

Gaps between sections are padded in a `.bin`, so a section placed far away makes a huge file.

---

## 5. Compiler flags worth knowing

### Optimization

| Flag | Meaning |
|---|---|
| `-O0` | No optimization (default). Large and slow, easy to debug |
| `-Og` | Optimize while keeping debugging sane. Good for development |
| `-O1`/`-O2`/`-O3` | Progressively more speed, more code |
| `-Os` | Optimize for size. The usual choice for release firmware |
| `-Oz` | Even smaller (clang; gcc treats like `-Os`) |
| `-flto` | Link-time optimization across files |

Optimization changes behavior of code with undefined behavior and of missing `volatile`. A program that only works at `-O0` almost always has a bug.

### Debug info

| Flag | Meaning |
|---|---|
| `-g` | Debug info (default level 2) |
| `-g3` | Also macro definitions (you can see `GPIO_PIN_7` in the debugger) |
| `-ggdb` | Format tuned for gdb |

Debug info lives in `.debug_*` sections of the ELF only. It does **not** increase Flash usage, because those sections are not loaded.

Without `-g`, gdb stops at `main ()` with no file or line, and breakpoints in source files do not resolve. CMake adds `-g` only if `CMAKE_BUILD_TYPE` is `Debug` (or similar).

### Dead-code removal (always use the pair)

```
compile: -ffunction-sections -fdata-sections
link:    -Wl,--gc-sections
```

Each function and variable goes into its own section, and the linker discards sections nothing references. Use `KEEP()` in the linker script for things that are referenced only by hardware (the vector table).

### Warnings

```
-Wall -Wextra -Wshadow -Wconversion -Wdouble-promotion -Wformat=2 -Wundef
```

Treat warnings seriously, but avoid `-Werror` on third-party code. Mark vendor headers as system headers (`-isystem`, or `SYSTEM` in CMake) so their warnings stay hidden.

### Language

```
-std=c11        # strict ISO C11
-std=gnu11      # C11 plus GNU extensions (GCC default style, CMake's default)
```

### Other useful ones

| Flag | Meaning |
|---|---|
| `-fno-common` | Error on duplicate tentative definitions (default since GCC 10) |
| `-fstack-usage` | Writes `.su` files with stack use per function |
| `-fno-exceptions -fno-rtti` | C++ size savings |
| `-ffile-prefix-map=OLD=NEW` | Remove absolute paths from the binary (reproducible builds) |
| `-MMD -MP` | Generate header dependency files (Make) |

---

## 6. The linker

### What it does

1. **Symbol resolution**: every `U` (undefined) symbol in one object must be defined in another object or library.
2. **Relocation**: assigns final addresses and patches every instruction or pointer that referred to a symbol.
3. **Layout**: places sections into memory regions according to the linker script.
4. **Garbage collection**: drops unused sections with `--gc-sections`.

### Libraries

- A static library `libx.a` is an archive of `.o` files. The linker pulls from it **only the members needed** to resolve undefined symbols.
- **Order matters** for archives: put libraries after the objects that use them (`-lm` last). `-Wl,--start-group ... --end-group` re-scans a set of archives repeatedly.
- `-Wl,-u,symbol` forces a symbol to be treated as undefined so the linker pulls it in. This is how `-Wl,-u,_printf_float` enables `%f` in newlib-nano.
- Weak symbols (`__attribute__((weak))`) are overridden by a strong definition. The startup file uses them for all interrupt handlers.

### The map file

```
-Wl,-Map=blink.map  -Wl,--print-memory-usage
```

```
Memory region         Used Size  Region Size  %age Used
           FLASH:        8712 B         1 MB      0.83%
             RAM:        2000 B       320 KB      0.61%
```

In `blink.map` you can see: which object put what where, the final address of every symbol, which library members were pulled in, and discarded sections. When Flash or RAM overflows, the map shows who is responsible.

### Common link errors

| Error | Cause and fix |
|---|---|
| `undefined reference to 'foo'` | Missing source file or library, or wrong order of `-l` |
| `undefined reference to '_init'` / `__libc_init_array` | Startup or libc missing: check `--specs` and that newlib is installed |
| `undefined reference to '_write'` / `_sbrk` | Syscalls not implemented. `nosys.specs` provides stubs, or write your own |
| `region 'FLASH' overflowed by N bytes` | Image too big. Use `-Os`, drop `printf %f`, inspect map |
| `region 'RAM' overflowed` | Too many globals or too large stack/heap reservation |
| `multiple definition of 'x'` | Two strong definitions, or variable defined in a header |
| `warning: _close is not implemented and will always fail` | Harmless: stubs from `nosys.specs`. Disappears when you provide syscalls |
| `... uses VFP register arguments, ... does not` | Mixed float ABIs: compile and link flags differ |
| `cannot find -lc` | newlib not installed (`libnewlib-arm-none-eabi`) |

---

## 7. The linker script (`.ld`)

It tells the linker the **memory map** of the chip and **where each section goes**.

### The STM32F746 memory map (what matters)

| Region | Address | Size | Notes |
|---|---|---|---|
| Flash (AXIM) | `0x08000000` | 1 MB | Code and constants. Default boot target |
| ITCM RAM | `0x00000000` | 16 KB | Zero wait states for code |
| DTCM RAM | `0x20000000` | 64 KB | Zero wait states for data. Initial stack is often here |
| SRAM1 | `0x20010000` | 240 KB | General purpose |
| SRAM2 | `0x2004C000` | 16 KB | General purpose |
| Peripherals | `0x40000000` | | APB/AHB registers |
| Core peripherals | `0xE0000000` | | SysTick, NVIC, SCB (CPACR, CFSR...) |

ST's default script treats `0x20000000` with 320 KB as one RAM region, which is why the initial stack pointer is `0x20050000` (`0x20000000 + 320K`). Check the reference manual for DMA access restrictions to DTCM before placing DMA buffers there.

### Minimal but real linker script

```ld
/* Entry point (informational for the debugger; hardware uses the vector table) */
ENTRY(Reset_Handler)

/* Memory regions */
MEMORY
{
  FLASH (rx)  : ORIGIN = 0x08000000, LENGTH = 1024K
  RAM   (rwx) : ORIGIN = 0x20000000, LENGTH = 320K
}

/* Initial stack pointer: top of RAM (stack grows downward) */
_estack = ORIGIN(RAM) + LENGTH(RAM);

_Min_Heap_Size  = 0x400;
_Min_Stack_Size = 0x1000;

SECTIONS
{
  /* Vector table must be first in Flash (address 0x08000000) */
  .isr_vector :
  {
    . = ALIGN(4);
    KEEP(*(.isr_vector))      /* KEEP: nothing references it, but hardware needs it */
    . = ALIGN(4);
  } >FLASH

  .text :
  {
    . = ALIGN(4);
    *(.text)
    *(.text*)
    KEEP(*(.init))
    KEEP(*(.fini))
    . = ALIGN(4);
    _etext = .;
  } >FLASH

  .rodata :
  {
    . = ALIGN(4);
    *(.rodata)
    *(.rodata*)
    . = ALIGN(4);
  } >FLASH

  /* C++ / newlib constructor tables */
  .preinit_array : { PROVIDE_HIDDEN(__preinit_array_start = .); KEEP(*(.preinit_array*)) PROVIDE_HIDDEN(__preinit_array_end = .); } >FLASH
  .init_array    : { PROVIDE_HIDDEN(__init_array_start = .);    KEEP(*(SORT(.init_array.*))) KEEP(*(.init_array*)) PROVIDE_HIDDEN(__init_array_end = .); } >FLASH
  .fini_array    : { PROVIDE_HIDDEN(__fini_array_start = .);    KEEP(*(SORT(.fini_array.*))) KEEP(*(.fini_array*)) PROVIDE_HIDDEN(__fini_array_end = .); } >FLASH

  /* Load address of .data in Flash (used by the startup copy loop) */
  _sidata = LOADADDR(.data);

  /* .data: VMA in RAM, LMA (stored) in Flash */
  .data :
  {
    . = ALIGN(4);
    _sdata = .;               /* start of .data in RAM */
    *(.data)
    *(.data*)
    . = ALIGN(4);
    _edata = .;               /* end of .data in RAM */
  } >RAM AT> FLASH

  .bss :
  {
    . = ALIGN(4);
    _sbss = .;
    *(.bss)
    *(.bss*)
    *(COMMON)
    . = ALIGN(4);
    _ebss = .;
  } >RAM

  /* Compile-time check that heap + stack still fit in RAM */
  ._user_heap_stack :
  {
    . = ALIGN(8);
    PROVIDE(end = .);
    PROVIDE(_end = .);
    . = . + _Min_Heap_Size;
    . = . + _Min_Stack_Size;
    . = ALIGN(8);
  } >RAM
}
```

### Concepts in the script

| Syntax | Meaning |
|---|---|
| `MEMORY { ... }` | Defines regions with attributes (`r`, `w`, `x`) |
| `SECTIONS { ... }` | Maps input sections to output sections |
| `.` | The **location counter**: current address |
| `*(.text*)` | All `.text*` input sections from all files |
| `>FLASH` | Place in region FLASH (VMA and LMA) |
| `>RAM AT> FLASH` | VMA in RAM, LMA in Flash |
| `KEEP(...)` | Protect from `--gc-sections` |
| `ALIGN(n)` | Round `.` up to a multiple of `n` |
| `sym = expr;` | Define a symbol (an absolute address, no storage) |
| `PROVIDE(sym = ...)` | Define only if no one else did |
| `LOADADDR(.sec)` / `ORIGIN()` / `LENGTH()` / `SIZEOF()` | Query layout |
| `/DISCARD/` | Drop sections |

### Using linker symbols from C

Linker symbols have no storage; their **address** is the value. Always take the address:

```c
extern uint32_t _sdata, _edata, _sidata;
uint32_t *src = &_sidata;        /* correct: the address */
/* uint32_t v = _sdata;  <- WRONG: would read memory at that address */
```

### Useful extra: place data in a specific region

```c
__attribute__((section(".dtcm_data"))) uint8_t fast_buf[1024];
```

and add a matching output section in the linker script.

---

## 8. Startup code and boot sequence

### What the hardware does at reset

1. Chooses the boot address (default: Flash at `0x08000000`).
2. Loads **SP** from the first word of the vector table (`0x08000000`).
3. Loads **PC** from the second word (`0x08000004`) = address of `Reset_Handler` (bit 0 = 1, Thumb).
4. Starts executing. No C runtime exists yet: RAM contains garbage.

You saw this in the debugger: `msp: 0x20050000` and `pc: 0x080020bc` right after `monitor reset halt`.

### Vector table layout (Cortex-M)

| Index | Offset | Entry |
|---|---|---|
| 0 | 0x00 | Initial stack pointer |
| 1 | 0x04 | Reset |
| 2 | 0x08 | NMI |
| 3 | 0x0C | HardFault |
| 4 | 0x10 | MemManage |
| 5 | 0x14 | BusFault |
| 6 | 0x18 | UsageFault |
| 7-10 | | Reserved |
| 11 | 0x2C | SVCall |
| 12 | 0x30 | DebugMonitor |
| 13 | | Reserved |
| 14 | 0x38 | PendSV |
| 15 | 0x3C | SysTick |
| 16+ | 0x40+ | Device IRQs (WWDG, PVD, ...). The F746 has about 98 |

The vector table must be aligned (relocating it with `SCB->VTOR` requires alignment to a power of two that covers its size, at least 0x200 on the F7).

### What `Reset_Handler` must do

1. Set the stack pointer (hardware already did, but ST's startup does it again).
2. Copy `.data` from Flash (LMA, `_sidata`) to RAM (VMA, `_sdata` to `_edata`).
3. Zero `.bss` (`_sbss` to `_ebss`).
4. Call `SystemInit()`: enable the FPU, optionally set VTOR, clocks.
5. Call `__libc_init_array()`: runs C++ constructors and `__attribute__((constructor))` functions, and newlib's `_init`.
6. Call `main()`.
7. Loop forever if `main` returns.

Why steps 2 and 3 matter: `int x = 5;` is stored in Flash but must be readable in RAM; `int y;` must be zero. Skipping them gives globals that contain garbage.

### A complete startup written in C

You can replace the vendor `.s` file with this. It is a good exercise to understand it.

```c
#include <stdint.h>

extern uint32_t _estack;
extern uint32_t _sidata, _sdata, _edata, _sbss, _ebss;

extern int  main(void);
extern void SystemInit(void);
extern void __libc_init_array(void);

void Reset_Handler(void);
void Default_Handler(void) { for (;;) { } }   /* breakpoint here to catch unexpected IRQs */

/* Every handler is a weak alias of Default_Handler: define a function with the same
   name anywhere in your code and it overrides the weak one. */
void NMI_Handler(void)        __attribute__((weak, alias("Default_Handler")));
void HardFault_Handler(void)  __attribute__((weak, alias("Default_Handler")));
void MemManage_Handler(void)  __attribute__((weak, alias("Default_Handler")));
void BusFault_Handler(void)   __attribute__((weak, alias("Default_Handler")));
void UsageFault_Handler(void) __attribute__((weak, alias("Default_Handler")));
void SVC_Handler(void)        __attribute__((weak, alias("Default_Handler")));
void DebugMon_Handler(void)   __attribute__((weak, alias("Default_Handler")));
void PendSV_Handler(void)     __attribute__((weak, alias("Default_Handler")));
void SysTick_Handler(void)    __attribute__((weak, alias("Default_Handler")));
void WWDG_IRQHandler(void)    __attribute__((weak, alias("Default_Handler")));
/* ... the other device IRQs ... */

/* Placed first in Flash by the linker script (.isr_vector) */
__attribute__((section(".isr_vector"), used))
void (* const vector_table[])(void) = {
    (void (*)(void))&_estack,   /* 0: initial SP */
    Reset_Handler,              /* 1 */
    NMI_Handler,                /* 2 */
    HardFault_Handler,          /* 3 */
    MemManage_Handler,          /* 4 */
    BusFault_Handler,           /* 5 */
    UsageFault_Handler,         /* 6 */
    0, 0, 0, 0,                 /* 7-10 reserved */
    SVC_Handler,                /* 11 */
    DebugMon_Handler,           /* 12 */
    0,                          /* 13 reserved */
    PendSV_Handler,             /* 14 */
    SysTick_Handler,            /* 15 */
    WWDG_IRQHandler,            /* 16: first device IRQ */
    /* ... */
};

void Reset_Handler(void)
{
    uint32_t *src = &_sidata;
    uint32_t *dst = &_sdata;
    while (dst < &_edata) { *dst++ = *src++; }     /* copy .data Flash -> RAM */

    for (dst = &_sbss; dst < &_ebss; ) { *dst++ = 0; }  /* zero .bss */

    SystemInit();
    __libc_init_array();
    main();
    for (;;) { }
}
```

### Why the debugger stopped in `WWDG_IRQHandler`

In ST's startup, every handler is a weak alias of `Default_Handler`, an endless loop. `WWDG_IRQHandler` is simply the **first** device IRQ, so the disassembler shows that name for the address of `Default_Handler`. Landing there means an exception or interrupt with no handler fired. To find out which, read the active exception number in `xPSR` (low 9 bits) or `SCB->ICSR` (VECTACTIVE), and `CFSR`/`HFSR` for faults.

### Fault analysis cheat sheet

```
x/wx 0xE000ED28   CFSR  (configurable fault status)
x/wx 0xE000ED2C   HFSR  (hard fault status)
x/wx 0xE000ED38   BFAR  (bus fault address, valid if CFSR BFARVALID)
x/wx 0xE000ED34   MMFAR (memory manage fault address)
x/wx 0xE000ED88   CPACR (FPU access: 0x00F00000 = enabled)
x/8wx $sp         stacked frame: r0 r1 r2 r3 r12 lr pc xPSR  ->  [6] is the faulting PC
```

| CFSR bit | Name | Typical cause |
|---|---|---|
| 0 | IACCVIOL | Fetch from a non-executable region |
| 1 | DACCVIOL | MPU data access violation |
| 8 | IBUSERR | Bus error on instruction fetch (jump to a bad address) |
| 9 | PRECISERR | Precise data bus error: BFAR holds the address (peripheral clock disabled, bad pointer) |
| 10 | IMPRECISERR | Imprecise bus error (write buffer) |
| 16 | UNDEFINSTR | Invalid instruction (wrong FPU/ISA flags, jump into data) |
| 17 | INVSTATE | Branch to an address with bit 0 clear (ARM state) |
| 18 | INVPC | Bad EXC_RETURN |
| 19 | NOCP | Coprocessor (FPU) used while disabled |
| 24 | UNALIGNED | Unaligned access with trapping enabled |
| 25 | DIVBYZERO | Divide by zero with trapping enabled |

---

## 9. The C runtime and newlib

### Which library

| Spec | Effect |
|---|---|
| (none) | Full newlib: larger, `printf` supports everything |
| `--specs=nano.specs` | **newlib-nano**: much smaller, reduced `printf`/`scanf`, no float formatting by default |
| `--specs=nosys.specs` | Links `libnosys`: stub syscalls that always fail (no OS) |
| `--specs=rdimon.specs` | Semihosting: I/O goes through the debugger |

Common combination: `--specs=nano.specs --specs=nosys.specs`.

Float printing with nano:

```
-Wl,-u,_printf_float     # enable %f in printf
-Wl,-u,_scanf_float      # enable %f in scanf
```

It costs roughly 10 KB of Flash.

### Syscalls: how `printf` reaches the UART

`printf` formats into a buffer and eventually calls `_write(fd, buf, len)`. You provide it:

```c
#include <errno.h>
#include <unistd.h>

int _write(int fd, char *ptr, int len)
{
    if (fd != STDOUT_FILENO && fd != STDERR_FILENO) { errno = EBADF; return -1; }
    for (int i = 0; i < len; i++) { uart_putc(ptr[i]); }
    return len;
}
```

Other syscalls and what uses them:

| Syscall | Used by | Notes |
|---|---|---|
| `_write` | `printf`, `puts`, `putchar` | Send to UART |
| `_read` | `scanf`, `getchar` | Receive from UART |
| `_sbrk` | `malloc` | Grows the heap; must not collide with the stack |
| `_close`, `_lseek`, `_fstat`, `_isatty` | stdio internals | Stubs are fine |
| `_exit`, `_kill`, `_getpid` | `abort`, `exit` | Stubs |

The warnings `_close is not implemented and will always fail` come from `nosys.specs` stubs. They are harmless, and disappear if you define these functions yourself.

### Stack and heap

```
High address  0x20050000  ┌───────────────┐ ◄── _estack (initial SP)
                          │     Stack     │  grows down
                          │       ▼       │
                          │               │
                          │       ▲       │
                          │     Heap      │  grows up (via _sbrk)
                          ├───────────────┤ ◄── end / _end
                          │     .bss      │
                          │     .data     │
Low address   0x20000000  └───────────────┘
```

- `printf("%f")` and `snprintf` use several hundred bytes of stack. If `_Min_Stack_Size` is too small you get random crashes.
- On the M7 there is no hardware stack-overflow protection unless you use the MPU. Detect it by filling the stack with a pattern at startup and checking the high-water mark, or with `-fstack-usage` and `-Wstack-usage=N`.
- In critical firmware, avoid `malloc`. Prefer static allocation.

### Buffering gotcha

By default `stdout` is line-buffered, so `printf("text")` without `\n` may not appear. For early bring-up:

```c
setvbuf(stdout, NULL, _IONBF, 0);   /* unbuffered */
```

Terminals also expect `\r\n`.

---

## 10. Debug info, flashing, and the CRC

### Programming paths

```bash
# st-flash (stlink-tools): raw binary, you give the address
st-flash --reset write build/blink.bin 0x08000000

# OpenOCD: reads the ELF, knows the addresses
openocd -f interface/stlink.cfg -f target/stm32f7x.cfg \
        -c "program build/blink.elf verify reset exit"

# GDB through OpenOCD (debug session)
openocd -f interface/stlink.cfg -f target/stm32f7x.cfg
arm-none-eabi-gdb build/blink.elf
(gdb) target extended-remote :3333
(gdb) monitor reset halt
(gdb) load
(gdb) break main
(gdb) continue
```

Without `--reset`, st-flash leaves the core halted after programming; the program does not start until you press reset.

If `st-flash` reports `LIBUSB_ERROR_TIMEOUT` and `GET_VERSION` fails, the ST-LINK USB interface is stuck: unplug and replug the board. This is not a firmware problem.

### CRC of the firmware image

Idea: compute a CRC over the image after linking, append it, and verify it at boot.

- The STM32 hardware CRC unit defaults to polynomial `0x04C11DB7`, init `0xFFFFFFFF`, **no** bit reflection, no final XOR, 32-bit word input. That is CRC-32/MPEG-2 over words, **not** Python's `zlib.crc32`.
- Pipeline: `elf` → `objcopy -O binary` → pad to 4 bytes → compute CRC → append → flash `blink_crc.bin`.
- The linker script defines `_fw_end` right after the last Flash section (`ALIGN(LOADADDR(.data) + SIZEOF(.data), 4)`). Firmware reads words from `0x08000000` to `_fw_end` through the CRC peripheral and compares with the stored word.
- When debugging with Cortex-Debug the ELF has no CRC appended, so the check fails. Skip it in Debug builds.

### Reproducible builds

A reproducible build produces the same bytes from the same source.

- `SOURCE_DATE_EPOCH` is an **environment variable** (not a CMake cache variable) read by GCC for `__DATE__`, `__TIME__`.
- `-ffile-prefix-map=/home/user/project=.` removes absolute paths from debug info and `__FILE__`.
- Check: build twice from scratch and compare `sha256sum build/blink.bin`.
- If you do not use `__DATE__`/`__TIME__`, the epoch changes nothing.

---

## 11. Putting it together: bare-metal LED, no HAL

A tiny program that exercises everything in this chapter. `main.c`:

```c
#include "stm32f7xx.h"

static void delay(volatile uint32_t n) { while (n--) { __NOP(); } }

int main(void)
{
    RCC->AHB1ENR |= RCC_AHB1ENR_GPIOBEN;      /* clock the GPIOB peripheral first */
    (void)RCC->AHB1ENR;                       /* read-back: short delay for the clock */

    GPIOB->MODER &= ~(3UL << (7 * 2));        /* PB7 = LD2 (blue) */
    GPIOB->MODER |=  (1UL << (7 * 2));        /* output mode */

    for (;;) {
        GPIOB->ODR ^= (1UL << 7);
        delay(1000000);
    }
}
```

Build by hand without any build system (this is what Make and CMake automate):

```bash
ARCH="-mcpu=cortex-m7 -mthumb -mfpu=fpv5-sp-d16 -mfloat-abi=hard"
INC="-Iextern/cmsis_core/Include -Iextern/cmsis_device_f7/Include"

arm-none-eabi-gcc $ARCH -DSTM32F746xx $INC -Og -g3 -ffunction-sections -fdata-sections -c main.c -o main.o
arm-none-eabi-gcc $ARCH -DSTM32F746xx $INC -Og -g3 -ffunction-sections -fdata-sections -c system_stm32f7xx.c -o system.o
arm-none-eabi-gcc $ARCH -x assembler-with-cpp -c startup_stm32f746xx.s -o startup.o

arm-none-eabi-gcc $ARCH -TSTM32F746ZGTx_FLASH.ld --specs=nano.specs --specs=nosys.specs \
    -Wl,--gc-sections -Wl,-Map=blink.map -Wl,--print-memory-usage \
    main.o system.o startup.o -o blink.elf

arm-none-eabi-size blink.elf
arm-none-eabi-objcopy -O binary blink.elf blink.bin
st-flash --reset write blink.bin 0x08000000
```

---

## 12. Lab exercises

Do these in order. Each one teaches one piece of the toolchain.

1. **Stages**: run `-E`, `-S`, `-c` on `main.c` and read each output. Find where `#define` values went.
2. **Optimization**: compile a function at `-O0`, `-Og`, `-Os`, `-O2` with `-S` and compare the assembly and `size`.
3. **Sections**: write a global `int a = 5; int b; const int c = 7;`. Use `nm` and `objdump -h` to see in which section each one lands and its address.
4. **VMA vs LMA**: `objdump -h blink.elf`; find `.data` and compare VMA and LMA. Then read `x/4wx` in gdb at both addresses after boot.
5. **Map file**: add a 4 KB global array, rebuild, and find it in `blink.map`. Watch `--print-memory-usage` change.
6. **Overflow**: make the array 400 KB. Read the `region 'RAM' overflowed` error.
7. **gc-sections**: remove `-ffunction-sections` and compare `size`. Add an unused function and confirm it disappears from `nm` with the flags on.
8. **Write your own startup**: replace the vendor `.s` with the C startup of section 8. Make the LED blink again.
9. **Weak handlers**: override `SysTick_Handler` in your code and toggle an LED from it. Remove it and observe the program stuck in `Default_Handler`.
10. **FPU**: compile with `-mfloat-abi=soft`, then `hard`, and compare `objdump -d` of a float multiplication. Then comment out the CPACR line and read the NOCP fault in CFSR.
11. **Float promotion**: add `-Wdouble-promotion`, call `printf("%f", f)` and see the warning. Search the disassembly for `f64`.
12. **Syscalls**: implement `_write` over UART. Remove `nosys.specs` and read what the linker complains about.
13. **Stack**: write a recursive function with a large local array to overflow the stack, and watch it corrupt `.bss` or fault. Then use `-fstack-usage`.
14. **Reproducibility**: build twice, compare hashes. Add `__DATE__` to a string and compare again with and without `SOURCE_DATE_EPOCH`.
15. **CRC**: add the CRC step, flash, then corrupt one byte of the `.bin` and confirm the firmware detects it.

---

## 13. Cheat sheet

### Flags that must match at compile and link

`-mcpu`, `-mthumb`, `-mfpu`, `-mfloat-abi`

### Typical flag set

```
Compile : $ARCH -Og -g3 -ffunction-sections -fdata-sections -Wall -Wextra -DSTM32F746xx
Link    : $ARCH -T<script>.ld --specs=nano.specs --specs=nosys.specs
          -Wl,--gc-sections -Wl,-Map=out.map -Wl,--print-memory-usage
```

### Questions and the command that answers them

| Question | Command |
|---|---|
| Which compiler and version? | `arm-none-eabi-gcc --version` |
| Which library variant is linked? | `-print-multi-directory` with your flags |
| How big is it? | `arm-none-eabi-size blink.elf` |
| What is taking space? | `nm -S --size-sort -C blink.elf \| tail` |
| Does it have debug symbols? | `readelf -S blink.elf \| grep debug_line` |
| What does this address belong to? | `addr2line -e blink.elf -f 0x...` or gdb `info symbol 0x...` |
| Where did the linker put X? | `blink.map` or `nm blink.elf \| grep X` |
| What instruction is at the fault? | `objdump -d blink.elf` or gdb `x/6i $pc` |
| What macros does the compiler predefine? | `gcc <flags> -dM -E - < /dev/null` |
| What did gcc really run? | `-v` or `-###` |

### Boot sequence in one line

Reset → load SP and PC from the vector table → `Reset_Handler` → copy `.data` → zero `.bss` → `SystemInit` → `__libc_init_array` → `main`.

---

## 14. Where this leads

- **Chapter 1 (make)** and **chapter 2 (cmake)** automate everything in section 11: compiling each file with the right flags, tracking header dependencies, linking with the linker script, and generating the `.bin`.
- **Cortex-M architecture** (modes, stacks, NVIC, exceptions) explains why the vector table and faults behave the way they do.
- **Debugging** (GDB, OpenOCD, Cortex-Debug) builds directly on the fault analysis cheat sheet above.

## References

- Arm GNU Toolchain documentation and GCC manual (`info gcc`)
- GNU ld manual: *Linker Scripts* (`info ld`)
- newlib documentation
- ARM *Cortex-M7 Devices Generic User Guide*
- ST *RM0385* (STM32F75xxx and STM32F74xxx reference manual) and *PM0253* (F7 programming manual)
- *The Definitive Guide to ARM Cortex-M3 and Cortex-M4 Processors*, Joseph Yiu