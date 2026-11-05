# 17. Python for Embedded Development: Tools, Tests, and Automation

Python is the glue of embedded work: talking to boards, parsing build output, generating code and tables, designing algorithms, writing hardware tests, and automating CI. This chapter assumes basic Python knowledge and shows **embedded-specific** patterns.

Prerequisites: chapter 11 (protocols), chapter 13 (filters), chapter 14 (testing), chapter 16 (image tools). Ubuntu with Python 3.10+.

**Verification note.** Library APIs (pyserial, pyelftools, pytest, pyocd, ...) change; the examples are standard but **not run against your board**. Check the version you install.

---

## 1. Setup and project hygiene

### 1.1 Environments

```bash
sudo apt install python3 python3-venv python3-pip pipx
python3 -m venv .venv                 # one per project
source .venv/bin/activate
pip install --upgrade pip
pip install pyserial pytest pyelftools numpy scipy matplotlib pandas
pip freeze > requirements.txt         # reproducible environments (pin versions)
deactivate
```

- On recent Ubuntu, system-wide `pip install` is blocked (PEP 668): use a **virtual environment** or **`pipx`** for command-line tools (`pipx install gcovr`). Avoid `--break-system-packages`.
- Keep tools in `tools/` in the firmware repository, with `requirements.txt` (or a `pyproject.toml`), so CI and teammates reproduce your environment.
- Add `.venv/` and `__pycache__/` to `.gitignore`.

### 1.2 Script skeleton

```python
#!/usr/bin/env python3
"""Short description of what the tool does."""
import argparse
import logging
import sys

log = logging.getLogger(__name__)

def parse_args(argv=None):
    p = argparse.ArgumentParser(description=__doc__)
    p.add_argument("port", help="serial port, e.g. /dev/ttyACM0")
    p.add_argument("-b", "--baud", type=int, default=115200)
    p.add_argument("-v", "--verbose", action="store_true")
    return p.parse_args(argv)

def main(argv=None) -> int:
    args = parse_args(argv)
    logging.basicConfig(level=logging.DEBUG if args.verbose else logging.INFO,
                        format="%(asctime)s %(levelname)s %(message)s")
    ...
    return 0

if __name__ == "__main__":
    sys.exit(main())
```

Habits: `argparse` (or `click`/`typer`), **exit codes** (0 success, non-zero failure: CI depends on them), the `logging` module instead of `print`, **type hints**, `pathlib.Path` for files, functions small enough to test with `pytest`, `subprocess.run(..., check=True)` for external commands, no hard-coded paths or ports.

---

## 2. Serial ports with pyserial

### 2.1 Basics

```python
import serial
import serial.tools.list_ports

for p in serial.tools.list_ports.comports():
    print(p.device, p.description, p.vid, p.pid, p.serial_number)     # find the ST-LINK VCP (VID 0483)

with serial.Serial("/dev/ttyACM0", 115200, timeout=0.5) as s:
    s.write(b"ping\r\n")
    line = s.readline()               # until \n or timeout
    print(line.decode(errors="replace").strip())
```

Important arguments: `timeout` (read timeout in seconds; `None` blocks forever), `write_timeout`, `bytesize`, `parity`, `stopbits`, `rtscts`/`xonxoff`, `exclusive=True` (fail if the port is used by another program). Use `/dev/serial/by-id/...` for stable names.

Key methods: `read(n)`, `read_until(b"\x00")`, `readline()`, `in_waiting`, `reset_input_buffer()`, `flush()`, `write()`, `send_break()`, and the control lines `dtr`, `rts` (some USB-UART adapters wire them to reset/boot pins; the Nucleo's VCP does not).

### 2.2 A timestamped logger

```python
#!/usr/bin/env python3
import argparse, datetime, serial

p = argparse.ArgumentParser()
p.add_argument("port"); p.add_argument("-b", "--baud", type=int, default=115200)
p.add_argument("-o", "--out", default=None)
a = p.parse_args()

out = open(a.out, "a", buffering=1) if a.out else None
with serial.Serial(a.port, a.baud, timeout=1) as s:
    while True:
        line = s.readline()
        if not line:
            continue
        ts = datetime.datetime.now().strftime("%H:%M:%S.%f")[:-3]
        text = f"{ts}  {line.decode(errors='replace').rstrip()}"
        print(text)
        if out: out.write(text + "\n")
```

(Same idea as `cat /dev/ttyACM0 | ts`; a script lets you filter, parse and plot.)

### 2.3 Robust reading in a thread

```python
import queue, threading, serial

def reader(s: serial.Serial, q: queue.Queue, stop: threading.Event):
    buf = bytearray()
    while not stop.is_set():
        data = s.read(s.in_waiting or 1)
        if not data: continue
        buf.extend(data)
        while b"\n" in buf:
            line, _, rest = buf.partition(b"\n")
            buf = bytearray(rest)
            q.put(bytes(line))
```

The main thread then consumes from the queue with timeouts: avoids blocking the GUI/test logic and losing data.

### 2.4 Request/response with timeouts and retries

```python
import time

def transact(s, request: bytes, expect_prefix: bytes, timeout=1.0, retries=3) -> bytes:
    for attempt in range(retries):
        s.reset_input_buffer()
        s.write(request)
        deadline = time.monotonic() + timeout
        while time.monotonic() < deadline:
            line = s.readline()
            if line.startswith(expect_prefix):
                return line
        log.warning("timeout on attempt %d", attempt + 1)
    raise TimeoutError(f"no reply to {request!r}")
```

Use `time.monotonic()` for timeouts (not `time.time()`).

### 2.5 Binary framing (chapter 11's protocol)

```python
import struct, binascii
from cobs import cobs                   # pip install cobs

def crc16(data: bytes) -> int:
    return binascii.crc_hqx(data, 0xFFFF)               # CRC-16/CCITT-FALSE

def pack_frame(msg_type: int, seq: int, payload: bytes = b"") -> bytes:
    body = struct.pack("<BBBB", 1, msg_type, seq, len(payload)) + payload
    body += struct.pack("<H", crc16(body))
    return cobs.encode(body) + b"\x00"

def unpack_frame(raw: bytes):
    body = cobs.decode(raw.rstrip(b"\x00"))
    ver, mtype, seq, length = struct.unpack_from("<BBBB", body)
    payload = body[4:4 + length]
    (crc_rx,) = struct.unpack_from("<H", body, 4 + length)
    if crc16(body[:4 + length]) != crc_rx:
        raise ValueError("bad CRC")
    return mtype, seq, payload
```

`struct` format characters: `<` little-endian, `B`/`H`/`I`/`Q` unsigned 8/16/32/64, `b`/`h`/`i`/`q` signed, `f`/`d` float/double, `s` bytes, `x` pad; `struct.calcsize`, `iter_unpack`, `pack_into`. Also `int.from_bytes(b, "little", signed=True)` and `x.to_bytes(4, "little")`.

### 2.6 Related libraries

| Library | Use |
|---|---|
| `pyserial-asyncio` | Serial with `asyncio` |
| `python-can` | CAN (SocketCAN, USB adapters) |
| `pymodbus` | Modbus RTU/TCP |
| `paho-mqtt` | MQTT client |
| `bleak` | BLE central |
| `pyusb`, `hidapi` | Raw USB/HID access |
| `scapy` | Packet crafting/analysis |
| `construct`, `bitstruct` | Declarative binary parsing |
| `crcmod`, `crc` | General CRC calculations |
| `pyvisa` | SCPI instruments (power supplies, scopes, meters) |

---

## 3. Checksums and bit-exact numerics

```python
import zlib, binascii

zlib.crc32(data) & 0xFFFFFFFF            # standard CRC-32 (IEEE, reflected)
binascii.crc_hqx(data, 0xFFFF)           # CRC-16/CCITT-FALSE
```

The STM32 hardware CRC (chapter 0) is **CRC-32/MPEG-2 over 32-bit words** with a different configuration: implement it explicitly and cross-check with a firmware test vector:

```python
import struct

def stm32_crc32(data: bytes) -> int:
    crc = 0xFFFFFFFF
    data += b"\xFF" * (-len(data) % 4)                    # pad to words
    for (word,) in struct.iter_unpack("<I", data):
        crc ^= word
        for _ in range(32):
            crc = ((crc << 1) ^ 0x04C11DB7) & 0xFFFFFFFF if crc & 0x80000000 else (crc << 1) & 0xFFFFFFFF
    return crc
```

Always verify new CRC code with **known check strings** (`"123456789"`) and with data that went through the real firmware.

Emulate C integer behavior when comparing algorithms (Python ints are unbounded): mask with `& 0xFFFFFFFF`, convert to signed with `struct.unpack("<i", struct.pack("<I", x))[0]`, and use `numpy` types (`np.int32`, `np.float32`) when float/int widths matter.

---

## 4. Parsing build artifacts

### 4.1 `arm-none-eabi-size` and the map file

```python
import re, subprocess

def elf_sizes(elf: str):
    out = subprocess.check_output(["arm-none-eabi-size", elf], text=True).splitlines()[1].split()
    text, data, bss = map(int, out[:3])
    return {"flash": text + data, "ram": data + bss, "text": text, "data": data, "bss": bss}

def map_symbols(map_path: str):
    """Rough parse of GNU ld map: yields (section, size, object) for text/data/bss contributions."""
    pat = re.compile(r"^\s(\.\S+)\s+0x[0-9a-f]+\s+(0x[0-9a-f]+)\s+(\S+)$")
    for line in open(map_path, errors="replace"):
        m = pat.match(line)
        if m:
            yield m.group(1), int(m.group(2), 16), m.group(3)
```

(GNU map files wrap long section names onto two lines; for exact results prefer parsing the ELF, next.)

### 4.2 Parsing the ELF with pyelftools

```python
from elftools.elf.elffile import ELFFile

def functions_by_size(elf_path: str, top: int = 20):
    with open(elf_path, "rb") as f:
        elf = ELFFile(f)
        symtab = elf.get_section_by_name(".symtab")
        funcs = [(s.name, s["st_size"]) for s in symtab.iter_symbols()
                 if s["st_info"]["type"] == "STT_FUNC" and s["st_size"] > 0]
    return sorted(funcs, key=lambda t: t[1], reverse=True)[:top]

for name, size in functions_by_size("build/blink.elf"):
    print(f"{size:6d}  {name}")
```

With `pyelftools` you can also list sections (`elf.iter_sections()`), read DWARF info (types, line tables), and look up a symbol's address: handy for scripts that patch binaries (insert a CRC at a known symbol) or compare releases.

Similar to `nm -S --size-sort`; the value of Python is **post-processing**: tables, trends over commits, and CI gates (chapter 14).

### 4.3 Size report to Markdown/CSV and a CI gate

```python
import csv, sys
sizes = elf_sizes(sys.argv[1])
print(f"| Flash | RAM |\n|---|---|\n| {sizes['flash']} | {sizes['ram']} |")
if sizes["flash"] > int(sys.argv[2]):
    sys.exit("flash budget exceeded")
```

Tools worth knowing: `bloaty` (Google, size attribution by symbol/file/section), `puncover`, `arm-none-eabi-nm --size-sort`.

---

## 5. Code and table generation

Generating C from data keeps tables correct and reproducible.

### 5.1 Filter coefficients (from chapter 13)

```python
from scipy.signal import butter

sos = butter(2, 20, fs=1000, output="sos")
b0, b1, b2, a0, a1, a2 = sos[0]
print(f"""\
/* generated by tools/gen_filter.py: do not edit */
static const biquad_t lp20 = {{ {b0:.9g}f, {b1:.9g}f, {b2:.9g}f, {a1:.9g}f, {a2:.9g}f, 0.0f, 0.0f }};
""")
```

### 5.2 Lookup tables

```python
import math
N = 256
print("static const int16_t sine_q15[%d] = {" % N)
print(",".join(str(round(32767 * math.sin(2 * math.pi * i / N))) for i in range(N)))
print("};")
```

(Add line wrapping, a `const` section placement, and a header comment with the generation command and a version.)

### 5.3 Templates (Jinja2)

```python
from jinja2 import Template
tpl = Template("""
typedef enum {
{%- for name, value in items %}
    {{ name }} = {{ value }},
{%- endfor %}
} error_code_t;
""")
print(tpl.render(items=[("ERR_OK", 0), ("ERR_TIMEOUT", 1), ("ERR_BUS", 2)]))
```

Generate **enums + string tables + docs** from one YAML/JSON source of truth (error codes, command IDs, register maps). Integrate in CMake with `add_custom_command(OUTPUT generated.h COMMAND python3 ...)` so the header regenerates when the input changes (chapter 19).

### 5.4 From SVD to register maps

`cmsis-svd` (Python package) parses SVD files: generate documentation or checks (`pip install cmsis-svd`; API varies by version).

---

## 6. Analyzing and plotting data

### 6.1 Capture to CSV, then analyze

```python
import pandas as pd
df = pd.read_csv("log.csv", names=["t_ms", "raw", "filtered"])
print(df.describe())                         # count, mean, std, min, max
df["raw"].plot(); df["filtered"].plot()
import matplotlib.pyplot as plt; plt.xlabel("sample"); plt.legend(); plt.show()
```

### 6.2 Spectrum

```python
import numpy as np
fs = 1000.0
x = df["raw"].to_numpy(dtype=float)
x = x - x.mean()
w = np.hanning(len(x))
spec = np.abs(np.fft.rfft(x * w)) / (len(x) / 4)          # amplitude scaling for a Hann window
freqs = np.fft.rfftfreq(len(x), 1 / fs)
plt.semilogy(freqs, spec); plt.xlabel("Hz"); plt.show()
```

### 6.3 Live plot of serial data

`matplotlib.animation.FuncAnimation` with a deque of the last N points works for slow data; `pyqtgraph` handles kHz rates; **Serial Studio** or the Arduino Serial Plotter style tools need no code. For step-response tuning (chapter 13) log `setpoint, measurement, output` as CSV at a fixed rate and plot offline.

### 6.4 Jupyter notebooks

`pip install jupyterlab`: use notebooks as a **lab notebook**: capture, plot, fit, and keep the narrative and conclusions with the code.

---

## 7. Automating the toolchain

### 7.1 Running tools

```python
import subprocess

def run(cmd, **kw):
    print("$", " ".join(map(str, cmd)))
    return subprocess.run(cmd, check=True, text=True, **kw)

run(["cmake", "--build", "build", "-j8"])
r = run(["arm-none-eabi-size", "build/blink.elf"], capture_output=True)
print(r.stdout)
```

`check=True` raises on failure; use `capture_output=True` to read output; `timeout=` for hangs; pass **lists** (not shell strings) to avoid quoting problems.

### 7.2 Talking to OpenOCD over its TCL RPC port

```python
import socket

class OpenOCD:
    TERM = b"\x1a"
    def __init__(self, host="127.0.0.1", port=6666):
        self.s = socket.create_connection((host, port), timeout=5)
    def cmd(self, c: str) -> str:
        self.s.sendall(c.encode() + self.TERM)
        data = b""
        while not data.endswith(self.TERM):
            data += self.s.recv(4096)
        return data[:-1].decode()

ocd = OpenOCD()
ocd.cmd("reset halt")
print(ocd.cmd("mdw 0xE000ED28"))             # CFSR
ocd.cmd("resume")
```

(Start OpenOCD first; the TCL port is 6666 by default, 50001 when started by Cortex-Debug.) Use it to script flashing, register dumps and post-mortem collection (chapter 4).

### 7.3 Debug probes from Python

| Tool | Notes |
|---|---|
| **pyOCD** | Python debug/flash library and CLI for CMSIS-DAP and ST-LINK probes; target support comes from CMSIS packs: `pyocd list --targets`, `pyocd flash -t <target> file.hex`; verify support for your STM32F746 |
| `pygdbmi` | Drive GDB through GDB/MI from Python |
| **GDB Python API** | Scripts inside gdb (chapter 4 `cfsr` command) |
| `st-flash`/`openocd` via `subprocess` | Simple and reliable |
| **probe-rs** (Rust, chapter 20) | Flash/RTT, with Python wrappers emerging |

### 7.4 Instruments (SCPI)

```python
import pyvisa
rm = pyvisa.ResourceManager("@py")
dev = rm.open_resource("TCPIP0::192.168.1.80::INSTR")
print(dev.query("*IDN?"))
dev.write("VOLT 3.3"); dev.write("OUTP ON")
print(dev.query("MEAS:CURR?"))
```

Power supplies, multimeters and scopes with SCPI over USB/LAN let you automate power-cycling, brown-out sweeps, and current logging.

### 7.5 `make`/CMake helper scripts

A single `tools/dev.py` (or a `justfile`/Makefile) with subcommands `build`, `flash`, `test`, `monitor`, `size` keeps the team's workflow consistent (use `argparse` subparsers).

---

## 8. Testing with Python

### 8.1 Hardware-in-the-loop with pytest (chapter 14)

```python
# tests/test_device.py
import pytest, serial

@pytest.fixture(scope="session")
def dut():
    with serial.Serial("/dev/ttyACM0", 115200, timeout=1) as s:
        s.reset_input_buffer()
        yield s

def ask(s, text):
    s.write((text + "\r\n").encode())
    return s.readline().decode().strip()

def test_ping(dut):
    assert ask(dut, "ping") == "pong"

@pytest.mark.parametrize("n", [0, 1, 255])
def test_echo_values(dut, n):
    assert ask(dut, f"echo {n}") == str(n)
```

Run: `pytest -v --junitxml=report.xml`. Useful plugins: `pytest-timeout`, `pytest-html`, `pytest-repeat`. Make the port configurable (`--port` option via `conftest.py` or an environment variable).

### 8.2 Testing C code from Python (`ctypes`/`cffi`)

Build the firmware's **pure logic** as a shared library on the PC and compare with a Python reference (golden tests):

```bash
gcc -shared -fPIC -O1 -g -o libdsp.so src/dsp/filter.c src/common/crc.c
```

```python
import ctypes, numpy as np

lib = ctypes.CDLL("./libdsp.so")
lib.crc16_ccitt.argtypes = [ctypes.c_char_p, ctypes.c_size_t]
lib.crc16_ccitt.restype = ctypes.c_uint16

import binascii, os
for _ in range(1000):
    data = os.urandom(np.random.randint(0, 200))
    assert lib.crc16_ccitt(data, len(data)) == binascii.crc_hqx(data, 0xFFFF)
```

Combine with **Hypothesis** for property-based testing:

```python
from hypothesis import given, strategies as st

@given(st.binary(max_size=300))
def test_crc_matches_reference(data):
    assert lib.crc16_ccitt(data, len(data)) == binascii.crc_hqx(data, 0xFFFF)
```

`cffi` is an alternative that reads C declarations. Remember the host `int`/`long` sizes differ from the target (use fixed-width types).

### 8.3 Simulating devices

Write a Python **mock device** (an I2C/serial device model) behind a `socat` pty pair to test PC software without hardware, or to simulate a sensor feeding your firmware over UART in HIL tests.

---

## 9. Packaging and sharing tools

- A `pyproject.toml` with `[project.scripts]` makes your tools installable commands (`pip install -e .`): `mytool flash --port /dev/ttyACM0`.
- Lint/format: `ruff` (fast linter/formatter), `black`, `mypy` for type checking; add them to `pre-commit` and CI (chapter 14).
- Document usage in the repo `README` and `--help`.
- Keep Python tool **versions pinned** and tested in CI (a small matrix of Python versions if you distribute them).
- For GUI tools: `tkinter` (built in), `PyQt/PySide`, `dearpygui`, or web UIs with `flask`/`fastapi` + a JS plot library; for quick dashboards, `streamlit`.

---

## 10. MicroPython and CircuitPython (on the MCU)

MicroPython runs a Python interpreter on the microcontroller (REPL over USB/UART, interactive hardware access). It has ports for STM32 (including **NUCLEO_F746ZG** as a listed board: verify in the MicroPython board list). Strengths: instant experimentation, readable drivers, scripting; weaknesses: slower, more RAM/Flash, non-deterministic timing (garbage collection), less control.

```python
# MicroPython on a Nucleo (example style)
from machine import Pin, ADC
import time
led = Pin("B7", Pin.OUT)
while True:
    led.toggle(); time.sleep_ms(500)
```

Use it to **prototype** sensors, protocols and logic quickly, then port to C/C++; or for non-critical scripting alongside C code. Tools: `mpremote`, `rshell`, `thonny`.

---

## 11. A reusable toolbox: what to build

| Tool | Value |
|---|---|
| `serial_log.py` | Timestamped capture with filters and file rotation |
| `frame_client.py` | Speaks the device protocol (request/response, retries) |
| `fw_size.py` | Flash/RAM report with per-file attribution and CI budget gate |
| `make_image.py` | Header/CRC/signature for update images (chapter 16) |
| `gen_tables.py` | Filters, LUTs, enums from one source of truth |
| `hil/` pytest suite | Automated tests on the board |
| `capture_plot.ipynb` | Experiments and tuning notebooks |
| `ocd.py` | OpenOCD scripting (post-mortem dump, flash, reset) |
| `power_sweep.py` | SCPI-driven brown-out/current sweeps |
| `pre-commit` setup | Formatting, linting, hooks |

---

## 12. Exercises

1. **Port discovery**: list serial ports and select the Nucleo's VCP by VID `0x0483`; open it and print boot messages.
2. **Logger**: timestamped logger with a rotating file and a `--grep` filter; test it with the board printing counters.
3. **Protocol client**: implement the COBS+CRC16 client of chapter 11 with retries; add a test with a fake serial object (`io.BytesIO`/mock).
4. **Reference CRC**: implement CRC-16/CCITT, CRC-16/MODBUS and the STM32 CRC32 in Python; verify against the check strings and against your C code (via `ctypes`).
5. **Size report**: parse `blink.elf` with pyelftools, print the top 20 functions and the totals, and fail if Flash exceeds a budget.
6. **Table generator**: generate a sine table and a thermistor table from Python into `generated/tables.h`, wired into CMake so it regenerates when the script changes.
7. **Filter design**: design a Butterworth biquad, generate C coefficients, and compare the step response of the C code (via `ctypes`) with SciPy.
8. **Plot**: capture ADC samples from the board, compute the spectrum, and identify mains hum (50 Hz) or switching noise.
9. **PID tuning data**: log setpoint/measurement/output at 100 Hz, plot the step response, and estimate overshoot and settling time in code.
10. **HIL suite**: write a pytest suite for your firmware's CLI (ping, version, ADC range, echo, error handling), with a `--port` option and JUnit output.
11. **OpenOCD script**: use the TCL port to halt the target, dump CFSR and the stack frame, resume, and print a decoded fault report.
12. **Property-based test**: Hypothesis test that `cobs.decode(cobs.encode(x)) == x` for C and Python implementations.
13. **Mock device**: a Python process simulating a sensor over a `socat` pty pair; point your logger at it.
14. **Instrument control**: if you have a SCPI power supply, script a sweep of VDD from 3.6 V to 2.6 V while logging the board's reset behavior.
15. **MicroPython** (optional): flash MicroPython on the Nucleo, read the button and ADC from the REPL, and compare the effort with C.

---

## 13. Cheat sheet

```
venv:      python3 -m venv .venv && source .venv/bin/activate && pip install -r requirements.txt
serial:    serial.Serial(port, baud, timeout=...) ; read_until(b"\0") ; reset_input_buffer()
binary:    struct.pack("<BBH", ...) ; int.from_bytes(b, "little", signed=True)
crc:       zlib.crc32 (CRC-32) ; binascii.crc_hqx(data, 0xFFFF) (CCITT-FALSE)
elf:       pyelftools ELFFile → symtab, sections ; arm-none-eabi-size / nm
codegen:   scipy.signal.butter/firwin + f-strings/Jinja2 → generated headers
test:      pytest (+ fixtures, parametrize, timeouts) ; ctypes/cffi to test C logic ; hypothesis
automate:  subprocess.run(list, check=True) ; OpenOCD TCL port 6666 ; pyocd ; pyvisa for SCPI
rules:     monotonic time for timeouts, exit codes, logging, pinned requirements, no hard-coded ports
```

---

## 14. Where this leads

- **Testing** (chapter 14): pytest HIL, golden tests, CI pipelines.
- **Control and DSP** (chapter 13): design and verification workflow.
- **Bootloader/security** (chapter 16): image and signing tools, update clients.
- **Rust** (chapter 20): `probe-rs` and `defmt` as another toolchain for the same workflows.

## References

- pyserial: <https://pyserial.readthedocs.io>; pytest: <https://docs.pytest.org>; Hypothesis: <https://hypothesis.readthedocs.io>
- pyelftools: <https://github.com/eliben/pyelftools>; pyOCD: <https://pyocd.io>
- NumPy, SciPy (`scipy.signal`), pandas, matplotlib documentation
- Python `struct`, `subprocess`, `argparse`, `logging` standard-library docs
- OpenOCD manual: TCL RPC server; MicroPython documentation: <https://docs.micropython.org>
- *Python for Data Analysis* (Wes McKinney); *Automate the Boring Stuff with Python*
