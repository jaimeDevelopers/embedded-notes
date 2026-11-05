# 19. Advanced CMake, Linker Scripts, and Binary Tools

Builds on chapter 0 (toolchain, linker script basics), chapter 1 (make), chapter 2 (CMake basics), chapter 8 (build graph as architecture). This chapter covers the techniques used in real firmware build systems.

**Verification note.** CMake and binutils evolve; options below exist in recent versions (CMake 3.20-4.x, binutils 2.38+) but check `cmake --help-command <name>` and `man ld`. Examples are illustrative and **not run on your board**.

---

## 1. CMake: a firmware helper function

Hide the repetitive parts (suffix, map file, size, bin/hex, flash target) behind one function in `cmake/modules/Firmware.cmake`:

```cmake
# cmake/modules/Firmware.cmake
include_guard(GLOBAL)

# add_firmware(<name> SOURCES ... LINKER_SCRIPT <ld> [LIBRARIES ...])
function(add_firmware name)
  cmake_parse_arguments(FW "" "LINKER_SCRIPT" "SOURCES;LIBRARIES;DEFINITIONS" ${ARGN})

  add_executable(${name} ${FW_SOURCES})
  set_target_properties(${name} PROPERTIES SUFFIX ".elf" LINK_DEPENDS "${FW_LINKER_SCRIPT}")
  target_compile_definitions(${name} PRIVATE ${FW_DEFINITIONS})
  target_link_libraries(${name} PRIVATE ${FW_LIBRARIES})
  target_link_options(${name} PRIVATE
    "-T${FW_LINKER_SCRIPT}"
    "-Wl,-Map=$<TARGET_FILE_DIR:${name}>/${name}.map"
    -Wl,--cref -Wl,--gc-sections -Wl,--print-memory-usage)

  add_custom_command(TARGET ${name} POST_BUILD
    COMMAND ${CMAKE_SIZE} $<TARGET_FILE:${name}>
    COMMAND ${CMAKE_OBJCOPY} -O binary $<TARGET_FILE:${name}> $<TARGET_FILE_DIR:${name}>/${name}.bin
    COMMAND ${CMAKE_OBJCOPY} -O ihex   $<TARGET_FILE:${name}> $<TARGET_FILE_DIR:${name}>/${name}.hex
    BYPRODUCTS $<TARGET_FILE_DIR:${name}>/${name}.bin $<TARGET_FILE_DIR:${name}>/${name}.hex
    COMMENT "Creating ${name}.bin and ${name}.hex")

  add_custom_target(${name}-flash
    COMMAND st-flash --reset write $<TARGET_FILE_DIR:${name}>/${name}.bin 0x08000000
    DEPENDS ${name} USES_TERMINAL)
endfunction()
```

Use:

```cmake
list(APPEND CMAKE_MODULE_PATH ${CMAKE_CURRENT_SOURCE_DIR}/cmake/modules)
include(Firmware)
add_firmware(blink SOURCES src/main.c ${BOARD_STARTUP_ASM} ${BOARD_SYSTEM_C}
             LINKER_SCRIPT ${BOARD_LINKER_SCRIPT} LIBRARIES app hal_stm32f7)
```

Benefits: several firmware targets (bootloader, app, tests) share the same logic; one place to change flags.

---

## 2. Generator expressions in depth

Recall: evaluated at generate time, written `$<...>`, **no spaces unless quoted**; lists use `;`.

| Expression | Meaning |
|---|---|
| `$<CONFIG:Debug>` | 1 if the build type is Debug |
| `$<$<CONFIG:Debug>:-Og;-g3>` | A list only for Debug |
| `$<IF:cond,then,else>` | Conditional value |
| `$<BOOL:string>` | Convert to 0/1 |
| `$<AND:a,b>`, `$<OR:a,b>`, `$<NOT:a>` | Logic |
| `$<COMPILE_LANGUAGE:C>`, `$<COMPILE_LANG_AND_ID:CXX,GNU>` | Per-language options |
| `$<TARGET_FILE:t>`, `$<TARGET_FILE_DIR:t>`, `$<TARGET_FILE_NAME:t>` | Output file info |
| `$<TARGET_PROPERTY:t,PROP>` | A target property value |
| `$<BUILD_INTERFACE:...>` / `$<INSTALL_INTERFACE:...>` | Different values when building vs installed |
| `$<JOIN:list,glue>` | Join a list with a separator |
| `$<LINK_LANGUAGE:CXX>` | Link-time language |
| `$<TARGET_OBJECTS:t>` | Object files of an OBJECT library |
| `$<SHELL_PATH:path>` | Path in shell syntax |

Examples:

```cmake
target_compile_options(app PRIVATE
  $<$<COMPILE_LANGUAGE:C>:-std=gnu11;-Wmissing-prototypes>
  $<$<COMPILE_LANGUAGE:CXX>:-fno-exceptions;-fno-rtti>
  $<$<CONFIG:Debug>:-Og;-g3>
  $<$<CONFIG:Release>:-Os>)

# Write a file whose content depends on generator expressions (configure vs generate time)
file(GENERATE OUTPUT ${CMAKE_BINARY_DIR}/flags.txt CONTENT "$<TARGET_PROPERTY:app,COMPILE_OPTIONS>\n")
```

---

## 3. Custom commands: generating files correctly

```cmake
# A generated header is rebuilt when its input or the script changes
add_custom_command(
  OUTPUT  ${CMAKE_BINARY_DIR}/generated/tables.h
  COMMAND ${CMAKE_COMMAND} -E make_directory ${CMAKE_BINARY_DIR}/generated
  COMMAND python3 ${CMAKE_SOURCE_DIR}/tools/gen_tables.py -o ${CMAKE_BINARY_DIR}/generated/tables.h
  DEPENDS ${CMAKE_SOURCE_DIR}/tools/gen_tables.py ${CMAKE_SOURCE_DIR}/data/tables.yaml
  COMMENT "Generating tables.h"
  VERBATIM)

add_custom_target(gen_tables DEPENDS ${CMAKE_BINARY_DIR}/generated/tables.h)
add_dependencies(app gen_tables)                                  # make sure it exists before compiling app
target_include_directories(app PRIVATE ${CMAKE_BINARY_DIR}/generated)
```

Key points:

- `OUTPUT` + `DEPENDS` gives correct incremental behavior; `add_custom_target` without it always runs.
- `VERBATIM` makes quoting portable.
- `BYPRODUCTS` declares extra outputs (needed for Ninja to know about them).
- `WORKING_DIRECTORY`, `COMMAND_EXPAND_LISTS`, `DEPENDS` on targets (creates target-level dependency).
- `POST_BUILD` for steps after linking, `PRE_LINK` before.
- A chain of steps: `elf → bin → signed image`: each a separate `OUTPUT` command with `DEPENDS` on the previous output.
- `configure_file(in out @ONLY)` for templates evaluated at configure time (version strings).

### Stamping the git version and build time (reproducibly)

```cmake
find_package(Git QUIET)
execute_process(COMMAND ${GIT_EXECUTABLE} describe --tags --always --dirty
                WORKING_DIRECTORY ${CMAKE_SOURCE_DIR}
                OUTPUT_VARIABLE GIT_DESC OUTPUT_STRIP_TRAILING_WHITESPACE ERROR_QUIET)
if(NOT GIT_DESC)
  set(GIT_DESC "unknown")
endif()
configure_file(src/version.h.in ${CMAKE_BINARY_DIR}/generated/version.h @ONLY)
```

This runs at **configure** time: the version updates only when you reconfigure. For always-fresh versions use a custom target that regenerates `version.h` on every build (and only rewrites the file when the content changes to avoid needless rebuilds). Avoid `__DATE__` for reproducible builds (chapter 0).

---

## 4. Dependencies: FetchContent, ExternalProject, submodules

| Method | Use |
|---|---|
| **Git submodule** + `add_subdirectory` | Pinned, offline-friendly, explicit (recommended for vendored code: CMSIS, HAL, FreeRTOS, ETL) |
| **`FetchContent`** | Downloads at configure time; pin `GIT_TAG` (a commit hash is safest); needs network on first configure; cache in CI |
| **`ExternalProject_Add`** | Builds another project as a separate configure/build step (own toolchain/flags): for the bootloader image inside the app's build, host tools |
| `find_package` | System-installed libraries (host tools/tests), not for cross-compiled firmware |
| **CPM.cmake** | A thin helper over FetchContent with caching |
| `vcpkg`/`Conan` | Package managers (supported for cross builds, setup effort) |

```cmake
include(FetchContent)
FetchContent_Declare(etl
  GIT_REPOSITORY https://github.com/ETLCPP/etl.git
  GIT_TAG        20.39.4)                        # example: pin a tag or commit you have verified
FetchContent_MakeAvailable(etl)
target_link_libraries(app PRIVATE etl::etl)
```

Building the bootloader **with a different configuration** inside the same CMake invocation:

```cmake
include(ExternalProject)
ExternalProject_Add(bootloader
  SOURCE_DIR   ${CMAKE_SOURCE_DIR}/bootloader
  BINARY_DIR   ${CMAKE_BINARY_DIR}/bootloader
  CMAKE_ARGS   -DCMAKE_TOOLCHAIN_FILE=${CMAKE_TOOLCHAIN_FILE} -DCMAKE_BUILD_TYPE=Release
  BUILD_ALWAYS ON
  INSTALL_COMMAND "")
```

Alternatively, **two CMake projects** side by side (bootloader and application) driven by a top-level script or a **workflow preset**.

---

## 5. Per-file flags, OBJECT libraries, and warnings policy

```cmake
# Vendor sources: no warnings, optimize for size
set_source_files_properties(extern/vendor/foo.c PROPERTIES COMPILE_OPTIONS "-w;-Os")

# OBJECT library: compiled once, linked into several targets (no archive; startup code lives here safely)
add_library(startup OBJECT ${BOARD_STARTUP_ASM} ${BOARD_SYSTEM_C})
target_link_libraries(blink PRIVATE $<TARGET_OBJECTS:startup>)

# Code that must be in RAM: compile with a section name and let the linker script place it (section 8)
set_source_files_properties(src/flash_ops.c PROPERTIES COMPILE_OPTIONS "-O1;-fno-lto")
```

Warnings policy in CMake:

```cmake
add_library(project_warnings INTERFACE)
target_compile_options(project_warnings INTERFACE
  -Wall -Wextra -Wshadow -Wconversion -Wdouble-promotion -Wformat=2 -Wundef
  $<$<COMPILE_LANGUAGE:C>:-Wstrict-prototypes;-Wmissing-prototypes>)
target_link_libraries(app PRIVATE project_warnings)        # your code only; vendor targets do not link it
```

`SYSTEM` includes hide warnings coming from vendor headers; use `-Werror` only on `project_warnings` consumers.

---

## 6. Tooling integration in CMake

```cmake
set(CMAKE_EXPORT_COMPILE_COMMANDS ON)          # compile_commands.json for clangd, clang-tidy, VS Code

# Run tools on every compile (slow: use in CI or a dedicated preset)
set(CMAKE_C_CLANG_TIDY   clang-tidy;-p;${CMAKE_BINARY_DIR};--warnings-as-errors=*)
set(CMAKE_C_CPPCHECK     cppcheck;--enable=warning,style;--inline-suppr;--suppress=missingIncludeSystem)

# compiler cache
find_program(CCACHE ccache)
if(CCACHE)
  set(CMAKE_C_COMPILER_LAUNCHER   ${CCACHE})
  set(CMAKE_CXX_COMPILER_LAUNCHER ${CCACHE})
endif()

# speed up large builds (optional)
set(CMAKE_UNITY_BUILD ON)                      # merges sources: faster, but can hide macro/static name clashes
set(CMAKE_INTERPROCEDURAL_OPTIMIZATION ON)     # LTO (see section 9)

# Ninja Multi-Config / presets
#   cmake -G "Ninja Multi-Config" ... ; cmake --build build --config Release
```

### Tests: CTest

```cmake
enable_testing()
add_test(NAME ring_buffer COMMAND test_ring_buffer)
set_tests_properties(ring_buffer PROPERTIES TIMEOUT 10 LABELS unit)
```

```bash
ctest --test-dir build-host -R ring --output-on-failure -j$(nproc)
ctest -L unit
```

Running **target** executables under an emulator from CTest (QEMU or Renode): set `CMAKE_CROSSCOMPILING_EMULATOR` in the toolchain file and `add_test(NAME x COMMAND x.elf)` runs `emulator x.elf`.

### Packaging release artifacts (CPack)

```cmake
install(FILES $<TARGET_FILE:blink> $<TARGET_FILE_DIR:blink>/blink.bin $<TARGET_FILE_DIR:blink>/blink.map
        DESTINATION firmware)
set(CPACK_GENERATOR ZIP)
set(CPACK_PACKAGE_FILE_NAME "blink-${GIT_DESC}")
include(CPack)
```

```bash
cmake --build build && cpack --config build/CPackConfig.cmake      # blink-<version>.zip with elf, bin, map
```

---

## 7. Presets, workflows, and debugging CMake

### 7.1 Presets with inheritance and workflows

```json
{
  "version": 6,
  "configurePresets": [
    { "name": "base", "hidden": true, "generator": "Ninja",
      "toolchainFile": "${sourceDir}/cmake/toolchains/arm-toolchain.cmake",
      "environment": { "SOURCE_DATE_EPOCH": "1700000000" } },
    { "name": "debug",   "inherits": "base", "binaryDir": "${sourceDir}/build/debug",
      "cacheVariables": { "CMAKE_BUILD_TYPE": "Debug" } },
    { "name": "release", "inherits": "base", "binaryDir": "${sourceDir}/build/release",
      "cacheVariables": { "CMAKE_BUILD_TYPE": "Release" } }
  ],
  "buildPresets": [
    { "name": "debug", "configurePreset": "debug" },
    { "name": "release", "configurePreset": "release" }
  ],
  "workflowPresets": [
    { "name": "ci", "steps": [
        { "type": "configure", "name": "release" },
        { "type": "build", "name": "release" } ] }
  ]
}
```

```bash
cmake --workflow --preset ci          # configure + build in one command (check minimum CMake version)
```

### 7.2 Debugging the build system

```bash
cmake --build build --verbose            # real compiler/linker lines
ninja -C build -t commands blink | tail   # every command, in order (Ninja)
ninja -C build -t graph | dot -Tpng -o graph.png
cmake --graphviz=deps.dot -S . -B build && dot -Tpng deps.dot -o deps.png
cmake -S . -B build --trace-expand --trace-source=CMakeLists.txt 2>&1 | less
cmake -LAH build | less                 # cache with help text
cmake -S . -B build --debug-find        # why find_package/find_program found (or not) something
message(CHECK_START "Looking for X") ... message(CHECK_PASS "found")      # readable configure logs
```

Cross-compilation gotchas: `try_compile` needs `CMAKE_TRY_COMPILE_TARGET_TYPE STATIC_LIBRARY`; do not call `find_package` for host libraries inside the firmware project; avoid `execute_process` of target binaries; `CMAKE_FIND_ROOT_PATH_MODE_*` for sysroots; host tools needed during the build (code generators) should be **host executables** found with `find_program`, not built with the target toolchain.

---

## 8. Linker scripts: advanced techniques

Starting point: chapter 0's script (`MEMORY`, `SECTIONS`, `.data AT> FLASH`). Below are the features used in serious projects.

### 8.1 More memory regions (STM32F746)

```ld
MEMORY
{
  FLASH  (rx)  : ORIGIN = 0x08000000, LENGTH = 1024K       /* AXIM flash */
  ITCM   (rwx) : ORIGIN = 0x00000000, LENGTH = 16K         /* zero-wait-state code */
  DTCM   (rw)  : ORIGIN = 0x20000000, LENGTH = 64K         /* zero-wait-state data, stack */
  SRAM1  (rwx) : ORIGIN = 0x20010000, LENGTH = 240K
  SRAM2  (rwx) : ORIGIN = 0x2004C000, LENGTH = 16K
  /* external memory mapped through FMC/QSPI, if used */
}
REGION_ALIAS("RAM", SRAM1)               /* the generic "RAM" that other parts of the script use */
```

### 8.2 Placing code in ITCM (copied at startup)

```ld
.itcm_text : ALIGN(4)
{
  _sitcm = .;
  *(.itcm_text .itcm_text.*)             /* functions marked with __attribute__((section(".itcm_text"))) */
  . = ALIGN(4);
  _eitcm = .;
} >ITCM AT> FLASH
_siitcm = LOADADDR(.itcm_text);
```

and in the startup (C):

```c
extern uint32_t _sitcm, _eitcm, _siitcm;
for (uint32_t *s = &_siitcm, *d = &_sitcm; d < &_eitcm; ) { *d++ = *s++; }
```

C usage:

```c
__attribute__((section(".itcm_text"), noinline)) void fast_isr_body(void) { ... }
```

(This is the general **"relocate section to RAM" pattern**: VMA in RAM, LMA in Flash, a copy loop at boot. It also serves `.ramfunc` for flash-programming code (chapter 16): `.ramfunc : { *(.ramfunc*) } >SRAM1 AT> FLASH`.) On the F7, code in ITCM is fetched over the ITCM bus: beware that the flash itself can be accessed through ITCM at `0x00200000` for the ART accelerator (check RM0385: the boot/address choice).

### 8.3 Data in DTCM, uninitialized and special sections

```ld
.dtcm_data : ALIGN(4) { _sdtcm = .; *(.dtcm_data*) . = ALIGN(4); _edtcm = .; } >DTCM AT> FLASH
_sidtcm = LOADADDR(.dtcm_data);
.dtcm_bss (NOLOAD) : ALIGN(4) { *(.dtcm_bss*) } >DTCM
.noinit (NOLOAD) : ALIGN(4) { *(.noinit*) } >SRAM1            /* survives soft reset: chapter 4 */
.dma_buffers (NOLOAD) : ALIGN(32) { *(.dma_buffers*) } >SRAM1   /* cache-line aligned, for DMA */
```

`NOLOAD` keeps the section out of the binary image and out of the startup `.bss` clearing if you place it outside `[_sbss, _ebss]`.

### 8.4 Assertions and sanity checks in the linker

```ld
_Min_Stack_Size = 0x1000;
_Min_Heap_Size  = 0x2000;

._user_heap_stack (NOLOAD) :
{
  . = ALIGN(8);
  PROVIDE(end = .);
  PROVIDE(_end = .);
  . = . + _Min_Heap_Size;
  . = . + _Min_Stack_Size;
  . = ALIGN(8);
} >SRAM1

ASSERT(. <= ORIGIN(SRAM1) + LENGTH(SRAM1), "RAM overflow: heap + stack do not fit")
ASSERT(SIZEOF(.isr_vector) <= 0x200, "vector table larger than expected")
ASSERT((_sidata % 4) == 0, ".data load address is not word aligned")
```

`ASSERT(cond, "msg")` fails the link with your message: use it for stack/heap fit, alignment of the vector table, image size limits (bootloader `LENGTH`), and presence of required sections.

### 8.5 Catching mistakes

```
-Wl,--orphan-handling=warn      # warn about input sections the script does not place (or =error)
-Wl,--no-warn-rwx-segments      # silence recent binutils' warning about RWX LOAD segments in bare-metal scripts (only if you understand it)
-Wl,--fatal-warnings            # treat linker warnings as errors
-Wl,--print-gc-sections         # list what was discarded
-Wl,--cref                      # cross-reference table in the map file: who references which symbol
-Wl,--trace-symbol=SysTick_Handler   # report where a symbol is defined/referenced while linking
-Wl,--defsym=_Min_Stack_Size=0x2000  # override a script symbol from the command line
```

### 8.6 Self-registering tables with `__start_`/`__stop_`

When a section name is a valid C identifier, GNU ld defines `__start_<name>` and `__stop_<name>` automatically. This lets modules **register themselves** (commands, tests, drivers) without a central list:

```c
typedef struct { const char *name; int (*fn)(int, char **); } cmd_t;
#define REGISTER_CMD(n, f) static const cmd_t cmd_##n __attribute__((section("cmd_table"), used)) = { #n, f }

REGISTER_CMD(led, cmd_led);                  /* in led.c */
REGISTER_CMD(adc, cmd_adc);                  /* in adc.c */

extern const cmd_t __start_cmd_table[], __stop_cmd_table[];
for (const cmd_t *c = __start_cmd_table; c < __stop_cmd_table; c++) { /* dispatch */ }
```

Make sure the linker script **KEEPs and places** it (otherwise `--gc-sections` removes it and orphan placement may fail): `.cmd_table : { KEEP(*(cmd_table)) } >FLASH` (with explicit symbols `__start_cmd_table = .;` etc. if the section is placed by the script).

### 8.7 Multiple images and shared symbols

- Bootloader and application linked separately, each with its own `ORIGIN`/`LENGTH`.
- Share addresses through a **common header** (`#define APP_BASE 0x08020000`) and linker symbols passed with `-Wl,--defsym` or generated include files for the script (`INCLUDE memory_map.ld`).
- Application can import bootloader functions (a fixed-address API table) with `--just-symbols=bootloader.elf`.
- Keep the vector table aligned (`ALIGN(0x200)` or the power of two required by `VTOR`).

### 8.8 Overlays and other rarities

`OVERLAY` loads different sections at the same VMA (rare on MCUs with enough RAM); `INSERT AFTER` adds sections to the default script without rewriting it; `PHDRS` defines program headers. Know they exist; do not use them without a reason.

---

## 9. Compiler/linker optimization features

| Feature | Flag | Notes |
|---|---|---|
| Garbage collection of sections | `-ffunction-sections -fdata-sections -Wl,--gc-sections` | Always (chapter 0) |
| **LTO** (link-time optimization) | `-flto` at compile **and** link (`-ffat-lto-objects`, `CMAKE_INTERPROCEDURAL_OPTIMIZATION`) | Smaller/faster code across files; harder debugging, interacts with startup/ISR names, weak symbols and `used` attributes; verify the image and keep the vector table/handlers marked `used` |
| Size optimization | `-Os`, `-Oz` (clang) | Release default |
| Merge identical constants/functions | `-fmerge-all-constants` (risky), `-fipa-icf` | Smaller |
| Exceptions/RTTI off | `-fno-exceptions -fno-rtti` | C++ (chapter 6) |
| Align functions/loops | `-falign-functions=16` | Tune for the M7 fetch |
| Profile-guided | `-fprofile-use` | Rare on MCUs |
| Link order and `--sort-section` | | Deterministic layout |
| Specs | `--specs=nano.specs --specs=nosys.specs` | `arm-none-eabi-gcc -dumpspecs` shows what they change; `picolibc.specs` if you installed picolibc |
| Math | `-ffast-math`, `-fno-math-errno` | Faster `sqrtf` without errno; `-ffast-math` changes IEEE behavior |

When LTO breaks something, mark the offending symbol `__attribute__((used))`, compile the startup file without LTO (`-fno-lto` per file), and make sure interrupt handlers are strong symbols reachable from the vector table.

---

## 10. Binary utilities and image tricks

```bash
arm-none-eabi-objcopy -O binary  in.elf out.bin                 # raw image
arm-none-eabi-objcopy -O ihex    in.elf out.hex                 # Intel HEX
arm-none-eabi-objcopy -O srec    in.elf out.srec
arm-none-eabi-objcopy --only-section=.text --only-section=.rodata in.elf code.bin
arm-none-eabi-objcopy --remove-section=.noinit in.elf out.elf
arm-none-eabi-objcopy --gap-fill 0xFF --pad-to 0x08040000 -O binary in.elf padded.bin   # fixed-size image filled with 0xFF
arm-none-eabi-objcopy --change-addresses 0x08020000 in.hex shifted.hex                 # relocate a hex
arm-none-eabi-strip -g in.elf                                   # drop debug info
arm-none-eabi-objcopy --only-keep-debug in.elf in.debug         # separate symbols for release
arm-none-eabi-objcopy --add-gnu-debuglink=in.debug stripped.elf # link them
arm-none-eabi-readelf -S -l -s -A in.elf                        # sections, segments, symbols, attributes
arm-none-eabi-readelf --debug-dump=info in.elf | less           # DWARF
arm-none-eabi-nm -S --size-sort -C in.elf
arm-none-eabi-size -A -x in.elf                                 # per-section sizes in hex
arm-none-eabi-objdump -D -b binary -m arm -M force-thumb out.bin   # disassemble a raw binary
arm-none-eabi-c++filt _ZN3Led2onEv
arm-none-eabi-addr2line -e in.elf -f -p 0x08001ba0
```

Merge or patch images with **`srec_cat`** (`sudo apt install srecord`):

```bash
srec_cat bootloader.bin -binary -offset 0x08000000 \
         app.bin        -binary -offset 0x08020000 \
         -o combined.hex -intel                                           # one HEX with both images
srec_cat in.bin -binary -offset 0x08000000 -fill 0xFF 0x08000000 0x0801FFFC \
         -crc32-b-e 0x0801FFFC -o with_crc.bin -binary                    # insert a CRC-32 (check the CRC parameters match your firmware!)
```

(`-crc32-b-e` is a big-endian CRC32 variant: the polynomial/reflection details must match the firmware's check; for exact parameters, use your own Python script as in chapter 16.)

### Analysis tools

| Tool | Use |
|---|---|
| **Bloaty McBloatface** | Size by symbol/section/file/library, and **diff between two builds** (`bloaty new.elf -- old.elf`) |
| `puncover` | Browse code size/stack per function |
| Map-file readers | Section/object attribution |
| `nm --size-sort`, `objdump -h` | Quick checks |
| `ld --trace-symbol`, `--cref` | Who pulls what in |
| `su` files (`-fstack-usage`) + `cflow`/scripts | Worst-case stack estimates |
| `arm-none-eabi-gdb -batch` | Scripted inspection |

### Reading the map file

Sections of a GNU ld map:

1. **Archive member included to satisfy reference**: which library object was pulled in and **why** (a symbol needed by another object). Great for finding why `printf` float code appeared.
2. **Discarded input sections**: what `--gc-sections` removed.
3. **Memory Configuration**: your `MEMORY` regions with sizes.
4. **Linker script and memory map**: the final address of every input section by output section, with the object file name and size.
5. **Cross Reference Table** (`--cref`).

Search `grep -n "malloc" build/blink.map` to see who reaches the heap; look at `.text` contributions sorted by size with a script (chapter 17).

---

## 11. Build speed and reproducibility

- **Ninja** instead of Makefiles; **ccache** in CI and locally; keep header dependencies lean; precompiled headers rarely help for C.
- Avoid `file(GLOB ...)` for sources (no re-configure when files are added) unless `CONFIGURE_DEPENDS`.
- Reproducibility (chapter 0): `-ffile-prefix-map`, fixed `SOURCE_DATE_EPOCH`, no `__DATE__/__TIME__`, deterministic archives (`ar D`), fixed toolchain version, `-Wl,--build-id=none` or a build-id derived from content, verify by building twice and comparing `sha256sum`.
- Keep **one source of truth** for flags (toolchain file + INTERFACE libraries) so host tests, firmware and tools stay consistent.
- Build **in containers** for identical environments (Dockerfile with `gcc-arm-none-eabi`, CMake, Ninja, Python, tools), used locally and in CI.

---

## 12. Exercises

1. **Helper function**: implement `add_firmware()` and rebuild your project with it; add a second target (a tiny test firmware) to prove the reuse.
2. **Generator expressions**: convert all per-config flags and per-language flags to generator expressions; print the final flags with `file(GENERATE)`.
3. **Generated header**: create a Python-generated `tables.h` wired with `add_custom_command(OUTPUT ...)`; verify it regenerates only when inputs change.
4. **Version stamping**: embed `git describe` in the firmware, print it at boot, and check that a dirty tree shows `-dirty`.
5. **Dependencies**: vendor ETL (or another header library) with FetchContent pinned to a tag, then replace it by a git submodule and compare workflows.
6. **ccache and Ninja**: measure clean and incremental build times before and after.
7. **clang-tidy/cppcheck in CMake**: enable them through `CMAKE_C_CLANG_TIDY`/`CMAKE_C_CPPCHECK` in a dedicated preset.
8. **CPack**: package ELF, BIN and MAP into a versioned zip.
9. **ITCM placement**: move one hot function to ITCM with the linker script and startup copy; verify its address with `nm`, and measure cycles in flash vs ITCM with DWT.
10. **`.ramfunc`**: place a flash-erase routine in RAM; verify `nm` shows a RAM VMA and a flash LMA (`objdump -h`).
11. **Linker assertions**: add `ASSERT`s for stack/heap fit and image size; provoke each failure.
12. **Orphan sections**: add `--orphan-handling=error`, create a section you forgot to place, and see the error.
13. **Self-registering commands**: implement `REGISTER_CMD` with `__start_/__stop_` and a CLI that lists commands; verify with `--gc-sections` enabled.
14. **`--wrap`**: intercept `malloc` with `-Wl,--wrap=malloc` to trap/log allocations (and use `--wrap` to mock a function in a host test).
15. **LTO**: build with `-flto`, compare size and behavior, and fix a breakage (a missing `used`, an ISR dropped).
16. **Bloaty diff**: compare two releases and find what grew.
17. **Map file reading**: find which object pulls in `printf` float support and why.
18. **Containerized build**: write a Dockerfile with the toolchain and build the firmware identically on your PC and in CI; compare hashes.

---

## 13. Cheat sheet

```
Function:     add_firmware(name SOURCES … LINKER_SCRIPT … LIBRARIES …)  → elf/bin/hex/map/size/flash
Gen exprs:    $<$<CONFIG:Debug>:-Og;-g3>  $<$<COMPILE_LANGUAGE:C>:…>  $<TARGET_FILE:t>  (no spaces; ';' separates)
Generated:    add_custom_command(OUTPUT … COMMAND … DEPENDS … VERBATIM) + add_custom_target + add_dependencies
Deps:         submodules (pinned) > FetchContent (pinned tag) ; ExternalProject for separate-config sub-builds
Debug build:  --verbose, ninja -t commands, cmake --graphviz, --trace-expand, -LAH
Linker:       MEMORY/REGION_ALIAS, AT> FLASH + startup copy, NOLOAD, ASSERT(), --orphan-handling, --cref, --print-gc-sections
Tricks:       __start_/__stop_ registries, .ramfunc, ITCM/DTCM placement, --wrap, --defsym, --just-symbols
Tools:        objcopy (bin/hex/pad/only-section), srec_cat, bloaty, readelf -S -l, objdump -D -b binary
Repro:        -ffile-prefix-map, SOURCE_DATE_EPOCH, pinned toolchain, containers, sha256sum twice
```

| Symptom | Look at |
|---|---|
| Section ended up in the wrong memory | Map file "Linker script and memory map", orphan handling |
| Code works in RAM but not after reset | Missing startup copy (`_si...` symbols), `AT>` |
| `--gc-sections` removed a table or ISR | `KEEP()` in the script, `used` attribute |
| Image too big | Bloaty, map file "Archive member included", LTO/`-Os` |
| LTO build behaves differently | Weak symbols, ISRs, missing `used`, startup compiled with LTO |
| Rebuilds everything every time | Custom command without correct `OUTPUT/DEPENDS`, timestamps, `configure_file` changing content |

---

## 14. Where this leads

- **Bootloader/security** (chapter 16): two images, post-build signing steps, `.ramfunc`.
- **Testing** (chapter 14): host builds from the same CMake graph, `--wrap` mocks, coverage builds.
- **Python tooling** (chapter 17): generators and analysis scripts invoked from CMake.
- **Zephyr** (chapter 9): its CMake is a large example of the techniques here (generated linker scripts, devicetree, Kconfig integration).

## References

- CMake documentation: `cmake-generator-expressions(7)`, `cmake-buildsystem(7)`, `cmake-toolchains(7)`, `cmake-presets(7)`, `cmake-language(7)`
- *Professional CMake*, Craig Scott
- GNU ld manual: *Linker Scripts*, *Command Line Options*; GNU binutils manual; `info ld`
- Bloaty: <https://github.com/google/bloaty>; srecord: <https://srecord.sourceforge.net>
- ccache: <https://ccache.dev>; Ninja manual
- *Linkers and Loaders*, John Levine
