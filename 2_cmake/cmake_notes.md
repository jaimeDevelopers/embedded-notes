# 2. CMake for Embedded Development

Examples target the **STM32F746ZG** (NUCLEO-F746ZG, Cortex-M7) with `arm-none-eabi-gcc`, Ubuntu, CMake 4.x.

Prerequisites: chapter 0 (toolchain) and chapter 1 (make). Everything CMake does ends up as the compiler and linker commands you already know.

---

## 1. What CMake is

CMake is **not** a build system. It is a **build system generator**: it reads `CMakeLists.txt` and writes Makefiles (or Ninja files) for you. Then `make`/`ninja` does the real work.

```
CMakeLists.txt ──► cmake (configure + generate) ──► Makefile / build.ninja ──► make / ninja ──► blink.elf
```

Three phases:

1. **Configure**: runs your `CMakeLists.txt`, detects the compiler, fills the cache.
2. **Generate**: writes the native build files.
3. **Build**: runs the native tool (`cmake --build` calls it for you).

### What it fixes compared with Make

| Make weakness | CMake answer |
|---|---|
| Does not notice flag or compiler changes | Build files depend on the configuration, so affected objects rebuild |
| No concept of libraries or include propagation | Targets with `PUBLIC`/`PRIVATE`/`INTERFACE` |
| Debug/Release by hand | `CMAKE_BUILD_TYPE` and per-config flags |
| One toolchain per Makefile | Toolchain files |
| No IDE integration | `compile_commands.json`, presets, VS Code CMake Tools |
| Header dependencies by hand (`-MMD -MP`) | Automatic |

```bash
cmake --version        # this project used 4.2.3
sudo apt install cmake ninja-build
```

---

## 2. Commands you use every day

```bash
# Configure (once per build directory)
cmake -S . -B build -DCMAKE_BUILD_TYPE=Debug \
      -DCMAKE_TOOLCHAIN_FILE=cmake/toolchains/arm-toolchain.cmake

# Build
cmake --build build
cmake --build build -j$(nproc)            # parallel
cmake --build build --target flash        # a specific target
cmake --build build --verbose             # show the real compiler commands
cmake --build build --clean-first         # clean, then build
cmake --build build --target clean

# Start from scratch
rm -rf build
```

| Option | Meaning |
|---|---|
| `-S <dir>` | **S**ource directory (where the top `CMakeLists.txt` is) |
| `-B <dir>` | **B**uild directory (created if missing) |
| `-D VAR=value` | Set a cache variable (**configure time only**) |
| `-G Ninja` | Choose the generator |
| `-L` / `-LA` / `-LAH` | List cache variables (all, with help text) |
| `--preset <name>` | Use a preset from `CMakePresets.json` |
| `--trace-expand` | Trace every line CMake executes |
| `-U 'VAR*'` | Remove cache entries |
| `-E <command>` | Portable helpers: `cmake -E copy`, `make_directory`, `echo`, `sha256sum`... |

Important facts:

- `cmake --build` does **not** accept `-D`. Variables are set when configuring.
- The first `-DCMAKE_TOOLCHAIN_FILE` wins. Passing it again on an existing build directory gives `Manually-specified variables were not used by the project`. It is not an error, but it also changes nothing. To change toolchain, delete the build directory.
- Pick a generator on the first configure and do not change it later in the same directory. `Ninja` is faster than `Unix Makefiles`.

---

## 3. A minimal project

```
learn_cmake/
├── CMakeLists.txt
└── main.c
```

```cmake
cmake_minimum_required(VERSION 3.16...4.2)
project(hola C)
add_executable(hola main.c)
```

```bash
cmake -S . -B build
cmake --build build
./build/hola
```

| Line | Purpose |
|---|---|
| `cmake_minimum_required` | Minimum CMake version and policy level |
| `project(hola C)` | Project name and languages (`C`, `CXX`, `ASM`) |
| `add_executable(hola main.c)` | Create the **target** `hola` from `main.c` |

About the version line:

- CMake 4.0 removed compatibility with versions below 3.5. A file that says `cmake_minimum_required(VERSION 2.8)` fails with `Compatibility with CMake < 3.5 has been removed`.
- `VERSION 3.16...4.2` means: needs at least 3.16, behaves like 4.2 if available. It is portable and enables modern policies. Writing `VERSION 4.2` works but forbids anyone with an older CMake.

---

## 4. The CMake language

### Comments and commands

```cmake
# line comment
message(STATUS "Hello")           # commands: name(arg1 arg2 ...)
```

Arguments are separated by spaces/newlines. Commands are case-insensitive; variable names are case-sensitive. Comments are allowed between arguments.

### Variables

```cmake
set(NAME value)
set(LIST_VAR a b c)               # a list is just a ';'-separated string: "a;b;c"
message("${NAME}")
set(NAME)                         # unset
unset(NAME)
```

- Reference with `${NAME}`.
- Environment variables: `$ENV{HOME}`, set with `set(ENV{VAR} value)` (affects only the configure step).
- **Cache** variables persist in `CMakeCache.txt` and can be set with `-D`:

```cmake
set(BOARD "stm32f746" CACHE STRING "Target board")
option(ENABLE_CRC "Append CRC to image" ON)
```

- Normal variables are scoped: directory scope (`add_subdirectory`) and function scope. Use `set(VAR value PARENT_SCOPE)` to return a value from a function.

### Predefined variables you meet constantly

| Variable | Meaning |
|---|---|
| `CMAKE_SOURCE_DIR` | Top-level source directory |
| `CMAKE_CURRENT_SOURCE_DIR` | Directory of the `CMakeLists.txt` being processed (prefer this) |
| `CMAKE_BINARY_DIR` | Top-level build directory |
| `CMAKE_CURRENT_BINARY_DIR` | Build directory for the current subdirectory |
| `PROJECT_NAME` | Name from `project()` |
| `CMAKE_BUILD_TYPE` | Debug, Release, ... |
| `CMAKE_C_COMPILER` | Path to the C compiler |
| `CMAKE_SYSTEM_NAME` | `Linux`, or `Generic` for bare metal |
| `CMAKE_CURRENT_LIST_DIR` | Directory of the file being processed (useful in included `.cmake` files) |

### Control flow

```cmake
if(DEFINED BOARD AND BOARD STREQUAL "stm32f746")
  ...
elseif(NOT BOARD)
  message(FATAL_ERROR "Set -DBOARD=...")
else()
  ...
endif()

foreach(src IN ITEMS a.c b.c)
  message(STATUS "${src}")
endforeach()

foreach(req IN ITEMS BOARD_DEFINES BOARD_LINKER_SCRIPT)
  if(NOT DEFINED ${req})
    message(FATAL_ERROR "${req} is not defined")
  endif()
endforeach()
```

Careful with nested references: `${${V}}` expands the variable whose **name** is in `V`. Case matters (`${${v}}` with a lowercase `v` expands an undefined variable and prints nothing).

### Functions and macros

```cmake
function(add_firmware name)
  add_executable(${name} ${ARGN})
  set_target_properties(${name} PROPERTIES SUFFIX ".elf")
endfunction()
```

- `function` has its own scope. `macro` pastes text into the caller (no scope). Prefer functions.
- `ARGN` holds the extra arguments. For named arguments use `cmake_parse_arguments`.

### Messages

```cmake
message(STATUS "Board : ${BOARD}")         # normal info
message(WARNING "something odd")
message(FATAL_ERROR "stop configuring")    # also aborts
```

### Lists and strings (quick reference)

```cmake
list(APPEND SRCS a.c b.c)
list(LENGTH SRCS n)
list(FILTER SRCS EXCLUDE REGEX "test")
string(REPLACE ".c" ".o" OBJS "${SRCS}")
file(GLOB SRCS CONFIGURE_DEPENDS src/*.c)  # works, but an explicit list is safer for firmware
get_filename_component(NAME main.c NAME_WE)
```

---

## 5. Targets: the core idea

A **target** is a thing to build (executable, library) that carries its own properties: sources, include paths, definitions, compile options, link options, dependencies. You **attach properties to targets** instead of setting global flags.

```cmake
add_executable(blink)                      # create empty, add sources below
target_sources(blink PRIVATE main.c uart.c)
```

Library kinds:

| Kind | Result | Use |
|---|---|---|
| `STATIC` | `libx.a` | Normal library |
| `OBJECT` | Just object files, no archive | Bag of `.o` linked directly into the consumer |
| `INTERFACE` | Nothing is compiled | Carries flags, defines, includes to its consumers |
| `SHARED` | `.so` | Not for bare metal |

### The `target_*` commands

```cmake
target_sources(tgt PRIVATE ...)
target_include_directories(tgt [SYSTEM] PUBLIC dir ...)
target_compile_definitions(tgt PRIVATE NAME=value ...)
target_compile_options(tgt PRIVATE -Wall ...)
target_link_options(tgt PRIVATE -Wl,--gc-sections ...)
target_link_libraries(tgt PRIVATE other_target)
set_target_properties(tgt PROPERTIES PROP value)
```

### PUBLIC / PRIVATE / INTERFACE

| Keyword | Used to build the target itself | Passed to targets that link it |
|---|---|---|
| `PRIVATE` | yes | no |
| `INTERFACE` | no | yes |
| `PUBLIC` | yes | yes |

Rule of thumb: if the property appears in the target's **public header**, make it `PUBLIC`. If only its `.c` files need it, `PRIVATE`. If it is only for consumers (header-only, flag bundles), `INTERFACE`.

Example from chapter 1's `mylib`:

```cmake
add_library(mylib mylib.c)
target_include_directories(mylib PUBLIC ${CMAKE_CURRENT_SOURCE_DIR})
add_executable(hola main.c)
target_link_libraries(hola PRIVATE mylib)    # hola inherits mylib's PUBLIC include dir
```

`-I/ruta` is what `target_include_directories` really emits. `SYSTEM` makes GCC treat the directory as system headers (`-isystem`), hiding warnings from vendor code.

### Target name vs file name

The target name is a logical name. The file is `blink.elf`, `libmylib.a`, etc. Inside shell commands use a generator expression to get the file (next section).

---

## 6. Generator expressions

Written `$<...>`. They are evaluated at **generate** time, not configure time, so they can know target file names and the active configuration.

```cmake
$<TARGET_FILE:blink>           # /path/build/blink.elf
$<TARGET_FILE_NAME:blink>      # blink.elf
$<TARGET_FILE_DIR:blink>       # /path/build
$<CONFIG:Debug>                # 1 if the config is Debug, else 0
$<$<CONFIG:Debug>:-Og -g3>     # "-Og -g3" only in Debug, empty otherwise
$<$<COMPILE_LANGUAGE:C>:-std=gnu11>   # only for C files (not ASM)
$<BUILD_INTERFACE:...>         # only while building, not when installed
```

### `${VAR}` vs `$<...>`

| | `${TARGET}` | `$<TARGET_FILE:${TARGET}>` |
|---|---|---|
| Evaluated | configure time | generate time |
| Value | the text (`blink`) | the full path of the produced file |
| Use | where CMake wants a target name | in external commands where you need the file |

Using `$<TARGET_FILE:...>` inside `COMMAND` also creates an implicit dependency on that target.

---

## 7. Build types and flags

### Single-config vs multi-config

- **Single-config** generators (`Unix Makefiles`, `Ninja`): one configuration per build directory, chosen by `CMAKE_BUILD_TYPE` at configure time.
- **Multi-config** (`Ninja Multi-Config`, Visual Studio, Xcode): choose at build time with `--config`.

### What each type adds by default (GCC)

| `CMAKE_BUILD_TYPE` | Flags |
|---|---|
| *(empty)* | nothing, so `-O0` and **no `-g`** |
| `Debug` | `-g` |
| `Release` | `-O3 -DNDEBUG` |
| `RelWithDebInfo` | `-O2 -g -DNDEBUG` |
| `MinSizeRel` | `-Os -DNDEBUG` |

That empty row bit you: with no build type, gdb showed `main ()` without file or line. Two safe habits:

```cmake
# Default to Debug when nobody chose a type
if(NOT CMAKE_BUILD_TYPE)
  set(CMAKE_BUILD_TYPE Debug CACHE STRING "Build type" FORCE)
endif()
```

and, in the toolchain file, define embedded-friendly flags per type:

```cmake
set(CMAKE_C_FLAGS_DEBUG_INIT     "-Og -g3")
set(CMAKE_C_FLAGS_RELEASE_INIT   "-Os -DNDEBUG")
set(CMAKE_ASM_FLAGS_DEBUG_INIT   "-g3")
```

The `_INIT` variables provide initial values and are the right place in a toolchain file. Alternative per target:

```cmake
target_compile_options(blink PRIVATE
  $<$<CONFIG:Debug>:-Og;-g3>
  $<$<CONFIG:Release>:-Os>)
```

Inside a generator expression, separate several flags with `;` (not spaces): an unquoted `$<...:-Og -g3>` is split by CMake at the space and breaks the expression. Alternatively quote the whole expression.

### Where flags go

| Variable / command | Applies to | Notes |
|---|---|---|
| `CMAKE_C_FLAGS` | all C compiles | Global, avoid growing it |
| `CMAKE_C_FLAGS_<CONFIG>` | only that config | |
| `target_compile_options` | one target (compile step) | Preferred. Also reaches ASM unless restricted |
| `target_link_options` | one target (link step) | **Linker flags go here** |
| `CMAKE_EXE_LINKER_FLAGS` | all executables | Global |

Mistake seen in this project: `-Og -g3` placed in `target_link_options`. It does nothing there, because optimization and debug info are **compile** flags. After moving it to compile options, the md5 and size of the binary changed and gdb showed source lines.

### Language standard

```cmake
set(CMAKE_C_STANDARD 11)              # emits -std=gnu11 (GNU extensions on)
set(CMAKE_C_STANDARD_REQUIRED ON)
set(CMAKE_C_EXTENSIONS OFF)           # emits -std=c11 (strict)
```

---

## 8. Toolchain files and cross-compiling

A toolchain file tells CMake which compiler to use **before** it starts probing. It is read on the first configure of a build directory.

```cmake
# cmake/toolchains/arm-toolchain.cmake

# "Generic" = no operating system; also switches CMake into cross-compiling mode
set(CMAKE_SYSTEM_NAME      Generic)
set(CMAKE_SYSTEM_PROCESSOR arm)

set(CMAKE_C_COMPILER   arm-none-eabi-gcc)
set(CMAKE_ASM_COMPILER arm-none-eabi-gcc)
set(CMAKE_OBJCOPY      arm-none-eabi-objcopy)
set(CMAKE_OBJDUMP      arm-none-eabi-objdump)
set(CMAKE_SIZE         arm-none-eabi-size)

# CMake's compiler checks must not link an executable (no linker script/startup yet)
set(CMAKE_TRY_COMPILE_TARGET_TYPE STATIC_LIBRARY)

set(CMAKE_C_FLAGS_DEBUG_INIT   "-Og -g3")
set(CMAKE_C_FLAGS_RELEASE_INIT "-Os -DNDEBUG")
set(CMAKE_ASM_FLAGS_DEBUG_INIT "-g3")
```

Use it:

```bash
cmake -S . -B build -DCMAKE_TOOLCHAIN_FILE=cmake/toolchains/arm-toolchain.cmake
```

Alternative style with `find_program` (fails clearly if the toolchain is missing):

```cmake
find_program(CMAKE_C_COMPILER NAMES arm-none-eabi-gcc REQUIRED)
find_program(CMAKE_OBJCOPY    NAMES arm-none-eabi-objcopy REQUIRED)
```

Other cross-compiling variables:

| Variable | Use |
|---|---|
| `CMAKE_FIND_ROOT_PATH` and the `CMAKE_FIND_ROOT_PATH_MODE_*` | Restrict `find_*` to the target sysroot |
| `CMAKE_CROSSCOMPILING` | Set to true automatically |
| `CMAKE_EXECUTABLE_SUFFIX` | Set to `.elf` so the output is `blink.elf` |

Debugging a toolchain file problem: delete the build directory. A stale cache keeps the old compiler.

---

## 9. Custom commands and targets

### `POST_BUILD`: run after a target is built

```cmake
add_custom_command(TARGET blink POST_BUILD
  COMMAND ${CMAKE_SIZE} $<TARGET_FILE:blink>
  COMMAND ${CMAKE_OBJCOPY} -O binary $<TARGET_FILE:blink> ${CMAKE_BINARY_DIR}/blink.bin
  COMMENT "Generating blink.bin")
```

Other keywords: `PRE_BUILD`, `PRE_LINK`.

### Producing a file from other files

```cmake
add_custom_command(
  OUTPUT  ${CMAKE_BINARY_DIR}/blink_crc.bin
  COMMAND python3 ${CMAKE_SOURCE_DIR}/tools/add_crc.py blink.bin blink_crc.bin
  DEPENDS blink ${CMAKE_SOURCE_DIR}/tools/add_crc.py
  WORKING_DIRECTORY ${CMAKE_BINARY_DIR})
add_custom_target(firmware_crc ALL DEPENDS ${CMAKE_BINARY_DIR}/blink_crc.bin)
```

### Custom targets: `flash`

```cmake
add_custom_target(flash
  COMMAND st-flash --reset write ${CMAKE_BINARY_DIR}/blink.bin 0x08000000
  DEPENDS blink
  USES_TERMINAL)                  # direct access to the terminal (progress output)
# add_dependencies(flash blink)   # explicit alternative to DEPENDS for target names
```

OpenOCD version:

```cmake
set(OPENOCD_CFG -f interface/stlink.cfg -f target/stm32f7x.cfg)

add_custom_target(flash-ocd
  COMMAND openocd ${OPENOCD_CFG}
          -c "program $<TARGET_FILE:blink> verify reset exit"
  DEPENDS blink
  USES_TERMINAL)

add_custom_target(openocd COMMAND openocd ${OPENOCD_CFG} USES_TERMINAL)
```

Usage: `cmake --build build --target flash`.

Notes:

- A custom target is not part of `all` unless you add the `ALL` keyword. `flash` should not be.
- `st-flash --reset write` is needed so the program starts without pressing the reset button.
- If flashing fails with `LIBUSB_ERROR_TIMEOUT` at `GET_VERSION`, replug the ST-LINK USB. It is the probe, not CMake.

---

## 10. Project organization

### Splitting into directories

```
project/
├── CMakeLists.txt
├── cmake/
│   ├── toolchains/arm-toolchain.cmake
│   └── modules/ToolchainProbe.cmake
├── boards/
│   └── stm32f746/
│       ├── board.cmake
│       ├── STM32F746ZGTx_FLASH.ld
│       └── vendor/{startup_stm32f746xx.s, system_stm32f7xx.c}
├── extern/{cmsis_core, cmsis_device_f7}
└── src/
    ├── main.c
    └── drivers/{led.c, uart.c, ...}
```

```cmake
add_subdirectory(src/drivers)             # runs src/drivers/CMakeLists.txt
include(cmake/modules/ToolchainProbe.cmake)   # runs a file in the current scope
include(boards/${BOARD}/board.cmake)
```

`target_sources` in a subdirectory (CMake ≥ 3.13 resolves relative paths against that subdirectory):

```cmake
# src/drivers/CMakeLists.txt
target_sources(blink PRIVATE led.c button.c adc.c uart.c systick.c)
```

### Board overlays (pattern used in this project)

Top-level file selects a board and includes its overlay, which sets variables:

```cmake
if(NOT DEFINED BOARD)
  message(FATAL_ERROR "Set -DBOARD=stm32f746")
endif()
include(boards/${BOARD}/board.cmake)

# Make sure the overlay provided everything we need
foreach(req IN ITEMS BOARD_DEFINES BOARD_ARCH_FLAGS BOARD_LINKER_SCRIPT
                     BOARD_STARTUP_ASM BOARD_SYSTEM_C)
  if(NOT DEFINED ${req})
    message(FATAL_ERROR "Overlay for ${BOARD} did not define ${req}")
  endif()
endforeach()
```

### Guard rails

```cmake
# Refuse in-source builds
if(CMAKE_SOURCE_DIR STREQUAL CMAKE_BINARY_DIR)
  message(FATAL_ERROR "In-source builds are disallowed")
endif()
```

### Output location

```cmake
set_target_properties(blink PROPERTIES
  RUNTIME_OUTPUT_DIRECTORY "${CMAKE_BINARY_DIR}/artifacts"
  OUTPUT_NAME "blink")
```

If you move the ELF, update `executable` in VS Code's `launch.json`.

---

## 11. A layered embedded project (recommended structure)

Use an INTERFACE library to carry the MCU flags once, a HAL as a normal library, and the application on top.

```cmake
cmake_minimum_required(VERSION 3.16...4.2)
project(blink C ASM)

if(NOT CMAKE_BUILD_TYPE)
  set(CMAKE_BUILD_TYPE Debug CACHE STRING "Build type" FORCE)
endif()

set(CMAKE_C_STANDARD 11)
set(CMAKE_EXECUTABLE_SUFFIX ".elf")

set(BOARD_DIR "${CMAKE_CURRENT_SOURCE_DIR}/boards/stm32f746")
set(LINKER_SCRIPT "${BOARD_DIR}/STM32F746ZGTx_FLASH.ld")
set(ARCH_FLAGS -mcpu=cortex-m7 -mthumb -mfpu=fpv5-sp-d16 -mfloat-abi=hard)

# ---- 1. mcu: carries flags, defines and CMSIS headers to everyone who links it
add_library(mcu INTERFACE)
target_compile_options(mcu INTERFACE ${ARCH_FLAGS} -ffunction-sections -fdata-sections)
target_link_options(mcu INTERFACE ${ARCH_FLAGS})
target_compile_definitions(mcu INTERFACE STM32F746xx CORE_CM7 CPU_HZ=16000000UL)
target_include_directories(mcu SYSTEM INTERFACE
  extern/cmsis_core/Include
  extern/cmsis_device_f7/Include)

# ---- 2. drivers: a normal static library
add_library(drivers STATIC
  src/drivers/led.c src/drivers/button.c src/drivers/adc.c
  src/drivers/uart.c src/drivers/systick.c)
target_include_directories(drivers PUBLIC src/drivers)
target_link_libraries(drivers PUBLIC mcu)

# ---- 3. the firmware
add_executable(blink
  src/main.c
  ${BOARD_DIR}/vendor/system_stm32f7xx.c
  ${BOARD_DIR}/vendor/startup_stm32f746xx.s)     # startup stays here, see warning below
target_link_libraries(blink PRIVATE drivers mcu)

target_compile_options(blink PRIVATE -Wall -Wextra -Wno-unused-parameter)

target_link_options(blink PRIVATE
  -T${LINKER_SCRIPT}
  --specs=nano.specs --specs=nosys.specs
  -Wl,-u,_printf_float
  -Wl,--gc-sections
  -Wl,-Map=${CMAKE_BINARY_DIR}/blink.map
  -Wl,--print-memory-usage)

set_target_properties(blink PROPERTIES LINK_DEPENDS ${LINKER_SCRIPT})

add_custom_command(TARGET blink POST_BUILD
  COMMAND ${CMAKE_SIZE} $<TARGET_FILE:blink>
  COMMAND ${CMAKE_OBJCOPY} -O binary $<TARGET_FILE:blink> ${CMAKE_BINARY_DIR}/blink.bin)

add_custom_target(flash
  COMMAND st-flash --reset write ${CMAKE_BINARY_DIR}/blink.bin 0x08000000
  DEPENDS blink USES_TERMINAL)
```

### Embedded gotchas with libraries

- **Never put the startup file or the vector table inside a static library.** The linker only pulls archive members that resolve an undefined symbol. Nothing references the vector table, so it would be dropped and the chip would not boot. Keep startup in the executable's own sources (or an `OBJECT` library).
- **Weak symbol overriding**: your `SysTick_Handler` in a static library will not override the startup's weak alias if the archive member is never pulled in. Same cause. Put interrupt handlers in the executable or reference them.
- **Link order**: `target_link_libraries` order is preserved for static archives. If libraries depend on each other, declare the dependencies between them (`target_link_libraries(drivers PUBLIC mcu)`) and CMake orders them.
- **Flags must match**: because `mcu` is linked by both `drivers` and `blink`, the same `-mcpu/-mfpu/-mfloat-abi` flags reach every compile and the link. This is exactly what failed before when they differed.
- `-ffreestanding` and `-fno-builtin` are **not** appropriate when you use newlib: they stop the compiler from optimizing `printf` and `memcpy` calls and are only meant for code without a C library.

### LINK_DEPENDS

Without `LINK_DEPENDS`, editing only the `.ld` file does not trigger a relink. With it, it does.

### HAL as a library (optional)

```cmake
set(HAL_DIR extern/stm32f7xx_hal_driver)
add_library(stm32_hal STATIC
  ${HAL_DIR}/Src/stm32f7xx_hal.c
  ${HAL_DIR}/Src/stm32f7xx_hal_rcc.c
  ${HAL_DIR}/Src/stm32f7xx_hal_gpio.c
  ${HAL_DIR}/Src/stm32f7xx_hal_uart.c)
target_compile_definitions(stm32_hal PUBLIC USE_HAL_DRIVER)
target_include_directories(stm32_hal PUBLIC config ${HAL_DIR}/Inc)
target_link_libraries(stm32_hal PUBLIC mcu)
target_compile_options(stm32_hal PRIVATE -w)     # silence third-party warnings
```

---

## 12. Presets (optional, for repeatable configuration)

`CMakePresets.json` stores configure/build options so you do not retype `-D` flags:

```json
{
  "version": 6,
  "cmakeMinimumRequired": { "major": 3, "minor": 25, "patch": 0 },
  "configurePresets": [
    {
      "name": "f746-debug",
      "generator": "Ninja",
      "binaryDir": "${sourceDir}/build/f746-debug",
      "toolchainFile": "${sourceDir}/cmake/toolchains/arm-toolchain.cmake",
      "cacheVariables": { "CMAKE_BUILD_TYPE": "Debug" },
      "environment": { "SOURCE_DATE_EPOCH": "1700000000" }
    },
    {
      "name": "f746-release",
      "inherits": "f746-debug",
      "binaryDir": "${sourceDir}/build/f746-release",
      "cacheVariables": { "CMAKE_BUILD_TYPE": "Release" }
    }
  ],
  "buildPresets": [
    { "name": "f746-debug",   "configurePreset": "f746-debug" },
    { "name": "f746-release", "configurePreset": "f746-release" }
  ]
}
```

```bash
cmake --list-presets
cmake --preset f746-debug
cmake --build --preset f746-debug
cmake --build --preset f746-debug --target flash
```

| Preset schema version | Requires CMake |
|---|---|
| 2 | 3.20 |
| 3 | 3.21 (adds `toolchainFile`) |
| 4 | 3.23 |
| 5 | 3.24 |
| 6 | 3.25 |

Notes:

- Environment values belong in `"environment"`, not in `cacheVariables`: tools such as GCC read **environment** variables (like `SOURCE_DATE_EPOCH`), not the CMake cache.
- Presets are optional. You can do everything with plain `-D` flags, as in section 2, if you prefer fewer files.

---

## 13. Reproducible and clean builds

```cmake
# remove absolute paths from debug info and __FILE__
target_compile_options(blink PRIVATE -ffile-prefix-map=${CMAKE_CURRENT_SOURCE_DIR}=.)
```

- Export `SOURCE_DATE_EPOCH=1700000000` in the environment of the build, so `__DATE__` and `__TIME__` are constant.
- Check by building twice from scratch and comparing `sha256sum build/blink.bin`.
- Prefer an explicit list of sources over `file(GLOB)`. If you do use GLOB, add `CONFIGURE_DEPENDS` so new files trigger a reconfigure.
- A `-ffile-prefix-map` with a relative result can make the debugger fail to find sources. Add `sourceFileMap` in `launch.json` or disable it while debugging.

---

## 14. Debugging CMake itself

```bash
cmake --build build --verbose                 # real compiler/linker commands
cmake -LAH build | less                       # every cache variable with help text
grep CMAKE_BUILD_TYPE build/CMakeCache.txt    # what the cache really holds
cmake -S . -B build --trace-expand 2>&1 | less  # every line executed
cmake -S . -B build --log-level=VERBOSE
```

Handy snippets:

```cmake
message(STATUS "C flags       : ${CMAKE_C_FLAGS}")
message(STATUS "C flags Debug : ${CMAKE_C_FLAGS_DEBUG}")
message(STATUS "Compiler      : ${CMAKE_C_COMPILER}")

get_target_property(OPTS blink COMPILE_OPTIONS)
message(STATUS "blink options : ${OPTS}")
```

Generate the compilation database for IDEs (autocomplete, clangd):

```cmake
set(CMAKE_EXPORT_COMPILE_COMMANDS ON)
```

This writes `build/compile_commands.json` (Makefile and Ninja generators only).

Where to look when a build behaves oddly:

| File | Content |
|---|---|
| `build/CMakeCache.txt` | Cache: toolchain, build type, your `-D` values |
| `build/CMakeFiles/blink.dir/flags.make` | Exact compile flags and defines (Makefile generator) |
| `build/CMakeFiles/blink.dir/link.txt` | Exact link command (Makefile generator) |
| `build/CMakeFiles/CMakeConfigureLog.yaml` | Compiler detection results |

---

## 15. VS Code integration

`.vscode/tasks.json` (the file must be named `tasks.json`, with an **s**, inside `.vscode/`):

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
    },
    {
      "label": "flash",
      "type": "shell",
      "command": "cmake --build build --target flash",
      "dependsOn": "build",
      "problemMatcher": []
    }
  ]
}
```

`.vscode/launch.json` with the Cortex-Debug extension:

```json
{
  "version": "0.2.0",
  "configurations": [
    {
      "name": "STM32F746 (OpenOCD)",
      "type": "cortex-debug",
      "request": "launch",
      "servertype": "openocd",
      "cwd": "${workspaceFolder}",
      "executable": "${workspaceFolder}/build/blink.elf",
      "configFiles": ["interface/stlink.cfg", "target/stm32f7x.cfg"],
      "gdbPath": "gdb-multiarch",
      "objdumpPath": "/usr/bin/arm-none-eabi-objdump",
      "runToEntryPoint": "main",
      "preLaunchTask": "build"
    }
  ]
}
```

Points to remember:

- `preLaunchTask` must match a task `label`. If VS Code says `Could not find the task build`, check the filename (`tasks.json`) and the label.
- The `executable` path must match where the ELF is really produced (`find build -name "*.elf"`).
- The build must have `-g` (Debug) or breakpoints will not resolve.
- Cortex-Debug with `gdb-multiarch` looks for `nm-multiarch`/`objdump-multiarch`, which do not exist. Set `objdumpPath` to `arm-none-eabi-objdump` to silence the errors.
- Close terminals (picocom) and other OpenOCD instances before flashing or debugging.

---

## 16. Errors and how to read them

| Message | Cause and fix |
|---|---|
| `Compatibility with CMake < 3.5 has been removed` | Old `cmake_minimum_required`. Set `VERSION 3.16...4.2` |
| `Manually-specified variables were not used: CMAKE_TOOLCHAIN_FILE` | Toolchain given on an existing build dir. Harmless; to change toolchain, delete `build/` |
| `gdb shows main () with no file/line` | No `-g`. Set `CMAKE_BUILD_TYPE=Debug` and reconfigure |
| `-Og -g3` has no effect | It was in `target_link_options`. Move to compile options |
| `The C compiler ... is not able to compile a simple test program` | Cross toolchain: add `CMAKE_TRY_COMPILE_TARGET_TYPE STATIC_LIBRARY` |
| `undefined reference to ...` at link | Missing source/library or wrong link order |
| Changing the `.ld` does not relink | Add `LINK_DEPENDS` |
| Chip does not boot after moving code to a library | Vector table dropped from the static library. Keep startup in the executable |
| `cmake --build build -DCMAKE_BUILD_TYPE=Debug` ignored | `-D` only works when configuring |
| `Could not find the task build` in VS Code | Wrong filename or label in `tasks.json` |
| `CMake Error: ... does not appear to contain CMakeLists.txt` | Wrong `-S` path |
| `CMakeCache.txt directory is different` | Build dir moved. Delete and reconfigure |
| `LIBUSB_ERROR_TIMEOUT` in `flash` | ST-LINK stuck; replug the board. Not a CMake issue |
| `ninja: error: loading 'build.ninja'` | Configure never ran or failed |
| Cached stale value | `rm -rf build` or `cmake -U VAR` |

---

## 17. From chapter 1: the Make example, in CMake

| Make | CMake |
|---|---|
| `SRCS := ...` | `add_executable(blink main.c ...)` or `target_sources` |
| `CFLAGS += -I...` | `target_include_directories` |
| `CFLAGS += -D...` | `target_compile_definitions` |
| `CFLAGS += -Wall` | `target_compile_options` |
| `LDFLAGS += -T...ld` | `target_link_options` |
| `-MMD -MP`, `-include $(DEPS)` | Automatic |
| `ifeq ($(BUILD),release)` | `CMAKE_BUILD_TYPE` and `$<CONFIG:...>` |
| `.PHONY: flash` | `add_custom_target(flash ...)` |
| Linker script as prerequisite | `set_target_properties(... LINK_DEPENDS ...)` |
| Flag-change detection (manual trick) | Built in |
| `make V=1` | `cmake --build build --verbose` |

---

## 18. Lab exercises

1. **Hello CMake**: configure, build, run the PC example. Open `build/` and read the generated Makefile.
2. **See the commands**: `cmake --build build --verbose`. Identify `-I`, `-D`, `-std=gnu11`.
3. **Library**: split code into `mylib` (`STATIC`). Change `PUBLIC` to `PRIVATE` on its include directory and read the compile error in the executable.
4. **Build types**: configure Debug and Release in two directories. Compare the flags (`flags.make`) and `size`.
5. **No build type**: configure without `CMAKE_BUILD_TYPE`, check `readelf -S ... | grep debug_line`, then fix it.
6. **Toolchain**: build for the STM32 with the toolchain file. Delete `build/`, remove `CMAKE_TRY_COMPILE_TARGET_TYPE` and read the failure.
7. **INTERFACE library**: move the CPU flags into `mcu`. Break one flag on purpose in the link options and read the linker message.
8. **Generator expressions**: print `$<TARGET_FILE:blink>` with `file(GENERATE ...)` or in a custom command.
9. **Custom target**: `flash` with `st-flash`, then `flash-ocd` with OpenOCD.
10. **POST_BUILD**: generate `.bin`, `.hex` and `.lst` (`objdump -d`) after linking.
11. **LINK_DEPENDS**: edit only the `.ld` with and without the property and watch if it relinks.
12. **Startup in a library**: move the startup into a `STATIC` library and see the board stop booting (check with `nm` that the vector table symbol disappeared). Fix it with an `OBJECT` library or by returning it to the executable.
13. **Board overlays**: create two boards (`stm32f746`, `stm32f411`) selected with `-DBOARD=...`.
14. **Presets**: write `CMakePresets.json` with Debug and Release.
15. **Reproducibility**: build twice and compare hashes, adding `-ffile-prefix-map`.
16. **CRC step**: add the Python CRC script as a `POST_BUILD` command and generate `blink_crc.bin`.

---

## 19. Cheat sheet

```bash
# Configure
cmake -S . -B build -DCMAKE_BUILD_TYPE=Debug -DCMAKE_TOOLCHAIN_FILE=cmake/toolchains/arm-toolchain.cmake
# Build / flash / clean
cmake --build build -j$(nproc)
cmake --build build --target flash
cmake --build build --clean-first
# Inspect
cmake --build build --verbose
cmake -LAH build | less
find build -name "*.elf"
```

| Goal | How |
|---|---|
| Add flags to one target | `target_compile_options(tgt PRIVATE ...)` |
| Add linker flags | `target_link_options(tgt PRIVATE ...)` |
| Add include path | `target_include_directories(tgt PRIVATE dir)` |
| Pass a define | `target_compile_definitions(tgt PRIVATE NAME=1)` |
| Share flags between targets | `INTERFACE` library + `target_link_libraries` |
| Debug vs release flags | `CMAKE_BUILD_TYPE` or `$<$<CONFIG:Debug>:...>` |
| Run a command after link | `add_custom_command(TARGET ... POST_BUILD ...)` |
| Add a `flash` target | `add_custom_target(flash COMMAND ... DEPENDS tgt)` |
| Get the path of the output file | `$<TARGET_FILE:tgt>` |
| Rebuild when the `.ld` changes | `set_target_properties(tgt PROPERTIES LINK_DEPENDS file)` |
| Hide vendor header warnings | `target_include_directories(... SYSTEM ...)` |
| Fail with a clear message | `message(FATAL_ERROR "...")` |
| Check which compiler/flags are used | `cmake --build build --verbose` |
| Start clean | `rm -rf build` |

### Habits that save time

- Attach everything to **targets**, not to global variables.
- Use `CMAKE_CURRENT_SOURCE_DIR` instead of `CMAKE_SOURCE_DIR` inside reusable pieces.
- Compile flags go in `target_compile_options`, link flags in `target_link_options`.
- Default `CMAKE_BUILD_TYPE` to Debug so `-g` is never missing.
- Keep an explicit source list in firmware projects.
- Reconfigure from scratch when you change the toolchain.

---

## 20. Where this leads

- **Cortex-M architecture** explains why the vector table, stacks and faults behave as they do.
- **Debugging** builds on the VS Code setup in section 15.
- Later chapters (C, C++, architecture patterns) will add `drivers/`, `hal/`, `app/` libraries to the layered structure of section 11.

## References

- Official docs: <https://cmake.org/cmake/help/latest/>
- *CMake Tutorial* in the official documentation
- `cmake --help-command target_link_libraries` (and any other command) from the terminal
- *Professional CMake: A Practical Guide*, Craig Scott
- Modern CMake practices: <https://cliutils.gitlab.io/modern-cmake/>