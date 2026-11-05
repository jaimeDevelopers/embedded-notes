# 15. Low-Power Design (STM32F7 and General Principles)

Prerequisites: chapter 3 (WFI/WFE, SLEEPDEEP), chapter 7 (clocks, RTC, peripherals), chapter 10 (supply, measurement), chapter 12 (tickless idle).

**Important context and verification note.** The STM32F7 family is a **performance** family (216 MHz, caches, big RAM). Its low-power modes work, but its sleep currents are far higher than those of ultra-low-power families (STM32L0/L4/L5/U5/WL, nRF52/53, MSP430...). If a product runs on a coin cell for years, choose an MCU designed for it; use this chapter to understand the principles and to optimize what you have. **All current values must come from your device's datasheet (power consumption tables); register details are from memory of RM0385 and not run on your board.** Always measure.

---

## 1. Power fundamentals

### 1.1 Average current decides battery life

```
I_avg = ( Σ I_k * t_k ) / T                     over one cycle T split into phases k
Battery life (h) = Capacity (mAh) / I_avg (mA)       (derate: 70-80 % usable, temperature, aging)
```

Example (illustrative numbers): a sensor node wakes once every 60 s: 20 mA for 50 ms (measure + transmit), 0.05 mA asleep otherwise:

```
I_avg = (20 mA * 0.05 s + 0.05 mA * 59.95 s) / 60 s = (1.0 + 3.0) / 60 = 0.0667 mA
Life with a 220 mAh coin cell ≈ 220 / 0.0667 = 3300 h ≈ 137 days (before derating)
```

Insight: **the sleep current dominates** when the duty cycle is low; the active phase dominates when it is high. Optimize the larger term first, and shorten the active phase (race to sleep).

### 1.2 Power in CMOS

```
P_dynamic ≈ C * V² * f * activity            (proportional to clock frequency and V²)
P_static  = leakage (grows with temperature and voltage; dominates in sleep)
```

Lower the frequency and voltage when the work allows, **gate clocks** of unused blocks, and switch off what you do not use.

### 1.3 Two strategies

- **Race to sleep**: run fast, finish quickly, sleep deeply. Often better because the CPU is idle most of the time anyway and leakage/sleep current is paid for the whole cycle.
- **Slow and steady**: lower frequency (and voltage scale) when work is continuous; peripherals (radio, ADC) may dominate.

Measure both for your workload: modern MCUs often favor race-to-sleep, but a radio or sensor with a fixed time cost can invert it.

---

## 2. STM32F7 power modes

The Cortex-M core has two architectural levels (**Sleep** and **Deep sleep**, chapter 3). On the STM32F7, with the PWR controller:

| Mode | CPU | Clocks | RAM | Wake-up sources | Notes |
|---|---|---|---|---|---|
| **Run** | Running | As configured | Retained | | Reduce frequency and disable unused peripheral clocks |
| **Sleep** | Stopped (`WFI`/`WFE`) | Peripherals keep running | Retained | Any enabled interrupt/event | Quickest wake-up, modest savings |
| **Stop** | Stopped | **1.2 V domain clocks stopped** (HSI/HSE/PLL off) | Retained (SRAM and registers) | EXTI lines, RTC alarm/wake-up timer, some peripherals | Regulator options (main/low-power, under-drive) trade current for wake-up time; **system restarts on HSI after wake-up** |
| **Standby** | Off | Almost everything off | **Lost** (except backup SRAM, backup registers, RTC domain) | WKUP pins, RTC alarm/wake-up, IWDG reset, NRST | Wake-up = reset |
| **VBAT** | VDD off | Only RTC and backup registers/SRAM from the battery | Backup domain | | Timekeeping with the main supply off |

Check the datasheet's **power consumption tables** for typical current in each mode and conditions (voltage, temperature, retained RAM, RTC on/off, regulator mode).

### 2.1 Entering Sleep

```c
__WFI();           /* sleeps until an enabled interrupt occurs; SysTick wakes it every tick unless disabled */
```

(Chapter 3: with `PRIMASK` set a pending interrupt still wakes the core without running its handler: a race-free idle pattern. `SCB->SCR |= SCB_SCR_SLEEPONEXIT_Msk` sleeps again automatically after each ISR.)

### 2.2 Entering Stop (outline; verify register and bit names in RM0385)

```c
void enter_stop(void)
{
    RCC->APB1ENR |= RCC_APB1ENR_PWREN;                 /* PWR block clock */
    PWR->CR1 &= ~PWR_CR1_PDDS;                         /* Stop, not Standby */
    PWR->CR1 |= PWR_CR1_LPDS;                          /* low-power regulator in Stop (slower wake-up): optional */
    SCB->SCR |= SCB_SCR_SLEEPDEEP_Msk;                 /* Deep sleep on WFI */
    __DSB();
    __WFI();                                           /* sleeps here */
    SCB->SCR &= ~SCB_SCR_SLEEPDEEP_Msk;                /* after wake-up: back to normal sleep semantics */
    clock_init_216mhz();                               /* the system restarted on HSI: reconfigure HSE/PLL (chapter 7) */
    /* re-enable SysTick if it was stopped, and any peripheral clocks/state not retained */
}
```

Points:

- **Wake-up from Stop uses HSI**: you must re-run the PLL setup (chapter 7) and wait for it.
- Peripheral registers and RAM are retained in Stop, but **in-progress transfers** are not meaningful; stop DMA/UART cleanly before and restart after.
- Before entering Stop, make sure **no interrupt is pending** (or the core wakes at once) and that your wake-up source is configured (EXTI line, RTC).
- Flash may be placed in power-down mode in Stop (`FPDS` bit) for additional savings at the cost of a longer wake-up.
- Debug connection may be lost in Stop/Standby unless `DBGMCU->CR` debug-in-low-power bits are set (chapter 4): leaving them set costs current: **clear them for power measurements**.
- Several advanced options (under-drive, regulator modes, over-drive off) exist; follow the RM section "Power control (PWR)" and the "Low-power modes" tables.

### 2.3 Wake-up with the RTC

The RTC runs from the LSE crystal (or LSI, less accurate) and can wake the system from Stop/Standby with an **alarm** or the periodic **wake-up timer**. Outline for Stop:

1. Enable backup-domain access (`PWR->CR1 |= PWR_CR1_DBP`), select and enable the RTC clock (`RCC->BDCR`).
2. Configure the RTC wake-up timer (`RTC->WUTR`, `CR`: `WUTE`, `WUTIE`, clock selection), unlocking the write protection with the key sequence `0xCA` then `0x53` in `RTC->WPR` and re-locking after.
3. Route the RTC wake-up event to the EXTI controller (the wake-up timer is connected to an internal EXTI line; unmask it and select the rising edge), and enable the NVIC IRQ (`RTC_WKUP_IRQn`).
4. Enter Stop; the ISR clears `RTC->ISR` flags and the corresponding EXTI pending bit.

(Many details: look at the RTC section of RM0385 and the ST examples; test one step at a time.)

### 2.4 Standby and the reset-on-wake pattern

After wake-up from Standby the chip **resets**; software detects it via `PWR->CSR1` (`SBF` flag), clears it, and may restore state from **backup registers/SRAM** (small, retained by VBAT/the backup regulator). Use Standby when the idle interval is long and the state to keep is tiny.

---

## 3. Reducing consumption: a checklist

### 3.1 Software and clocks

| Action | Effect |
|---|---|
| Lower `SYSCLK` (HSI 16 MHz instead of 216 MHz PLL) when you do not need speed | Dynamic power drops about proportionally |
| **Gate peripheral clocks** (`RCC->xxxENR` bits; and the `xxxLPENR` registers control which stay on in Sleep) | Saves current in Run and Sleep |
| Switch off PLL and HSE when idle; prefer HSI or MSI-like internal sources in light modes | |
| Turn off unused peripherals (ADC `ADON=0`, UART `UE=0`, timers stopped) | |
| Use **DMA** so the CPU can sleep during transfers | |
| **Event-driven design**: block on queues and interrupts; no polling loops | The CPU sleeps whenever idle |
| Use **tickless** idle (RTOS) or no periodic tick | Avoid waking every millisecond |
| Batch work: wake, do many things, sleep | Fewer wake-up overheads |
| Reduce flash wait states/ART settings appropriately for the frequency | |
| Keep interrupts efficient and short | Less active time |
| Lower voltage scaling where allowed (power scale options) | |

### 3.2 Pins and external hardware

| Action | Why |
|---|---|
| **Unused pins in analog mode** (or driven to a defined level) | Floating digital inputs draw current |
| Disable **pull-ups/pull-downs** that fight a driven level | A 100 kΩ pull-up held low at 3.3 V wastes 33 µA |
| Avoid LEDs always on; use short pulses | An LED at 2 mA dominates a µA budget |
| Put sensors/radios in their **standby** modes; cut their power with a **load switch** | |
| Choose **low quiescent current** regulators (LDO Iq of µA, not mA) | A 1 mA regulator quiescent current ruins a µA design |
| Use high-value dividers (MΩ) with a **switchable** measurement path | |
| Beware **leakage** paths: back-powering through I/O pins into an unpowered chip, protection diodes | |
| Check external pull-ups on I2C (a 2.2 kΩ pull-up held low sinks 1.5 mA!) | Release or switch off when idle |
| Remove or isolate **development hardware** (ST-LINK, board LEDs) when measuring | Nucleo boards consume far more than the MCU alone |

### 3.3 Radio and communications

Radios often dominate: reduce **on-air time** (short payloads, compact encoding), duty-cycle, use longer connection intervals/sleep modes, avoid retries (good link budget), batch transmissions. Wi-Fi association is expensive; BLE/LoRa/sub-GHz are designed for low duty cycle.

---

## 4. Measuring current correctly

### 4.1 Why it is hard

Currents range from **µA** (sleep) to **hundreds of mA** (active) within milliseconds. A multimeter's **burden voltage** (voltage drop across its shunt) can reset the MCU at high current and it averages slowly; a scope across a shunt resistor shows the waveform but lacks µA resolution.

### 4.2 Methods

| Method | Notes |
|---|---|
| Multimeter in series (µA/mA range) | Fine for steady sleep currents; range switching can brown-out the target; sees only an average |
| **Shunt resistor + oscilloscope/DAQ** | `V = I * R`: 10 Ω (100 mV at 10 mA) to 1 kΩ for µA; watch the voltage drop and add a capacitor/switching to avoid dropouts |
| **Dedicated profiler**: Nordic **PPK2**, Qoitech **Otii Arc**, EEVblog µCurrent (amplifier), Joulescope | Auto-ranging, long captures, energy integration, GPIO sync: the right tool |
| Lab supply with current display | Rough |
| Coulomb counter / fuel gauge ICs | Long-term energy |

Always **capture long enough** to include several full cycles, integrate to get the **average current/energy** (not just the peaks), and **synchronize** with a GPIO from the firmware to label phases.

### 4.3 Nucleo-144 measurement

The board has an **IDD measurement jumper (JP6)** in series with the MCU's VDD supply (verify in UM1974): remove the jumper and connect your ammeter/profiler in its place to measure the MCU alone. The ST-LINK part, LEDs and regulators draw current outside that path, so (a) measure at the IDD jumper, (b) power from the target-side 3.3 V where appropriate, (c) disconnect or disable the VCP traffic and any LEDs, (d) remember **debug stays powered** so the real in-system numbers differ. For a true low-power evaluation use your own board or an MCU board without a debugger.

### 4.4 A measurement procedure

1. Define the **scenario** (a full cycle of the product).
2. Flash a firmware build **without** debug-in-low-power bits and without semihosting; detach the debugger.
3. Measure the **baseline**: Run at 16 MHz doing nothing but a loop; Sleep; Stop; Standby. Record a table: mode, frequency, current.
4. Add features one by one; record the change in each (UART on, ADC sampling, LEDs, radio).
5. Mark phases with a GPIO and analyze charge per phase: `Q = ∫ I dt`.
6. Repeat at **temperature and voltage extremes** if the product requires it.

---

## 5. Software patterns

### 5.1 Sleep in the main loop

```c
for (;;) {
    event_dispatch_all();                 /* chapter 8 */
    __disable_irq();
    if (!event_pending()) { __WFI(); }    /* atomic: no event can be lost between the check and the sleep */
    __enable_irq();
}
```

### 5.2 Periodic wake-up design

```
Standby/Stop ─(RTC alarm every N s)─► init minimum ─► read sensor ─► process ─► (transmit?) ─► back to sleep
```

- Keep the wake-up path **short**: minimal clock configuration, no unnecessary initialization, reuse retained state.
- **Avoid printing** during wake cycles (UART at 115200 takes 87 µs per byte at full CPU power).
- Choose the **wake-up interval** to match what the application needs (not "as fast as possible").

### 5.3 Peripheral lifecycle

`power on ─► settle ─► use ─► power off`: wrap sensors, radios, ADC and displays in modules with `start/stop` so the application can power them only when needed (chapter 8).

### 5.4 RTOS idle and tickless

- FreeRTOS: `configUSE_TICKLESS_IDLE = 1` stops the tick during long idle periods; the default port sleeps with `WFI` in Sleep mode; for Stop you provide `vPortSuppressTicksAndSleep` with a low-power timer (RTC/LPTIM).
- Zephyr: tickless kernel and power management policies (`CONFIG_PM`); STM32F7 support is limited compared to newer families (chapter 9).
- In the idle hook: `__WFI()` is the minimum.

### 5.5 GPIO state across low-power modes

In **Standby**, GPIO states are lost (pins go to analog/floating unless pull-up/pull-down are configured via the PWR registers for wake-up pins); external circuits must tolerate it. In **Stop**, pin states are retained. Design the external hardware so floating pins during Standby are harmless.

---

## 6. Power supply and battery aspects

### 6.1 Batteries

| Chemistry | Voltage | Notes |
|---|---|---|
| CR2032 coin cell | 3.0 V nominal, drops to ~2.0 V | High internal resistance and **limited peak current** (a few mA continuous, ~15 mA pulses depending on the cell): add a bulk capacitor (100 µF-1 mF) for radio bursts; cells age and cold weather hurts |
| Alkaline AA/AAA | 1.5 V each | Cheap, sloping discharge curve, leakage risk |
| Li-SOCl2 (primary lithium) | 3.6 V | Very low self-discharge, long-life sensors; passivation |
| LiPo/Li-ion | 3.0-4.2 V | Rechargeable: needs a charger IC, protection, fuel gauge; regulate down to 3.3 V |
| Supercapacitor | Variable | Energy harvesting, bursts |

### 6.2 Regulation

- **LDO**: simplest; efficiency `Vout/Vin` plus Iq; good when Vin is close to Vout (e.g. a Li-SOCl2 cell at 3.6 V to 3.3 V).
- **Buck**: better at higher input voltage and load; check **light-load efficiency** and Iq (PFM/burst mode).
- Choose a regulator whose **Iq at your sleep load** is a small fraction of the sleep budget.
- **Brown-out**: the supply must not fall below the MCU's minimum (BOR) when the radio or flash write draws current: check the voltage with a scope during bursts.

### 6.3 Monitoring the battery

Divider + ADC (use a switched divider to avoid standby current); the internal **VBAT channel** only measures the backup pin; fuel-gauge ICs (coulomb counting) for accuracy. Provide a **low-battery policy**: reduce activity, warn, then protect data and shut down gracefully.

### 6.4 Energy harvesting and supercaps (overview)

Solar, thermal, vibration; very low sleep current is essential; **cold start** and energy-aware scheduling (do work only when enough energy is stored).

---

## 7. Debugging power problems

| Symptom | Likely cause and checks |
|---|---|
| Sleep current much higher than the datasheet | Debug-in-low-power bits set, peripherals/clocks left on, floating pins, pull resistors, LEDs, ST-LINK or board circuits included in the measurement, an external device not in standby |
| Never goes to sleep, or wakes immediately | Pending interrupt (SysTick, UART, EXTI), event flag set, `WFE` event register, interrupt not cleared |
| Wakes randomly | Noisy wake-up pin without pull, RTC alarm misconfigured, watchdog |
| Crashes after wake-up from Stop | Clocks not reconfigured (running on HSI), peripheral state assumptions, SysTick not restarted, PLL not locked before switching |
| Standby wake-up loops | Wake-up flag (`WUF`) not cleared, wake-up pin level still active |
| Current spikes drain the battery | Debug UART printing, retries, regulator inrush, radio on-time |
| Brown-out resets only on battery | Battery internal resistance, missing bulk capacitor, regulator dropout |
| Debugger lost after sleep | Normal in deep sleep unless debug-in-low-power is enabled (turn off for measurement) |
| Measurement jumpy | Meter range switching, averaging too slow: use a profiler or scope |

Method: **bisect the system**: measure the MCU alone in each mode, then add peripherals and external circuits one at a time until the extra current appears.

---

## 8. Exercises

1. **Baseline table**: measure the current of your board in Run (16 MHz and 216 MHz), Sleep and Stop (using the IDD jumper and a profiler/multimeter); compare with the datasheet.
2. **Clock gating**: disable all unused peripheral clocks and measure the saving; then change frequency and plot current vs frequency.
3. **Idle loop**: replace a busy-wait main loop with the `WFI` pattern of 5.1 and measure.
4. **Stop with RTC wake-up**: wake every second, toggle a GPIO, go back to Stop; verify the period with a logic analyzer and measure the average current; check that the clock is reconfigured correctly.
5. **Standby**: implement a counter in backup registers across Standby wake-ups; print it after each wake-up.
6. **Pin leakage**: leave a GPIO floating as input in Stop and compare with analog mode and with a defined output level.
7. **Pull-up cost**: add an external 10 kΩ pull-up and drive the pin low; calculate and measure the extra current.
8. **Duty cycle budget**: define a scenario (wake every 10 s, measure for 20 ms), compute the average current and battery life, then measure and reconcile the difference.
9. **Race to sleep**: run the same computation at 16 MHz and at 216 MHz; compare **energy per task** (charge integrated) and decide which is better.
10. **FreeRTOS tickless**: enable `configUSE_TICKLESS_IDLE` on a periodic-task application and measure the improvement in Sleep.
11. **Measurement tool**: build or buy a simple shunt-based current monitor and compare it with a multimeter on a pulsed load.
12. **Choose an MCU**: using datasheets, compare the sleep currents and wake-up times of the F746 and an ultra-low-power part (e.g. STM32L4/U5 or an nRF52) for a 5-year coin-cell scenario.

---

## 9. Cheat sheet

```
I_avg = Σ(I_k t_k)/T ; life(h) = mAh / mA_avg   (derate)
Dynamic power ∝ C V² f ; gate clocks ; race to sleep (measure!)
Modes: Run > Sleep (WFI) > Stop (SLEEPDEEP, PDDS=0, restart on HSI) > Standby (reset on wake) > VBAT
After Stop: reconfigure HSE/PLL (chapter 7). After Standby: check SBF, restore from backup registers.
Pins: unused → analog; no fighting pulls; switch off external loads and sensors.
Measure: IDD jumper + profiler; GPIO markers; disable debug-in-low-power.
```

| Question | Answer |
|---|---|
| Biggest lever for a low duty cycle? | Sleep current (and quiescent current of regulators/sensors) |
| For a high duty cycle? | Active current and time (radio, CPU frequency) |
| First thing to check when sleep current is high? | Debug bits, floating pins, pulls, external devices, the measurement path |
| Is the F7 a good fit for a coin cell? | Usually not: consider an ultra-low-power family |

---

## 10. Where this leads

- **Bootloader/security** (chapter 16): low-power wake-up for update windows, secure storage in backup domains.
- **Control and DSP** (chapter 13): lower sample rates, sleeping between samples.
- **PCB design** (chapter 21): power rails, regulators, and measurement points for low-power boards.
- **Zephyr/FreeRTOS** (chapters 9 and 12): tickless kernels and power policies.

## References

- ST RM0385 "Power controller (PWR)" and "Real-time clock (RTC)" chapters; the F746 datasheet "Power consumption" tables
- ST application notes on low-power modes and on measuring current (search "STM32 low-power" for your family)
- Nordic PPK2 and Qoitech Otii documentation (measurement practice)
- *Designing Embedded Systems with Ultra-Low-Power Considerations* (various TI/ST/Nordic white papers)
- Battery datasheets (Energizer CR2032, Saft LS14500) for capacity and pulse-current limits
