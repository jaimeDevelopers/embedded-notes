# 8. Firmware Architecture and Design Patterns

Context: everything built in the previous chapters (toolchain, Make/CMake, Cortex-M, debugging, C, C++, peripherals) on the NUCLEO-F746ZG. This chapter is about **how to organize the code** so that it stays testable, portable and understandable as it grows from a blinking LED to a product.

**Verification note.** The code here is illustrative and **has not been compiled or run on your board**. It is written in the style of the earlier chapters; treat it as templates, compile with warnings on, and test on the host where possible (section 14).

---

## 1. Why architecture matters in firmware

A first project often looks like this:

```c
int main(void)
{
    /* init everything with register writes */
    for (;;) {
        if (USART3->ISR & USART_ISR_RXNE) { ... GPIOB->ODR ^= ...; adc_read(); printf(...); }
        ...
    }
}
```

It works until you need to: change the board, add a second sensor, test without hardware, reuse the driver in another project, or find out why it crashes once a week. By then registers are scattered through the application logic and nothing can be tested without the board.

Architecture is the set of decisions that keep **change cheap** and **bugs local**. For firmware, the goals are:

| Goal | Meaning |
|---|---|
| **Testability** | Business logic can run on a PC with fake hardware |
| **Portability** | Changing the MCU, board or peripheral touches a small layer |
| **Readability** | A reader finds "where is X" in seconds |
| **Predictability** | Memory use, timing and ISR behavior are known in advance |
| **Robustness** | Failures are detected, contained and recovered |
| **Maintainability** | A change in one module does not ripple through all the others |

Resource limits make embedded different: abstraction must be **cheap** (no heap, no hidden costs), and decisions should be checked with `size`, the map file and the debugger (chapters 0 and 4).

### Principles that carry most of the weight

1. **Separation of concerns**: hardware access, device protocols, application logic and user interface are different jobs in different modules.
2. **High cohesion, low coupling**: a module does one thing; modules know as little as possible about each other.
3. **Information hiding**: expose an interface (header), hide the data and helpers (`static`, opaque types).
4. **Dependency inversion**: high-level code depends on an **interface**, not on a concrete low-level implementation. The sensor driver needs "a bus", not "I2C1 of an STM32".
5. **Depend downward only**: higher layers call lower layers; lower layers notify higher ones through callbacks or events, never by including their headers.
6. **Make the right thing easy and the wrong thing hard**: types, `static`, and the build graph should enforce the rules (section 12).
7. **Do not over-engineer**: abstract when you have two implementations or a testing need, not "just in case". Every layer has a cost in code, indirection and reading time.

---

## 2. Layered architecture

```
┌─────────────────────────────────────────────────────────┐
│  Application                                            │  what the product does
│  (state machines, policies, user interaction)           │
├─────────────────────────────────────────────────────────┤
│  Services / middleware                                  │  reusable logic with no hardware
│  (event queue, scheduler, logging, CLI, settings,       │
│   protocol stacks, filesystem, RTOS wrappers)           │
├─────────────────────────────────────────────────────────┤
│  Device drivers (components)                            │  external chips and board features
│  (sensor, display, flash chip, LED, button)             │  built on the HAL interfaces
├─────────────────────────────────────────────────────────┤
│  HAL interfaces  (hal_gpio.h, hal_uart.h, hal_i2c.h...) │  the contract, no vendor types
├─────────────────────────────────────────────────────────┤
│  HAL implementation / MCU drivers                       │  STM32F7 registers, clock, DMA, ISRs
│  (your peripheral drivers or the vendor HAL)            │
├─────────────────────────────────────────────────────────┤
│  BSP / board                                            │  pin map, clocks, board init
├─────────────────────────────────────────────────────────┤
│  CMSIS, startup, linker script                          │  vendor/ARM base
├─────────────────────────────────────────────────────────┤
│  Hardware                                               │
└─────────────────────────────────────────────────────────┘
```

### Rules of a layered design

- A layer uses only the layer **directly below** (or the interfaces of lower ones). It never includes a header from above.
- **Events and callbacks go up**; **calls go down**.
- A layer does not know the implementation behind the interface below it.
- Cross-cutting concerns (logging, assertions, error codes, time) are small shared modules (`common/`) that any layer may use, and which depend on nothing but the language.
- Vendor headers (`stm32f7xx.h`) appear **only** in the MCU layer and the BSP. If `app.c` includes `stm32f7xx.h`, the architecture has leaked.

### Mapping the current project

| Existing file | Where it belongs |
|---|---|
| `led.c`, `button.c` | Device drivers (use `hal_gpio`), with pins from the BSP |
| `uart.c` | HAL implementation (`hal_uart_stm32.c`), with a `hal_uart.h` interface |
| `adc.c` | HAL implementation plus a service that converts raw readings to volts/°C |
| `systick.c` | HAL implementation of `hal_time` (`hal_millis()`) |
| `main.c` | Composition root: creates instances, wires them, runs the loop |
| `system_stm32f7xx.c`, startup, linker script | `boards/stm32f746/` |

### Folder layout

```
project/
├── CMakeLists.txt
├── cmake/
│   ├── toolchains/arm-toolchain.cmake
│   └── modules/
├── boards/
│   └── stm32f746_nucleo/
│       ├── board.cmake            # flags, defines, linker script, startup, board source list
│       ├── board.c  board.h       # clock init, pin map, board_init()
│       ├── pins.h
│       ├── STM32F746ZGTx_FLASH.ld
│       └── vendor/                # startup_*.s, system_*.c
├── extern/                        # cmsis_core, cmsis_device_f7, optional: etl, freertos, unity
├── src/
│   ├── common/                    # status codes, assert, log, bit helpers, ring buffer
│   ├── hal/
│   │   ├── include/               # hal_gpio.h hal_uart.h hal_time.h ...  (interfaces)
│   │   ├── stm32f7/               # implementations for the MCU
│   │   └── host/                  # fakes for PC tests
│   ├── drivers/                   # sensor_xyz.c, led.c, button.c ...
│   ├── services/                  # event_queue.c, scheduler.c, cli.c, settings.c
│   ├── app/                       # state machines, application logic
│   └── main.c                     # composition root
├── tests/                         # host tests (own CMake project)
├── tools/                         # scripts: add_crc.py, gdb helpers, openocd cfg
└── docs/                          # architecture notes, ADRs, diagrams
```

---

## 3. Designing the HAL (hardware abstraction)

A HAL here means **your own thin interface** over the hardware, one header per capability. It is not the vendor's "STM32 HAL" (though you may implement your interface on top of it).

### 3.1 What a good HAL interface looks like

```c
/* src/hal/include/hal_gpio.h  --  no vendor includes */
#ifndef HAL_GPIO_H
#define HAL_GPIO_H

#include <stdbool.h>
#include <stdint.h>

typedef uint8_t hal_pin_t;                       /* opaque pin id, defined by the board */
#define HAL_PIN(port_letter, n)  ((hal_pin_t)((((port_letter) - 'A') << 4) | (n)))

typedef enum { HAL_GPIO_INPUT, HAL_GPIO_OUTPUT, HAL_GPIO_ANALOG } hal_gpio_mode_t;
typedef enum { HAL_GPIO_NOPULL, HAL_GPIO_PULLUP, HAL_GPIO_PULLDOWN } hal_gpio_pull_t;

void hal_gpio_configure(hal_pin_t pin, hal_gpio_mode_t mode, hal_gpio_pull_t pull);
void hal_gpio_write(hal_pin_t pin, bool level);
bool hal_gpio_read(hal_pin_t pin);
void hal_gpio_toggle(hal_pin_t pin);

#endif
```

Qualities to aim for:

- **No vendor types** in the interface: pin is an integer, not a `GPIO_TypeDef *`.
- **Small and capability-oriented**: what the upper layers need ("write this pin"), not what the silicon offers.
- **Error reporting** through return values (`status_t`) where operations can fail.
- **Timeouts** on anything that can wait on hardware.
- **Documented behavior**: blocking or not, ISR-safe or not, thread-safe or not.

### 3.2 Three ways to swap implementations (the "seam")

| Seam | How | Cost | Best for |
|---|---|---|---|
| **Link-time** | Same header, different `.c` selected by the build (`hal/stm32f7/hal_gpio.c` for the target, `hal/host/hal_gpio_fake.c` for tests) | Zero run-time cost | Most firmware: one hardware at a time. Simple and efficient |
| **Run-time (ops table / function pointers)** | A struct of function pointers selected at start-up | One indirect call, a few bytes per instance | Several instances with different behavior (two buses, two displays), plugins |
| **Compile-time (C++ templates)** | Template parameter, CRTP, concepts | Zero cost, code per instantiation | C++ projects, policy-based drivers |

Rule of thumb: **default to the link-time seam** (no overhead, trivial to understand). Use an ops table when the same code must handle different backends in one image.

### 3.3 Ops table (runtime polymorphism in C)

```c
typedef struct {
    int (*write)(void *ctx, const uint8_t *data, size_t len);
    int (*read)(void *ctx, uint8_t *data, size_t len);
} stream_ops_t;

typedef struct {
    const stream_ops_t *ops;
    void               *ctx;
} stream_t;

static inline int stream_write(stream_t *s, const uint8_t *d, size_t n) { return s->ops->write(s->ctx, d, n); }
```

The same `log` or `cli` module writes to a UART, to ITM/SWO, to a ring buffer in RAM, or to a test fake, depending on the `stream_t` it receives.

### 3.4 Pin map in the board layer

```c
/* boards/stm32f746_nucleo/pins.h */
#include "hal_gpio.h"
#define PIN_LED_GREEN   HAL_PIN('B', 0)     /* LD1 */
#define PIN_LED_BLUE    HAL_PIN('B', 7)     /* LD2 */
#define PIN_LED_RED     HAL_PIN('B', 14)    /* LD3 */
#define PIN_BUTTON      HAL_PIN('C', 13)    /* B1 */
```

Implementation (STM32 layer, the only place with vendor types):

```c
/* src/hal/stm32f7/hal_gpio.c */
#include "hal_gpio.h"
#include "stm32f7xx.h"

static GPIO_TypeDef *port_of(hal_pin_t pin) { return (GPIO_TypeDef *)(GPIOA_BASE + (uintptr_t)(pin >> 4) * 0x400u); }
static unsigned      num_of(hal_pin_t pin)  { return pin & 0xFu; }

void hal_gpio_write(hal_pin_t pin, bool level)
{
    port_of(pin)->BSRR = 1u << (num_of(pin) + (level ? 0u : 16u));
}
bool hal_gpio_read(hal_pin_t pin)   { return (port_of(pin)->IDR & (1u << num_of(pin))) != 0u; }
void hal_gpio_toggle(hal_pin_t pin) { port_of(pin)->ODR ^= 1u << num_of(pin); }
/* hal_gpio_configure(): enable clock, set MODER/PUPDR (chapter 7) */
```

Host fake:

```c
/* src/hal/host/hal_gpio_fake.c */
#include "hal_gpio.h"
static bool levels[256];
void hal_gpio_write(hal_pin_t pin, bool level) { levels[pin] = level; }
bool hal_gpio_read(hal_pin_t pin)   { return levels[pin]; }
void hal_gpio_toggle(hal_pin_t pin) { levels[pin] = !levels[pin]; }
void hal_gpio_configure(hal_pin_t pin, hal_gpio_mode_t m, hal_gpio_pull_t p) { (void)pin; (void)m; (void)p; }
```

### 3.5 Other HAL interfaces you will want

| Interface | Content |
|---|---|
| `hal_time` | `hal_millis()`, `hal_micros()`, `hal_delay_ms()` (wrap-safe) |
| `hal_irq` | `hal_irq_save()`, `hal_irq_restore()`, `hal_wfi()`: critical sections and sleep |
| `hal_uart` | `init`, `write`, `read`, callbacks, error counters |
| `hal_i2c` / `hal_spi` | `transfer(addr, tx, tx_len, rx, rx_len, timeout)` |
| `hal_adc` | `read_raw(channel)`, scaling in a service |
| `hal_timer` / `hal_pwm` | Periodic callbacks, duty control |
| `hal_flash` | `read`, `erase_sector`, `program` |
| `hal_wdt` | `start`, `kick` |
| `hal_reset` | `hal_reset_cause()`, `hal_system_reset()` |

Start small: define an interface when a second user (or a test) needs it.

---

## 4. Designing drivers and components

### 4.1 Module template (C)

```c
/* sensor.h */
#ifndef SENSOR_H
#define SENSOR_H
#include "status.h"
#include "bus.h"

typedef struct sensor sensor_t;            /* opaque */

sensor_t *sensor_create(const bus_t *bus, uint8_t addr);
status_t  sensor_init(sensor_t *s);
status_t  sensor_read_milli_celsius(sensor_t *s, int32_t *out);

#endif
```

Design rules:

- **Lifecycle**: `init` (configure), optional `start`/`stop`, `deinit`. Constructors only store configuration; hardware access happens in `init` (same lesson as C++ constructors in chapter 6).
- **Static allocation**: a fixed pool of instances or a caller-provided struct, never `malloc`.
- **One owner** per piece of hardware or state. Document who may call what from which context (main, ISR, task).
- **Blocking vs non-blocking** is part of the interface: name it and document it (`_blocking` vs `_start`/`_poll`/callback).
- **Timeouts** on every wait.
- **Errors** as `status_t` values, never as magic numbers or silent failures.
- **No printing inside drivers** except through the logging service.
- **Config separate from code**: `const` config structs in the board layer.

### 4.2 A common status type

```c
typedef enum {
    ST_OK = 0,
    ST_ERR_TIMEOUT,
    ST_ERR_BUSY,
    ST_ERR_BUS,
    ST_ERR_INVALID,
    ST_ERR_NOT_READY,
    ST_ERR_OVERFLOW,
    ST_ERR_IO
} status_t;

const char *status_str(status_t s);              /* for logs */
#define RETURN_IF_ERR(expr)  do { status_t _s = (expr); if (_s != ST_OK) { return _s; } } while (0)
```

### 4.3 Dependency inversion in practice: a sensor on "a bus"

The sensor driver depends on a small `bus_t` interface, not on I2C1:

```c
/* bus.h */
typedef struct {
    status_t (*read_reg)(void *ctx, uint8_t dev, uint8_t reg, uint8_t *buf, size_t len);
    status_t (*write_reg)(void *ctx, uint8_t dev, uint8_t reg, const uint8_t *buf, size_t len);
} bus_ops_t;

typedef struct { const bus_ops_t *ops; void *ctx; } bus_t;
```

```c
/* sensor.c : an invented device with a big-endian 16-bit temperature register at 0x00, 1/256 degC per LSB */
struct sensor { const bus_t *bus; uint8_t addr; };

status_t sensor_read_milli_celsius(sensor_t *s, int32_t *out)
{
    uint8_t raw[2];
    RETURN_IF_ERR(s->bus->ops->read_reg(s->bus->ctx, s->addr, 0x00u, raw, sizeof raw));
    int16_t v = (int16_t)(((uint16_t)raw[0] << 8) | raw[1]);
    *out = ((int32_t)v * 1000) / 256;
    return ST_OK;
}
```

On the target, the bus ops wrap `hal_i2c_transfer`. In a host test they are a **fake** that returns scripted bytes:

```c
static status_t fake_read(void *ctx, uint8_t dev, uint8_t reg, uint8_t *buf, size_t len)
{
    (void)ctx; (void)dev; (void)reg;
    buf[0] = 0x19; buf[1] = 0x80;                 /* 25.5 degC = 0x1980 / 256 */
    return ST_OK;
}
/* assert(sensor_read_milli_celsius(&s, &t) == ST_OK && t == 25500); */
```

The driver can be tested, debugged, and reused with SPI or a different MCU without touching it.

### 4.4 Interrupt-driven drivers: the ISR boundary

```
Hardware ──► ISR (short) ──► ring buffer / flag / event ──► main loop or task ──► driver logic
```

- The ISR moves data and posts an event; it does not parse protocols or call application code.
- The driver exposes `hal_uart_set_rx_callback(cb)` only if the callback is documented as **running in ISR context**; otherwise the driver posts an event and the callback runs from the main loop.
- Shared state is accessed via atomics, `volatile` plus critical sections, or an SPSC ring buffer (chapters 5 and 6).

---

## 5. Execution models

How the system decides *what runs when*. Pick the simplest one that meets the timing requirements.

| Model | Description | Pros | Cons | Use when |
|---|---|---|---|---|
| **Polling superloop** | `while(1)` checks everything | Trivial, deterministic | Wastes power, latency grows with work | Tiny projects |
| **Superloop + interrupts (foreground/background)** | ISRs set flags or fill buffers, loop processes | Simple, low latency for events | Loop can grow unmanageable, long processing delays everything | Most small to medium firmware |
| **Cooperative scheduler** | Task table with periods, run-to-completion | Predictable, no preemption bugs, low RAM | A long task blocks the others | Periodic duties, no hard multi-deadline needs |
| **Event-driven (event queue + dispatcher / state machines)** | Everything reacts to events; the loop dispatches | Very clean, testable, low power (sleep when queue empty) | Needs discipline: run-to-completion handlers, no blocking | Medium to large systems without an RTOS |
| **Active objects** | Each component owns a thread/queue/state machine (QP framework style) | Isolation, no shared state | More queues and memory | Complex reactive systems |
| **Preemptive RTOS** | Tasks with priorities, queues, mutexes | Meets multiple deadlines, structured concurrency | Stack per task, shared-state hazards, learning curve | Several activities with different timing, networking stacks, USB, file systems |

Notice that the models are not exclusive: an RTOS-based design with a few tasks that each run an event loop is common.

### 5.1 Cooperative periodic scheduler

```c
typedef struct {
    void (*run)(void);
    uint32_t period_ms;
    uint32_t last_ms;
} periodic_task_t;

static periodic_task_t tasks[] = {
    { led_task,    500u, 0u },
    { button_task,  10u, 0u },
    { uart_task,     5u, 0u },
    { adc_task,   1000u, 0u },
};

void scheduler_run(void)
{
    for (;;) {
        uint32_t now = hal_millis();
        for (size_t i = 0; i < sizeof tasks / sizeof tasks[0]; i++) {
            if ((uint32_t)(now - tasks[i].last_ms) >= tasks[i].period_ms) {
                tasks[i].last_ms += tasks[i].period_ms;      /* keeps the average rate exact */
                tasks[i].run();
            }
        }
        hal_wfi();                                            /* sleep until the next interrupt (SysTick at least) */
    }
}
```

Rules: tasks run to completion, never block (no busy-wait delays), and each takes much less than the shortest period. Measure the worst-case execution time with the DWT cycle counter.

### 5.2 Event queue and dispatcher

Events decouple producers (ISRs, timers, drivers) from consumers (application logic).

```c
typedef enum { EV_NONE = 0, EV_BUTTON, EV_TICK_1S, EV_UART_RX, EV_ADC_DONE, EV_COUNT } event_id_t;
typedef struct { event_id_t id; uint32_t arg; } event_t;

#define EVQ_SIZE 16u                                  /* power of two */
static event_t           evq[EVQ_SIZE];
static volatile uint32_t evq_head, evq_tail;

bool event_post(event_id_t id, uint32_t arg)          /* callable from ISRs and main (multiple producers) */
{
    uint32_t pm = hal_irq_save();
    uint32_t next = (evq_head + 1u) & (EVQ_SIZE - 1u);
    bool ok = (next != evq_tail);
    if (ok) { evq[evq_head] = (event_t){ id, arg }; evq_head = next; }
    hal_irq_restore(pm);
    return ok;                                         /* false = queue full: count it, it is a design problem */
}

bool event_get(event_t *ev)                            /* main loop only (single consumer) */
{
    if (evq_tail == evq_head) { return false; }
    *ev = evq[evq_tail];
    evq_tail = (evq_tail + 1u) & (EVQ_SIZE - 1u);
    return true;
}
```

Dispatcher with static subscriber table:

```c
typedef void (*event_handler_t)(const event_t *ev);

#define MAX_SUBSCRIBERS 4u
static event_handler_t subs[EV_COUNT][MAX_SUBSCRIBERS];

bool event_subscribe(event_id_t id, event_handler_t h)
{
    for (unsigned i = 0; i < MAX_SUBSCRIBERS; i++) {
        if (subs[id][i] == NULL) { subs[id][i] = h; return true; }
    }
    return false;
}

void event_dispatch_all(void)
{
    event_t ev;
    while (event_get(&ev)) {
        for (unsigned i = 0; i < MAX_SUBSCRIBERS && subs[ev.id][i]; i++) { subs[ev.id][i](&ev); }
    }
}
```

Main loop:

```c
for (;;) {
    event_dispatch_all();
    hal_irq_disable();
    if (!event_pending()) { hal_wfi(); }       /* sleep only if nothing is pending; WFI wakes even with IRQs masked */
    hal_irq_enable();
}
```

(Sleeping with interrupts masked and `WFI` avoids the race "event arrives between the check and sleep": the pending interrupt wakes the core, then you enable interrupts and its ISR runs. Chapter 3, section 10.)

Design points:

- **Run-to-completion**: a handler finishes before the next event is dispatched. No blocking calls inside.
- Events carry small data (an id plus a word, or a pointer into a static pool). Never pointers to stack variables.
- Count dropped events (queue full) and expose the counter in diagnostics.
- Producers in ISR context use `event_post` (short critical section).

### 5.3 Software timers service

Many "do X in 200 ms" needs become one service on top of `hal_millis`:

```c
typedef struct { uint32_t deadline; uint32_t period; event_id_t ev; bool active; } sw_timer_t;
void swtimer_start_oneshot(sw_timer_t *t, uint32_t ms, event_id_t ev);
void swtimer_start_periodic(sw_timer_t *t, uint32_t ms, event_id_t ev);
void swtimer_poll(void);          /* called from the main loop each iteration; posts events when due */
```

Using events for timeouts keeps the logic in state machines instead of `delay()` calls.

### 5.4 State machines

State machines are the core of reactive firmware. Three levels of implementation:

**1. `switch` on an enum** (small machines, chapters 5 and 6).

**2. Table-driven**: transitions described as data, easy to review and test:

```c
typedef enum { S_IDLE, S_RUN, S_ERROR, S_COUNT } state_t;
typedef enum { E_START, E_STOP, E_FAULT, E_COUNT } fsm_event_t;

typedef struct {
    bool     valid;
    state_t  next;
    void   (*action)(void);
} transition_t;

static const transition_t table[S_COUNT][E_COUNT] = {
    [S_IDLE]  = { [E_START] = { true, S_RUN,   motor_start }, [E_FAULT] = { true, S_ERROR, log_fault } },
    [S_RUN]   = { [E_STOP]  = { true, S_IDLE,  motor_stop  }, [E_FAULT] = { true, S_ERROR, motor_stop } },
    [S_ERROR] = { [E_STOP]  = { true, S_IDLE,  NULL        } },
};

static state_t state = S_IDLE;

void fsm_handle(fsm_event_t ev)
{
    const transition_t *t = &table[state][ev];
    if (!t->valid) { return; }                /* event ignored in this state */
    if (t->action != NULL) { t->action(); }
    state = t->next;
}
```

**3. Hierarchical state machines** (statecharts, e.g. the QP/QM framework): states nested, with entry/exit actions and inherited transitions. Worth it when flat tables explode.

Good practices:

- Keep **one** variable that holds the state, and one function that changes it (`set_state()`), where you log transitions.
- Entry and exit actions for resources (enable a peripheral on entry, disable on exit).
- All time-based behavior through timer events, not blocking delays.
- Test every transition on the host (section 14).
- Draw the diagram (Mermaid or PlantUML) and keep it next to the code.

### 5.5 Deferred interrupt processing ("top half / bottom half")

| Part | Context | Work |
|---|---|---|
| Top half | ISR | Acknowledge hardware, move bytes, post an event |
| Bottom half | Main loop or RTOS task | Parse, decide, call drivers, allocate, print |

Keep an **interrupt priority map** as documentation (and a static check in code if possible):

| IRQ | Priority | Why |
|---|---|---|
| Fault handlers | fixed highest | |
| DMA/UART RX | 2 | Loss of data if late |
| Timer for control loop | 1 | Hard deadline |
| SysTick | lowest among time-critical (e.g. 14) | Time base only |
| PendSV | 15 | Context switch (RTOS) |

---

## 6. Communication between components

| Mechanism | Coupling | Use |
|---|---|---|
| **Direct call** (downward) | Caller knows callee's header | Normal calls to a lower layer |
| **Callback** (upward) | Lower layer holds a function pointer + context | One listener, e.g. "on RX complete" |
| **Observer / pub-sub** | Publisher does not know subscribers | Several listeners; the event queue of 5.2 |
| **Queue / mailbox** | Producer and consumer decoupled in time | Between ISR and main, or between RTOS tasks |
| **Shared variable** | Hidden coupling, race hazards | Avoid, or wrap behind getters with a critical section |
| **Command / request-response** | Request object plus callback | CLI, protocol handlers |

### Callback with context (no globals)

```c
typedef void (*hal_uart_rx_cb_t)(void *ctx, uint8_t byte);
void hal_uart_set_rx_callback(hal_uart_rx_cb_t cb, void *ctx);
```

The `ctx` pointer lets the same function serve several instances without global state.

### Observer with a static list

```c
#define MAX_OBSERVERS 4
typedef void (*observer_fn)(int value);
static observer_fn observers[MAX_OBSERVERS];

bool temp_subscribe(observer_fn f) { for (int i = 0; i < MAX_OBSERVERS; i++) { if (!observers[i]) { observers[i] = f; return true; } } return false; }
static void notify_all(int v)      { for (int i = 0; i < MAX_OBSERVERS; i++) { if (observers[i]) { observers[i](v); } } }
```

### Command pattern: a command-line interface

```c
typedef struct { const char *name; const char *help; int (*handler)(int argc, char **argv); } cli_command_t;

static int cmd_led(int argc, char **argv);
static int cmd_adc(int argc, char **argv);
static int cmd_reboot(int argc, char **argv);

static const cli_command_t commands[] = {
    { "led",    "led <on|off|toggle>", cmd_led    },
    { "adc",    "adc <channel>",       cmd_adc    },
    { "reboot", "reset the MCU",       cmd_reboot },
};
```

The CLI module tokenizes a line, looks up the table and calls the handler. Adding a command is one line of data. It reads from a `stream_t`, so it can be used over UART, USB CDC or a test fake. A CLI is one of the best debugging and manufacturing-test tools you can add.

---

## 7. Memory architecture

### 7.1 Static allocation by design

- Every buffer, queue, pool and instance has a compile-time size.
- **No heap** in the application (trap `operator new`/`malloc` while developing).
- Use **pools** for variable-lifetime objects (messages, packets): fixed-size blocks, O(1), no fragmentation, failure is detectable.

```c
typedef struct block { struct block *next; } block_t;
typedef struct { block_t *free_list; size_t block_size; size_t count; } pool_t;
void  pool_init(pool_t *p, void *mem, size_t block_size, size_t count);
void *pool_alloc(pool_t *p);                         /* NULL if exhausted: handle it */
void  pool_free(pool_t *p, void *b);
```

### 7.2 A memory budget

Keep a table, update it with every feature (read it from the map file):

| Module | Flash (B) | RAM (B) | Stack (B) |
|---|---|---|---|
| startup + libc (nano) | 3000 | 100 | |
| UART driver + buffers | 1200 | 768 | 128 |
| Event queue | 300 | 140 | |
| CLI | 2500 | 200 | 256 |
| `printf` with float | 10000 | | 400 |
| Application | 4000 | 500 | 256 |
| **Total / available** | | | |

Tools: `-Wl,--print-memory-usage`, `arm-none-eabi-nm -S --size-sort`, `-fstack-usage`, stack painting (chapter 4), a CI **size check** that fails the build if Flash or RAM grows beyond a budget.

### 7.3 Where to place things

| Data | Section | Notes |
|---|---|---|
| Constant tables, strings | `.rodata` (Flash) | `static const` |
| DMA buffers | SRAM1/2, 32-byte aligned, or non-cacheable region | Not in DTCM unless DMA can reach it |
| Time-critical code/data | ITCM/DTCM via linker sections | Measure first |
| Data surviving reset | `.noinit` | Fault records, boot counters (chapter 4) |
| Stack | Top of RAM (or DTCM for speed) | Reserve with `_Min_Stack_Size` |

---

## 8. Design patterns that fit embedded systems

| Pattern | Embedded form | Notes |
|---|---|---|
| **Singleton** | A module with `static` state and a header with functions | Do not build a class; one UART is one module. For testing prefer passing an instance |
| **Facade** | `board_init()` hides clock, pins and driver initialization behind one call | Makes `main()` readable |
| **Adapter** | Wrap the vendor HAL or a third-party library to fit your interface | Isolates vendor changes |
| **Strategy** | Ops table or function pointer chosen at init (filter algorithm, bus backend) | |
| **Observer** | Event queue / callback list (section 6) | |
| **State** | Table-driven FSM or one handler function per state | |
| **Command** | Command table for CLI and protocols | |
| **Template method / hooks** | Weak functions (`__attribute__((weak))`) or callbacks for customization points | Used by startup (`Default_Handler`) |
| **Proxy / decorator** | A `stream_t` that filters or timestamps then forwards to another | Logging pipelines |
| **Factory** | Static construction tables, or `board_create_*()` functions returning pre-built instances | No heap |
| **RAII** (C++) | Critical-section guard, peripheral clock guard | Chapter 6 |
| **CRTP / policy-based** (C++) | Compile-time polymorphism | Chapter 6 |
| **Dependency injection** | Pass dependencies as parameters (`sensor_create(bus)`), choose them in `main` | The enabler of tests |
| **Pipeline** | Sensor → filter → scaler → consumer, each stage a small function | Easy to test and tune |

### Composition root

`main.c` is the **only** place that knows all the concrete types and wires them together:

```c
int main(void)
{
    board_init();                                           /* clock, pins, HAL peripherals */

    static const bus_t   i2c_bus = { &stm32_i2c_ops, &i2c1_ctx };
    static sensor_t      sensor;
    sensor_init_static(&sensor, &i2c_bus, 0x48u);           /* inject the dependency */

    app_init(&sensor, &uart_stream);                        /* application gets abstractions only */
    scheduler_run();
}
```

Everything else receives its dependencies as arguments or interfaces. Without that, tests need global state surgery.

---

## 9. Configuration, variants, and generated code

### 9.1 Compile-time configuration

Collect tunables in one header:

```c
/* config.h */
#define CFG_UART_BAUD         115200u
#define CFG_EVENT_QUEUE_SIZE  16u
#define CFG_LOG_LEVEL         LOG_LEVEL_INFO
#define CFG_ENABLE_CLI        1
```

and check them at compile time (`_Static_assert((CFG_EVENT_QUEUE_SIZE & (CFG_EVENT_QUEUE_SIZE - 1u)) == 0u, "power of two")`). Prefer `#if CFG_FEATURE` with 0/1 values over `#ifdef`, and `-Wundef`.

CMake can inject settings from options:

```cmake
option(ENABLE_CLI "Build the command line interface" ON)
target_compile_definitions(firmware PRIVATE CFG_ENABLE_CLI=$<BOOL:${ENABLE_CLI}>)
```

Larger systems use **Kconfig** (the Linux/Zephyr configuration language) instead.

### 9.2 Multiple boards and builds

You already have the pattern: `-DBOARD=...` selects `boards/<name>/board.cmake` that defines architecture flags, defines, startup, linker script and sources. Keep board differences **only** there. Add build types (Debug, Release) and test builds on top.

### 9.3 Version information in the binary

```cmake
execute_process(COMMAND git describe --tags --always --dirty
                WORKING_DIRECTORY ${CMAKE_SOURCE_DIR}
                OUTPUT_VARIABLE FW_VERSION OUTPUT_STRIP_TRAILING_WHITESPACE ERROR_QUIET)
if(NOT FW_VERSION)
  set(FW_VERSION "unknown")
endif()
configure_file(src/common/version.h.in ${CMAKE_BINARY_DIR}/generated/version.h @ONLY)
target_include_directories(firmware PRIVATE ${CMAKE_BINARY_DIR}/generated)
```

`version.h.in`: `#define FW_VERSION "@FW_VERSION@"`. Print it at boot and in the CLI. (A `-dirty` marker is helpful for developers; release builds should come from a clean tag.)

### 9.4 Settings stored in Flash

Persistent configuration needs a **format** and **protection**:

```c
typedef struct {
    uint32_t magic;           /* identifies a valid record */
    uint16_t version;         /* layout version, for migration */
    uint16_t length;
    /* ... fields ... */
    uint32_t crc;             /* over everything above */
} settings_t;
```

Rules: validate magic, version and CRC at boot, fall back to defaults if invalid; write with **two alternating slots** so a power loss during write never destroys the only copy; limit write frequency (Flash endurance, about 10 000 cycles on STM32F7); erase whole sectors (F746: sectors of 32/128/256 KB, so dedicate one).

---

## 10. Error handling, fault tolerance, diagnostics

### 10.1 Error strategy

| Type | Examples | Handling |
|---|---|---|
| **Programmer errors** | Null pointer argument, enum out of range | `ASSERT`: stop in debug, log + safe reset in release |
| **Expected runtime failures** | Timeout, NACK, CRC mismatch | Return `status_t`; retry with limits; degrade gracefully |
| **Environmental faults** | Brown-out, overtemperature, sensor missing | Detect, report, move to a safe state |
| **Software faults** | HardFault, stack overflow, watchdog | Capture evidence in `.noinit`, reset (chapter 4) |

Rules:

- **Check every returned status.** `[[nodiscard]]` (C++) or `__attribute__((warn_unused_result))` makes the compiler help.
- Decide in **one place** what an error means (a policy in the application layer); low-level code reports, it does not decide.
- **Timeouts everywhere**; retries are bounded, with back-off.
- Define the **safe state** of the hardware (outputs off, motor stopped) and apply it on any fatal error. Outputs controlled from a fault handler must not depend on the failing component.
- Watchdog strategy: kick only when **every** critical task reported progress (a flag per task checked in the main loop), never from an ISR.
- Avoid unbounded loops waiting on hardware. Always have `if (timed_out) return ST_ERR_TIMEOUT;`.

### 10.2 Boot-time self-check

At start: print version and reset cause (`RCC->CSR`), verify firmware CRC, check settings validity, report previous fault record, run quick peripheral sanity checks, then start the application.

### 10.3 Health and diagnostics data

A small struct of counters, visible in the debugger and via the CLI:

```c
typedef struct {
    uint32_t uptime_s;
    uint32_t reset_count;
    uint32_t uart_overruns;
    uint32_t event_queue_drops;
    uint32_t i2c_errors;
    uint32_t max_loop_us;          /* worst main-loop iteration, via DWT */
    uint32_t stack_free_min;       /* stack painting high-water mark */
} diag_t;
```

Counters turn "it sometimes fails" into data.

### 10.4 Logging architecture

```c
typedef enum { LOG_ERROR, LOG_WARN, LOG_INFO, LOG_DEBUG } log_level_t;

void log_write(log_level_t lvl, const char *tag, const char *fmt, ...) __attribute__((format(printf, 3, 4)));

#if CFG_LOG_LEVEL >= 2
  #define LOGI(tag, ...)  log_write(LOG_INFO, tag, __VA_ARGS__)
#else
  #define LOGI(tag, ...)  ((void)0)
#endif
```

- Levels, tags and timestamps; compile-time stripping so release builds contain no debug strings.
- **Sinks** are `stream_t`s: UART, ITM/SWO, RTT, RAM ring buffer (read by the debugger after a crash). Logging goes to a ring buffer and is flushed from the main loop, not formatted in ISRs.
- For heavy logging consider **binary logging**: send an id and arguments, and decode on the PC (saves format strings and CPU).

---

## 11. RTOS-based architecture

### 11.1 When an RTOS pays off

- Several independent activities with different timing (control loop at 1 kHz, UI at 20 Hz, network stack, file system).
- Middleware that expects an OS (lwIP, USB stacks, FatFS with blocking I/O).
- You want blocking calls ("wait for 10 ms", "wait for data") without freezing the rest.

It does not pay off for simple periodic work that a cooperative scheduler handles. An RTOS adds stacks (RAM), context-switch overhead, concurrency bugs and configuration.

### 11.2 Building blocks

| Primitive | Use |
|---|---|
| Task | An independent flow with its own stack and priority |
| Queue | Pass messages between tasks or from ISR to task (copy semantics) |
| Binary semaphore / task notification | Signal events from ISRs (lightweight) |
| Mutex | Mutual exclusion with priority inheritance |
| Counting semaphore | Resource counting |
| Software timer | Callbacks in a timer service task |
| Event group | Wait on combinations of flags |

### 11.3 Design rules

1. **Few tasks**, one per concern (communications, sensors, control, UI). Do not create a task per function.
2. **Communicate by queues/notifications**; avoid sharing state. If a datum must be shared, one task **owns** it and others ask by message.
3. **Priorities by deadline** (rate-monotonic reasoning): the task with the shortest deadline gets the highest priority. Few priority levels.
4. Keep ISRs short: use `...FromISR` calls to hand data to a task, and request a context switch at ISR exit.
5. **Size stacks** by measurement (high-water marks) plus margin; remember FPU context adds space.
6. **Avoid long-held mutexes**, never take a mutex in an ISR, beware **priority inversion** (use mutexes with inheritance) and deadlocks (fixed lock order).
7. Never block with unbounded timeouts in production paths.

### 11.4 FreeRTOS on the Cortex-M7: points that matter

- Port: the Cortex-M7 port for GCC (`ARM_CM7/r0p1` in the FreeRTOS kernel tree). Your core is r0p1 (chapter 3). Check the FreeRTOS documentation for your revision and for the **errata notes**.
- It uses **SysTick** (tick), **PendSV** (context switch) and **SVC** (start). Map the handlers in `FreeRTOSConfig.h`:

```c
#define vPortSVCHandler     SVC_Handler
#define xPortPendSVHandler  PendSV_Handler
#define xPortSysTickHandler SysTick_Handler
```

- Interrupt priorities: use all priority bits as preemption priority (`NVIC_SetPriorityGrouping(3)` on STM32, 4 bits). Interrupts that call `...FromISR` functions must have a **numerically greater or equal** priority than `configMAX_SYSCALL_INTERRUPT_PRIORITY` (that is, equal or lower urgency). Higher-urgency interrupts must not call the kernel at all.
- `configPRIO_BITS` = 4 for STM32F7; `configKERNEL_INTERRUPT_PRIORITY` is the lowest priority shifted into the top bits.
- Critical sections use `BASEPRI`, so urgent interrupts keep running (chapter 3).
- Stack sizes in `xTaskCreate` are in **words** (4 bytes).
- Enable `configCHECK_FOR_STACK_OVERFLOW` and `uxTaskGetStackHighWaterMark()` while developing; use the static allocation API (`xTaskCreateStatic`) to avoid the heap.

### 11.5 Skeleton

```c
static QueueHandle_t q_events;

static void sensor_task(void *arg)
{
    (void)arg;
    TickType_t last = xTaskGetTickCount();
    for (;;) {
        vTaskDelayUntil(&last, pdMS_TO_TICKS(100));          /* fixed-rate loop */
        event_t ev = { EV_ADC_DONE, read_sensor() };
        (void)xQueueSend(q_events, &ev, 0);                   /* do not block: count drops */
    }
}

static void app_task(void *arg)
{
    (void)arg;
    event_t ev;
    for (;;) {
        if (xQueueReceive(q_events, &ev, portMAX_DELAY) == pdTRUE) { app_handle(&ev); }
    }
}

void EXTI15_10_IRQHandler(void)                                /* ISR to task */
{
    BaseType_t woken = pdFALSE;
    event_t ev = { EV_BUTTON, 0 };
    EXTI->PR = (1u << 13);
    xQueueSendFromISR(q_events, &ev, &woken);
    portYIELD_FROM_ISR(woken);
}

int main(void)
{
    board_init();
    q_events = xQueueCreate(16, sizeof(event_t));
    xTaskCreate(sensor_task, "sensor", 256, NULL, 2, NULL);   /* 256 words = 1 KB */
    xTaskCreate(app_task,    "app",    384, NULL, 1, NULL);
    vTaskStartScheduler();                                     /* never returns */
}
```

Alternatives: Zephyr (full OS with device tree, drivers, networking), ThreadX/Azure RTOS, RTX/CMSIS-RTOS2 (a standard API over several kernels, useful for portability), or ChibiOS. Wrap OS calls behind a thin `os_*` layer if you want to keep the application portable and testable.

---

## 12. The build system as an architecture enforcer

In CMake, **a library target per module** and the link graph make architecture visible and enforceable:

```cmake
add_library(common      STATIC src/common/status.c src/common/ring_buffer.c)
target_include_directories(common PUBLIC src/common)

add_library(hal_iface   INTERFACE)
target_include_directories(hal_iface INTERFACE src/hal/include)
target_link_libraries(hal_iface INTERFACE common)

add_library(hal_stm32f7 STATIC src/hal/stm32f7/hal_gpio.c src/hal/stm32f7/hal_time.c src/hal/stm32f7/hal_uart.c)
target_link_libraries(hal_stm32f7 PUBLIC hal_iface mcu)           # only this one sees CMSIS

add_library(drivers     STATIC src/drivers/sensor.c src/drivers/led.c src/drivers/button.c)
target_link_libraries(drivers PUBLIC hal_iface)                    # drivers cannot see vendor headers

add_library(services    STATIC src/services/event_queue.c src/services/scheduler.c src/services/log.c)
target_link_libraries(services PUBLIC hal_iface)

add_library(app         STATIC src/app/app.c src/app/fsm.c)
target_link_libraries(app PUBLIC drivers services)

add_executable(firmware src/main.c boards/stm32f746_nucleo/board.c ${BOARD_STARTUP_ASM} ${BOARD_SYSTEM_C})
target_link_libraries(firmware PRIVATE app hal_stm32f7)            # the concrete HAL is chosen here
```

What this enforces:

- `app` includes only headers of `drivers`, `services`, `hal_iface` and `common`. If it tries `#include "stm32f7xx.h"`, the build fails (the include path is not there).
- The HAL implementation is chosen at the top. A host test links `hal_host` instead of `hal_stm32f7`.
- `PUBLIC`/`PRIVATE`/`INTERFACE` (chapter 2) express which dependencies leak through headers.

Visualize and check the graph:

```bash
cmake --graphviz=deps.dot -S . -B build && dot -Tpng deps.dot -o deps.png
```

Pitfalls:

- Startup and vector table stay in the **executable** (not in a static library) or they are dropped by the linker (chapter 2).
- Static libraries with circular dependencies need link groups; a circular dependency is also an architecture smell: fix the design rather than the link line.
- ISRs placed in libraries are only linked if something references them (weak default handler problem): put them in the executable's sources or reference them.
- Keep include directories narrow: a module exposes `include/` (public headers) and keeps private headers next to its sources.

---

## 13. Boot and update architecture (bootloader)

### 13.1 Flash partitioning (STM32F746, 1 MB)

Sectors: 4 x 32 KB (0x08000000..0x0801FFFF), 1 x 128 KB (0x08020000), 3 x 256 KB (0x08040000, 0x08080000, 0x080C0000).

```
0x08000000  ┌────────────────┐
            │ Bootloader     │  sectors 0-1 (64 KB)
0x08010000  ├────────────────┤
            │ Settings (A/B) │  sectors 2-3 (64 KB)
0x08020000  ├────────────────┤
            │ Application    │  sector 4 + 5 ...
            │ (header + code)│
0x080C0000  ├────────────────┤
            │ Update staging │  last sector(s): downloaded image, or a second app slot
0x08100000  └────────────────┘
```

Adjust to your needs; **erase granularity is a whole sector**, so partition on sector boundaries.

### 13.2 Application image header

```c
typedef struct {
    uint32_t magic;          /* 0x46575F31 "FW_1" */
    uint32_t version;        /* semantic version packed */
    uint32_t size;           /* bytes of the image that follow the header */
    uint32_t crc32;          /* over the image (same polynomial as the STM32 CRC unit, chapter 0) */
    uint32_t entry_offset;   /* usually 0: vector table right after the header */
} image_header_t;
```

The linker script of the application starts Flash at the application address (after the header), and `VTOR` must point to the new vector table (`USER_VECT_TAB_ADDRESS` in `system_stm32f7xx.c`, with the table aligned).

### 13.3 Jumping to the application

```c
typedef void (*app_entry_t)(void);

void bootloader_jump(uint32_t app_base)
{
    uint32_t sp = *(volatile uint32_t *)app_base;
    uint32_t pc = *(volatile uint32_t *)(app_base + 4u);

    /* basic sanity checks: SP in RAM, PC in Flash */
    if ((sp & 0xFFF00000u) != 0x20000000u || (pc & 0xFF000000u) != 0x08000000u) { return; }

    __disable_irq();
    SysTick->CTRL = 0u;  SysTick->LOAD = 0u;  SysTick->VAL = 0u;
    for (unsigned i = 0; i < 8u; i++) { NVIC->ICER[i] = 0xFFFFFFFFu; NVIC->ICPR[i] = 0xFFFFFFFFu; }
    /* de-initialize any peripheral the bootloader used (reset it with RCC->xxxRSTR) */
    SCB_DisableDCache();                 /* clean/disable caches so the application starts from a known state */
    SCB_DisableICache();
    __set_CONTROL(0u);
    SCB->VTOR = app_base;                /* the application's vector table */
    __DSB(); __ISB();
    __set_MSP(sp);
    ((app_entry_t)pc)();                 /* never returns */
}
```

Points:

- Leave the hardware in a **reset-like state** so the application's startup assumptions hold.
- Verify the image (magic, size limits, CRC) **before** jumping; keep the bootloader small and thoroughly tested.
- Update safety: **never erase the only valid image** before the new one is verified. Use A/B slots or a staging area, and a "pending/confirmed" flag so the bootloader can roll back if the new image fails to confirm itself.
- Transport: UART with a simple framed protocol (CRC per packet, ACK/NACK), USB DFU, CAN, Ethernet. The ST system bootloader in ROM is available too (BOOT pins/option bytes) as a fallback.
- Security (when it matters): signed images (e.g. ECDSA, Ed25519), read-out protection, secure boot. This is a large topic of its own.

---

## 14. Testing architecture

### 14.1 The test pyramid for firmware

| Level | Where it runs | Tests |
|---|---|---|
| **Unit** (many, fast) | **Host (PC)** | Pure logic: ring buffer, parser, CRC, state machines, filters, drivers with fake buses |
| **Component/integration** | Host with fakes | Several modules together (app + drivers + fake HAL), event sequences, timing via fake clock |
| **On-target** | The board | HAL implementations, DMA, timing, interrupt priorities, electrical behavior |
| **Hardware-in-the-loop (HIL)** | Board plus fixtures | Automated: scripts drive inputs (relays, DAC, serial) and check outputs |
| **System/acceptance** | Real device | End-to-end behavior in the environment |

The architecture of sections 2 to 4 exists to push as much logic as possible into the first two levels.

### 14.2 Fakes, stubs, mocks

| Kind | Role |
|---|---|
| **Stub** | Returns canned values |
| **Fake** | Working simplified implementation (fake clock whose time you set, fake UART with a buffer) |
| **Mock** | Records calls and verifies expectations (CMock/gmock) |

Fakes are usually the most useful and the least brittle for hardware layers.

### 14.3 Frameworks

| Language | Options |
|---|---|
| C | **Unity** + **Ceedling** (+ CMock for mocks), CMocka, Check, minimal asserts |
| C++ | Catch2, doctest, GoogleTest/GoogleMock |
| Driving tests | CTest (part of CMake), `pytest` for HIL scripts |

### 14.4 Host test project

```
tests/
├── CMakeLists.txt
├── test_ring_buffer.c
├── test_fsm.c
├── test_sensor.c
└── fakes/
    ├── hal_gpio_fake.c
    ├── hal_time_fake.c
    └── bus_fake.c
```

`tests/CMakeLists.txt` (host build, no cross toolchain):

```cmake
cmake_minimum_required(VERSION 3.16...4.2)
project(firmware_tests C)
enable_testing()

set(SRC ${CMAKE_CURRENT_SOURCE_DIR}/../src)

function(add_fw_test name)
  add_executable(${name} ${name}.c ${ARGN})
  target_include_directories(${name} PRIVATE ${SRC}/common ${SRC}/hal/include ${SRC}/drivers ${SRC}/services ${SRC}/app)
  target_compile_options(${name} PRIVATE -g -O1 -Wall -Wextra -fsanitize=address,undefined)
  target_link_options(${name}    PRIVATE -fsanitize=address,undefined)
  add_test(NAME ${name} COMMAND ${name})
endfunction()

add_fw_test(test_ring_buffer  ${SRC}/common/ring_buffer.c)
add_fw_test(test_sensor       ${SRC}/drivers/sensor.c fakes/bus_fake.c)
add_fw_test(test_fsm          ${SRC}/app/fsm.c fakes/hal_gpio_fake.c fakes/hal_time_fake.c)
```

```bash
cmake -S tests -B build-host && cmake --build build-host && ctest --test-dir build-host --output-on-failure
```

(Host `int`, `long` and pointer sizes differ from the target. Use fixed-width types and, for 32-bit behavior on the PC, `-m32` if needed.)

Example test with a fake clock:

```c
#include <assert.h>
#include "blinker.h"

extern void     fake_time_set(uint32_t ms);
extern int      fake_gpio_toggles(void);

int main(void)
{
    blinker_t b; blinker_init(&b, /*period*/ 500u);
    fake_time_set(499);  blinker_step(&b);  assert(fake_gpio_toggles() == 0);
    fake_time_set(500);  blinker_step(&b);  assert(fake_gpio_toggles() == 1);
    fake_time_set(0xFFFFFFF0u); blinker_reset(&b);
    fake_time_set(0x00000100u); blinker_step(&b); /* across the 32-bit wrap */
    return 0;
}
```

Edge cases worth a test: tick wrap-around, queue full, empty queue, buffer boundaries, bad checksums, timeouts, simultaneous events, every state-machine transition.

### 14.5 On-target tests

- A tiny test runner on the MCU that prints results on UART (Unity works on targets), launched by CTest/`pytest` over the serial port.
- **Semihosting or SWO** can return results through the debug probe (watch the side effects, chapter 4).
- **Simulation**: **Renode** and **QEMU** run firmware without hardware; coverage of specific STM32 peripherals varies, so check support for your part before relying on it.

### 14.6 Quality gates

- **Compiler warnings** as errors for your code (not for vendor code).
- **Static analysis**: `cppcheck`, `clang-tidy`, GCC `-fanalyzer`.
- **Sanitizers** (ASan/UBSan) on host tests.
- **Coverage**: `gcov`/`lcov` on host tests (`--coverage`); aim at logic and branches, not at a number.
- **Size budget** check in CI.
- **MISRA C** checking if the product requires it (commercial tools or `cppcheck` premium).

---

## 15. Process and engineering practices

### 15.1 Documentation that stays useful

- A short **architecture overview** in `docs/` (layers, folder map, execution model, priority map).
- **ADRs** (architecture decision records): one page per decision with context, choice, alternatives and consequences ("use event queue, no RTOS", "static allocation only").
- **Module headers documented** (purpose, thread/ISR safety, blocking behavior, units), optionally Doxygen.
- **Diagrams as code**: Mermaid or PlantUML in the repo, rendered in review.
- A **hardware notes** file: pin map, jumpers, solder bridges, known board quirks (like the debug pins and the USB stuck state from earlier chapters).

### 15.2 Naming and style

- `module_verb_noun()` function names, `module_t` types, `MODULE_CONSTANT` macros, no names starting with `_` and a capital letter.
- One module = one `.h` and one `.c` with the same stem; private helpers `static`.
- Units in names (`timeout_ms`, `freq_hz`, `temp_mc`) or strong types in C++.
- Formatting with `clang-format` in CI; coding rules from MISRA/CERT/Core Guidelines.

### 15.3 Git and review

- Small commits, conventional messages, a changelog.
- Review checklist: ISR safety, error handling, timeouts, no blocking in handlers, `volatile`/atomics for shared data, units, magic numbers, memory impact, tests added.
- Tags for releases; build the release from a **clean tag** and archive the `.elf`, `.map`, `.bin` together (the ELF is needed for post-mortem analysis, chapter 4).

### 15.4 Continuous integration (example)

```yaml
# .github/workflows/ci.yml  (illustrative; verify actions and package names)
name: ci
on: [push, pull_request]
jobs:
  firmware:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4
      - name: Install toolchain
        run: sudo apt-get update && sudo apt-get install -y gcc-arm-none-eabi binutils-arm-none-eabi libnewlib-arm-none-eabi cmake ninja-build
      - name: Configure
        run: cmake -S . -B build -G Ninja -DCMAKE_BUILD_TYPE=Release -DCMAKE_TOOLCHAIN_FILE=cmake/toolchains/arm-toolchain.cmake
      - name: Build
        run: cmake --build build
      - name: Size report
        run: arm-none-eabi-size build/blink.elf
      - uses: actions/upload-artifact@v4
        with: { name: firmware, path: "build/*.elf\nbuild/*.bin\nbuild/*.map" }
  host-tests:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4
      - run: cmake -S tests -B build-host && cmake --build build-host
      - run: ctest --test-dir build-host --output-on-failure
```

Add: static analysis, a size-regression gate, build matrix (boards x build types), release artifacts, and a nightly HIL job on a self-hosted runner connected to the board.

### 15.5 Safety and standards (awareness)

Depending on the product: IEC 61508 (functional safety), ISO 26262 (automotive), IEC 62304 (medical software), DO-178C (avionics), UL 1998/IEC 60730 (appliances). They add requirements for process, traceability, coding standards and test coverage. Architecture choices here (layering, static allocation, deterministic behavior, fault handling, testability) are the foundation they build upon.

---

## 16. Worked example: layering the current project

Goal: take "LED blink + button + UART + ADC VBAT" and structure it as in sections 2 to 5, testable on the PC.

### 16.1 Interfaces (`src/hal/include`)

```c
/* hal_time.h */
uint32_t hal_millis(void);

/* hal_irq.h */
uint32_t hal_irq_save(void);
void     hal_irq_restore(uint32_t state);
void     hal_wfi(void);

/* hal_gpio.h : as in section 3.1 */

/* hal_adc.h */
status_t hal_adc_read_vbat_raw(uint16_t *raw);
```

### 16.2 Application logic (pure, host-testable)

```c
/* src/app/blinker.h */
typedef struct { uint32_t last_ms; uint32_t period_ms; hal_pin_t pin; } blinker_t;
void blinker_init(blinker_t *b, hal_pin_t pin, uint32_t period_ms);
void blinker_step(blinker_t *b);

/* src/app/blinker.c */
#include "blinker.h"
#include "hal_gpio.h"
#include "hal_time.h"

void blinker_init(blinker_t *b, hal_pin_t pin, uint32_t period_ms)
{
    b->pin = pin; b->period_ms = period_ms; b->last_ms = hal_millis();
    hal_gpio_configure(pin, HAL_GPIO_OUTPUT, HAL_GPIO_NOPULL);
}

void blinker_step(blinker_t *b)
{
    if ((uint32_t)(hal_millis() - b->last_ms) >= b->period_ms) {
        b->last_ms += b->period_ms;
        hal_gpio_toggle(b->pin);
    }
}
```

### 16.3 Battery monitor service

```c
/* src/services/battery.c */
status_t battery_read_mv(uint32_t *mv)
{
    uint16_t raw;
    RETURN_IF_ERR(hal_adc_read_vbat_raw(&raw));
    *mv = ((uint32_t)raw * 3300u * 4u) / 4095u;     /* VBAT/4 divider, VDDA = 3.3 V (chapter 7) */
    return ST_OK;
}
```

Unit-test it with a fake `hal_adc_read_vbat_raw()` returning 0, 2048, 4095, and an error.

### 16.4 Application and composition

```c
/* src/app/app.c : reacts to events, owns policy */
static void on_button(const event_t *ev)   { (void)ev; LOGI("app", "button pressed"); }
static void on_tick_1s(const event_t *ev)  { (void)ev; uint32_t mv; if (battery_read_mv(&mv) == ST_OK) { LOGI("app", "vbat=%lu mV", (unsigned long)mv); } }

void app_init(void)
{
    event_subscribe(EV_BUTTON,   on_button);
    event_subscribe(EV_TICK_1S,  on_tick_1s);
}
```

```c
/* src/main.c : composition root */
int main(void)
{
    board_init();                          /* clock 216 MHz, pins, SysTick, UART (chapter 7) */
    log_init(&uart_stream);
    static blinker_t blue;
    blinker_init(&blue, PIN_LED_BLUE, 500u);
    app_init();

    for (;;) {
        blinker_step(&blue);
        swtimer_poll();                    /* posts EV_TICK_1S etc. */
        event_dispatch_all();
        sleep_if_idle();
    }
}
```

### 16.5 The dependency rule at a glance

```
main  ──►  app, board, hal_stm32f7
app   ──►  services, drivers
services/drivers ──►  hal interfaces, common
hal_stm32f7 ──►  CMSIS            (only here)
tests ──►  app, services, drivers, hal fakes    (no CMSIS, no cross compiler)
```

Run the host tests on every change; flash the board only for integration checks.

---

## 17. Anti-patterns

| Anti-pattern | Why it hurts | Instead |
|---|---|---|
| God `main.c` with everything inline | Untestable, unreadable | Modules, composition root |
| Registers touched from application code | Locks the code to one chip, impossible to test | HAL interface, drivers |
| Global variables as the integration mechanism | Hidden coupling, races with ISRs | Module state `static`, accessors, events |
| Long ISRs doing real work | Latency, priority problems | Top half / bottom half |
| Blocking `delay()` in the main flow | Everything else stops | Timers and events |
| `malloc`/heap in long-running firmware | Fragmentation, nondeterminism | Static allocation, pools |
| Unbounded waits on hardware | Hangs | Timeouts, error returns |
| Ignoring return values | Silent failure | `status_t`, `[[nodiscard]]`, review |
| Circular dependencies between modules | Cannot test or reuse one without the other | Reverse with events/callbacks, introduce an interface |
| "Utility" module that everyone depends on and that depends on everything | Hidden big ball of mud | Small focused common modules |
| Abstracting everything "for the future" | More code, more bugs | Abstract at real seams (second implementation, tests) |
| Copy-pasted drivers per board | Divergence | One driver, board config |
| Business logic in HAL implementations | Cannot test, cannot port | Keep HAL thin |
| Debug-only behavior that changes timing | Heisenbugs | Same code in debug and release where possible; log through ring buffers |
| No watchdog or fault handler strategy | Field failures with no data | Chapter 4 post-mortem plus watchdog policy |

---

## 18. Lab exercises

Refactoring:

1. **Draw the current architecture** of your project (files and who calls whom). Mark every place where application code touches registers.
2. **Introduce `hal_gpio` and `hal_time`** with the link-time seam. Port `led.c` and `button.c` to use them.
3. **Create `hal/host` fakes** and compile `blinker.c` on the PC with a test that checks wrap-around of the 32-bit time.
4. **Layered CMake**: one library per layer as in section 12; verify with `cmake --graphviz` and prove the rule by making `app` include `stm32f7xx.h` and watching the build fail.

Execution models:

5. **Cooperative scheduler** (5.1) running LED, button and UART tasks; measure each task's worst-case time with DWT.
6. **Event queue and dispatcher** (5.2): ISRs post events, `main` dispatches, sleep in `WFI` when idle. Count dropped events under a flood.
7. **Software timers**: implement `swtimer` and replace every `delay_ms` in your project.
8. **Table-driven FSM** for a protocol or a user-interface sequence; write a test for **every** transition and for ignored events.

Components:

9. **Bus abstraction**: write `bus_t`, a fake bus, and a sensor driver tested only on the PC; later back it with `hal_i2c`.
10. **Stream abstraction**: make `log` write to `stream_t` sinks (UART, ring buffer, ITM) and select the sink at boot.
11. **CLI** over UART with a command table (`help`, `led`, `adc`, `diag`, `reboot`), reading from a `stream_t`, tested on the host with a fake stream.
12. **Settings in Flash** with two slots, magic/version/CRC, power-loss test (reset in the middle of a write).

Robustness:

13. **Diagnostics**: add the `diag_t` counters, expose them via the CLI, and make queue drops and UART overruns visible.
14. **Watchdog policy**: each component reports progress; the main loop kicks the IWDG only if all did; simulate a hang and read the reset cause and fault record after reboot.
15. **Memory budget**: build the table in 7.2 from the map file, then add a CI check that fails if Flash grows beyond a limit.

Larger systems:

16. **Port to FreeRTOS**: tasks for sensor, app and console, queues for events, ISR to task hand-off, stack high-water-mark printout.
17. **Bootloader**: a minimal bootloader in sectors 0-1 that verifies an application image header and CRC and jumps; app linked at its own address with `VTOR` set; test a corrupt image.
18. **CI**: add the GitHub Actions workflow (or GitLab CI) building firmware and running host tests with sanitizers; upload the `.elf` and `.map` as artifacts.

---

## 19. Cheat sheet

### Layers and rules

```
app → services → drivers → HAL interface → HAL implementation → CMSIS → hardware
 calls go down, events go up; vendor headers only in HAL implementation and board
```

### Choosing

| Question | Answer |
|---|---|
| How do I swap hardware for tests? | Link-time seam (fake `.c`) by default; ops table when runtime choice is needed |
| How do modules talk? | Direct call down, callback/event up, queue between contexts |
| How do I organize time? | Cooperative scheduler or event queue for small systems; RTOS when deadlines and middleware need it |
| How do I model behavior? | Table-driven state machines driven by events and timers |
| How do I allocate? | Statically, pools for dynamic lifetime, no heap |
| How do I handle errors? | `status_t`, timeouts, central policy, safe state, record faults, watchdog |
| How do I test? | Host unit tests with fakes and sanitizers, then on-target and HIL |
| How do I keep rules honest? | Library per layer, narrow include paths, CI gates |

### New module checklist

1. One purpose, one `.h`/`.c` pair, private helpers `static`.
2. Interface documented: context (ISR/main/task), blocking, units, ownership.
3. Depends only downward; vendor types absent from the header.
4. No hardware access in constructors/`init` that other modules rely on implicitly.
5. All waits have timeouts; all statuses are checked.
6. State is `static` or instance-based; shared data handled safely.
7. Fake or test seam available; unit tests written.
8. Memory use added to the budget.

### ISR checklist

Short; clears the source; posts an event or fills a buffer; no blocking; no `printf`; priority documented; shared variables safe.

---

## 20. Map of all the notes and where to go next

| Chapter | File |
|---|---|
| 0. Toolchain: compilation, linker, startup | `0_toolchain_notes.md` |
| 1. Make | `make_notes.md` |
| 2. CMake | `2_cmake_notes.md` |
| 3. Cortex-M architecture | `cortex_m_notes.md` |
| 4. Debugging | `debugging_notes.md` |
| 5. C for embedded | `c_embedded_notes.md` |
| 6. C++ for embedded | `cpp_embedded_notes.md` |
| 7. Peripherals | `peripherals_notes.md` |
| 8. Architecture and patterns | `architecture_notes.md` |

Suggested way to keep them together in a repository:

```
notes/
├── 00_toolchain.md
├── 01_make.md
├── 02_cmake.md
├── 03_cortex_m.md
├── 04_debugging.md
├── 05_c.md
├── 06_cpp.md
├── 07_peripherals.md
├── 08_architecture.md
└── examples/              # real, compiling code for every chapter
```

To build one book (for LibreOffice or PDF):

```bash
pandoc notes/0*.md -o embedded_notes.pdf --toc --highlight-style=tango
pandoc notes/0*.md -o embedded_notes.odt --toc
```

### Natural next topics

| Topic | Why |
|---|---|
| **RTOS in depth** (FreeRTOS or Zephyr) | Scheduling theory, priority inversion, tracing (SystemView), stack sizing, lwIP/USB integration |
| **Connectivity** | USB CDC/MSC, CAN/CAN-FD, Ethernet with lwIP, Modbus, MQTT over TCP |
| **Low power design** | Stop/Standby with RTC wake-up, measuring microamps, power budgets |
| **DSP and control** | CMSIS-DSP, filters, FFT, PID controllers, fixed-point arithmetic, motor control with TIM1 |
| **Bootloaders, OTA and security** | Signed images, secure boot, read-out protection, TrustZone-class MCUs (M33) |
| **Hardware design basics** | Schematics, decoupling, ADC layout, EMC, reading datasheets and errata |
| **Testing and CI maturity** | HIL rigs, coverage, fuzzing parsers, static analysis policy |
| **Safety standards** | MISRA, IEC 61508/62304/26262, traceability |
| **Other cores** | Cortex-M33/M55, RISC-V, Arm Cortex-A boot, Linux on MCUs |

### A final suggestion

Pick **one real project** (a data logger, a small controller, a sensor node) and build it using this stack end to end: board bring-up (chapter 7), layered code (this chapter), host tests, CI, a bootloader, and field diagnostics. Nothing consolidates the notes like shipping something that runs unattended for a month.

## References

- *Embedded Systems Architecture*, Daniele Lacamera
- *Making Embedded Systems*, Elecia White
- *Test Driven Development for Embedded C*, James Grenning
- *Practical UML Statecharts in C/C++*, Miro Samek (QP framework: <https://www.state-machine.com>)
- *Mastering the FreeRTOS Real Time Kernel*: <https://www.freertos.org/Documentation/>
- *Clean Architecture*, Robert C. Martin (principles; adapt them to constrained systems)
- *Professional CMake*, Craig Scott
- *Embedded Template Library* documentation: <https://www.etlcpp.com>
- ThrowTheSwitch (Unity, CMock, Ceedling): <https://www.throwtheswitch.org>
- Memfault *Interrupt* blog: <https://interrupt.memfault.com> (practical articles on fault analysis, bootloaders, build systems, CI)
- C++ Core Guidelines: <https://isocpp.github.io/CppCoreGuidelines/>