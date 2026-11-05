# 10. Electronics and Datasheets for Firmware Engineers

Goal: enough electronics to **read schematics and datasheets, wire things correctly, measure what is really happening, and tell a hardware problem from a software one**. Many "firmware bugs" are a missing pull-up, a dead decoupling capacitor, or a wrong voltage level.

Board used in examples: NUCLEO-F746ZG (3.3 V logic). **Component values and register-level numbers here are typical or illustrative: always confirm in the datasheet of your exact part.**

---

## 1. Quantities and laws

| Quantity | Symbol | Unit | Meaning |
|---|---|---|---|
| Voltage | V | volt (V) | Potential difference (always between two points) |
| Current | I | ampere (A) | Charge flow (always through something) |
| Resistance | R | ohm (Ω) | Opposition to current |
| Power | P | watt (W) | Energy per second |
| Charge/Capacitance | Q / C | coulomb / farad (F) | Stored charge; ability to store it |
| Inductance | L | henry (H) | Opposes changes of current |
| Frequency | f | hertz (Hz) | Cycles per second |

Laws you will use constantly:

```
Ohm:            V = I * R
Power:          P = V * I = I^2 * R = V^2 / R
Series R:       R = R1 + R2
Parallel R:     R = (R1 * R2) / (R1 + R2)
Divider:        Vout = Vin * R2 / (R1 + R2)          (unloaded)
Kirchhoff (current): currents entering a node sum to zero
Kirchhoff (voltage): voltages around a loop sum to zero
Capacitor:      I = C * dV/dt ;  RC time constant tau = R * C  (63 % in 1 tau, ~99 % in 5 tau)
Energy:         E = 1/2 * C * V^2   (capacitor);   E = V * I * t
Battery life:   hours = capacity_mAh / average_current_mA
```

Rules of thumb:

- Voltage is measured **across** a part (two probe points); current is measured **in series** (break the circuit). Putting an ammeter across the supply is a short circuit.
- Everything needs a **return path**: current flows in loops. "Ground" is a shared reference, not a magic sink.
- Power rating of resistors (1/8 W, 1/4 W): check `P = I^2 R` before using a resistor.

---

## 2. Components you will meet

### 2.1 Resistors

- Values follow the **E12/E24/E96** series (e.g. E12: 1.0, 1.2, 1.5, 1.8, 2.2, 2.7, 3.3, 3.9, 4.7, 5.6, 6.8, 8.2 times powers of ten). Tolerance 1 % to 5 %.
- Common roles in firmware boards: pull-up/pull-down (4.7 kΩ to 100 kΩ), series protection (100 Ω to 1 kΩ), LED current limiting, dividers for ADC (high values waste battery; low values load the source).
- **Pull-ups and pull-downs**: define a pin's level when nothing drives it. Weak (100 kΩ) saves power; strong (2.2-4.7 kΩ) gives faster edges (I2C). The STM32's internal pull resistors are roughly tens of kΩ and imprecise: do not use them where timing or accuracy matters.

### 2.2 Capacitors

| Type | Typical use | Caveats |
|---|---|---|
| Ceramic (MLCC, X7R/X5R/C0G) | Decoupling, filters, crystal loads | **Capacitance drops with DC bias** (a 10 µF 6.3 V X5R may be ~3 µF at 3.3 V); piezo/microphonic effects; C0G is stable but small values |
| Electrolytic (aluminum) | Bulk storage, power rails | Polarized; ESR; drying with age; limited temperature life |
| Tantalum / polymer | Bulk, low ESR | Tantalum can fail short when stressed: derate voltage |

Roles: **decoupling** (local energy reservoir for current spikes), **filtering** (RC low-pass, LC), **timing** (RC delays, debounce), **AC coupling**, **bulk storage**.

### 2.3 Inductors and ferrite beads

Inductors store energy (switching regulators); ferrite beads block high-frequency noise (analog supply filtering). Check saturation current (inductors) and DC resistance.

### 2.4 Diodes

| Diode | Use |
|---|---|
| Rectifier / signal (1N4148) | Clamp, steering |
| **Schottky** (low forward voltage, ~0.2-0.4 V) | Reverse polarity, OR-ing, flyback |
| **Zener** | Voltage reference/clamp |
| **LED** | Indicator: forward voltage ~1.8 V (red) to ~3 V (blue/white) |
| **TVS** | Surge/ESD protection on connectors |
| **Flyback** | Across relay/motor coils to absorb the inductive spike |

LED resistor: `R = (Vsupply - Vf - Vol) / I`. With 3.3 V, red LED Vf 2.0 V, 5 mA: `(3.3 - 2.0) / 0.005 = 260 Ω`, use 270 Ω (or 330 Ω). An LED is current-driven; never connect it without a resistor.

### 2.5 Transistors and switches

**N-channel MOSFET as a low-side switch** (load between supply and drain, source to ground, gate driven by the MCU):

```
 +V ──── load ──── drain
                    |
 MCU pin ─[100Ω]── gate      source ── GND      gate pulldown 10-100 kΩ to GND (defined off state)
```

- Choose a **logic-level** MOSFET (Rds(on) specified at Vgs = 2.5-4.5 V). Check `Rds(on)`, `Vgs(th)` (< 3.3 V well below), current, `Vds` max.
- Inductive load (motor, relay): add a **flyback diode** across the load.
- **High-side switching** needs a P-MOSFET or a gate driver; a load switch IC is easier.
- **BJT** (NPN, e.g. 2N3904, BC547): base resistor from `Ib = Ic / hFE` with a margin of 5-10x: for a 100 mA load with hFE ≈ 100, `Ib ≈ 5-10 mA`... use a MOSFET or driver when the load is large.
- **Never drive a motor, relay or large LED directly from a GPIO.** A pin gives a few mA (see datasheet) and has a **total package current limit**.

### 2.6 Op-amps (brief)

Voltage follower (buffer) for high-impedance sensors before the ADC; non-inverting amplifier `gain = 1 + Rf/Rg`; active filters; instrumentation amplifier for small signals. Check input/output swing (rail-to-rail), supply range, offset, GBW.

### 2.7 Power conversion

| Regulator | Pros | Cons |
|---|---|---|
| **LDO** (linear) | Simple, quiet, cheap | Efficiency `Vout/Vin`; heat `P = (Vin - Vout) * I`; needs dropout margin |
| **Buck** (switching) | High efficiency | Noise, layout-sensitive, needs inductor |
| Boost / buck-boost | Step up / either | Same |
| Charge pump | No inductor, small currents | Limited current |

Example: 5 V to 3.3 V LDO at 200 mA dissipates `(5 - 3.3) * 0.2 = 0.34 W`: warm but acceptable; at 1 A it is 1.7 W: use a buck. Mind **quiescent current** for battery products.

### 2.8 Crystals and oscillators

- A crystal needs two load capacitors: `CL = (C1 * C2) / (C1 + C2) + Cstray`; for equal `C1 = C2`, `C1 ≈ 2 * (CL - Cstray)`. Use the datasheet `CL` of the crystal and typical `Cstray` of 3-5 pF. Keep traces short, ground guard around.
- Your Nucleo: the HSE is an **8 MHz clock from the ST-LINK MCO** (no crystal); the LSE crystal (32.768 kHz) is for the RTC.
- Verify oscillators with a scope probe of low capacitance (loading can stop oscillation) or with the **MCO pin output** (chapter 7).

---

## 3. Digital I/O electrical reality

### 3.1 Logic levels

For a 3.3 V STM32: input low `VIL(max)` is roughly 0.3 x VDD, input high `VIH(min)` roughly 0.7 x VDD (check the table of **I/O static characteristics** in the datasheet). Outputs: `VOL` low, `VOH` high at a given load current. Between VIL and VIH a signal is **undefined**.

- **5 V devices**: only pins marked **FT** (5 V tolerant) in the datasheet pin table accept 5 V when VDD is on; never on analog inputs or when VDD is off.
- A 3.3 V output driving a 5 V input may not reach its VIH: use a level shifter.

### 3.2 Level shifting

| Method | Use |
|---|---|
| Resistor divider | One-way, slow, 5 V to 3.3 V signals |
| MOSFET bidirectional (BSS138) | I2C and open-drain buses |
| Dedicated translator IC (74LVC245, TXB0108, TXS0108) | Multi-bit buses; check direction/speed rules |

### 3.3 Inputs, switches and buttons

- A button to ground with a **pull-up** (internal or external) is the standard "active low" wiring. The Nucleo user button B1 is wired with a pull-down and reads high when pressed (verify on your board).
- **Debounce**: mechanical contacts bounce for 1-20 ms. In software (timer/state) or hardware: RC low-pass (R = 10 kΩ, C = 100 nF gives `tau = 1 ms`) optionally with a Schmitt-trigger input (the STM32's inputs have hysteresis, check the datasheet).
- **Floating inputs** pick up noise and draw extra current: always give inputs a defined level.
- Add a **series resistor (100 Ω-1 kΩ)** between a connector and the MCU pin to limit fault current; add TVS/ESD protection on exposed lines.

### 3.4 Output and current limits

Each pin has a source/sink limit (a few mA to ~20 mA absolute, with lower recommended values), and the whole chip has a **total current limit**. Respect both. Use transistors or drivers for loads and LEDs in bulk.

### 3.5 Open-drain vs push-pull

- **Push-pull** actively drives high and low.
- **Open-drain** only pulls low; a pull-up provides high. Allows wired-AND (I2C), level translation, multiple drivers on a line. Slower rising edges (`tau = R * C`).

---

## 4. Power supply, decoupling, reset, boot

### 4.1 Decoupling

Every VDD/VSS pair of the MCU needs a **100 nF** ceramic **as close as possible** (short loop to the pin and the ground plane), plus **bulk** capacitance (4.7-10 µF) near the supply entry. Fast digital edges draw current spikes the supply cannot deliver instantly; the capacitor does.

Typical STM32F7 power pins and what they need (**check ST's "getting started with STM32F7 hardware development" application note and the datasheet for your part**):

| Pin | Requirement |
|---|---|
| VDD (several) | 100 nF each + bulk |
| **VDDA / VREF+** | Analog supply and ADC/DAC reference: clean, with ferrite bead + 1 µF + 100 nF (or a dedicated reference) |
| **VCAP1/VCAP2** | Internal regulator output: external capacitors required (see datasheet value, ESR/ESL limits) |
| VBAT | Backup battery or tied to VDD (on the Nucleo, solder bridge SB156 isolates VBAT from VDD for backup-domain tests) |
| **BOOT0** | Pull-down for normal boot from Flash; must not float |
| **NRST** | 100 nF to ground plus pull-up (internal) and reset button; an external reset supervisor if needed |
| SWD (PA13/PA14) | Header for the debugger; keep accessible |

### 4.2 Supply budgeting

- Sum maximum currents of everything on a rail with margin (+30-50 %), including peaks (radio TX, motor start, SD card writes).
- A rail dropping below the **brown-out** level resets the MCU (BOR option byte). Spiky loads need local bulk capacitance.
- **USB 5 V** from a PC allows 100 mA before enumeration, 500 mA after (USB 2.0), more with USB-C PD/charging negotiation. Inrush from big capacitors can trip protection.
- Reverse polarity protection: Schottky diode in series (loses ~0.3 V) or a P-MOSFET ideal diode.
- Fuses/polyfuses protect against shorts; TVS protects against surges.

### 4.3 Reset and boot checks (symptom: "the board is dead")

1. Measure the supply rails with a multimeter: 3.3 V present and stable?
2. Is NRST high? A stuck-low reset keeps the MCU off.
3. Is BOOT0 low?
4. Does the debugger connect (`Target voltage` in OpenOCD, chapter 4)?
5. Is the HSE/oscillator running (MCO or scope)? If HSE fails, the MCU falls back to HSI only if the firmware handles it.
6. Is anything pulling a line to ground (short between rails: check resistance rail to ground with power off; a few ohms means a short or a reversed capacitor)?

---

## 5. Analog front-end for the ADC

### 5.1 Reference and accuracy

The ADC result is `raw = Vin / VREF * 4095` (12 bit). If VREF/VDDA is noisy or not exactly 3.3 V, so are the readings. The ADC's real accuracy (offset, gain, nonlinearity, noise) is in the datasheet: effective resolution is about 10-11 bits, not 12.

### 5.2 Source impedance and sample time

The ADC input is a sampling capacitor (`C_ADC`, a few pF) behind a switch resistance. The source must charge it during the sample time. The datasheet gives the maximum source resistance as a function of sampling time and ADC clock (formula in the "ADC characteristics" section):

```
R_AIN(max) = T_s / (f_ADC * C_ADC * ln(2^(N+2)))  -  R_ADC
```

Where `T_s` is the sample time in ADC cycles, `N` the resolution. Rule: **high-impedance source means longer sample time** or a buffer. A 10 kΩ potentiometer is usually fine with a 56-480 cycle sample time; a 1 MΩ divider is not.

A small **capacitor (10-100 nF) at the ADC pin** (after a resistor) helps by supplying the charge; combined with R it forms an anti-alias filter (`fc = 1 / (2 * pi * R * C)`).

### 5.3 Dividers and scaling

```
Vin_max (e.g. 12 V) -> divider -> 3.3 V full scale
R1 = 33 kΩ, R2 = 10 kΩ:  Vout = Vin * 10 / 43 = 0.2326 * Vin   (12 V -> 2.79 V)
```

- Use 1 % resistors; total divider current `Vin / (R1 + R2)` is wasted from the battery.
- Protect the pin: a series resistor and clamp diodes/TVS for inputs that may exceed the range.
- Measuring battery voltage: divider + optional MOSFET to disconnect it between measurements (zero standby current).

### 5.4 Noise and layout

- Keep analog traces away from clocks and switching nodes; use a solid ground plane.
- Separate analog supply (ferrite + capacitors), average many samples (reduces noise by `sqrt(N)`), sample at a quiet time (not during radio or motor switching).
- Use a precision reference or ratiometric measurement (sensor supplied from the same VDDA) when absolute accuracy matters.

---

## 6. Buses: electrical details

### 6.1 UART

TTL 3.3 V levels (idle high). **RS-232** uses ±3 to ±15 V (needs a level converter like MAX3232). **RS-485** is differential, multi-drop, long cable (needs a transceiver and direction control, 120 Ω termination at both ends, bias resistors). USB-UART adapters (CP2102, FT232, CH340): match the **3.3 V** level; TX of one goes to RX of the other, and **ground must be shared**.

### 6.2 I2C

Open-drain bus with pull-ups. Choose `Rp` from the I2C specification:

```
Rp(max) = t_r / (0.8473 * C_bus)         t_r = 1000 ns (100 kHz), 300 ns (400 kHz)
Rp(min) = (VDD - 0.4 V) / 3 mA           (low-level sink current 3 mA)
```

Example: 400 kHz, `C_bus` = 100 pF: `Rp(max) = 300e-9 / (0.8473 * 100e-12) = 3.5 kΩ`; `Rp(min) = (3.3 - 0.4) / 0.003 = 967 Ω`; pick 2.2 kΩ. Bus capacitance limit is 400 pF: long wires and many devices slow edges. Use a logic analyzer to view rise times; rounded edges mean too much capacitance or too weak a pull-up. Two devices with the **same address**, or sensors needing different voltage levels, need a multiplexer (TCA9548A) or level shifting.

### 6.3 SPI

Push-pull, single-ended, fast. Keep traces short; add **series resistors (22-100 Ω) at the driver** for fast signals to damp reflections; chip select per slave; mind idle clock level (mode) and tri-state MISO when not selected (some devices do not tri-state: use a buffer).

### 6.4 CAN

Differential pair CANH/CANL with a transceiver (e.g. TJA1051/MCP2551), **120 Ω termination at each end of the bus** (60 Ω measured across the pair with the power off, between CANH and CANL), twisted pair, common-mode choke and ESD protection for harsh environments. The MCU's CAN peripheral outputs TX/RX at logic levels only.

### 6.5 USB

D+/D- 90 Ω differential, 22-33 Ω series resistors if the PHY requires them (see the ST application note), ESD protection (USBLC6), 48 MHz clock (PLLQ), VBUS sensing through a divider, shield handling. A USB data cable, not a charge-only one.

### 6.6 Ethernet

RMII to an external PHY (the Nucleo uses an on-board PHY), magnetics in the RJ45, 50 MHz reference clock, controlled-impedance pairs, careful layout. Use reference designs.

---

## 7. Reading datasheets

### 7.1 Documents for an STM32 and what is in each

| Document | Use it for |
|---|---|
| **Datasheet** (STM32F745xx/F746xx) | Feature list, **pinout and alternate-function table**, **electrical characteristics** (supply, I/O, ADC, timings), absolute maxima, package drawings |
| **Reference manual** RM0385 | Peripheral registers and behavior |
| **Programming manual** PM0253 | Core instructions, NVIC, faults |
| **Errata sheet** (ES0xxx for your device) | **Known silicon bugs and workarounds**: read it before blaming your code |
| **Application notes** (AN) | Hardware design guidelines, clock config, ADC accuracy, DMA, bootloader protocol (AN2606) |
| **User manual** (UM1974 for the Nucleo-144) | Board connectors, jumpers, solder bridges, schematics |

The silicon bug warning in your OpenOCD log (`single stepping may enter pending exception handler`) is an example of an erratum of that core revision.

### 7.2 Reading any component datasheet: a checklist

1. **First page**: what is it, key features, applications, pinout and package.
2. **Absolute maximum ratings**: never exceed (damage). Not operating limits.
3. **Recommended operating conditions**: where it is specified to work (supply range, temperature).
4. **Electrical characteristics**: tables with **min / typ / max** and test conditions. Design with min/max, not typ.
5. **Timing characteristics and diagrams**: setup/hold times, SPI/I2C timing, startup time.
6. **Pin description**: function, type, and what to do with unused pins.
7. **Typical application circuit** and layout guidelines: copy them.
8. **Register map** (for chips with a digital interface): reset values, access types.
9. **Package/footprint** drawings and soldering notes.
10. **Revision history and errata**.

Decision questions for any new part: voltage and interface compatibility, current consumption, timing limits, package you can solder, availability and price, driver library, temperature range.

### 7.3 STM32-specific tables worth bookmarking

- **Pin definitions / alternate function mapping** (datasheet): which pin supports which peripheral function (chapter 7 uses it for UART/TIM/I2C pins).
- **Operating conditions**: VDD range, flash wait states vs frequency.
- **I/O port characteristics**: VIL/VIH, VOL/VOH, pin and total current limits.
- **ADC characteristics**: maximum source resistance, sample time, accuracy.
- **Power consumption** tables by mode and frequency (chapter 15).
- **Reset/BOR thresholds**.

---

## 8. Reading schematics

- **Reference designators**: R resistor, C capacitor, L inductor, D diode, Q transistor, U IC, J connector, SW switch/button, X/Y crystal, F fuse, TP test point, JP jumper, SB solder bridge.
- **Net labels** with the same name are connected even without a wire; **power symbols** (+3V3, GND) connect globally.
- **Hierarchical sheets** hide sub-blocks; look for the sheet pins.
- **Not-fitted parts** (DNP/NF, 0 Ω links, solder bridges) switch configurations. The Nucleo has many (SBxx), as shown in its user manual.
- Trace a signal from the MCU pin to the connector: which resistors, which protections?

Exercise with your board: open the **MB1137 schematic** (in the UM1974 or on the ST site) and find:

1. LD1/LD2/LD3: which MCU pins, which resistors, and the polarity of the LED connection.
2. User button B1: pin, pull resistor, any RC filter.
3. Where the 8 MHz HSE clock comes from (ST-LINK MCO, solder bridges).
4. The USART3 route to the ST-LINK VCP and the solder bridges that connect it.
5. VBAT connection (SB156).
6. The IDD measurement jumper (see chapter 15).
7. 3.3 V regulator and the supply path (USB, E5V, external).

---

## 9. Instruments

| Instrument | Use | Tips |
|---|---|---|
| **Multimeter** | Voltage, resistance, **continuity**, diode test, current (in series) | First tool for dead boards. Resistance only with power off. Current ranges have a fuse; set the right range before measuring |
| **Bench power supply** with current limit | Power a prototype safely | Set a **current limit** a bit above expected so a short does not burn parts |
| **Oscilloscope** | Voltage vs time: edges, noise, ripple, clocks | Use **10x probes**, compensate them, keep the ground lead short (use the spring tip for fast signals), choose bandwidth ≥ 5x the signal frequency, trigger on the edge of interest |
| **Logic analyzer** | Digital protocols (UART/SPI/I2C/CAN), timing of GPIOs | 8-channel USB analyzers (clones of Saleae) with sigrok/PulseView or Saleae software; sample rate ≥ 4-10x the signal frequency; use the protocol decoders |
| **USB power meter / current analyzer** | Current consumption | Nordic PPK2, Otii Arc, or a shunt + scope for sleep currents (chapter 15) |
| **Function generator** | Test inputs | Or a spare MCU/timer pin |
| **Soldering iron, hot air, flux, wick** | Assembly and rework | Temperature control; lead-free needs hotter iron; flux is your friend |
| **Magnifier/microscope** | Inspect joints | Many "dead boards" have a bridge or a cold joint |

Safety: ESD (touch a grounded object before handling chips), power off before rewiring, never touch mains, observe polarity, watch capacitor ratings, wear eye protection when cutting leads or soldering.

---

## 10. Debugging hardware problems

### 10.1 The method

1. **Observe and reproduce**: what exactly fails, under what conditions?
2. **Check power first**: rails, ripple, current draw, resets.
3. **Check clocks and reset**: the chip must be alive.
4. **Check the debug link**: if SWD connects, the MCU runs.
5. **Make a minimal firmware** (blink or UART hello) to separate hardware from software.
6. **Measure, do not guess**: put the probe on the actual pin, with the actual signal.
7. **Change one thing at a time**; compare with a known-good board.
8. **Isolate**: disconnect peripherals until it works, then add back.
9. **Write down** what you measured: it prevents loops.

### 10.2 Typical problems

| Symptom | Likely hardware cause |
|---|---|
| Random resets | Supply dips (brown-out), missing decoupling, noise on NRST, watchdog |
| Works on USB power but not on battery | Battery internal resistance, regulator dropout, inrush |
| ADC noisy or offset | Noisy VDDA, high source impedance, no ground reference |
| I2C device not found | No pull-ups, wrong address (7-bit vs 8-bit), swapped SDA/SCL, wrong voltage, device in reset |
| I2C works only slowly | Pull-ups too weak or bus capacitance too high |
| SPI garbage | Wrong mode, long wires, no common ground, chip select timing |
| UART garbage | Baud mismatch (wrong clock after PLL), TX/RX swapped, wrong level, no common ground |
| MCU hot or very high current | Short, floating input oscillating, contention (two outputs fighting), reversed supply |
| Crystal does not start | Wrong load capacitors, long traces, probe loading, too much drive |
| Debugger cannot connect | SWD pins reused, board unpowered, reset held, BOOT/option bytes, bad cable |
| Intermittent behavior | Cold solder joint, loose breadboard contact, ESD damage, thermal drift |
| Board works until something is touched | Floating pin, missing ground, poor shield |

### 10.3 Breadboard and wiring hygiene

- Keep wires short; use a **common ground** between all boards (including the USB-UART adapter and sensors).
- Power sensors from the right voltage (3.3 V for most modules, 5 V for some: check the board).
- Add a 100 nF capacitor across the supply of each module if the board has none.
- Prefer soldered or well-crimped connections for anything that moves.
- Label wires; photograph the setup before changes.

---

## 11. Hands-on exercises with the Nucleo

1. **LED current**: calculate the resistor for an external LED on a GPIO; measure the voltage across the resistor with the multimeter and compute the real current.
2. **Logic levels**: toggle a GPIO and measure high/low with the scope; compare with VOH/VOL in the datasheet. Load it with a resistor and see how the level moves.
3. **Debounce**: probe the user-button pin with a scope in single-shot mode; capture the bounces; add an RC filter and compare.
4. **I2C pull-ups**: with a logic analyzer on SCL/SDA, try external pull-ups of 10 kΩ, 4.7 kΩ and 2.2 kΩ with a real sensor; measure rise times and find the failure threshold at 400 kHz.
5. **ADC source impedance**: read a potentiometer, then a high-resistance divider (1 MΩ) at different sample times; observe the error and fix it with a capacitor.
6. **UART timing**: measure the bit time of one character on the scope and verify the baud rate (chapter 7).
7. **Clock check**: output HSE and the PLL on MCO1 (PA8) and verify the frequency.
8. **Power**: with a bench supply (or the Nucleo's 3.3 V), measure the board current; find the IDD jumper and measure only the MCU (chapter 15).
9. **Brown-out**: slowly lower an external supply on the MCU and find the reset threshold; compare with BOR settings.
10. **Read the schematic**: complete the checklist of section 8 for the Nucleo.
11. **Errata hunt**: read the errata sheet of your chip and find three items that may affect your projects; write a note on the workaround.
12. **Build a small circuit**: an N-MOSFET driving a small load (LED strip or motor) with a flyback diode, controlled by PWM from TIM4 (chapter 7).

---

## 12. Cheat sheet

```
Ohm / power      V=IR   P=VI=I²R=V²/R
Divider          Vout = Vin * R2/(R1+R2)
RC               tau=RC ; fc=1/(2πRC)
LED resistor     R=(Vcc-Vf-Vol)/I
I2C pull-up      Rp(max)=tr/(0.8473*Cb) ; Rp(min)=(Vdd-0.4)/3mA
Crystal load     C1=C2≈2(CL-Cstray)
LDO heat         P=(Vin-Vout)*I
Battery life     h = mAh / mA_avg
ADC              raw = Vin/VREF*4095 ; check source R vs sample time
```

| Question | Where to look |
|---|---|
| Can I connect these two voltages? | Absolute maxima, VIH/VOH, FT pins |
| Which pin does function X? | Datasheet alternate-function table |
| How much can the pin drive? | I/O characteristics + total current limit |
| Why does it reset? | Supply, NRST, BOR, watchdog, reset flags (`RCC->CSR`) |
| Is it a known chip bug? | Errata sheet |
| What did the board designers do? | Schematic and user manual |

Hardware debugging order: **power, reset, clock, debug link, minimal firmware, then peripherals.**

---

## 13. Where this leads

- **Protocols** (chapter 11): the electrical details here explain most bus failures.
- **Low power** (chapter 15): measuring microamps and designing the supply path.
- **PCB design** (chapter 21): turning a schematic into a board.
- **Bootloader/security** (chapter 16): option bytes, read-out protection, and hardware security features.

## References

- ST: STM32F746 datasheet, RM0385, PM0253, errata sheet for your device, UM1974, and the hardware development application note for STM32F7
- *The Art of Electronics*, Horowitz and Hill (reference); *Practical Electronics for Inventors*, Scherz and Monk
- *Make: Electronics*, Charles Platt (hands-on introduction)
- NXP UM10204: I2C-bus specification and user manual
- TI application notes on I2C pull-ups, ESD protection, and decoupling
- Sigrok / PulseView: <https://sigrok.org>