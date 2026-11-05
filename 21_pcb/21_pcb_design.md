# 21. PCB Design with KiCad: From Schematic to a Board You Can Order

Goal: learn the workflow and the **rules that make a microcontroller board work the first time**, using the free and open-source **KiCad** suite. You will not become a layout expert from one chapter, but you will be able to design, order and bring up a simple 2-layer STM32 board and understand what the Nucleo's designers did.

Prerequisites: chapter 10 (electronics, datasheets, decoupling, buses), chapter 7 (peripherals/clock), chapter 16 (boot pins, option bytes).

**Verification note.** KiCad's menus, library names and fabrication-house capabilities (minimum trace/space, drill sizes, prices, lead times) **change often**. Verify rules against your fabricator's current "capabilities" page and the ST hardware design application note for your exact MCU. Numbers here are typical starting points, not guarantees. Nothing here has been fabricated or tested by me. Never design mains-powered or safety-critical hardware without proper training and certification.

---

## 1. The design flow

```
 Requirements ─► block diagram ─► part selection ─► schematic (ERC)
      ─► footprints ─► placement ─► routing ─► DRC ─► outputs (Gerber, drill, BOM, pick&place)
      ─► fabrication (+ assembly) ─► bring-up ─► test ─► revision
```

Plan **bring-up** from the start: test points, debug header, power LEDs, jumpers to isolate sections, a schematic notes list. Expect a **second revision**: the first board teaches you what you missed.

### 1.1 Requirements and block diagram

- Function, interfaces (USB, UART, CAN, I2C sensors, display), supply (USB 5 V, battery, mains adapter), **power budget** (chapter 10), size/shape, environment (temperature, vibration, EMC), cost and volume, how it will be programmed and tested.
- A block diagram with the power tree (source → protection → regulators → rails), clocks, buses and connectors.

### 1.2 Part selection

Check each part for: electrical fit (voltage, current, interface), **package you can solder or have assembled**, **availability and lifecycle** (stock at several distributors; Digi-Key, Mouser, LCSC, Farnell), price, datasheet quality, reference design, and a software driver. Prefer **common parts** and **second sources**. For passives use a few standard values (E12/E24) and sizes (0402/0603 for assembly services; 0805 or larger for hand soldering).

---

## 2. KiCad overview

| Component | Purpose |
|---|---|
| **Project manager** | Creates the project (`.kicad_pro`), launches the tools |
| **Schematic editor** (Eeschema) | Draw the circuit, annotate, ERC, BOM |
| **Symbol editor** | Create/modify schematic symbols |
| **Footprint editor** | Create/modify PCB footprints (pads, courtyard, silkscreen) |
| **PCB editor** (Pcbnew) | Layout, routing, DRC, zones, 3D viewer, Gerber export |
| **Gerber viewer** | Check the fabrication files |
| **Calculator tools** | Track width, impedance, color code, regulators, attenuators, E-series |
| **`kicad-cli`** | Command-line exports for automation and CI (ERC/DRC, Gerbers, PDFs, BOM) |

Install: `sudo apt install kicad` (Ubuntu repositories may be behind) or the **official PPA/Flatpak** for the latest stable; then install the official libraries (symbols, footprints, 3D models). Check the KiCad documentation for the current release and for ready-made STM32 symbols/footprints; many libraries are included. Learn with the official **Getting Started** guide and tutorials.

Project hygiene: keep the project in **git** (text files diff fine); commit generated outputs only for releases; add `*-backups/`, `fp-info-cache`, and `*.lck` to `.gitignore`; use project-local libraries for custom parts so the project is self-contained.

---

## 3. Schematic design

### 3.1 Conventions

- One idea per sheet: **power**, **MCU**, **connectors**, **sensors**, **USB/communications**; use hierarchical sheets for larger boards.
- **Net labels** for buses and signals; **power symbols** (`+3V3`, `GND`) and `PWR_FLAG` where a power net is driven by a connector/regulator (ERC needs it).
- Reference designators: R, C, L, D, Q, U, J, SW, Y/X, F, TP; **annotate** all (Tools → Annotate).
- Values and **footprints assigned** to every symbol; add **MPN/manufacturer, supplier part number** fields for BOM and ordering.
- Put **notes** in the schematic: why a resistor is there, boot configuration, jumper settings, expected voltages.
- Group related components visually (decoupling capacitors next to the MCU power pins in the drawing).
- Mark optional parts **DNP** (do not populate) and **0 Ω links/solder jumpers** to configure alternatives (as ST does on the Nucleo).
- Run **ERC** (Electrical Rules Check) and resolve or consciously waive every warning.

### 3.2 A minimal STM32F7 system (LQFP144 as on the Nucleo's F746ZG)

For your exact part, follow ST's **hardware development getting-started application note** for the F7 family and the datasheet pin table. Typical blocks:

| Block | Notes |
|---|---|
| **Power** | 3.3 V regulator sized with margin; reverse-polarity and overcurrent protection; bulk capacitor |
| **VDD pins** | **100 nF per VDD pin**, close to the pin, plus bulk 4.7-10 µF |
| **VDDA / VREF+** | Separate filtering (ferrite bead + 1 µF + 100 nF), clean reference for the ADC |
| **VCAP1/VCAP2** | Internal regulator output: required capacitors with the specified value and low ESR (datasheet) |
| **VBAT** | Coin cell with a diode/jumper, or tied to VDD |
| **BOOT0** | Pull-down to ground (resistor), with a jumper/button to 3.3 V for the ROM bootloader |
| **NRST** | 100 nF to ground, pull-up (internal ok), reset button, test point |
| **HSE** | 8 MHz (or 25 MHz) crystal with load capacitors calculated from the crystal's `CL` (chapter 10), short traces, ground guard; or an external clock |
| **LSE** | 32.768 kHz crystal for the RTC |
| **SWD** | 2x5 1.27 mm Cortex debug header or **Tag-Connect** footprint (no connector cost), pins SWDIO, SWCLK, GND, VTref, NRST, optional SWO |
| **USB** | Connector, ESD protection (e.g. USBLC6-2), series resistors if required, 5 V sensing divider, 48 MHz clock accuracy |
| **Status** | Power LED, user LEDs, user button |
| **Test points** | 3.3 V, GND, UART TX/RX, key signals |
| **Unused pins** | Define their configuration in firmware (analog) and leave footprints/pads accessible via headers if useful |

### 3.3 Interfaces

- **I2C**: pull-up resistors (chapter 10: pick `Rp`, place one set per bus), address configuration jumpers.
- **UART to PC**: USB-UART bridge chip or expose a header for an adapter; or use the MCU's native USB (CDC).
- **CAN**: transceiver, 120 Ω termination (jumper or solder link), common-mode choke/ESD.
- **Analog inputs**: dividers, filters, clamping, protection (chapter 10).
- **Power outputs**: protection, current limit, flyback diodes, MOSFET drivers.
- **Connectors**: choose by current, mating cycles, keying, and **make pin 1 and polarity obvious** on the silkscreen; add ESD/TVS and series resistors on external lines.

### 3.4 Schematic review checklist

- [ ] Every IC power pin connected and decoupled; no pin left unintentionally floating.
- [ ] Voltage levels and **absolute maxima** respected at every interface (including during power-up/down).
- [ ] Pull-ups/pull-downs where defaults matter: **BOOT0**, chip selects, resets, enables, I2C.
- [ ] Reset circuit and boot options reachable; debug header correct (pin order against the probe's cable).
- [ ] Regulator input/output capacitors per its datasheet; **dropout**, current, thermal dissipation (`(Vin-Vout)*I`).
- [ ] Crystal load capacitors computed; oscillator frequency/accuracy suits the peripherals (USB needs accuracy).
- [ ] ADC reference and analog filtering considered.
- [ ] ESD/overvoltage/reverse polarity protection at external connectors.
- [ ] Correct **footprint** for every part (pin 1, pitch, package variant); verify against the **datasheet's land pattern** and 3D model.
- [ ] Alternate-function assignments consistent with the datasheet table and CubeMX (and no conflicts: SWD, boot pins, USB pins, Ethernet RMII pins).
- [ ] Test points and jumpers for bring-up; LEDs for status.
- [ ] BOM complete with MPNs; availability checked.
- [ ] Review by a second person, reading the schematic against the datasheets, pin by pin.

---

## 4. Footprints and packages

| Package | Notes |
|---|---|
| **LQFP144/100/64/48** (QFP) | Leaded pins, 0.5 mm pitch (LQFP144 for the F746ZG): drag solder or reflow; hand-solderable with care and flux |
| **QFN/DFN** | No leads, exposed thermal pad: reflow or hot air; tricky by hand |
| **BGA** (e.g. TFBGA216 for large F7) | Needs reflow, fine pitch, more layers, X-ray/inspection; avoid for a first board |
| **SOT-23, SOIC, TSSOP** | Common small ICs |
| **0402/0603/0805 passives** | 0603 or larger are comfortable by hand; 0402 and below mostly for assembly services |

Rules: use KiCad's standard libraries or the **manufacturer-recommended land pattern**, verify **pin 1 orientation and numbering** and the **3D model** overlay, include a **courtyard**, silkscreen outline, and a polarity mark; for hand soldering extend pads slightly. Create custom footprints carefully and **print the PCB at 1:1 on paper** to test-fit real components before ordering.

---

## 5. PCB layout fundamentals

### 5.1 Board setup

- **Layers**: **2-layer** (top/bottom) is fine for simple MCU boards at modest speeds if the ground plane is managed well; **4-layer** (signal/GND/power/signal) greatly eases routing and EMC for fast designs (Ethernet, SDRAM, USB HS) and is cheap today.
- **Design rules** from the fabricator: minimum **track width/clearance**, **drill size**, **annular ring**, **via size**, board outline and edge clearance, silkscreen limits. Typical economical rules start around 0.15-0.2 mm (6-8 mil) track/space and 0.3 mm drill vias; use wider where possible (0.25-0.5 mm for general signals, more for power).
- **Net classes**: Default signals, Power (wider tracks), High-speed/differential (specific width/gap).
- Choose the **board stack-up** the fabricator offers (thickness, copper weight 1 oz typical, controlled impedance options for USB/Ethernet if required).
- Board **size and mounting holes**, connector locations on edges, keep-out areas, fiducials for assembly.

### 5.2 Placement (most important step)

1. Place **connectors, mounting holes, and mechanical constraints** first.
2. Place the **MCU** centrally; place the **crystal very close** to its pins; place **decoupling capacitors right at each VDD pin** (shortest loop to the pin and via to ground).
3. Group **functional blocks** (power, analog, digital, USB, RF) and separate noisy (switching regulators, motor drivers) from sensitive (ADC inputs, oscillators, sensors).
4. Keep **signal flow** logical; minimize crossing; orient parts for short, straight routes.
5. Place **test points** and the debug header where probes reach.
6. Leave room for **routing channels** and rework.

### 5.3 Power and ground

- A **solid, unbroken ground plane** on a layer under the MCU is the single most valuable layout feature. Use many **ground vias** near decoupling capacitors, connectors and return paths. On a 2-layer board, pour ground on both layers with stitching vias.
- **Return currents** follow the path of least impedance, right under the signal: **never cut the ground plane under fast signals**; avoid routing across plane splits/slots.
- **Decoupling loop area**: capacitor pad → via to ground and power pin → MCU pin forming the **smallest possible loop**; connect the capacitor directly to the pin, then to the plane.
- **Power distribution**: wider tracks or planes for rails; star or low-impedance distribution; each rail with bulk and local capacitors; check **current capacity** with a track-width calculator (KiCad Calculator Tools: IPC-2221 based); 1 oz copper outer layers carry roughly 1 A per 0.3-0.5 mm of width at a modest temperature rise: **verify with the calculator**.
- **Analog**: keep VDDA/VREF filtered and separate; route analog inputs away from clocks and switching nodes; place the ADC filter parts at the input pins; avoid running digital signals under analog areas.
- **Switching regulators**: minimize the **hot loop** (input capacitor, switch, diode/inductor), place the inductor and capacitors per the datasheet layout example, keep the feedback trace short and away from the inductor.

### 5.4 Routing

- Route **critical signals first**: crystal, USB differential pair, high-speed buses, analog inputs; then power; then the rest.
- **Right-angle bends** are fine at modest speeds; prefer 45° as a habit; avoid acute angles and stubs.
- **Differential pairs** (USB 90 Ω differential): keep the pair tightly coupled, equal length, with a continuous reference plane; use KiCad's differential-pair routing; match the fabricator's impedance tables for your stackup.
- **Crystal**: short, symmetric traces, no other signals nearby, ground guard ring/plane underneath, load capacitors adjacent.
- **Length matching** only where required (SDRAM, QSPI at high speed, Ethernet pairs).
- **SPI/I2C/UART** at kHz-MHz rates are forgiving; very fast edges need series damping resistors near the driver (chapter 10).
- Avoid **long parallel runs** of unrelated signals (crosstalk); keep sensitive lines short.
- Use **vias sparingly** on fast signals; add ground vias when a signal changes layers.
- **Thermal**: exposed pads need thermal vias to a plane; power devices need copper area.
- **Teardrops**, **zone fills** (copper pours) with sensible clearances, and **thermal reliefs** on pads for hand soldering.

### 5.5 EMC and ESD basics

- Small loop areas (power and signal), continuous return paths, filtering at connectors (ferrites, RC, TVS), common-mode chokes on USB/CAN where necessary, shielded cables if needed, correct grounding of connector shells.
- ESD protection **at the connector**, with a short, low-inductance path to ground, before signals reach the MCU.
- Pre-compliance tests (near-field probes, spectrum analyzer) before formal EMC; design for compliance with the reference layouts of ST and chip vendors.

### 5.6 Silkscreen and documentation on the board

- Reference designators readable (not under components), **pin 1** marks, connector pin names, polarity, **board name, version, date**, a logo if you like.
- Test point labels and jumper function labels (`BOOT0`, `SWD`, `3V3`, `GND`, `TX`, `RX`).
- Keep silkscreen off pads (the CAM will clip it).

---

## 6. Checks before ordering

### 6.1 DRC and ERC

Run **DRC** (clearances, unconnected nets, courtyard overlaps, drill/annular ring, silkscreen over pads) with **no errors**; justify warnings. ERC on the schematic before layout; keep the schematic and PCB **in sync** (Update PCB from Schematic).

### 6.2 Manual review checklist

- [ ] **Footprints match the real parts** (printed 1:1 test fit; verify pin 1 and orientation).
- [ ] Decoupling capacitors adjacent to each VDD pin; ground vias nearby.
- [ ] Crystal and its capacitors tight; no tracks beneath unless ground.
- [ ] Ground plane continuous; no slots under high-speed lines; stitching vias placed.
- [ ] Power track widths adequate; no thin bottlenecks.
- [ ] **Connectors**: correct pinout and mirror orientation (top vs bottom mating), mechanical fit, keep-out zones.
- [ ] Debug header pinout matches the probe; **BOOT0** and **NRST** accessible; test points present.
- [ ] Silkscreen readable, polarity marked, version printed.
- [ ] Board outline, mounting holes, edge clearance for parts and copper.
- [ ] Solder mask and paste layers sensible; no exposed copper where a short is likely.
- [ ] 3D viewer check for mechanical collisions with the enclosure.
- [ ] Second person's review.

### 6.3 Outputs (KiCad)

- **Gerber files** for each layer (copper, mask, silkscreen, paste, edge cuts), **drill files** (Excellon, PTH/NPTH), usually zipped; many fabricators have a KiCad-specific instruction page.
- **BOM** (CSV) with MPN and supplier numbers; **pick-and-place** (position/CPL) file for assembly; assembly drawing PDF; schematic PDF; 3D STEP for the mechanical designer.
- View the Gerbers in the **Gerber viewer** (or the fabricator's online viewer) before ordering.
- Automate with `kicad-cli` (check available commands/options in your version):

```bash
kicad-cli sch erc  board.kicad_sch --output erc.rpt
kicad-cli pcb drc  board.kicad_pcb --output drc.rpt --severity-error
kicad-cli pcb export gerbers board.kicad_pcb --output out/gerbers/
kicad-cli pcb export drill   board.kicad_pcb --output out/gerbers/
kicad-cli pcb export pos     board.kicad_pcb --output out/pos.csv --format csv
kicad-cli sch export pdf     board.kicad_sch --output out/schematic.pdf
```

Plugins/CI: **KiBot** automates outputs from a YAML description; the **Interactive HTML BOM** plugin helps hand assembly; GitHub Actions can run ERC/DRC and attach manufacturing files to releases.

---

## 7. Fabrication and assembly

| Item | Notes |
|---|---|
| **Fabricators** | JLCPCB, PCBWay, OSH Park, Eurocircuits, Aisler, Seeed Fusion, and local houses: compare capabilities, price, lead time, quality |
| **Options** | Layers, thickness (1.6 mm typical), copper weight, finish (HASL, **ENIG** better for fine-pitch and flatness), solder mask color, via tenting, impedance control |
| **Assembly** | Turnkey SMT assembly from the BOM and CPL; check **rotation/offset** conventions for each part in the preview; parts library (basic vs extended) affects cost at some services |
| **Panelization** | Break-away tabs/V-score for small boards |
| **Quantities** | 5-10 boards for prototypes is usually the cheapest |
| **Stencil** | For paste: order a stencil (and a frame or use a jig) if you solder with paste |

Hand assembly kit: temperature-controlled iron, hot-air station, flux, solder paste with a stencil, tweezers, magnification, solder wick, hot plate or reflow oven for small batches, multimeter with continuity.

**Assembly order for bring-up**: populate power first (regulator, protection), check rails with the multimeter **before** installing the MCU, then the MCU, crystal, debug header; test SWD connection; then add peripherals one by one.

---

## 8. Bring-up and test

1. **Visual inspection** under magnification: bridges, missing parts, orientation, tombstones.
2. **Short checks with the power off**: resistance between each rail and ground (not zero), between VDD and GND (some hundreds of ohms to kΩ), no shorts between rails.
3. **Power up with a current-limited bench supply** (limit to the expected current plus margin); watch current: a runaway current means a short or a reversed part.
4. **Measure rails** (3.3 V, VDDA, core regulator pins) and the **reset** line.
5. **Connect the debugger**: if SWD sees the chip, basic power/clock/boot are alive (`Target voltage` in OpenOCD, chapter 4).
6. Flash a **minimal blink + UART hello**; check the clock with MCO and the scope.
7. Bring up each peripheral and bus with the logic analyzer, one at a time, with test firmware (chapter 11).
8. Log all **deviations and fixes** (bodge wires, cut traces) for the next revision.

Common first-board bugs: wrong footprint (mirrored, wrong pitch), swapped connector pins, missing pull-ups/pull-down on boot pins, reversed polarity of an LED or diode, wrong regulator pinout, missing decoupling, USB D+/D- swapped, crystal load capacitors wrong, debug pins unreachable. Most are caught by the checklists.

---

## 9. Learning plan and first projects

1. **Follow the official KiCad Getting Started tutorial** to the end (a small board).
2. **Redraw a known circuit**: an LED + button + regulator board, then fabricate it (cheap and fast).
3. **A breakout board** for an I2C sensor: practices footprints, pull-ups, connectors, and labeling.
4. **A minimal STM32 board**: start with a smaller part than the F746 (for example an **LQFP48** STM32 G4/F4/F1 class device or a QFN): easier to solder and route, with a USB-C power/USB connector, SWD header, a few LEDs/buttons, and an I2C/SPI header. Use a 2-layer board with a solid ground pour.
5. **Study open-source hardware**: the **Nucleo-144 schematic (MB1137)**, STM32 Discovery boards, and reference designs on GitHub (read schematics and layouts, see how decoupling and crystals are placed).
6. Move to a **4-layer** design with USB or Ethernet when comfortable, and **controlled impedance** where needed.

Supporting skills: soldering practice, reading datasheets (chapter 10), basic SPICE simulation (**ngspice** integrated in KiCad, or LTspice) for filters and power stages, thermal and power calculations, mechanical design (enclosures with FreeCAD/Fusion/OpenSCAD), and test jigs (pogo pins).

---

## 10. Cheat sheet

```
Flow:    requirements → parts → schematic + ERC → footprints → placement → routing → DRC → Gerber/BOM/CPL → order → bring-up
Rules:   decoupling at every VDD pin ; solid ground plane ; short crystal loop ; no splits under fast signals
         ESD at connectors ; BOOT0/NRST/SWD accessible ; test points and LEDs ; version on silkscreen
Check:   footprints vs datasheets (print 1:1) ; pin 1 ; polarity ; connector orientation ; fabricator DRC rules
Outputs: Gerbers + Excellon drills + BOM + pick&place + PDF ; view Gerbers before ordering
Bring-up: no MCU first → rails → add MCU → SWD → blink → peripherals ; current-limited supply
```

| Problem | Likely cause |
|---|---|
| Board draws high current at power-up | Short, reversed capacitor/diode, wrong regulator pinout, solder bridge |
| MCU not detected by the debugger | Power/reset/boot, SWD pinout/connector orientation, solder joints, crystal/clock |
| Random resets | Missing decoupling, poor ground, regulator instability, supply droop |
| USB not recognized | D+/D- swap, missing 48 MHz clock accuracy, pull-up, ESD parts, shield/ground |
| Noisy ADC | No filtering, VDDA coupled to digital noise, route near switchers |
| I2C unreliable | Pull-ups, long traces, level issues |
| Component does not fit | Wrong footprint or pad size: print 1:1 before ordering |

---

## 11. Where this leads

- **Low power** (chapter 15): regulator selection, power paths, measurement points and jumpers on your own board.
- **Bootloader/security** (chapter 16): production programming access, boot pins, protection of debug access.
- **Protocols** (chapter 11): transceivers, termination, EMC for CAN/USB/Ethernet.
- **Embedded Linux** (chapter 22): complex boards with DDR memory, PMICs, and high-speed layout (4-6 layers and impedance control).

## References

- KiCad documentation: <https://docs.kicad.org> (Getting Started, Schematic Editor, PCB Editor, `kicad-cli`)
- ST hardware development application note for your STM32F7 part; datasheet pin definitions; MB1137 Nucleo-144 schematic (UM1974)
- *Hardware Design guidelines*: TI, Analog Devices, and Altium/Eurocircuits layout application notes; "PCB design guidelines for reduced EMI"
- *Printed Circuit Board Design Techniques for EMC Compliance*, Mark Montrose; *High-Speed Digital Design*, Johnson and Graham
- *Bogatin's Practical Guide to Prototype Breadboard and PCB Design*, Eric Bogatin
- JLCPCB/PCBWay/OSH Park capability pages (current limits); KiBot: <https://kibot.readthedocs.io>
