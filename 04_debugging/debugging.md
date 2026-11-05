# 4. Debugging Embedded Firmware: ST-LINK, OpenOCD, GDB, VS Code

Prerequisites: chapter 0 (toolchain), chapter 2 (CMake), chapter 3 (Cortex-M, especially faults). This chapter turns the pieces you used while chasing the `printf("%.2f")` HardFault into a repeatable method.

Target: NUCLEO-F746ZG (on-board ST-LINK/V2-1), `arm-none-eabi-gcc`, OpenOCD 0.12, `gdb-multiarch`, Ubuntu, VS Code with Cortex-Debug.

---

## 1. The debug chain

```
 VS Code (Cortex-Debug)           optional front end
        │  GDB/MI
        ▼
   gdb-multiarch  ◄── reads blink.elf (symbols, source lines)
        │  GDB remote protocol (TCP :3333, or :50000 when started by Cortex-Debug)
        ▼
     OpenOCD      ◄── knows the chip: flash driver, reset logic, registers
        │  libusb
        ▼
  ST-LINK/V2-1 (probe on the Nucleo)
        │  SWD: SWDIO (PA13), SWCLK (PA14), optional SWO (PB3), NRST
        ▼
 Cortex-M7 debug hardware (DAP, FPB, DWT, ITM)
```

Each link can fail independently, and the quickest way to debug a debugger problem is to ask **which link is broken**:

| Symptom | Link at fault |
|---|---|
| `LIBUSB_ERROR_TIMEOUT` at `GET_VERSION` | USB or ST-LINK (replug the board) |
| `LIBUSB_ERROR_ACCESS`, `open failed` | udev rules, or another process owns the probe |
| `Target voltage: 0.0`, `init mode failed` | Probe to chip: power, SWD pins, chip in a state that blocks SWD |
| OpenOCD connects, gdb cannot | Port in use, wrong port, gdb architecture mismatch |
| gdb connects, no source lines | ELF has no `-g`, or it is not the ELF that was flashed |
| Breakpoint set but never hit | Code not running, wrong binary, hardware breakpoint limit |

---

## 2. Building for debugging

### Flags

```
-Og -g3            development: optimized enough to be small and fast, still debuggable
-O0 -g3            hardest to get wrong when you need every variable visible (bigger and slower)
-Os (no -g needed) release; add -g anyway if you want symbols, it costs no Flash
```

- `-g` includes debug info; `-g3` also includes **macro definitions**, so you can `print GPIO_PIN_7` or `info macro NAME`.
- Debug info lives in `.debug_*` sections of the ELF. It is **not** downloaded to the chip and does not use Flash, so shipping a release with `-g` is free (keep the ELF for post-mortems).
- Without `-g`, gdb stops at `main ()` without file or line. In CMake, `CMAKE_BUILD_TYPE=Debug` gives `-g`, and `-Og -g3` is best put in the toolchain file via `CMAKE_C_FLAGS_DEBUG_INIT`. Put these in **compile options**, never in link options.

Verify the ELF has symbols and is the one you flashed:

```bash
arm-none-eabi-readelf -S build/blink.elf | grep debug_line
arm-none-eabi-size build/blink.elf
sha256sum build/blink.elf
```

### Debug-friendly code habits

- Use `volatile` on variables you want to watch from an ISR or the debugger. The optimizer may keep a normal variable only in a register.
- Mark functions you want to break on `__attribute__((noinline))` if the optimizer inlines them.
- Keep a global `volatile` "debug mailbox" struct while bringing up hardware: you can read it in gdb without adding prints.
- Assertions (section 11) turn silent corruption into a stop at the first violation.

### Optimized code and `<optimized out>`

At `-Og`/`-O1` and above, gdb may show:

- `<optimized out>`: the value is not kept anywhere at that point.
- Lines stepping out of order, breakpoints on lines that have no code, or moving to a different line.
- Variables that look wrong after their last use.

Fixes: build with `-Og` or `-O0` while debugging, make the variable `volatile`, or look at the registers with `info registers` and `x/i $pc`.

---

## 3. ST-LINK

The Nucleo's on-board probe provides, over **one** USB cable:

| Function | Linux device | Notes |
|---|---|---|
| SWD debug and programming | USB interface used by OpenOCD / `st-flash` | One owner at a time |
| Virtual COM port | `/dev/ttyACM0` | Connected to USART3 PD8/PD9 on the Nucleo-144 |
| Mass storage (drag-and-drop) | `/media/.../NODE_F746ZG` | Drop a `.bin` to flash |
| SWO | Through the SWD interface | Needs PB3 routed to the probe |

```bash
lsusb | grep -i st-link          # 0483:374b ST-LINK/V2.1
dmesg | tail                     # shows ttyACM0 and mass storage appearing
ls /dev/ttyACM*
```

### Permissions (udev)

```bash
sudo apt install stlink-tools openocd
sudo cp /usr/share/openocd/contrib/60-openocd.rules /etc/udev/rules.d/
sudo udevadm control --reload-rules && sudo udevadm trigger
sudo usermod -aG dialout $USER           # for /dev/ttyACM0 (log out and in)
```

### Probe firmware

Old ST-LINK firmware causes odd behavior (missing SWO, flaky connection). Update with ST's **STSW-LINK007** tool. OpenOCD printed `STLINK V2J48M35`, which tells you: ST-LINK/V2-1, JTAG version 48, mass-storage/VCP version 35.

### One owner at a time

Only one program may drive the probe: `st-flash`, `st-util`, OpenOCD, and Cortex-Debug (which starts its own OpenOCD). When something says `open failed`:

```bash
pgrep -a "openocd|st-util|st-flash"
pkill openocd; pkill st-util
```

### Typical USB trouble

`LIBUSB_ERROR_TIMEOUT` on `GET_VERSION` or `GET_CURRENT_MODE` means the probe stopped answering before touching your chip. Replug the board (direct port, a data cable, no hub). It happened to you after a debugging session and cleared on replug. It is not a CMake or firmware problem.

---

## 4. OpenOCD in depth

### 4.1 Starting it

```bash
openocd -f interface/stlink.cfg -f target/stm32f7x.cfg
```

For the NUCLEO-F746ZG this two-file form (probe plus chip) is the one used throughout these notes. Look for:

```
Info : STLINK V2J48M35 (API v2) VID:PID 0483:374B
Info : Target voltage: 3.269703
Info : [stm32f7x.cpu] Cortex-M7 r0p1 processor detected
Info : [stm32f7x.cpu] target has 8 breakpoints, 4 watchpoints
Info : Listening on port 3333 for gdb connections
```

| Line | What it tells you |
|---|---|
| `Target voltage` | Probe sees the chip's supply. 0 V means no power or no connection |
| `Cortex-M7 r0p1` | Core and revision (matches CPUID `0x410FC271`) |
| `8 breakpoints, 4 watchpoints` | FPB/DWT comparator counts: your hardware limits |
| `Listening on port 3333` | GDB server. Telnet is 4444, Tcl is 6666 by default |

Cortex-Debug starts OpenOCD itself on ports 50000 (gdb), 50001 (tcl) and 50002 (telnet), as seen in your log: `-c "gdb_port 50000" -c "tcl_port 50001" -c "telnet_port 50002"`.

### 4.2 Your own configuration file

Put the board setup in one file in the repo, `tools/stm32f746.cfg`:

```tcl
source [find interface/stlink.cfg]
transport select hla_swd
source [find target/stm32f7x.cfg]

# Optional: connect even when the firmware disables SWD pins or sleeps
# reset_config srst_only srst_nogate connect_assert_srst

# Reasonable SWD speed (kHz). The ST-LINK rounds it (you saw 2000 -> 1800)
adapter speed 2000
```

Use it:

```bash
openocd -f tools/stm32f746.cfg
openocd -f tools/stm32f746.cfg -c "program build/blink.elf verify reset exit"
```

In Cortex-Debug: `"configFiles": ["${workspaceFolder}/tools/stm32f746.cfg"]`.

### 4.3 Talking to a running OpenOCD (telnet)

```bash
telnet localhost 4444
```

| Command | Meaning |
|---|---|
| `targets` | List targets and their state |
| `halt`, `resume`, `step` | Run control |
| `reset halt` | Reset and stop at the first instruction |
| `reset init` | Reset, halt, and run the target's init script (clock setup in some boards) |
| `reset run` | Reset and run |
| `reg` / `reg pc` | Show registers |
| `mdw 0xE000ED28` | Memory display word (CFSR). Also `mdh`, `mdb`; add a count: `mdw 0x08000000 4` |
| `mww 0x40020418 0x80` | Memory write word |
| `flash list`, `flash info 0` | Flash banks and sectors |
| `flash probe 0` | Detect flash |
| `flash write_image erase build/blink.elf` | Program an ELF |
| `flash erase_sector 0 0 last` | Erase sectors |
| `program file.elf verify reset exit` | Program, verify, reset, quit (one-shot) |
| `verify_image build/blink.elf` | Compare target with the file |
| `stm32f7x options_read 0` | Read option bytes (RDP, boot address) |
| `stm32f7x unlock 0` | Remove read protection (erases the flash) |
| `arm semihosting enable` | Enable semihosting |
| `shutdown` | Quit OpenOCD |

From a shell one-liner (no gdb):

```bash
openocd -f tools/stm32f746.cfg -c "init; reset halt; mdw 0xE000ED28; exit"
```

From gdb, any OpenOCD command is `monitor <command>`, for example `monitor reset halt` and `monitor mdw 0xE000ED28`.

### 4.4 Reset modes

| Command | Effect |
|---|---|
| `reset run` | Reset, let the program run from the start |
| `reset halt` | Reset and stop at `Reset_Handler`. Use this to debug startup |
| `reset init` | `reset halt` plus the `reset-init` event script |

With ST-LINK (HLA) the chip is reset with SYSRESETREQ or the NRST line, depending on `reset_config`. The Nucleo wires NRST to the probe, so hardware reset works.

### 4.5 Messages you will meet

| Message | Meaning and action |
|---|---|
| `Error: open failed` | Another process holds the probe, or no probe. `pkill openocd`, check `lsusb` |
| `LIBUSB_ERROR_ACCESS` | Missing udev rules. Install and replug |
| `Info: Unable to match requested speed 2000 kHz, using 1800 kHz` | Harmless (probe rounds the speed) |
| `Warn: Silicon bug: single stepping may enter pending exception handler!` | Erratum of r0p1: stepping with an IRQ pending may jump into the handler |
| `Warn: target was in unknown state when halt was requested` | Seen in your log. Harmless: the target was in a fault/handler when attached |
| `Error: init mode failed (unable to connect to the target)` | See section 8 (SWD pins, sleep, connect under reset) |
| `Error: timed out while waiting for target halted` | The core is not responding: low-power state, clock issue, lockup |
| `Info: accepting 'gdb' connection on tcp/3333` | Good: gdb attached |
| `Error: couldn't bind gdb to socket on port 3333: Address already in use` | Another OpenOCD is running |
| `Warn: Flash write ... failed` / `verify failed` | Wrong address, protected flash (RDP), power or SWD speed issues |

---

## 5. GDB in depth

### 5.1 Starting a session

```bash
gdb-multiarch -q build/blink.elf
(gdb) target extended-remote :3333
(gdb) monitor reset halt
(gdb) load                    # write the ELF to Flash
(gdb) compare-sections        # verify Flash matches the ELF (all Flash sections)
(gdb) tbreak main
(gdb) continue
```

If you see `Remote 'g' packet reply is too long`, gdb picked a wrong architecture. Use `gdb-multiarch` (or `arm-none-eabi-gdb`) with the ELF loaded **before** connecting, or `set architecture arm`.

`arm-none-eabi-gdb` may not be installed on recent Ubuntu; `gdb-multiarch` works identically for this.

### 5.2 Running and stepping

| Command | Short | Action |
|---|---|---|
| `continue` | `c` | Run until a stop |
| `next` | `n` | Next source line, step over calls |
| `step` | `s` | Next source line, step into calls |
| `finish` | | Run until the current function returns, print its result |
| `until` / `advance LOCATION` | | Run to a line, without stopping inside loops |
| `stepi` / `nexti` | `si`/`ni` | One machine instruction |
| `run` | `r` | Restart the program (extended-remote) |
| `Ctrl+C` | | Halt a running target |
| `kill` / `detach` | | End the session (`detach` lets the chip keep running) |
| `return` | | Pop the frame without running it (careful) |
| `call func(3)` | | Call a function in the target |
| `jump *0x08001b98` | | Continue from an address |

`monitor halt`, `monitor resume`, and `monitor reset halt` go to OpenOCD directly.

### 5.3 Breakpoints and watchpoints

```
(gdb) break main
(gdb) break uart.c:42
(gdb) break *0x08001ba0                 # at an address (works without source)
(gdb) tbreak led_on                     # temporary: removed after the first hit
(gdb) break uart_send if len > 64        # conditional
(gdb) condition 2 i == 10                # add a condition to breakpoint 2
(gdb) ignore 2 5                         # skip the next 5 hits
(gdb) commands 2                         # actions when hit
> silent
> printf "count=%d\n", count
> continue
> end
(gdb) info breakpoints
(gdb) delete 2        disable 2        enable 2
(gdb) watch g_ms                         # stop when the value changes
(gdb) watch *(uint32_t *)0x20000100      # watch an address
(gdb) rwatch var     awatch var          # read / read-or-write
(gdb) watch buf[3] if buf[3] == 0xFF
```

Hardware limits:

- **Breakpoints**: 8 FPB comparators (what OpenOCD reported). Flash code needs hardware breakpoints, and gdb uses them automatically.
- **Watchpoints**: 4 DWT comparators. Watching a large struct or a software expression silently becomes single-stepping and is extremely slow.
- Each `tbreak`/`break` that is enabled consumes a comparator. `info breakpoints` shows what you have.

### 5.4 Looking at data

```
(gdb) print var                  p var
(gdb) print/x reg                # hex     /d decimal    /t binary    /c char    /f float
(gdb) print *ptr
(gdb) print arr[0]@8             # 8 elements starting at arr[0]
(gdb) print &var                 # address
(gdb) print sizeof(struct foo)
(gdb) ptype struct foo           # type layout
(gdb) whatis var
(gdb) info locals                info args
(gdb) display/x $pc              # re-shown at every stop
(gdb) undisplay 1
(gdb) set var g_ms = 0           # modify
(gdb) print GPIOB->ODR           # peripheral registers (needs -g and CMSIS headers)
(gdb) print/x *GPIOB             # the whole register block
(gdb) set print pretty on
(gdb) info macro GPIO_PIN_7      # needs -g3
```

### 5.5 Memory and disassembly

```
(gdb) x/8wx $sp                  # 8 words in hex from SP
(gdb) x/16xb 0x20000000          # bytes
(gdb) x/4i $pc                   # 4 instructions
(gdb) x/s 0x08002000             # string
(gdb) x/wx 0xE000ED28            # CFSR
(gdb) disassemble                # current function
(gdb) disassemble /s main        # with source
(gdb) set disassemble-next-line on
(gdb) info symbol 0x08001ba0     # which function contains an address
(gdb) info line *0x08001ba0      # source line of an address
(gdb) info address main
```

Format letters for `x/NFU`: `N` count, `F` = `x` hex, `d` decimal, `u` unsigned, `t` binary, `i` instruction, `s` string, `c` char; `U` = `b` byte, `h` halfword, `w` word, `g` giant (8 bytes).

### 5.6 Stack and frames

```
(gdb) bt                          # backtrace
(gdb) bt full                     # with locals
(gdb) frame 1      up      down
(gdb) info frame
(gdb) info registers              # core registers
(gdb) info registers pc lr sp xpsr
(gdb) info all-registers          # includes FPU registers
```

Right after a fault, `bt` is often unreliable because the stack unwinder follows the handler's frame. Use the **stacked exception frame** (see 9) instead.

### 5.7 TUI

```
(gdb) tui enable        # or start with: gdb-multiarch -tui build/blink.elf
(gdb) layout src        # source window
(gdb) layout split      # source + disassembly
(gdb) layout regs
(gdb) focus cmd
(gdb) refresh
```

Ctrl+X, A toggles TUI. Useful over SSH when there is no VS Code.

### 5.8 GDB scripts

Put commands in a file and load it with `-x`:

`tools/gdb.cmds`

```
target extended-remote :3333
monitor reset halt
load
tbreak main
continue
```

```bash
gdb-multiarch -q -x tools/gdb.cmds build/blink.elf
```

(Do not name it `.gdbinit` in the project directory: gdb refuses to auto-load it for safety unless you add the directory with `add-auto-load-safe-path`.)

Batch mode (for CI or one-shot actions):

```bash
gdb-multiarch -q -batch -ex "target extended-remote :3333" -ex "monitor reset halt" \
              -ex "x/wx 0xE000ED28" -ex "detach" build/blink.elf
```

User-defined commands in `tools/gdb.cmds` (or any file loaded with `source`):

```
define fault
  printf "CFSR  = 0x%08x\n", *(unsigned int *)0xE000ED28
  printf "HFSR  = 0x%08x\n", *(unsigned int *)0xE000ED2C
  printf "MMFAR = 0x%08x\n", *(unsigned int *)0xE000ED34
  printf "BFAR  = 0x%08x\n", *(unsigned int *)0xE000ED38
  printf "CPACR = 0x%08x\n", *(unsigned int *)0xE000ED88
end
document fault
Print the Cortex-M fault status registers.
end

define exframe
  # usage: exframe $sp   (or exframe $psp)
  set $f = (unsigned int *)$arg0
  printf "R0=%08x R1=%08x R2=%08x R3=%08x\n", $f[0], $f[1], $f[2], $f[3]
  printf "R12=%08x LR=%08x PC=%08x xPSR=%08x\n", $f[4], $f[5], $f[6], $f[7]
  info symbol $f[6]
  info line *$f[6]
end
```

A Python command to decode CFSR (save as `tools/gdb_cortexm.py`, load with `source tools/gdb_cortexm.py`):

```python
import gdb

class Cfsr(gdb.Command):
    """Decode the Cortex-M CFSR register."""
    BITS = {0: "IACCVIOL", 1: "DACCVIOL", 3: "MUNSTKERR", 4: "MSTKERR", 5: "MLSPERR",
            7: "MMARVALID", 8: "IBUSERR", 9: "PRECISERR", 10: "IMPRECISERR",
            11: "UNSTKERR", 12: "STKERR", 13: "LSPERR", 15: "BFARVALID",
            16: "UNDEFINSTR", 17: "INVSTATE", 18: "INVPC", 19: "NOCP",
            24: "UNALIGNED", 25: "DIVBYZERO"}

    def __init__(self):
        super().__init__("cfsr", gdb.COMMAND_USER)

    def invoke(self, arg, from_tty):
        mem = gdb.selected_inferior().read_memory(0xE000ED28, 4)
        v = int.from_bytes(bytes(mem), "little")
        print("CFSR = 0x%08x" % v)
        for bit, name in self.BITS.items():
            if v & (1 << bit):
                print("  bit %2d  %s" % (bit, name))

Cfsr()
```

Then `(gdb) cfsr` prints the active fault causes.

---

## 6. VS Code with Cortex-Debug

### 6.1 What it does for you

Cortex-Debug starts OpenOCD, starts gdb, loads the ELF, runs to `main`, and gives you breakpoints in the editor, a variables panel, a peripherals panel (from an SVD file), a registers panel, memory viewer, disassembly, live watch, and SWO output.

Install the extension **Cortex-Debug** (marus25). Optional: **C/C++**, **CMake Tools**, **Memory View**, **RTOS Views**.

### 6.2 `launch.json`

```json
{
  "version": "0.2.0",
  "configurations": [
    {
      "name": "STM32F746: debug (OpenOCD)",
      "type": "cortex-debug",
      "request": "launch",
      "servertype": "openocd",
      "cwd": "${workspaceFolder}",
      "executable": "${workspaceFolder}/build/blink.elf",
      "configFiles": ["interface/stlink.cfg", "target/stm32f7x.cfg"],
      "gdbPath": "gdb-multiarch",
      "objdumpPath": "/usr/bin/arm-none-eabi-objdump",
      "runToEntryPoint": "main",
      "preLaunchTask": "build",
      "svdFile": "${workspaceFolder}/boards/stm32f746/STM32F746.svd",
      "liveWatch": { "enabled": true, "samplesPerSecond": 4 },
      "showDevDebugOutput": "none"
    },
    {
      "name": "STM32F746: attach (no reset)",
      "type": "cortex-debug",
      "request": "attach",
      "servertype": "openocd",
      "cwd": "${workspaceFolder}",
      "executable": "${workspaceFolder}/build/blink.elf",
      "configFiles": ["interface/stlink.cfg", "target/stm32f7x.cfg"],
      "gdbPath": "gdb-multiarch",
      "objdumpPath": "/usr/bin/arm-none-eabi-objdump",
      "svdFile": "${workspaceFolder}/boards/stm32f746/STM32F746.svd"
    }
  ]
}
```

| Key | Meaning |
|---|---|
| `request: launch` | Flash, reset, run to `main` |
| `request: attach` | Connect to the running program **without resetting or flashing** (inspect a live crash) |
| `executable` | Path to the ELF. Wrong path gives the "executable not found" error |
| `configFiles` | OpenOCD `-f` files; `searchDir` can add search paths |
| `gdbPath` | `gdb-multiarch` or `arm-none-eabi-gdb` |
| `objdumpPath` | Avoids the `nm-multiarch`/`objdump-multiarch not found` messages |
| `runToEntryPoint` | Function to stop at (`"main"`) |
| `breakAfterReset` | Stop at the reset vector instead |
| `preLaunchTask` | Label of a task in `tasks.json` (must match exactly) |
| `svdFile` | Peripheral register definitions. Download the F746 SVD from ST's packs or the `modm-io/cmsis-svd-stm32` repo |
| `liveWatch` | Variables updated while the target runs |
| `showDevDebugOutput` | `"raw"` shows all gdb traffic: use it to report or understand a failure |
| `postLaunchCommands` / `overrideLaunchCommands` | Extra gdb commands, or replace the default flash sequence |
| `openOCDLaunchCommands` | Extra OpenOCD commands at start |
| `swoConfig`, `rttConfig` | Trace output (sections 10.2 and 10.3) |

Example of extra gdb commands: `"postLaunchCommands": ["source ${workspaceFolder}/tools/gdb_cortexm.py"]`.

### 6.3 `tasks.json` that supports F5

```json
{
  "version": "2.0.0",
  "options": { "env": { "SOURCE_DATE_EPOCH": "1700000000" } },
  "tasks": [
    {
      "label": "configure",
      "type": "shell",
      "command": "test -f build/CMakeCache.txt || cmake -S . -B build -DCMAKE_BUILD_TYPE=Debug -DCMAKE_TOOLCHAIN_FILE=cmake/toolchains/arm-toolchain.cmake",
      "problemMatcher": []
    },
    {
      "label": "build",
      "type": "shell",
      "command": "cmake --build build",
      "dependsOn": "configure",
      "group": { "kind": "build", "isDefault": true },
      "problemMatcher": "$gcc"
    }
  ]
}
```

The file must be `.vscode/tasks.json` (with the **s**) in the folder you opened.

### 6.4 Using the UI

- **F5** start, **F10** step over, **F11** step into, **Shift+F11** step out, **F9** toggle breakpoint, **Shift+F5** stop.
- Right-click a breakpoint for conditions, hit counts, and log points (print without stopping).
- **Debug Console**: type gdb commands with the prefix `-exec`, for example `-exec x/wx 0xE000ED28` or `-exec monitor reset halt`.
- The **Peripherals** panel (needs the SVD) lets you read and even edit registers (GPIO, USART, RCC...). Useful to prove whether the clock bit is really set.
- The **Cortex Registers** panel shows core registers (including MSP, PSP, CONTROL, PRIMASK).
- **Disassembly** view: open from the context menu when source is not enough.
- **Memory** view: `Cortex Debug: View Memory` for raw dumps of RAM or peripherals.

### 6.5 Terminal tabs to watch

| Tab | Content |
|---|---|
| Debug Console | gdb output and your commands |
| Terminal: `[gdb-server]` | OpenOCD output (**read it when something fails**) |
| Cortex-Debug: GDB Server console | Same, structured |
| Cortex-Debug: SWO | Trace output (if configured) |

---

## 7. Debugging session recipes

### 7.1 Why does my program not start (stuck before `main`)?

```
(gdb) monitor reset halt
(gdb) break Reset_Handler
(gdb) continue
(gdb) display/i $pc
(gdb) stepi            # repeat; watch the .data copy loop and SystemInit
(gdb) break main
(gdb) continue
```

If it never reaches `main`: check `x/2wx 0x08000000` (SP and reset vector), that the reset vector is odd, and that the linker placed `.isr_vector` at the start of Flash:

```bash
arm-none-eabi-objdump -h build/blink.elf | grep -E "isr_vector|\.text"
```

### 7.2 Is the Flash content what I think?

```
(gdb) load
(gdb) compare-sections
```

It prints `matched` for each section, or `MIS-MATCHED!`. Then reset: after `st-flash`, press reset or use `--reset`, otherwise the core can stay halted.

### 7.3 Globals look wrong (initial value, zero)

After reset-halt, set a breakpoint at `main` and compare:

```
(gdb) p &_sdata   p &_edata   p &_sidata
(gdb) x/4wx &_sidata        # initial values in Flash
(gdb) x/4wx &_sdata         # the same values must now be in RAM
```

If RAM differs, the `.data` copy in the startup is broken (wrong symbol names or linker script).

### 7.4 Something changes a variable and I don't know who

```
(gdb) watch g_counter
(gdb) continue
```

On stop, `bt` and `info line *$pc` show the writer. If the variable is a struct member, `watch -l ptr->field` watches that address even after `ptr` changes.

### 7.5 Which interrupt keeps firing?

Stop and read the active exception:

```
(gdb) p/x $xpsr                           # low 9 bits = IPSR
(gdb) x/wx 0xE000ED04                     # ICSR: VECTACTIVE in bits 8:0; VECTPENDING in 20:12
(gdb) x/wx 0xE000E200                     # NVIC ISPR0: which IRQs are pending
(gdb) x/wx 0xE000E300                     # NVIC IABR0: which are active
```

IRQ number = exception number - 16.

### 7.6 Hung in a loop waiting for a flag

Stop with Ctrl+C. `bt` and `info line *$pc` show the loop. Read the peripheral register it waits on (Peripherals panel or `x/wx`). Typical causes: peripheral clock disabled, wrong bit, flag cleared by another reader, or an interrupt that is masked.

### 7.7 Unexpected reset loop

Read the reset cause in the firmware (section 9.3) and stop at the reset vector: `monitor reset halt`, `break HardFault_Handler`, `continue`. A watchdog that is not stopped while debugging also loops (see 8.2).

---

## 8. Hardware realities of debugging

### 8.1 What halting changes

- **SysTick stops** while the core is halted, so `HAL_Delay` and your `millis()` freeze. Timers may keep running or stop depending on `DBGMCU`.
- Peripherals keep running (UART may overrun, DMA continues, PWM continues).
- Single stepping with an IRQ pending can enter the handler (the r0p1 erratum OpenOCD warned about).
- Breakpoints and watchpoints use hardware comparators, so code timing is unchanged when they do not trigger.

### 8.2 Freeze peripherals during debug (DBGMCU)

By default, the watchdogs keep counting while halted, so the board resets under you. Freeze them (and timers you want stopped):

```c
DBGMCU->APB1FZ |= DBGMCU_APB1_FZ_DBG_IWDG_STOP | DBGMCU_APB1_FZ_DBG_WWDG_STOP;
DBGMCU->APB1FZ |= DBGMCU_APB1_FZ_DBG_TIM2_STOP;      /* stop TIM2 while halted */
```

Names can differ slightly between header versions; with the HAL: `__HAL_DBGMCU_FREEZE_IWDG()`.

### 8.3 Debugging in low-power modes

In Sleep/Stop/Standby the debug clocks may stop and the probe cannot connect. Keep debugging alive with `DBGMCU->CR |= DBGMCU_CR_DBG_SLEEP | DBGMCU_CR_DBG_STOP | DBGMCU_CR_DBG_STANDBY` during development.

### 8.4 When the debugger cannot connect

Typical triggers: the firmware reconfigured **PA13/PA14** (SWD) as GPIO, entered a low-power mode right after reset, or turned off the clocks of the debug unit. OpenOCD says `init mode failed (unable to connect to the target)` or `Target voltage: 0.0`.

Recovery:

1. **Connect under reset**: hold the reset button, start OpenOCD, release after it says it connected; or add `reset_config srst_only srst_nogate connect_assert_srst` to your OpenOCD config.
2. With `st-flash`: `st-flash --connect-under-reset erase`, then flash a known-good firmware.
3. Check `BOOT0` and that the board has power (`Target voltage` should be near 3.3 V).
4. As a last resort, mass-erase with ST's STM32CubeProgrammer.

Prevention: keep PA13/PA14 (and PB3 if you use SWO) out of your GPIO initialization.

### 8.5 Read-out protection (RDP)

If option bytes set RDP level 1, the debugger can connect but cannot read Flash. `stm32f7x unlock 0` in OpenOCD removes it **and erases the chip**. RDP level 2 is permanent. Do not enable RDP lightly.

---

## 9. Fault and crash analysis

This ties chapter 3 into a workflow.

### 9.1 Live: stop at the fault

Set a breakpoint in the handler, or use vector catch, so the debugger stops at the exact moment:

```
(gdb) break HardFault_Handler
(gdb) continue
```

Then:

```
(gdb) fault                      # the user command from section 5.8, or cfsr
(gdb) p/x $lr                    # EXC_RETURN: bit 2 = which stack held the frame
(gdb) exframe $msp               # or exframe $psp if LR bit 2 = 1
```

Worked values from your session: CFSR = `0x00010000` (UNDEFINSTR), stacked PC = `0x08001ba0`, `info symbol` = `main + 40`, instruction `vcvt.f64.f32`. Conclusion: wrong FPU flag for the chip. Step by step:

1. CFSR names the **type** of fault.
2. The stacked PC names the **instruction**.
3. `info line *PC` names the **source line**.
4. BFAR or MMFAR (if valid) names the **address** that was accessed.
5. The surrounding code and `objdump -d` explain **why**.

### 9.2 Post-mortem: record the fault and reboot

A fault in the field has no debugger attached. Save the evidence in RAM that survives a software reset, reset, and report it at the next boot.

Linker script: add a `NOLOAD` section for variables that are not initialized by startup:

```ld
  .noinit (NOLOAD) :
  {
    . = ALIGN(4);
    *(.noinit*)
    . = ALIGN(4);
  } >RAM
```

Code:

```c
#include "stm32f7xx.h"
#include <stdint.h>

#define FAULT_MAGIC 0xFA17C0DEu

typedef struct {
    uint32_t magic;
    uint32_t cfsr, hfsr, mmfar, bfar;
    uint32_t pc, lr, xpsr;
} fault_record_t;

__attribute__((section(".noinit"))) volatile fault_record_t g_fault;

void hard_fault_c(uint32_t *frame)          /* called from the naked HardFault_Handler */
{
    g_fault.cfsr  = SCB->CFSR;
    g_fault.hfsr  = SCB->HFSR;
    g_fault.mmfar = SCB->MMFAR;
    g_fault.bfar  = SCB->BFAR;
    g_fault.lr    = frame[5];
    g_fault.pc    = frame[6];
    g_fault.xpsr  = frame[7];
    g_fault.magic = FAULT_MAGIC;
    __DSB();
    NVIC_SystemReset();
}
```

At boot:

```c
void report_previous_fault(void)
{
    if (g_fault.magic == FAULT_MAGIC) {
        printf("Previous run crashed: PC=0x%08lx CFSR=0x%08lx BFAR=0x%08lx\r\n",
               g_fault.pc, g_fault.cfsr, g_fault.bfar);
        g_fault.magic = 0;
    }
}
```

Then map the PC to a line on your PC with the **same ELF**: `arm-none-eabi-addr2line -e build/blink.elf -f -p 0x08001ba0`. That is why you keep the release ELF for every shipped version.

Magic numbers in uninitialized RAM can occasionally appear by chance after power-up. Combine with the reset flag check below.

### 9.3 Why did the chip reset?

```c
uint32_t csr = RCC->CSR;
if (csr & RCC_CSR_PORRSTF)   puts("power-on reset");
if (csr & RCC_CSR_PINRSTF)   puts("reset pin");
if (csr & RCC_CSR_SFTRSTF)   puts("software reset (NVIC_SystemReset)");
if (csr & RCC_CSR_IWDGRSTF)  puts("independent watchdog");
if (csr & RCC_CSR_WWDGRSTF)  puts("window watchdog");
if (csr & RCC_CSR_BORRSTF)   puts("brown-out");
if (csr & RCC_CSR_LPWRRSTF)  puts("low-power reset");
RCC->CSR |= RCC_CSR_RMVF;    /* clear the flags */
```

Read them early, before clearing. A power-on reset means the RAM was lost (so ignore `.noinit` content); a software reset keeps it.

### 9.4 Vector catch and fault-friendly settings

During development enable detailed faults so the cause is precise:

```c
SCB->SHCSR |= SCB_SHCSR_MEMFAULTENA_Msk | SCB_SHCSR_BUSFAULTENA_Msk | SCB_SHCSR_USGFAULTENA_Msk;
SCB->CCR   |= SCB_CCR_DIV_0_TRP_Msk;
SCnSCB->ACTLR |= SCnSCB_ACTLR_DISDEFWBUF_Msk;   /* make bus faults precise: slower, debug only */
```

### 9.5 Stack overflow detection

Paint the stack at boot and measure how much is untouched:

Linker script: add `_sstack = _estack - _Min_Stack_Size;` after `_estack`.

```c
#define STACK_PAINT 0xDEADBEEFu
extern uint32_t _sstack, _estack;

void stack_paint(void)                       /* call first thing in main, or in Reset_Handler */
{
    uint32_t *p  = &_sstack;
    uint32_t *sp = (uint32_t *)__get_MSP();
    while (p < sp - 16) { *p++ = STACK_PAINT; }   /* stay clear of the live part */
}

uint32_t stack_free_min(void)                /* bytes never touched = high-water mark margin */
{
    uint32_t *p = &_sstack;
    while (p < &_estack && *p == STACK_PAINT) { p++; }
    return (uint32_t)(p - &_sstack) * 4u;
}
```

Print `stack_free_min()` after exercising worst-case code paths (`printf` with floats uses hundreds of bytes). Compile-time view: `-fstack-usage` creates `.su` files with per-function stack use, and `-Wstack-usage=512` warns about big frames.

For a hard guarantee, put a no-access MPU region at `_sstack`, turning an overflow into a MemManage fault at the exact instruction.

---

## 10. Logging and tracing

### 10.1 UART printf

You already have this. Habits that help:

- Unbuffered `stdout` (`setvbuf(stdout, NULL, _IONBF, 0)`), `\r\n` line ends, and a baud rate that matches (115200).
- `picocom -b 115200 /dev/ttyACM0` (exit: Ctrl+A, Ctrl+X). Close it before flashing if you see odd timeouts.
- Prefix each line with a timestamp (`millis()` or the DWT counter) and a module tag. Long blocking prints distort timing.
- Never `printf` from a high-priority ISR; push to a ring buffer and print from the main loop.

Ring-buffer log skeleton:

```c
#define LOG_SIZE 1024u                     /* power of two */
static volatile uint8_t  log_buf[LOG_SIZE];
static volatile uint32_t log_head, log_tail;

void log_putc(uint8_t c)                   /* safe from ISR if only one producer */
{
    uint32_t next = (log_head + 1u) & (LOG_SIZE - 1u);
    if (next != log_tail) { log_buf[log_head] = c; log_head = next; }  /* drop on full */
}

void log_flush(void)                       /* main loop: drain to UART */
{
    while (log_tail != log_head) {
        uart_putc(log_buf[log_tail]);
        log_tail = (log_tail + 1u) & (LOG_SIZE - 1u);
    }
}
```

### 10.2 ITM / SWO (printf without a UART)

`ITM_SendChar()` writes to a trace port that the probe streams over the SWO pin, with very low CPU cost.

```c
int _write(int fd, char *ptr, int len)
{
    (void)fd;
    for (int i = 0; i < len; i++) { ITM_SendChar((uint32_t)ptr[i]); }
    return len;
}
```

Requirements: ITM enabled by the debugger (Cortex-Debug does it), SWO pin PB3 connected to the probe (check the Nucleo-144 user manual UM1974 for the solder bridge), and the trace clock set to the real core frequency.

Cortex-Debug configuration:

```json
"swoConfig": {
  "enabled": true,
  "cpuFrequency": 16000000,
  "swoFrequency": 2000000,
  "source": "probe",
  "decoders": [ { "port": 0, "type": "console", "label": "ITM", "encoding": "ascii" } ]
}
```

`cpuFrequency` must equal `SystemCoreClock` (16 MHz on HSI, 216 MHz after PLL). If you change the clock tree, update it or the output is garbage. Standalone OpenOCD needs a TPIU setup whose syntax changed between versions (check `help tpiu` in your OpenOCD).

### 10.3 Other logging options

| Option | Notes |
|---|---|
| Semihosting | `printf` goes through the debugger using `BKPT`. Very slow, and **faults if no debugger is attached**. Development only |
| SEGGER RTT | Fast RAM-based channel read by the debugger. Works with OpenOCD (`rttConfig` in Cortex-Debug). Needs the RTT source files |
| GPIO toggling | A pin high/low around code, viewed with a logic analyzer or scope: the least intrusive timing probe |
| DWT cycle counter | Exact cycle counts of code sections |
| Logic analyzer (sigrok/PulseView, 8-channel clones) | Decode UART/SPI/I2C and check timing of GPIO toggles |

### 10.4 Assertions

```c
#ifdef NDEBUG
  #define ASSERT(cond) ((void)0)
#else
  #define ASSERT(cond) do { if (!(cond)) assert_failed(__FILE__, __LINE__); } while (0)
#endif

void assert_failed(const char *file, int line)
{
    printf("ASSERT %s:%d\r\n", file, line);
    __BKPT(0);                       /* debugger stops here; without one this locks up */
    for (;;) { }
}
```

For production, replace `__BKPT` with a recorded fault + `NVIC_SystemReset()` (section 9.2). `-ffile-prefix-map` makes `__FILE__` short.

### 10.5 Timing and performance

```c
uint32_t t0 = DWT->CYCCNT;
work();
printf("work: %lu cycles\r\n", (unsigned long)(DWT->CYCCNT - t0));
```

(Enable the DWT counter first: see chapter 3, section 7.) Pair with a GPIO toggle to see real-time behavior in the logic analyzer.

---

## 11. Analyzing the binary without a debugger

```bash
arm-none-eabi-size build/blink.elf                           # Flash/RAM summary
arm-none-eabi-nm -S --size-sort -C build/blink.elf | tail -20 # biggest symbols
arm-none-eabi-objdump -S -d build/blink.elf | less            # disassembly + source
arm-none-eabi-addr2line -e build/blink.elf -f -p 0x08001ba0   # address -> function:line
arm-none-eabi-objdump -t build/blink.elf | grep -i uart       # symbol table
grep -n "uart" build/blink.map | head                         # where the linker placed it
```

The `.map` file shows which object contributed each byte, which libraries were pulled in, and the final address of every symbol. When Flash or RAM is nearly full, start there.

Compare the flashed image with a file:

```bash
openocd -f tools/stm32f746.cfg -c "init; reset halt; verify_image build/blink.elf; exit"
```

---

## 12. A terminal workflow (no IDE)

`tools/debug.sh`:

```bash
#!/usr/bin/env bash
set -euo pipefail
ELF="${1:-build/blink.elf}"

openocd -f interface/stlink.cfg -f target/stm32f7x.cfg > /tmp/openocd.log 2>&1 &
OCD=$!
trap 'kill $OCD 2>/dev/null || true' EXIT
sleep 1
grep -q "Listening on port 3333" /tmp/openocd.log || { cat /tmp/openocd.log; exit 1; }

gdb-multiarch -q -x tools/gdb.cmds "$ELF"
```

CMake helpers (chapter 2 style):

```cmake
set(OPENOCD_CFG -f interface/stlink.cfg -f target/stm32f7x.cfg)

add_custom_target(flash-ocd
  COMMAND openocd ${OPENOCD_CFG} -c "program $<TARGET_FILE:blink> verify reset exit"
  DEPENDS blink USES_TERMINAL)

add_custom_target(gdb
  COMMAND gdb-multiarch -q -x ${CMAKE_SOURCE_DIR}/tools/gdb.cmds $<TARGET_FILE:blink>
  DEPENDS blink USES_TERMINAL)
```

---

## 13. Problems from our sessions, and the fix

| Problem | Cause | Fix |
|---|---|---|
| `st-flash`: `GET_VERSION ... LIBUSB_ERROR_TIMEOUT`, `Failed to enter SWD mode` | ST-LINK USB interface stuck | Replug the board. `lsusb` shows `0483:374b`, but the probe does not answer |
| Program starts only after pressing reset | `st-flash` without `--reset` leaves the core halted | `st-flash --reset write ...` or OpenOCD `program ... reset exit` |
| `Could not find the task build` | `task.json` instead of `tasks.json`, or label mismatch | Rename to `.vscode/tasks.json`, check `label` |
| `nm-multiarch / objdump-multiarch failed` | Cortex-Debug derives tool names from `gdb-multiarch` | `"objdumpPath": "/usr/bin/arm-none-eabi-objdump"` |
| Stops at `main ()` with no file/line, breakpoints grey | No `-g` | `CMAKE_BUILD_TYPE=Debug`, reconfigure from scratch |
| `-Og -g3` put in link options had no effect | They are compile options | Move to `target_compile_options` or `CMAKE_C_FLAGS_DEBUG_INIT` |
| `Could not find ... elf` after `rm -rf build` | Nothing configured yet | `configure` task before `build`, or configure by hand once |
| HardFault at `printf("%.2f")`, CFSR `0x00010000` | `-mfpu=fpv5-d16` (double) on a single-precision FPU | `-mfpu=fpv5-sp-d16`, use `float` |
| Debugger shows `WWDG_IRQHandler` | Weak alias of `Default_Handler` (first IRQ) | Unhandled exception: read IPSR/ICSR and CFSR |
| `Manually-specified variables were not used: CMAKE_TOOLCHAIN_FILE` | Toolchain passed to an existing build dir | Harmless; delete `build/` to change it |
| OpenOCD warns `target was in unknown state` | Attached while in a fault handler | Harmless; reset halt |

---

## 14. Lab exercises

1. **Chain check**: with the board connected, run `lsusb`, start OpenOCD alone, then `telnet localhost 4444` and issue `targets`, `reset halt`, `mdw 0xE000ED00`. Decode the CPUID.
2. **First gdb session by hand**: connect, `load`, `compare-sections`, `tbreak main`, `continue`, `next`, `info locals`, `bt`.
3. **No symbols**: build without `-g`, observe the gdb output, then fix and compare.
4. **Break on data**: `watch` a global modified in `SysTick_Handler` and see which line changes it.
5. **Conditional breakpoint**: stop in a loop only on iteration 100.
6. **Startup walk**: single-step `Reset_Handler`, watch `.data` get copied, and verify with `x/4wx`.
7. **Your own gdb commands**: put `fault`, `exframe` and the Python `cfsr` in `tools/` and load them with `-x`.
8. **Trigger every fault**: NULL read, divide by zero, wrong FPU flag, peripheral without clock; capture CFSR, PC and BFAR for each, and map each to a source line using only gdb commands.
9. **Post-mortem**: implement the `.noinit` fault record, trigger a fault with no debugger, and read the report over UART after the automatic reset.
10. **Stack paint**: measure stack headroom with and without `printf("%f")`.
11. **Break the debugger on purpose**: reconfigure PA13/PA14 as GPIO, flash, then recover using connect-under-reset.
12. **Freeze watchdog**: enable the IWDG, debug until it resets the board mid-session, then fix with `DBGMCU` freeze.
13. **SWO**: enable ITM output, view it in Cortex-Debug, and compare CPU cost with UART `printf` using the DWT counter.
14. **Peripherals panel**: with the SVD loaded, toggle a GPIO bit from the panel and see the LED change.
15. **Reproducible report**: keep the ELF of a build, crash it, and show that `addr2line` still finds the right line a week later.

---

## 15. Cheat sheet

### Terminal session

```bash
openocd -f interface/stlink.cfg -f target/stm32f7x.cfg
gdb-multiarch -q build/blink.elf
(gdb) target extended-remote :3333
(gdb) monitor reset halt
(gdb) load
(gdb) tbreak main
(gdb) continue
```

### The 12 gdb commands you use most

`break`, `tbreak`, `continue`, `next`, `step`, `finish`, `print`, `x`, `info registers`, `bt`, `watch`, `monitor`.

### Fault in three lines

```
(gdb) x/wx 0xE000ED28          # CFSR
(gdb) x/8wx $sp                # stacked frame: [6] is the faulting PC
(gdb) info line *<that PC>
```

### Questions and the command that answers them

| Question | Command |
|---|---|
| Does the probe see the chip? | OpenOCD output: `Target voltage`, `Cortex-M7 r0p1` |
| Is the flashed image the one I built? | `compare-sections` or `verify_image` |
| Where am I? | `bt`, `info line *$pc`, `x/6i $pc` |
| Why did it fault? | `x/wx 0xE000ED28`, stacked PC, BFAR |
| Which IRQ is active/pending? | `x/wx 0xE000ED04`, `x/wx 0xE000E200` |
| Who changed this variable? | `watch var` |
| How much stack is left? | Paint and measure (section 9.5) |
| Why did the chip reset? | `RCC->CSR` flags |
| Can't connect | Replug; connect under reset; check PA13/PA14 and `Target voltage` |

### Rules of thumb

- Debug builds: `-Og -g3`, always with symbols; keep the ELF of every release.
- One owner of the probe at a time.
- Read the OpenOCD output first when something does not connect.
- Enable the individual fault handlers during development.
- Freeze watchdogs and low-power modes while debugging.
- A fault in the field leaves no debugger: record it in `.noinit` and report it after reset.

---

## 16. Where this leads

- **C for embedded**: the language rules (`volatile`, aliasing, atomicity, undefined behavior) behind most "works in debug, fails in release" bugs.
- **Peripherals chapters**: use the Peripherals panel, SWO and the logic analyzer to verify each driver.
- **RTOS**: Cortex-Debug can show tasks (RTOS Views), and the fault and stack techniques here become essential with multiple stacks.
- **Testing and CI**: batch-mode gdb and OpenOCD scripts are the base for hardware-in-the-loop tests.

## References

- GDB manual: <https://sourceware.org/gdb/current/onlinedocs/gdb/>
- OpenOCD user guide: <https://openocd.org/doc/html/index.html>
- Cortex-Debug wiki: <https://github.com/Marus25/cortex-debug>
- ST UM1974 (Nucleo-144 user manual: solder bridges, ST-LINK, SWO), UM1075 (ST-LINK/V2-1)
- Arm *Cortex-M7 Devices Generic User Guide* (debug and fault registers)
- Chapter 3 of these notes (fault registers) and chapter 0 (symbols, map file, ELF tools)