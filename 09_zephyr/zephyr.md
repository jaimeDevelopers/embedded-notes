# 9. Zephyr RTOS: Setup, Concepts, Tips and Tricks (NUCLEO-F746ZG)

Chapter 8 ended with "when an RTOS pays off". This chapter is the hands-on version for **Zephyr**: how the project is organized, how to build and flash on your Nucleo, the four pillars (**west, CMake, Kconfig, devicetree**), the kernel and driver APIs, debugging, testing, and a long list of practical tips.

**Versions and verification.** As of late October 2026 the latest Zephyr release is **4.5.0** (28 Oct 2026); the **3.7** series is the current LTS; since 4.4 (April 2026) releases come **twice a year** (April and October). Zephyr moves quickly: option names, board identifiers and Kconfig/devicetree details change between releases. Everything below is written for the 4.x series and has **not been run on your board**. When something does not match, read the **migration guide** of your release and the board page (<https://docs.zephyrproject.org/latest/boards/st/nucleo_f746zg/doc/index.html>). Always pin the Zephyr version in your project (section 3).

---

## 1. What Zephyr is, and how it differs from what you built

Zephyr is an open-source (Apache 2.0) **RTOS plus a full embedded platform**: kernel, device drivers, hardware abstraction through a hardware description (devicetree), configuration system (Kconfig), build system (CMake), networking (IP, Bluetooth, USB, CAN, Modbus...), file systems, shell, logging, settings, bootloader (MCUboot), testing framework (ztest, Twister), and the tooling (`west`).

| Aspect | Bare metal + CMSIS (chapters 0-8) | FreeRTOS | **Zephyr** |
|---|---|---|---|
| What you get | Only what you write | Kernel + primitives | Kernel + drivers + subsystems + tooling |
| Hardware description | Headers, your `pins.h` | Your code | **Devicetree** (data, not code) |
| Configuration | `#define`s, CMake options | `FreeRTOSConfig.h` | **Kconfig** (`prj.conf`, `menuconfig`) |
| Board support | You write it | You write it | Hundreds of boards ready (`west boards`) |
| Startup, linker script, vector table | Yours | Yours (plus port) | Generated for you |
| Drivers | Yours or vendor HAL | Vendor HAL | Common driver API (GPIO, UART, I2C, SPI, ADC...) |
| Learning curve | Low per step, high in total | Low | **High at first**, then productive |
| Footprint | Smallest | Small | Larger baseline (tens of KB), configurable |
| Portability across vendors | Low | Medium | **High** (same app code on many MCUs) |
| Test infrastructure | Yours | Yours | ztest, `native_sim`, emulators, Twister |
| Releases and security | Yours | Vendor/AWS | Regular releases, LTS, security process |

### When Zephyr is a good choice

- You need **several concurrent activities** plus connectivity (networking, USB, BLE, CAN) and want maintained stacks.
- The product may **change MCU or vendor**, and board support should be data, not rewrites.
- You value **tests without hardware** (`native_sim`), reproducible builds, and a large community.
- Long-lived products where **security updates and an LTS** matter.

### When it is not

- A tiny or very simple device (a few KB, one task): bare metal or a cooperative scheduler is simpler.
- You must understand and control every register and cycle (but you can still do that inside Zephyr by reading the driver code).
- A very tight Flash/RAM budget on a small MCU.

For your F746 (1 MB Flash, 320 KB RAM) Zephyr fits comfortably.

### How it maps to what you learned

| What you wrote | In Zephyr |
|---|---|
| `startup_stm32f746xx.s`, linker script | `arch/arm`, SoC support, a generated linker script (`build/zephyr/linker.cmd`) |
| `SystemInit()`, clock tree code (chapter 7) | Clock control driver driven by devicetree (`&rcc`, `&pll`, `&clk_hse`) |
| `pins.h`, `gpio_config()` | Devicetree nodes, pinctrl, aliases (`led0`, `sw0`) |
| `millis()` (SysTick) | `k_uptime_get()`, `k_msleep()`, kernel timers |
| Critical section (`PRIMASK`) | `irq_lock()` / `K_SPINLOCK` / `k_mutex` |
| Event queue (chapter 8) | `k_msgq`, `k_fifo`, `k_poll`, `k_event`, zbus |
| Cooperative scheduler | Threads, work queues, timers |
| Ring buffer | `ring_buf` utility |
| `printf` over UART + `_write` | `printk`, logging subsystem, console, shell |
| `uart.c`, `adc.c` | `uart_*`, `adc_*` APIs with devicetree specs |
| Bootloader and CRC image | MCUboot, `west sign`, image header and hash |
| Host test with fakes | ztest on `native_sim`, emulated devices |
| `arm-none-eabi-gcc` | Zephyr SDK (`arm-zephyr-eabi-gcc`) or your own via `ZEPHYR_TOOLCHAIN_VARIANT=gnuarmemb` |

---

## 2. The four pillars

```
 west  ── manages the workspace (Zephyr + modules/HALs), builds, flashes, debugs
 CMake ── build system; each app is a CMake project that pulls in Zephyr
 Kconfig ─ software configuration: which features, sizes, options (prj.conf)
 Devicetree ─ hardware description: which peripherals, pins, devices (.dts, .overlay)
```

The flow of a build:

```
board DTS + your overlay ─► devicetree ─► devicetree_generated.h   (hardware as C macros)
board defconfig + prj.conf ─► Kconfig  ─► .config / autoconf.h     (software options as CONFIG_*)
your sources + Zephyr kernel/drivers (selected by those two) ─► compile ─► link with the generated linker script ─► zephyr.elf/.bin/.hex
```

Understanding that **hardware choices live in devicetree and software choices live in Kconfig** removes most of the initial confusion.

---

## 3. Installing on Ubuntu

Based on the official Getting Started Guide (verify against <https://docs.zephyrproject.org/latest/develop/getting_started/index.html>, which tracks the current release).

### 3.1 System packages

```bash
sudo apt update
sudo apt install --no-install-recommends git cmake ninja-build gperf ccache dfu-util \
     device-tree-compiler wget python3-dev python3-venv python3-tk xz-utils file make \
     gcc gcc-multilib g++-multilib libsdl2-dev libmagic1
```

Minimum versions in the guide: CMake 3.20.5, Python 3.10, devicetree compiler 1.4.6. Check with `cmake --version`, `python3 --version`, `dtc --version` (your CMake 4.x is fine).

### 3.2 Python virtual environment, west, and the sources

```bash
python3 -m venv ~/zephyrproject/.venv
source ~/zephyrproject/.venv/bin/activate       # activate in EVERY new terminal
pip install west

west init ~/zephyrproject                       # latest main branch
# pinned release (recommended for real work):
#   west init --mr v4.5.0 ~/zephyrproject      (or the LTS branch tag, e.g. v3.7.x)
cd ~/zephyrproject
west update                                     # fetches Zephyr and all its modules (large download)
west zephyr-export                              # lets CMake find this Zephyr
west packages pip --install                     # Python dependencies for this Zephyr version
```

Do not mix versions: the Python dependencies come from the checked-out Zephyr, so run `west packages pip --install` again after changing releases.

### 3.3 The SDK (toolchains, OpenOCD, QEMU)

```bash
cd ~/zephyrproject/zephyr
west sdk install                                # downloads and sets up the Zephyr SDK (toolchains and host tools)
# to limit what is installed, see: west sdk install --help (e.g. only arm toolchains)
```

The SDK includes `arm-zephyr-eabi-gcc`, a custom OpenOCD and QEMU, and (on Linux) the udev rules. Your `apt` ARM toolchain is **not** needed, though it can be used (section 3.5).

Environment for each shell (put in a helper script or an alias):

```bash
source ~/zephyrproject/.venv/bin/activate
source ~/zephyrproject/zephyr/zephyr-env.sh    # sets ZEPHYR_BASE and helper functions
```

```bash
alias zephyr='source ~/zephyrproject/.venv/bin/activate && source ~/zephyrproject/zephyr/zephyr-env.sh'
```

### 3.4 First build and flash

```bash
cd ~/zephyrproject/zephyr
west boards | grep -i f746                      # list boards
west build -p always -b nucleo_f746zg samples/basic/blinky
west flash --runner openocd
```

Points about this board (from its documentation page):

- Board identifier: `nucleo_f746zg` (the fully qualified form is `nucleo_f746zg/stm32f746xx`).
- **The default flash runner is `stm32cubeprogrammer`**, which requires STM32CubeProgrammer installed. OpenOCD and J-Link are alternatives selected with `--runner`/`-r`. So on a fresh install, **`west flash` fails until you pass `-r openocd`** (or install CubeProgrammer). This is the most common first stumbling block.
- The Zephyr **console is USART3** at **115200 8N1**, which is the ST-LINK virtual COM port you already used: `picocom -b 115200 /dev/ttyACM0`.
- The default system clock in this board's configuration is **72 MHz** (PLL from the 8 MHz HSE), not 216 MHz (section 8.3 shows how to change it).

Hello world:

```bash
west build -p always -b nucleo_f746zg samples/hello_world
west flash -r openocd
picocom -b 115200 /dev/ttyACM0         # expect: Hello World! nucleo_f746zg
```

### 3.5 Using your own `arm-none-eabi-gcc` (optional)

```bash
export ZEPHYR_TOOLCHAIN_VARIANT=gnuarmemb
export GNUARMEMB_TOOLCHAIN_PATH=/usr          # where bin/arm-none-eabi-gcc is
west build -p always -b nucleo_f746zg samples/hello_world
```

Works for many cases, but the SDK is the tested path and also gives OpenOCD, QEMU and `west debug` support. Check the "toolchain variants" documentation for your release.

### 3.6 udev and permissions

Same as before: the SDK provides rules (`sudo cp ~/zephyr-sdk-*/sysroots/x86_64-pokysdk-linux/usr/share/openocd/contrib/60-openocd.rules /etc/udev/rules.d/` and `sudo udevadm control --reload`), or the ones you already installed. Add yourself to `dialout` for the serial port.

---

## 4. `west`: the workspace tool

### 4.1 The commands you use

| Command | Purpose |
|---|---|
| `west init`, `west update` | Create the workspace; fetch/update all projects to the manifest revisions |
| `west list` | Projects (Zephyr and modules) with paths and revisions |
| `west status`, `west diff` | Git status/diff across projects |
| `west forall -c 'git status -s'` | Run a command in every project |
| `west boards` / `west boards -n f746` | List boards / filter by name |
| `west build` | Configure (CMake) and build |
| `west flash`, `west debug`, `west attach`, `west debugserver`, `west reset` | Flash and debug through runners |
| `west config` | Read/write west settings |
| `west sdk install` / `west sdk list` | Manage SDKs |
| `west packages pip --install` | Python requirements |
| `west twister` | The test runner |
| `west sign` | Sign images for MCUboot |
| `west completion bash` | Shell completion (save to `~/.bash_completion.d/` or source it) |
| `west -h`, `west build -h`, `west help` | Help; many extension commands appear only inside a workspace |

### 4.2 `west build` essentials

```bash
west build -b nucleo_f746zg path/to/app            # configure and build (first time needs -b)
west build                                         # rebuild with the saved configuration
west build -p always                               # pristine: wipe build dir first
west build -p auto                                 # let west decide when a pristine build is needed
west build -d build/f746 -b nucleo_f746zg app      # choose the build directory
west build -t menuconfig                           # interactive Kconfig (text UI)
west build -t guiconfig                            # graphical Kconfig
west build -t ram_report                           # RAM usage tree
west build -t rom_report                           # Flash usage tree
west build -t run                                  # run on emulators (qemu_*, native_sim)
west build -t clean ; west build -t pristine
west build -t usage                                # list available targets
west build -- -DCONFIG_LOG=y -DEXTRA_CONF_FILE=debug.conf    # CMake arguments go after --
```

Everything after `--` goes to CMake. Important variables:

| Variable | Use |
|---|---|
| `-DBOARD=...` | Board (usually via `-b`) |
| `-DCONF_FILE=...` | Replace `prj.conf` |
| `-DEXTRA_CONF_FILE=...` | Add extra Kconfig fragments |
| `-DDTC_OVERLAY_FILE=...` / `-DEXTRA_DTC_OVERLAY_FILE=...` | Replace/add devicetree overlays |
| `-DCONFIG_FOO=y` | Set a Kconfig symbol from the command line |
| `-DFILE_SUFFIX=debug` | Select `prj_debug.conf`, `app_debug.overlay`, `boards/<board>_debug.conf/overlay` (release-dependent; check docs) |
| `-DBOARD_FLASH_RUNNER=openocd` | Default runner for `west flash` (also `BOARD_DEBUG_RUNNER`) |
| `-DCMAKE_BUILD_TYPE=...` | Mostly not needed; optimization is chosen with Kconfig |

### 4.3 Defaults with `west config`

```bash
west config build.board nucleo_f746zg       # no more -b
west config build.pristine auto
west config --global build.generator Ninja  # or leave the default
```

After this, `cd app && west build` is enough.

### 4.4 Application layouts

**Option 1: app inside the workspace** (simplest to start): `~/zephyrproject/apps/blink/` with `CMakeLists.txt`, `prj.conf`, `src/main.c`.

**Option 2: out-of-tree "T2" topology** (recommended for real projects): your app repository **is** the manifest repository and pulls Zephyr in as a dependency, with a pinned version:

```
myproject/                  # your git repo
├── west.yml                # manifest
├── app/ (or top level) CMakeLists.txt prj.conf src/ boards/ ...
└── (west workspace created next to it)
```

```yaml
# west.yml
manifest:
  remotes:
    - name: zephyrproject-rtos
      url-base: https://github.com/zephyrproject-rtos
  projects:
    - name: zephyr
      remote: zephyrproject-rtos
      revision: v4.5.0              # pin the version (or an LTS tag)
      import: true                  # take Zephyr's own module list
  self:
    path: app
```

```bash
mkdir ws && cd ws
git clone https://example.com/me/myproject app
west init -l app          # use the existing repo as manifest
west update
```

Tip: `import: true` fetches every module (all vendor HALs). To save time and disk use `import:` with a `name-allowlist` listing only the modules you need (get names with `west list`); at least `hal_stm32`, `cmsis` (name varies by release), and anything your app uses.

---

## 5. A first application, step by step

```
blink/
├── CMakeLists.txt
├── prj.conf
├── src/main.c
└── boards/
    └── nucleo_f746zg.overlay        # optional, applied automatically for this board
```

`CMakeLists.txt`:

```cmake
cmake_minimum_required(VERSION 3.20.0)
find_package(Zephyr REQUIRED HINTS $ENV{ZEPHYR_BASE})
project(blink)

target_sources(app PRIVATE src/main.c)
```

`prj.conf`:

```
CONFIG_GPIO=y
CONFIG_LOG=y
CONFIG_ASSERT=y
```

`src/main.c`:

```c
#include <zephyr/kernel.h>
#include <zephyr/drivers/gpio.h>
#include <zephyr/logging/log.h>

LOG_MODULE_REGISTER(app, LOG_LEVEL_INF);

/* The hardware is chosen by an alias in the devicetree, not by a pin number in the code */
static const struct gpio_dt_spec led = GPIO_DT_SPEC_GET(DT_ALIAS(led0), gpios);

int main(void)
{
    if (!gpio_is_ready_dt(&led)) {
        LOG_ERR("LED GPIO controller not ready");
        return 0;
    }
    if (gpio_pin_configure_dt(&led, GPIO_OUTPUT_ACTIVE) < 0) {
        return 0;
    }

    for (;;) {
        gpio_pin_toggle_dt(&led);
        LOG_INF("uptime %lld ms", k_uptime_get());
        k_msleep(500);
    }
}
```

```bash
west build -p always -b nucleo_f746zg blink
west flash -r openocd
picocom -b 115200 /dev/ttyACM0
```

What differs from your bare-metal blink:

- No `SystemInit`, no clock setup, no register: `led0` is an alias defined in the board's devicetree; `gpio_dt_spec` bundles controller, pin number and polarity flags.
- `main()` is just a thread (the "main thread") started by the kernel after initialization. It may return.
- `k_msleep()` blocks this thread and lets other threads (and the idle thread) run, instead of burning the CPU.
- The same code works on any board that defines a `led0` alias.

Which LED is `led0`? Look at the board's devicetree (section 7.2): on this Nucleo it is expected to be the first user LED (LD1 green), `led1` the blue one and `led2` the red one, and `sw0` the user button B1. Verify in `build/zephyr/zephyr.dts`.

---

## 6. Kconfig: software configuration

### 6.1 Where options come from (later layers override earlier ones)

1. Defaults inside each `Kconfig` file (and `select`/`imply` from other symbols).
2. The board's defconfig (`boards/st/nucleo_f746zg/nucleo_f746zg_defconfig`).
3. **`prj.conf`** (your application).
4. Extra fragments (`boards/<board>.conf`, `-DEXTRA_CONF_FILE`, `-DOVERLAY_CONFIG` in older releases).
5. Command-line `-DCONFIG_X=y`.

The final result is in `build/zephyr/.config` (and `build/zephyr/include/generated/.../autoconf.h` for C). **Always check `.config`** to know what you really got.

### 6.2 Using `menuconfig`

```bash
west build -t menuconfig         # navigate with arrows; / searches symbols; ? shows help; S saves
```

Changes made in `menuconfig` go to the build directory only (lost on pristine builds). Copy the symbols you want to keep into `prj.conf`. The search shows a symbol's **dependencies and what selects it**, which is how you find out why an option is not available.

### 6.3 Frequent symbols

```
# console, logging, shell
CONFIG_PRINTK=y
CONFIG_LOG=y
CONFIG_LOG_MODE_IMMEDIATE=y        # print synchronously (easier for debugging, slower)
CONFIG_SHELL=y
CONFIG_KERNEL_SHELL=y
CONFIG_DEVICE_SHELL=y
CONFIG_GPIO_SHELL=y
CONFIG_I2C_SHELL=y

# debugging and robustness
CONFIG_ASSERT=y
CONFIG_DEBUG_OPTIMIZATIONS=y       # -Og instead of -Os
CONFIG_DEBUG_THREAD_INFO=y         # thread awareness in the debugger
CONFIG_THREAD_NAME=y
CONFIG_THREAD_STACK_INFO=y
CONFIG_THREAD_MONITOR=y
CONFIG_THREAD_ANALYZER=y
CONFIG_THREAD_ANALYZER_AUTO=y
CONFIG_THREAD_ANALYZER_AUTO_INTERVAL=5
CONFIG_INIT_STACKS=y
CONFIG_STACK_SENTINEL=y
CONFIG_HW_STACK_PROTECTION=y       # MPU guard at the end of stacks
CONFIG_RESET_ON_FATAL_ERROR=y      # reboot instead of halting on a fatal error (production)

# sizes
CONFIG_MAIN_STACK_SIZE=2048
CONFIG_ISR_STACK_SIZE=2048
CONFIG_SYSTEM_WORKQUEUE_STACK_SIZE=2048
CONFIG_HEAP_MEM_POOL_SIZE=4096     # k_malloc heap (0 disables dynamic allocation)

# optimization
CONFIG_SIZE_OPTIMIZATIONS=y
# CONFIG_SPEED_OPTIMIZATIONS=y

# floating point and printing
CONFIG_FPU=y                       # the F746 FPU (Zephyr enables the right FPU flags for the SoC)
CONFIG_CBPRINTF_FP_SUPPORT=y       # %f in printk/printf/log (costs Flash)

# C++
CONFIG_CPP=y
CONFIG_STD_CPP17=y
```

### 6.4 Kconfig tips

- **Assigned but not applied**: if you write `CONFIG_FOO=y` and a dependency is missing, the build **fails** with a message "was assigned the value y but got the value n. Missing dependencies: ...". Read it: it names exactly what to enable first.
- A typo in a symbol name is also reported. (Zephyr treats these as errors, which is good.)
- Browse all symbols with their help at <https://docs.zephyrproject.org/latest/kconfig.html>.
- In C: `IS_ENABLED(CONFIG_FOO)` (use it in `if (...)` so both branches are compiled and type-checked), or `#if defined(CONFIG_FOO)`.
- Keep **several configurations** with fragments: `prj.conf` (base), `debug.conf`, `release.conf`; select with `-DEXTRA_CONF_FILE=debug.conf`.
- Add **your own symbols** in an app `Kconfig` file (`source "Kconfig.zephyr"` at the end) to make application options visible in `menuconfig`:

```kconfig
# Kconfig (in the app root)
mainmenu "My app"
config APP_SENSOR_PERIOD_MS
    int "Sensor sampling period (ms)"
    default 100
source "Kconfig.zephyr"
```

and use `CONFIG_APP_SENSOR_PERIOD_MS` in C.

---

## 7. Devicetree: hardware description

### 7.1 Concepts

A devicetree is a tree of **nodes** with **properties**. It describes what hardware exists and how it is wired; **bindings** (YAML files) define which properties a node type may have. Zephyr turns the tree into C macros at build time (`devicetree_generated.h`).

```dts
/ {
    leds {
        compatible = "gpio-leds";
        green_led_1: led_0 {                      /* label: green_led_1, node name: led_0 */
            gpios = <&gpiob 0 GPIO_ACTIVE_HIGH>;  /* phandle to the GPIOB controller, pin 0, flags */
            label = "User LD1";
        };
    };
    aliases {
        led0 = &green_led_1;                      /* application-level alias for hardware independence */
    };
};

&usart3 { status = "okay"; current-speed = <115200>; };    /* override a node by label */
```

| Syntax | Meaning |
|---|---|
| `label: node { ... }` | Defines a node with a label for references |
| `&label` | Reference to a node (phandle) |
| `&label { ... }` | Modify an existing node (the way overlays work) |
| `status = "okay"` / `"disabled"` | Enable/disable a node (drivers only instantiate `okay` nodes) |
| `compatible = "vendor,device"` | Selects the binding and the driver |
| `reg = <...>` | Addresses (peripheral base, I2C address, ...) |
| `aliases { name = &node; }` | Stable names the application uses |
| `chosen { zephyr,console = &usart3; }` | System-level selections (console, shell, flash, SRAM) |
| `/delete-property/ x;`, `/delete-node/ &label;` | Remove from the inherited tree |
| `#include <zephyr/dt-bindings/...>` | Constants (`GPIO_ACTIVE_HIGH`, `I2C_BITRATE_FAST`, ...) |

### 7.2 Where to look (very useful)

```bash
find build -name zephyr.dts                       # the FINAL, merged devicetree: read this first
find build -name devicetree_generated.h           # generated C macros
ls ~/zephyrproject/zephyr/boards/st/nucleo_f746zg/                     # board files (.dts, defconfig, board.yml)
ls ~/zephyrproject/zephyr/dts/arm/st/f7/                               # SoC files (stm32f7.dtsi, stm32f746.dtsi)
ls ~/zephyrproject/zephyr/dts/bindings/                                # all bindings (properties documented here)
```

`build/zephyr/zephyr.dts` shows **which aliases exist**, which nodes are `okay`, and the final values after your overlay. When something "is not found", look there.

Documentation of bindings: <https://docs.zephyrproject.org/latest/build/dts/api/bindings.html>.

### 7.3 Overlays

Overlays modify the board's devicetree for your application, without touching Zephyr:

- `boards/nucleo_f746zg.overlay` (automatically applied for that board), or `app.overlay`, or `-DEXTRA_DTC_OVERLAY_FILE=...`.

Examples (labels such as `&i2c1`, `&adc1`, `&gpiod`, `&timers4` come from the SoC dtsi; verify them in your release):

```dts
/* Add a debug pin as an LED-like device with an alias */
/ {
    leds {
        compatible = "gpio-leds";
        debug_pin: debug_pin {
            gpios = <&gpiod 10 GPIO_ACTIVE_HIGH>;
        };
    };
    aliases {
        debugpin = &debug_pin;
    };
};
```

```dts
/* Enable I2C1 on PB8/PB9 and describe a sensor on it (example device) */
&i2c1 {
    status = "okay";
    pinctrl-0 = <&i2c1_scl_pb8 &i2c1_sda_pb9>;
    pinctrl-names = "default";
    clock-frequency = <I2C_BITRATE_FAST>;

    temp_sensor: sensor@48 {
        compatible = "ti,tmp116";        /* a compatible whose driver/binding exists in your release */
        reg = <0x48>;
    };
};
```

```dts
/* An ADC channel for an analog input, exposed through the zephyr,user node */
/ {
    zephyr,user {
        io-channels = <&adc1 3>;
    };
};

&adc1 {
    status = "okay";
    pinctrl-0 = <&adc1_in3_pa3>;
    pinctrl-names = "default";
    #address-cells = <1>;
    #size-cells = <0>;

    channel@3 {
        reg = <3>;
        zephyr,gain = "ADC_GAIN_1";
        zephyr,reference = "ADC_REF_INTERNAL";
        zephyr,acquisition-time = <ADC_ACQ_TIME_DEFAULT>;
        zephyr,resolution = <12>;
    };
};
```

The pinctrl labels (`i2c1_scl_pb8`, `adc1_in3_pa3`) follow the STM32 pin-control naming; list them with `grep -n "i2c1_scl" ~/zephyrproject/zephyr/dts/arm/st/f7/*pinctrl*` or in the `modules/hal/stm32/dts/st/f7/` pinctrl headers. They must match the alternate-function tables in the datasheet (chapter 7).

### 7.4 Using devicetree from C

```c
/* by alias (hardware independent): preferred in application code */
#define LED0  DT_ALIAS(led0)
static const struct gpio_dt_spec led = GPIO_DT_SPEC_GET(LED0, gpios);

/* by label */
#define SENSOR DT_NODELABEL(temp_sensor)
static const struct device *const sensor = DEVICE_DT_GET(SENSOR);

/* by the "chosen" system selection */
static const struct device *const console = DEVICE_DT_GET(DT_CHOSEN(zephyr_console));

/* properties and checks at compile time */
#if DT_NODE_HAS_STATUS(DT_NODELABEL(i2c1), okay)
  #define I2C1_FREQ DT_PROP(DT_NODELABEL(i2c1), clock_frequency)
#endif

/* is some device present at all? (useful for code shared between boards) */
#if DT_HAS_COMPAT_STATUS_OKAY(ti_tmp116)
  ...
#endif
```

Then, always at run time before use: `if (!device_is_ready(dev)) { ... }` (or `gpio_is_ready_dt(&spec)`).

### 7.5 Devicetree tips

- **Use aliases in application code** (`led0`, `sw0`, your own `debugpin`), and map them per board in overlays. Then the same source runs on other boards.
- A node that is `status = "disabled"` produces **no driver and no device**: using it leads to errors like `undefined reference to __device_dts_ord_NN` at link time. Fix: enable it (`status = "okay"`) and make sure the subsystem's Kconfig symbol (e.g. `CONFIG_I2C=y`) is set. Drivers are enabled automatically from `okay` nodes, but the **subsystem** (`CONFIG_GPIO`, `CONFIG_I2C`, `CONFIG_ADC`, `CONFIG_PWM`...) is up to the application.
- `DT_NODELABEL(x)` for a missing label gives a long error about an "undeclared" macro: check `zephyr.dts` for the correct label and `okay` status.
- Nodes can carry **custom properties** for your app: add a binding file `dts/bindings/vendor,my-thing.yaml` in your app and read them with `DT_PROP`. For simple values, use the `zephyr,user` node.
- Pin changes (AF) belong in `pinctrl`, not in code.
- The **Zio (Arduino) connector** labels (`arduino_header`, `arduino_i2c`, `arduino_spi`) are defined by the board; per the board page, note the Arduino SPI conflicts with the on-board Ethernet on PA7.
- Editor support: the *nRF DeviceTree* VS Code extension (works with any Zephyr board) gives completion and navigation.

---

## 8. Platform specifics: Nucleo-F746ZG

### 8.1 Defaults to remember

| Item | Default in the Zephyr board configuration |
|---|---|
| Console / shell / log | USART3 (PD8/PD9) via ST-LINK VCP, 115200 8N1 |
| Clock | PLL at 72 MHz from the 8 MHz HSE (ST-LINK MCO) |
| Flash runner | `stm32cubeprogrammer` (default); `openocd` and `jlink` also supported |
| Debug runner | OpenOCD |
| Extra UART | UART_2 on PD5/PD6/PD4/PD3 mapped on the Zio connector |
| Ethernet | Supported by the board configuration |

### 8.2 Flashing and debugging

```bash
west flash -r openocd                      # or install STM32CubeProgrammer and use plain `west flash`
west debug                                 # starts OpenOCD + gdb, stops at the first instruction
west debugserver                           # only the gdb server (for VS Code Cortex-Debug)
west attach                                # attach to a running target
```

In `west debug` (gdb) the usual commands apply (chapter 4). The SDK's gdb is `arm-zephyr-eabi-gdb` (in `~/zephyr-sdk-*/arm-zephyr-eabi/bin/`).

Cortex-Debug in VS Code (adapt the SDK path and verify against your versions):

```json
{
  "name": "Zephyr nucleo_f746zg",
  "type": "cortex-debug",
  "request": "launch",
  "servertype": "openocd",
  "cwd": "${workspaceFolder}",
  "executable": "${workspaceFolder}/build/zephyr/zephyr.elf",
  "configFiles": ["interface/stlink.cfg", "target/stm32f7x.cfg"],
  "gdbPath": "/home/jaigar/zephyr-sdk-VERSION/arm-zephyr-eabi/bin/arm-zephyr-eabi-gdb",
  "objdumpPath": "/home/jaigar/zephyr-sdk-VERSION/arm-zephyr-eabi/bin/arm-zephyr-eabi-objdump",
  "runToEntryPoint": "main",
  "rtos": "Zephyr"
}
```

Needs `CONFIG_DEBUG_THREAD_INFO=y` for the thread view (`"rtos": "Zephyr"`); remove the key if the debugger complains. Build with `CONFIG_DEBUG_OPTIMIZATIONS=y` for easier stepping. If the system OpenOCD is used instead of the SDK one, the `interface/stlink.cfg` and `target/stm32f7x.cfg` from chapter 4 work the same.

### 8.3 Changing the clock to 216 MHz (overlay, verify with the board DTS and your release)

The board's default is 72 MHz. To run at 216 MHz with the 8 MHz HSE (same numbers as chapter 7: M=4, N=216, P=2, Q=9; AHB /1, APB1 /4, APB2 /2):

```dts
&clk_hse {
    hse-bypass;                      /* clock comes from the ST-LINK MCO */
    clock-frequency = <DT_FREQ_M(8)>;
    status = "okay";
};

&pll {
    div-m = <4>;
    mul-n = <216>;
    div-p = <2>;
    div-q = <9>;
    clocks = <&clk_hse>;
    status = "okay";
};

&rcc {
    clocks = <&pll>;
    clock-frequency = <DT_FREQ_M(216)>;
    ahb-prescaler = <1>;
    apb1-prescaler = <4>;
    apb2-prescaler = <2>;
};
```

Compare with the board's own node values in `zephyr.dts` and change **only what differs**. Check that the clock driver for the F7 enables **over-drive** above 180 MHz (it should, but verify in the driver source), then **measure** (MCO output, a timer-generated pin on the logic analyzer, or compare `k_uptime_get()` against a stopwatch). After changing the clock, the UART baud rate, timers and `k_msleep()` all follow automatically, because they are derived from devicetree: another advantage over the bare-metal approach.

### 8.4 Reading internal channels

The STM32 ADC driver provides devicetree nodes for the internal channels (die temperature, VREF, VBAT) in recent releases, with the matching sensor drivers; search the docs for "stm32 vbat", "stm32 temp" and see the ADC and sensor samples (`samples/drivers/adc/adc_dt`, `samples/sensor/die_temp_polling` or similar). Check `zephyr.dts` for nodes named `vbat`, `vref`, `die_temp`.

---

## 9. The kernel in practice

### 9.1 Threads and scheduling

```c
#include <zephyr/kernel.h>

#define STACK_SIZE 1024
#define PRIO       5

static void sensor_thread(void *p1, void *p2, void *p3)
{
    ARG_UNUSED(p1); ARG_UNUSED(p2); ARG_UNUSED(p3);
    for (;;) {
        /* ... */
        k_msleep(100);
    }
}

K_THREAD_DEFINE(sensor_tid, STACK_SIZE, sensor_thread, NULL, NULL, NULL, PRIO, 0, 0);
```

Dynamic creation: `k_thread_create(&thread, stack, size, entry, p1, p2, p3, prio, options, delay)` with `K_THREAD_STACK_DEFINE(stack, SIZE); static struct k_thread thread;`.

Key facts:

- **Priorities**: lower number = higher priority. **Negative priorities are cooperative** (never preempted by other threads, only yield or block); **0 and positive are preemptible**. `main()` runs at priority `CONFIG_MAIN_THREAD_PRIORITY` (default 0). The system workqueue is cooperative-high by default.
- Scheduler is preemptive and priority-based; **time slicing** among equal priorities is optional (`CONFIG_TIMESLICING`, `CONFIG_TIMESLICE_SIZE`).
- Idle thread runs when nothing is ready (and sleeps the CPU).
- `k_msleep(ms)`, `k_sleep(K_SECONDS(1))`, `k_yield()`, `k_busy_wait(us)` (spins, only for microsecond waits), `k_thread_suspend/resume/abort`, `k_thread_name_set` (with `CONFIG_THREAD_NAME`).
- Time: `k_uptime_get()` (ms, 64-bit), `k_uptime_get_32()`, `k_cycle_get_32()`, `k_cyc_to_us_floor32()`, `sys_clock_hw_cycles_per_sec()`.

### 9.2 Synchronization and communication

| Object | Define | Use |
|---|---|---|
| Semaphore | `K_SEM_DEFINE(sem, 0, 1)` | Signal events (give from ISR is allowed) |
| Mutex | `K_MUTEX_DEFINE(m)` | Protect a resource (priority inheritance included) |
| Condition variable | `K_CONDVAR_DEFINE(cv)` | Wait for a condition with a mutex |
| Event | `K_EVENT_DEFINE(ev)` | Wait on bit combinations |
| Message queue | `K_MSGQ_DEFINE(q, msg_size, max_msgs, align)` | Fixed-size messages, copy semantics (ISR-safe with `K_NO_WAIT`) |
| FIFO/LIFO | `K_FIFO_DEFINE(f)` | Linked items you allocate |
| Pipe | `K_PIPE_DEFINE(...)` | Byte streams |
| Mailbox | `K_MBOX_DEFINE(m)` | Messages with sender/receiver matching |
| `k_poll` | `k_poll(events, n, timeout)` | Wait on several kernel objects at once |
| Ring buffer | `RING_BUF_DECLARE(rb, size)` | Utility (not a kernel object) |
| Atomics | `atomic_t`, `atomic_set_bit()`, `atomic_inc()` | Lock-free flags and counters |
| Spinlock | `K_SPINLOCK(&lock) { ... }` | Short critical sections (irq-safe) |
| zbus | `ZBUS_CHAN_DEFINE(...)` | Publish/subscribe message bus (like the event system of chapter 8) |

Timeouts: `K_NO_WAIT`, `K_FOREVER`, `K_MSEC(n)`, `K_SECONDS(n)`.

Producer/consumer with a message queue:

```c
struct sample { uint32_t t_ms; int16_t value; };
K_MSGQ_DEFINE(sample_q, sizeof(struct sample), 16, 4);

static void producer(void *a, void *b, void *c)          /* runs every 100 ms */
{
    for (;;) {
        struct sample s = { .t_ms = (uint32_t)k_uptime_get(), .value = read_sensor() };
        if (k_msgq_put(&sample_q, &s, K_NO_WAIT) != 0) { /* queue full: count the drop */ }
        k_msleep(100);
    }
}

static void consumer(void *a, void *b, void *c)
{
    struct sample s;
    for (;;) {
        k_msgq_get(&sample_q, &s, K_FOREVER);            /* sleeps until data arrives */
        LOG_INF("t=%u v=%d", s.t_ms, s.value);
    }
}
K_THREAD_DEFINE(prod_tid, 1024, producer, NULL, NULL, NULL, 6, 0, 0);
K_THREAD_DEFINE(cons_tid, 1536, consumer, NULL, NULL, NULL, 7, 0, 0);
```

### 9.3 Interrupts to threads: the button example

```c
static const struct gpio_dt_spec button = GPIO_DT_SPEC_GET(DT_ALIAS(sw0), gpios);
static struct gpio_callback button_cb_data;
K_SEM_DEFINE(button_sem, 0, 1);

static void button_isr(const struct device *port, struct gpio_callback *cb, uint32_t pins)
{
    k_sem_give(&button_sem);                              /* ISR context: keep it tiny */
}

int button_init(void)
{
    if (!gpio_is_ready_dt(&button)) { return -ENODEV; }
    gpio_pin_configure_dt(&button, GPIO_INPUT);
    gpio_pin_interrupt_configure_dt(&button, GPIO_INT_EDGE_TO_ACTIVE);
    gpio_init_callback(&button_cb_data, button_isr, BIT(button.pin));
    return gpio_add_callback(button.port, &button_cb_data);
}

/* in a thread: */
k_sem_take(&button_sem, K_FOREVER);
```

Debounce with a delayable work item: in the ISR call `k_work_reschedule(&debounce_work, K_MSEC(20))`; in the handler re-read the pin.

### 9.4 Timers and work queues

```c
/* periodic kernel timer: the expiry function runs in ISR context (system clock interrupt) */
static void tick_expiry(struct k_timer *t) { k_sem_give(&tick_sem); }
K_TIMER_DEFINE(tick_timer, tick_expiry, NULL);
k_timer_start(&tick_timer, K_SECONDS(1), K_SECONDS(1));

/* work queue: deferred work in thread context (the "bottom half") */
static void blink_handler(struct k_work *work);
static K_WORK_DELAYABLE_DEFINE(blink_work, blink_handler);

static void blink_handler(struct k_work *work)
{
    gpio_pin_toggle_dt(&led);
    k_work_reschedule(&blink_work, K_MSEC(500));          /* re-arm */
}
/* start: k_work_reschedule(&blink_work, K_NO_WAIT); */
```

Rules: `k_timer` callbacks and ISRs must not block; push work to the system workqueue (`k_work_submit`) or a dedicated one (`K_THREAD_STACK_DEFINE`, `k_work_queue_start`) whenever the response needs blocking calls. Do not block the system workqueue with long operations: it is shared with drivers and subsystems.

### 9.5 Memory

- **Static first**: `K_MEM_SLAB_DEFINE` (fixed blocks), `K_HEAP_DEFINE`, static buffers, `K_MSGQ`.
- `k_malloc()/k_free()` use the system heap, sized by `CONFIG_HEAP_MEM_POOL_SIZE` (0 means no heap). Prefer private heaps (`k_heap`) for subsystems.
- C library: **picolibc** is the default in current releases (small), or newlib (`CONFIG_NEWLIB_LIBC`). Float formatting needs `CONFIG_CBPRINTF_FP_SUPPORT=y` (and for `printf`/`scanf` family see `CONFIG_PICOLIBC_IO_FLOAT`).
- Stack sizes are a constant source of bugs: use `CONFIG_THREAD_ANALYZER`/`kernel stacks` (below) and give margin; log/printk/shell run with their own stack needs.

### 9.6 ISRs and interrupt control

Drivers register ISRs for you (devicetree decides the IRQ number and priority). For your own: `IRQ_CONNECT(irq, prio, isr, arg, flags); irq_enable(irq);`. `irq_lock()` returns a key to restore with `irq_unlock(key)`. ISRs use the dedicated interrupt stack (`CONFIG_ISR_STACK_SIZE`). Kernel calls allowed from an ISR are marked "ISR-ok" in the documentation (`k_sem_give`, `k_msgq_put` with `K_NO_WAIT`, `k_work_submit`, `k_fifo_put`, `atomic_*`); `k_mutex_lock` and `k_sleep` are not.

---

## 10. Drivers and subsystems (APIs by example)

Common pattern: get the device from devicetree, check `device_is_ready`, configure, use.

### 10.1 UART

```c
const struct device *const uart = DEVICE_DT_GET(DT_NODELABEL(usart2));   /* the label depends on the board */
uart_poll_out(uart, 'A');                       /* blocking one byte */
unsigned char c; int rc = uart_poll_in(uart, &c);    /* 0 on data, -1 none */
/* interrupt-driven API: uart_irq_callback_user_data_set(), uart_irq_rx_enable() ...
   async API (DMA): uart_callback_set(), uart_tx(), uart_rx_enable() */
```

Console/shell/logging already use the chosen UART; use a second UART (`UART_2` on the Zio connector) for application data.

### 10.2 ADC (with the overlay of 7.3)

```c
#include <zephyr/drivers/adc.h>

static const struct adc_dt_spec adc_ch = ADC_DT_SPEC_GET_BY_IDX(DT_PATH(zephyr_user), 0);

int read_mv(int32_t *mv)
{
    int16_t raw;
    struct adc_sequence seq = { .buffer = &raw, .buffer_size = sizeof(raw) };

    if (!adc_is_ready_dt(&adc_ch)) { return -ENODEV; }
    int rc = adc_channel_setup_dt(&adc_ch);                 /* once at init in real code */
    if (rc) { return rc; }
    adc_sequence_init_dt(&adc_ch, &seq);
    rc = adc_read_dt(&adc_ch, &seq);
    if (rc) { return rc; }
    *mv = raw;
    return adc_raw_to_millivolts_dt(&adc_ch, mv);
}
```

### 10.3 PWM, I2C, SPI, sensors

```c
/* PWM via a devicetree "pwms" property (pwm_dt_spec); period and pulse in ns or with macros */
pwm_set_dt(&pwm_led, PWM_USEC(1000), PWM_USEC(250));

/* I2C */
const struct i2c_dt_spec dev = I2C_DT_SPEC_GET(DT_NODELABEL(temp_sensor));
uint8_t reg = 0x00, buf[2];
i2c_write_read_dt(&dev, &reg, 1, buf, 2);

/* Sensor API */
struct sensor_value val;
sensor_sample_fetch(sensor);
sensor_channel_get(sensor, SENSOR_CHAN_AMBIENT_TEMP, &val);        /* val.val1 integer, val.val2 millionths */
```

Zephyr provides drivers for a large number of external sensors and displays: check `zephyr/drivers/sensor/` and the bindings before writing your own.

### 10.4 Writing a driver or a "device" of your own

- Define a **binding** (YAML in `dts/bindings/`), write the driver with `DT_DRV_COMPAT`, instantiate with `DT_INST_FOREACH_STATUS_OKAY()`, and register with `DEVICE_DT_INST_DEFINE`. It is a rewarding exercise and the same structure as the in-tree drivers; read a small one (e.g. a simple sensor or GPIO expander) first.
- For application code that is not a device, write ordinary modules (chapter 8 layering still applies): the application is the top layer, Zephyr's drivers are the HAL.

### 10.5 Other subsystems worth knowing

| Area | Items |
|---|---|
| Storage | Flash map (`flash_area_*`), NVS, Settings, FCB, LittleFS, FAT, ZMS |
| Networking | Sockets API, IPv4/IPv6, DHCP, DNS, MQTT, CoAP, HTTP client/server, TLS (mbedTLS), PTP; Ethernet MAC on the F746 |
| USB | The new USB device stack (`usbd`) (CDC ACM, MSC, HID...) and the older one, depending on release |
| Bluetooth, Wi-Fi, 802.15.4, LoRa | Need suitable hardware (not on this board by default) |
| CAN | `can_*` API, ISO-TP, CANopen |
| Industrial | Modbus, OpenAMP |
| UI | LVGL port, display API |
| Power | System PM, device runtime PM, tickless idle |
| Security | Crypto API, PSA, MCUboot, secure storage |
| Utilities | `sys/util.h`, `byteorder`, `crc`, `base64`, `ring_buf`, `sys_slist`, `lib/os/` helpers |

---

## 11. Logging, shell, tracing, and debugging aids

### 11.1 Logging

```c
#include <zephyr/logging/log.h>
LOG_MODULE_REGISTER(sensor, LOG_LEVEL_DBG);       /* one module per .c file; name appears in output */

LOG_ERR("read failed: %d", rc);
LOG_WRN("battery low (%d mV)", mv);
LOG_INF("started");
LOG_DBG("raw=%d", raw);
LOG_HEXDUMP_INF(buf, len, "rx");
```

- Levels can be chosen per module at compile time (`CONFIG_LOG_DEFAULT_LEVEL`, per-module Kconfig `CONFIG_SENSOR_LOG_LEVEL_DBG=y` via `LOG_MODULE_REGISTER(sensor)` with Kconfig-based level) and **at run time through the shell** (`log enable dbg sensor`).
- **Deferred mode** (default) formats log messages in a low-priority thread: fast for the caller, good for performance. **Immediate mode** (`CONFIG_LOG_MODE_IMMEDIATE=y`) prints right away in the caller's context: easier when debugging crashes, slower.
- Backends: UART, **RTT** (`CONFIG_USE_SEGGER_RTT=y`, `CONFIG_LOG_BACKEND_RTT=y`; works with J-Link and with OpenOCD-based RTT in some setups), shell, file system, network.
- `printk()` is the simple, always-available alternative (no formatting overhead of the logging subsystem; can be used in early init and in fatal handlers).

### 11.2 Shell

```
CONFIG_SHELL=y
CONFIG_KERNEL_SHELL=y
CONFIG_DEVICE_SHELL=y
CONFIG_THREAD_NAME=y
CONFIG_THREAD_MONITOR=y
CONFIG_THREAD_STACK_INFO=y
CONFIG_INIT_STACKS=y
```

Typical commands (type `help`): `kernel threads`, `kernel stacks`, `kernel uptime`, `kernel cycles`, `device list`, `log status`, `log enable inf app`, `gpio get ...`, `i2c scan i2c@40005400`, `sensor get ...`, `history`, `clear`. This turns a Nucleo into an interactive lab: scan I2C buses and read GPIOs without recompiling.

Your own commands:

```c
#include <zephyr/shell/shell.h>

static int cmd_vbat(const struct shell *sh, size_t argc, char **argv)
{
    int32_t mv;
    if (read_mv(&mv) == 0) { shell_print(sh, "adc = %d mV", mv); return 0; }
    shell_error(sh, "read failed");
    return -EIO;
}
SHELL_CMD_REGISTER(vbat, NULL, "Read the ADC channel", cmd_vbat);
```

(The shell takes over the console UART: the log output is mixed with it unless you use another backend.)

### 11.3 Thread analyzer and stack usage

```
CONFIG_THREAD_ANALYZER=y
CONFIG_THREAD_ANALYZER_AUTO=y
CONFIG_THREAD_ANALYZER_AUTO_INTERVAL=5
CONFIG_THREAD_ANALYZER_USE_LOG=y
CONFIG_THREAD_NAME=y
```

Prints, for each thread, the stack **used / size** and CPU usage periodically. Combine with `CONFIG_STACK_SENTINEL` and `CONFIG_HW_STACK_PROTECTION=y` (the MPU turns an overflow into a clean fault) and Zephyr's fatal error report names the thread.

### 11.4 Fatal errors: reading the report

A crash prints the register dump (`r0..r3, r12, lr, pc, xpsr`), the fault type and the current thread, e.g. a `ZEPHYR FATAL ERROR` with `Current thread: 0x... (name)` and a `Halting system`. This is the same stacked frame you analysed in chapter 3:

```
arm-zephyr-eabi-addr2line -e build/zephyr/zephyr.elf -f -p 0x0800abcd        # the reported pc
```

Options: `CONFIG_EXCEPTION_STACK_TRACE=y` (prints a call trace), `CONFIG_ASSERT=y` (assert failures show file and line), `CONFIG_RESET_ON_FATAL_ERROR=y` for production, a custom `k_sys_fatal_error_handler()` to record the fault in `.noinit`/retained memory (chapter 4 post-mortem).

### 11.5 Core dump and tracing

- `CONFIG_DEBUG_COREDUMP=y` writes a core dump to a backend (log, flash, ...) that you decode with `scripts/coredump/coredump_gdbserver.py` and gdb: post-mortem debugging of field failures.
- **Tracing**: CTF format, **SEGGER SystemView** (`CONFIG_SEGGER_SYSTEMVIEW=y`), Tracealyzer, or Percepio: show scheduling, ISRs, and mutex activity over time. This is the best way to understand priority inversion and latency problems in an RTOS.

### 11.6 gdb tips for Zephyr

```
(gdb) info threads                 # with CONFIG_DEBUG_THREAD_INFO and an RTOS-aware setup
(gdb) thread 3 ; bt                # backtrace of another thread
(gdb) p _kernel                    # the kernel structure
(gdb) p *_kernel.cpus[0].current   # the running thread control block
(gdb) break z_fatal_error          # stop at the fatal error handler
(gdb) break k_sys_fatal_error_handler
```

---

## 12. Power and timing notes

- Zephyr uses the Cortex-M SysTick (or an alternative timer) as the system clock. `CONFIG_TICKLESS_KERNEL=y` (default on many boards) removes the periodic tick and wakes only when needed, which saves power. `CONFIG_SYS_CLOCK_TICKS_PER_SEC` sets the tick resolution; `k_msleep()` granularity follows it.
- `CONFIG_PM=y` and device runtime PM require SoC support; on STM32F7 support is more limited than on newer STM32 families. Check the SoC documentation before designing a low-power product.
- Use `k_busy_wait(us)` only for tiny delays; use timers or `k_msleep` otherwise.
- For precise timing use the hardware cycle counter (`k_cycle_get_32()`), or a hardware timer/counter device API.

---

## 13. Testing

### 13.1 ztest

```c
/* tests/unit/src/main.c */
#include <zephyr/ztest.h>

ZTEST(math_suite, test_addition)
{
    zassert_equal(2 + 2, 4, "math is broken");
    zassert_within(3.14f, 3.1415f, 0.01f, "pi too far");
}

ZTEST_SUITE(math_suite, NULL, NULL, NULL, NULL, NULL);
```

`tests/unit/prj.conf`: `CONFIG_ZTEST=y`. `tests/unit/CMakeLists.txt`:

```cmake
cmake_minimum_required(VERSION 3.20.0)
find_package(Zephyr REQUIRED HINTS $ENV{ZEPHYR_BASE})
project(unit_tests)
target_sources(app PRIVATE src/main.c)
target_include_directories(app PRIVATE ${CMAKE_CURRENT_SOURCE_DIR}/../../app/src)
```

Run on your PC (no hardware) with the **`native_sim`** board:

```bash
west build -b native_sim tests/unit -t run
```

### 13.2 Twister: the test runner

`testcase.yaml`:

```yaml
tests:
  app.unit:
    platform_allow: native_sim
    tags: unit
```

```bash
west twister -T tests/ -p native_sim              # run all tests for native_sim
west twister -T tests/ -p nucleo_f746zg --device-testing --device-serial /dev/ttyACM0   # on hardware
west twister -T tests/ -p native_sim --coverage   # coverage reports
```

### 13.3 Hardware-free testing of drivers

- **`native_sim`** runs the whole application as a Linux process, with simulated UART, timers, and console. Excellent for application logic, state machines and RTOS interaction.
- **Emulators** for devices: `zephyr,i2c-emul` and sensor emulators, `gpio-emul`, flash simulators; test your driver code against a fake chip described in devicetree.
- QEMU boards (e.g. `qemu_cortex_m3`) run real ARM code without hardware (peripherals limited).
- Apply chapter 8's layering: pure logic in a module with no Zephyr dependencies is trivial to test; code using Zephyr APIs runs on `native_sim`.

### 13.4 CI

A CI job can install the SDK (cache it), run `west twister` on `native_sim`, build for `nucleo_f746zg`, check size reports (`west build -t rom_report`), and archive `zephyr.elf/.map`. The official CI action docs and containers (the Zephyr CI image) save time.

---

## 14. Images, bootloader, and updates (MCUboot)

```bash
west build -b nucleo_f746zg --sysbuild app -- -DSB_CONFIG_BOOTLOADER_MCUBOOT=y
west flash -r openocd
west sign -t imgtool ...            # signed, versioned images
```

- **Sysbuild** builds several images (bootloader + app) in one command (check the exact option names for your release).
- Flash layout is described by **devicetree fixed partitions** (`boot_partition`, `slot0_partition`, `slot1_partition`, `scratch_partition`, `storage_partition`). The STM32F7's **non-uniform sector sizes** (4x32 KB, 1x128 KB, 3x256 KB) constrain MCUboot's swap modes and slot placement. Read the board page and the MCUboot documentation, and test update and rollback paths explicitly before relying on them.
- Chapter 8's bootloader checklist (verify, never erase the only image, A/B or staging, confirm after boot) applies equally here.

---

## 15. C++ in Zephyr

```
CONFIG_CPP=y
CONFIG_STD_CPP17=y
# exceptions and RTTI are off by default; keep them off:
# CONFIG_CPP_EXCEPTIONS is not set
# CONFIG_CPP_RTTI is not set
```

A `.cpp` source in `target_sources(app ...)`; Zephyr's headers are C++-safe, `main()` can be defined as `int main(void)`. Constructors of global objects run before `main` as in chapter 6, so the same rules apply (no hardware access in constructors). Zephyr kernel objects such as `k_sem`, `k_mutex` can be wrapped in RAII classes (a `Mutex`/`LockGuard` pair is a nice exercise).

---

## 16. Tips and tricks (the list)

### 16.1 Workflow and build

1. **Pin the release** (`west init --mr vX.Y.Z` or `revision:` in `west.yml`). `main` changes daily. Prefer the LTS (3.7 series) for long-lived products, a recent release for new features.
2. **Read the migration guide** before each upgrade; Zephyr has regular breaking changes (board names, headers, Kconfig symbols). The current series moved to twice-yearly releases, so you have time between them.
3. Set defaults: `west config build.board nucleo_f746zg`, `west config build.pristine auto`.
4. Use a **separate build directory per board/config** (`-d build/f746-debug`) so you never need to wipe.
5. **Always check `build/zephyr/.config` and `build/zephyr/zephyr.dts`** when behavior surprises you: they are the truth after all merging.
6. After switching boards or changing devicetree/Kconfig fundamentals, build with `-p always` (pristine). Many "weird" errors are stale cache.
7. **`ccache`** is installed with the dependencies; Zephyr uses it automatically: rebuilds are fast.
8. `west build -- -DCONFIG_X=y` for quick experiments without editing files.
9. Use `FILE_SUFFIX` (or fragments) to keep `debug` and `release` configurations in the repo.
10. `west flash -r openocd` (or set `BOARD_FLASH_RUNNER`) so you do not need STM32CubeProgrammer.
11. Add shell completion: `west completion bash > ~/.west_completion && echo 'source ~/.west_completion' >> ~/.bashrc`.
12. Keep the **Zephyr SDK version** matched to the Zephyr release (the docs state the minimum). A mismatch gives odd compiler or linker errors.
13. `west build -t rom_report` and `ram_report` show **who uses Flash and RAM**: the first stop for size problems.
14. Run `west update` after every `git pull`/branch switch of the manifest (or the modules will not match).
15. Use the **samples as templates**: `samples/basic/blinky`, `samples/basic/button`, `samples/synchronization`, `samples/philosophers`, `samples/drivers/adc/adc_dt`, `samples/subsys/shell/shell_module`, `samples/subsys/logging/logger`, `samples/net/sockets/echo_server`, `samples/subsys/settings`, `samples/subsys/usb/cdc_acm`. Copy one, then modify.
16. **Search the code**, not just the docs: `grep -rn "CONFIG_FOO" ~/zephyrproject/zephyr --include=Kconfig*`, `rg k_msgq_put zephyr/include`, and look at `tests/` for usage examples of every API.

### 16.2 Kconfig and devicetree

17. **Application code should depend on aliases and `CONFIG_APP_*` symbols, not on pin numbers.** That is what lets the same app run on other boards.
18. If a build error says a `__device_dts_ord_*` symbol is undefined, the node is disabled or the subsystem Kconfig is missing.
19. If `device_is_ready()` returns false at run time: the driver failed to init (clock, pinctrl, reset), the node is disabled, or init order/priority is wrong. The kernel logs the reason when `CONFIG_LOG` is on; try `CONFIG_LOG_MODE_IMMEDIATE=y` and check `device list` in the shell.
20. Never edit Zephyr's board files in place: use overlays. Your diffs stay small and survive upgrades.
21. Use `IS_ENABLED(CONFIG_X)` in `if` conditions rather than `#ifdef` when possible, so both branches are compiled and type-checked.
22. `menuconfig` search (`/`) is the best way to discover options and **why a symbol cannot be enabled**.
23. Enable `CONFIG_ASSERT=y` in development: many API misuse errors become immediate, located failures.
24. `zephyr,user` node in the overlay is the easy way to pass arbitrary hardware parameters (GPIO, ADC channels, PWM) to the app without writing a binding.
25. Put each board's tuning (`boards/<board>.conf` + `.overlay`) in the app's `boards/` directory; they are picked up automatically.

### 16.3 Kernel and design

26. **Few threads**, clear priorities, communicate with queues/events (chapter 8, RTOS rules). Do not create a thread per function.
27. Prefer **work queues** (`k_work`) for deferred ISR work and short jobs: no extra stack, no extra thread.
28. Keep ISRs and `k_timer` callbacks tiny; use `K_NO_WAIT` in them.
29. **Never block** (`k_msleep`, `k_mutex_lock`, `k_sem_take` with a timeout) in the system workqueue handlers for long periods, nor in ISRs.
30. Use **`k_msgq`** for fixed-size messages (copy semantics, no ownership questions); use `k_fifo`/`k_mem_slab` when passing buffers.
31. Use **`K_THREAD_DEFINE`** for always-running threads (static memory, starts at boot) and `k_thread_create` only when you need dynamic control.
32. Protect shared data with a **mutex** (priority inheritance) or **spinlock** (very short sections), never with `irq_lock` held over slow operations.
33. **Use atomics** (`atomic_t`) for flags set in ISRs and read in threads.
34. **Tune stack sizes by measurement** (thread analyzer), then add 25-50 % margin; `CONFIG_HW_STACK_PROTECTION` catches overflows on Cortex-M with an MPU.
35. For latency-sensitive code, give the thread a **cooperative priority** (negative) or raise its priority; measure with tracing before guessing.
36. Name threads (`k_thread_name_set` or the `K_THREAD_DEFINE` name) when `CONFIG_THREAD_NAME` is on: logs and the shell become readable.
37. Avoid `k_malloc` in long-running firmware; static allocation and slabs behave predictably.
38. Use **`LOG_MODULE_REGISTER`** in every file, with the module name as the tag. Log levels per module are a superpower.
39. `printk` for very early boot or fatal handlers; `LOG_*` everywhere else.

### 16.4 Debugging

40. If the board prints nothing: check the console `chosen` node and baud rate, that the right terminal is open (`/dev/ttyACM0`), `CONFIG_SERIAL=y` and `CONFIG_UART_CONSOLE=y` defaults, and that nothing else holds the port.
41. `west debug` for a quick session, `west debugserver` + Cortex-Debug for VS Code, `west attach` to inspect a running system without reset.
42. **Use the shell** (`kernel threads`, `kernel stacks`, `device list`, `i2c scan`) in development; it replaces a lot of printf debugging.
43. Add `CONFIG_DEBUG_OPTIMIZATIONS=y` and `CONFIG_DEBUG_THREAD_INFO=y` while debugging; remove for release.
44. On a fatal error read the **pc and lr** in the report and resolve them with `addr2line`; check which thread crashed.
45. Reproduce logic bugs on **`native_sim`** first: it is faster than flashing and you can use `gdb`, ASan and `valgrind`-like tools on it.
46. If `west flash` hangs or times out: the same ST-LINK issues from chapter 4 (replug the board, close other tools holding the probe).
47. For timing questions use **tracing** (SystemView/CTF) rather than guessing: you will see priority inversion and unexpected preemptions directly.

### 16.5 Hardware specifics

48. The **console UART is shared by logs, shell and printk**: if you also need raw data on it, use a different UART for your protocol, or disable the shell.
49. The Nucleo's Arduino **SPI pins conflict with Ethernet (PA7)** when both are used; check the board documentation for such notes before wiring.
50. Default clock is 72 MHz in the board configuration; **overlay to 216 MHz** only if you need it (more power, more heat, flash wait states and over-drive).
51. Check the board page for solder-bridge notes (for example removing SB156 to disconnect VBAT from VDD to test the backup SRAM).
52. Remember the debug pins (PA13/PA14/PB3) when you reassign pins in an overlay.

### 16.6 Common mistakes table

| Symptom | Likely cause and fix |
|---|---|
| `west flash` fails complaining about STM32CubeProgrammer | Default runner: use `west flash -r openocd`, or install CubeProgrammer |
| `west: unknown command "build"` | Not inside a workspace or the venv is not activated; `source .venv/bin/activate` and `source zephyr/zephyr-env.sh` |
| `Board nucleo_f746zg not found` | Wrong name/qualifier or old release: `west boards \| grep f746` |
| `CMake Error: could not find Zephyr` | `ZEPHYR_BASE` not set (`source zephyr-env.sh`), or `west zephyr-export` was not run |
| Kconfig "assigned the value y but got n" | Missing dependency named in the message: enable it first |
| `undefined reference to __device_dts_ord_X` | Node disabled or driver/subsystem Kconfig not enabled |
| `DT_N_ALIAS_led0 undeclared` | The board has no `led0` alias: add one in an overlay |
| `device_is_ready()` false | Driver init failed or node disabled; check logs/`device list` |
| Random reboots/hangs, `Stacking error`, MPU fault | Stack overflow or bad pointer: enable stack protection, measure stacks |
| Output garbled at startup | Baud mismatch after a clock change, or logging mode/UART shared with the shell |
| `%f` prints nothing | `CONFIG_CBPRINTF_FP_SUPPORT=y` (and libc float options) |
| `k_msleep` seems inaccurate | System tick resolution/tickless settings; use a timer or hardware counter for exact timing |
| Priority inversion symptoms | Use mutexes (inheritance), not binary semaphores, for resource locking |
| Out of Flash/RAM | `ram_report`/`rom_report`, `CONFIG_SIZE_OPTIMIZATIONS`, disable logging/shell in release, shrink stacks |
| Build works only after `-p always` | Stale cache after changing board/overlays: build pristine, or use separate build dirs |

---

## 17. Lab exercises

Setup and basics:

1. **Install and verify**: run `hello_world` on the Nucleo; use `picocom` to read the console.
2. **First flash with OpenOCD**: understand why plain `west flash` failed (default runner) and set `BOARD_FLASH_RUNNER`.
3. **Read the generated files**: open `build/zephyr/.config`, `zephyr.dts`, `devicetree_generated.h`, `zephyr.map`. Find the `led0` alias, the console UART, and the clock configuration.
4. **menuconfig**: change the log level and the main stack size with `menuconfig`; then make the change permanent in `prj.conf`.

Devicetree and Kconfig:

5. **Overlay**: add `boards/nucleo_f746zg.overlay` with a new LED alias for another pin, and toggle it from code via `DT_ALIAS`.
6. **Clock**: switch to 216 MHz with the overlay of 8.3, then prove the frequency (logic analyzer with a toggled pin and `k_busy_wait`, or MCO).
7. **Kconfig fragments**: create `debug.conf` and `release.conf` and build both in separate directories; compare `rom_report` and Flash size.
8. **Custom Kconfig symbol** and a custom binding/property read with `DT_PROP`.

Kernel:

9. **Two threads** with different priorities and a shared counter: show the race without a mutex, then fix it.
10. **ISR to thread**: button GPIO callback giving a semaphore; debounce with `k_work_delayable`; count events.
11. **Message queue pipeline**: sensor thread to processing thread to logger, with drop counters under stress.
12. **Work queue**: replace a sleeping loop with `k_work_reschedule`; compare stack and CPU use with the thread analyzer.
13. **Priority inversion**: reproduce it with a low-priority holder, a medium busy thread and a high-priority waiter using a semaphore; then fix with a mutex and look at the behavior in SystemView or by logging.
14. **Stack overflow**: allocate a large local array in a thread with a small stack; observe the fatal error report with `CONFIG_HW_STACK_PROTECTION` on and off.

Drivers and subsystems:

15. **ADC**: read an input (A0 on the Zio connector; verify the pin) and print millivolts; expose a `vbat` shell command.
16. **I2C scan** with the shell, then read a real sensor through the sensor API (enable the node in an overlay).
17. **PWM**: dim an LED through a `pwm-leds`/`pwms` node, with a thread generating a breathing pattern.
18. **Second UART**: send data on UART_2 (Zio connector) while the shell stays on the console.
19. **Logging**: per-module levels, switch levels at run time from the shell, hexdump a buffer.
20. **Fatal handler**: implement `k_sys_fatal_error_handler()` that stores the fault info in a `.noinit` variable, resets, and prints the report on the next boot (chapter 4).

Testing and delivery:

21. **ztest**: unit-test a pure-logic module (ring buffer, parser, state machine) on `native_sim` with `west twister`.
22. **Emulated device**: test your sensor code against an I2C emulator node.
23. **MCUboot**: build with sysbuild, flash bootloader+app, and update with a new signed image; test rollback by flashing a deliberately bad image.
24. **CI**: a pipeline that installs the SDK (cached), runs twister on `native_sim`, builds the Nucleo image, and uploads `zephyr.elf` and `zephyr.map`.
25. **Port a chapter 8 example**: re-implement the "blinker + button + UART + VBAT" project in Zephyr and compare it with the bare-metal version (code size, lines of code, development time, debugging experience).

---

## 18. Cheat sheet

### Setup

```bash
source ~/zephyrproject/.venv/bin/activate
source ~/zephyrproject/zephyr/zephyr-env.sh
```

### Everyday commands

```bash
west build -b nucleo_f746zg -p auto app           # build (configure on first use)
west build -t menuconfig                          # configuration UI
west build -t rom_report ; west build -t ram_report
west flash -r openocd                             # program (default runner is CubeProgrammer)
west debug ; west debugserver ; west attach
west boards | grep f746 ; west list ; west update
west twister -T tests/ -p native_sim              # tests
picocom -b 115200 /dev/ttyACM0                    # console (Ctrl+A Ctrl+X to exit)
```

### Where truth lives

| Question | File / command |
|---|---|
| What did Kconfig finally choose? | `build/zephyr/.config` |
| What does the hardware look like after overlays? | `build/zephyr/zephyr.dts` |
| Which macros does my code get? | `devicetree_generated.h`, `autoconf.h` |
| Where did Flash/RAM go? | `west build -t rom_report` / `ram_report`, `zephyr.map` |
| Why is a symbol unavailable? | `menuconfig`, search, dependencies |
| What properties can a node have? | `zephyr/dts/bindings/**.yaml`, binding docs |
| How is this API used? | `samples/`, `tests/`, `include/zephyr/` |

### Kernel quick reference

```
Threads    K_THREAD_DEFINE, k_thread_create, k_msleep, k_yield     (lower number = higher priority; <0 cooperative)
Sync       k_sem, k_mutex, k_condvar, k_event, k_poll
Data       k_msgq, k_fifo, k_pipe, ring_buf, zbus
Deferred   k_work, k_work_delayable, k_timer
Memory     K_MEM_SLAB_DEFINE, K_HEAP_DEFINE, k_malloc (CONFIG_HEAP_MEM_POOL_SIZE)
Time       k_uptime_get(), k_cycle_get_32(), K_MSEC(), K_SECONDS(), K_FOREVER, K_NO_WAIT
HW access  DT_ALIAS / DT_NODELABEL / DEVICE_DT_GET / *_dt_spec, device_is_ready()
Debug      LOG_*, printk, shell, thread analyzer, CONFIG_ASSERT, west debug
```

### Golden rules

- Hardware in devicetree, software in Kconfig, logic in C.
- Pin the version; read migration guides.
- Use aliases in app code; overlays for board differences.
- Check `.config` and `zephyr.dts` when surprised.
- Measure stacks and sizes, do not guess.
- Test logic on `native_sim` first.

---

## 19. Where this leads

- **Networking**: run `samples/net/sockets/echo_server` on the F746's Ethernet, then MQTT or HTTP (needs a PHY and a cable; check the board page for current support level).
- **USB**: CDC ACM console or MSC with the new USB device stack.
- **Bootloader and updates**: MCUboot with signed images, over UART/USB/network.
- **Writing a driver and a binding** for an external sensor, then upstreaming it (the project welcomes contributions: the documentation has a contributor guide).
- **Power management** on a board with better support (newer STM32 or Nordic parts), measuring current.
- **Learning material**: Nordic's *nRF Connect SDK Fundamentals* and *Intermediate* courses on DevAcademy (the nRF Connect SDK is Zephyr-based and the concepts transfer directly), Zephyr's own documentation and samples, and the Zephyr project's talks.

## References

- Zephyr documentation: <https://docs.zephyrproject.org/latest/>
- Getting Started Guide: <https://docs.zephyrproject.org/latest/develop/getting_started/index.html>
- Board page: <https://docs.zephyrproject.org/latest/boards/st/nucleo_f746zg/doc/index.html>
- Release notes and migration guides: <https://docs.zephyrproject.org/latest/releases/index.html>
- Devicetree guide and bindings index: <https://docs.zephyrproject.org/latest/build/dts/index.html>
- Kconfig symbol search: <https://docs.zephyrproject.org/latest/kconfig.html>
- West documentation: <https://docs.zephyrproject.org/latest/develop/west/index.html>
- Zephyr SDK: <https://github.com/zephyrproject-rtos/sdk-ng>
- Zephyr repository and samples: <https://github.com/zephyrproject-rtos/zephyr>
- Memfault *Interrupt* blog (Zephyr series): <https://interrupt.memfault.com>
- Nordic DevAcademy (Zephyr-based courses): <https://academy.nordicsemi.com>
- ST UM1974 (Nucleo-144 user manual) and RM0385 (chapter 7 of these notes)