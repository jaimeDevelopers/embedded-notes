# 14. Advanced Testing, Quality, and CI for Firmware

Prerequisites: chapter 5 (C, UB), chapter 6 (C++), chapter 8 (architecture, seams, test pyramid), chapter 11 (protocols), chapter 17 (Python tools).

**Verification note.** Tool options change between versions (Ceedling 1.0, CMock, GoogleTest, GitHub Actions, MISRA tooling). Commands and configs here are representative and **not run on your setup**: check each tool's documentation. A pass in these tests is evidence, not proof.

---

## 1. Goals and a test strategy

Firmware is hard to test because it touches hardware, runs forever, depends on time and interrupts, and cannot be patched easily once deployed. The strategy is to **push as much logic as possible into code that runs on your PC**, and to test the hardware-specific remainder with automation on the real target.

```
          ▲  few, slow, expensive
          │  System / acceptance tests on the product
          │  HIL (hardware-in-the-loop) tests: board + fixture + scripts
          │  On-target integration tests (drivers, DMA, timing)
          │  Component tests on the host with fakes
          ▼  Unit tests on the host (thousands, run in seconds)
             many, fast, cheap
```

What testing buys you: regressions caught in minutes, courage to refactor, documented behavior, and a faster debug loop than flashing a board. What it does not do: prove the absence of bugs or replace code review and analysis.

### What to test where

| Code | Where |
|---|---|
| Pure logic: parsers, state machines, CRC, filters, PID, ring buffers, scheduling policy | **Host unit tests** |
| Drivers talking to a chip through an interface (bus/HAL) | Host with **fakes** |
| Application flows with fake time and fake I/O | Host component tests |
| Register-level code, DMA, interrupts, clock, timing | **On target** (automated) |
| Analog behavior, EMC, power | Lab measurements |
| End-to-end behavior | HIL/system tests |

---

## 2. Testing techniques

### 2.1 Test design

| Technique | Idea |
|---|---|
| **Arrange-Act-Assert** | Set up the state, call the unit, check the result: one behavior per test |
| **Equivalence classes** | Test one value per class of inputs |
| **Boundary values** | 0, 1, max-1, max, max+1, negative, empty, full, wrap-around (tick overflow, index wrap) |
| **Error injection** | Fakes that fail (timeouts, NACKs, CRC errors, full queues) |
| **State-transition coverage** | Every transition of a state machine, and invalid events in each state |
| **Property-based testing** | Generate many random inputs and check properties (`decode(encode(x)) == x`); Hypothesis (Python), RapidCheck (C++) |
| **Golden/reference tests** | Compare with a trusted reference (Python implementation, a standard test vector) |
| **Characterization tests** | Pin down current behavior of legacy code before refactoring |
| **Fuzzing** | Random/mutated inputs against parsers (section 6) |
| **Regression tests** | Every fixed bug gets a test that failed before the fix |

### 2.2 Test-driven development (TDD) for embedded

```
1. Write a failing test (red)       → defines the behavior and the interface
2. Write the minimal code (green)
3. Refactor with tests as a safety net
```

Works well for protocol parsers, state machines and algorithms. The "red" step proves the test can fail; never trust a test you have not seen fail.

### 2.3 Testability principles (recap)

- Separate **logic from hardware** (HAL interface, chapter 8).
- Inject **dependencies**: time, bus, GPIO, storage.
- **No hidden globals**; module state resettable for tests (`module_reset()` in test builds or `setUp`).
- Keep functions **small and deterministic**.
- Seams: **link-time** (different `.c` per build) is the simplest; function pointers/ops tables for runtime; templates in C++; linker `--wrap` (chapter 19) to intercept calls in legacy code; avoid `#ifdef UNIT_TEST` sprinkled in production code.

---

## 3. Frameworks

| Framework | Language | Notes |
|---|---|---|
| **Unity** (ThrowTheSwitch) | C | Tiny, embeddable (also usable on target), many assertion macros |
| **Ceedling** | C | Build/test runner around Unity + CMock + generated runners (Ruby tool; config in YAML) |
| **CMock** | C | Generates mocks from header files |
| **CMocka** | C | Mocking with `will_return`, `expect_*` |
| **GoogleTest / GoogleMock** | C++ | Rich assertions and mocks |
| **Catch2**, **doctest** | C++ | Header-only, simple |
| **ztest** | C (Zephyr) | Chapter 9 |
| **pytest** | Python | HIL, protocol conformance, tooling tests |
| **CTest** | any | CMake's test runner: orchestrates all of the above |

### 3.1 Unity example

```c
/* test_ring_buffer.c */
#include "unity.h"
#include "ring_buffer.h"

static ring_t rb;
static uint8_t storage[8];

void setUp(void)    { ring_init(&rb, storage, sizeof storage); }
void tearDown(void) { }

void test_empty_buffer_returns_false(void)
{
    uint8_t b;
    TEST_ASSERT_FALSE(ring_get(&rb, &b));
}

void test_put_then_get_returns_same_byte(void)
{
    uint8_t out = 0;
    TEST_ASSERT_TRUE(ring_put(&rb, 0xA5));
    TEST_ASSERT_TRUE(ring_get(&rb, &out));
    TEST_ASSERT_EQUAL_HEX8(0xA5, out);
}

void test_full_buffer_rejects_put(void)
{
    for (unsigned i = 0; i < sizeof storage - 1; i++) { TEST_ASSERT_TRUE(ring_put(&rb, (uint8_t)i)); }
    TEST_ASSERT_FALSE(ring_put(&rb, 0xFF));                 /* one slot is kept empty */
}

int main(void)
{
    UNITY_BEGIN();
    RUN_TEST(test_empty_buffer_returns_false);
    RUN_TEST(test_put_then_get_returns_same_byte);
    RUN_TEST(test_full_buffer_rejects_put);
    return UNITY_END();
}
```

Useful macros: `TEST_ASSERT_EQUAL_INT/UINT32/HEX8`, `TEST_ASSERT_EQUAL_UINT8_ARRAY(exp, act, n)`, `TEST_ASSERT_EQUAL_FLOAT` (or `TEST_ASSERT_FLOAT_WITHIN(delta, exp, act)`), `TEST_ASSERT_EQUAL_STRING`, `TEST_ASSERT_NULL`, `TEST_ASSERT_BITS`, `TEST_FAIL_MESSAGE`.

### 3.2 Mocks with CMock (concept)

Given `hal_i2c.h`, CMock generates `Mockhal_i2c.c/h` with functions like:

```c
hal_i2c_read_ExpectAndReturn(0x48, 0x00, buf, 2, ST_OK);         /* expect this call, return OK */
hal_i2c_read_ReturnArrayThruPtr_buf(raw, 2);                     /* fill the output buffer */
TEST_ASSERT_EQUAL(ST_OK, sensor_read(&s, &temp));
```

Mocks verify **interactions** (calls and arguments); they can make tests brittle. Prefer **fakes** (working simple implementations with state: a fake I2C device with a register map) for hardware-like behavior, and mocks for checking specific call sequences.

### 3.3 Ceedling

A `project.yml` configures source and test paths, defines, plugins (`gcov`), and the compiler. Typical use: `ceedling test:all`, `ceedling gcov:all`. Look at the current Ceedling documentation: its configuration schema changed between 0.x and 1.x.

### 3.4 GoogleTest through CMake `FetchContent`

```cmake
cmake_minimum_required(VERSION 3.16...4.2)
project(host_tests CXX C)
enable_testing()

include(FetchContent)
FetchContent_Declare(googletest
  GIT_REPOSITORY https://github.com/google/googletest.git
  GIT_TAG        v1.15.2)                     # pin a tag you have verified
FetchContent_MakeAvailable(googletest)

add_executable(test_fsm test_fsm.cpp ../src/app/fsm.c)
target_include_directories(test_fsm PRIVATE ../src/app ../src/hal/include)
target_link_libraries(test_fsm PRIVATE GTest::gtest_main)
target_compile_options(test_fsm PRIVATE -g -O1 -Wall -Wextra -fsanitize=address,undefined)
target_link_options(test_fsm PRIVATE -fsanitize=address,undefined)

include(GoogleTest)
gtest_discover_tests(test_fsm)
```

(Network access is needed to fetch; pin versions and vendor/cache them for reproducible CI.)

### 3.5 A fake clock and fake GPIO (host fakes)

```c
/* fakes/hal_time_fake.c */
#include "hal_time.h"
static uint32_t now_ms;
uint32_t hal_millis(void)     { return now_ms; }
void     fake_time_set(uint32_t t)     { now_ms = t; }
void     fake_time_advance(uint32_t d) { now_ms += d; }       /* unsigned wrap is part of the test! */
```

Tests then control time exactly: wrap-around of the 32-bit tick (`fake_time_set(0xFFFFFFF0u)`), timeouts, debounce intervals, without sleeping.

---

## 4. Coverage

### 4.1 Types

| Coverage | Meaning |
|---|---|
| Statement/line | Each statement executed |
| **Branch/decision** | Each `if`/`switch` outcome taken both ways |
| Condition | Each boolean sub-expression true and false |
| **MC/DC** | Each condition independently affects the outcome (required by DO-178C level A, used in ISO 26262 high ASIL) |
| Function/call | Each function called |

High coverage does not mean good tests (a test with no assertions "covers" everything), but **low** coverage shows untested code. Use it to find gaps, not as a target to game.

### 4.2 Tools (host)

```bash
# build tests with coverage instrumentation
gcc -O0 -g --coverage -fprofile-arcs -ftest-coverage test.c module.c -o test && ./test
gcov module.c                                   # per-file .gcov text
gcovr -r . --html --html-details -o coverage.html --branches     # HTML report (pip install gcovr)
lcov --capture --directory . --output-file cov.info && genhtml cov.info -o cov_html
```

In CMake: add `--coverage` to compile and link options for test targets only. Track the trend in CI; set a modest gate (for example "coverage must not decrease").

On-target coverage is possible (gcov data via semihosting/RTT) but costly; host coverage of the logic is the practical choice.

---

## 5. Static and dynamic analysis

### 5.1 Compiler warnings (first line of defense)

```
-Wall -Wextra -Wshadow -Wconversion -Wsign-conversion -Wdouble-promotion -Wformat=2
-Wundef -Wstrict-prototypes -Wmissing-prototypes -Wcast-align -Wnull-dereference
-Wstack-usage=1024 -Wswitch-enum -Wredundant-decls
```

Apply to your code (not vendor code) and **keep the build warning-free**; then `-Werror` in CI.

### 5.2 Static analyzers

| Tool | Notes |
|---|---|
| **cppcheck** | Free, easy: `cppcheck --enable=warning,style,performance,portability --inline-suppr --std=c11 src/`; MISRA addon needs the rule texts |
| **clang-tidy** | Needs `compile_commands.json`; checks `bugprone-*`, `cert-*`, `clang-analyzer-*`, `performance-*`, `readability-*`; for C++ `cppcoreguidelines-*` |
| **GCC `-fanalyzer`** | Interprocedural analysis for C (noisy; useful for leaks, null derefs, double free) |
| `scan-build` (clang static analyzer) | Wrap the build: `scan-build make` |
| Commercial: Coverity, PVS-Studio, Polyspace, Klocwork, LDRA, QAC | Deep analysis, MISRA/CERT checkers, certification support (free tiers for open source exist) |
| `include-what-you-use` | Include hygiene |
| `clang-format` | Formatting (enforce in CI or pre-commit) |

Policy tips: start with a small, agreed ruleset; fix or **justify** each finding (inline suppression with a comment); do not drown in noise.

### 5.2.1 MISRA C

A coding standard for safety/critical software (MISRA C:2012 with amendments; newer 2023 edition): directives and rules (e.g., no dynamic memory, restricted use of `goto`, essential types, no recursion, all `switch` complete). Rules are **mandatory/required/advisory**; deviations are documented. Useful even if you are not certified: it systematizes defensive C. Checking needs a licensed tool or cppcheck's addon with the rule text.

### 5.3 Dynamic analysis on the host

| Tool | Flag | Finds |
|---|---|---|
| **AddressSanitizer** | `-fsanitize=address` | Out-of-bounds, use-after-free, leaks |
| **UndefinedBehaviorSanitizer** | `-fsanitize=undefined` | Signed overflow, bad shifts, null deref, misaligned access |
| **MemorySanitizer** (clang) | `-fsanitize=memory` | Uninitialized reads |
| **ThreadSanitizer** | `-fsanitize=thread` | Data races in threaded host code |
| **Valgrind** | `valgrind --leak-check=full ./test` | Memory errors without recompiling |

Always run host tests under ASan+UBSan in CI.

### 5.4 Analysis on the target

- **UBSan as traps**: build with `-fsanitize=undefined -fsanitize-undefined-trap-on-error` (GCC) so undefined behavior becomes a fault you can catch in the debugger (check your toolchain support and code-size cost).
- **Stack usage**: `-fstack-usage` + `-Wstack-usage`, a call-graph tool (e.g. `cflow`, or scripts over `.su` files), stack painting (chapter 4).
- **Stack protector**: `-fstack-protector-strong` needs `__stack_chk_guard` and `__stack_chk_fail` (security hardening, chapter 16).
- **Map-file checks**: size gates (section 9.2).
- `ASSERT()` active in test/debug builds.

---

## 6. Fuzzing

Fuzzing feeds many mutated inputs to a function and watches for crashes or sanitizer reports. Ideal for **parsers** and decoders: COBS, frame parsers, Modbus, JSON, config loaders.

### 6.1 libFuzzer harness (clang)

```c
/* fuzz_frame.c */
#include <stdint.h>
#include <stddef.h>
#include "frame_parser.h"

int LLVMFuzzerTestOneInput(const uint8_t *data, size_t size)
{
    rx_frame_t rx = {0};
    for (size_t i = 0; i < size; i++) { rx_feed(&rx, data[i], dummy_handler); }   /* must never crash or leak */
    return 0;
}
```

```bash
clang -g -O1 -fsanitize=fuzzer,address,undefined fuzz_frame.c frame_parser.c cobs.c -o fuzz_frame
mkdir corpus && ./fuzz_frame corpus -max_total_time=60       # grows the corpus automatically
```

Add seed inputs (valid frames) to `corpus/`; keep crashing inputs as **regression tests**. AFL++ (`afl-clang-fast`) is an alternative. Fuzz **round-trip properties** too: `decode(encode(x)) == x`.

### 6.2 What to fuzz and what to assert

- No crashes, hangs, or sanitizer errors for **any** input.
- Output lengths never exceed buffers.
- Invalid input yields an error code, never undefined behavior.
- State returns to a consistent state after garbage (resync).

---

## 7. Mutation testing and test quality

Mutation testing changes your code slightly (flip `<` to `<=`, remove a statement) and checks whether the tests fail ("kill the mutant"). Surviving mutants reveal weak tests. Tools: `mull` (C/C++ with clang), `mutmut` (Python). Costly but revealing for critical modules.

Other quality signals: flaky tests (fix or quarantine, never ignore), test run time (keep unit tests under seconds), and the **defect escape rate** (bugs found after release versus before).

---

## 8. On-target and HIL testing

### 8.1 What needs the hardware

Interrupt latency and priorities, DMA, timers/PWM accuracy, clock settings, flash driver, power modes, real sensor/bus behavior, electrical behavior.

### 8.2 A simple on-target test runner

Run Unity (it is small) on the board; the tests print results over UART/RTT; a host script reads them. Structure:

```c
int main(void)
{
    board_init();
    UNITY_BEGIN();
    RUN_TEST(test_uart_loopback);
    RUN_TEST(test_timer_period_within_tolerance);
    int fails = UNITY_END();
    printf("RESULT %s\r\n", fails ? "FAIL" : "PASS");
    for (;;) { }
}
```

### 8.3 HIL with pytest and pyserial

```python
# tests_hil/test_device.py
import time, pytest, serial

@pytest.fixture(scope="session")
def dut():
    with serial.Serial("/dev/ttyACM0", 115200, timeout=1.0) as s:
        s.reset_input_buffer()
        yield s

def cmd(dut, text: str) -> str:
    dut.write((text + "\r\n").encode())
    return dut.readline().decode().strip()

def test_ping(dut):
    assert cmd(dut, "ping") == "pong"

def test_version_format(dut):
    v = cmd(dut, "version")
    assert v.startswith("fw ") and len(v.split(".")) >= 3

@pytest.mark.timeout(5)
def test_adc_reads_in_range(dut):
    mv = int(cmd(dut, "adc 0"))
    assert 0 <= mv <= 3300
```

Practical HIL setup:

- A **flash step** before the session (`cmake --build build --target flash` or `openocd program`), then wait for boot.
- **Power control** for repeatable resets: USB hub per-port power (`uhubctl`), relay board, lab supply controlled over SCPI.
- **Stimulus and measurement fixtures**: a second MCU or a DAC/relay board generating inputs, a logic analyzer API (sigrok-cli) or scope to measure outputs, a CAN adapter, a USB-UART bridge.
- **Reports**: `pytest --junitxml=report.xml` for CI dashboards; attach logs and captures to failures.
- Handle **flakiness** (timeouts, retries only where the hardware requires them), and **one DUT per runner** (a self-hosted CI runner connected to the board).
- Add a **CLI/test command interface** to the firmware (chapter 8) to make HIL easy.

### 8.4 Simulation and emulation

| Tool | Use |
|---|---|
| **Renode** | Simulates MCUs and peripherals, with Robot Framework test integration; check support for your STM32 part |
| **QEMU** | Some ARM boards (limited STM32 peripherals) |
| **Zephyr `native_sim`** | Runs Zephyr apps on the PC (chapter 9) |
| Device emulators (fake I2C/SPI chips on the host) | Test drivers against a software model |

---

## 9. Continuous integration and quality gates

### 9.1 Pipeline stages

```
 commit/PR ─► format + lint ─► build (all boards × Debug/Release) ─► host unit tests (+sanitizers)
          ─► static analysis ─► coverage ─► size check ─► artifacts (.elf .bin .map)
          ─► (nightly/self-hosted) HIL tests ─► release (tag) ─► sign + publish
```

Keep PR feedback **fast** (minutes); push slow jobs (HIL, fuzzing, mutation) to nightly.

### 9.2 Size gate script

```python
#!/usr/bin/env python3
# tools/check_size.py : fail the build if Flash/RAM exceed budgets
import subprocess, sys
elf, flash_budget, ram_budget = sys.argv[1], int(sys.argv[2]), int(sys.argv[3])
out = subprocess.check_output(["arm-none-eabi-size", elf], text=True).splitlines()[1].split()
text, data, bss = int(out[0]), int(out[1]), int(out[2])
flash, ram = text + data, data + bss
print(f"Flash {flash} / {flash_budget}   RAM {ram} / {ram_budget}")
if flash > flash_budget or ram > ram_budget:
    sys.exit("size budget exceeded")
```

Store the previous build's numbers as an artifact and report the **delta** per PR: size regressions are easier to fix when caught immediately.

### 9.3 GitHub Actions sketch

```yaml
name: ci
on: [push, pull_request]
jobs:
  host-tests:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4
        with: { submodules: recursive }
      - run: sudo apt-get update && sudo apt-get install -y cmake ninja-build cppcheck lcov gcovr
      - run: cmake -S tests -B build-host -G Ninja -DCMAKE_BUILD_TYPE=Debug
      - run: cmake --build build-host
      - run: ctest --test-dir build-host --output-on-failure
      - run: cppcheck --error-exitcode=1 --enable=warning,performance --inline-suppr -q src/
  firmware:
    runs-on: ubuntu-latest
    strategy: { matrix: { build_type: [Debug, Release] } }
    steps:
      - uses: actions/checkout@v4
        with: { submodules: recursive }
      - run: sudo apt-get update && sudo apt-get install -y gcc-arm-none-eabi libnewlib-arm-none-eabi cmake ninja-build
      - run: cmake -S . -B build -G Ninja -DCMAKE_BUILD_TYPE=${{ matrix.build_type }} -DCMAKE_TOOLCHAIN_FILE=cmake/toolchains/arm-toolchain.cmake
      - run: cmake --build build
      - run: python3 tools/check_size.py build/blink.elf 200000 100000
      - uses: actions/upload-artifact@v4
        with: { name: fw-${{ matrix.build_type }}, path: "build/*.elf\nbuild/*.map\nbuild/*.bin" }
```

Verify action versions and package names for your runner image. A self-hosted runner with the board attached runs the HIL job (`runs-on: [self-hosted, nucleo]`).

### 9.4 Pre-commit hooks

`.pre-commit-config.yaml` (framework from <https://pre-commit.com>):

```yaml
repos:
  - repo: https://github.com/pre-commit/mirrors-clang-format
    rev: v18.1.8
    hooks: [ { id: clang-format, files: '\.(c|h|cpp|hpp)$' } ]
  - repo: https://github.com/shellcheck-py/shellcheck-py
    rev: v0.10.0.1
    hooks: [ { id: shellcheck } ]
  - repo: https://github.com/pre-commit/pre-commit-hooks
    rev: v4.6.0
    hooks: [ { id: trailing-whitespace }, { id: end-of-file-fixer }, { id: check-added-large-files } ]
```

Pin to versions you have checked. Install with `pre-commit install`.

### 9.5 Build hygiene and reproducibility

- Pin toolchain versions (container image or version-checked script); record `arm-none-eabi-gcc --version` in the artifacts.
- Reproducible builds (chapter 0): same inputs give the same `sha256sum`; CI can verify by building twice.
- Keep **the ELF and map of every release** (chapter 4).
- **Dependency management**: git submodules with pinned commits or CMake `FetchContent` with pinned tags; track CVEs for third-party code; generate an **SBOM** (list of components and versions); regulations such as the EU Cyber Resilience Act increasingly require one (chapter 16).

---

## 10. Review and process

### 10.1 Code review checklist

- Does every new behavior have a test? Does a fixed bug have a regression test?
- ISR/thread safety of shared data; `volatile`/atomics; critical sections short.
- Return values checked; **timeouts** on every wait; no unbounded loops.
- Buffer sizes and bounds; integer overflows; signed/unsigned mixing.
- No blocking calls in ISRs; no dynamic allocation.
- Units and ranges documented; magic numbers named.
- Resource usage (Flash, RAM, stack) considered.
- Naming, comments explaining *why*, public API documented.
- Error handling consistent; failure leads to a safe state.

### 10.2 Definition of done

Builds warning-free on all targets, tests added and green, static analysis clean (or suppressions justified), size budget respected, docs/changelog updated, reviewed.

### 10.3 Bug handling

Reproduce, write a failing test, fix, keep the test, note the cause in the commit. For field failures: collect fault records and logs (chapter 4), reproduce on the bench with the recorded inputs.

---

## 11. Exercises

1. **Unity**: write tests for a ring buffer (empty, full, wrap-around), run them on the PC under ASan/UBSan.
2. **Fake clock**: test a debounce/timeout module across the 32-bit tick wrap.
3. **Fake bus**: test a sensor driver against a fake I2C device that returns scripted data and injects NACKs/timeouts.
4. **State machine**: write a transition-table test that exercises **every** (state, event) pair, including invalid ones.
5. **TDD**: implement the COBS encoder/decoder test-first, with Python as the reference.
6. **Property test**: use Hypothesis (via `ctypes`/`cffi`) to check `decode(encode(x)) == x` for random inputs.
7. **Mocks**: use CMock or CMocka to verify the exact I2C call sequence of an init routine, then replace it with a fake and compare how brittle each test is.
8. **Coverage**: measure branch coverage with gcovr and add tests until all branches of the parser are exercised.
9. **cppcheck and clang-tidy** on your project; triage and fix or justify each finding.
10. **Fuzzing**: build the libFuzzer harness for the frame parser, find (or confirm absence of) a crash, add the crashing input as a regression test.
11. **Sanitizers on target**: build with `-fsanitize=undefined -fsanitize-undefined-trap-on-error` and provoke a trap.
12. **On-target tests**: run a Unity test binary on the Nucleo that checks timer periods and UART loopback, reporting through the VCP, driven by `pytest`.
13. **HIL**: write the pytest suite of section 8.3 against your CLI; add a timeout and a retry-free assertion style.
14. **CI**: create the pipeline (host tests, firmware build matrix, size gate); break each gate on purpose to see it fail.
15. **Mutation testing** of a small module with `mull` or `mutmut`; strengthen the tests until mutants die.
16. **Process**: write your team's definition of done and review checklist, and apply it to one of your past changes.

---

## 12. Cheat sheet

```
Host test         gcc/clang -g -O1 -fsanitize=address,undefined test.c unit.c fakes.c
Coverage          --coverage → gcov / gcovr --branches --html
Static            -Wall -Wextra -Wconversion … ; cppcheck ; clang-tidy ; -fanalyzer
Fuzz              clang -fsanitize=fuzzer,address,undefined harness.c parser.c
CI gates          warnings=0, tests pass, sanitizers clean, analysis clean, size within budget
HIL               pytest + pyserial + power control + fixtures; JUnit XML
```

| Question | Answer |
|---|---|
| Hardware-dependent code, how to test on the PC? | Interface + fake (link-time seam) |
| Time-dependent code? | Inject a fake clock; test wrap-around |
| ISR code? | Move logic to a function called by the ISR; test the function |
| Parsers? | Table tests + fuzzing + round-trip properties |
| Confidence in tests? | Coverage + mutation + seeing the test fail first |
| Regressions in size or performance? | CI gates with budgets |
| Real hardware behavior? | On-target tests + HIL |

---

## 13. Where this leads

- **Bootloader/security** (chapter 16): fuzz update parsers, test rollback and power-loss behavior.
- **Python tooling** (chapter 17): HIL frameworks, golden-vector generators, size reports.
- **Advanced toolchain** (chapter 19): `--wrap` for link-time mocking, CTest integration, coverage builds.
- **Safety standards**: traceability, coverage objectives, tool qualification.

## References

- *Test Driven Development for Embedded C*, James W. Grenning
- ThrowTheSwitch (Unity, CMock, Ceedling): <https://www.throwtheswitch.org>
- GoogleTest documentation; Catch2; CMocka; Hypothesis
- libFuzzer and AFL++ documentation; Sanitizers documentation (clang/GCC)
- cppcheck, clang-tidy, GCC `-fanalyzer` manuals; MISRA C:2012/2023 (paid), SEI CERT C (free)
- *Working Effectively with Legacy Code*, Michael Feathers (seams and characterization tests)
- Renode: <https://renode.io>; pytest: <https://docs.pytest.org>