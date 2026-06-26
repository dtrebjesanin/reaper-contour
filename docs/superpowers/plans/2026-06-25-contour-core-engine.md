# Contour Core Engine (Phase 1, Part 1) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Build the pure, Reaper-independent modulation + point-reduction engine (`shapes`, `lfo`, `reduce`) that both the Generate and Reduce tools will sit on, fully covered by headless unit tests.

**Architecture:** Three pure Lua modules under `core/`, each a table of functions with no side effects and no Reaper API calls. `shapes` produces a bipolar waveform value for a normalized phase; `lfo` composes shapes across a time span into a list of `{time, value}` points; `reduce` thins a point list via vertical-distance Ramer–Douglas–Peucker. A tiny dependency-free test harness runs every module under a standalone Lua interpreter.

**Tech Stack:** Lua 5.4 (matches Reaper's embedded ReaScript Lua). No external libraries in shipped code or tests.

## Global Constraints

- Language: **Lua 5.4** (Reaper's ReaScript interpreter). Avoid 5.1/5.2-only idioms.
- The `core/` modules MUST have **zero Reaper API calls** and **zero external dependencies** — they run under plain `lua`.
- Every function in `core/` is **pure**: same inputs → same outputs, no globals mutated, no I/O.
- Waveform contract: `shapes.value(...)` returns a value in **`[-1, 1]`** (bipolar). Amplitude/baseline scaling and value-range clamping happen later in the Reaper layer (Part 2), NOT here.
- Point contract: a point is the table **`{ time = <number>, value = <number> }`**. A span is **`{ t0 = <number>, t1 = <number> }`** in seconds. A value range is **`{ vmin = <number>, vmax = <number> }`**.
- Tests run from the **repo root** with `lua tests/<file>.lua`; exit code 0 = all pass.
- Conventional-commit messages; commit after each task's tests pass.

---

## File Structure

| File | Responsibility |
|---|---|
| `core/shapes.lua` | Pure waveform math: base shapes + per-cycle modifiers + seeded random. Returns `[-1,1]`. |
| `core/lfo.lua` | Compose `shapes` across a span into `{time,value}` points: rate model, phase, amplitude/baseline, fades, quantize, density. |
| `core/reduce.lua` | Vertical-distance RDP thinning of a point list; `thin()` maps a 0–1 amount to an epsilon via value range. |
| `tests/harness.lua` | ~25-line dependency-free test runner (`test`, `eq`, `almost`, `truthy`, `run`). |
| `tests/test_shapes.lua` | Unit tests for `core/shapes.lua`. |
| `tests/test_lfo.lua` | Unit tests for `core/lfo.lua`. |
| `tests/test_reduce.lua` | Unit tests for `core/reduce.lua`. |

**Out of scope for this plan (later parts):** `core/context.lua`, `core/target.lua`, `core/presets.lua`, the entire `ui/` layer, and `contour.lua`. Those are Reaper-bound and planned in Part 2/3.

---

### Task 1: Test harness + interpreter

**Files:**
- Create: `tests/harness.lua`
- Create: `tests/test_smoke.lua`

**Interfaces:**
- Consumes: nothing.
- Produces: a test module returned by `require("harness")` with:
  - `test(name, fn)` — register a test
  - `eq(actual, expected, msg?)` — assert equality
  - `almost(actual, expected, tol?, msg?)` — assert float closeness (default tol `1e-9`)
  - `truthy(v, msg?)` — assert truthy
  - `run()` — run all registered tests, print results, `os.exit(0|1)`

- [ ] **Step 1: Verify a Lua interpreter is available**

Run: `lua -v`
Expected: prints something like `Lua 5.4.x`. If "command not found": install one — on Windows `scoop install lua` (or download Lua 5.4 and add to PATH), then re-run `lua -v` and confirm it prints a 5.x version before continuing.

- [ ] **Step 2: Write the harness**

Create `tests/harness.lua`:

```lua
-- tests/harness.lua — minimal dependency-free test runner
local M = { tests = {} }

function M.test(name, fn) M.tests[#M.tests + 1] = { name = name, fn = fn } end

local function fmt(x) return tostring(x) end

function M.eq(a, b, msg)
  if a ~= b then error((msg or "") .. " expected " .. fmt(b) .. " got " .. fmt(a), 2) end
end

function M.almost(a, b, tol, msg)
  tol = tol or 1e-9
  if type(a) ~= "number" then error((msg or "") .. " expected number got " .. fmt(a), 2) end
  if math.abs(a - b) > tol then
    error((msg or "") .. " expected ~" .. fmt(b) .. " got " .. fmt(a), 2)
  end
end

function M.truthy(v, msg)
  if not v then error((msg or "") .. " expected truthy value", 2) end
end

function M.run()
  local pass, fail = 0, 0
  for _, t in ipairs(M.tests) do
    local ok, err = pcall(t.fn)
    if ok then
      pass = pass + 1
      print("PASS " .. t.name)
    else
      fail = fail + 1
      print("FAIL " .. t.name .. "\n   " .. tostring(err))
    end
  end
  print(string.format("\n%d passed, %d failed", pass, fail))
  os.exit(fail == 0 and 0 or 1)
end

return M
```

- [ ] **Step 3: Write a smoke test**

Create `tests/test_smoke.lua`:

```lua
package.path = package.path .. ";./?.lua;./tests/?.lua"
local h = require("harness")

h.test("harness eq works", function() h.eq(1 + 1, 2) end)
h.test("harness almost works", function() h.almost(0.1 + 0.2, 0.3, 1e-9) end)

h.run()
```

- [ ] **Step 4: Run the smoke test**

Run: `lua tests/test_smoke.lua`
Expected:
```
PASS harness eq works
PASS harness almost works

2 passed, 0 failed
```

- [ ] **Step 5: Commit**

```bash
git add tests/harness.lua tests/test_smoke.lua
git commit -m "test: add dependency-free Lua test harness"
```

---

### Task 2: shapes — base waveforms

**Files:**
- Create: `core/shapes.lua`
- Test: `tests/test_shapes.lua`

**Interfaces:**
- Consumes: nothing.
- Produces:
  - `shapes.value(shape, t, p) -> number in [-1,1]` where `shape` ∈ `"sine"|"square"|"triangle"|"sawup"|"sawdown"|"none"` (more behavior added in Tasks 3–4), `t` is phase-in-cycle in `[0,1)`, `p` is a params table (unused fields ignored).
  - `shapes.base` — table of raw shape functions (internal, exposed for testing).

- [ ] **Step 1: Write the failing test**

Create `tests/test_shapes.lua`:

```lua
package.path = package.path .. ";./?.lua;./tests/?.lua"
local h = require("harness")
local shapes = require("core.shapes")

-- sine: 0 -> 0, .25 -> 1, .5 -> 0, .75 -> -1
h.test("sine quarters", function()
  h.almost(shapes.value("sine", 0.0, {}), 0)
  h.almost(shapes.value("sine", 0.25, {}), 1)
  h.almost(shapes.value("sine", 0.5, {}), 0, 1e-9)
  h.almost(shapes.value("sine", 0.75, {}), -1)
end)

-- square (default 50% duty): first half +1, second half -1
h.test("square halves", function()
  h.eq(shapes.value("square", 0.1, {}), 1)
  h.eq(shapes.value("square", 0.6, {}), -1)
end)

-- triangle: 0->0, .25->1, .5->0, .75->-1
h.test("triangle peaks", function()
  h.almost(shapes.value("triangle", 0.0, {}), 0)
  h.almost(shapes.value("triangle", 0.25, {}), 1)
  h.almost(shapes.value("triangle", 0.5, {}), 0)
  h.almost(shapes.value("triangle", 0.75, {}), -1)
end)

-- saws span -1..1
h.test("saws", function()
  h.almost(shapes.value("sawup", 0.0, {}), -1)
  h.almost(shapes.value("sawup", 1.0 - 1e-12, {}), 1, 1e-6)
  h.almost(shapes.value("sawdown", 0.0, {}), 1)
end)

h.test("none is flat zero", function()
  h.eq(shapes.value("none", 0.3, {}), 0)
end)

h.run()
```

- [ ] **Step 2: Run test to verify it fails**

Run: `lua tests/test_shapes.lua`
Expected: FAIL — `module 'core.shapes' not found`.

- [ ] **Step 3: Write minimal implementation**

Create `core/shapes.lua`:

```lua
-- core/shapes.lua — pure waveform math. Returns values in [-1, 1]. No Reaper, no I/O.
local M = {}
local pi, sin, abs, floor = math.pi, math.sin, math.abs, math.floor

local function clamp(x, lo, hi)
  if x < lo then return lo elseif x > hi then return hi else return x end
end
local function frac(x) return x - floor(x) end

-- Base shapes: t in [0,1), returns [-1,1].
local base = {}
function base.sine(t) return sin(2 * pi * t) end
function base.square(t, pw) pw = pw or 0.5; return (t < pw) and 1 or -1 end
function base.triangle(t)
  if t < 0.25 then return 4 * t
  elseif t < 0.75 then return 2 - 4 * t
  else return 4 * t - 4 end
end
function base.sawup(t) return 2 * t - 1 end
function base.sawdown(t) return 1 - 2 * t end
function base.none(_) return 0 end
M.base = base

local dispatch = {
  sine = base.sine, square = base.square, triangle = base.triangle,
  sawup = base.sawup, sawdown = base.sawdown, none = base.none,
}

function M.value(shape, t, p)
  p = p or {}
  local tt = frac(t)
  local fn = dispatch[shape] or base.sine
  local v
  if shape == "square" then v = fn(tt, p.pulseWidth) else v = fn(tt) end
  return clamp(v, -1, 1)
end

M._clamp = clamp
M._frac = frac
return M
```

- [ ] **Step 4: Run test to verify it passes**

Run: `lua tests/test_shapes.lua`
Expected: all `PASS`, `5 passed, 0 failed`.

- [ ] **Step 5: Commit**

```bash
git add core/shapes.lua tests/test_shapes.lua
git commit -m "feat(core): add base LFO shapes"
```

---

### Task 3: shapes — modifiers (pulse width, freq skew, amp skew, tilt)

**Files:**
- Modify: `core/shapes.lua`
- Modify: `tests/test_shapes.lua`

**Interfaces:**
- Consumes: `shapes.value` from Task 2.
- Produces: `shapes.value(shape, t, p)` now honors these `p` fields, each defaulting to the no-op value:
  - `p.pulseWidth` (number in `(0,1)`, default `0.5`) — square duty cycle.
  - `p.freqSkew` (number in `[-1,1]`, default `0`) — bends time within the cycle; `0` = no change.
  - `p.ampSkew` (number in `[-1,1]`, default `0`) — power curve on output magnitude; `0` = no change.
  - `p.tilt` (number in `[-1,1]`, default `0`) — blends a linear ramp across the cycle; `0` = no change.

- [ ] **Step 1: Write the failing tests**

Append to `tests/test_shapes.lua` (before the final `h.run()` line — move `h.run()` to the end):

```lua
-- pulse width changes square duty
h.test("pulse width duty", function()
  h.eq(shapes.value("square", 0.2, { pulseWidth = 0.25 }), 1)
  h.eq(shapes.value("square", 0.3, { pulseWidth = 0.25 }), -1)
end)

-- identity: every modifier at its default leaves sine unchanged
h.test("modifier identities", function()
  local p = { freqSkew = 0, ampSkew = 0, tilt = 0 }
  h.almost(shapes.value("sine", 0.25, p), 1)
  h.almost(shapes.value("sine", 0.5, p), 0, 1e-9)
end)

-- freqSkew > 0 slows the start: at t=0.25 the sine has advanced less than 1
h.test("freqSkew bends time", function()
  local v = shapes.value("sine", 0.25, { freqSkew = 0.5 })
  h.truthy(v < 1 - 1e-6, "expected peak not yet reached")
end)

-- ampSkew > 0 pushes magnitude toward the extreme (|v| grows for mid values)
h.test("ampSkew sharpens", function()
  local plain = shapes.value("sine", 0.125, {})            -- ~0.707
  local skewed = shapes.value("sine", 0.125, { ampSkew = 0.5 })
  h.truthy(skewed > plain, "expected larger magnitude with positive ampSkew")
end)

-- tilt adds a linear component; at full tilt the cycle ends are pulled apart
h.test("tilt ramps", function()
  local a = shapes.value("none", 0.0, { tilt = 1 })   -- baseline 0, full tilt -> -1 at start
  local b = shapes.value("none", 1.0 - 1e-9, { tilt = 1 }) -- -> ~+1 at end
  h.almost(a, -1, 1e-6)
  h.almost(b, 1, 1e-3)
end)
```

Ensure the file ends with a single `h.run()`.

- [ ] **Step 2: Run test to verify it fails**

Run: `lua tests/test_shapes.lua`
Expected: FAIL on `freqSkew bends time` / `ampSkew sharpens` / `tilt ramps` (modifiers not applied yet).

- [ ] **Step 3: Write the implementation**

In `core/shapes.lua`, add the modifier helpers above `M.value` and apply them inside `M.value`. Replace the existing `M.value` with:

```lua
local function applyFreqSkew(t, skew)
  if skew == 0 then return t end
  local k = 2 ^ (skew * 2)        -- skew>0 => exponent>1 => slow start, fast end
  return t ^ k
end

local function applyAmpSkew(v, skew)
  if skew == 0 then return v end
  local g = 2 ^ (-skew * 2)       -- skew>0 => g<1 => |v|^g larger => sharper
  local s = (v < 0) and -1 or 1
  return s * (abs(v) ^ g)
end

local function applyTilt(v, t, tilt)
  if tilt == 0 then return v end
  return v * (1 - abs(tilt)) + tilt * (2 * t - 1)
end

function M.value(shape, t, p)
  p = p or {}
  local tt = frac(t)
  tt = applyFreqSkew(tt, p.freqSkew or 0)
  local fn = dispatch[shape] or base.sine
  local v
  if shape == "square" then v = fn(tt, p.pulseWidth) else v = fn(tt) end
  v = applyAmpSkew(v, p.ampSkew or 0)
  v = applyTilt(v, tt, p.tilt or 0)
  return clamp(v, -1, 1)
end
```

- [ ] **Step 4: Run test to verify it passes**

Run: `lua tests/test_shapes.lua`
Expected: all `PASS`.

- [ ] **Step 5: Commit**

```bash
git add core/shapes.lua tests/test_shapes.lua
git commit -m "feat(core): add shape modifiers (pulse width, freq/amp skew, tilt)"
```

---

### Task 4: shapes — smoothing + seeded random

**Files:**
- Modify: `core/shapes.lua`
- Modify: `tests/test_shapes.lua`

**Interfaces:**
- Consumes: `shapes.value` from Task 3.
- Produces:
  - `p.smooth` (number in `[0,1]`, default `0`) on `shapes.value` — blends the hard shape toward a sine of the same phase; `0` = unchanged, `1` = full sine.
  - `shapes.randomAt(seed, index) -> number in [-1,1]` — deterministic per-(seed,index) value for sample-and-hold; same args → same result, different `index` → (almost always) different result.

- [ ] **Step 1: Write the failing tests**

Append to `tests/test_shapes.lua` (before `h.run()`):

```lua
-- smooth=0 leaves the triangle unchanged; smooth=1 makes it equal sine
h.test("smooth blends to sine", function()
  h.almost(shapes.value("triangle", 0.1, { smooth = 0 }), 0.4)        -- 4*0.1
  h.almost(shapes.value("triangle", 0.1, { smooth = 1 }), math.sin(2 * math.pi * 0.1))
end)

-- randomAt is deterministic and in range
h.test("randomAt deterministic in range", function()
  local a = shapes.randomAt(42, 3)
  local b = shapes.randomAt(42, 3)
  h.eq(a, b)
  h.truthy(a >= -1 and a <= 1, "in [-1,1]")
end)

-- different cycle index generally differs
h.test("randomAt varies by index", function()
  h.truthy(shapes.randomAt(42, 0) ~= shapes.randomAt(42, 1), "expected different values")
end)
```

- [ ] **Step 2: Run test to verify it fails**

Run: `lua tests/test_shapes.lua`
Expected: FAIL on smoothing (`smooth` not applied) and `randomAt` (nil function).

- [ ] **Step 3: Write the implementation**

In `core/shapes.lua`, add a smoothing helper and apply it in `M.value` (right after computing `v` from the base function, before `applyAmpSkew`):

```lua
local function applySmooth(v, vSine, smooth)
  if smooth <= 0 then return v end
  if smooth >= 1 then return vSine end
  return v * (1 - smooth) + vSine * smooth
end
```

Update the body of `M.value` so the shape value is smoothed toward the sine of the same (post-freq-skew) phase:

```lua
function M.value(shape, t, p)
  p = p or {}
  local tt = frac(t)
  tt = applyFreqSkew(tt, p.freqSkew or 0)
  local fn = dispatch[shape] or base.sine
  local v
  if shape == "square" then v = fn(tt, p.pulseWidth) else v = fn(tt) end
  v = applySmooth(v, base.sine(tt), p.smooth or 0)
  v = applyAmpSkew(v, p.ampSkew or 0)
  v = applyTilt(v, tt, p.tilt or 0)
  return clamp(v, -1, 1)
end
```

Add the deterministic random near the bottom of the file (before `return M`):

```lua
-- Deterministic LCG-based PRNG; returns a closure yielding (0,1).
function M.prng(seed)
  local state = (seed or 0) % 2147483647
  if state <= 0 then state = state + 2147483646 end
  return function()
    state = (state * 16807) % 2147483647
    return state / 2147483647
  end
end

-- Deterministic value in [-1,1] for a (seed, cycle index) pair (sample & hold).
function M.randomAt(seed, index)
  local r = M.prng((seed or 0) + index * 2789 + 1)
  r()                 -- discard first for mixing
  return r() * 2 - 1
end
```

- [ ] **Step 4: Run test to verify it passes**

Run: `lua tests/test_shapes.lua`
Expected: all `PASS`.

- [ ] **Step 5: Commit**

```bash
git add core/shapes.lua tests/test_shapes.lua
git commit -m "feat(core): add shape smoothing and seeded sample-and-hold"
```

---

### Task 5: lfo — rate model + pure helpers

**Files:**
- Create: `core/lfo.lua`
- Test: `tests/test_lfo.lua`

**Interfaces:**
- Consumes: nothing yet (uses only its own helpers).
- Produces:
  - `lfo.cycleLength(rate, spanLen) -> seconds`, where `rate` is one of:
    - `{ mode = "free", cycles = <n> }` → `spanLen / cycles`
    - `{ mode = "hz", hz = <n> }` → `1 / hz`
    - `{ mode = "sync", cycleSec = <n> }` → `cycleSec` (precomputed by the Reaper layer from tempo + division)
  - `lfo.quantizeBipolar(v, steps) -> number` — snaps `v∈[-1,1]` to `steps` levels; `steps < 2` or `nil` → unchanged.
  - `lfo.fadeDepth(rel, fadeIn, fadeOut) -> number in [0,1]` — depth multiplier at relative position `rel∈[0,1]`.

- [ ] **Step 1: Write the failing test**

Create `tests/test_lfo.lua`:

```lua
package.path = package.path .. ";./?.lua;./tests/?.lua"
local h = require("harness")
local lfo = require("core.lfo")

h.test("cycleLength free", function()
  h.almost(lfo.cycleLength({ mode = "free", cycles = 4 }, 8.0), 2.0)
end)
h.test("cycleLength hz", function()
  h.almost(lfo.cycleLength({ mode = "hz", hz = 2 }, 8.0), 0.5)
end)
h.test("cycleLength sync passthrough", function()
  h.almost(lfo.cycleLength({ mode = "sync", cycleSec = 0.75 }, 8.0), 0.75)
end)

h.test("quantize off is identity", function()
  h.almost(lfo.quantizeBipolar(0.3, nil), 0.3)
  h.almost(lfo.quantizeBipolar(0.3, 1), 0.3)
end)
h.test("quantize 2 steps snaps to -1/+1", function()
  h.eq(lfo.quantizeBipolar(0.2, 2), 1)
  h.eq(lfo.quantizeBipolar(-0.2, 2), -1)
end)
h.test("quantize 3 steps has a zero", function()
  h.almost(lfo.quantizeBipolar(0.1, 3), 0)
end)

h.test("fadeDepth no fades is full", function()
  h.eq(lfo.fadeDepth(0.0, 0, 0), 1)
  h.eq(lfo.fadeDepth(0.5, 0, 0), 1)
end)
h.test("fadeDepth ramps in and out", function()
  h.almost(lfo.fadeDepth(0.0, 0.2, 0), 0)     -- start of a fade-in
  h.almost(lfo.fadeDepth(0.1, 0.2, 0), 0.5)   -- halfway through fade-in
  h.almost(lfo.fadeDepth(1.0, 0, 0.2), 0)     -- end of a fade-out
end)

h.run()
```

- [ ] **Step 2: Run test to verify it fails**

Run: `lua tests/test_lfo.lua`
Expected: FAIL — `module 'core.lfo' not found`.

- [ ] **Step 3: Write minimal implementation**

Create `core/lfo.lua`:

```lua
-- core/lfo.lua — pure composition of shapes into {time,value} points. No Reaper, no I/O.
local M = {}
local floor, min, max = math.floor, math.min, math.max

function M.cycleLength(rate, spanLen)
  if rate.mode == "free" then
    return spanLen / max(1e-9, rate.cycles)
  elseif rate.mode == "hz" then
    return 1 / max(1e-9, rate.hz)
  elseif rate.mode == "sync" then
    return rate.cycleSec
  end
  error("unknown rate mode: " .. tostring(rate.mode))
end

function M.quantizeBipolar(v, steps)
  if not steps or steps < 2 then return v end
  local level = floor(((v + 1) / 2) * (steps - 1) + 0.5)
  return (level / (steps - 1)) * 2 - 1
end

function M.fadeDepth(rel, fadeIn, fadeOut)
  local d = 1
  if fadeIn and fadeIn > 0 and rel < fadeIn then d = min(d, rel / fadeIn) end
  if fadeOut and fadeOut > 0 and rel > 1 - fadeOut then d = min(d, (1 - rel) / fadeOut) end
  if d < 0 then d = 0 end
  return d
end

return M
```

- [ ] **Step 4: Run test to verify it passes**

Run: `lua tests/test_lfo.lua`
Expected: all `PASS`.

- [ ] **Step 5: Commit**

```bash
git add core/lfo.lua tests/test_lfo.lua
git commit -m "feat(core): add LFO rate model, quantize, and fade helpers"
```

---

### Task 6: lfo — generate point list

**Files:**
- Modify: `core/lfo.lua`
- Modify: `tests/test_lfo.lua`

**Interfaces:**
- Consumes: `shapes.value`, `shapes.randomAt` (Task 4); `lfo.cycleLength`, `lfo.quantizeBipolar`, `lfo.fadeDepth` (Task 5).
- Produces: `lfo.generate(span, params) -> { {time, value}, ... }` where:
  - `span = { t0, t1 }` seconds.
  - `params` fields (all optional except `shape` and `rate`): `shape` (string), `rate` (rate table), `phase` (cycles, default `0`), `amplitude` (default `1`), `baseline` (default `0`), `density` (points per cycle, default `16`), `seed` (default `0`), `quantizeSteps`, `fadeIn`, `fadeOut`, plus the shape-modifier fields passed through to `shapes.value`.
  - Points are emitted from `t0` to `t1` inclusive; the last point's `time` equals `t1`.
  - For `shape == "random"`, all points within one cycle share one held value (sample & hold).

- [ ] **Step 1: Write the failing tests**

Append to `tests/test_lfo.lua` (before `h.run()`):

```lua
local shapes = require("core.shapes")

-- A sine over [0,1] with 1 cycle, baseline 0, amplitude 1, density 4 -> 5 points (0..1 inclusive)
h.test("generate point count and endpoints", function()
  local pts = lfo.generate({ t0 = 0, t1 = 1 }, {
    shape = "sine", rate = { mode = "free", cycles = 1 },
    amplitude = 1, baseline = 0, density = 4,
  })
  h.eq(#pts, 5)
  h.almost(pts[1].time, 0)
  h.almost(pts[#pts].time, 1)
  h.almost(pts[1].value, 0, 1e-9)         -- sine at phase 0
  h.almost(pts[2].value, 1, 1e-9)         -- quarter cycle -> peak
end)

-- baseline + amplitude scaling
h.test("generate scales by amplitude and baseline", function()
  local pts = lfo.generate({ t0 = 0, t1 = 1 }, {
    shape = "sine", rate = { mode = "free", cycles = 1 },
    amplitude = 50, baseline = 64, density = 4,
  })
  h.almost(pts[2].value, 114, 1e-6)       -- 64 + 50*1
end)

-- random shape holds one value across the whole single cycle
h.test("generate random is stepped per cycle", function()
  local pts = lfo.generate({ t0 = 0, t1 = 1 }, {
    shape = "random", rate = { mode = "free", cycles = 1 },
    amplitude = 1, baseline = 0, density = 4, seed = 7,
  })
  for i = 2, #pts - 1 do h.almost(pts[i].value, pts[1].value) end
end)

-- fade-in ramps the first point's depth to zero
h.test("generate honors fade in", function()
  local pts = lfo.generate({ t0 = 0, t1 = 1 }, {
    shape = "sine", rate = { mode = "free", cycles = 1 },
    amplitude = 1, baseline = 0, density = 4, fadeIn = 0.5,
  })
  h.almost(pts[1].value, 0, 1e-9)         -- depth 0 at the very start
end)

-- empty/zero-length span yields no points
h.test("generate empty span", function()
  local pts = lfo.generate({ t0 = 2, t1 = 2 }, {
    shape = "sine", rate = { mode = "free", cycles = 1 },
  })
  h.eq(#pts, 0)
end)
```

- [ ] **Step 2: Run test to verify it fails**

Run: `lua tests/test_lfo.lua`
Expected: FAIL — `attempt to call a nil value (field 'generate')`.

- [ ] **Step 3: Write the implementation**

Add to `core/lfo.lua` (above `return M`), and add the `require` at the top of the file:

At the very top, under the `local floor...` line, add:

```lua
local shapes = require("core.shapes")
```

Then the function:

```lua
function M.generate(span, params)
  local t0, t1 = span.t0, span.t1
  local spanLen = t1 - t0
  if spanLen <= 0 then return {} end

  local p = params
  local cycleLen = M.cycleLength(p.rate, spanLen)
  local ppc = max(1, p.density or 16)
  local dt = cycleLen / ppc
  local n = max(1, floor(spanLen / dt + 0.5))

  local amp = p.amplitude or 1
  local baseV = p.baseline or 0
  local seed = p.seed or 0
  local phase = p.phase or 0

  local pts = {}
  for i = 0, n do
    local T = t0 + i * dt
    if T > t1 then T = t1 end
    local rel = (T - t0) / spanLen
    local cyclePos = (T - t0) / cycleLen + phase
    local cyc = floor(cyclePos)
    local tInCycle = cyclePos - cyc

    local sv
    if p.shape == "random" then
      sv = shapes.randomAt(seed, cyc)
    else
      sv = shapes.value(p.shape, tInCycle, p)
    end
    sv = M.quantizeBipolar(sv, p.quantizeSteps)
    local depth = M.fadeDepth(rel, p.fadeIn, p.fadeOut)

    pts[#pts + 1] = { time = T, value = baseV + amp * sv * depth }
    if T >= t1 then break end
  end
  return pts
end
```

- [ ] **Step 4: Run test to verify it passes**

Run: `lua tests/test_lfo.lua`
Expected: all `PASS`.

- [ ] **Step 5: Commit**

```bash
git add core/lfo.lua tests/test_lfo.lua
git commit -m "feat(core): generate LFO point lists across a span"
```

---

### Task 7: reduce — RDP thinning

**Files:**
- Create: `core/reduce.lua`
- Test: `tests/test_reduce.lua`

**Interfaces:**
- Consumes: nothing (operates on plain point lists).
- Produces:
  - `reduce.rdp(points, eps) -> points` — vertical-distance Ramer–Douglas–Peucker. `points` is `{ {time,value}, ... }` sorted by `time`; `eps` is in value units. Always keeps the first and last point. `≤ 2` points returned unchanged.
  - `reduce.thin(points, amount, valueRange) -> points` — maps `amount∈[0,1]` to `eps = amount * (valueRange.vmax - valueRange.vmin)` and calls `rdp`.

- [ ] **Step 1: Write the failing test**

Create `tests/test_reduce.lua`:

```lua
package.path = package.path .. ";./?.lua;./tests/?.lua"
local h = require("harness")
local reduce = require("core.reduce")

local function line(n)            -- n collinear points from (0,0) to (n-1, n-1)
  local t = {}
  for i = 0, n - 1 do t[#t + 1] = { time = i, value = i } end
  return t
end

h.test("rdp keeps endpoints only for a straight line", function()
  local out = reduce.rdp(line(6), 0.001)
  h.eq(#out, 2)
  h.eq(out[1].time, 0)
  h.eq(out[2].time, 5)
end)

h.test("rdp keeps a spike above epsilon", function()
  local pts = { { time = 0, value = 0 }, { time = 1, value = 0 },
                { time = 2, value = 10 },                       -- spike
                { time = 3, value = 0 }, { time = 4, value = 0 } }
  local out = reduce.rdp(pts, 1.0)
  h.eq(#out, 3)                   -- endpoints + spike
  h.eq(out[2].time, 2)
end)

h.test("rdp drops a spike below epsilon", function()
  local pts = { { time = 0, value = 0 }, { time = 1, value = 0.1 },
                { time = 2, value = 0 } }
  local out = reduce.rdp(pts, 1.0)
  h.eq(#out, 2)
end)

h.test("rdp passes through tiny lists", function()
  h.eq(#reduce.rdp({}, 1), 0)
  h.eq(#reduce.rdp({ { time = 0, value = 0 } }, 1), 1)
  h.eq(#reduce.rdp({ { time = 0, value = 0 }, { time = 1, value = 9 } }, 1), 2)
end)

h.test("thin maps amount through value range", function()
  -- range 0..10; amount 0.2 -> eps 2.0, so the value-1 spike (below 2) is dropped
  local pts = { { time = 0, value = 0 }, { time = 1, value = 1 }, { time = 2, value = 0 } }
  local out = reduce.thin(pts, 0.2, { vmin = 0, vmax = 10 })
  h.eq(#out, 2)
end)

h.run()
```

- [ ] **Step 2: Run test to verify it fails**

Run: `lua tests/test_reduce.lua`
Expected: FAIL — `module 'core.reduce' not found`.

- [ ] **Step 3: Write minimal implementation**

Create `core/reduce.lua`:

```lua
-- core/reduce.lua — pure vertical-distance Ramer–Douglas–Peucker thinning. No Reaper, no I/O.
local M = {}
local abs = math.abs

function M.rdp(points, eps)
  local n = #points
  if n <= 2 then
    local out = {}
    for i = 1, n do out[i] = points[i] end
    return out
  end

  local first, last = points[1], points[n]
  local dx = last.time - first.time
  local maxd, idx = -1, 0
  for i = 2, n - 1 do
    local p = points[i]
    local yline
    if dx == 0 then
      yline = first.value
    else
      yline = first.value + (last.value - first.value) * (p.time - first.time) / dx
    end
    local d = abs(p.value - yline)
    if d > maxd then maxd = d; idx = i end
  end

  if maxd > eps then
    local left = {}
    for i = 1, idx do left[i] = points[i] end
    local right = {}
    for i = idx, n do right[#right + 1] = points[i] end
    local rl = M.rdp(left, eps)
    local rr = M.rdp(right, eps)
    local out = {}
    for i = 1, #rl do out[i] = rl[i] end
    for i = 2, #rr do out[#out + 1] = rr[i] end   -- skip the shared junction point
    return out
  else
    return { first, last }
  end
end

function M.thin(points, amount, valueRange)
  local span = (valueRange and (valueRange.vmax - valueRange.vmin)) or 1
  local eps = (amount or 0) * span
  return M.rdp(points, eps)
end

return M
```

- [ ] **Step 4: Run test to verify it passes**

Run: `lua tests/test_reduce.lua`
Expected: all `PASS`.

- [ ] **Step 5: Run the whole suite and commit**

Run all three module suites:
```bash
lua tests/test_shapes.lua && lua tests/test_lfo.lua && lua tests/test_reduce.lua
```
Expected: each ends with `N passed, 0 failed`.

```bash
git add core/reduce.lua tests/test_reduce.lua
git commit -m "feat(core): add RDP point reduction"
```

---

## Plan Self-Review

**Spec coverage (against §6.2 and §7–§8 of the design):**
- `shapes.lua` (shape math, smoothing, seeded random) → Tasks 2–4. ✓
- `lfo.lua` (rate model Sync/Free/Hz, amplitude/baseline, fades, quantize, density, phase) → Tasks 5–6. ✓
- `reduce.lua` (RDP, tolerance normalized to value range) → Task 7. ✓
- Headless unit-test strategy (§13) → Task 1 harness + per-module suites. ✓
- **Deferred to later plans (not gaps in this plan):** `context.lua`, `target.lua` (Reaper-bound), `presets.lua`, all `ui/`, AI-tab properties, live/undo wiring. These need Reaper and are Part 2/3.

**Placeholder scan:** No "TBD"/"handle edge cases"/"similar to" — every code step shows complete code; edge cases (empty span, ≤2 points, quantize off, no fades) have explicit tests and handling. ✓

**Type consistency:** Point is `{time, value}` everywhere (Tasks 6–7). Span is `{t0,t1}`; value range is `{vmin,vmax}` (Task 7 matches the Global Constraints block). `rate` tables use `mode` + (`cycles`|`hz`|`cycleSec`) consistently across Tasks 5–6. `shapes.value(shape, t, p)` signature identical in Tasks 2–4 and as called in Task 6. ✓

---

## Notes for Part 2 (so interfaces line up)

- The Reaper layer builds `rate.cycleSec` for Sync mode from project tempo + the chosen division (straight/dotted/triplet) before calling `lfo.generate`.
- `target:valueRange()` feeds both the clamp (applied in the Reaper layer after `generate`) and `reduce.thin`'s `valueRange`.
- `lfo.generate` returns bipolar-scaled values around `baseline`; the Reaper layer clamps to `valueRange` and writes via `target:writePoints`.
