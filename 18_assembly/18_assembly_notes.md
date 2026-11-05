# 18. ARM Thumb-2 Assembly for Cortex-M7

Purpose: **read** compiler output and vendor startup files, **write** small assembly routines (handlers, context switch, tight loops), and use inline assembly and intrinsics safely. You do not need to write much assembly; you need to read it fluently.

Prerequisites: chapter 0 (toolchain, startup), chapter 3 (registers, exceptions, AAPCS), chapter 5 (C). Target: Cortex-M7 (ARMv7E-M, Thumb-2, FPv5-SP).

**Verification note.** Instruction semantics are from the ARMv7-M Architecture Reference Manual and the Cortex-M7 user guide as I remember them; code is illustrative and **not run on your board**. When in doubt, assemble it and disassemble the result, or check the ARM ARM encoding.

---

## 1. Why learn it

| Reason | Example |
|---|---|
| Read disassembly (`objdump -d`, gdb) | Find the `vcvt.f64.f32` that caused UNDEFINSTR (chapter 3) |
| Understand startup and handlers | `Reset_Handler`, `HardFault_Handler` trampolines, `PendSV` context switch |
| Diagnose compiler/optimizer effects | Missing `volatile`, inlined/removed code, jump tables |
| Optimize hot paths | Intrinsics (`__SSAT`, `__REV`, `__CLZ`, `__SMLAD`), choosing the right instruction |
| Cycle-exact or special-instruction code | Barriers, `WFI`, `MRS/MSR`, exclusive access, bit-banging |
| Debugging when there is no source | Binary-only libs, ROM code, crash dumps |

Rule: **let the compiler generate the code**, check what it produced where it matters, and drop to assembly only for what C cannot express.

---

## 2. The programming model (recap)

| Register | Notes |
|---|---|
| `r0`-`r12` | General purpose (`r0`-`r7` "low": usable by all 16-bit encodings) |
| `r13` = `sp` | Stack pointer (banked MSP/PSP) |
| `r14` = `lr` | Link register / `EXC_RETURN` in handlers |
| `r15` = `pc` | Program counter (reads as current instruction + 4 in Thumb) |
| `xPSR` | N, Z, C, V, Q flags; T bit must be 1; IPSR exception number |
| `s0`-`s31` | FPU registers (`d0`-`d15` pairs on DP) |
| `PRIMASK`, `BASEPRI`, `FAULTMASK`, `CONTROL` | Special registers (`MRS`/`MSR`) |

Thumb-2 mixes **16-bit** and **32-bit** instructions. Branch targets and function pointers must have **bit 0 = 1** (Thumb state): the assembler/linker handle this for symbols declared `.thumb_func`.

### Flags and conditions

Instructions with an **`S` suffix** (`adds`, `subs`, `movs`) update the flags; `cmp`, `cmn`, `tst`, `teq` always do. Condition codes:

| Code | Meaning | Flags |
|---|---|---|
| `EQ` / `NE` | equal / not equal | Z=1 / Z=0 |
| `CS`(`HS`) / `CC`(`LO`) | unsigned higher-or-same / lower | C=1 / C=0 |
| `MI` / `PL` | negative / positive-or-zero | N=1 / N=0 |
| `VS` / `VC` | overflow / no overflow | V=1 / V=0 |
| `HI` / `LS` | unsigned higher / lower-or-same | C=1&Z=0 / C=0 or Z=1 |
| `GE` / `LT` | signed >= / < | N==V / N!=V |
| `GT` / `LE` | signed > / <= | Z=0&N==V / Z=1 or N!=V |
| `AL` | always | |

Use **unsigned** conditions (`HI`, `LO`...) for pointers and `uint32_t`, **signed** (`GT`, `LT`...) for `int32_t`.

---

## 3. Instruction tour

Notation: `Rd` destination, `Rn`/`Rm` source registers, `#imm` immediate, `op2` flexible second operand (register optionally shifted, or an immediate).

### 3.1 Data movement and constants

```
mov   r0, r1            ; r0 = r1
movs  r0, #5            ; r0 = 5 and update flags
movw  r0, #0x1234       ; r0 = 0x00001234 (16-bit immediate)
movt  r0, #0x4002       ; upper halfword: r0 = 0x40021234
ldr   r0, =0x40021800   ; assembler picks mov/movw+movt or a literal pool word
ldr   r0, =label        ; address of a symbol
adr   r0, label         ; PC-relative address (nearby)
mvn   r0, r1            ; r0 = ~r1
```

### 3.2 Load and store

```
ldr   r0, [r1]              ; r0 = *(uint32_t*)r1
ldr   r0, [r1, #8]          ; offset addressing
ldr   r0, [r1, r2]          ; register offset
ldr   r0, [r1, r2, lsl #2]  ; scaled index (array of words)
ldr   r0, [r1, #4]!         ; pre-index with writeback: r1 += 4 first
ldr   r0, [r1], #4          ; post-index: use r1, then r1 += 4
ldrb  r0, [r1]  ldrh r0, [r1]   ; byte / halfword, zero-extended
ldrsb r0, [r1]  ldrsh r0, [r1]  ; sign-extended
str   r0, [r1] ; strb ; strh
ldrd  r0, r1, [r2]          ; two registers (needs word alignment)
ldm   r0!, {r1-r4}          ; load multiple (ascending), r0 updated
stmdb r0!, {r4-r11}         ; store multiple, decrement before (used by the context switch)
push  {r4, r5, lr}          ; = stmdb sp!, {r4, r5, lr}
pop   {r4, r5, pc}          ; = ldmia sp!, {r4, r5, pc} : return
ldrex / strex               ; exclusive access (atomic read-modify-write)
```

### 3.3 Arithmetic and logic

```
add  r0, r1, r2         ; r0 = r1 + r2         adds/adc for carry chains
sub  r0, r1, #4         ; rsb r0, r1, #0 : reverse subtract (negate)
mul  r0, r1, r2         ; 32-bit multiply (1 cycle on M7)
mla  r0, r1, r2, r3     ; r0 = r1*r2 + r3        mls : r3 - r1*r2
smull / umull  RdLo, RdHi, Rn, Rm   ; 32x32 -> 64-bit signed / unsigned
smlal / umlal                       ; accumulate into 64-bit
sdiv / udiv  r0, r1, r2             ; hardware divide (2-12 cycles); division by zero returns 0 unless trapped (CCR.DIV_0_TRP)
and  orr  eor  bic  orn             ; logic (bic = bit clear: Rn & ~op2)
lsl  lsr  asr  ror                  ; shifts and rotates
adds r0, r1, r2, lsl #2             ; flexible op2: r1 + (r2 << 2)
```

### 3.4 Bit-field and bit tricks

```
ubfx r0, r1, #8, #4     ; unsigned bit-field extract: r0 = (r1 >> 8) & 0xF
sbfx                    ; signed extract
bfi  r0, r1, #8, #4     ; insert low 4 bits of r1 into r0[11:8]
bfc  r0, #8, #4         ; clear field
clz  r0, r1             ; count leading zeros
rbit r0, r1             ; reverse bits (ctz = rbit + clz)
rev  rev16  revsh       ; byte swap (endianness)
uxtb uxth sxtb sxth     ; zero/sign extend byte/halfword
```

### 3.5 Branches

```
b     label             ; unconditional
beq/bne/blt/...         ; conditional (after cmp/flags)
bl    function          ; call: lr = return address (bit 0 set)
bx    lr                ; return / indirect jump (bit 0 selects state: must be 1)
blx   r3                ; indirect call
cbz   r0, label ; cbnz  ; compare and branch if (non)zero: FORWARD only, r0-r7, short range
tbb   [pc, r0]  tbh     ; table branch (switch jump tables)
it    eq                ; IT block: next instruction executes only if EQ (up to 4 instructions: ite, itt, itte ...)
```

`cmp r0, #10` then `bhi` etc. After `IT`-block conditions the assembler requires the condition suffix on each instruction: `it eq` / `addeq r0, r0, #1`.

### 3.6 System and special

```
mrs  r0, msp            ; read special registers: msp, psp, primask, basepri, faultmask, control, ipsr, xpsr
msr  primask, r0        ; write them
cpsid i  /  cpsie i     ; disable / enable interrupts (PRIMASK)  ; cpsid f / cpsie f : FAULTMASK
svc  #5                 ; supervisor call (SVCall exception; 8-bit immediate)
bkpt #0                 ; breakpoint
wfi  wfe  sev           ; wait for interrupt / event ; send event
nop
dmb  dsb  isb           ; barriers (usually "sy" = full system): chapter 3
```

### 3.7 Saturating and DSP (ARMv7E-M)

```
ssat r0, #16, r1        ; signed saturate to 16 bits
usat r0, #8, r1         ; unsigned saturate to 8 bits
qadd qsub qdadd         ; saturating add/sub
sadd16 / uadd8 / ...    ; SIMD adds on halfword/byte pairs
smlad r0, r1, r2, r3    ; dual 16x16 multiply-accumulate: r0 = r3 + r1[15:0]*r2[15:0] + r1[31:16]*r2[31:16]
smuad / smusd / pkhbt   ; related dual-MAC and pack operations
```

CMSIS-DSP uses these; in C use the intrinsics from `cmsis_gcc.h`: `__SSAT`, `__USAT`, `__QADD`, `__SMLAD`, `__REV`, `__RBIT`, `__CLZ`.

### 3.8 Floating point (FPv5-SP)

```
vldr  s0, [r0]          ; load a float          vstr s0, [r0]
vmov  s0, r1            ; core register <-> FPU register ; vmov.f32 s0, #1.0 (small constants)
vadd.f32 s2, s0, s1     ; vsub.f32 vmul.f32 vdiv.f32 vsqrt.f32 vabs.f32 vneg.f32
vfma.f32 s2, s0, s1     ; fused multiply-add: s2 += s0*s1
vcmp.f32 s0, s1 ; vmrs APSR_nzcv, fpscr    ; compare and copy FP flags to the integer flags
vcvt.s32.f32 s0, s0     ; float -> int (truncation)    vcvt.f32.s32 : int -> float
vcvt.f64.f32 d7, s0     ; float -> double: DOUBLE-PRECISION instruction: UNDEFINSTR on an SP-only FPU (chapter 3)
vpush {s16-s31} / vpop  ; save callee-saved FP registers
```

`-mfloat-abi=hard`: floating arguments and results travel in `s0`... (chapter 3 AAPCS table). Variadic functions (`printf`) still pass floats **as doubles in core registers** after promotion.

---

## 4. Writing assembly with the GNU assembler

### 4.1 File skeleton

```asm
    .syntax unified            @ modern unified syntax (always use it)
    .cpu cortex-m7
    .fpu fpv5-sp-d16
    .thumb

    .section .text.add3, "ax", %progbits
    .global add3
    .type   add3, %function
    .thumb_func
add3:                          @ int add3(int a, int b, int c)
    add   r0, r0, r1
    add   r0, r0, r2
    bx    lr
    .size add3, . - add3
```

Comments: `@` (ARM GNU assembler) or `//`; if the file ends with `.S` (capital) it goes through the C preprocessor (`#include`, `#define`), `.s` does not. In CMake, enable `ASM` in `project()` and list the file as a source.

### 4.2 Useful directives

| Directive | Meaning |
|---|---|
| `.global sym` / `.weak sym` | Export / weak symbol (default interrupt handlers) |
| `.thumb_func` | Mark the next label as a Thumb function (sets bit 0 in its address) |
| `.type sym, %function`, `.size sym, expr` | Symbol info (debuggers, `nm -S`) |
| `.section name, "flags", %type` | `"ax"` allocatable+executable, `"aw"` writable, `%progbits`/`%nobits` |
| `.word`, `.hword`, `.byte`, `.ascii`, `.asciz` | Data |
| `.align n` / `.balign n` | Alignment (`.align 2` = 4 bytes on ARM) |
| `.equ NAME, value`, `.set` | Constants |
| `.ltorg` | Place the literal pool here (for `ldr r0, =value`) |
| `.macro` ... `.endm` | Macros |
| `.extern`, `.include` | |

### 4.3 Calling convention (AAPCS recap)

`r0-r3` arguments and results (`r0:r1` for 64-bit), `r12` scratch, **`r4-r11` must be preserved**, `sp` 8-byte aligned at calls, `lr` return address. A function that calls others must save `lr`. With the hard-float ABI, `s0-s15` are caller-saved and **`s16-s31` callee-saved**.

### 4.4 Examples

**strlen** (byte loop; `cbz`/`cbnz` only branch **forward**, so a backward loop uses `cmp` + `bne`):

```asm
@ size_t my_strlen(const char *s)
    .global my_strlen
    .type my_strlen, %function
    .thumb_func
my_strlen:
    mov   r1, r0
1:  ldrb  r2, [r1], #1        @ r2 = *r1++
    cmp   r2, #0
    bne   1b                  @ backward branch to local label 1
    subs  r0, r1, r0          @ r1 is one past the terminator
    subs  r0, r0, #1
    bx    lr
```

**Word copy** (forward `cbz` is allowed):

```asm
@ void copy_words(uint32_t *dst, const uint32_t *src, uint32_t n)
copy_words:
    cbz   r2, 2f
1:  ldr   r3, [r1], #4
    str   r3, [r0], #4
    subs  r2, r2, #1
    bne   1b
2:  bx    lr
```

**Reading CPU state from C** (inline assembly, chapter 3):

```c
static inline uint32_t get_sp(void) { uint32_t v; __asm volatile ("mov %0, sp" : "=r"(v)); return v; }
```

**Count trailing zeros** (`rbit` + `clz`, which is what `__builtin_ctz` compiles to):

```asm
ctz32:
    rbit r0, r0
    clz  r0, r0
    bx   lr
```

**Exclusive access (atomic increment)**:

```asm
@ void atomic_inc(volatile uint32_t *p)
atomic_inc:
1:  ldrex r1, [r0]
    adds  r1, r1, #1
    strex r2, r1, [r0]
    cbnz  r2, 3f             @ forward branch only: use a normal conditional branch for the retry
    bx    lr
3:  b     1b
```

(In C use `<stdatomic.h>`: the compiler generates this.)

### 4.5 Inline assembly syntax

```c
__asm volatile (
    "template"
    : output operands          /* "=r"(var)  "+r"(var) for read-write */
    : input operands           /* "r"(var)   "i"(constant)   "I"(8-bit immediate)*/
    : clobbers                 /* "memory", "cc", "r0" ... */
);
```

```c
uint32_t r;
__asm volatile ("qadd %0, %1, %2" : "=r"(r) : "r"(a), "r"(b));            /* saturating add */
__asm volatile ("mrs %0, primask" : "=r"(primask));
__asm volatile ("cpsid i" ::: "memory");                                  /* "memory": compiler barrier */
__asm volatile ("ldr %[v], [%[p]]" : [v] "=r"(val) : [p] "r"(ptr));       /* named operands */
```

- `volatile` prevents removal/reordering relative to other volatile operations; `"memory"` tells the compiler memory may change; `"cc"` flags are modified; `&` early-clobber output (`"=&r"`) when the output is written before all inputs are consumed.
- Prefer CMSIS intrinsics (`__disable_irq()`, `__get_PRIMASK()`, `__DSB()`, `__WFI()`) which have the right constraints.
- **Naked functions** (`__attribute__((naked))`) contain **only** assembly: no prologue, no epilogue, no C code inside (chapter 3's HardFault trampoline).

---

## 5. Real-world assembly pieces

### 5.1 `Reset_Handler` (typical ST startup, annotated; your file may differ)

```asm
Reset_Handler:
    ldr   sp, =_estack            @ initial stack pointer (also loaded by hardware from the vector table)
    movs  r1, #0
    b     LoopCopyDataInit
CopyDataInit:                      @ copy .data from Flash to RAM, one word at a time
    ldr   r3, =_sidata
    ldr   r3, [r3, r1]
    str   r3, [r0, r1]
    adds  r1, r1, #4
LoopCopyDataInit:
    ldr   r0, =_sdata
    ldr   r3, =_edata
    adds  r2, r0, r1
    cmp   r2, r3
    bcc   CopyDataInit             @ while (dst + offset < _edata)
    ldr   r2, =_sbss
    b     LoopFillZerobss
FillZerobss:                       @ zero .bss
    movs  r3, #0
    str   r3, [r2], #4
LoopFillZerobss:
    ldr   r3, =_ebss
    cmp   r2, r3
    bcc   FillZerobss
    bl    SystemInit               @ enable FPU, VTOR (chapter 3)
    bl    __libc_init_array        @ C library and constructors
    bl    main
    bx    lr                       @ main returned (should not happen)
```

`bcc` = branch if carry clear = unsigned lower. The same logic as the C version in chapter 0.

### 5.2 A weak default handler

```asm
    .weak NMI_Handler
    .thumb_set NMI_Handler, Default_Handler     @ alias: overridden by any strong definition of NMI_Handler

Default_Handler:
Infinite_Loop:
    b Infinite_Loop                              @ the loop you saw as WWDG_IRQHandler in gdb
```

### 5.3 SVC handler and the number

```c
__attribute__((naked)) void SVC_Handler(void)
{
    __asm volatile (
        "tst   lr, #4        \n"           /* EXC_RETURN bit 2: which stack held the frame? */
        "ite   eq            \n"
        "mrseq r0, msp       \n"
        "mrsne r0, psp       \n"
        "b     svc_c         \n");
}

void svc_c(uint32_t *frame)                /* frame = r0 r1 r2 r3 r12 lr pc xpsr */
{
    uint8_t number = ((const uint8_t *)frame[6])[-2];   /* the imm8 of the `svc #n` instruction before the stacked PC */
    frame[0] = do_syscall(number, frame[0], frame[1]);   /* return value goes back into the caller's r0 */
}
```

### 5.4 PendSV context switch

See chapter 3 section 13: `mrs r0, psp`, `stmdb r0!, {r4-r11}`, save the stack pointer, pick the next task, `ldmia`, `msr psp`, `bx lr` with `EXC_RETURN = 0xFFFFFFFD`. FPU tasks also need `vstmdb/vldmia` of `s16-s31` depending on `EXC_RETURN` bit 4.

### 5.5 Cycle-accurate delays: why they are not accurate

```asm
delay_loop:
    subs r0, r0, #1
    bne  delay_loop           @ NOT a reliable delay: timing depends on flash wait states, ART, caches, prefetch, branch prediction, and dual issue
```

The Cortex-M7 has a 6-stage **dual-issue** pipeline, branch prediction, I/D caches, and flash accelerators: the same loop can take different times in different memories or after the caches warm up. For real timing use a **hardware timer** or the **DWT cycle counter** (chapter 3), and `k_busy_wait`/`delay_us` built on them.

---

## 6. Reading compiler output

### 6.1 Tools

```bash
arm-none-eabi-gcc -mcpu=cortex-m7 -mthumb -mfpu=fpv5-sp-d16 -mfloat-abi=hard -Os -S -fverbose-asm f.c   # assembly source
arm-none-eabi-objdump -d -S build/blink.elf | less          # disassembly with source (needs -g)
arm-none-eabi-objdump -d --no-show-raw-insn build/blink.elf # cleaner view
arm-none-eabi-objdump -D -b binary -m arm -M force-thumb file.bin     # disassemble a raw binary as Thumb
arm-none-eabi-gdb> disassemble /s main ; x/12i $pc ; display/i $pc ; stepi ; layout asm ; layout regs
```

Compiler Explorer (godbolt.org, `ARM GCC (none-eabi)`) with the same flags is the fastest way to experiment.

### 6.2 Patterns to recognize

| C | Typical Thumb-2 |
|---|---|
| Function prologue/epilogue | `push {r4-r7, lr}` ... `pop {r4-r7, pc}` |
| `x = *p` (volatile) | `ldr r0, [r1]` kept even if the value is unused |
| `a[i]` on `int` | `ldr r0, [r1, r2, lsl #2]` |
| `x * 10` | `add r0, r0, r0, lsl #2` then `lsl r0, r0, #1` (or `mov` + `mul`) |
| `x / 8` unsigned | `lsrs r0, r0, #3`; signed needs a fix-up for negatives |
| `x / constant` | multiply by a magic reciprocal (`smull`/`umull`) and shift |
| `x % 2^n` | `and`/`bic` (unsigned) |
| `if` / `else` | `cmp` + `b<cond>`, or `it`/`ite` blocks for short cases |
| `switch` with dense cases | `cmp` + `bhi default` + `tbb`/`tbh` jump table |
| Loop `for (i = 0; i < n; i++)` | `subs`/`bne` counting down; unrolled at `-O2/-O3` |
| 64-bit add | `adds` + `adc` pair |
| 64-bit multiply | `umull` / `mla` combinations |
| Float ops | `vldr`, `vmul.f32`, `vadd.f32`, `vstr`; `vfma.f32` with `-ffp-contract=fast` |
| `float` → `double` | `vcvt.f64.f32`: **not available on an SP-only FPU** |
| Function call | `bl func` (or `bx r3`/`blx r3` for pointers); arguments in `r0-r3` |
| Tail call | `b func` instead of `bl` + `pop {pc}` |
| `volatile` access | Every access appears; no merging |
| Inlined function | Body repeated at the call site; symbol may still exist unused |
| `memcpy` small constant | A few `ldr/str` pairs or `ldm/stm`; larger: `bl memcpy` |
| Bit-field | `ubfx`, `bfi`, `bfc` |
| `__builtin_clz` | `clz` |
| Stack protector | A canary load/compare before return |

### 6.3 Optimization levels and what you will see

`-O0`: every variable lives on the stack; instructions mirror the source (easy to follow, slow). `-Og`: debug-friendly. `-Os`/`-O2`: values stay in registers, loops restructured, code inlined and reordered; debugger line stepping jumps around. Compare `-O0` and `-Os` of the same function once; it demystifies the optimizer.

### 6.4 Case study: what happened with `printf("%.2f", vbat)`

```
bl      adc_read_vbat        ; returns float in s0 (hard-float ABI)
vcvt.f64.f32 d7, s0          ; float -> double: promotion required by the variadic call
vmov    r2, r3, d7           ; the double is passed in r2:r3 (r0 = format, r1 skipped for alignment)
bl      printf
```

The second instruction needs a **double-precision FPU**; on the F746's single-precision FPU it raised UNDEFINSTR (chapter 3, section 6.4). This is the kind of diagnosis only assembly literacy makes quick.

---

## 7. Performance on the Cortex-M7

- **Dual-issue** in-order pipeline: some instruction pairs execute together; independent instructions fill both slots; dependent chains do not.
- **Branch prediction** and a **branch target cache**: loops are cheap when predicted; unpredictable branches cost cycles.
- **Memory**: ITCM/DTCM give deterministic zero-wait-state access; flash via the **ART accelerator** and I-cache is fast on hits, slow on misses; AXI SRAM goes through the D-cache (hits/misses/write buffer).
- Load/store timing depends on alignment and on the memory region; multiple loads can pipeline.
- Hardware **divide** takes a variable number of cycles; `vsqrt`/`vdiv` take 14 cycles or so (check the TRM): avoid in hot loops.
- Measure with the DWT cycle counter on realistic data and in the final memory placement; **do not count cycles by hand**.

Optimization order: algorithm → data layout and memory placement → compiler flags (`-O2`, `-Os`, LTO, `-ffast-math` only if safe) → intrinsics/CMSIS-DSP → hand assembly (almost never).

---

## 8. Debugging assembly

```
(gdb) layout asm            # source and instructions
(gdb) stepi / nexti         # one instruction
(gdb) display/i $pc         # show the next instruction at every stop
(gdb) info registers        # r0-r12, sp, lr, pc, xpsr
(gdb) p/x $xpsr             # flags: N bit 31, Z 30, C 29, V 28; T bit 24
(gdb) x/8i $pc ; x/4wx $sp
(gdb) info line *0x08001ba0 ; info symbol 0x08001ba0
```

Common mistakes in hand-written code: forgetting `.thumb_func` (the symbol has bit 0 clear: BX to it faults with INVSTATE), clobbering `r4-r11` or `s16-s31` without saving, misaligned stack (`push` an odd number of registers before a call), backward `cbz`/`cbnz`, wrong condition (signed vs unsigned), using `lr` after a `bl` without saving it, literal pools out of range (add `.ltorg`), flags changed unexpectedly by `adds` vs `add`.

---

## 9. Exercises

1. **Read a function**: compile `int sum(const int *a, int n)` at `-O0` and `-Os`; annotate each instruction and compare.
2. **Disassemble your blink**: find `main`, the GPIO write, the loop, and the delay; identify `BSRR`/`ODR` accesses.
3. **`vcvt.f64.f32`**: find it in a build with the wrong `-mfpu` (chapter 3) and show it is gone with `-mfpu=fpv5-sp-d16` and a cast/literal fix.
4. **Startup**: annotate your project's `Reset_Handler` and re-write it in C (chapter 0), then compare the generated assembly.
5. **Assembly function in CMake**: add `add3.S` and call it from C; test it; check the `.thumb_func` effect by removing it and observing the fault.
6. **`my_strlen` and `copy_words`**: implement, test against `strlen`/`memcpy` on random data in the board's firmware; measure cycles with DWT versus the library versions.
7. **Intrinsics**: compare a C saturating add and `__QADD`; `__REV` vs manual byte swap; `__CLZ`; inspect the instructions generated.
8. **Switch jump table**: compile a dense `switch`, find `tbb`/`tbh`, and an if-chain for a sparse one.
9. **Inline assembly**: read `PRIMASK`, `CONTROL`, `MSP`/`PSP` with `MRS`, print them; write `CONTROL.SPSEL` and verify the stack switch.
10. **SVC**: implement `svc #n` calls from Thread mode and handle them as in 5.3; return a value.
11. **Atomic**: implement `atomic_inc` with `LDREX/STREX`, compare with `atomic_fetch_add`.
12. **Timing**: measure `delay_loop` iterations in cycles at 16 MHz and 216 MHz, in flash and in ITCM/RAM, with caches on/off; observe the variance.
13. **Hand-assemble**: pick `movs r0, #5` and `add r0, r1, r2`, find their encodings in the ARM ARM, and confirm with `objdump -d` (and the raw bytes with `xxd`).
14. **Crash analysis**: from the fault frame of chapter 3, disassemble around the stacked PC and explain the fault in terms of the instruction.

---

## 10. Cheat sheet

```
Flags:   N Z C V ; S suffix updates ; cmp/tst always ; EQ NE CS CC MI PL VS VC HI LS GE LT GT LE AL
Call:    bl f / bx lr ; args r0-r3 ; preserve r4-r11 (and s16-s31) ; sp 8-byte aligned ; save lr if you call
Mem:     ldr/str (b,h,sb,sh,d) ; [rn, #off] [rn, rm, lsl #n] [rn, #n]! [rn], #n ; ldm/stm ; push/pop
Const:   movs / movw+movt / ldr r0,=imm
Bits:    ubfx sbfx bfi bfc clz rbit rev uxtb sxth
Math:    add sub mul mla smull umull sdiv udiv ssat usat qadd smlad
FPU:     vldr vstr vmov vadd.f32 vmul.f32 vfma.f32 vcvt vmrs  (no f64 on the F746)
Sys:     mrs msr cpsid/cpsie svc bkpt wfi wfe dmb dsb isb ldrex strex
Rules:   .syntax unified ; .thumb_func ; cbz forward only ; literal pools .ltorg ; compiler first, assembly last
```

---

## 11. Where this leads

- **Advanced toolchain** (chapter 19): linker scripts for code in ITCM, `.ramfunc`, naked functions and sections.
- **Control and DSP** (chapter 13): intrinsics and CMSIS-DSP use of `SMLAD`, saturation.
- **RTOS** (chapters 9 and 12): context switching and SVC/PendSV internals.
- **Security** (chapter 16): constant-time code, stack protector, glitch-resistant checks.

## References

- Arm *ARMv7-M Architecture Reference Manual* (instruction set and encodings); Arm *Cortex-M7 Devices Generic User Guide* and *Technical Reference Manual*
- Arm *Procedure Call Standard for the Arm Architecture* (AAPCS)
- GNU assembler (`as`) manual: ARM directives and syntax; GCC "Extended Asm"
- Joseph Yiu, *The Definitive Guide to ARM Cortex-M3 and Cortex-M4 Processors*; *Arm Assembly Language*, Hohl and Hinds
- CMSIS-Core `cmsis_gcc.h` (intrinsics)
- Compiler Explorer: <https://godbolt.org>
