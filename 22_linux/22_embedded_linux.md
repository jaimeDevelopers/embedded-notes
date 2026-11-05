# 22. Embedded Linux: A Primer for Microcontroller Engineers

You have spent these chapters on **microcontrollers** (bare metal, RTOS). Many products use a **microprocessor running Linux** instead: network gateways, UIs, cameras, industrial controllers. This chapter explains **where Linux fits, how a Linux system boots and is built, and how your MCU knowledge transfers**, with a hands-on path that needs only your Ubuntu PC (QEMU) before buying hardware.

Prerequisites: chapters 0-3 (toolchain, linker/ELF, startup, exceptions), chapter 7 (peripherals), chapter 11 (protocols), chapter 16 (secure boot and OTA concepts), chapter 20/17 (tools).

**Verification note.** Release information was checked in October 2026: **Yocto Project 6.0 "Wrynose"** (LTS, released May 2026, supported until April 2030, Linux 6.18 LTS) and **Buildroot 2026.02** (March 2026; quarterly releases follow). Versions, recommended host requirements and layer names change: check the official documentation of the release you choose. Commands are standard but **not run by me on your machine**.

---

## 1. Where Linux fits (and where it does not)

| Aspect | Microcontroller (bare metal / RTOS) | Embedded Linux |
|---|---|---|
| CPU | Cortex-M, no MMU | Cortex-A (and some RISC-V/x86), **MMU**, usually 64-bit/32-bit multi-core |
| RAM | KB to a few MB | **tens of MB to GB** (external DDR) |
| Storage | Internal flash | SD/eMMC/NAND/NOR, GB-scale |
| Boot time | Milliseconds | Seconds (tens of ms to a few seconds with tuning) |
| Real-time | Hard real-time, microsecond jitter | Soft real-time; **PREEMPT_RT** gives 10s-100s µs bounded latency |
| Software | Your code + small RTOS | Kernel + drivers + libc + userspace (many processes) |
| Power | µA-mA | 100s mW to W (suspend modes exist) |
| Networking, USB, filesystems, UI, languages | Add stacks yourself | **Rich and mature** (TCP/IP, TLS, Python, Qt, browsers) |
| Updates/security | Bootloader + signed image | Full OS updates, package/ container ecosystems, more attack surface |
| Cost/complexity | Low | Higher: BOM, power, layout (DDR), build system, maintenance |
| Typical devices | Sensors, motor drives, appliances | Gateways, HMIs, cameras, routers, vehicle infotainment |

### Common architecture: both together

```
 [ Linux SoC (UI, network, storage, cloud)  ] ◄── UART / SPI / CAN / RPMsg ──► [ MCU (real-time control, safety, low power) ]
```

Linux does what is hard on an MCU (networking, UI, storage), the MCU does what Linux does poorly (hard real-time, deterministic I/O, ultra-low power). **STM32MP1/MP2** parts integrate Cortex-A cores plus a Cortex-M co-processor in one chip (communication through **RPMsg/OpenAMP**), and your Cortex-M knowledge applies directly to the M side.

Your **NUCLEO-F746ZG cannot run mainstream Linux** (no MMU, too little RAM; uClinux exists for MMU-less parts but is niche). Your Ubuntu laptop is the **development host**; a Raspberry Pi, BeagleBone, STM32MP1 Discovery, i.MX board, or **QEMU** is the target.

---

## 2. Anatomy of an embedded Linux system

```
 Boot ROM ──► first-stage bootloader (SPL / TF-A) ──► U-Boot ──► Linux kernel (+ device tree) ──► init system ──► your applications
  (SoC)        initializes DDR/clocks                   loads        drivers, filesystem                systemd / BusyBox init
```

| Component | Role |
|---|---|
| **Boot ROM** | Fixed code in the SoC: reads boot pins/fuses, loads the first stage from SD/eMMC/QSPI/USB/UART |
| **SPL / TF-A / TPL** | Initialize DRAM and basic hardware; load U-Boot; on Armv8 TF-A (Trusted Firmware-A) sets up secure monitor/PSCI |
| **U-Boot** (most common bootloader) | Loads kernel image, **device tree blob (DTB)** and optionally initramfs from storage/network; environment variables; scripts; handles A/B logic; has a console (`printenv`, `bootcmd`, `tftp`, `ext4load`, `bootz`/`booti`) |
| **Kernel** | Scheduler, memory management, drivers, networking, filesystems, security; built with **Kconfig** (`make menuconfig`), configured by a **defconfig** |
| **Device tree** | Describes the hardware to the kernel (`.dts` → `.dtb`); conceptually the same as Zephyr's (chapter 9) |
| **Root filesystem** | `/bin`, `/lib`, `/etc`, `/dev`... on ext4/squashfs/UBIFS/initramfs |
| **C library** | glibc (full), **musl** (small), uClibc-ng |
| **init system** | **systemd** (services, units, logging) or **BusyBox init**/OpenRC (minimal) |
| **Userspace** | BusyBox (tiny coreutils), daemons (`sshd`, `dropbear`), your application(s) and libraries |
| **Kernel modules** | Loadable drivers (`.ko`) |

Key mental shift from MCU:

- **Processes, virtual memory and files**: your program does not own the hardware; it uses **system calls** and **device files**.
- **No linker script for your app**: the OS loader maps ELF files; the kernel and drivers do the hardware access.
- **Drivers are in the kernel** (or userspace via `/dev` interfaces: GPIO, I2C, SPI, UART, IIO, `uio`, `spidev`).
- A crash of your app does not crash the system (it is killed), but a kernel bug does.
- **Boot media** can be corrupted by power loss: use read-only root filesystems and journaling, as in section 9.

---

## 3. The device tree (comparison with Zephyr)

```dts
/* excerpt style of arch/arm/boot/dts/... */
&i2c1 {
    status = "okay";
    clock-frequency = <400000>;
    pinctrl-names = "default";
    pinctrl-0 = <&i2c1_pins>;

    temp@48 {
        compatible = "ti,tmp102";       /* matches a kernel driver (and its binding document) */
        reg = <0x48>;
    };
};
```

| | Linux device tree | Zephyr devicetree (chapter 9) |
|---|---|---|
| Syntax | Same DTS language | Same DTS language |
| Compiled by | `dtc` → `.dtb` loaded by the bootloader at **boot time** | `dtc`/Python → C macros at **build time** |
| Bindings | Documentation (`Documentation/devicetree/bindings`, YAML schemas) | YAML bindings used by the build |
| Used by | Kernel drivers matching `compatible` strings at run time | Application and drivers via macros |
| Overlays | `.dtbo` applied at boot (e.g. Raspberry Pi `dtoverlay=`) or at run time with configfs | `.overlay` files at build time |

Debug aids: `dtc -I dtb -O dts file.dtb` (decompile), `/proc/device-tree` and `/sys/firmware/devicetree` at run time, `dmesg | grep -i i2c`, `ls /sys/bus/i2c/devices`.

---

## 4. Choosing how to get a Linux system

| Option | What | When |
|---|---|---|
| **Ready-made distro** (Raspberry Pi OS, Debian/Ubuntu for ARM, Armbian) | Pre-built images; `apt` packages | Prototyping, learning, products where size/boot time are not critical |
| **Buildroot** | Simple build system (Kconfig + Makefiles) that builds toolchain, bootloader, kernel, and a **small custom root filesystem** | Single product images, learning, fast iteration, small footprint |
| **Yocto Project / OpenEmbedded** | Powerful layered build framework (**BitBake**, recipes, layers) that generates a **distribution**, SDKs and package feeds | Product lines, many boards, long-term maintenance, vendor BSPs (NXP, ST, TI...), license/CVE/SBOM management |
| **OpenWrt** | Router-oriented distribution with a package system | Network devices |
| **Vendor SDKs** | Often Yocto-based (OpenSTLinux for STM32MP, NXP i.MX BSP) | When using that vendor's SoC |

Rule of thumb: **learn with Buildroot** (an afternoon to a working image); **use Yocto** when you need a maintained product platform. Both are heavy builds (hours on the first run) and need a Linux host.

---

## 5. Hands-on 1: Buildroot with QEMU (no hardware needed)

### 5.1 Host setup

```bash
sudo apt install build-essential git libncurses-dev libssl-dev bc flex bison unzip rsync cpio file wget \
                 qemu-system-arm python3
git clone https://gitlab.com/buildroot.org/buildroot.git
cd buildroot
git checkout 2026.02.1            # or the current release tag you choose: list with `git tag | tail`
make list-defconfigs | grep qemu
```

(Buildroot releases quarterly: `YYYY.02`, `.05`, `.08`, `.11`; the `.02` releases get longer maintenance. Use a **tag**, not `master`, for reproducibility.)

### 5.2 Build and run an ARM system

```bash
make qemu_arm_vexpress_defconfig        # an ARM Cortex-A9 Versatile Express machine definition
make menuconfig                         # optional: toolchain, packages, kernel options
make -j"$(nproc)"                       # first build takes tens of minutes to hours: downloads and compiles everything
ls output/images/                       # zImage, DTB, rootfs.ext2 (names depend on the config) and start-qemu.sh
./output/images/start-qemu.sh --serial-only      # follow output/images and board/qemu/arm-vexpress/readme.txt
```

At the login prompt use `root` (no password in the default QEMU configs). You are now inside an embedded Linux system you built: explore `uname -a`, `ls /dev`, `cat /proc/cpuinfo`, `dmesg`, `ps`, `mount`.

### 5.3 What the build produced

```
output/
├── build/        per-package build directories (source trees compiled)
├── host/         the host tools, including the cross toolchain (host/bin/arm-buildroot-linux-*-gcc)
├── staging/      target sysroot (headers and libs for cross-compiling your own apps)
├── target/       the root filesystem tree (before packing into an image)
└── images/       final images: kernel, DTB, root filesystem, SD card image
```

### 5.4 Customizing

```bash
make menuconfig                         # Target packages → add dropbear (SSH), htop, python3, i2c-tools, libgpiod...
make savedefconfig BR2_DEFCONFIG=configs/myboard_defconfig     # store your configuration compactly
make linux-menuconfig                   # kernel configuration; make linux-update-defconfig to save
make <package>-rebuild ; make <package>-dirclean
make clean ; make distclean
```

Better practice: **keep customizations out of the Buildroot tree** with `BR2_EXTERNAL` (your own repository with `configs/`, `board/`, `package/`, overlays):

```bash
make BR2_EXTERNAL=../my_external myboard_defconfig
```

A **root filesystem overlay** (`BR2_ROOTFS_OVERLAY`) adds your files (config, scripts, your compiled application) into the image; a **post-build script** (`BR2_ROOTFS_POST_BUILD_SCRIPT`) runs commands on `output/target` before packing.

### 5.5 Adding your own application as a package

```make
# package/myapp/Config.in
config BR2_PACKAGE_MYAPP
    bool "myapp"
    help
      My application.

# package/myapp/myapp.mk
MYAPP_VERSION = 1.0
MYAPP_SITE = $(BR2_EXTERNAL_MY_PATH)/src/myapp
MYAPP_SITE_METHOD = local
$(eval $(cmake-package))               # or $(generic-package) / $(autotools-package)
```

This is where your CMake knowledge (chapter 2) pays off: a CMake project becomes a Buildroot package with three lines.

---

## 6. Hands-on 2: Yocto (overview and a minimal path)

Yocto is **a build system generator for distributions**: you describe an image from **layers** of **recipes** (`.bb`), and **BitBake** builds everything reproducibly with caching (`sstate`) and a package feed.

Key terms:

| Term | Meaning |
|---|---|
| **Poky** | Yocto's reference distribution and build system bundle |
| **OpenEmbedded-Core** (`meta`) | Core recipes |
| **Layer** (`meta-xyz`) | A collection of recipes/config (BSP layer for your board, application layer, vendor layers) |
| **Recipe** (`.bb`, `.bbappend`) | Instructions to fetch, configure, build, package one piece of software |
| **MACHINE** | Target hardware (e.g. `qemuarm64`, `raspberrypi4-64`, `stm32mp157f-dk2`) |
| **DISTRO** | Policy: init system, libc, features |
| **Image recipe** | What goes in the image (`core-image-minimal`, `core-image-base`, your own) |
| `local.conf`, `bblayers.conf` | Build configuration and enabled layers |
| **SDK** (`bitbake -c populate_sdk`) | Cross toolchain + sysroot for application developers |
| **devtool** | Modify/add recipes and iterate on sources |
| `wic` | Create partitioned disk images |

Current status (October 2026): **Yocto Project 6.0 "Wrynose"** is the LTS (4 years of support), with Linux 6.18; 6.1 is the short-term release (Q4 2026) and the next LTS is planned for 2028. Release notes mention improved **SBOM and CVE tracking** (aligned with the EU Cyber Resilience Act), and **a new `bitbake-setup` tool** for fetching layers and setting up build directories. The documentation lists recommended host requirements for the release (it is heavy: expect tens of GB of RAM and well over 100 GB of disk for the full toolchain builds, check the current documentation).

A minimal QEMU build (verify the commands with the quick-build guide of your release):

```bash
sudo apt install gawk wget git diffstat unzip texinfo gcc build-essential chrpath socat cpio python3 \
                 python3-pip python3-pexpect xz-utils debianutils iputils-ping python3-git python3-jinja2 \
                 libegl1 libsdl1.2-dev pylint xterm python3-subunit mesa-common-dev zstd liblz4-tool file locales
git clone -b wrynose git://git.yoctoproject.org/poky      # branch name = release codename
cd poky
source oe-init-build-env                                   # creates build/ and enters it
# in conf/local.conf: MACHINE ?= "qemuarm64"  (or qemux86-64)
bitbake core-image-minimal                                 # hours the first time
runqemu qemuarm64 nographic
```

Workflow for products: your own **layer** (`meta-mycompany`) with: a machine/BSP, an image recipe, recipes for your app (`inherit cmake`), and `.bbappend` files for customizations; build in **CI** with sstate caching; version-pin layers with a manifest (`kas`, `repo`, or `bitbake-setup`); generate **SBOMs and license manifests**; update with **RAUC/SWUpdate/Mender** (section 9).

---

## 7. Developing applications for Linux (what changes)

### 7.1 Cross-compiling and native builds

- **Native**: build on a Raspberry Pi directly (`gcc`, `cmake`, `make`); fine for learning.
- **Cross**: use the toolchain from Buildroot (`output/host/bin/<triplet>-gcc`) or a Yocto SDK, with a **CMake toolchain file** (`CMAKE_SYSTEM_NAME Linux`, `CMAKE_SYSROOT`, `CMAKE_C_COMPILER`, `CMAKE_FIND_ROOT_PATH_MODE_*`): the same pattern as chapter 2, with `Linux` instead of `Generic`.
- Deploy with `scp` or `rsync`, debug with **`gdbserver`** on the target and `gdb-multiarch` on the host (`target remote ip:2345`), the same remote-debugging idea as OpenOCD.

### 7.2 Hardware access from userspace

| Interface | How |
|---|---|
| **GPIO** | **libgpiod** (character device `/dev/gpiochipN`, the modern API); tools `gpiodetect`, `gpioinfo`, `gpioset`, `gpioget`, `gpiomon`. The old sysfs interface (`/sys/class/gpio`) is deprecated |
| **I2C** | `/dev/i2c-N` with `ioctl`/`read`/`write` (or the `i2c-tools`: `i2cdetect -y 1`, `i2cget`, `i2cset`, `i2cdump`) or a kernel driver exposing the device through **IIO**/hwmon |
| **SPI** | `/dev/spidevB.C` (`spidev` driver, `ioctl SPI_IOC_MESSAGE`) |
| **UART** | `/dev/ttyS*`, `/dev/ttyAMA*`, `/dev/ttyACM*`; `termios` for configuration (like `stty`) |
| **ADC/DAC and sensors** | **IIO** subsystem: `/sys/bus/iio/devices/iio:deviceN/in_voltage0_raw` |
| **PWM** | `/sys/class/pwm` or kernel pwm-backed devices |
| **CAN** | **SocketCAN**: `can0` network interface, `candump`/`cansend`, sockets with `AF_CAN` |
| **USB** | libusb, `usbfs`; class drivers (CDC ACM, HID, MSC) in the kernel |
| **Memory-mapped registers** | `/dev/mem` + `mmap` (or `devmem`) for experiments; `uio` for userspace drivers with interrupts |
| **Watchdog** | `/dev/watchdog` (write periodically to keep the system alive) |
| **Networking** | Sockets (POSIX), the same API you used in chapter 11 |

Example: toggling a GPIO with libgpiod from C (v2 API names; check the version installed):

```c
#include <gpiod.h>
/* ... request line 17 of /dev/gpiochip0 as output, set value 1 ... */
```

and from the shell:

```bash
gpiodetect ; gpioinfo | head
gpioset gpiochip0 17=1
```

Read an I2C sensor register from userspace in C:

```c
#include <fcntl.h>
#include <linux/i2c-dev.h>
#include <sys/ioctl.h>
#include <unistd.h>
#include <stdint.h>

int fd = open("/dev/i2c-1", O_RDWR);
ioctl(fd, I2C_SLAVE, 0x48);                 /* 7-bit address */
uint8_t reg = 0x00, buf[2];
write(fd, &reg, 1);
read(fd, buf, 2);
int16_t raw = (int16_t)((buf[0] << 8) | buf[1]);
close(fd);
```

### 7.3 Real-time on Linux

- Normal Linux is **not hard real-time**: scheduling latencies are typically hundreds of microseconds but unbounded in the worst case.
- **PREEMPT_RT** (now part of the mainline kernel) makes most kernel code preemptible and gives bounded latencies on the order of tens to a few hundred microseconds on good hardware.
- Application techniques: `sched_setscheduler(SCHED_FIFO, prio)`, `mlockall(MCL_CURRENT | MCL_FUTURE)` (avoid page faults), pre-fault stack/heap, CPU isolation (`isolcpus`, `taskset`), avoid dynamic allocation in the loop, use `clock_nanosleep(TIMER_ABSTIME)`, and **measure with `cyclictest`** (`rt-tests` package).
- For deterministic sub-microsecond I/O, use a **microcontroller or PRU/M-core** next to Linux.

### 7.4 Kernel modules (a taste)

```c
/* hello.c */
#include <linux/module.h>
#include <linux/kernel.h>

static int __init hello_init(void) { pr_info("hello from the kernel\n"); return 0; }
static void __exit hello_exit(void) { pr_info("bye\n"); }
module_init(hello_init);
module_exit(hello_exit);
MODULE_LICENSE("GPL");
```

```make
obj-m += hello.o
all:
	make -C $(KDIR) M=$(PWD) modules          # KDIR = the kernel build tree (Buildroot: output/build/linux-*)
```

`insmod hello.ko`, `dmesg | tail`, `rmmod hello`. Real drivers bind to devicetree nodes (`platform_driver` with `of_match_table`), register character devices or subsystems (IIO, input, I2C client drivers), and handle interrupts and DMA with the kernel APIs. Prefer **existing drivers and userspace interfaces**; write kernel code only when needed.

---

## 8. Debugging and tools on the target

| Need | Tool |
|---|---|
| Kernel messages | `dmesg -w`, `journalctl -k`, `printk` levels, `console=ttyS0,115200` boot args |
| Processes | `ps`, `top`/`htop`, `pidstat`, `/proc/<pid>/...` |
| System calls | `strace -f -tt ./app` |
| Library calls | `ltrace` |
| Memory | `free`, `/proc/meminfo`, `valgrind` (native), AddressSanitizer in the app build |
| Crashes | Core dumps (`ulimit -c unlimited`, `coredumpctl`), `gdb`/`gdbserver` |
| Performance | `perf top/record/report`, `ftrace`, `trace-cmd`, `bpftrace`, `iostat`, `vmstat` |
| Latency | `cyclictest`, `hwlatdetect` |
| Network | `ip`, `ss`, `tcpdump`, `iperf3`, `ethtool` |
| Devices | `lsusb`, `lspci`, `lsmod`, `modinfo`, `udevadm`, `/sys` |
| Boot issues | Serial console + U-Boot prompt (interrupt autoboot), `printenv`, `bootargs`; **a UART connection to the SoC's debug console is essential** |
| Low-level | JTAG/SWD to Cortex-A (OpenOCD, vendor probes), kernel `kgdb` |
| Logging | `systemd-journald`, `logger`, persistent logs on a separate partition with rotation |

Debugging mindset: **serial console first**, then logs, then tools. Boot problems are usually bootloader environment, device tree, kernel command line (`root=`, `console=`), missing drivers (`CONFIG_` options), or a wrong rootfs.

---

## 9. Product concerns

| Concern | Practices |
|---|---|
| **Boot time** | Strip the bootloader, kernel config and init; `systemd-analyze blame`; consider BusyBox init; compressed vs uncompressed kernel; XIP and prelinking are special cases |
| **Robust storage** | **Read-only root filesystem** (squashfs/ext4 ro) with an **overlay** or a separate writable data partition; journaling filesystems; `fsync` discipline; wear leveling on raw flash (UBIFS) or use eMMC; handle power loss |
| **Updates (OTA)** | **A/B rootfs** with rollback using **RAUC**, **SWUpdate**, **Mender** or **OSTree**; U-Boot environment/bootcount for trial boots; signed bundles (chapter 16 principles) |
| **Security** | **Secure boot** chain (ROM → SPL/TF-A → U-Boot → kernel (FIT image signed) → rootfs integrity with `dm-verity`), disk encryption where needed, minimal services, no default passwords, SSH keys, SELinux/AppArmor, seccomp, user separation, firewall, regular CVE patching (Yocto's tooling), SBOM; close debug ports in production |
| **Licensing** | GPL/LGPL obligations (provide sources, allow relinking), license manifest generation (Yocto), avoid proprietary kernel modules |
| **Longevity** | Pick LTS kernels (6.12, 6.18 LTS...) and LTS Yocto/Buildroot releases; plan updates for the product's lifetime (CRA/regulatory expectations) |
| **Manufacturing** | Image flashing (`dd`, `uuu` for NXP, `STM32CubeProgrammer`, `bmaptool`), per-device provisioning (keys, serial numbers), test scripts |
| **Observability** | Metrics and crash reports, remote logs, watchdog and hardware watchdog (`/dev/watchdog`, systemd `WatchdogSec`) |
| **Power** | Suspend-to-RAM, CPU frequency scaling, runtime PM; Linux is not a µA platform |
| **Containers** | Docker/Podman/LXC on bigger devices for isolation and updates; adds footprint |

---

## 10. How your MCU knowledge carries over

| MCU concept (this series) | Linux equivalent |
|---|---|
| Startup code and linker script | Boot ROM, SPL, U-Boot, kernel `head.S`; ELF loader for apps |
| Vector table and NVIC | Interrupt controller (GIC) handled by the kernel; ISRs inside drivers; userspace sees `poll`/`epoll`/signals |
| Peripherals and registers (chapter 7) | Kernel drivers + `/dev`/`/sys` interfaces; same peripherals (I2C, SPI, UART, CAN) with same electrical behavior (chapter 10) |
| Devicetree (Zephyr) | Linux device tree |
| RTOS tasks and queues | Threads/processes, pipes, sockets, message queues (`mq_open`), `eventfd`, `epoll` |
| Priority inversion and priority inheritance | Real-time mutexes (`PTHREAD_PRIO_INHERIT`), PREEMPT_RT |
| Watchdog, fault handling | Hardware watchdog daemon, systemd restart policies, kernel panic handling (`panic=`) |
| Bootloader and OTA (chapter 16) | U-Boot + A/B rootfs, RAUC/SWUpdate/Mender |
| Testing on the host with fakes | Normal desktop development, containers, QEMU/emulated targets |
| `printf` logging | `syslog`/journald; `dmesg` for the kernel |
| Debugger (OpenOCD + gdb) | `gdbserver` over the network, JTAG for early boot |
| Static allocation, no heap | Heap and virtual memory are normal; be aware of leaks, fragmentation and OOM killer |
| `volatile`, barriers | Still relevant in drivers and `mmap`ed I/O; userspace uses atomics/mutexes |

Skills that become valuable: shell scripting, systemd, networking, cross-compilation, reading kernel code and documentation, Git workflows with upstream projects, Python for tooling.

---

## 11. Learning path and exercises

### 11.1 Suggested order

1. **QEMU + Buildroot** (section 5): boot your first custom image; add packages; add your own CMake application as a package.
2. **A real board** (Raspberry Pi, BeagleBone, STM32MP1 or i.MX board): flash a distro image, enable SSH, serial console, build natively, then cross-compile.
3. **Hardware from userspace**: GPIO (libgpiod), I2C sensor, SPI, UART, PWM and IIO ADC.
4. **Boot chain**: U-Boot console, environment, load kernel and DTB over TFTP/NFS, change the device tree and kernel command line.
5. **Kernel module and device tree**: a hello module, then a platform driver bound to a custom devicetree node.
6. **systemd**: write a service unit for your application, restart on failure, watchdog, logging to the journal.
7. **Real-time**: PREEMPT_RT kernel, `cyclictest` under load, an RT thread with `SCHED_FIFO`.
8. **Robust product concerns**: read-only rootfs, A/B update with RAUC/SWUpdate, secure boot concepts.
9. **Yocto**: build `core-image-minimal` for QEMU, create your own layer with an image and an app recipe (heavy: plan resources and time).
10. **Heterogeneous systems**: link an MCU (your Nucleo!) to a Linux SBC via UART/CAN/SPI using your protocol from chapter 11; log data on the Linux side and process it with Python (chapter 17).

### 11.2 Exercises

1. **Boot QEMU**: build `qemu_arm_vexpress_defconfig`, boot it, and find: kernel version, memory, the root filesystem type, the init process, and the console device.
2. **Add packages**: enable `dropbear`, `htop`, `i2c-tools`, `python3` in `menuconfig`; rebuild and use them in QEMU.
3. **Own app**: write a small C program and package it with a CMake-based Buildroot package; use `gdbserver` from the host.
4. **Rootfs overlay**: add a config file and a systemd/BusyBox init script via `BR2_ROOTFS_OVERLAY`.
5. **Device tree**: dump the QEMU board's DTB with `dtc -I dtb -O dts`, find the UART and interrupt controller nodes.
6. **U-Boot**: boot QEMU through U-Boot and change `bootargs` to see the effect.
7. **GPIO/I2C**: on a Raspberry Pi, blink an LED with libgpiod and read an I2C sensor with `i2cget` and then C; compare with your MCU code.
8. **Serial link to your MCU**: connect the Nucleo's UART to the SBC, run your COBS+CRC protocol client on Linux (Python), and display telemetry.
9. **Kernel module**: build, load and unload the hello module; add a parameter.
10. **systemd unit**: create a service that starts your app after the network, restarts on crash, and has `WatchdogSec`.
11. **Latency**: run `cyclictest` on a stock and a PREEMPT_RT kernel under `stress-ng` load; compare worst-case latency.
12. **Read-only rootfs**: configure an overlay or a tmpfs for `/var`, pull the power repeatedly, and verify the filesystem stays clean.
13. **Update**: set up an A/B update with RAUC or SWUpdate on QEMU or a board; test rollback.
14. **Yocto**: build and boot `core-image-minimal` for QEMU, add a recipe for your app, and examine the SBOM/license manifest.

---

## 12. Cheat sheet

```
Boot:        ROM → SPL/TF-A → U-Boot → kernel + DTB → init (systemd/BusyBox) → apps
Build tools: Buildroot (make menuconfig; make; output/images) | Yocto (bitbake core-image-minimal; layers, recipes)
Learn with:  QEMU + Buildroot (qemu_arm_vexpress_defconfig) | Raspberry Pi
Hardware:    GPIO: libgpiod (gpiodetect/gpioset) | I2C: /dev/i2c-N, i2cdetect | SPI: /dev/spidev | UART: termios
             CAN: SocketCAN | ADC: IIO (/sys/bus/iio) | registers: /dev/mem (experiments)
Debug:       serial console, dmesg, strace, perf, gdbserver, ftrace, cyclictest (PREEMPT_RT)
Product:     read-only rootfs + overlay, A/B OTA (RAUC/SWUpdate/Mender), secure boot + dm-verity, LTS versions, SBOM
Mindset:     Linux = processes + virtual memory + files + drivers in the kernel; MCU = you own the hardware
Remember:    choose an MCU for hard real-time/low power, Linux for networking/UI/storage; often use both
```

| Question | Answer |
|---|---|
| Can the Nucleo-F746ZG run Linux? | No (no MMU, small RAM). Use a Cortex-A board or QEMU |
| Buildroot or Yocto? | Buildroot to learn and for single-product images; Yocto for product families and long-term maintenance |
| Is Linux real-time? | Soft real-time; PREEMPT_RT bounds latency to tens-hundreds of µs; use an MCU for hard deadlines |
| How to update a Linux device safely? | A/B rootfs + signed bundles + rollback (RAUC, SWUpdate, Mender) |
| First debug tool? | The serial console |

---

## 13. Where this leads

- **Yocto and BSPs** for a specific SoC (STM32MP1/MP2 with OpenSTLinux, NXP i.MX, TI AM62): vendor documentation and layers.
- **Kernel development**: drivers, device tree bindings, upstreaming; *Linux Device Drivers*, the kernel documentation, and the `kernelnewbies` community.
- **Real-time and safety**: PREEMPT_RT, Xenomai, Jailhouse/Zephyr co-existing with Linux (hypervisors), OpenAMP/RPMsg for Linux + MCU systems; Linux in safety (ELISA project).
- **Security**: secure boot with FIT signatures, OP-TEE (trusted execution), dm-verity, SELinux, and CRA compliance work.
- **Containers and fleet management** for larger devices (balena, Mender, Azure IoT Edge, AWS Greengrass).
- **Back to the MCU** (chapters 0-21): the other half of most real products.

## References

- Yocto Project documentation and release information: <https://docs.yoctoproject.org>, <https://www.yoctoproject.org>
- Buildroot manual: <https://buildroot.org/downloads/manual/manual.html>
- Bootlin free training materials: *Embedded Linux system development*, *Linux kernel and driver development*, *Buildroot*, *Yocto* (<https://bootlin.com/training/>)
- *Mastering Embedded Linux Programming*, Chris Simmonds; *Embedded Linux Primer*, Christopher Hallinan; *Linux Device Drivers* (LDD3, with current kernel documentation)
- *Building Embedded Linux Systems*, Karim Yaghmour; *The Linux Programming Interface*, Michael Kerrisk
- Linux kernel documentation: <https://docs.kernel.org> (device tree bindings, GPIO/I2C/SPI/IIO subsystems)
- libgpiod documentation; `i2c-tools`; `rt-tests` and the PREEMPT_RT wiki
- U-Boot documentation: <https://docs.u-boot.org>; RAUC, SWUpdate, Mender documentation
