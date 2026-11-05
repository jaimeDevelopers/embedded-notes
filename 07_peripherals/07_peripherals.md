# 7. Peripherals on the STM32F746ZG (register level)

Board: NUCLEO-F746ZG (MB1137). Code style: C with CMSIS device headers (`stm32f7xx.h`), no HAL. The same techniques apply in C++ (chapter 6) with templates around the register accesses.

Prerequisites: chapter 0 (startup, `SystemInit`), chapter 3 (NVIC, SysTick, barriers, caches), chapter 4 (Peripherals panel, logic analyzer), chapter 5 (`volatile`, bit manipulation).

**Verification warning.** Register names, pin numbers, alternate functions, DMA stream/channel mappings and calibration addresses below come from my memory of RM0385, the F746 datasheet and UM1974. The code is written to be correct but **has not been compiled or run on your board**. Treat every table of pins, AF numbers and DMA requests as "check against the reference manual before use". Where this matters, the text says so.

---

## 1. How to approach any peripheral

### 1.1 Documents

| Document | Contains |
|---|---|
| **RM0385** reference manual | Every register, bit, timing and block diagram. The truth about behavior |
| **Datasheet** (STM32F745xx/F746xx) | Pin list, **alternate function table**, electrical limits, ADC accuracy, absolute maximums |
| **PM0253** programming manual | The Cortex-M7 core |
| **UM1974** Nucleo-144 user manual | Which pin goes where on the board, solder bridges, ST-LINK connections |
| **STM32CubeMX** (just as a reference) | Pin/AF assistant, clock tree calculator, I2C timing calculator |
| **SVD file** | Register definitions for the debugger's Peripherals panel |

### 1.2 The standard bring-up sequence

Almost every peripheral follows these steps:

1. **Enable the peripheral clock** in RCC (`AHB1ENR`, `APB1ENR`, `APB2ENR`...) and read it back.
2. **Configure the pins** (GPIO mode, alternate function, speed, pull).
3. **Configure the peripheral** while it is disabled (baud rate, prescaler, mode, channel).
4. **Configure interrupts/DMA** (peripheral enable bits, NVIC priority, handlers).
5. **Enable the peripheral** (`UE`, `EN`, `ADON`, `CEN`...) last.
6. **Use it**, checking status flags with timeouts and handling errors.
7. If it misbehaves, reset it through `RCC->xxxRSTR` and start again.

Skipping step 1 gives silent failures or bus faults (chapter 3).

### 1.3 Reading a register description

For each register, look at:

- **Address offset** from the peripheral base.
- **Reset value**: what you have before touching anything.
- **Access type** of every bit: `rw`, `r`, `w`, `rc_w1` (clear by writing 1), `rc_w0` (clear by writing 0), `rs` (set by writing 1), `t` (toggle).
- Reserved bits: keep them at reset value (use read-modify-write or `MODIFY_REG`).
- Notes such as "must be written when UE = 0".

CMSIS provides `<PERIPH>_<REG>_<FIELD>` masks plus `_Pos`, e.g. `RCC_AHB1ENR_GPIOBEN`, `USART_CR1_UE`, `TIM_CR1_CEN`. Use them instead of magic numbers.

### 1.4 Where things live

| Bus | Max clock | Peripherals (selection) |
|---|---|---|
| AHB1 | 216 MHz | GPIOA-K, CRC, DMA1, DMA2, Ethernet, USB HS |
| AHB2 | 216 MHz | DCMI, USB FS, RNG |
| APB1 | 54 MHz | TIM2-7, TIM12-14, WWDG, SPI2/3, USART2/3, UART4/5/7/8, I2C1-3, CAN, DAC, PWR |
| APB2 | 108 MHz | TIM1/8/9/10/11, USART1/6, SPI1/4/5/6, ADC1-3, SYSCFG, EXTI, SDMMC1, SAI |

| Peripheral | Base address (verify in RM0385) |
|---|---|
| GPIOA, GPIOB, GPIOC, GPIOD ... | `0x40020000`, `0x40020400`, `0x40020800`, `0x40020C00` ... (+0x400 each) |
| RCC | `0x40023800` |
| FLASH interface | `0x40023C00` |
| DMA1 / DMA2 | `0x40026000` / `0x40026400` |
| CRC | `0x40023000` |
| TIM2 / TIM3 / TIM4 / TIM6 | `0x40000000` / `0x40000400` / `0x40000800` / `0x40001000` |
| USART3 | `0x40004800` |
| I2C1 | `0x40005400` |
| PWR | `0x40007000` |
| ADC1 | `0x40012000` |
| SPI1 | `0x40013000` |
| SYSCFG / EXTI | `0x40013800` / `0x40013C00` |
| IWDG | `0x40003000` |

CMSIS names them: `GPIOB`, `RCC`, `USART3`, `TIM4`, `ADC1`, `DMA1`, and the `_BASE` constants (`GPIOB_BASE`).

---

## 2. Project structure for the drivers

A layout that matches what you already built:

```
src/
├── main.c
├── board/
│   ├── clock.c  clock.h        # PLL, flash latency, bus prescalers
│   └── pins.h                  # LED, button, UART pin definitions in one place
└── drivers/
    ├── gpio.c  gpio.h          # generic pin configuration
    ├── systick.c               # millis()
    ├── uart.c  uart.h          # USART3 + ring buffers (+ DMA later)
    ├── button.c                # EXTI + debounce
    ├── timer.c                 # PWM, periodic tick
    ├── adc.c                   # polling, VBAT, temperature
    └── watchdog.c
```

`pins.h` keeps the board knowledge in one file:

```c
#ifndef PINS_H
#define PINS_H
#include "stm32f7xx.h"

/* Nucleo-144 (MB1137): verify against UM1974 */
#define LED_GREEN_PORT   GPIOB
#define LED_GREEN_PIN    0u        /* LD1 */
#define LED_BLUE_PORT    GPIOB
#define LED_BLUE_PIN     7u        /* LD2 */
#define LED_RED_PORT     GPIOB
#define LED_RED_PIN      14u       /* LD3 */

#define BUTTON_PORT      GPIOC
#define BUTTON_PIN       13u       /* B1 USER button */

#define VCP_TX_PORT      GPIOD     /* USART3 to ST-LINK virtual COM port */
#define VCP_TX_PIN       8u
#define VCP_RX_PORT      GPIOD
#define VCP_RX_PIN       9u
#define VCP_AF           7u

#endif
```

---

## 3. Clock tree

### 3.1 Sources

| Source | Frequency | Notes |
|---|---|---|
| HSI | 16 MHz | Internal RC, default after reset, about 1% accuracy |
| HSE | Crystal or external clock | On the Nucleo-144 the default is an **8 MHz clock from the ST-LINK MCO** (bypass mode). Check UM1974 for the solder bridges if you changed the board |
| PLL | VCO from HSE or HSI | Produces SYSCLK (up to 216 MHz) and the 48 MHz clock for USB/RNG |
| LSI | about 32 kHz | Independent watchdog, optional RTC |
| LSE | 32.768 kHz crystal | RTC (Nucleo has the crystal fitted) |

### 3.2 PLL formulas

```
f(VCO input) = f(PLL source) / PLLM          must be 1 to 2 MHz (2 MHz recommended)
f(VCO)       = f(VCO input) * PLLN           must be 192 to 432 MHz
SYSCLK       = f(VCO) / PLLP                 PLLP in {2, 4, 6, 8}, max 216 MHz
48 MHz clock = f(VCO) / PLLQ                 PLLQ 2..15
```

For **216 MHz** with 8 MHz HSE: `PLLM = 4` (2 MHz), `PLLN = 216` (432 MHz VCO), `PLLP = 2` (216 MHz), `PLLQ = 9` (48 MHz exactly: 432 / 9).

With HSI as source: `PLLM = 8` (2 MHz), the rest identical (HSI accuracy is not enough for USB, but fine for general use).

### 3.3 Limits

| Item | Limit at 216 MHz |
|---|---|
| SYSCLK / AHB (HCLK) | 216 MHz, requires **Over-drive** mode (above 180 MHz) |
| APB1 (PCLK1) | 54 MHz max, so prescaler **/4** |
| APB2 (PCLK2) | 108 MHz max, so prescaler **/2** |
| Flash wait states | **7** at 2.7 to 3.6 V (the datasheet table gives the exact number for your supply and frequency) |
| Timer clocks | If the APB prescaler is not 1, timer clock = **2 x PCLK**: APB1 timers 108 MHz, APB2 timers 216 MHz |

### 3.4 The sequence (HSE bypass to 216 MHz)

The order matters: raise the flash latency and voltage capability **before** switching to the fast clock.

```c
#include "stm32f7xx.h"
#include <stdbool.h>

static bool wait_for(volatile uint32_t *reg, uint32_t mask, uint32_t timeout_loops)
{
    while (((*reg) & mask) == 0u) {
        if (timeout_loops-- == 0u) { return false; }
    }
    return true;
}

bool clock_init_216mhz(void)
{
    /* 1. Power controller clock, needed for over-drive */
    RCC->APB1ENR |= RCC_APB1ENR_PWREN;
    (void)RCC->APB1ENR;

    /* 2. HSE in bypass mode (clock supplied by ST-LINK, no crystal) */
    RCC->CR |= RCC_CR_HSEBYP | RCC_CR_HSEON;
    if (!wait_for(&RCC->CR, RCC_CR_HSERDY, 100000u)) { return false; }

    /* 3. PLL configuration (must be done while the PLL is off) */
    RCC->PLLCFGR = (4u   << RCC_PLLCFGR_PLLM_Pos)   /* /4  -> 2 MHz   */
                 | (216u << RCC_PLLCFGR_PLLN_Pos)   /* x216 -> 432 MHz */
                 | (0u   << RCC_PLLCFGR_PLLP_Pos)   /* 00 = /2 -> 216 MHz */
                 | (9u   << RCC_PLLCFGR_PLLQ_Pos)   /* /9  -> 48 MHz  */
                 | RCC_PLLCFGR_PLLSRC_HSE;
    RCC->CR |= RCC_CR_PLLON;
    if (!wait_for(&RCC->CR, RCC_CR_PLLRDY, 100000u)) { return false; }

    /* 4. Over-drive: required above 180 MHz */
    PWR->CR1 |= PWR_CR1_ODEN;
    if (!wait_for(&PWR->CSR1, PWR_CSR1_ODRDY, 100000u)) { return false; }
    PWR->CR1 |= PWR_CR1_ODSWEN;
    if (!wait_for(&PWR->CSR1, PWR_CSR1_ODSWRDY, 100000u)) { return false; }

    /* 5. Flash: 7 wait states, ART accelerator and prefetch on */
    FLASH->ACR = FLASH_ACR_LATENCY_7WS | FLASH_ACR_ARTEN | FLASH_ACR_PRFTEN;

    /* 6. Bus prescalers: AHB /1, APB1 /4 (54 MHz), APB2 /2 (108 MHz) */
    RCC->CFGR = (RCC->CFGR & ~(RCC_CFGR_HPRE | RCC_CFGR_PPRE1 | RCC_CFGR_PPRE2))
              | RCC_CFGR_HPRE_DIV1 | RCC_CFGR_PPRE1_DIV4 | RCC_CFGR_PPRE2_DIV2;

    /* 7. Switch SYSCLK to the PLL and wait for confirmation */
    RCC->CFGR = (RCC->CFGR & ~RCC_CFGR_SW) | RCC_CFGR_SW_PLL;
    if (!wait_for(&RCC->CFGR, RCC_CFGR_SWS_PLL, 100000u)) { return false; }

    SystemCoreClockUpdate();            /* SystemCoreClock must now read 216000000 */
    return true;
}
```

Notes and checks:

- `SystemCoreClockUpdate()` in `system_stm32f7xx.c` uses `HSE_VALUE`. It defaults to 25 MHz in the ST file, so define `HSE_VALUE=8000000` (`-DHSE_VALUE=8000000UL`) or `SystemCoreClock` will be wrong. A wrong `SystemCoreClock` breaks SysTick, UART and timers silently.
- The `wait_for` loops count iterations, not time. After the PLL is running, a given loop count lasts a shorter time. For a real timeout use a hardware timer (SysTick/DWT) or generous counts.
- If the PLL does not lock, the board stays on HSI and the function returns `false`: show it with an LED.
- Verify with the debugger: `RCC->CFGR` field `SWS` (= `0b10` for PLL), `RCC->CR` bits `PLLRDY`, and measure a known frequency (a 1 kHz toggle with a logic analyzer, or `MCO1` below).

### 3.5 Output the clock on a pin (MCO)

Excellent for checking clocks with a scope or logic analyzer: PA8 (`MCO1`, AF0) can output HSI, HSE or the PLL divided by 1 to 5 (`RCC->CFGR` fields `MCO1` and `MCO1PRE`).

### 3.6 After changing the clock, reconfigure everything that depends on it

| Item | Update |
|---|---|
| SysTick | `SysTick_Config(SystemCoreClock / 1000)` |
| UART baud | `BRR` from the new PCLK |
| Timers | Prescaler/ARR from the new timer clock |
| ADC | `ADCPRE` so the ADC clock is at most 36 MHz |
| `CPU_HZ` compile-time constants | Update or replace with `SystemCoreClock` |
| `SWO` trace | `cpuFrequency` in Cortex-Debug |

Best practice: call `clock_init_216mhz()` as the **first thing in `main`** (or in `SystemInit` replacement), then initialize peripherals.

---

## 4. GPIO

### 4.1 Registers

| Register | Purpose |
|---|---|
| `MODER` | 2 bits per pin: 00 input, 01 output, 10 alternate function, 11 analog (reset state for most pins is input; on port A/B the debug pins differ) |
| `OTYPER` | 0 push-pull, 1 open-drain |
| `OSPEEDR` | 2 bits: low, medium, high, very high (slew rate; faster edges need cleaner PCB and more EMI) |
| `PUPDR` | 2 bits: none, pull-up, pull-down |
| `IDR` | Input data (read) |
| `ODR` | Output data |
| `BSRR` | Atomic set (bits 0-15) and reset (bits 16-31) |
| `LCKR` | Lock configuration |
| `AFR[0]`, `AFR[1]` | 4 bits per pin: alternate function number (AFRL for pins 0-7, AFRH for 8-15) |

### 4.2 Generic helper

```c
#include "stm32f7xx.h"
#include <stdint.h>
#include <stdbool.h>

typedef enum { GPIO_MODE_IN = 0u, GPIO_MODE_OUT = 1u, GPIO_MODE_AF = 2u, GPIO_MODE_ANALOG = 3u } gpio_mode_t;
typedef enum { GPIO_PULL_NONE = 0u, GPIO_PULL_UP = 1u, GPIO_PULL_DOWN = 2u } gpio_pull_t;
typedef enum { GPIO_SPEED_LOW = 0u, GPIO_SPEED_MEDIUM = 1u, GPIO_SPEED_HIGH = 2u, GPIO_SPEED_VERY_HIGH = 3u } gpio_speed_t;

void gpio_config(GPIO_TypeDef *port, unsigned pin, gpio_mode_t mode,
                 gpio_pull_t pull, gpio_speed_t speed, bool open_drain, unsigned af)
{
    /* clock for this port: GPIOxEN bits are consecutive from bit 0 (A=0, B=1, ...) */
    unsigned idx = (unsigned)(((uintptr_t)port - GPIOA_BASE) / 0x400u);
    RCC->AHB1ENR |= (RCC_AHB1ENR_GPIOAEN << idx);
    (void)RCC->AHB1ENR;

    port->PUPDR   = (port->PUPDR   & ~(3u << (pin * 2u))) | ((unsigned)pull  << (pin * 2u));
    port->OSPEEDR = (port->OSPEEDR & ~(3u << (pin * 2u))) | ((unsigned)speed << (pin * 2u));
    port->OTYPER  = (port->OTYPER  & ~(1u << pin))        | ((open_drain ? 1u : 0u) << pin);

    if (mode == GPIO_MODE_AF) {
        unsigned reg = pin >> 3, shift = (pin & 7u) * 4u;
        port->AFR[reg] = (port->AFR[reg] & ~(0xFu << shift)) | (af << shift);
    }
    port->MODER = (port->MODER & ~(3u << (pin * 2u))) | ((unsigned)mode << (pin * 2u));   /* mode last */
}

static inline void gpio_set(GPIO_TypeDef *p, unsigned pin)    { p->BSRR = 1u << pin; }
static inline void gpio_clear(GPIO_TypeDef *p, unsigned pin)  { p->BSRR = 1u << (pin + 16u); }
static inline bool gpio_read(GPIO_TypeDef *p, unsigned pin)   { return (p->IDR & (1u << pin)) != 0u; }
```

Order: set the pull, speed, type and alternate function **before** switching `MODER`, so the pin never shows a glitch in an intermediate state.

### 4.3 Practical rules

- **Never leave inputs floating.** A floating input draws extra current and reads noise. Use a pull or an external resistor. Unused pins: analog mode (lowest leakage) or output low.
- **Open-drain** (I2C, wired-AND buses, level translators): needs an external or internal pull-up.
- **Speed**: use the slowest speed that meets your timing (less EMI, less ground bounce). `LOW` is fine for LEDs and buttons.
- **Current limits**: a pin sources/sinks a few mA (check datasheet limits for per-pin and total). Drive LEDs with series resistors, loads through transistors.
- **5 V tolerance**: only pins marked "FT" in the pin table; never apply 5 V to analog pins, to VBAT, or when VDD is off.
- **Debug pins**: PA13 (SWDIO), PA14 (SWCLK), PB3 (SWO) have their alternate function after reset. Reconfiguring them can lock you out of the debugger (chapter 4, section 8).
- Atomic updates use `BSRR`; `ODR ^=` is read-modify-write (fine if only one context uses that port).
- Pin map of the Nucleo-144 (verify in UM1974): LD1 green PB0, LD2 blue PB7, LD3 red PB14, B1 user button PC13. On this board B1 reads **high when pressed** (external pull-down): verify on your board.

### 4.4 Alternate function selection

Every peripheral signal has specific pins and AF numbers. They are in the **datasheet alternate function table**, not in the reference manual. Example values used below (verify them):

| Signal | Pin | AF |
|---|---|---|
| USART3_TX / USART3_RX (to ST-LINK VCP) | PD8 / PD9 | AF7 |
| TIM4_CH2 | PB7 | AF2 |
| TIM3_CH3 | PB0 | AF2 |
| I2C1_SCL / I2C1_SDA | PB8 / PB9 | AF4 |
| SPI1_SCK / MISO / MOSI | PA5 / PA6 / PA7 | AF5 |
| MCO1 | PA8 | AF0 |
| ADC inputs | PAx/PBx/PCx marked ADCx_INy | Analog mode (no AF) |

CubeMX is a handy second opinion for which pins can serve each function.

---

## 5. External interrupts (EXTI) and the user button

Each of the 16 EXTI lines (0-15) can be connected to the same pin number of any port. PC13 uses **line 13**, which is handled by `EXTI15_10_IRQn`.

```c
#include "stm32f7xx.h"
#include "pins.h"

void button_init(void)
{
    gpio_config(BUTTON_PORT, BUTTON_PIN, GPIO_MODE_IN, GPIO_PULL_NONE, GPIO_SPEED_LOW, false, 0);

    RCC->APB2ENR |= RCC_APB2ENR_SYSCFGEN;               /* SYSCFG routes pins to EXTI */
    (void)RCC->APB2ENR;

    /* EXTICR[3] covers lines 12..15; line 13 uses bits 7:4; port C = 2 */
    SYSCFG->EXTICR[3] = (SYSCFG->EXTICR[3] & ~(0xFu << 4)) | (2u << 4);

    EXTI->RTSR |= (1u << 13);                           /* rising edge (pressed = high) */
    EXTI->FTSR &= ~(1u << 13);
    EXTI->PR    = (1u << 13);                           /* clear any pending flag first (write 1) */
    EXTI->IMR  |= (1u << 13);                           /* unmask the line */

    NVIC_SetPriority(EXTI15_10_IRQn, 6);
    NVIC_EnableIRQ(EXTI15_10_IRQn);
}

static volatile uint32_t g_button_time_ms;
static volatile bool     g_button_event;

void EXTI15_10_IRQHandler(void)
{
    if (EXTI->PR & (1u << 13)) {
        EXTI->PR = (1u << 13);                          /* clear by writing 1 */
        uint32_t now = millis();
        if ((uint32_t)(now - g_button_time_ms) >= 30u) {   /* ignore bounces within 30 ms */
            g_button_time_ms = now;
            g_button_event = true;
        }
    }
}

bool button_event_pending(void)
{
    if (g_button_event) { g_button_event = false; return true; }
    return false;
}
```

Details:

- The pending flag **must** be cleared in the handler (write 1 to `EXTI->PR`), or the interrupt re-triggers immediately.
- The same handler serves lines 10 to 15: always check which line fired.
- Debounce in the ISR by ignoring edges that follow too closely, or by starting a timer and re-reading the pin when it fires. Never block in the ISR.
- Lines 0 to 4 have their own handlers (`EXTI0_IRQn`...), lines 5-9 share `EXTI9_5_IRQn`.
- `g_button_event = false` after the check is a read-then-write on a flag set by an ISR: with a single flag it can lose an event that arrives between the two lines. Use a counter, or a critical section, if events must not be lost.

---

## 6. Time base: SysTick (summary)

```c
static volatile uint32_t g_ms;
void SysTick_Handler(void) { g_ms++; }
uint32_t millis(void) { return g_ms; }
void systick_init(void) { SysTick_Config(SystemCoreClock / 1000u); }
```

Re-run `systick_init()` after the PLL switch. At 216 MHz `SystemCoreClock / 1000 = 216000`, well under the 24-bit limit (16 777 215).

Blocking delay with a timeout-safe comparison:

```c
void delay_ms(uint32_t ms) { uint32_t t0 = millis(); while ((uint32_t)(millis() - t0) < ms) { __WFI(); } }
```

(`__WFI()` wakes on the next interrupt, at most 1 ms later because of SysTick.)

---

## 7. USART (serial port)

### 7.1 Registers (F7 USART)

| Register | Notes |
|---|---|
| `CR1` | `UE` (enable), `TE`, `RE`, interrupt enables `RXNEIE`, `TXEIE`, `TCIE`, `IDLEIE`, `PEIE`, word length `M0/M1`, oversampling `OVER8`, parity |
| `CR2` | Stop bits, clock output, address |
| `CR3` | `DMAT`, `DMAR`, `EIE` (error interrupt), flow control |
| `BRR` | Baud rate divisor |
| `ISR` | Flags: `TXE`, `TC`, `RXNE`, `IDLE`, `ORE`, `NE`, `FE`, `PE`, `BUSY` |
| `ICR` | Write 1 to clear flags: `ORECF`, `FECF`, `NCF`, `PECF`, `IDLECF`, `TCCF` |
| `RDR`, `TDR` | Receive and transmit data |

Baud rate with 16x oversampling: `BRR = f_USART_clk / baud` (rounded). The clock for USART2/3 and UART4/5/7/8 is PCLK1 by default (selectable in `RCC->DCKCFGR2`).

| PCLK1 | Baud | BRR | Actual baud | Error |
|---|---|---|---|---|
| 16 MHz (HSI, reset state) | 115200 | 139 | 115108 | -0.08 % |
| 54 MHz (216 MHz config) | 115200 | 469 | 115139 | -0.05 % |
| 54 MHz | 921600 | 59 | 915254 | -0.7 % |
| 54 MHz | 3 000 000 | 18 | 3 000 000 | 0 % |

Keep error below about 2 %, ideally below 1 %.

### 7.2 Initialization

```c
#include "stm32f7xx.h"
#include "pins.h"

#define UART_RX_SIZE 256u            /* power of two */
#define UART_TX_SIZE 512u

static volatile uint8_t  rx_buf[UART_RX_SIZE];
static volatile uint32_t rx_head, rx_tail;          /* ISR writes head, main reads tail */
static volatile uint8_t  tx_buf[UART_TX_SIZE];
static volatile uint32_t tx_head, tx_tail;          /* main writes head, ISR reads tail */
static volatile uint32_t uart_errors;

void uart_init(uint32_t pclk1_hz, uint32_t baud)
{
    gpio_config(VCP_TX_PORT, VCP_TX_PIN, GPIO_MODE_AF, GPIO_PULL_NONE, GPIO_SPEED_HIGH, false, VCP_AF);
    gpio_config(VCP_RX_PORT, VCP_RX_PIN, GPIO_MODE_AF, GPIO_PULL_UP,   GPIO_SPEED_HIGH, false, VCP_AF);

    RCC->APB1ENR |= RCC_APB1ENR_USART3EN;
    (void)RCC->APB1ENR;

    USART3->CR1 = 0;                                   /* UE = 0 while configuring */
    USART3->BRR = (pclk1_hz + baud / 2u) / baud;       /* rounded divisor, 16x oversampling */
    USART3->CR2 = 0;                                   /* 1 stop bit */
    USART3->CR3 = USART_CR3_EIE;                       /* error interrupts (overrun etc.) */
    USART3->CR1 = USART_CR1_TE | USART_CR1_RE | USART_CR1_RXNEIE;
    USART3->CR1 |= USART_CR1_UE;                       /* enable last */

    NVIC_SetPriority(USART3_IRQn, 5);
    NVIC_EnableIRQ(USART3_IRQn);
}

void USART3_IRQHandler(void)
{
    uint32_t isr = USART3->ISR;

    if (isr & (USART_ISR_ORE | USART_ISR_FE | USART_ISR_NE)) {
        USART3->ICR = USART_ICR_ORECF | USART_ICR_FECF | USART_ICR_NCF;     /* clear error flags */
        uart_errors++;
    }
    if (isr & USART_ISR_RXNE) {
        uint8_t b = (uint8_t)USART3->RDR;                                    /* reading clears RXNE */
        uint32_t next = (rx_head + 1u) & (UART_RX_SIZE - 1u);
        if (next != rx_tail) { rx_buf[rx_head] = b; rx_head = next; }        /* drop when full */
    }
    if ((USART3->CR1 & USART_CR1_TXEIE) && (isr & USART_ISR_TXE)) {
        if (tx_tail != tx_head) {
            USART3->TDR = tx_buf[tx_tail];                                   /* writing clears TXE */
            tx_tail = (tx_tail + 1u) & (UART_TX_SIZE - 1u);
        } else {
            USART3->CR1 &= ~USART_CR1_TXEIE;                                 /* nothing left: stop TXE interrupts */
        }
    }
}

bool uart_getc(uint8_t *c)
{
    if (rx_tail == rx_head) { return false; }
    *c = rx_buf[rx_tail];
    rx_tail = (rx_tail + 1u) & (UART_RX_SIZE - 1u);
    return true;
}

bool uart_putc(uint8_t c)                                    /* non-blocking: false if full */
{
    uint32_t next = (tx_head + 1u) & (UART_TX_SIZE - 1u);
    if (next == tx_tail) { return false; }
    tx_buf[tx_head] = c;
    tx_head = next;
    USART3->CR1 |= USART_CR1_TXEIE;                          /* start/continue transmission (RMW: see note) */
    return true;
}
```

Notes:

- The `CR1 |= TXEIE` in `uart_putc` is a read-modify-write on a register the ISR also modifies (`&= ~TXEIE`). If the ISR runs between the read and the write, the ISR's clear can be lost (harmless: the next TXE interrupt finds the buffer empty and clears it again) or a set can be lost (the data would wait until the next `uart_putc`). For bulletproof behavior, wrap in `__disable_irq()` / `__set_PRIMASK(...)`, or use DMA for TX.
- ORE (overrun) happens when RXNE is not serviced in time. Clear it via `ICR`; if `ORE` is not cleared the receiver stays blocked on some devices.
- `printf` over this UART: in `_write`, loop `uart_putc()` and **wait** if full (or drop):

```c
int _write(int fd, char *ptr, int len)
{
    (void)fd;
    for (int i = 0; i < len; i++) { while (!uart_putc((uint8_t)ptr[i])) { /* wait for space */ } }
    return len;
}
```

  Waiting inside `_write` from an ISR of equal or higher priority than USART3 deadlocks. Never `printf` from ISRs.
- After switching to 216 MHz, call `uart_init(54000000u, 115200u)` (PCLK1 = 54 MHz).
- Pin loopback test: connect PD8 to PD9 (if accessible), or use the ST-LINK VCP and echo characters in `main`.

### 7.3 UART with DMA (high-throughput patterns)

Use DMA when data is continuous or large: the CPU only sees buffer-level events.

**TX with DMA** (DMA1 Stream 3, Channel 4 for USART3_TX: verify in the RM0385 "DMA1 request mapping" table):

```c
static uint8_t tx_dma_buf[256] __attribute__((aligned(32)));
static volatile bool tx_busy;

void uart_dma_tx_init(void)
{
    RCC->AHB1ENR |= RCC_AHB1ENR_DMA1EN;
    (void)RCC->AHB1ENR;

    DMA1_Stream3->CR &= ~DMA_SxCR_EN;
    while (DMA1_Stream3->CR & DMA_SxCR_EN) { }              /* wait until really disabled */

    DMA1->LIFCR = DMA_LIFCR_CTCIF3 | DMA_LIFCR_CHTIF3 | DMA_LIFCR_CTEIF3
                | DMA_LIFCR_CDMEIF3 | DMA_LIFCR_CFEIF3;     /* clear all stream-3 flags */

    DMA1_Stream3->PAR  = (uint32_t)&USART3->TDR;
    DMA1_Stream3->CR   = (4u << DMA_SxCR_CHSEL_Pos)         /* channel 4 */
                       | DMA_SxCR_MINC                      /* increment memory address */
                       | DMA_SxCR_DIR_0                     /* memory to peripheral */
                       | DMA_SxCR_TCIE;                     /* transfer-complete interrupt */
    USART3->CR3 |= USART_CR3_DMAT;                          /* UART requests DMA on TXE */

    NVIC_SetPriority(DMA1_Stream3_IRQn, 6);
    NVIC_EnableIRQ(DMA1_Stream3_IRQn);
}

bool uart_dma_send(const uint8_t *data, uint16_t len)
{
    if (tx_busy || len == 0u || len > sizeof tx_dma_buf) { return false; }
    tx_busy = true;
    memcpy(tx_dma_buf, data, len);
    SCB_CleanDCache_by_Addr((uint32_t *)tx_dma_buf, (int32_t)sizeof tx_dma_buf);   /* if D-cache is on */

    DMA1_Stream3->M0AR = (uint32_t)tx_dma_buf;
    DMA1_Stream3->NDTR = len;
    DMA1_Stream3->CR  |= DMA_SxCR_EN;
    return true;
}

void DMA1_Stream3_IRQHandler(void)
{
    if (DMA1->LISR & DMA_LISR_TCIF3) {
        DMA1->LIFCR = DMA_LIFCR_CTCIF3;
        tx_busy = false;
    }
    if (DMA1->LISR & (DMA_LISR_TEIF3 | DMA_LISR_DMEIF3)) {
        DMA1->LIFCR = DMA_LIFCR_CTEIF3 | DMA_LIFCR_CDMEIF3;
        tx_busy = false;                                    /* transfer error: recover */
    }
}
```

**RX with circular DMA + IDLE-line interrupt** (DMA1 Stream 1, Channel 4 for USART3_RX: verify). The DMA writes received bytes continuously into a circular buffer; the **IDLE** interrupt fires when the line is quiet after a burst, so you process whole messages without per-byte interrupts:

```c
static uint8_t rx_dma_buf[256] __attribute__((aligned(32)));
static uint32_t rx_dma_read_pos;

void uart_dma_rx_init(void)
{
    DMA1_Stream1->CR &= ~DMA_SxCR_EN;
    while (DMA1_Stream1->CR & DMA_SxCR_EN) { }
    DMA1->LIFCR = DMA_LIFCR_CTCIF1 | DMA_LIFCR_CHTIF1 | DMA_LIFCR_CTEIF1
                | DMA_LIFCR_CDMEIF1 | DMA_LIFCR_CFEIF1;

    DMA1_Stream1->PAR  = (uint32_t)&USART3->RDR;
    DMA1_Stream1->M0AR = (uint32_t)rx_dma_buf;
    DMA1_Stream1->NDTR = sizeof rx_dma_buf;
    DMA1_Stream1->CR   = (4u << DMA_SxCR_CHSEL_Pos) | DMA_SxCR_MINC | DMA_SxCR_CIRC;   /* peripheral to memory, circular */
    DMA1_Stream1->CR  |= DMA_SxCR_EN;

    USART3->CR3 |= USART_CR3_DMAR;
    USART3->CR1 |= USART_CR1_IDLEIE;                         /* IDLE interrupt in USART3_IRQHandler */
}

/* in USART3_IRQHandler: */
if (isr & USART_ISR_IDLE) {
    USART3->ICR = USART_ICR_IDLECF;
    uint32_t write_pos = sizeof rx_dma_buf - DMA1_Stream1->NDTR;       /* where DMA is now */
    SCB_InvalidateDCache_by_Addr((uint32_t *)rx_dma_buf, (int32_t)sizeof rx_dma_buf);
    process_bytes(rx_dma_buf, rx_dma_read_pos, write_pos);              /* handle wrap-around inside */
    rx_dma_read_pos = write_pos;
}
```

(Remove the cache calls if the D-cache is off, and see chapter 3 for the 32-byte alignment rules. `process_bytes` must handle the case `write_pos < read_pos` (wrap).)

### 7.4 What to remember

- Clock to the USART **and** the GPIO; AF number correct; `BRR` computed from the actual PCLK.
- Enable `UE` last; clear flags by the documented method (`ICR`, read `RDR`).
- Never block inside ISRs; use ring buffers or DMA.
- A garbage-character terminal almost always means a wrong baud or wrong clock (PLL switched but `BRR` not updated).

---

## 8. Timers

### 8.1 Families

| Timers | Width | Notes |
|---|---|---|
| TIM6, TIM7 | 16-bit | Basic: only time base, DAC trigger |
| TIM2, TIM5 | **32-bit** | General purpose: capture/compare, PWM, encoder |
| TIM3, TIM4 | 16-bit | General purpose |
| TIM9-14 | 16-bit | Simpler general purpose |
| TIM1, TIM8 | 16-bit | **Advanced**: complementary outputs, dead time, break (motor control, power) |
| LPTIM1 | 16-bit | Low power |

### 8.2 The time base

```
f_update = f_timer_clock / ((PSC + 1) * (ARR + 1))
```

- `PSC` (prescaler) divides the clock, `ARR` (auto-reload) sets the period, `CNT` counts.
- The timer clock is **2 x PCLK** when the bus prescaler is not 1 (so 108 MHz for TIM2-7 and 216 MHz for TIM1/8/9-11 in the 216 MHz setup).
- Changes to `PSC`/`ARR` take effect at the next update event unless you force one with `EGR = TIM_EGR_UG`. `ARPE` (auto-reload preload) buffers `ARR` updates.

Example, 1 kHz periodic interrupt from TIM6 (clock 108 MHz): `PSC = 108 - 1` gives 1 MHz counting; `ARR = 1000 - 1` gives 1 kHz.

```c
void tim6_init_1khz(void)
{
    RCC->APB1ENR |= RCC_APB1ENR_TIM6EN;
    (void)RCC->APB1ENR;

    TIM6->PSC  = 108u - 1u;                  /* 108 MHz / 108 = 1 MHz tick */
    TIM6->ARR  = 1000u - 1u;                 /* 1000 ticks = 1 ms */
    TIM6->EGR  = TIM_EGR_UG;                 /* load the registers now */
    TIM6->SR   = 0u;                         /* clear the update flag set by UG */
    TIM6->DIER = TIM_DIER_UIE;               /* update interrupt */
    NVIC_SetPriority(TIM6_DAC_IRQn, 7);
    NVIC_EnableIRQ(TIM6_DAC_IRQn);
    TIM6->CR1  = TIM_CR1_CEN;                /* start */
}

void TIM6_DAC_IRQHandler(void)
{
    if (TIM6->SR & TIM_SR_UIF) {
        TIM6->SR = ~TIM_SR_UIF;              /* rc_w0: clear by writing 0 to that bit */
        /* every 1 ms */
    }
}
```

### 8.3 PWM output

PB7 (the blue LED) is `TIM4_CH2` on AF2 (verify in the datasheet). TIM4 is on APB1: 108 MHz timer clock in the 216 MHz setup.

```c
void pwm_init(void)
{
    gpio_config(GPIOB, 7, GPIO_MODE_AF, GPIO_PULL_NONE, GPIO_SPEED_LOW, false, 2u);

    RCC->APB1ENR |= RCC_APB1ENR_TIM4EN;
    (void)RCC->APB1ENR;

    TIM4->PSC  = 108u - 1u;                  /* 1 MHz counter clock */
    TIM4->ARR  = 1000u - 1u;                 /* 1 kHz PWM, 1000 steps */
    TIM4->CCR2 = 0u;                         /* duty 0 % */

    /* channel 2: PWM mode 1 (OC2M = 110), preload on CCR2 */
    TIM4->CCMR1 = (TIM4->CCMR1 & ~(TIM_CCMR1_OC2M | TIM_CCMR1_CC2S))
                | TIM_CCMR1_OC2M_1 | TIM_CCMR1_OC2M_2 | TIM_CCMR1_OC2PE;
    TIM4->CCER |= TIM_CCER_CC2E;             /* output enable for channel 2 */
    TIM4->CR1  |= TIM_CR1_ARPE;
    TIM4->EGR   = TIM_EGR_UG;                /* load preloaded registers */
    TIM4->CR1  |= TIM_CR1_CEN;
}

void pwm_set_permille(uint16_t permille)     /* 0..1000 */
{
    if (permille > 1000u) { permille = 1000u; }
    TIM4->CCR2 = permille;                   /* duty = CCR / (ARR + 1) */
}
```

For TIM1 and TIM8 you must also set the **main output enable**: `TIM1->BDTR |= TIM_BDTR_MOE;`, otherwise nothing comes out.

PWM math: `duty = CCR / (ARR + 1)`, frequency `= f_timer / ((PSC + 1)(ARR + 1))`. Choose `ARR` large for resolution; if the load is an LED, 500 Hz to 1 kHz or above avoids visible flicker.

### 8.4 Other modes

| Mode | Use |
|---|---|
| Output compare | Toggle a pin or interrupt at a given count |
| Input capture | Measure pulse width and period (ultrasonic sensors, tachometers) |
| Encoder mode | Quadrature encoders on TIM2/3/4/5 |
| One-pulse mode | A single pulse of programmed width |
| Master/slave and `TRGO` | Chain timers or trigger the ADC/DAC from a timer |
| Break and dead time (TIM1/8) | Safe complementary drive for half bridges |

### 8.5 Microsecond delay and profiling

- `DWT->CYCCNT` for cycle-exact timing (chapter 3).
- A free-running 32-bit timer (TIM2 at 1 MHz: `PSC = 108 - 1`, `ARR = 0xFFFFFFFF`) gives a microsecond timestamp with wrap-safe subtraction.

---

## 9. ADC

### 9.1 Overview

- Three ADCs (ADC1, ADC2, ADC3), **12-bit** (resolution selectable 6/8/10/12 bits), up to 2.4 MSPS each (interleaved modes reach more).
- 16 external channels plus internal: temperature sensor, VREFINT and VBAT (on ADC1; see below).
- ADC clock: PCLK2 divided by `ADCPRE` (/2, /4, /6, /8) from `ADC->CCR`. **Maximum 36 MHz** (at 108 MHz PCLK2 use /4 = 27 MHz).
- Sample time per channel: 3, 15, 28, 56, 84, 112, 144 or 480 ADC clock cycles. Total conversion = sample time + 12 cycles.
- Reference: VREF+ is VDDA (3.3 V on the Nucleo). The result is ratiometric: `Vin = raw / 4095 * VDDA`.

### 9.2 Registers

| Register | Purpose |
|---|---|
| `ADCx->CR1` | Resolution `RES`, scan mode `SCAN`, end-of-conversion interrupt `EOCIE`, watchdog |
| `ADCx->CR2` | `ADON`, `CONT` (continuous), `SWSTART`, `EOCS`, `DMA`, `DDS`, external trigger `EXTSEL/EXTEN` |
| `ADCx->SMPR1`, `SMPR2` | Sample time, 3 bits per channel (`SMPR2` channels 0-9, `SMPR1` channels 10-18) |
| `ADCx->SQR1..3` | Conversion sequence (`SQR1.L` = number of conversions minus 1) |
| `ADCx->SR` | `EOC`, `OVR`, `STRT` |
| `ADCx->DR` | Result (reading clears `EOC`) |
| `ADC->CCR` (common) | `ADCPRE`, `TSVREFE` (temperature sensor and VREFINT), `VBATE`, multi-ADC mode |

### 9.3 Polling driver (single conversions)

```c
#include "stm32f7xx.h"
#include <stdbool.h>

void adc1_init(void)
{
    RCC->APB2ENR |= RCC_APB2ENR_ADC1EN;
    (void)RCC->APB2ENR;

    ADC->CCR = (ADC->CCR & ~ADC_CCR_ADCPRE) | ADC_CCR_ADCPRE_0;    /* PCLK2 / 4 (27 MHz at 108 MHz) */

    ADC1->CR1 = 0;                          /* 12-bit, no scan */
    ADC1->CR2 = ADC_CR2_ADON;               /* power on; allow a few microseconds to stabilize */
    for (volatile int i = 0; i < 1000; i++) { }
}

/* sample_code: 0..7 = 3,15,28,56,84,112,144,480 cycles */
bool adc1_read(uint8_t channel, uint8_t sample_code, uint16_t *out)
{
    if (channel < 10u) {
        ADC1->SMPR2 = (ADC1->SMPR2 & ~(7u << (channel * 3u))) | ((uint32_t)sample_code << (channel * 3u));
    } else {
        unsigned s = (channel - 10u) * 3u;
        ADC1->SMPR1 = (ADC1->SMPR1 & ~(7u << s)) | ((uint32_t)sample_code << s);
    }
    ADC1->SQR1 = 0;                         /* L = 0: one conversion */
    ADC1->SQR3 = channel;                   /* first (only) in the sequence */

    ADC1->SR   = 0;                         /* clear old flags */
    ADC1->CR2 |= ADC_CR2_SWSTART;

    uint32_t timeout = 100000u;
    while ((ADC1->SR & ADC_SR_EOC) == 0u) {
        if (timeout-- == 0u) { return false; }
    }
    *out = (uint16_t)ADC1->DR;              /* reading DR clears EOC */
    return true;
}
```

An external pin: put it in **analog mode** (`GPIO_MODE_ANALOG`), then read its channel. On the Nucleo-144 the Arduino header pin A0 is PA3, which is `ADC123_IN3` (verify the mapping in UM1974).

```c
gpio_config(GPIOA, 3, GPIO_MODE_ANALOG, GPIO_PULL_NONE, GPIO_SPEED_LOW, false, 0);
uint16_t raw;
if (adc1_read(3, 3u /*56 cycles*/, &raw)) {
    float volts = (float)raw * (3.3f / 4095.0f);
}
```

### 9.4 VBAT and temperature sensor

Internal channels need to be connected and need a long sample time:

```c
float adc_read_vbat(void)
{
    ADC->CCR |= ADC_CCR_VBATE;              /* connect VBAT/4 to ADC1 channel 18 */
    uint16_t raw = 0;
    adc1_read(18, 7u /*480 cycles*/, &raw);
    ADC->CCR &= ~ADC_CCR_VBATE;
    return (float)raw * (3.3f / 4095.0f) * 4.0f;       /* the F7 divides VBAT by 4 (RM0385) */
}

float adc_read_temperature_c(void)
{
    ADC->CCR |= ADC_CCR_TSVREFE;            /* temperature sensor also on ADC1 channel 18 */
    uint16_t raw = 0;
    adc1_read(18, 7u, &raw);                /* temperature sensor needs at least 10 us sampling */
    ADC->CCR &= ~ADC_CCR_TSVREFE;
    float v = (float)raw * (3.3f / 4095.0f);
    return (v - 0.76f) / 0.0025f + 25.0f;   /* typical: V25 = 0.76 V, slope 2.5 mV/degC (datasheet) */
}
```

Notes:

- VBAT and the temperature sensor **share channel 18**; if both enables are set only VBAT is converted.
- The datasheet typical values (V25, slope) vary a lot between chips (several degrees). For better accuracy use the **factory calibration values** stored in system memory (two readings at known temperatures and VDDA = 3.3 V; the addresses and their formula are in the F746 datasheet: look up "TS_CAL1/TS_CAL2" there) and interpolate linearly: `T = 80 / (TS_CAL2 - TS_CAL1) * (raw - TS_CAL1) + 30`.
- On the Nucleo, check that VBAT is connected as you expect (UM1974): without a battery it may be tied to VDD, and you will read about 3.3 V.
- Sensor and VBAT results are rough indicators, not precision measurements.

### 9.5 Quality of the measurement

| Issue | What to do |
|---|---|
| High source impedance | Longer sample time, or a buffer (op-amp), or a capacitor at the pin |
| Noise | Decoupling on VDDA, average N samples (`sum >> k`), oversample, keep analog traces away from digital |
| Wrong values near 0 or full scale | Offset/gain errors: calibrate against known voltages |
| Reference changes | `VDDA` is not exactly 3.3 V: measure `VREFINT` (internal 1.2 V) and compute the real VDDA |
| Resolution | 12 bits gives 0.8 mV steps at 3.3 V; effective bits are lower |
| Channel crosstalk | Discard the first sample after switching channels |
| Aliasing | Sample at least twice the highest signal frequency, add an anti-alias RC filter |

### 9.6 Continuous conversions with DMA and a timer trigger

For regular sampling: a timer's `TRGO` triggers the ADC at a fixed rate (`EXTSEL` selects the timer event, `EXTEN` the edge), the ADC converts a scan sequence, and DMA stores results in a buffer (circular, with half-transfer and transfer-complete interrupts to process blocks). The sampling rate is then set by the timer, not by software timing:

```
timer (TRGO) ──► ADC (scan, external trigger) ──► DMA (circular buffer) ──► half/complete interrupt ──► process
```

Remember D-cache invalidation of the buffer before reading it, and 32-byte alignment (chapter 3).

---

## 10. SPI and I2C (outline)

### 10.1 SPI

| Setting | Notes |
|---|---|
| Mode | `CPOL`/`CPHA` (4 modes): must match the device datasheet |
| Baud | `BR[2:0]` divides PCLK by 2..256 (SPI1 on APB2) |
| Data size | 4 to 16 bits (`DS` in `CR2`); set `FRXTH` to read 8-bit frames correctly |
| NSS | Usually software-managed (`SSM`/`SSI`) with a GPIO as chip select |
| Registers | `CR1`, `CR2`, `SR` (`TXE`, `RXNE`, `BSY`), `DR` |

Skeleton (polling, master, mode 0, 8 bits):

```c
uint8_t spi_xfer(SPI_TypeDef *spi, uint8_t b)
{
    while (!(spi->SR & SPI_SR_TXE)) { }
    *(volatile uint8_t *)&spi->DR = b;         /* 8-bit access to DR: important on F7 */
    while (!(spi->SR & SPI_SR_RXNE)) { }
    return *(volatile uint8_t *)&spi->DR;
}
```

Pitfalls: 16-bit write to `DR` when the frame is 8 bits sends two frames. Wait for `BSY = 0` before releasing chip select. For speed use DMA (TX and RX streams), and mind cache coherency.

### 10.2 I2C

The F7 uses the "new" I2C block with the **`TIMINGR`** register: prescaler plus setup, hold, high and low periods. Do not hand-calculate it: use the table in the reference manual for your kernel clock, or STM32CubeMX's I2C timing tool, and **record the resulting 32-bit value** with the clock it assumes.

Transfer outline (7-bit address, write N bytes):

1. Enable the clock (`APB1ENR.I2C1EN`), configure SCL/SDA as **alternate function, open-drain, pull-up** (plus external pull-ups of 2.2-4.7 kΩ on the bus), AF4 on the F7 pins (verify).
2. `TIMINGR = <value>`, `CR1.PE = 1`.
3. Set `CR2`: `SADD` (address << 1), `NBYTES`, `AUTOEND`, `START`.
4. For each byte: wait for `ISR.TXIS`, write `TXDR`. Check `ISR.NACKF` (device did not answer).
5. Wait for `ISR.STOPF` and clear it (`ICR.STOPCF`).
6. Reads: `RD_WRN` bit, then wait for `RXNE` and read `RXDR`.

Always implement **timeouts** and bus-recovery (clock out 9 pulses on SCL if SDA is stuck low). A logic analyzer with an I2C decoder is the fastest way to debug.

---

## 11. Watchdogs, reset sources, and other useful blocks

### 11.1 Independent watchdog (IWDG)

Clocked from the LSI (about 32 kHz, inaccurate), keeps counting through most states, resets the chip if not "kicked". Once started it **cannot be stopped** except by reset.

```c
void iwdg_init_1s(void)
{
    IWDG->KR  = 0x5555u;                 /* unlock PR and RLR */
    IWDG->PR  = 4u;                      /* prescaler /64: 32 kHz / 64 = 500 Hz */
    IWDG->RLR = 500u - 1u;               /* 500 ticks = about 1 s */
    while (IWDG->SR != 0u) { }           /* wait until the registers are updated */
    IWDG->KR  = 0xAAAAu;                 /* load the counter */
    IWDG->KR  = 0xCCCCu;                 /* START */
}
static inline void iwdg_kick(void) { IWDG->KR = 0xAAAAu; }
```

Use: kick it from the main loop only when all critical tasks have reported alive, not from a timer ISR (a hung main loop would be hidden). During debugging freeze it with `DBGMCU->APB1FZ` (chapter 4).

The **window watchdog** (WWDG, APB1 clock) also resets if you kick **too early**, which catches runaway loops that kick constantly.

After reset, read `RCC->CSR` to learn the cause (chapter 4, section 9.3).

### 11.2 Other blocks you will meet

| Block | Notes |
|---|---|
| CRC | Hardware CRC-32 (used in chapter 0 for firmware integrity) |
| RNG | True random generator; needs the 48 MHz clock (PLLQ) enabled |
| RTC | Calendar, alarms, wake-up timer; backup domain, LSE crystal; needs `PWR->CR1.DBP` to write |
| DAC | 12-bit, two channels (PA4, PA5); trigger from TIM6/7, DMA waveforms |
| Flash (internal) | Sector erase before write. F746: 4 x 32 KB, 1 x 128 KB, 3 x 256 KB sectors. Store settings in a dedicated sector, with CRC and wear spreading |
| CAN, USB, Ethernet, SDMMC, FMC, SAI, QSPI, DCMI, LTDC | Large subsystems; start from the reference manual and ST example projects |
| DMA2D, JPEG | Graphics acceleration (some variants) |
| MPU, caches | Core features (chapter 3) |

### 11.3 Power modes

| Mode | Core | Wake-up | Notes |
|---|---|---|---|
| Run | Running | | |
| Sleep | Stopped, peripherals running | Any interrupt | `__WFI()` |
| Stop | Clocks stopped, SRAM kept | EXTI lines, RTC, ... | `SCB->SCR.SLEEPDEEP` + `PWR->CR1` settings |
| Standby | Almost all off | WKUP pins, RTC, reset | RAM lost except backup |

Reconfigure the clock tree after waking from Stop (the system restarts on HSI). Remember debugging may not work in deep sleep (chapter 4).

---

## 12. Using the HAL, LL, or CMSIS

| Approach | Strength | Weakness |
|---|---|---|
| **Registers (CMSIS)** | Smallest, fastest, full control, you learn the hardware | You must read the RM, easy to miss a step |
| **LL (Low Layer)** | Thin inline wrappers over registers | Still STM32-specific |
| **HAL** | Portable between STM32, many examples, CubeMX generates it | Larger, slower, hides timing, many callbacks |

Good way to use the HAL **for learning**: generate a project in CubeMX that does what you want, then read its generated `HAL_xxx_MspInit`, `MX_xxx_Init` and HAL source to see which registers it sets. Use CubeMX as a **reference** for pins, alternate functions, clock tree and DMA mapping even when you write your own driver.

Mixing is possible but mind the ownership of shared registers (do not let HAL and your code both reconfigure the same peripheral).

---

## 13. Debugging a peripheral

Checklist, in this order:

1. Is the **clock enabled** (`RCC->xxxENR` bit)? Read the register in the Peripherals panel.
2. Did you **read back** after enabling (short delay)?
3. Is the peripheral **enabled** (`UE`, `ADON`, `CEN`, `PE`) and **configured while disabled**?
4. Are the **pins** in the right mode and AF? Check `GPIOx->MODER`, `AFR`. Compare against the datasheet table.
5. Is the pin actually connected on the board (solder bridge, jumper, other peripheral using it, header position)?
6. Do the **status flags** change when you act (`TXE`, `RXNE`, `EOC`)? Which ones stay set?
7. **Interrupts**: is the NVIC enabled and prioritised, is the peripheral's interrupt-enable bit set, is the handler name exact, do you clear the flag?
8. **Clock frequencies** really what you assume (`SystemCoreClock`, PCLK, timer clock doubling)?
9. Watch the signals: logic analyzer or scope on the pins (UART bit time gives the baud rate; PWM period; I2C ACK/NACK).
10. Compare with a **HAL-generated** working project: diff the register values with the debugger.

### Common mistakes

| Symptom | Likely cause |
|---|---|
| Peripheral registers read as 0 or the write has no effect | Clock not enabled |
| Bus fault accessing a peripheral | Clock not enabled (PRECISERR with BFAR in `0x40xxxxxx`) |
| No signal on the pin | Wrong AF, pin not in AF mode, wrong pin, or peripheral not enabled |
| UART garbage | Baud wrong because PCLK differs from what `BRR` assumed (after the PLL switch) |
| UART sends once and stops | `TXEIE` handling wrong or buffer pointers wrong |
| UART loses characters | Overrun: ISR too slow or `ORE` flag not cleared; use DMA |
| ISR runs forever | Flag not cleared, or wrong clearing method (`rc_w0` vs `rc_w1`) |
| ISR never runs | NVIC not enabled, wrong handler name, interrupt enable bit missing, PRIMASK set |
| Timer period 2x off | Timer clock doubling (APB prescaler) not accounted for |
| PWM stuck | `CCxE` not set, `MOE` not set on TIM1/8, or `CCR` greater than `ARR` |
| ADC always 0 or 4095 | Pin not in analog mode, wrong channel, no reference, sample time too short |
| ADC readings jump | High source impedance, noise, floating pin |
| DMA does nothing | Stream still enabled while configuring, wrong channel/stream for the request, `NDTR` zero, request bit missing in the peripheral (`DMAT`/`DMAR`) |
| DMA data stale or corrupt | D-cache coherency (clean before TX, invalidate before RX), buffer not 32-byte aligned |
| After switching to 216 MHz everything is wrong | `SystemCoreClock` and dependent settings not updated; flash latency or over-drive missing |
| Hard fault only after raising the clock | Flash wait states too low |
| Debugger lost after init | PA13/PA14/PB3 reconfigured, or low-power mode entered |

---

## 14. Lab exercises

Clock and basics:

1. **Measure the clocks**: output HSI, HSE and the PLL on MCO1 (PA8) and verify with a logic analyzer.
2. **216 MHz**: implement `clock_init_216mhz()`, then show with the DWT cycle counter that a 1 ms SysTick loop still takes 216000 cycles. Try forcing a wrong flash latency and read the fault or failure.
3. **GPIO helper**: write `gpio_config()`, configure the three LEDs, and generate a binary counter on them. Check `MODER`/`AFR` values in the Peripherals panel.
4. **Button interrupt**: implement EXTI on PC13 with debounce. Count presses and print them.

Serial:

5. **UART polling**, then **interrupt-driven RX/TX** with ring buffers; echo characters back.
6. **Baud error**: try 921600 and 3 000 000 baud at 54 MHz PCLK1 and check which ones your PC terminal accepts.
7. **UART DMA TX** and **circular RX with IDLE**: send 4 KB messages without CPU load, measure CPU time with DWT.
8. **Break it**: leave out the `ORE` clearing and flood RX; see the receiver stall; then fix it.

Timers and analog:

9. **Timer interrupt**: 1 kHz on TIM6 while toggling a pin; measure period and jitter on the logic analyzer, with and without a busy-wait in `main`.
10. **PWM**: dim the blue LED (PB7/TIM4_CH2), implement a "breathing" effect with a lookup table, change frequency to see flicker.
11. **Input capture** (if you have a signal source): measure the frequency of a PWM generated by a second timer, wired externally.
12. **ADC**: read a potentiometer on A0, average 16 samples, print volts. Compare sample times 3 vs 480 cycles with a high-impedance source.
13. **VBAT and temperature**: read both, then compute temperature with the factory calibration values from the datasheet. Compare with the typical-value formula.
14. **ADC + timer + DMA**: sample at exactly 10 kHz into a circular buffer and process half buffers; verify the rate with a pin toggle.

Reliability:

15. **IWDG**: start the watchdog, deliberately hang, observe the reset, and report the cause from `RCC->CSR`.
16. **Everything with timeouts**: replace every unbounded wait in your drivers with a bounded one and add an error counter you can read in the debugger.
17. **C++ version**: rewrite GPIO and UART as the template classes from chapter 6; compare code size and disassembly.

---

## 15. Cheat sheet

### Bring-up order

```
RCC clock on -> read back -> GPIO mode/AF -> configure peripheral (disabled) -> interrupts/DMA -> enable last
```

### Clock numbers at 216 MHz (HSE 8 MHz bypass)

```
PLLM=4, PLLN=216, PLLP=/2, PLLQ=9      SYSCLK 216 MHz, USB/RNG 48 MHz
AHB /1 = 216 MHz   APB1 /4 = 54 MHz   APB2 /2 = 108 MHz
Timer clocks: APB1 timers 108 MHz, APB2 timers 216 MHz
Flash latency 7 WS, Over-drive on, ADC clock <= 36 MHz (PCLK2/4 = 27 MHz)
```

### Formulas

```
UART BRR  = PCLK / baud                       (16x oversampling)
Timer f   = f_timer / ((PSC+1)(ARR+1))
PWM duty  = CCR / (ARR+1)
ADC volts = raw / 4095 * VDDA                 (VBAT: * 4)
IWDG time = (RLR+1) * prescaler / 32 kHz      (approx)
```

### Flag clearing styles

| Style | Example |
|---|---|
| Write 1 to clear (`rc_w1`) | `EXTI->PR`, `USART->ICR`, `DMA->xIFCR` |
| Write 0 to clear (`rc_w0`) | `TIM->SR` |
| Read data register | `USART->RDR` clears RXNE, `ADC->DR` clears EOC |
| Write data register | `USART->TDR` clears TXE |

### Where each thing is documented

| Need | Document |
|---|---|
| Registers and behavior | RM0385 |
| Pin to peripheral, AF numbers | Datasheet (alternate function table) |
| Which pin is on which header, solder bridges | UM1974 |
| Electrical limits (ADC accuracy, currents, 5 V tolerant) | Datasheet |
| DMA stream/channel for each request | RM0385 DMA request mapping tables |
| Calibration values | Datasheet / RM0385 (system memory addresses) |

---

## 16. Where this leads

- **Architecture patterns** (next): turn these drivers into layers (HAL interface, drivers, services, application), with event queues and host-side tests using fakes.
- **RTOS**: the ISR-to-task patterns of sections 5 to 9 (queues, notifications) map directly onto FreeRTOS primitives.
- **Bootloader and updates**: flash programming, CRC check, jump to application (chapters 0 and 3).
- **Low power**: apply the power modes with RTC wake-up and measure current.
- **Connectivity**: CAN, USB CDC, Ethernet with lwIP, SD cards with FatFS.

## References

- ST RM0385: STM32F75xxx and STM32F74xxx advanced Arm-based 32-bit MCUs reference manual
- ST datasheet: STM32F745xx / STM32F746xx
- ST UM1974: STM32 Nucleo-144 boards (MB1137)
- ST PM0253: STM32F7 Series and STM32H7 Series Cortex-M7 processor programming manual
- ST AN4891: STM32F72xxx/F73xxx/F74xxx/F75xxx/F76xxx/F77xxx oscillator and clock design (plus the clock-related application notes)
- ST AN4838 / AN4839: MPU and L1 cache programming on STM32F7
- STM32CubeF7 firmware package (HAL source and examples to read, not necessarily to use)
- STM32CubeMX: clock tree, pin and DMA assistant