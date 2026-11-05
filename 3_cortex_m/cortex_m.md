# 3. Cortex-M Architecture (focus: Cortex-M7 on the STM32F746ZG)

Prerequisites: chapter 0 (toolchain, startup, linker script). This chapter explains **what the hardware does** underneath all of it: registers, modes, stacks, memory, exceptions, faults, SysTick, FPU, caches, and the instruction set.

Reference documents (keep them open):

- **Arm Cortex-M7 Devices Generic User Guide** (instruction set, core peripherals)
- **ST PM0253**: STM32F7 programming manual (core as implemented by ST)
- **ST RM0385**: STM32F75xxx / F74xxx reference manual (peripherals, memory map)
- **Arm Architecture Reference Manual, ARMv7-M** (exact semantics)

---

## 1. The big picture

Cortex-M is a family of 32-bit Arm cores for microcontrollers. All run **Thumb/Thumb-2** only (no classic ARM state), are **little-endian**, and share one programming model, so knowledge transfers between M0, M3, M4, M7 and later.

| Core | Architecture | Notes |
|---|---|---|
| M0 / M0+ | ARMv6-M | Smallest, no hardware divide, fewer instructions |
| M3 | ARMv7-M | Thumb-2, bit-banding |
| M4 | ARMv7E-M | + DSP instructions, optional single-precision FPU |
| **M7** | **ARMv7E-M** | **6-stage dual-issue pipeline, caches, TCM, optional FPU (SP or DP), AXI bus** |
| M33 | ARMv8-M | TrustZone, stack overflow detection |

The M7 in your F746 adds to the M4: L1 instruction and data caches, tightly coupled memories (ITCM, DTCM), an AXI master interface, branch prediction, and a faster FPU. No bit-banding on the M7.

```
              ┌────────────────────── Cortex-M7 core ───────────────────────┐
              │  Registers  ALU  FPU  Thumb-2 decoder  NVIC  SysTick  MPU   │
              │  I-cache   D-cache   Debug (FPB, DWT, ITM)                  │
              └──┬──────────┬───────────┬───────────┬────────────┬──────────┘
               ITCM        DTCM        AXIM         AHBP         AHBS
             (code RAM)  (data RAM)  (Flash, SRAM,  (peripherals) (DMA access
                                      ext. memory)                 to TCM)
```

Read your chip's ID from the CPU:

```
(gdb) x/wx 0xE000ED00        # CPUID
0x410FC271                   # example: implementer 0x41 (Arm), arch 0xF, part 0xC27 (Cortex-M7), rev r0p1
```

Your OpenOCD log said `Cortex-M7 r0p1 processor detected`, which matches. It also warned `Silicon bug: single stepping may enter pending exception handler!`. That is a known erratum of that revision: when single-stepping with an interrupt pending, the debugger may step into the handler.

---

## 2. Programmer's model

### 2.1 Core registers

| Register | Role |
|---|---|
| R0 to R7 | Low registers, usable by every instruction |
| R8 to R12 | High registers, some 16-bit instructions cannot use them |
| R13 (SP) | Stack pointer. **Two banked copies**: MSP and PSP |
| R14 (LR) | Link register: return address, or `EXC_RETURN` inside exceptions |
| R15 (PC) | Program counter |
| xPSR | Program status register (see below) |
| PRIMASK | 1 = mask all configurable-priority exceptions |
| FAULTMASK | 1 = mask everything except NMI |
| BASEPRI | Mask exceptions with priority number >= BASEPRI (0 = disabled) |
| CONTROL | Mode and stack selection |
| S0 to S31 / FPSCR | Floating-point registers and status (if FPU) |

### 2.2 xPSR

```
 31 30 29 28 27 26:25  24  23:20  19:16  15:10   9    8:0
 N  Z  C  V  Q  ICI/IT  T          GE    ICI/IT  (A)  IPSR (exception number)
```

| Field | Meaning |
|---|---|
| N Z C V | Condition flags (negative, zero, carry, overflow) |
| Q | Sticky saturation flag (DSP) |
| ICI/IT | Interruptible-continuable state, or If-Then state |
| **T (bit 24)** | **Thumb state. Must be 1.** Clear it and you get a UsageFault (INVSTATE) |
| IPSR | Active exception number: 0 = Thread mode, 3 = HardFault, 15 = SysTick, 16+ = IRQs |

Reading the values you saw:

- After `monitor reset halt`: `xPSR: 0x01000000`. Only bit 24 (T) set, IPSR = 0 (Thread mode).
- When it was stuck in the fault: `xPSR: 0x01000003`. IPSR = 3, so the core was **inside HardFault**. OpenOCD printed `current mode: Handler HardFault`.
- Stacked xPSR `0x21000000`: T set plus the carry flag.

### 2.3 Operating modes and privilege

| Mode | Entered when | Privilege | Stack |
|---|---|---|---|
| **Thread** | After reset, and after returning from exceptions | Privileged or unprivileged (set by CONTROL) | MSP or PSP (CONTROL.SPSEL) |
| **Handler** | While running an exception handler | **Always privileged** | **Always MSP** |

Typical bare-metal firmware only uses Thread mode, privileged, on MSP. An RTOS runs tasks in Thread mode on PSP (possibly unprivileged), and the kernel and ISRs in Handler mode on MSP.

### 2.4 CONTROL register

| Bit | Name | 0 | 1 |
|---|---|---|---|
| 0 | nPRIV | Privileged | Unprivileged (Thread only) |
| 1 | SPSEL | Thread uses MSP | Thread uses PSP |
| 2 | FPCA | No active FP context | FP context active (set automatically on first FPU instruction) |

Changing CONTROL needs an `ISB` afterwards:

```c
__set_CONTROL(__get_CONTROL() | 2u);   /* switch Thread to PSP */
__ISB();
```

An unprivileged thread cannot write CONTROL back to privileged. The only way back is an exception (SVC).

### 2.5 Stacks

- **Full descending**: SP points to the last used word; PUSH decrements then stores.
- After reset SP = MSP, loaded from vector table entry 0 (`_estack`).
- Two stacks isolate the OS (MSP) from tasks (PSP), so a task overflow does not corrupt the kernel.
- The stack must be **8-byte aligned** at public function boundaries (AAPCS). Hardware realigns it on exception entry (see 5.4).

Inspect in gdb (OpenOCD exposes them):

```
(gdb) info registers
(gdb) p/x $msp
(gdb) p/x $psp
(gdb) p/x $primask
(gdb) p/x $control
```

---

## 3. Memory model

### 3.1 Architectural memory map

| Range | Region | Typical use |
|---|---|---|
| `0x00000000` to `0x1FFFFFFF` | Code | Flash/boot alias, ITCM |
| `0x20000000` to `0x3FFFFFFF` | SRAM | Data (DTCM, SRAM1, SRAM2 on the F746) |
| `0x40000000` to `0x5FFFFFFF` | Peripheral | Device registers (AHB/APB) |
| `0x60000000` to `0x9FFFFFFF` | External RAM | FMC/SDRAM |
| `0xA0000000` to `0xDFFFFFFF` | External device | FMC |
| `0xE0000000` to `0xE00FFFFF` | **Private peripheral bus** | Core peripherals |
| `0xE0100000` to `0xFFFFFFFF` | Vendor system | |

### 3.2 Private peripheral bus (core registers)

| Address | Block |
|---|---|
| `0xE0000000` | ITM (instrumentation trace) |
| `0xE0001000` | DWT (data watchpoint and trace, cycle counter) |
| `0xE0002000` | FPB (flash patch and breakpoint) |
| `0xE000E010` | SysTick |
| `0xE000E100` | NVIC |
| `0xE000ED00` | SCB (system control block) |
| `0xE000ED90` | MPU |
| `0xE000EF30` | FPU control (FPCCR, FPCAR, FPDSCR) |
| `0xE000EDF0` | Debug (DHCSR, DEMCR) |

Registers of the SCB you will use most:

| Address | Register |
|---|---|
| `0xE000ED00` | CPUID |
| `0xE000ED04` | ICSR (interrupt control and state, VECTACTIVE, PENDSV set) |
| `0xE000ED08` | VTOR (vector table offset) |
| `0xE000ED0C` | AIRCR (priority grouping, system reset) |
| `0xE000ED10` | SCR (sleep control) |
| `0xE000ED14` | CCR (configuration: DIV_0_TRP, UNALIGN_TRP, STKALIGN, caches) |
| `0xE000ED24` | SHCSR (enable MemManage/BusFault/UsageFault) |
| `0xE000ED28` | **CFSR** (configurable fault status) |
| `0xE000ED2C` | **HFSR** (HardFault status) |
| `0xE000ED30` | DFSR (debug fault status) |
| `0xE000ED34` | MMFAR (MemManage fault address) |
| `0xE000ED38` | **BFAR** (BusFault address) |
| `0xE000ED88` | **CPACR** (coprocessor access: FPU enable) |

CMSIS gives these as `SCB->CFSR`, `SCB->VTOR`, `NVIC->ISER[...]`, `SysTick->CTRL`, etc.

### 3.3 STM32F746 memory in practice

| Region | Address | Size | Notes |
|---|---|---|---|
| Flash via AXIM | `0x08000000` | 1 MB | Default code location, cached |
| Flash via ITCM | `0x00200000` | 1 MB | Accelerated by the ART accelerator |
| ITCM RAM | `0x00000000` | 16 KB | Zero wait-state code |
| DTCM RAM | `0x20000000` | 64 KB | Zero wait-state data. Great for stack and hot variables |
| SRAM1 | `0x20010000` | 240 KB | General |
| SRAM2 | `0x2004C000` | 16 KB | General |

Your initial stack pointer `0x20050000` is the top of the 320 KB RAM block (`0x20000000 + 320K`). Check the reference manual for which masters (DMA) can reach DTCM before putting DMA buffers there.

### 3.4 Bit-banding

Cortex-M3/M4 had bit-banding: an alias region that maps each bit of SRAM/peripherals to a word. **The Cortex-M7 does not have it.** On the STM32F7 use the atomic set/reset registers instead:

```c
GPIOB->BSRR = (1u << 7);          /* set PB7, atomic */
GPIOB->BSRR = (1u << (7 + 16));   /* reset PB7, atomic */
```

`GPIOB->ODR ^= (1u << 7)` is a read-modify-write, not atomic: an interrupt in the middle can lose an update.

### 3.5 Endianness, alignment

- Little-endian: the least significant byte is at the lowest address.
- Unaligned `LDR/STR/LDRH/STRH` are allowed (when `CCR.UNALIGN_TRP = 0`), but slower. `LDM/STM/LDRD/STRD/VLDM` **require** alignment, and unaligned access to Device memory faults.
- `__attribute__((packed))` structs may generate unaligned accesses. Be careful with pointers into packed members.

### 3.6 Memory types and `volatile`

Memory attributes: **Normal** (can be cached, reordered, merged), **Device** (no merging, ordered per device), **Strongly-ordered**. Peripheral registers are Device memory. The compiler does not know that, so mark register accesses `volatile` (CMSIS headers already do).

### 3.7 Barriers

| Instruction | CMSIS | Guarantees |
|---|---|---|
| `DMB` | `__DMB()` | Memory accesses before the barrier are observed before those after |
| `DSB` | `__DSB()` | All previous memory accesses (and cache/system operations) **complete** |
| `ISB` | `__ISB()` | Flush the pipeline; later instructions are re-fetched |

When you need them:

- After writing `SCB->CPACR` (enable FPU): `DSB; ISB` before any FPU instruction.
- After changing `SCB->VTOR`, MPU, or `CONTROL`: `DSB; ISB`.
- After enabling a peripheral clock: read the register back (`(void)RCC->AHB1ENR;`) so the write has happened before touching the peripheral.
- Before `WFI` if you must be sure a write took effect.
- Cache maintenance and DMA handoffs.

Write buffer effect: a store may complete **later** than the instruction that issued it, which produces **imprecise** bus faults (CFSR bit 10) that point at the wrong instruction. Use `DSB` after a suspicious store, or set `SCB->ACTLR |= SCnSCB_ACTLR_DISDEFWBUF_Msk` while debugging to make bus faults precise.

---

## 4. Reset and boot

1. Hardware reset. Core registers are in a known state. Mode = Thread, privileged, MSP.
2. The core reads the vector table at `VTOR` (reset value = boot address, `0x08000000` with default boot settings).
3. `MSP = *(uint32_t*)0x08000000`, `PC = *(uint32_t*)0x08000004` (bit 0 must be 1 = Thumb).
4. `Reset_Handler` runs (copy `.data`, zero `.bss`, `SystemInit`, libc init, `main`).

If bit 0 of the reset vector is 0, the first instruction faults with INVSTATE. That is why function addresses in the vector table end in an odd number (`0x080020bd` for a function at `0x080020bc`).

### Relocating the vector table

```c
SCB->VTOR = 0x08010000;     /* e.g. application after a bootloader */
__DSB();
```

The table must be aligned to a power of two at least as big as the table, and at least 128 bytes (the F7 has many IRQs, so typically 0x200 or more). With a bootloader, the application's linker script `ORIGIN` and `VTOR` must agree.

---

## 5. Exceptions and interrupts

### 5.1 Exception types

| Number | Name | Priority | Notes |
|---|---|---|---|
| 1 | Reset | -3 (fixed) | |
| 2 | NMI | -2 (fixed) | Cannot be masked |
| 3 | HardFault | -1 (fixed) | Catch-all fault |
| 4 | MemManage | configurable | MPU violations |
| 5 | BusFault | configurable | Bus errors |
| 6 | UsageFault | configurable | Undefined instruction, bad state, unaligned, divide by zero, no coprocessor |
| 11 | SVCall | configurable | `SVC #n` instruction |
| 12 | DebugMonitor | configurable | |
| 14 | PendSV | configurable | Software-pended, used for context switching |
| 15 | SysTick | configurable | System timer |
| 16 and up | IRQ0, IRQ1, ... | configurable | Device interrupts. The list is in your startup file (`WWDG_IRQHandler` is IRQ0) |

The exception number is the index in the vector table, and it is what IPSR holds.

### 5.2 Priorities

- **Lower number = higher urgency.**
- Reset, NMI, HardFault have fixed negative priorities. All others are configurable.
- The priority field is 8 bits but silicon implements only the top bits. **STM32 implements 4 bits** (16 levels), stored in the upper nibble (`__NVIC_PRIO_BITS = 4`). CMSIS handles the shift for you.
- **Priority grouping** (`AIRCR.PRIGROUP`) splits the implemented bits into *preemption priority* and *sub-priority*:

| PRIGROUP | Preempt bits | Sub bits | HAL name |
|---|---|---|---|
| 3 | 4 | 0 | `NVIC_PRIORITYGROUP_4` (HAL default; 16 preemption levels) |
| 4 | 3 | 1 | `NVIC_PRIORITYGROUP_3` |
| 5 | 2 | 2 | `NVIC_PRIORITYGROUP_2` |
| 6 | 1 | 3 | `NVIC_PRIORITYGROUP_1` |
| 7 | 0 | 4 | `NVIC_PRIORITYGROUP_0` |

An exception can **preempt** another only if its preemption priority is strictly higher (numerically lower). Sub-priority only orders pending exceptions of the same preemption level.

### 5.3 NVIC API (CMSIS)

```c
NVIC_SetPriorityGrouping(3);                   /* once, at startup */
NVIC_SetPriority(USART3_IRQn, 5);              /* preempt level 5 */
NVIC_EnableIRQ(USART3_IRQn);
NVIC_DisableIRQ(USART3_IRQn);
NVIC_SetPendingIRQ(USART3_IRQn);               /* trigger from software */
NVIC_ClearPendingIRQ(USART3_IRQn);
uint32_t p = NVIC_GetPriority(USART3_IRQn);
NVIC_SystemReset();
```

Registers behind it: `NVIC->ISER` (enable set), `ICER` (clear), `ISPR` (pend set), `ICPR` (pend clear), `IABR` (active), `IPR` (priorities). `SCB->SHPR[]` holds priorities of system handlers (SVC, PendSV, SysTick, faults).

### 5.4 What happens on exception entry

Fully in hardware, no code needed:

1. **Stacking**: the CPU pushes 8 words onto the **current stack** (MSP or PSP):

```
 higher address
   [SP+28]  xPSR
   [SP+24]  PC            ← return address (faulting instruction for faults)
   [SP+20]  LR
   [SP+16]  R12
   [SP+12]  R3
   [SP+ 8]  R2
   [SP+ 4]  R1
   [SP+ 0]  R0            ← SP after stacking
 lower address
```

2. If SP was not 8-byte aligned, a padding word is inserted and **bit 9 of the stacked xPSR** records it.
3. If an FPU context is active, it also stacks S0-S15 and FPSCR (extended frame, 26 words). With **lazy stacking** (default) space is reserved but copied only if the handler actually uses the FPU.
4. **Vector fetch**: reads the handler address from the table.
5. Updates: IPSR = exception number, LR = **EXC_RETURN**, mode = Handler, PC = handler.

Because caller-saved registers are stacked by hardware, **an ISR is a normal C function** following AAPCS. No special prologue or `__attribute__((interrupt))` is needed on Cortex-M.

Latency is about 12 cycles from event to first handler instruction (with zero wait-state memory).

### 5.5 EXC_RETURN values

In the handler, LR holds a special value. Returning (`bx lr`, `pop {pc}`) triggers unstacking.

| EXC_RETURN | Return to | Stack | Frame |
|---|---|---|---|
| `0xFFFFFFF1` | Handler mode | MSP | Basic |
| `0xFFFFFFF9` | Thread mode | MSP | Basic |
| `0xFFFFFFFD` | Thread mode | PSP | Basic |
| `0xFFFFFFE1` | Handler mode | MSP | Extended (FPU) |
| `0xFFFFFFE9` | Thread mode | MSP | Extended (FPU) |
| `0xFFFFFFED` | Thread mode | PSP | Extended (FPU) |

In your fault debugging session, `lr = 0xffffffe9` meant: the interrupted code was Thread mode on MSP, with an FPU context active (extended frame). Bit 2 tells which stack to read the frame from: `0` = MSP, `1` = PSP. Bit 4 = 0 means FPU frame. This is how the fault handler in section 6.5 finds the frame.

### 5.6 Tail-chaining, late arrival, pop preemption

- **Tail-chaining**: if another exception is pending when a handler finishes, the CPU skips unstacking and restacking and jumps directly to the next handler (about 6 cycles).
- **Late arrival**: a higher-priority exception arriving during the stacking phase of a lower one is serviced first, reusing the stacking.
- **Pop preemption**: an exception arriving during unstacking abandons it and restarts.

### 5.7 Masking interrupts

| Mechanism | CMSIS | Effect |
|---|---|---|
| PRIMASK | `__disable_irq()` / `__enable_irq()` | Blocks all configurable exceptions (faults still occur if enabled) |
| BASEPRI | `__set_BASEPRI(x)` | Blocks priorities with number >= x. Lets high-priority IRQs through. RTOSes use this |
| FAULTMASK | `__set_FAULTMASK(1)` | Blocks everything but NMI (also masks HardFault) |
| NVIC enable | `NVIC_DisableIRQ(n)` | One interrupt |
| Peripheral enable | device register | At the source |

Critical section that nests safely:

```c
static inline uint32_t irq_save(void)
{
    uint32_t primask = __get_PRIMASK();
    __disable_irq();
    return primask;
}
static inline void irq_restore(uint32_t primask)
{
    __set_PRIMASK(primask);            /* re-enable only if it was enabled before */
}

uint32_t s = irq_save();
shared_counter++;                       /* now safe against ISR */
irq_restore(s);
```

Atomicity facts:

- Aligned 8/16/32-bit loads and stores are atomic. 64-bit accesses (`uint64_t`, `double`) are **not**.
- `x++` is read-modify-write and **not** atomic against an ISR.
- Use `LDREX/STREX` (via C11 `<stdatomic.h>`) or a critical section.
- Short critical sections only: they add latency to every interrupt.

### 5.8 Writing correct ISRs

```c
volatile uint32_t g_ms;                 /* volatile: shared between ISR and main */

void SysTick_Handler(void)              /* name must match the vector table (weak alias in startup) */
{
    g_ms++;
}
```

Rules:

- The handler's name must match exactly (`SysTick_handler` with a lowercase `h` silently falls into `Default_Handler`).
- Keep ISRs short: set a flag, push to a queue, return.
- **Clear the peripheral's interrupt flag**, otherwise the ISR re-triggers forever. (Clearing the NVIC pending bit alone is not enough for level-triggered sources.)
- Variables shared with main code: `volatile`, and protect multi-step access.
- Avoid `printf`, `malloc`, and long loops in an ISR.
- If an ISR needs the FPU, the context is stacked on entry. Avoid float math in high-rate ISRs when you can.
- The debugger halting the core stops SysTick, so `HAL_Delay` loops hang at breakpoints.
- A blocking delay (like `HAL_Delay`) called from an ISR of equal or higher priority than SysTick will deadlock, because SysTick can never preempt it.

### 5.9 SVC and PendSV

- **SVC**: `svc #5` triggers SVCall synchronously. The handler recovers the number from the instruction before the stacked PC. Used for system calls from unprivileged code.
- **PendSV**: pended by software (`SCB->ICSR = SCB_ICSR_PENDSVSET_Msk`) with the **lowest priority**, so it runs only when no other interrupt is active. RTOSes do context switching in it (see section 12).

---

## 6. Faults

### 6.1 Types and escalation

| Fault | Typical cause |
|---|---|
| **MemManage** | MPU violation, execute from no-execute region |
| **BusFault** | Access to an address with no device, a peripheral with its clock off, bad pointer |
| **UsageFault** | Undefined instruction, invalid state (Thumb bit), invalid EXC_RETURN, no coprocessor (FPU disabled), unaligned, divide by zero |
| **HardFault** | Any fault whose specific handler is **disabled** or can't run, plus vector table read errors |

At reset only HardFault is enabled. MemManage, BusFault and UsageFault are **disabled**, so any of those faults **escalates to HardFault** (`HFSR.FORCED = 1`). Enable them for precise diagnosis:

```c
SCB->SHCSR |= SCB_SHCSR_MEMFAULTENA_Msk | SCB_SHCSR_BUSFAULTENA_Msk | SCB_SHCSR_USGFAULTENA_Msk;
SCB->CCR   |= SCB_CCR_DIV_0_TRP_Msk;        /* optional: trap divide by zero */
```

A fault **inside** the HardFault handler (or while a fault of the same or higher priority is running) puts the core in **lockup**: it stops executing until reset or debugger. The debugger shows it as halted with no obvious reason. FAULTMASK-related behavior and NMI aside, lockup is what you get from stack corruption that makes even the fault handler fail.

### 6.2 CFSR: fault status

`CFSR` (0xE000ED28) is three registers combined:

```
 31      16 15      8 7       0
 [  UFSR  ] [ BFSR  ] [ MMFSR ]
```

MMFSR (bits 7:0):

| Bit | Name | Meaning |
|---|---|---|
| 0 | IACCVIOL | Instruction access violation |
| 1 | DACCVIOL | Data access violation |
| 3 | MUNSTKERR | Fault on unstacking at exception return |
| 4 | MSTKERR | Fault on stacking at exception entry (**stack overflow** into a protected region) |
| 5 | MLSPERR | Fault during FP lazy state preservation |
| 7 | MMARVALID | `MMFAR` holds the faulting address |

BFSR (bits 15:8):

| Bit | Name | Meaning |
|---|---|---|
| 8 | IBUSERR | Bus error fetching an instruction (jumped to an invalid address) |
| 9 | **PRECISERR** | Precise data bus error. `BFAR` holds the address. Classic cause: accessing a peripheral whose clock is not enabled |
| 10 | IMPRECISERR | Imprecise (buffered write). PC is not exact |
| 11 | UNSTKERR | Bus error on unstacking |
| 12 | STKERR | Bus error on stacking (**bad stack pointer**) |
| 13 | LSPERR | Bus error during FP lazy stacking |
| 15 | BFARVALID | `BFAR` is valid |

UFSR (bits 31:16):

| Bit | Name | Meaning |
|---|---|---|
| 16 | **UNDEFINSTR** | Undefined instruction (wrong ISA/FPU flags, jumped into data) |
| 17 | INVSTATE | Tried to execute with T bit = 0 (bad branch to an even address) |
| 18 | INVPC | Invalid EXC_RETURN or xPSR on return |
| 19 | **NOCP** | FPU/coprocessor instruction while access is disabled |
| 24 | UNALIGNED | Unaligned access with trapping enabled (or LDM/LDRD) |
| 25 | DIVBYZERO | Integer divide by zero with `DIV_0_TRP` set |

`HFSR` (0xE000ED2C): bit 1 `VECTTBL` (bus error reading the vector table), bit 30 `FORCED` (escalated from a configurable fault, look at CFSR), bit 31 `DEBUGEVT`.

CFSR bits are write-1-to-clear: `SCB->CFSR = SCB->CFSR;` clears them.

### 6.3 Diagnosis procedure

1. Stop the core (the debugger or a breakpoint in `HardFault_Handler`).
2. Read `CFSR`, `HFSR`, and `BFAR`/`MMFAR` if valid.
3. Find which stack was in use (`LR` bit 2) and read the stacked frame: `[6]` = PC of the faulting instruction, `[5]` = stacked LR.
4. Map the PC to code:
   ```
   (gdb) info symbol 0x08001ba0
   (gdb) x/6i 0x08001b9c
   (gdb) info line *0x08001ba0         # needs -g
   $ arm-none-eabi-addr2line -e blink.elf -f 0x08001ba0
   ```
5. Match the CFSR bit to the cause (section 6.2).

### 6.4 Worked example: the `printf("%.2f")` crash

Observed data:

| Observation | Meaning |
|---|---|
| OpenOCD: `current mode: Handler HardFault`, `xPSR 0x01000003` | In HardFault (IPSR = 3) |
| `CFSR = 0x00010000` | Bit 16 = UNDEFINSTR |
| `CPACR = 0x00F00000` | FPU **is** enabled, so not NOCP |
| `x/8wx $sp` = `3e8 40020800 40012000 40012000 0 08001ba1 08001ba0 21000000` | R0..R3, R12, **LR=0x08001ba1, PC=0x08001ba0**, xPSR |
| `info symbol 0x08001ba0` | `main + 40` |
| `x/i 0x08001ba0` | `vcvt.f64.f32 d7, s0` |

Conclusion: a double-precision instruction on a core whose FPU is single-precision. Fix: compile with `-mfpu=fpv5-sp-d16` (the F746 as used here), so `double` operations are done by library code, and use `float` literals. (Confirm the FPU type of your exact part in its datasheet.) The wrong-FPU-flag fault looks like UNDEFINSTR; a disabled FPU looks like NOCP.

Why the dump order matters: `0x2004ff88` was SP after stacking, so the stacked frame begins right at SP. Reading the **stacked PC** gives the instruction that faulted, not the handler address you see in `pc`.

### 6.5 A fault handler that tells you what happened

```c
#include "stm32f7xx.h"
#include <stdint.h>
#include <stdio.h>

typedef struct {
    uint32_t r0, r1, r2, r3, r12, lr, pc, xpsr;
} stacked_regs_t;

void hard_fault_c(stacked_regs_t *f)
{
    volatile uint32_t cfsr  = SCB->CFSR;
    volatile uint32_t hfsr  = SCB->HFSR;
    volatile uint32_t mmfar = SCB->MMFAR;
    volatile uint32_t bfar  = SCB->BFAR;
    volatile uint32_t pc    = f->pc;          /* faulting instruction */
    volatile uint32_t lr    = f->lr;
    (void)cfsr; (void)hfsr; (void)mmfar; (void)bfar; (void)pc; (void)lr;

    __BKPT(0);                                /* stops the debugger here with everything readable */
    for (;;) { }
}

/* Naked: no prologue, so the stack still holds the exception frame.
   Select MSP or PSP using EXC_RETURN bit 2, then call the C function with the frame in r0. */
__attribute__((naked)) void HardFault_Handler(void)
{
    __asm volatile(
        "tst   lr, #4        \n"
        "ite   eq            \n"
        "mrseq r0, msp       \n"
        "mrsne r0, psp       \n"
        "b     hard_fault_c  \n"
    );
}
```

`__BKPT(0)` with no debugger attached causes a lockup, so for production firmware log and reset instead (`NVIC_SystemReset()`).

Stack overflow note: if the stack pointer is bad, stacking itself faults (STKERR/MSTKERR) and the handler may not even run. In that case look at SP in the debugger and compare with the `.map` file layout.

### 6.6 Typical causes by symptom

| Symptom | Likely cause |
|---|---|
| Stuck in `Default_Handler` (shown as `WWDG_IRQHandler`) | Exception with no handler. Read IPSR/VECTACTIVE to see which |
| UNDEFINSTR | Wrong `-mcpu/-mfpu`, jump to data, corrupted function pointer, wrong library variant |
| NOCP | FPU used before enabling CPACR |
| INVSTATE | Function pointer with bit 0 clear, or ARM-state code |
| PRECISERR with BFAR in the `0x40xxxxxx` range | Peripheral clock not enabled (RCC) |
| BFAR at `0x00000000` | NULL pointer dereference |
| IBUSERR | Jumped to an invalid address (corrupted return address) |
| IMPRECISERR | Buffered write to a bad address: PC is not accurate |
| Fault only with optimization or only without it | Missing `volatile`, uninitialized variable, undefined behavior |
| Random crashes with `printf` of floats | Stack too small (`_Min_Stack_Size`) |

---

## 7. SysTick and timing

SysTick is a 24-bit down-counter built into the core. It is the standard source for a 1 ms tick.

| Register | Address | Purpose |
|---|---|---|
| `CTRL` | `0xE000E010` | ENABLE (bit 0), TICKINT (bit 1), CLKSOURCE (bit 2: 1 = core clock), COUNTFLAG (bit 16) |
| `LOAD` | `0xE000E014` | Reload value (24 bit) |
| `VAL` | `0xE000E018` | Current value; writing clears it |
| `CALIB` | `0xE000E01C` | Calibration info |

```c
volatile uint32_t g_ms;

void SysTick_Handler(void) { g_ms++; }

void systick_init(void)
{
    /* LOAD = ticks per ms - 1; also sets lowest priority and enables the interrupt */
    if (SysTick_Config(SystemCoreClock / 1000u)) {
        for (;;) { }                            /* reload value too large for 24 bits */
    }
}

uint32_t millis(void) { return g_ms; }
```

Overflow-safe timeout test (works across the 32-bit wrap):

```c
if ((uint32_t)(millis() - last) >= interval_ms) { last += interval_ms; ... }
```

Maximum period at 16 MHz: 2^24 / 16e6 about 1.05 s. At 216 MHz: about 77 ms. For longer periods, count ticks in the ISR.

If you change the system clock (PLL), reconfigure SysTick: `SystemCoreClock` must be updated (`SystemCoreClockUpdate()`), then call `SysTick_Config` again.

### Cycle counter (DWT)

Exact timing of code, in CPU cycles:

```c
static void cyccnt_init(void)
{
    CoreDebug->DEMCR |= CoreDebug_DEMCR_TRCENA_Msk;   /* enable trace/debug blocks */
    DWT->LAR = 0xC5ACCE55;                            /* unlock (needed on Cortex-M7) */
    DWT->CYCCNT = 0;
    DWT->CTRL |= DWT_CTRL_CYCCNTENA_Msk;
}

uint32_t t0 = DWT->CYCCNT;
work();
uint32_t cycles = DWT->CYCCNT - t0;
```

It wraps every 2^32 cycles (about 19 s at 216 MHz).

---

## 8. The FPU

- Enabled with `CPACR`: CP10 and CP11 full access (`3UL << 20 | 3UL << 22`), then `DSB; ISB`. Done in `SystemInit`. Disabled at reset, so any FPU instruction before that raises NOCP.
- Registers: S0 to S31 (also viewable as D0 to D15 if the FPU is double precision), plus FPSCR (flags, rounding, flush-to-zero, default NaN).
- `FPCCR` (`0xE000EF34`): `ASPEN` (automatic state preservation) and `LSPEN` (lazy stacking), both on by default.
- `CONTROL.FPCA` is set when the code has used the FPU, which makes exceptions stack the FP context.

Choosing flags:

| FPU type | `-mfpu` |
|---|---|
| Single precision (SP), e.g. F746 as used in this project | `fpv5-sp-d16` |
| Double precision (DP), e.g. F76x/F77x, H7 | `fpv5-d16` |

Check your part's datasheet and reference manual.

Practical rules:

- With `-mfloat-abi=hard`, float arguments and returns use FPU registers. Mixed ABIs in one image cause link errors (`uses VFP register arguments`).
- On an SP-only FPU, `double` math is software (slow). Use `float` and `3.3f` literals. `-fsingle-precision-constant` and `-Wdouble-promotion` help find accidents.
- `printf("%f", float_value)` promotes to `double`. That is fine (conversion is library code on SP-only chips), but needs `-Wl,-u,_printf_float` with newlib-nano.
- FPU use in ISRs adds stacking cost (lazy stacking mitigates it).
- RTOS tasks that use the FPU need extra stack for S16-S31 and the extended frame.

---

## 9. MPU and caches

### 9.1 MPU

The Memory Protection Unit (up to 8 regions on the F7, 8 on most Cortex-M7 parts) defines per-region address, size, access permissions, execute-never, and **cache attributes**.

Common uses:

- Trap NULL-pointer access: make `0x00000000` no-access (but the ITCM/vector alias lives there on some configs, check).
- Stack guard: a small no-access region below each task's stack, which converts silent overflow into a MemManage fault.
- Mark RAM as execute-never to block code injection.
- **Make DMA buffers non-cacheable** (see below).

Enable steps: configure regions, then `MPU->CTRL = MPU_CTRL_ENABLE_Msk | MPU_CTRL_PRIVDEFENA_Msk; __DSB(); __ISB();`. `PRIVDEFENA` keeps the default memory map for privileged code outside regions.

Enable `MemManage` (SHCSR) so violations are reported as MemManage, not HardFault.

### 9.2 Caches (M7)

```c
SCB_EnableICache();      /* instruction cache: safe and nearly always beneficial */
SCB_EnableDCache();      /* data cache: needs care with DMA */
```

Cache line size is 32 bytes. Check the cache sizes in your part's datasheet.

**The DMA coherency problem** (very common bug on F7/H7): with the D-cache on, the CPU can read stale cached data that DMA already replaced in RAM, or DMA can read stale RAM that the CPU left in the cache.

| Direction | Do |
|---|---|
| CPU writes, DMA reads (TX) | `SCB_CleanDCache_by_Addr(buf, len)` before starting DMA |
| DMA writes, CPU reads (RX) | `SCB_InvalidateDCache_by_Addr(buf, len)` after DMA completes |

Buffers must be **32-byte aligned and a multiple of 32 bytes**, or cache maintenance corrupts neighbors:

```c
__attribute__((aligned(32))) uint8_t rx_buf[256];
```

Simpler alternatives: put DMA buffers in a region marked **non-cacheable** with the MPU, or leave the D-cache off while learning.

Other effects: timing becomes less predictable (cache misses), and flash wait states hide behind the ART accelerator and the I-cache.

---

## 10. Sleep modes

| Instruction | CMSIS | Behavior |
|---|---|---|
| `WFI` | `__WFI()` | Sleep until an interrupt (or debug event) |
| `WFE` | `__WFE()` | Sleep until an event (SEV, or interrupt if `SEVONPEND`) |
| `SEV` | `__SEV()` | Send event |

`SCB->SCR` bits: `SLEEPONEXIT` (sleep after finishing an ISR, interrupt-driven designs), `SLEEPDEEP` (deeper sleep, combined with PWR settings in the STM32 for Stop/Standby), `SEVONPEND`.

Pattern:

```c
while (1) {
    if (!work_pending) { __WFI(); }
    handle_events();
}
```

Race to avoid: an interrupt may set `work_pending` between the check and `WFI`. With `WFI` an already-pending interrupt wakes immediately, but check carefully that the flag is set from an ISR **after** WFI is armed. With PRIMASK set, WFI still wakes on a pending interrupt without running its handler, which is a classic way to make this race-free.

Debug and sleep: the debugger loses connection in deep sleep unless `DBGMCU->CR` (`DBG_SLEEP`, `DBG_STOP`, `DBG_STANDBY`) is configured.

---

## 11. On-chip debug and trace

| Block | Function |
|---|---|
| **FPB** | Hardware breakpoints. OpenOCD reported `target has 8 breakpoints` |
| **DWT** | Data watchpoints (OpenOCD: `4 watchpoints`), cycle counter, event counters |
| **ITM** | Software trace: `ITM_SendChar()` outputs through **SWO** without halting the CPU |
| **DHCSR / DEMCR** | Halt, step, vector catch (stop on reset or on a fault) |
| **SWD** | The 2-wire debug interface that ST-LINK uses |

- 8 hardware breakpoints means flash breakpoints are limited. GDB falls back to hardware breakpoints automatically (OpenOCD said `automatically using hardware breakpoints for read-only addresses`).
- Watchpoint in gdb: `watch g_ms`, `rwatch var`, `awatch var`.
- Vector catch (`DEMCR.VC_HARDERR`, etc.) makes the debugger stop exactly at the fault.
- **Semihosting** (`--specs=rdimon.specs`) sends I/O through the debugger using `BKPT 0xAB`. Without a debugger attached it faults. Do not leave it in a firmware that runs alone.
- `printf` via UART is the most reliable approach for bring-up. ITM/SWO gives lower overhead.

---

## 12. Thumb-2 and calling convention

### 12.1 Instruction set essentials

Thumb-2 mixes 16-bit and 32-bit instructions, so code is compact without losing power. The `.w` suffix marks a 32-bit encoding (`ldr.w`).

| Group | Examples |
|---|---|
| Move | `mov r0, #5`, `movw/movt` (load 32-bit constant), `mvn` |
| Arithmetic | `add`, `adds`, `sub`, `mul`, `mla`, `sdiv`, `udiv`, `rsb` |
| Logic and shift | `and`, `orr`, `eor`, `bic`, `lsl`, `lsr`, `asr`, `ror` |
| Bit fields | `ubfx`, `sbfx`, `bfi`, `bfc`, `clz`, `rbit`, `rev` |
| Compare/branch | `cmp`, `tst`, `b`, `bl`, `bx`, `blx`, `cbz`, `cbnz`, conditional `beq/bne/blt/...` |
| Load/store | `ldr`, `ldrb`, `ldrh`, `ldrd`, `str`, `ldm`, `stm`, `push`, `pop`, `ldrex/strex` |
| Conditional blocks | `it`, `ite`, `itt` (up to 4 conditionally executed instructions) |
| System | `mrs`, `msr`, `cpsid i`, `cpsie i`, `svc`, `bkpt`, `wfi`, `wfe`, `sev`, `nop` |
| Barriers | `dmb`, `dsb`, `isb` |
| DSP (ARMv7E-M) | `ssat`, `usat`, `smlad`, `smull`, `uadd8`, ... |
| FPU | `vldr`, `vstr`, `vadd.f32`, `vmul.f32`, `vcvt`, `vmov`, `vsqrt.f32`, `vmrs`, `vmsr` |

Flags are only updated by the `s`-suffixed forms (`adds`) or by compare instructions (in unified syntax, 16-bit encodings often set flags implicitly).

Branching: `bx lr` returns; the target's bit 0 selects the state, which must be 1 (Thumb). Compilers/linkers handle it for function pointers. Hand-written code that loads a function address into a register must keep the odd address.

### 12.2 AAPCS: the calling convention

| Register | Role | Preserved by callee? |
|---|---|---|
| R0 to R3 | Arguments and return value (R0, or R0:R1 for 64-bit) | No (caller-saved) |
| R12 (IP) | Scratch | No |
| R4 to R11 | Locals | **Yes** (callee-saved) |
| R13 (SP) | Stack pointer, **8-byte aligned** at calls | Yes |
| R14 (LR) | Return address | Saved if the function calls others |
| S0 to S15 | FP arguments/return (hard-float) | No |
| S16 to S31 | FP locals (hard-float) | **Yes** |

Rules:

- A `uint64_t`/`double` argument uses an **even-numbered register pair** (R0:R1 or R2:R3).
- Return values wider than 32 bits (up to 64) come back in R0:R1; larger structs via a hidden pointer in R0.
- **Variadic functions** (`printf`) use the base ABI: floats are promoted to `double` and passed in core registers, **even with `-mfloat-abi=hard`**.

Reading the disassembly from your crash with that in mind:

```
bl      adc_read_vbat        ; returns a float in s0 (hard-float ABI)
vcvt.f64.f32 d7, s0          ; C promotes float to double for the variadic call
vmov    r2, r3, d7           ; double goes in the register pair r2:r3
ldr     r0, [pc, #48]        ; r0 = format string (r1 is skipped to keep the pair even-aligned)
bl      printf
```

Function prologue and epilogue:

```
push    {r4, r5, lr}         ; save callee-saved registers we use, and the return address
...
pop     {r4, r5, pc}         ; restore and return in one instruction (pc <- saved lr)
```

### 12.3 Inline assembly with GCC

```c
uint32_t sp;
__asm volatile ("mov %0, sp" : "=r"(sp));            /* output operand */
__asm volatile ("cpsid i" ::: "memory");             /* "memory" clobber: acts as a compiler barrier */
__asm volatile ("dsb 0xF" ::: "memory");
```

Prefer the CMSIS wrappers (`__disable_irq()`, `__get_MSP()`, `__WFI()`, `__DSB()`, `__NOP()`, `__BKPT()`), which already carry the right constraints.

`__attribute__((naked))` removes prologue and epilogue: only use it with a body of pure assembly (as in the fault handler above).

### 12.4 Reading generated code

```bash
arm-none-eabi-gcc -mcpu=cortex-m7 -mthumb -mfpu=fpv5-sp-d16 -mfloat-abi=hard -Os -S -fverbose-asm test.c
arm-none-eabi-objdump -d -S build/blink.elf | less
```

Good habit: write a tiny function, compile at `-O0` and `-Os`, and read the result. Online, the Compiler Explorer (godbolt.org) with `ARM GCC (none-eabi)` is great for this.

---

## 13. Context switching (how an RTOS works)

Ingredients:

- Each task has its own **stack** and a saved stack pointer in its task control block (TCB).
- Tasks run in Thread mode on **PSP**; the kernel and ISRs use **MSP**.
- **SysTick** fires every tick and requests a switch by pending **PendSV** (lowest priority).
- **PendSV** performs the switch.

The hardware already stacked R0-R3, R12, LR, PC, xPSR on the old task's PSP when the exception was taken. The handler only has to save and restore **R4-R11** (and S16-S31 if the task used the FPU), then change PSP:

```
PendSV_Handler:                       @ simplified, no FPU
    mrs     r0, psp                   @ old task's stack pointer
    isb
    stmdb   r0!, {r4-r11}             @ push callee-saved regs onto the old task's stack
    ldr     r1, =current_task         @ r1 = &current_task (TCB pointer; first TCB field = saved sp)
    ldr     r2, [r1]
    str     r0, [r2]                  @ save new SP in the old TCB

    push    {r3, lr}                  @ keep EXC_RETURN (and 8-byte alignment) across the call
    bl      scheduler_pick_next       @ C function: updates current_task
    pop     {r3, lr}

    ldr     r1, =current_task
    ldr     r2, [r1]
    ldr     r0, [r2]                  @ new task's saved sp
    ldmia   r0!, {r4-r11}             @ restore its callee-saved regs
    msr     psp, r0
    isb
    bx      lr                        @ LR = 0xFFFFFFFD: return to Thread mode, on PSP
```

Starting a task for the first time: build a **fake exception frame** on its stack (xPSR = `0x01000000`, PC = entry function, LR = function to call if the task returns, R0 = argument), plus eight dummy words for R4-R11, and set the TCB's saved SP to the bottom of it. The first "return from exception" then starts the task.

Real RTOSes (FreeRTOS, Zephyr) also handle FPU context, `BASEPRI`-based critical sections so that high-priority ISRs stay responsive, and priority inversion. Use this section to understand them, not to replace them.

---

## 14. CMSIS quick reference

Headers: `core_cm7.h` (core, via `stm32f7xx.h`), device header `stm32f746xx.h`.

| Area | Functions/macros |
|---|---|
| Interrupts | `__enable_irq`, `__disable_irq`, `NVIC_EnableIRQ`, `NVIC_DisableIRQ`, `NVIC_SetPriority`, `NVIC_GetPriority`, `NVIC_SetPendingIRQ`, `NVIC_ClearPendingIRQ`, `NVIC_SystemReset`, `NVIC_SetPriorityGrouping` |
| Registers | `__get_PRIMASK/__set_PRIMASK`, `__get_BASEPRI/__set_BASEPRI`, `__get_CONTROL/__set_CONTROL`, `__get_MSP/__set_MSP`, `__get_PSP/__set_PSP`, `__get_FPSCR/__set_FPSCR` |
| Barriers/hints | `__DMB`, `__DSB`, `__ISB`, `__NOP`, `__WFI`, `__WFE`, `__SEV`, `__BKPT` |
| Bit ops | `__CLZ`, `__RBIT`, `__REV`, `__REV16`, `__USAT`, `__SSAT` |
| Cache | `SCB_EnableICache/DCache`, `SCB_Disable...`, `SCB_CleanDCache`, `SCB_InvalidateDCache`, `SCB_CleanInvalidateDCache`, `..._by_Addr` |
| SysTick | `SysTick_Config(ticks)` |
| ITM | `ITM_SendChar(c)` |
| Globals | `SystemCoreClock`, `SystemInit()`, `SystemCoreClockUpdate()` |
| Access macros | `SCB->`, `NVIC->`, `SysTick->`, `DWT->`, `CoreDebug->`, `MPU->`, `FPU->` |

---

## 15. GDB and OpenOCD cheat sheet for Cortex-M

```
(gdb) target extended-remote :3333
(gdb) monitor reset halt             # reset and stop at the first instruction
(gdb) monitor reset init
(gdb) load                           # program the ELF
(gdb) tbreak main
(gdb) continue
(gdb) info registers                 # r0-r12, sp, lr, pc, xpsr (+ special regs via OpenOCD)
(gdb) p/x $xpsr
(gdb) p/x $msp
(gdb) x/8wx $sp                      # raw stack words
(gdb) x/wx 0xE000ED28                # CFSR
(gdb) monitor mdw 0xE000ED28         # same, via OpenOCD memory display word
(gdb) x/6i $pc                       # next instructions
(gdb) info symbol 0x08001ba0
(gdb) info line *0x08001ba0
(gdb) bt                             # unreliable right after a fault: use the stacked frame instead
(gdb) watch g_ms
(gdb) display/x $pc
(gdb) set var g_ms = 0
(gdb) stepi                          # one instruction
(gdb) monitor halt / monitor resume
```

OpenOCD notes:

- `LIBUSB_ERROR_ACCESS` means missing udev rules. Reinstall them and replug.
- Only one tool at a time can talk to the ST-LINK (`st-flash`, OpenOCD, `st-util`).
- OpenOCD adjusting the speed (`Unable to match requested speed 2000 kHz, using 1800 kHz`) is normal.

---

## 16. Lab exercises

1. **Read your CPU**: print CPUID and decode implementer, part and revision. Match it with the OpenOCD message.
2. **Registers**: halt in `main` and print `$msp`, `$psp`, `$control`, `$xpsr`, `$primask`. Explain each value.
3. **Mode switch**: set `CONTROL.SPSEL`, observe `$psp` becoming SP, and set it back.
4. **Vector table**: dump the first 16 words at `0x08000000` with `x/16wx`. Identify SP, Reset and the handler addresses, and confirm that they are odd.
5. **Break the Thumb bit**: store a function pointer with bit 0 cleared and call it. Read INVSTATE in UFSR.
6. **Default handler hunt**: define an interrupt you did not implement (e.g. enable `EXTI` without a handler). Find which one fired using `SCB->ICSR` (VECTACTIVE).
7. **SysTick**: write your own `millis()`; verify the period with the DWT cycle counter.
8. **Priorities**: use two timers (or SysTick plus a software-pended IRQ). Give them different preemption priorities and prove that preemption happens by toggling pins/LEDs and watching the order.
9. **Critical section**: increment a shared counter from an ISR and from main without protection, count lost updates, then fix with `irq_save/restore`.
10. **Faults, one at a time**: enable all fault handlers and trigger each: NULL read (BFAR), divide by zero, unaligned `LDM`, jump to RAM data (INVSTATE or UNDEFINSTR), access a peripheral with its clock disabled (PRECISERR). Record CFSR for each.
11. **Fault handler**: install the handler from 6.5 and print PC, LR and CFSR over UART, then `NVIC_SystemReset()`.
12. **FPU**: build once with the FPU enable commented out and read NOCP. Build with the wrong `-mfpu` for a DP instruction and read UNDEFINSTR.
13. **Stack overflow**: recurse with a large local array; observe how the failure changes depending on what lies below the stack. Add an MPU guard region and see MemManage.
14. **Cache and DMA**: enable the D-cache, DMA into a buffer, show the stale-read problem, then fix it with clean/invalidate.
15. **Write a tiny scheduler**: two tasks on PSP, switched in PendSV by SysTick, each toggling an LED. Follow section 13.
16. **Sleep**: put the main loop in `WFI`, wake from SysTick, and compare current consumption if you can measure it.

---

## 17. Cheat sheet

### Core facts

- Thumb-2 only, little-endian, 32-bit, full descending stack, two stacks (MSP/PSP), two modes (Thread/Handler).
- Reset: SP = `[VTOR+0]`, PC = `[VTOR+4]`, T bit must be 1.
- Exception entry stacks `R0-R3, R12, LR, PC, xPSR`; handlers are plain C functions.
- `LR` in a handler is `EXC_RETURN`; bit 2 = which stack, bit 4 = FPU frame.
- Lower priority number = more urgent. STM32 has 4 priority bits.
- At reset, MemManage/BusFault/UsageFault are disabled, so they escalate to HardFault.

### Registers to remember

| Address | Name | Use |
|---|---|---|
| `0xE000ED28` | CFSR | What fault |
| `0xE000ED2C` | HFSR | Escalated? |
| `0xE000ED34` | MMFAR | MemManage address |
| `0xE000ED38` | BFAR | Bus fault address |
| `0xE000ED88` | CPACR | FPU on (`0x00F00000`) |
| `0xE000ED04` | ICSR | Active exception |
| `0xE000ED08` | VTOR | Vector table |
| `0xE000E010` | SysTick CTRL | Tick control |

### Fault quick table

| CFSR | Meaning |
|---|---|
| `0x00010000` | UNDEFINSTR |
| `0x00020000` | INVSTATE |
| `0x00080000` | NOCP (FPU off) |
| `0x00000200` | PRECISERR (check BFAR) |
| `0x00000400` | IMPRECISERR |
| `0x01000000` | DIVBYZERO |
| `0x00000002` | DACCVIOL (MPU) |

### Typical startup safety checklist

1. `SystemInit`: enable FPU (`CPACR`, `DSB`, `ISB`), set `VTOR` if relocated.
2. Enable fault handlers (`SHCSR`) and optionally `DIV_0_TRP`.
3. Configure priority grouping and set priorities before enabling IRQs.
4. Enable caches (`ICache`, then `DCache` only if you handle DMA coherency).
5. Initialize SysTick.
6. Install a `HardFault_Handler` that records the stacked frame.

---

## 18. Where this leads

- **C for embedded** (next): `volatile`, register access, structs and bitfields, atomicity, and how C maps to what you saw here.
- **Debugging chapter**: build on sections 6 and 15 with OpenOCD, GDB scripts, SWO and fault post-mortems.
- **Peripherals**: clock tree and PLL, GPIO, UART, timers, DMA, all driven by NVIC and the memory rules of this chapter.
- **RTOS**: section 13 is the starting point for FreeRTOS or Zephyr.

## References

- Arm: *Cortex-M7 Devices Generic User Guide*, *ARMv7-M Architecture Reference Manual*, *Cortex-M7 Technical Reference Manual*
- ST: PM0253 (F7 programming manual), RM0385 (reference manual), AN4839 (L1 cache on STM32F7), AN4838 (MPU programming)
- Joseph Yiu, *The Definitive Guide to ARM Cortex-M3 and Cortex-M4 Processors* (concepts carry over to the M7)
- CMSIS-Core documentation (function reference)