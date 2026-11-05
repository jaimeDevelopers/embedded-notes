# GNU Make: Notes for Embedded Development

Target platform used in the examples: STM32F746ZG (Cortex-M7), `arm-none-eabi-gcc`, Ubuntu.

> **Important:** recipe lines in a Makefile must start with a real **TAB** character, not spaces.
> If you copy code from this file and get `*** missing separator. Stop.`, your editor converted the tabs.
> Keep the full working examples as real files in a git repo and copy from there.

---

## 1. What make is

`make` is a **rule executor driven by dependencies**. It compares file modification times and runs only what is needed. If you change `uart.c`, it recompiles `uart.o` and relinks, without touching the rest.

```bash
make --version                 # Ubuntu ships GNU Make 4.x
sudo apt install build-essential
```

By default it looks for `GNUmakefile`, `makefile` or `Makefile` (in that order) in the current directory.

---

## 2. Anatomy of a rule

```make
target: prerequisites
	recipe
```

- **target**: what you want to produce (usually a file).
- **prerequisites**: what it needs. If any is newer than the target, or the target does not exist, the recipe runs.
- **recipe**: shell commands, each line starting with a TAB.

```make
hello: main.o util.o
	gcc main.o util.o -o hello

main.o: main.c util.h
	gcc -c main.c -o main.o
```

- `make` with no arguments builds the **first target** in the file (the *default goal*).
- `make main.o` builds a specific target.

---

## 3. How make thinks (two phases)

1. **Phase 1 (parse):** reads all Makefiles, expands variables and conditionals, builds the dependency graph.
2. **Phase 2 (execute):** walks the graph and runs recipes where needed.

This explains most surprising behavior. Variables and conditionals are evaluated in phase 1. Variables inside recipes are expanded just before the recipe runs, and then the shell sees the result.

---

## 4. Variables

```make
CC      = arm-none-eabi-gcc    # recursive: re-evaluated every time it is used
CFLAGS := -Og -g3              # simple: evaluated once, at definition (recommended)
CFLAGS += -Wall                # append (adds a space)
BUILD  ?= debug                # assign only if not already defined
```

| Operator | Meaning |
|---|---|
| `=` | Recursive (deferred expansion) |
| `:=` or `::=` | Simple (immediate expansion) |
| `?=` | Assign only if undefined |
| `+=` | Append |
| `!=` | Assign the output of a shell command |

Use with `$(CC)` or `${CC}`. A single-character name can omit parentheses (`$X`), but avoid that.

**Precedence (highest first):** command line > Makefile > environment.

```bash
make CFLAGS=-O2        # overrides the Makefile value (unless it uses `override`)
BUILD=release make     # environment variable (loses to the Makefile unless ?=)
make -e                # let the environment override the Makefile
```

To keep a variable from being overridden from the command line: `override CFLAGS += -Wall`.

### Multi-line variables

```make
define HELP_TEXT
Targets:
  all    build firmware
  flash  program the board
endef
```

---

## 5. Automatic variables

Available inside recipes:

| Variable | Value |
|---|---|
| `$@` | Target name |
| `$<` | First prerequisite |
| `$^` | All prerequisites (duplicates removed) |
| `$+` | All prerequisites (duplicates kept, useful for link order) |
| `$?` | Prerequisites newer than the target |
| `$*` | The stem matched by `%` |
| `$(@D)` / `$(@F)` | Directory part / file part of `$@` |
| `$(<D)` / `$(<F)` | Same for `$<` |
| `$|` | Order-only prerequisites |

```make
%.o: %.c
	$(CC) $(CFLAGS) -c $< -o $@
```

---

## 6. Pattern rules

`%` is a wildcard that matches the same text in the target and prerequisites:

```make
build/%.o: src/%.c
	@mkdir -p $(dir $@)
	$(CC) $(CFLAGS) -c $< -o $@
```

### Static pattern rules

Limit a pattern to an explicit list of targets:

```make
$(OBJS): build/%.o: src/%.c
	$(CC) $(CFLAGS) -c $< -o $@
```

### Built-in (implicit) rules

Make knows how to build `.o` from `.c` using `CC`, `CFLAGS`, `CPPFLAGS` without you writing a rule.

```bash
make -p          # print all rules and variables (very long)
make -r          # disable built-in rules
make -R          # disable built-in variables
```

In embedded projects, write explicit rules and disable the built-ins.

---

## 7. `.PHONY` targets

Phony targets are not files: `all`, `clean`, `flash`. If a file named `clean` existed, make would consider the target up to date and do nothing.

```make
.PHONY: all clean flash
```

---

## 8. Functions

Syntax: `$(function arguments)`.

### Files and paths

```make
SRCS := $(wildcard src/*.c)                  # expand a glob
$(dir src/a.c)            # src/
$(notdir src/a.c)         # a.c
$(basename src/a.c)       # src/a
$(suffix src/a.c)         # .c
$(abspath ../x)           # absolute path, no symlink resolution
$(realpath ../x)          # absolute path, symlinks resolved, must exist
$(addprefix -I,src lib)   # -Isrc -Ilib
$(addsuffix .o,a b)       # a.o b.o
```

### Text

```make
OBJS := $(patsubst %.c,build/%.o,$(SRCS))    # src/a.c -> build/src/a.o
OBJS := $(SRCS:%.c=build/%.o)                # shorthand, equivalent
$(subst from,to,text)
$(strip   a   b )                            # a b
$(filter %.c,$(FILES))                       # keep matches
$(filter-out main.c,$(SRCS))                 # remove matches
$(sort $(LIST))                              # sort and remove duplicates
$(word 2,a b c)                              # b
$(words a b c)                               # 3
$(firstword a b c)                           # a
```

### Logic and control

```make
$(if $(DEBUG),-g,-O2)
$(or $(A),$(B))
$(and $(A),$(B))
$(foreach d,$(DIRS),$(wildcard $(d)/*.c))
$(call my_func,arg1,arg2)                    # user-defined function ($(1), $(2) inside)
$(eval ...)                                  # parse text as Makefile syntax
$(origin VAR)                                # where a variable came from
$(value VAR)                                 # unexpanded value
```

### Shell and diagnostics

```make
GIT_REV := $(shell git rev-parse --short HEAD)
$(info Building revision $(GIT_REV))         # print message
$(warning something odd)                     # print with file:line
$(error Missing BOARD)                       # stop with an error
```

> `wildcard` is convenient, but in firmware projects an **explicit list of source files** is safer: you know exactly what goes into the image.

---

## 9. Conditionals

```make
ifeq ($(BUILD),release)
  OPT := -Os -DNDEBUG
else ifeq ($(BUILD),debug)
  OPT := -Og -g3
else
  $(error Unknown BUILD '$(BUILD)')
endif

ifdef VERBOSE
  Q :=
else
  Q := @
endif
```

Other forms: `ifneq`, `ifndef`. Conditionals are evaluated in phase 1, so they cannot test values that only exist while recipes run. Inside a recipe use shell `if`.

---

## 10. Header dependencies (very important)

If `led.h` changes, make does not know that `main.c` includes it. Let GCC generate dependency files:

```make
CFLAGS += -MMD -MP
-include $(OBJS:.o=.d)
```

- `-MMD` writes a `.d` file listing the user headers each object depends on.
- `-MP` adds an empty target for each header, so deleting a header does not break the build.
- `-include` (with the dash) does not fail if the `.d` files do not exist yet.

Missing this is the number one cause of "I changed a header and nothing was rebuilt".

---

## 11. Recipe control

```make
all:
	@echo "quiet command"     # @ : do not echo the command
	-rm -f file               # - : ignore errors from this command
	+$(MAKE) sub              # + : run even with -n / -t / -q
```

- **Each recipe line runs in its own shell.** `cd dir` on one line does not affect the next. Join with `&&` or `;`, or use `.ONESHELL:`.
- The default shell is `/bin/sh`. Change with `SHELL := /bin/bash`.
- To pass a literal `$` to the shell, double it: `$$HOME`, `$$(date)`.
- Break long lines with a trailing `\`.
- A recipe stops at the first failing command (non-zero exit status).

---

## 12. Order-only prerequisites

Prerequisites after `|` must exist, but their timestamp does not trigger a rebuild. Ideal for directories (a directory's mtime changes whenever files are added to it):

```make
build/%.o: src/%.c | build
	$(CC) $(CFLAGS) -c $< -o $@

build:
	mkdir -p $@
```

---

## 13. Special targets and variables

| Name | Effect |
|---|---|
| `.PHONY` | Targets that are not files |
| `.DEFAULT_GOAL := all` | Set the default goal explicitly |
| `.DELETE_ON_ERROR:` | Delete the target if its recipe fails (prevents corrupt artifacts) |
| `.PRECIOUS` | Do not delete these targets if make is interrupted |
| `.SECONDARY` | Keep intermediate files |
| `.SUFFIXES:` | Empty the old-style suffix list |
| `.ONESHELL:` | Run each whole recipe in a single shell |
| `.SILENT:` | Do not echo recipes (like `@` everywhere) |
| `MAKEFLAGS` | Flags passed to sub-makes |
| `MAKECMDGOALS` | Goals given on the command line |

A healthy Makefile header:

```make
.DELETE_ON_ERROR:
.SUFFIXES:
```

---

## 14. Command-line options

| Option | Use |
|---|---|
| `make -n` | Dry run: print what would be executed |
| `make -j$(nproc)` | Build in parallel |
| `make -B` | Rebuild everything, ignore timestamps |
| `make -C dir` | Change to `dir` first |
| `make -f other.mk` | Use another Makefile |
| `make -k` | Keep going after errors |
| `make -s` | Silent |
| `make -p` | Print internal rules and variables |
| `make -d` / `--debug=b` | Explain why targets are rebuilt |
| `make -q` | Question mode: exit status says whether it is up to date |
| `make -W file` | Pretend `file` is new |
| `make -o file` | Pretend `file` is old |
| `make VAR=value` | Set a variable (overrides the Makefile) |
| `make -e` | Environment overrides Makefile |
| `make -r` / `-R` | Disable built-in rules / variables |
| `make --warn-undefined-variables` | Warn on use of undefined variables |

---

## 15. Recursive make and `include`

```make
include config.mk          # error if missing
-include extra.mk          # no error if missing
sinclude extra.mk          # same as -include
```

Recursive make:

```make
SUBDIRS := drivers lib

.PHONY: all $(SUBDIRS)
all: $(SUBDIRS)

$(SUBDIRS):
	$(MAKE) -C $@
```

Always use `$(MAKE)`, never plain `make`, so that `-j`, `-n` and other flags propagate correctly.

Recursion has known drawbacks: dependencies between subdirectories are invisible to the top-level make. For most firmware projects, a single Makefile that `include`s small `.mk` fragments is more reliable.

---

## 16. Parallel builds

```bash
make -j$(nproc)       # run as many jobs as CPU cores
make -j4 -O           # -O groups output per target so logs don't interleave
```

Parallel builds expose **missing dependencies**: a build that works with `-j1` may fail with `-j8` if a rule relies on an order that was never declared. If that happens, add the missing prerequisite instead of removing `-j`.

---

## 17. Common errors

| Message | Cause |
|---|---|
| `*** missing separator. Stop.` | Spaces instead of TAB in a recipe |
| `No rule to make target 'x.o'` | Source file missing or wrong path |
| `Nothing to be done for 'all'` | Everything is up to date |
| `'x' is up to date.` | Target exists and is newer than its prerequisites |
| Always rebuilds | Missing `.PHONY`, or a prerequisite never gets created |
| Header changed, no rebuild | Missing `-MMD -MP` |
| `Circular dependency dropped` | A target depends on itself through the graph |
| `unterminated call to function` | Unbalanced parentheses in `$(...)` |
| Odd behavior with paths | Spaces in file names. Make handles them badly, avoid them |
| `cd` has no effect | Each line is a separate shell |

Debugging tools:

```bash
make -n                    # what would run
make --debug=b             # why each target is rebuilt
make -p | less             # all rules and variables
make -d | less             # very verbose
make print-VAR             # needs the helper below
```

Handy helper target to print any variable (`make print-CFLAGS`):

```make
print-%:
	@echo '$* = $($*)'
```

---

## 18. Complete Makefile for the STM32F746ZG

```make
# ---------------------------------------------------------------------------
# Makefile for STM32F746ZG (bare metal, CMSIS, newlib-nano)
# ---------------------------------------------------------------------------
TARGET    := blink
BUILD_DIR := build

# Toolchain
CC      := arm-none-eabi-gcc
OBJCOPY := arm-none-eabi-objcopy
SIZE    := arm-none-eabi-size

# Quiet by default; run "make V=1" to see the full commands
ifeq ($(V),1)
  Q :=
else
  Q := @
endif

# Sources (explicit list, no wildcard)
SRCS := src/main.c \
        src/drivers/led.c \
        src/drivers/button.c \
        src/drivers/adc.c \
        src/drivers/uart.c \
        src/drivers/systick.c \
        boards/stm32f746/vendor/system_stm32f7xx.c \
        boards/stm32f746/vendor/startup_stm32f746xx.s

# build/src/main.c.o, build/boards/.../startup_stm32f746xx.s.o, ...
OBJS := $(SRCS:%=$(BUILD_DIR)/%.o)
DEPS := $(OBJS:.o=.d)

LDSCRIPT := boards/stm32f746/STM32F746ZGTx_FLASH.ld

# CPU flags: must be identical when compiling and linking.
# The F746 FPU is single precision only (fpv5-sp-d16).
ARCH := -mcpu=cortex-m7 -mthumb -mfpu=fpv5-sp-d16 -mfloat-abi=hard

DEFS := -DSTM32F746xx -DTARGET_F746 -DCORE_CM7 -DCPU_HZ=16000000UL
INCS := -Isrc -Isrc/drivers \
        -isystem extern/cmsis_core/Include \
        -isystem extern/cmsis_device_f7/Include

# BUILD=release gives a size-optimized image
BUILD ?= debug
ifeq ($(BUILD),release)
  OPT := -Os -DNDEBUG
else
  OPT := -Og -g3
endif

CFLAGS  := $(ARCH) $(DEFS) $(INCS) $(OPT) \
           -std=gnu11 -Wall -Wextra -Wno-unused-parameter \
           -ffunction-sections -fdata-sections \
           -MMD -MP

LDFLAGS := $(ARCH) \
           -T$(LDSCRIPT) \
           --specs=nano.specs --specs=nosys.specs \
           -Wl,-u,_printf_float \
           -Wl,--gc-sections \
           -Wl,-Map=$(BUILD_DIR)/$(TARGET).map \
           -Wl,--print-memory-usage

.DEFAULT_GOAL := all
.DELETE_ON_ERROR:
.SUFFIXES:
.PHONY: all clean flash

all: $(BUILD_DIR)/$(TARGET).bin

# Link (the linker script is a prerequisite, so changing it relinks)
$(BUILD_DIR)/$(TARGET).elf: $(OBJS) $(LDSCRIPT)
	@echo "LD   $@"
	$(Q)$(CC) $(OBJS) $(LDFLAGS) -o $@
	$(Q)$(SIZE) $@

# ELF -> raw binary
$(BUILD_DIR)/%.bin: $(BUILD_DIR)/%.elf
	@echo "BIN  $@"
	$(Q)$(OBJCOPY) -O binary $< $@

# Compile C
$(BUILD_DIR)/%.c.o: %.c
	@echo "CC   $<"
	@mkdir -p $(dir $@)
	$(Q)$(CC) $(CFLAGS) -c $< -o $@

# Assemble (.s goes through the C preprocessor)
$(BUILD_DIR)/%.s.o: %.s
	@echo "AS   $<"
	@mkdir -p $(dir $@)
	$(Q)$(CC) $(CFLAGS) -x assembler-with-cpp -c $< -o $@

flash: $(BUILD_DIR)/$(TARGET).bin
	st-flash --reset write $< 0x08000000

clean:
	rm -rf $(BUILD_DIR)

# Header dependencies generated by -MMD
-include $(DEPS)
```

Usage:

```bash
make -j$(nproc)          # build
make V=1                 # show the real commands
make BUILD=release       # size-optimized (run "make clean" first)
make flash               # build, program and reset
make clean
make -n                  # dry run
```

### Things worth understanding in this example

- `$(SRCS:%=$(BUILD_DIR)/%.o)` is a substitution reference. The object keeps `.c` in its name (`main.c.o`) so `a.c` and `a.s` never collide.
- `@mkdir -p $(dir $@)` creates a mirror directory tree under `build/`.
- The linker script is a prerequisite of the ELF.
- `-MMD -MP` plus `-include $(DEPS)` handles header dependencies.
- `.DELETE_ON_ERROR` prevents half-written artifacts.

### Known limitation

If you change `BUILD` (or any flag), make does **not** know and will not recompile the existing objects. See the next section. This is a classic weakness that CMake solves automatically.

---

## 19. Rebuilding when flags change

Store the current flags in a file and make every object depend on it:

```make
FLAGS_FILE := $(BUILD_DIR)/.flags

# Rewrite the file only when its content differs (keeps its timestamp otherwise)
$(FLAGS_FILE): FORCE
	@mkdir -p $(dir $@)
	@echo '$(CC) $(CFLAGS)' | cmp -s - $@ || echo '$(CC) $(CFLAGS)' > $@

.PHONY: FORCE
FORCE:

$(OBJS): $(FLAGS_FILE)
```

Now changing `BUILD`, `CFLAGS` or the compiler recompiles everything.

---

## 20. Splitting into `.mk` fragments

```make
# Makefile
include mk/toolchain.mk
include mk/board_stm32f746.mk
include mk/rules.mk
```

Each fragment sets variables or defines rules. Paths are relative to where `make` is launched, not to the fragment, so run make from the project root (or use `$(dir $(lastword $(MAKEFILE_LIST)))` to find a fragment's own directory).

---

## 21. Out-of-tree and multi-configuration builds

Use a build directory per configuration so objects never mix:

```make
BUILD ?= debug
BUILD_DIR := build/$(BUILD)
```

```bash
make BUILD=debug
make BUILD=release
```

---

## 22. Useful extras

```bash
# Generate compile_commands.json for IDE autocompletion
sudo apt install bear
bear -- make

# Show the real commands without building
make -n V=1

# Print the macros the compiler predefines for your flags
arm-none-eabi-gcc -mcpu=cortex-m7 -mfpu=fpv5-sp-d16 -mfloat-abi=hard -dM -E - < /dev/null | grep -i fp
```

- Manual: `info make`, `man make`, <https://www.gnu.org/software/make/manual/>.
- Check for stray spaces in recipes: `cat -A Makefile | grep -n '^ '` (tabs show as `^I`).

---

## 23. Cheat sheet

| Goal | How |
|---|---|
| Build in parallel | `make -j$(nproc)` |
| See commands | `make V=1` (with the `Q` pattern) |
| Why was X rebuilt? | `make --debug=b` |
| Dry run | `make -n` |
| Force full rebuild | `make -B` |
| Print a variable | `make print-VAR` (helper target) |
| Header changes ignored | Add `-MMD -MP` and `-include $(DEPS)` |
| `cd` not working | Each line is its own shell; use `&&` or `.ONESHELL:` |
| Literal `$` in shell | `$$` |
| Directory as prerequisite | Order-only: `target: src \| dir` |
| Avoid corrupt outputs | `.DELETE_ON_ERROR:` |
| Rebuild on flag change | Flags-file trick (section 19) |

---

## 24. What make does not do well (why CMake exists)

- No automatic detection of flag or compiler changes.
- No built-in notion of libraries, include propagation or build types.
- Hard to support several toolchains or boards cleanly.
- Recursive builds hide dependencies.
- No portable way to generate IDE project files.

Next topic: **CMake**, which generates the build system (Makefiles or Ninja) instead of you writing it by hand.