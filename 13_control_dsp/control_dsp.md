# 13. Control and Digital Signal Processing on a Cortex-M7

Target: STM32F746ZG (single-precision FPU, DSP instructions), C, with Python for design and checking. Prerequisites: chapter 5 (C), chapter 7 (ADC, timers, DMA), chapter 8 (testing seams), chapter 12 (periodic tasks).

**Verification note.** Formulas are standard; code is illustrative and **has not been compiled or run on your board**. Test every algorithm on the PC against Python first (section 11), and verify CMSIS-DSP function names and types against the library version you use.

---

## 1. Why this matters

Firmware spends its life reading sensors, filtering noise, deciding, and driving actuators. The pieces are:

```
sensor ─► ADC ─► sampling ─► filtering ─► estimation ─► control law ─► PWM/DAC ─► actuator
                  (timing!)   (noise)     (state)       (PID etc.)
```

Most failures here are **timing** (jittery sample period), **numeric** (overflow, quantization, wrong units) and **tuning**, not syntax.

---

## 2. Sampling

### 2.1 Nyquist and aliasing

A signal must be sampled at **more than twice its highest frequency** (`fs > 2 * fmax`). Frequencies above `fs/2` **fold back (alias)** into the measured band and cannot be removed afterwards. So:

- Put an **analog low-pass (anti-alias) filter** before the ADC with cutoff below `fs/2` (a simple RC: `fc = 1 / (2 π R C)`, chapter 10).
- Choose `fs` 5-10x the signal bandwidth for practical filtering and control.
- **Oversample** then decimate: sampling fast, averaging N samples, adds about `0.5 * log2(N)` effective bits (noise must be present and roughly random).

### 2.2 Quantization and resolution

For an N-bit ADC: step `LSB = VREF / 2^N` (3.3 V / 4096 = 0.81 mV for 12 bits); ideal SNR `≈ 6.02 N + 1.76 dB` (74 dB at 12 bits); real ADCs give around 10-11 effective bits (datasheet: ENOB).

### 2.3 Fixed, jitter-free sampling

For filters and control the **sample period must be constant**. Do not sample "when the main loop gets around to it". Options:

| Method | Jitter | Notes |
|---|---|---|
| Timer-triggered ADC (TRGO) + DMA | Hardware-exact | Best: sampling not affected by software (chapter 7, section 9.6) |
| Timer interrupt starts the ADC | Interrupt latency | Good enough for kHz rates |
| RTOS periodic task (`xTaskDelayUntil`) | Tick resolution + scheduling | Fine for tens of Hz |
| Main loop | Large and variable | Avoid for control |

Measure jitter with a GPIO toggle at the sampling instant and a logic analyzer.

---

## 3. Numbers: floating point vs fixed point

On the F746 (single-precision FPU, 1-cycle-ish multiply-accumulate with `VFMA`), **`float` is fast and simplest**: use it unless you have a reason not to. Fixed-point is for cores without an FPU, very deterministic arithmetic, big arrays (memory), or when DSP SIMD instructions pay off.

### 3.1 Float pitfalls

- **Single precision has 24 bits of mantissa** (about 7 decimal digits): accumulating many small numbers into a big one loses precision (use Kahan summation, or double on the PC).
- Never use `==` on floats; compare with a tolerance.
- Avoid `double` accidentally (chapter 5): `0.5` is a `double`; write `0.5f`.
- Beware NaN/Inf propagation: check inputs, divisions, `logf` of non-positive numbers.
- Do not accumulate **time** in float seconds for long runs (precision decays); use integer ticks.

### 3.2 Fixed-point formats (Qm.n)

A Qm.n number stores `value * 2^n` in an integer with `m` integer bits (sign included) and `n` fractional bits. Common: **Q15** (`int16_t`, range -1 to +0.99997), **Q31** (`int32_t`), Q16.16 (`int32_t`).

```c
typedef int32_t q16_16_t;
#define Q16(x)        ((q16_16_t)((x) * 65536.0f))
#define Q16_TO_F(q)   ((float)(q) / 65536.0f)

static inline q16_16_t q16_mul(q16_16_t a, q16_16_t b) { return (q16_16_t)(((int64_t)a * b) >> 16); }
static inline q16_16_t q16_div(q16_16_t a, q16_16_t b) { return (q16_16_t)(((int64_t)a << 16) / b); }
```

Rules:

1. Multiply in a **wider type** (`int64_t` for Q16.16, `int32_t` for Q15), then shift back.
2. **Saturate** instead of wrapping on overflow (`__SSAT`/`__USAT` intrinsics in CMSIS, or `qadd`).
3. **Round** instead of truncating when it matters: add `1 << (n-1)` before the shift.
4. Keep track of the format of every variable in its **name or type** (`speed_q15`, `gain_q16`).
5. Right shift of negative numbers is arithmetic on GCC (implementation-defined).
6. Division is slow and may overflow (`INT_MIN / -1`): avoid in loops, use reciprocal multiplication.

### 3.3 Saturating add and DSP intrinsics

```c
#include "cmsis_gcc.h"          /* via stm32f7xx.h */
int32_t sat_add(int32_t a, int32_t b)   { return __QADD(a, b); }              /* single QADD instruction */
int16_t clamp16(int32_t x)              { return (int16_t)__SSAT(x, 16); }
```

The M7 (ARMv7E-M) has SIMD-style instructions for 16-bit pairs (`SMLAD`, `SADD16`, ...) that CMSIS-DSP uses internally.

---

## 4. Filters

### 4.1 Moving average

```c
#define MA_N 16u                                /* power of two: division becomes a shift */

typedef struct { int32_t buf[MA_N]; uint32_t idx; int32_t sum; } ma_t;

int32_t ma_update(ma_t *f, int32_t x)
{
    f->sum += x - f->buf[f->idx];               /* running sum: O(1) per sample */
    f->buf[f->idx] = x;
    f->idx = (f->idx + 1u) & (MA_N - 1u);
    return f->sum / (int32_t)MA_N;              /* or >> 4 for non-negative values */
}
```

Properties: removes random noise by `sqrt(N)`, but adds a delay of `(N-1)/2` samples and has a poor frequency response (notches at multiples of `fs/N`). Initialize `buf` to the first sample to avoid a start-up transient.

### 4.2 Exponential moving average (first-order IIR low-pass)

```c
/* y[n] = y[n-1] + alpha * (x[n] - y[n-1]),   alpha in (0, 1] */
static inline float ema(float y, float x, float alpha) { return y + alpha * (x - y); }

/* integer version, alpha = 1/2^k: tiny and fast */
static inline int32_t ema_k(int32_t y, int32_t x, unsigned k) { return y + ((x - y) >> k); }
```

Cutoff: `alpha = 1 - exp(-2π fc / fs)` (or `≈ 2π fc / fs` for `fc << fs`); time constant `tau = Ts / alpha`. One state variable, no buffer: the default choice for "smooth this reading".

### 4.3 Median filter

Removes **spikes/outliers** (bad I2C reads, glitches) without blurring edges: take the median of the last 3 or 5 samples. Combine: median (spikes) then EMA (noise).

### 4.4 FIR filters

```
y[n] = Σ_{k=0}^{M-1} h[k] x[n-k]
```

Linear phase (constant delay `(M-1)/2` samples), always stable, cost `M` multiply-accumulates per sample. Design with Python (section 11):

```python
from scipy.signal import firwin
h = firwin(numtaps=31, cutoff=50, fs=1000)      # 50 Hz low-pass at 1 kHz sampling
```

C (direct form with a circular buffer):

```c
typedef struct { const float *h; float *x; uint32_t m, idx; } fir_t;

float fir_update(fir_t *f, float in)
{
    f->x[f->idx] = in;
    float acc = 0.0f;
    uint32_t i = f->idx;
    for (uint32_t k = 0; k < f->m; k++) {
        acc += f->h[k] * f->x[i];
        i = (i == 0u) ? f->m - 1u : i - 1u;
    }
    f->idx = (f->idx + 1u == f->m) ? 0u : f->idx + 1u;
    return acc;
}
```

CMSIS-DSP provides optimized `arm_fir_f32` (block processing).

### 4.5 IIR biquad (second-order section)

Efficient filters with few coefficients (Butterworth, Chebyshev, notch). **Direct Form II Transposed**:

```c
typedef struct { float b0, b1, b2, a1, a2; float z1, z2; } biquad_t;

float biquad_update(biquad_t *q, float x)
{
    float y = q->b0 * x + q->z1;
    q->z1 = q->b1 * x - q->a1 * y + q->z2;
    q->z2 = q->b2 * x - q->a2 * y;
    return y;
}
```

(`a0` normalized to 1; sign convention of `a1`, `a2` depends on the design tool: **check it** with a step response against Python.) Higher orders are **cascades of biquads** (never one high-order polynomial: numerically unstable). Design with `scipy.signal.butter(order, fc, fs=fs, output='sos')`. CMSIS: `arm_biquad_cascade_df2T_f32`. Watch stability (poles inside the unit circle) and fixed-point coefficient quantization.

### 4.6 Other useful techniques

| Technique | Use |
|---|---|
| Hysteresis (Schmitt) | Avoid chattering around a threshold |
| Dead band | Ignore small changes |
| Rate limiter (slew) | Limit change per sample |
| Debounce (counter or time) | Buttons, noisy digital inputs |
| Calibration (offset/gain, two-point) | `y = (x - x0) * (y1 - y0) / (x1 - x0) + y0` |
| Lookup table + interpolation | Nonlinear sensors (thermistors, NTC, curves) |
| Peak detection, zero crossing | Pulses, frequency |

### 4.7 Lookup table with linear interpolation

```c
typedef struct { float x, y; } point_t;               /* x increasing */

float lut_interp(const point_t *t, size_t n, float x)
{
    if (x <= t[0].x)     { return t[0].y; }
    if (x >= t[n - 1].x) { return t[n - 1].y; }
    size_t i = 1;
    while (t[i].x < x) { i++; }
    float f = (x - t[i - 1].x) / (t[i].x - t[i - 1].x);
    return t[i - 1].y + f * (t[i].y - t[i - 1].y);
}
```

Generate tables with Python and write them to a header (chapter 17). Store them `static const` (Flash).

### 4.8 Thermistor (NTC) with the beta equation

```
1/T = 1/T0 + (1/B) * ln(R / R0)        (T in kelvin; R0 resistance at T0 = 298.15 K; B from the datasheet)
```

```c
float ntc_celsius(float r_ohm, float r0, float t0_k, float beta)
{
    float inv_t = (1.0f / t0_k) + (logf(r_ohm / r0) / beta);
    return (1.0f / inv_t) - 273.15f;
}
/* resistance from a divider: NTC to ground, fixed Rtop to VREF:  R = Rtop * raw / (4095 - raw) */
```

Mind self-heating (excitation current), tolerance, and ADC range (choose `Rtop` near `R0`).

---

## 5. Frequency-domain tools

### 5.1 FFT basics

An N-point FFT of a real signal sampled at `fs` gives `N/2` useful bins spaced `fs/N` apart (frequency resolution). To resolve two nearby tones you need a longer window. Always apply a **window** (Hann, Hamming) to reduce spectral leakage, and scale the magnitudes.

```c
#include "arm_math.h"                         /* CMSIS-DSP */
#define N 1024

static float32_t in[N], spec[N], mag[N / 2];
static arm_rfft_fast_instance_f32 rfft;

void fft_init(void) { arm_rfft_fast_init_f32(&rfft, N); }

void fft_run(void)                            /* in[] holds N samples, already windowed */
{
    arm_rfft_fast_f32(&rfft, in, spec, 0);              /* 0 = forward transform */
    arm_cmplx_mag_f32(spec, mag, N / 2);                /* magnitude per bin */
    uint32_t idx; float32_t peak;
    arm_max_f32(&mag[1], N / 2 - 1, &peak, &idx);      /* skip DC (bin 0) */
    float f_peak = (float)(idx + 1) * FS_HZ / (float)N;
}
```

(The packed output format of `arm_rfft_fast_f32` has the Nyquist term in the second element of the first pair: check the CMSIS-DSP documentation for the exact layout of your version.) Uses: vibration analysis, tone detection, checking noise sources, spectrum display.

### 5.2 Goertzel algorithm

Detects **one specific frequency** much more cheaply than a full FFT (DTMF tones, a known interference line): `O(N)` per frequency with two state variables.

---

## 6. CMSIS-DSP

A library of optimized signal-processing functions (filters, FFT, matrices, statistics, fast math, transforms) in floating point, Q31, Q15, Q7. The M7's FPU and DSP instructions give large speedups over naive C.

| Area | Examples |
|---|---|
| Basic math | `arm_add_f32`, `arm_mult_f32`, `arm_scale_f32`, `arm_dot_prod_f32` |
| Fast math | `arm_sin_f32`, `arm_cos_f32`, `arm_sqrt_f32`, `arm_sin_cos_f32` |
| Filtering | `arm_fir_f32`, `arm_biquad_cascade_df2T_f32`, `arm_lms_f32` |
| Transforms | `arm_rfft_fast_f32`, `arm_cfft_f32`, `arm_dct4_f32` |
| Statistics | `arm_mean_f32`, `arm_rms_f32`, `arm_std_f32`, `arm_max_f32`, `arm_min_f32` |
| Matrix | `arm_mat_add_f32`, `arm_mat_mult_f32`, `arm_mat_inverse_f32` |
| Controller | `arm_pid_f32`, Clarke/Park transforms for motor control |
| Conversion | `arm_float_to_q15`, `arm_q15_to_float`, etc. |

Using it with CMake: the library lives in the `CMSIS-DSP` repository with CMake support; build it as a static library with your MCU flags, define `ARM_MATH_LOOPUNROLL` and the core (`-DARM_MATH_CM7`) as needed, and include its headers (`arm_math.h`). Check the version's README for the exact options. Use **block processing** (arrays of samples) to benefit from the optimizations.

When to use CMSIS-DSP vs hand-written code: simple filters (EMA, moving average) are better hand-written (clear and tiny); FFT, big FIR/IIR, matrix work benefit from the library.

---

## 7. Control theory essentials

### 7.1 Open loop, closed loop

- **Open loop**: command the actuator by a model (a servo's commanded angle, a fixed PWM): simple, no correction for disturbances.
- **Closed loop (feedback)**: measure the output, compare to the setpoint, correct the actuator. Needs a **sensor, a controller, an actuator**, and stable tuning.

```
setpoint ──►(+)── error ──► controller ──► actuator ──► plant (process) ──┬─► output
             ▲ (-)                                                         │
             └──────────────────── sensor ◄────────────────────────────────┘
```

Key properties: **rise time**, **overshoot**, **settling time**, **steady-state error**, **stability**, **disturbance rejection**, and **robustness** to plant variations.

### 7.2 Simple controllers

| Controller | Behavior |
|---|---|
| **On/off (bang-bang) with hysteresis** | Thermostat: simple, constant oscillation around the setpoint within the hysteresis band |
| **Proportional (P)** | `u = Kp * e`; leaves a steady-state error for plants without integration |
| **PI** | Removes steady-state error; the most common in practice |
| **PID** | Adds a derivative term to damp and anticipate |
| **Feed-forward + feedback** | Compute the expected command from the setpoint, let feedback correct the rest |
| **Cascade** | Fast inner loop (current) inside a slower outer loop (speed, position) |
| **State feedback, observers (Kalman), MPC** | Advanced model-based control |

### 7.3 PID in discrete time

```
u[n] = Kp e[n] + Ki Σ e[k] Ts + Kd (e[n]-e[n-1]) / Ts
```

Practical implementation with the improvements that matter:

```c
typedef struct {
    float kp, ki, kd;
    float out_min, out_max;
    float integral;
    float prev_meas;
    float d_filt;            /* low-passed derivative */
    float d_alpha;           /* derivative filter coefficient (0..1], 1 = no filtering */
} pid_ctrl_t;

static float clampf(float v, float lo, float hi) { return (v < lo) ? lo : (v > hi) ? hi : v; }

float pid_update(pid_ctrl_t *p, float setpoint, float meas, float dt)
{
    float err = setpoint - meas;

    /* derivative on the MEASUREMENT (no kick on setpoint changes), filtered */
    float d_raw = -(meas - p->prev_meas) / dt;
    p->d_filt  += p->d_alpha * (d_raw - p->d_filt);
    p->prev_meas = meas;

    float u_unsat = p->kp * err + p->integral + p->kd * p->d_filt;
    float u = clampf(u_unsat, p->out_min, p->out_max);

    /* anti-windup by conditional integration: do not integrate while saturated in the direction of the error */
    bool saturating_high = (u_unsat > p->out_max) && (err > 0.0f);
    bool saturating_low  = (u_unsat < p->out_min) && (err < 0.0f);
    if (!saturating_high && !saturating_low) {
        p->integral += p->ki * err * dt;
        p->integral  = clampf(p->integral, p->out_min, p->out_max);
    }
    return u;
}
```

Important details:

1. **Constant `dt`**: run the loop from a timer or periodic task and pass the nominal `dt` (jitter degrades the derivative and integral).
2. **Anti-windup**: without it, the integral grows while the actuator is saturated and causes huge overshoot afterwards.
3. **Derivative on measurement + filter**: setpoint steps would otherwise create a derivative spike, and noise gets amplified by `Kd`.
4. **Output limits** and **rate limits** protect the actuator.
5. **Units**: keep gains in clear units (output units per input unit; `ki` per second; `kd` seconds).
6. **Bumpless transfer** when switching manual/auto: initialize `integral` so that `u` equals the current output.
7. **Dead time and filtering** on the measurement add phase lag: keep it as low as the noise allows.
8. **Sample rate**: 10-20x the closed-loop bandwidth at least.

### 7.4 Tuning

| Method | Procedure |
|---|---|
| **Manual** | Set `Ki = Kd = 0`; raise `Kp` until it oscillates, take about half; add `Ki` to remove steady-state error (reduce if overshoot); add `Kd` only if needed to damp |
| **Ziegler-Nichols (closed loop)** | Find ultimate gain `Ku` and oscillation period `Tu` with P only; PID: `Kp = 0.6 Ku`, `Ti = Tu / 2`, `Td = Tu / 8` (aggressive; often needs softening) |
| **Step-response (reaction curve)** | Apply an open-loop step, measure dead time `L`, time constant `T`, gain; use tuning rules (Cohen-Coon, SIMC) |
| **Model-based** | Identify a model with Python (`scipy`), simulate the PID, tune in simulation, then verify on hardware |

Record **step responses on the real system** over UART (setpoint, measurement, output at a fixed rate) and plot them in Python: tuning without data is guesswork (chapter 17).

### 7.5 Stability and safety

- A loop with too much gain or delay oscillates and may **diverge**: always **limit** outputs and add **independent safety** (over-temperature cutoff, current limit, watchdog; chapter 12).
- Define behavior on **sensor failure** (open/short, stuck value, out of range): fall to a safe output.
- Heating or motion systems: hardware limit as a second line of defense (thermal fuse, current limiter).

---

## 8. State estimation

### 8.1 Complementary filter (IMU angle)

Gyroscope: smooth but drifts when integrated. Accelerometer: noisy short-term but correct on average. Combine:

```c
/* angle in degrees; gyro in deg/s; acc_angle computed from the accelerometer (atan2f(ay, az) * 180/pi) */
angle = alpha * (angle + gyro * dt) + (1.0f - alpha) * acc_angle;     /* alpha ≈ 0.98 for dt = 10 ms */
```

Choose `alpha = tau / (tau + dt)` with `tau` (e.g. 0.5 s) the time constant where you switch trust from gyro to accelerometer. Simple, cheap, good enough for many balancing or tilt applications.

### 8.2 Kalman filter (concept)

Optimal recursive estimator for linear systems with Gaussian noise: **predict** the state with the model, **update** with each measurement weighted by their uncertainties. Parameters: process noise `Q`, measurement noise `R`. Start with a 1-D version on the PC, then use CMSIS matrix functions or hand-coded small matrices. Extended/Unscented variants for nonlinear systems.

### 8.3 Sensor fusion practicalities

Timestamp every sample; handle different rates; calibrate biases and scale factors; check sensor ranges; log raw data so you can replay and tune offline.

---

## 9. Motor control and actuation basics

| Topic | Notes |
|---|---|
| Brushed DC motor | H-bridge, PWM duty = average voltage; current sense for torque; back-EMF; flyback paths |
| PWM generation | Advanced timers TIM1/TIM8: **complementary outputs with dead-time** (prevents shoot-through), **break input** (hardware emergency stop), center-aligned mode, update events synchronized with ADC triggering |
| Encoder | Timer **encoder mode** counts quadrature pulses in hardware (TIM2/3/4/5) |
| Speed loop | Measure encoder counts per interval (M method) or period between pulses (T method) |
| Position loop | Outer loop on the speed loop (cascade); trajectory profiles (trapezoidal) for smooth motion |
| Current loop | Fastest inner loop (kHz+), ADC sampled synchronously with PWM |
| BLDC/PMSM | Trapezoidal (6-step, Hall sensors) or **FOC** (field-oriented control: Clarke/Park transforms, PI current loops, SVPWM): ST's motor control SDK and CMSIS-DSP provide building blocks |
| Servo (RC) | 50 Hz PWM, 1-2 ms pulse |
| Stepper | Step/direction drivers, microstepping, acceleration ramps |

Safety first: enable the **break input**, current limits and timeouts before testing with a real motor; test with a current-limited bench supply.

---

## 10. Timing structure of a control application

```
Timer ISR / ADC DMA complete (hard-timed)
     │ posts event / notification
     ▼
control task or ISR:  read sample ─► filter ─► PID ─► write PWM duty
     │
     ├─ supervision (limits, faults) ─► safe state
     └─ telemetry ring buffer ─► low-priority task prints over UART
```

- Do the **time-critical** path (sample, compute, actuate) in a timer interrupt or in a highest-priority RTOS task triggered by the timer. Keep the rest (logging, UI, communication) low priority.
- Measure **latency** (sample to actuation) and **jitter** with a GPIO and a logic analyzer; measure **execution time** with DWT (chapter 3).
- Do not call `printf` in the control path: push data to a ring buffer.
- On the F7, the data cache and flash wait states make execution time vary; place hot code/data in **ITCM/DTCM** (chapter 19) and use the cycle counter to confirm.

---

## 11. Designing and verifying in Python first

A workflow that avoids hours of debugging on the board:

1. **Prototype** the algorithm in Python (NumPy/SciPy): design the filter (`firwin`, `butter`), simulate the plant and PID (a first-order model with dead time is a good start).
2. **Generate coefficient headers** automatically (chapter 17):

```python
from scipy.signal import butter
sos = butter(2, 20, fs=1000, output="sos")           # one biquad: [b0 b1 b2 a0 a1 a2]
b0, b1, b2, a0, a1, a2 = sos[0]
print(f"static const biquad_t lp20 = {{ {b0:.8f}f, {b1:.8f}f, {b2:.8f}f, {a1:.8f}f, {a2:.8f}f, 0, 0 }};")
```

(The `a1`, `a2` sign convention matches the biquad above when `a0 = 1`: check by comparing step responses.)

3. **Test the C code on the PC** against the Python reference with the same input vectors (golden tests, chapter 14; `ctypes` or file-based comparison). Check numerical differences stay within tolerance, particularly in fixed point.
4. **Replay real data**: log raw ADC samples from the board over UART, run your C filter on the PC with them, and plot input and output.
5. Only then run it on the board, and compare execution time and output with the PC.

---

## 12. Exercises

1. **Aliasing**: sample a 900 Hz sine at 1 kHz on the PC (and with the ADC and a function generator on the board); see the alias at 100 Hz; add an RC anti-alias filter and re-measure.
2. **Noise reduction**: log 1000 ADC samples of a grounded input and of a potentiometer; compute standard deviation; compare moving average (N = 4, 16, 64) and EMA.
3. **Filter design**: design a 2nd-order Butterworth low-pass (fc = 10 Hz at fs = 200 Hz) in Python, implement `biquad_update`, and compare the step response with SciPy.
4. **Fixed point**: implement the same filter in Q15; measure the error against float for random inputs; find overflow cases.
5. **Median + EMA**: inject random spikes into a signal and show the pipeline removes them.
6. **Thermistor**: implement the beta equation, compare with a lookup table with interpolation, and check both against a reference thermometer.
7. **FFT**: measure the spectrum of a tone generated by a PWM + RC filter or a DAC; find the peak frequency and the leakage effect with and without a Hann window.
8. **PID simulation**: simulate a first-order plant with dead time in Python; implement the PID of 7.3; test anti-windup (saturate the output) and derivative kick.
9. **PID on hardware**: control the brightness of an LED measured by a light sensor, or the temperature of a small heater (with a hard limit); log step responses and tune.
10. **Control timing**: run the loop from a timer interrupt at 1 kHz; measure jitter and execution time with GPIO and DWT; move the code to ITCM and compare.
11. **Complementary filter**: with an IMU on I2C, compare accelerometer-only, gyro-only and fused angle plots.
12. **Encoder speed**: use a timer in encoder mode (or simulate with two PWM channels in quadrature) and measure speed with the M and T methods.
13. **CMSIS-DSP**: build the library into your CMake project and compare cycle counts of a hand-written FIR against `arm_fir_f32` for different tap counts.
14. **Golden tests**: run your C filter on the PC through `ctypes` with the same vectors as Python; automate the comparison in CI.

---

## 13. Cheat sheet

```
Nyquist            fs > 2 fmax ; anti-alias RC: fc = 1/(2πRC)
ADC LSB            VREF / 2^N ; SNR ≈ 6.02N + 1.76 dB
EMA                y += α (x - y) ;  α = 1 - exp(-2π fc/fs) ≈ 2π fc/fs
Moving avg delay   (N-1)/2 samples ; noise ↓ √N
FIR delay          (M-1)/2 samples
FFT resolution     fs / N ; leakage → window
PID                u = Kp e + Ki ∫e dt + Kd de/dt ; D on measurement + filter ; anti-windup ; constant dt
Q15                int16_t, value = x / 32768 ; multiply in int32_t then >> 15 ; saturate
NTC beta           1/T = 1/T0 + ln(R/R0)/B
Complementary      θ = α(θ + ω dt) + (1-α) θ_acc
```

| Problem | Likely cause |
|---|---|
| Noise gets worse after the filter | Aliasing happened before the ADC; filter in the wrong place |
| PID oscillates | Gain too high, delay too large, derivative on noisy signal, unstable sample time |
| PID overshoots after a long saturation | No anti-windup |
| Output jumps on setpoint change | Derivative on error (kick) |
| Fixed-point results wrong | Overflow, truncation, wrong Q format |
| Filter output slightly different on the board and on the PC | Float rounding, coefficient quantization, different order of operations |
| Control loop timing erratic | Software-triggered sampling, cache/flash effects, preemption by logging |

---

## 14. Where this leads

- **Low power** (chapter 15): lower sampling rates, sleeping between samples.
- **Testing** (chapter 14): golden tests, property-based tests of algorithms.
- **Python tooling** (chapter 17): design, plotting, coefficient generation, replay.
- **FreeRTOS** (chapter 12): periodic control tasks, priorities and jitter.
- **Assembly** (chapter 18): reading the instructions behind `VFMA`, `SMLAD`, and saturating arithmetic.

## References

- *Digital Signal Processing: A Practical Guide for Engineers and Scientists*, Steven W. Smith (free online: <https://www.dspguide.com>)
- *Understanding Digital Signal Processing*, Richard Lyons
- *Feedback Control of Dynamic Systems*, Franklin, Powell, Emami-Naeini; Åström and Murray, *Feedback Systems* (free: <https://fbswiki.org>)
- *PID Without a PhD*, Tim Wescott
- CMSIS-DSP documentation: <https://arm-software.github.io/CMSIS-DSP/>
- ST motor control SDK documentation (for FOC)