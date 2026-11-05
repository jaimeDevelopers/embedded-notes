# 12. FreeRTOS in Depth (Cortex-M7, STM32F746ZG)

Prerequisites: chapter 3 (exceptions, NVIC, BASEPRI), chapter 8 (RTOS design rules), chapter 9 (Zephyr, a second viewpoint on the same ideas).

**Verification note.** FreeRTOS APIs and configuration macros evolve between releases (10.x to 11.x). Names below match the long-standing API; **check the kernel version you vendor** and its documentation (<https://www.freertos.org/Documentation/>). The code is illustrative and **has not been compiled or run on your board**.

---

## 1. What FreeRTOS is

A small, widely used **real-time kernel** (MIT license, now stewarded by AWS): a preemptive priority-based scheduler, tasks, queues, semaphores, mutexes, timers, event groups, stream/message buffers, task notifications. It is **only a kernel**: no drivers, no devicetree, no networking (those are add-ons: FreeRTOS+TCP, lwIP, vendor HALs).

| Aspect | FreeRTOS | Zephyr (chapter 9) |
|---|---|---|
| Scope | Kernel + optional libraries | Whole platform |
| Hardware description | Your code / vendor HAL | Devicetree |
| Configuration | `FreeRTOSConfig.h` | Kconfig |
| Priorities | **Higher number = higher priority** | Lower number = higher priority |
| Footprint | A few KB | Larger baseline |
| Ecosystem | Huge (every vendor supports it) | Growing, one project |
| Learning curve | Gentle | Steeper |

You keep control of everything else: the structure of chapter 8 (layers, HAL, drivers) applies unchanged, with an RTOS-based execution model.

---

## 2. Kernel concepts

### 2.1 Tasks and states

A **task** is a function with its own stack and priority (never returns, unless it deletes itself).

```
            ┌──────────── scheduler picks highest-priority ready task ────────────┐
   Ready ───┤                                                                      ├──► Running
            └─ preempted by higher priority / time slice ◄─────────────────────────┘
   Running ─ vTaskDelay / blocking call ─► Blocked ─ event/timeout ─► Ready
   Running/Ready ─ vTaskSuspend ─► Suspended ─ vTaskResume ─► Ready
```

- **Running**: executing on the CPU (one per core).
- **Ready**: can run, waiting for the CPU.
- **Blocked**: waiting for time or an event (queue, semaphore, notification); uses no CPU.
- **Suspended**: not scheduled until resumed.
- The **idle task** (lowest priority) runs when everything else is blocked; it also frees deleted tasks' memory and can sleep the CPU (`WFI` or tickless idle).

### 2.2 Scheduling

- **Fixed-priority preemptive**: the highest-priority ready task always runs; a task that becomes ready with higher priority preempts immediately.
- **Time slicing** among tasks of **equal priority** (round robin on each tick) if `configUSE_TIME_SLICING = 1`.
- Task priorities range `0` (idle) to `configMAX_PRIORITIES - 1`. Keep the number of levels small (4-8).
- The tick (`configTICK_RATE_HZ`, typically 1000) drives delays and time slicing. It uses SysTick on Cortex-M.

### 2.3 What the port uses on the Cortex-M

| Mechanism | Purpose |
|---|---|
| **SysTick** | Tick interrupt |
| **PendSV** | Context switch (lowest priority) |
| **SVC** | Starts the first task |
| **BASEPRI** | Critical sections that still let high-priority interrupts run |
| MSP for ISRs and the scheduler start, **PSP for tasks** | Stack separation (chapter 3) |

For the Cortex-M7 use the **`GCC/ARM_CM7/r0p1`** port of the FreeRTOS-Kernel source tree (it works for r0p1 and later revisions; your core reported r0p1). Check the port documentation for erratum notes on your revision.

### 2.4 Interrupt priorities (the most error-prone part)

Cortex-M has 4 priority bits on STM32 (`configPRIO_BITS = 4`), lower number = more urgent. FreeRTOS defines two levels:

```
 0 (most urgent) ... configMAX_SYSCALL_INTERRUPT_PRIORITY ... configKERNEL_INTERRUPT_PRIORITY (15, least urgent)
 |--- never touch the kernel ---|--- may call ...FromISR() functions ---|
```

- Interrupts with priority **numerically below** `configMAX_SYSCALL_INTERRUPT_PRIORITY` (more urgent) are **never delayed by the kernel** but **must not call any FreeRTOS API**.
- Interrupts at or above it (numerically `>=`, less urgent) may call `...FromISR()` APIs.
- SysTick and PendSV run at the **lowest** priority (`configKERNEL_INTERRUPT_PRIORITY`).
- **All priority bits must be preemption bits** (no sub-priorities): `NVIC_SetPriorityGrouping(3)` on STM32 (HAL name `NVIC_PRIORITYGROUP_4`) before starting the scheduler.
- Define macros with the shifted values (priority in the **top bits** of the 8-bit field):

```c
#define configPRIO_BITS                         4
#define configLIBRARY_LOWEST_INTERRUPT_PRIORITY 15
#define configLIBRARY_MAX_SYSCALL_INTERRUPT_PRIORITY 5      /* ISRs with priority 5..15 may use the API */
#define configKERNEL_INTERRUPT_PRIORITY         (configLIBRARY_LOWEST_INTERRUPT_PRIORITY << (8 - configPRIO_BITS))
#define configMAX_SYSCALL_INTERRUPT_PRIORITY    (configLIBRARY_MAX_SYSCALL_INTERRUPT_PRIORITY << (8 - configPRIO_BITS))
```

Rule of thumb: an ISR that uses the kernel gets a priority number in `[5, 14]`; hard-real-time ISRs that must never be delayed use `[0, 4]` and communicate with the kernel through shared memory, DMA or a lower-priority ISR. **`configASSERT` catches a wrong priority** when you call `...FromISR()` from an ISR that is too urgent (the port checks `BASEPRI`/priority): always define `configASSERT`.

---

## 3. `FreeRTOSConfig.h` for the F746 (annotated)

```c
#ifndef FREERTOS_CONFIG_H
#define FREERTOS_CONFIG_H

#include <stdint.h>
extern uint32_t SystemCoreClock;

/* Scheduler */
#define configUSE_PREEMPTION                    1
#define configUSE_TIME_SLICING                  1
#define configUSE_PORT_OPTIMISED_TASK_SELECTION 1      /* uses CLZ, M7 supports it */
#define configCPU_CLOCK_HZ                      (SystemCoreClock)
#define configTICK_RATE_HZ                      ((TickType_t)1000)
#define configMAX_PRIORITIES                    7
#define configMINIMAL_STACK_SIZE                ((uint16_t)128)     /* in WORDS (4 bytes) */
#define configMAX_TASK_NAME_LEN                 16
#define configUSE_16_BIT_TICKS                  0

/* Memory */
#define configSUPPORT_DYNAMIC_ALLOCATION        1
#define configSUPPORT_STATIC_ALLOCATION         1
#define configTOTAL_HEAP_SIZE                   ((size_t)(48 * 1024))   /* used by heap_4.c */
#define configAPPLICATION_ALLOCATED_HEAP        0

/* Features */
#define configUSE_MUTEXES                       1
#define configUSE_RECURSIVE_MUTEXES             1
#define configUSE_COUNTING_SEMAPHORES           1
#define configUSE_TASK_NOTIFICATIONS            1
#define configUSE_TIMERS                        1
#define configTIMER_TASK_PRIORITY               (configMAX_PRIORITIES - 2)
#define configTIMER_QUEUE_LENGTH                10
#define configTIMER_TASK_STACK_DEPTH            (configMINIMAL_STACK_SIZE * 2)
#define configQUEUE_REGISTRY_SIZE               8

/* Safety and debugging */
#define configCHECK_FOR_STACK_OVERFLOW          2       /* method 2: pattern check, see hook */
#define configUSE_MALLOC_FAILED_HOOK            1
#define configUSE_IDLE_HOOK                     0
#define configUSE_TICK_HOOK                     0
#define configUSE_TRACE_FACILITY                1
#define configUSE_STATS_FORMATTING_FUNCTIONS    1
#define configGENERATE_RUN_TIME_STATS           0       /* needs a fast timer: see section 9 */
#define configASSERT(x)  do { if (!(x)) { taskDISABLE_INTERRUPTS(); for (;;) { } } } while (0)

/* Cortex-M interrupt priorities (see section 2.4) */
#define configPRIO_BITS                         4
#define configLIBRARY_LOWEST_INTERRUPT_PRIORITY 15
#define configLIBRARY_MAX_SYSCALL_INTERRUPT_PRIORITY 5
#define configKERNEL_INTERRUPT_PRIORITY         (configLIBRARY_LOWEST_INTERRUPT_PRIORITY << (8 - configPRIO_BITS))
#define configMAX_SYSCALL_INTERRUPT_PRIORITY    (configLIBRARY_MAX_SYSCALL_INTERRUPT_PRIORITY << (8 - configPRIO_BITS))

/* Map the port handlers onto the CMSIS vector names (the startup file expects these) */
#define vPortSVCHandler     SVC_Handler
#define xPortPendSVHandler  PendSV_Handler
#define xPortSysTickHandler SysTick_Handler

/* API inclusion */
#define INCLUDE_vTaskDelay                      1
#define INCLUDE_xTaskDelayUntil                 1
#define INCLUDE_vTaskDelete                     1
#define INCLUDE_vTaskSuspend                    1
#define INCLUDE_uxTaskGetStackHighWaterMark     1
#define INCLUDE_xTaskGetCurrentTaskHandle       1
#define INCLUDE_xTaskGetSchedulerState          1

#endif
```

Notes:

- **Stack sizes are in words** for `xTaskCreate` (`configMINIMAL_STACK_SIZE = 128` is 512 bytes).
- Selecting `configUSE_PORT_OPTIMISED_TASK_SELECTION` makes `configMAX_PRIORITIES` limited to 32.
- If you use the FPU (`-mfloat-abi=hard`), the Cortex-M7 port saves FPU registers automatically (lazy stacking); each task using floats needs extra stack (S16-S31 and the extended frame).
- Several macros differ across kernel versions (for example the newlib reentrancy options): consult the version-specific config documentation.
- Do not use `SysTick_Config` yourself: the port configures SysTick when the scheduler starts. Do not run your own `SysTick_Handler` either (or call `xPortSysTickHandler` from it if you need a bare-metal tick too, which is a common source of confusion).

---

## 4. Integrating FreeRTOS in your CMake project

### 4.1 Sources to build

From the `FreeRTOS-Kernel` repository (add as a git submodule in `extern/`):

```
tasks.c  queue.c  list.c  timers.c  event_groups.c  stream_buffer.c  croutine.c(optional)
portable/GCC/ARM_CM7/r0p1/port.c  and  portmacro.h
portable/MemMang/heap_4.c         (one heap implementation)
include/*.h
```

### 4.2 CMake

```cmake
add_library(freertos STATIC
  extern/FreeRTOS-Kernel/tasks.c
  extern/FreeRTOS-Kernel/queue.c
  extern/FreeRTOS-Kernel/list.c
  extern/FreeRTOS-Kernel/timers.c
  extern/FreeRTOS-Kernel/event_groups.c
  extern/FreeRTOS-Kernel/stream_buffer.c
  extern/FreeRTOS-Kernel/portable/GCC/ARM_CM7/r0p1/port.c
  extern/FreeRTOS-Kernel/portable/MemMang/heap_4.c)

target_include_directories(freertos PUBLIC
  extern/FreeRTOS-Kernel/include
  extern/FreeRTOS-Kernel/portable/GCC/ARM_CM7/r0p1
  config)                                   # the folder with FreeRTOSConfig.h

target_link_libraries(freertos PUBLIC mcu)  # same CPU/FPU flags (chapter 2)
target_compile_options(freertos PRIVATE -w) # vendor code warnings off, or keep them on and fix

target_link_libraries(firmware PRIVATE app freertos hal_stm32f7)
```

The FreeRTOS-Kernel repository also ships CMake support (`FREERTOS_PORT` and `FREERTOS_HEAP` cache variables and a `freertos_kernel` target); check its README for your version if you prefer that route.

### 4.3 Integration checklist

1. `FreeRTOSConfig.h` in an include path **before** any other.
2. `SVC_Handler`, `PendSV_Handler`, `SysTick_Handler` mapped (macros above) and **not defined elsewhere**.
3. `NVIC_SetPriorityGrouping(3)` early in `main`.
4. Heap file chosen, or static allocation only.
5. Hooks defined: `vApplicationMallocFailedHook`, `vApplicationStackOverflowHook(TaskHandle_t, char *)`, and, with static allocation, `vApplicationGetIdleTaskMemory`/`vApplicationGetTimerTaskMemory`.
6. Startup must run `SystemInit`/clock config **before** `vTaskStartScheduler` (the tick depends on the core clock).
7. Interrupts that use `...FromISR` are in the allowed priority range.
8. The vector table (and `main` stack) are untouched: after `vTaskStartScheduler` the MSP is reused for interrupts.

---

## 5. Memory management

### 5.1 Heap implementations (`portable/MemMang`)

| File | Behavior | Use |
|---|---|---|
| `heap_1.c` | Allocate only, never free | Static systems that never delete |
| `heap_2.c` | Free but no coalescing (obsolete) | Avoid |
| **`heap_4.c`** | First-fit with coalescing | Default choice |
| `heap_5.c` | `heap_4` over several memory regions | Multiple RAMs (e.g. DTCM + SRAM) |
| Static allocation | `xTaskCreateStatic`, `xQueueCreateStatic`, ... | No heap at all: preferable for safety-critical firmware |

Query: `xPortGetFreeHeapSize()`, `xPortGetMinimumEverFreeHeapSize()` (the high-water mark of heap usage).

### 5.2 Static allocation example

```c
static StackType_t  sensor_stack[256];
static StaticTask_t sensor_tcb;
TaskHandle_t h = xTaskCreateStatic(sensor_task, "sensor", 256, NULL, 3, sensor_stack, &sensor_tcb);

static StaticQueue_t q_tcb;
static uint8_t       q_storage[16 * sizeof(event_t)];
QueueHandle_t q = xQueueCreateStatic(16, sizeof(event_t), q_storage, &q_tcb);

/* required when configSUPPORT_STATIC_ALLOCATION == 1 */
void vApplicationGetIdleTaskMemory(StaticTask_t **tcb, StackType_t **stack, uint32_t *size)
{
    static StaticTask_t idle_tcb; static StackType_t idle_stack[configMINIMAL_STACK_SIZE];
    *tcb = &idle_tcb; *stack = idle_stack; *size = configMINIMAL_STACK_SIZE;
}
/* same for vApplicationGetTimerTaskMemory when timers are enabled */
```

### 5.3 Stack sizing and overflow

- Check each task's **high-water mark**: `uxTaskGetStackHighWaterMark(NULL)` returns the minimum free stack **in words** ever seen. Print it after exercising the worst case, then add a margin.
- `configCHECK_FOR_STACK_OVERFLOW = 2` fills stacks with a pattern and checks the last bytes at each context switch (catches most, not all, overflows). Method 1 checks only the saved stack pointer. The hook:

```c
void vApplicationStackOverflowHook(TaskHandle_t task, char *name)
{
    (void)task; (void)name;
    taskDISABLE_INTERRUPTS();
    for (;;) { }                          /* stop here: inspect `name` in the debugger */
}
```

- The MPU-aware ports (`ARM_CM7_MPU`) can place guard regions per task; they need MPU region definitions: advanced.
- Typical stacks: 128-256 words for simple tasks; **`printf`/`snprintf` with floats can need 512+ words**; the timer task and ISRs have their own accounting; interrupt nesting uses MSP (check `_Min_Stack_Size`).

---

## 6. Inter-task communication and synchronization

### 6.1 Selecting the right primitive

| Need | Primitive | Notes |
|---|---|---|
| Pass data between tasks/ISR | **Queue** (copy semantics) | Fixed item size; blocking send/receive with timeouts |
| Pass bytes (UART RX) from ISR to a task | **Stream buffer** | Single writer, single reader: very efficient |
| Pass whole variable-size messages | **Message buffer** | Like stream buffer with length prefixes |
| Signal an event (ISR to task) | **Task notification** | Fastest and smallest (no extra object) |
| Signal with a count | Counting semaphore | Resource counting, event counting |
| Mutual exclusion | **Mutex** | Priority inheritance; never from an ISR |
| Wait for several flags | **Event group** | Bits; `xEventGroupWaitBits` with AND/OR |
| Delayed or periodic callbacks | **Software timer** | Runs in the timer service task |
| Sleep for a time | `vTaskDelay`, **`xTaskDelayUntil`** | `...Until` gives drift-free periods |

### 6.2 Queues

```c
typedef struct { uint32_t id; uint32_t value; } event_t;
QueueHandle_t q_events;

q_events = xQueueCreate(16, sizeof(event_t));

/* task: send, wait up to 10 ms for space */
event_t ev = { 1, 42 };
if (xQueueSend(q_events, &ev, pdMS_TO_TICKS(10)) != pdPASS) { /* full: count the drop */ }

/* task: receive, blocking forever */
event_t r;
while (xQueueReceive(q_events, &r, portMAX_DELAY) == pdPASS) { handle(&r); }
```

Items are **copied** into the queue: for large data pass a **pointer** (and define who owns the buffer: a pool is better than the heap) or use stream/message buffers.

### 6.3 Task notifications (lightweight signals)

```c
static TaskHandle_t rx_task_handle;

/* ISR: notify the handler task */
void USART3_IRQHandler(void)
{
    BaseType_t woken = pdFALSE;
    /* ... read data, clear flags ... */
    vTaskNotifyGiveFromISR(rx_task_handle, &woken);
    portYIELD_FROM_ISR(woken);
}

/* task */
for (;;) {
    ulTaskNotifyTake(pdTRUE, portMAX_DELAY);     /* blocks until notified; returns the count */
    process_rx();
}
```

`xTaskNotify` (with actions: set bits, increment, overwrite value) and `xTaskNotifyWait` give event-flag behavior. A task has a notification value of its own; each notification index is an independent slot in newer versions.

### 6.4 Stream buffer for UART RX

```c
static StreamBufferHandle_t rx_sb;     /* xStreamBufferCreate(256, 1) : trigger level 1 byte */

/* ISR: push the received byte */
BaseType_t woken = pdFALSE;
uint8_t b = (uint8_t)USART3->RDR;
xStreamBufferSendFromISR(rx_sb, &b, 1, &woken);
portYIELD_FROM_ISR(woken);

/* parser task */
uint8_t chunk[32];
for (;;) {
    size_t n = xStreamBufferReceive(rx_sb, chunk, sizeof chunk, portMAX_DELAY);
    for (size_t i = 0; i < n; i++) { rx_feed(&frame, chunk[i], on_frame); }   /* COBS parser, chapter 11 */
}
```

Only **one** writer and **one** reader are allowed.

### 6.5 Mutexes, priority inversion, deadlock

**Priority inversion**: a low-priority task holds a lock needed by a high-priority task; a medium-priority task preempts the low one, so the high-priority task waits for the medium one (it "inherited" nothing). FreeRTOS **mutexes** use **priority inheritance** (the holder temporarily gets the waiter's priority). **Binary semaphores do not**: use mutexes for locking.

```c
SemaphoreHandle_t m = xSemaphoreCreateMutex();
if (xSemaphoreTake(m, pdMS_TO_TICKS(100)) == pdTRUE) {
    /* critical resource */
    xSemaphoreGive(m);                      /* give from the same task that took it */
}
```

Rules:

1. Keep critical sections **short**; never block (delays, queues) while holding a mutex unless unavoidable.
2. Acquire multiple mutexes in a **fixed global order** (prevents deadlock).
3. Mutexes are **not usable from ISRs**; use queues/notifications.
4. **Prefer ownership by a single task** (a "gatekeeper") instead of shared locks: the UART/log/display is owned by one task and others send it messages.
5. Avoid recursive mutexes unless needed.

### 6.6 Event groups

```c
EventGroupHandle_t eg = xEventGroupCreate();
#define BIT_SENSOR_OK (1u << 0)
#define BIT_COMM_OK   (1u << 1)
#define ALL_OK        (BIT_SENSOR_OK | BIT_COMM_OK)

/* workers: xEventGroupSetBits(eg, BIT_SENSOR_OK); */
/* supervisor: wait for all, clear on exit, timeout 2 s: */
EventBits_t b = xEventGroupWaitBits(eg, ALL_OK, pdTRUE, pdTRUE, pdMS_TO_TICKS(2000));
if ((b & ALL_OK) == ALL_OK) { iwdg_kick(); }       /* watchdog supervision pattern */
```

### 6.7 Software timers

Callbacks run in the **timer service task** (priority `configTIMER_TASK_PRIORITY`), so they must not block. `xTimerCreate`, `xTimerStart`, `xTimerChangePeriod`; from an ISR use the `...FromISR` variants. Good for timeouts, retries, periodic checks; a blocking callback delays all other timers.

---

## 7. Interrupts and the deferred-processing pattern

```
Hardware ──► ISR (short): read/clear flag, move data, give notification/queue ──► handler task (does the work)
```

Rules for ISRs using FreeRTOS:

- Use only `...FromISR` functions, with `BaseType_t woken = pdFALSE;` and `portYIELD_FROM_ISR(woken)` at the end so a woken high-priority task runs **immediately** when the ISR returns.
- ISR priority must be in the allowed range (section 2.4).
- No blocking, no `malloc`, no `printf`.
- To handle the **ISR safe critical section** inside an ISR: `UBaseType_t s = taskENTER_CRITICAL_FROM_ISR(); ... taskEXIT_CRITICAL_FROM_ISR(s);`.
- Task critical sections: `taskENTER_CRITICAL()`/`taskEXIT_CRITICAL()` raise `BASEPRI` to the max syscall priority: **keep them extremely short**; urgent ISRs still run.
- `vTaskSuspendAll()`/`xTaskResumeAll()` stop task switches but leave interrupts enabled: for longer sections that do not touch ISR-shared data.

---

## 8. Design patterns for FreeRTOS applications

### 8.1 Task decomposition rules (chapter 8, applied)

1. A task per **concern** and per **timing requirement** (communications, sensing, control, UI, logging), not per function.
2. **Few tasks**: each costs a stack plus a TCB and adds interleavings to reason about.
3. Priorities from **deadlines** (shortest deadline = highest priority); leave gaps in numbering.
4. Tasks communicate through **queues/notifications**, share as little state as possible.
5. Every task blocks **somewhere** (`xQueueReceive`, `ulTaskNotifyTake`, `vTaskDelayUntil`): a task that never blocks starves all lower priorities.
6. Use **event-driven** tasks (wait on a queue) rather than polling; they save CPU and power.

### 8.2 Periodic task with drift-free timing

```c
void control_task(void *arg)
{
    TickType_t last = xTaskGetTickCount();
    for (;;) {
        xTaskDelayUntil(&last, pdMS_TO_TICKS(10));      /* 100 Hz exactly, regardless of the work time */
        control_step();
    }
}
```

`vTaskDelay(10)` would delay 10 ms **after** the work: the period drifts. For 1 kHz and faster loops a hardware timer ISR (with a notification) gives better jitter than the 1 ms tick.

### 8.3 Gatekeeper task (owner of a resource)

```c
typedef struct { char text[64]; } log_msg_t;
static QueueHandle_t q_log;

void log_task(void *arg)                      /* the ONLY task that touches the UART */
{
    log_msg_t m;
    for (;;) { xQueueReceive(q_log, &m, portMAX_DELAY); uart_write_blocking(m.text); }
}
/* everyone else formats into a local msg and calls xQueueSend(q_log, &m, 0) */
```

Removes the need for a UART mutex and keeps logging from blocking real-time tasks.

### 8.4 Command/response between tasks

Send a request struct that includes a reply queue handle or a notification target; the owner task processes it and answers. Avoid synchronous call chains across several tasks (hidden coupling).

### 8.5 Supervision with watchdog

Each critical task sets a bit in an event group (or a "progress" counter) every cycle; a supervisor task waits for all bits within the period and only then kicks the independent watchdog (section 6.6). A hung task makes the supervisor stop kicking: the chip resets and reports the reason (chapter 4).

### 8.6 Pipeline

```
ADC ISR/DMA ─► sensor_task ─► filter_task ─► control_task ─► actuator
              (queue)         (queue)          (queue)
```

Each stage is a small task or function; queue lengths decouple rates; watch for overflow and count drops.

### 8.7 State machines inside tasks

A task owning a state machine blocks on its **event queue**, handles one event to completion, loops. Timeouts come from `xQueueReceive` with a timeout, or software timers that post events.

---

## 9. Timing analysis and debugging

### 9.1 Scheduling analysis basics

For periodic tasks with period `Ti` (deadline = period) and worst-case execution time `Ci`:

```
CPU utilization  U = Σ Ci / Ti
Rate-monotonic bound: schedulable if U ≤ n (2^(1/n) - 1)       (n=3: 0.780;  n→∞: ln 2 ≈ 0.693)
```

Rate-monotonic assignment: **shorter period = higher priority**. The bound is sufficient, not necessary; for exactness use **response-time analysis**: `Ri = Ci + Σ_{j higher priority} ceil(Ri / Tj) * Cj`, iterate until it converges; check `Ri ≤ Di`. Include **blocking** time from mutexes (bounded with priority inheritance) and **ISR interference**.

Example: tasks A (T = 10 ms, C = 2), B (T = 20 ms, C = 4), C (T = 50 ms, C = 10): `U = 0.2 + 0.2 + 0.2 = 0.6 < 0.78`: schedulable. Priorities: A > B > C.

**Measure `Ci`** with the DWT cycle counter (chapter 3) around the task body, taking worst cases over many runs and including cache/flash wait-state effects (the M7 timing is data-dependent); add a safety margin (30-50 %).

### 9.2 Runtime statistics

```c
/* needs configUSE_TRACE_FACILITY = 1, configUSE_STATS_FORMATTING_FUNCTIONS = 1 */
char buf[512];
vTaskList(buf);                  /* name, state, priority, stack high-water mark, number */
printf("%s", buf);

/* CPU usage per task: configGENERATE_RUN_TIME_STATS = 1 and provide a time base
   at least 10x faster than the tick (a free-running 32-bit timer or DWT->CYCCNT scaled): */
#define portCONFIGURE_TIMER_FOR_RUN_TIME_STATS()  dwt_cyccnt_init()
#define portGET_RUN_TIME_COUNTER_VALUE()          (DWT->CYCCNT)
vTaskGetRunTimeStats(buf);
```

(`vTaskList`/`vTaskGetRunTimeStats` are intended for debugging: they disable the scheduler while formatting and use `sprintf`.)

### 9.3 Tracing

- **SEGGER SystemView** (via RTT, works with J-Link; community ports for other probes): timeline of tasks, ISRs, queue activity, and CPU load. The best way to find priority inversion and latency causes.
- **Percepio Tracealyzer**: similar, with a free tier.
- A **GPIO per task**: set at task entry/exit; a logic analyzer shows the scheduling. Cheap and effective (chapter 10).

### 9.4 Debugger awareness

- GDB/OpenOCD can list tasks if built with `configUSE_TRACE_FACILITY` and the symbol `uxTopUsedPriority` is retained: OpenOCD target option `-rtos FreeRTOS`; in Cortex-Debug set `"rtos": "FreeRTOS"`.
- Useful gdb: `info threads`, `thread N` then `bt`; inspect `pxCurrentTCB`, `xTickCount`, `uxTopReadyPriority`.
- A `HardFault` inside a task: the stacked frame is on the **PSP** (`EXC_RETURN` bit 2 set): use the handler of chapter 3 to read it, then `addr2line`.

### 9.5 Common bugs and symptoms

| Symptom | Cause |
|---|---|
| Hard fault at `vTaskStartScheduler` | Handlers not mapped, wrong port (CM4 vs CM7), vector table/stack, FPU not enabled |
| Scheduler never switches / stuck in a task | A task never blocks; tick ISR priority wrong; PendSV handler overridden |
| `configASSERT` failure in `...FromISR` | ISR priority numerically too low (too urgent) or wrong priority grouping |
| Random crashes | Stack overflow, heap exhaustion, ISR calling a non-ISR API |
| Task never runs | Higher-priority task starving it (never blocks), or the task is created after the scheduler and heap is full |
| Starvation of equal-priority tasks | `configUSE_TIME_SLICING = 0` or a task that never yields |
| Deadlock | Two mutexes taken in opposite order; waiting forever on an event never sent |
| Priority inversion hiccups | Binary semaphore used as a lock, or mutex held across a blocking call |
| Timer callbacks delayed | Blocking callback, low timer task priority, full timer command queue |
| Missed UART bytes | ISR too slow, queue too small; use stream buffer/DMA |
| `malloc` failures over time | Fragmentation (use `heap_4` with a stable allocation pattern, or static allocation) |
| Wrong delays | Tick rate mismatch, SysTick clock not matching `configCPU_CLOCK_HZ` (PLL changed after kernel start) |
| Printf garbage / crash | Newlib not thread-safe: use a single logging task, or enable the kernel's reentrancy support for your version |
| Debug builds work, release fails | Missing `volatile`, timing assumptions, stack sizes smaller at `-Os`/`-Og` |

---

## 10. Full example: sensor, processing, and logging

```c
/* app_rtos.c : illustrative */
#include "FreeRTOS.h"
#include "task.h"
#include "queue.h"
#include "stream_buffer.h"

typedef struct { uint32_t t_ms; int16_t raw; } sample_t;

static QueueHandle_t       q_samples;
static StreamBufferHandle_t sb_rx;
static TaskHandle_t        h_proc;

static void sensor_task(void *arg)                       /* 100 Hz, priority 4 */
{
    (void)arg;
    TickType_t last = xTaskGetTickCount();
    for (;;) {
        xTaskDelayUntil(&last, pdMS_TO_TICKS(10));
        sample_t s = { .t_ms = xTaskGetTickCount() * portTICK_PERIOD_MS, .raw = adc_read() };
        if (xQueueSend(q_samples, &s, 0) != pdPASS) { stats.drops++; }
    }
}

static void process_task(void *arg)                      /* priority 3 */
{
    (void)arg;
    sample_t s;
    for (;;) {
        xQueueReceive(q_samples, &s, portMAX_DELAY);
        float v = filter_update((float)s.raw);           /* chapter 13 */
        log_post("t=%lu v=%.2f", (unsigned long)s.t_ms, (double)v);
    }
}

static void rx_task(void *arg)                           /* parses commands from UART, priority 2 */
{
    (void)arg;
    uint8_t chunk[32];
    for (;;) {
        size_t n = xStreamBufferReceive(sb_rx, chunk, sizeof chunk, portMAX_DELAY);
        for (size_t i = 0; i < n; i++) { rx_feed(&rx, chunk[i], on_frame); }
    }
}

void USART3_IRQHandler(void)                             /* ISR priority 6: allowed to use the API (range 5..14) */
{
    BaseType_t woken = pdFALSE;
    if (USART3->ISR & USART_ISR_RXNE) {
        uint8_t b = (uint8_t)USART3->RDR;
        xStreamBufferSendFromISR(sb_rx, &b, 1, &woken);
    }
    portYIELD_FROM_ISR(woken);
}

int main(void)
{
    board_init();                                        /* clock, pins, UART (chapter 7) */
    NVIC_SetPriorityGrouping(3);                         /* all bits preemption */

    q_samples = xQueueCreate(32, sizeof(sample_t));
    sb_rx     = xStreamBufferCreate(256, 1);
    log_init();                                          /* creates the log gatekeeper task */

    xTaskCreate(sensor_task,  "sensor",  256, NULL, 4, NULL);
    xTaskCreate(process_task, "process", 512, NULL, 3, &h_proc);
    xTaskCreate(rx_task,      "rx",      384, NULL, 2, NULL);

    vTaskStartScheduler();                               /* never returns if there is enough heap */
    for (;;) { }                                         /* reaching here means no memory for idle/timer task */
}

void vApplicationMallocFailedHook(void) { for (;;) { } }
```

Check after building: the map file for heap use, `uxTaskGetStackHighWaterMark` of each task, and a logic-analyzer trace of the task GPIOs.

---

## 11. Tickless idle and low power (preview of chapter 15)

`configUSE_TICKLESS_IDLE = 1` stops the periodic tick when all tasks are blocked for a long time and sleeps until the next event (`WFI`); the kernel reprograms the tick source and corrects the tick count on wake-up. The default port implementation works with SysTick in Sleep mode; deeper modes (Stop) need a low-power timer (LPTIM/RTC) and a custom `vPortSuppressTicksAndSleep`. Remember peripheral clocks and re-init after Stop (chapter 15).

---

## 12. FreeRTOS and your C++/Zephyr/other knowledge

- **C++**: tasks are C functions; wrap objects with a trampoline (`static void entry(void *p) { static_cast<MyTask *>(p)->run(); }`), construct objects before the scheduler starts, avoid heavy global constructors (chapter 6).
- **CMSIS-RTOS2** is a standard API over FreeRTOS (and others); wrapper layers (`osThreadNew`, `osMessageQueueNew`) improve portability at a small cost. Use it if a vendor library expects it.
- **Zephyr vs FreeRTOS**: the concepts map one to one: `k_msgq` ≈ queue, `k_sem_give` from ISR ≈ `xSemaphoreGiveFromISR`, `k_work` ≈ deferred task/timer callback, `K_THREAD_DEFINE` ≈ `xTaskCreateStatic`; the priority numbering is **reversed**, which is a classic source of mistakes when moving between them.
- **Newlib reentrancy**: C library functions that keep global state (`errno`, `strtok`, `rand`, `printf` buffers) need protection; use thread-safe formatting through a single logging task.

---

## 13. Exercises

1. **Bring-up**: add FreeRTOS to your CMake project, blink two LEDs from two tasks with different periods, and verify the tick with a logic analyzer.
2. **Interrupt priorities**: set a UART ISR priority to 2 and call `xQueueSendFromISR`; observe the `configASSERT`; fix it with a priority in the allowed range.
3. **Stack sizing**: create a task that uses `snprintf("%f")`, measure `uxTaskGetStackHighWaterMark`, then tune the stack; provoke an overflow and catch it with the hook.
4. **Producer/consumer**: ADC samples through a queue to a logger; stress it with a slow consumer and count drops.
5. **Notification vs semaphore**: implement ISR-to-task signaling with both and compare code size and latency (GPIO toggles measured with a scope).
6. **Stream buffer UART**: implement the COBS parser pipeline of chapter 11 on the Nucleo VCP; send garbage and valid frames from Python.
7. **Priority inversion**: reproduce it (low holds a lock, medium busy-loops, high waits) using a binary semaphore; then fix with a mutex; show both timelines with GPIO traces or SystemView.
8. **Deadlock**: create two tasks taking two mutexes in opposite order; observe the hang; fix with consistent ordering.
9. **Gatekeeper**: remove the UART mutex and implement a logging task; compare timing of the real-time task.
10. **Watchdog supervision**: event-group based supervisor; hang one task on purpose and observe the reset and its cause.
11. **Response-time analysis**: measure `Ci` of three tasks with DWT, compute `U` and response times, and verify with a trace.
12. **Run-time stats**: enable `vTaskList` and `vTaskGetRunTimeStats` with the DWT counter and print a table over UART.
13. **Static allocation**: remove the heap completely (`configSUPPORT_DYNAMIC_ALLOCATION = 0`) and build with static tasks/queues.
14. **SystemView or Tracealyzer** (if you have a J-Link or the free trial): capture a trace and identify one latency.
15. **Port the example from chapter 8** (blinker + button + UART + VBAT) from the cooperative scheduler to FreeRTOS and compare Flash/RAM, latency, and lines of code.

---

## 14. Cheat sheet

```
Create        xTaskCreate(fn, "name", stack_words, arg, prio, &handle)     (higher number = higher priority)
Time          vTaskDelay(ms) / xTaskDelayUntil(&last, period) / pdMS_TO_TICKS(ms) / xTaskGetTickCount()
Queue         xQueueCreate / xQueueSend / xQueueReceive          (+ ...FromISR)
Notify        xTaskNotifyGive / ulTaskNotifyTake                 (+ vTaskNotifyGiveFromISR)
Mutex         xSemaphoreCreateMutex / Take / Give                (priority inheritance, no ISR)
Event group   xEventGroupSetBits / WaitBits
Stream buf    xStreamBufferSend / Receive                        (+ FromISR, one writer one reader)
Timer         xTimerCreate / Start                               (callback runs in the timer task)
ISR end       portYIELD_FROM_ISR(woken)
Info          uxTaskGetStackHighWaterMark, xPortGetFreeHeapSize, vTaskList
Config        configMAX_SYSCALL_INTERRUPT_PRIORITY, configPRIO_BITS=4, handlers mapped to CMSIS names
```

Golden rules: every task blocks somewhere; ISRs short and in the allowed priority range; mutexes for locks; ownership by one task where possible; size stacks by measurement; `configASSERT` on; never block in the timer callback; analyze timing with numbers, not intuition.

---

## 15. Where this leads

- **Control and DSP** (chapter 13): fixed-rate control tasks and sampling.
- **Low power** (chapter 15): tickless idle and sleep modes.
- **Testing** (chapter 14): host tests of task logic with an OS abstraction layer, HIL tests.
- **Bootloader/security** (chapter 16): update tasks and secure communications.
- **Zephyr** (chapter 9): compare the same design with a platform-style RTOS.

## References

- FreeRTOS documentation and *Mastering the FreeRTOS Real Time Kernel*: <https://www.freertos.org/Documentation/>
- FreeRTOS-Kernel source and port notes: <https://github.com/FreeRTOS/FreeRTOS-Kernel>
- Arm *Cortex-M7 Devices Generic User Guide* (BASEPRI, NVIC); chapter 3 of these notes
- Liu and Layland (1973), rate-monotonic scheduling; Buttazzo, *Hard Real-Time Computing Systems*
- SEGGER SystemView, Percepio Tracealyzer documentation
- *Real-Time Concepts for Embedded Systems*, Qing Li and Caroline Yao