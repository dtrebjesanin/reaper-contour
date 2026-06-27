# LFO Shapes Expansion Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add 8 new Generate LFO shapes (Saw Down, Random S&H, Drift, Pump, AD, Trapezoid, Rectified sine, Sine²) plus Steps/Smooth modifiers and the Saw→Saw Up rename, and fix the Random staircase bug — without breaking the native-CC-LFO match.

**Architecture:** Pure engine (`Contour/core/shapes.lua` waveform math, `Contour/core/lfo.lua` point composition) + `Contour/ui/generate.lua` panel. Simple periodic shapes are `base.*` functions routed through the existing generic ppc sampler; curve shapes (Random, Drift, Pump, AD) get dedicated point-emitters mirroring the existing Square/Saw emitters.

**Tech Stack:** Lua 5.4, ReaImGui. Headless tests run with `lua.exe tests/test_*.lua` (lua.exe is NOT on PATH — full path below).

## Global Constraints

- **Native match is sacred:** ids `sine`/`triangle`/`saw`/`square`/`parametric` keep their exact emitters at default settings. `tests/test_native_match.lua` MUST stay green. Smooth/Steps only divert a native shape to the generic sampler when non-default (`smooth>0` or `quantizeSteps` set) — today's behavior.
- **Internal shape ids never change.** Renames are display labels only (`"saw"` id stays `"saw"`).
- **Local only:** `git commit` after each task; **never `git push`** (no GitHub/ReaPack until the user says so).
- **Waveform functions return `[-1,1]` for phase `t in [0,1)`.**
- **Lua interpreter:** `/c/Users/Dani/AppData/Local/Programs/Lua/bin/lua.exe`.
- **Run from repo root** (`C:\Users\Dani\reaper-lfo-toolkit`); tests already add `;./Contour/?.lua` to `package.path`.

**Run the full suite with:**
```bash
LUA="/c/Users/Dani/AppData/Local/Programs/Lua/bin/lua.exe"; for t in tests/test_*.lua; do "$LUA" "$t" >/dev/null 2>&1 && echo "PASS $t" || echo "FAIL $t"; done
```

---

### Task 1: Fix the Random staircase (`shapes.randomAt`)

**Files:**
- Modify: `Contour/core/shapes.lua` (the `M.randomAt` function, ~lines 75-80)
- Test: `tests/test_shapes.lua`

**Interfaces:**
- Produces: `shapes.randomAt(seed, index) -> number in [-1,1)`, deterministic, decorrelated across consecutive `index`. Same signature as today; only the internals change. Consumed by the Random/Drift emitter (Task 3).

- [ ] **Step 1: Write the failing regression test** — append to `tests/test_shapes.lua` before `h.run()`:

```lua
-- REGRESSION: randomAt used to seed an LCG linearly by index, producing a staircase (near-constant
-- consecutive deltas that wrap). Real noise must NOT march by a constant step and must spread the range.
h.test("randomAt is noise, not a staircase", function()
  local v = {}
  for i = 0, 31 do v[i] = shapes.randomAt(12345, i) end
  local d0 = v[1] - v[0]
  local sameStep = 0
  for i = 1, 31 do if math.abs((v[i] - v[i-1]) - d0) < 0.02 then sameStep = sameStep + 1 end end
  h.truthy(sameStep < 10, "consecutive deltas are ~constant => staircase, not random")
  local lo, hi = 2, -2
  for i = 0, 31 do lo = math.min(lo, v[i]); hi = math.max(hi, v[i]) end
  h.truthy(hi - lo > 1.0, "random values should spread across the range")
end)
```

- [ ] **Step 2: Run it and confirm it FAILS on current code**

Run: `/c/Users/Dani/AppData/Local/Programs/Lua/bin/lua.exe tests/test_shapes.lua`
Expected: FAIL on "randomAt is noise, not a staircase" (sameStep ≈ 31).

- [ ] **Step 3: Replace `M.randomAt` with a splitmix64 hash.** In `Contour/core/shapes.lua`, replace the existing `M.prng`/`M.randomAt` block (the `-- Deterministic LCG...` prng and `-- Deterministic value...` randomAt, ~lines 65-80) with:

```lua
-- Deterministic LCG-based PRNG; returns a closure yielding (0,1). Kept for any external callers.
function M.prng(seed)
  local state = (seed or 0) % 2147483647
  if state <= 0 then state = state + 2147483646 end
  return function()
    state = (state * 16807) % 2147483647
    return state / 2147483647
  end
end

-- splitmix64 finalizer: a strong integer mixing hash. Lua 5.4 integer ops wrap mod 2^64
-- (two's complement), which is exactly what the hash wants.
local function mix64(x)
  x = (x ~ (x >> 30)) * 0xbf58476d1ce4e5b9
  x = (x ~ (x >> 27)) * 0x94d049bb133111eb
  return x ~ (x >> 31)
end

-- Deterministic value in [-1,1) for a (seed, cycle index) pair (sample & hold). Uses a hash so
-- CONSECUTIVE indices decorrelate (the old LCG-seeded-by-index approach produced a staircase).
function M.randomAt(seed, index)
  local h = mix64((seed or 0) * 0x9E3779B97F4A7C15 + (index or 0))
  local u = (h & 0x1FFFFFFFFFFFFF) / 0x20000000000000  -- low 53 bits -> [0,1)
  return u * 2 - 1
end
```

- [ ] **Step 4: Run the test and confirm it PASSES**

Run: `/c/Users/Dani/AppData/Local/Programs/Lua/bin/lua.exe tests/test_shapes.lua`
Expected: PASS, including "randomAt is noise, not a staircase" and the existing randomAt tests.

- [ ] **Step 5: Commit**

```bash
git add Contour/core/shapes.lua tests/test_shapes.lua
git commit -m "fix: randomAt staircase -> splitmix64 hash (real S&H noise)"
```

---

### Task 2: New base waveforms — Trapezoid, Rectified sine, Sine²

**Files:**
- Modify: `Contour/core/shapes.lua` (imports line ~3; `base` table ~lines 11-26; `dispatch` ~lines 33-37; `M.value` ~lines 54-63)
- Test: `tests/test_shapes.lua`

**Interfaces:**
- Produces: ids `trapezoid` (reads `p.edge` in `[0,0.5]`), `rectsine`, `sine2` — usable via `shapes.value(id, t, p)`. Consumed by the generic sampler (already exists) once `lfo.generate` is reached with these ids; the UI (Task 6/7) adds them to the dropdown and passes `p.edge`.

- [ ] **Step 1: Write the failing tests** — append to `tests/test_shapes.lua` before `h.run()`:

```lua
-- Trapezoid: square with linear ramps of width `edge` in [0,0.5]. edge=0 => high first half /
-- low second half; edge=0.5 => symmetric triangle peaking at 0.5.
h.test("trapezoid edges", function()
  h.eq(shapes.value("trapezoid", 0.1, { edge = 0 }), 1)        -- edge 0 => high first half
  h.eq(shapes.value("trapezoid", 0.6, { edge = 0 }), -1)       -- low second half
  h.almost(shapes.value("trapezoid", 0.0, { edge = 0.25 }), -1)-- ramp starts at trough
  h.almost(shapes.value("trapezoid", 0.25, { edge = 0.25 }), 1)-- reached high by end of ramp
  h.almost(shapes.value("trapezoid", 0.5, { edge = 0.5 }), 1)  -- edge 0.5 => triangle peak at 0.5
end)

-- Rectified sine: full-wave |sin| humps. -1 at 0 and 0.5, +1 at 0.25 and 0.75 (two humps/cycle).
h.test("rectified sine humps", function()
  h.almost(shapes.value("rectsine", 0.0, {}), -1)
  h.almost(shapes.value("rectsine", 0.25, {}), 1)
  h.almost(shapes.value("rectsine", 0.5, {}), -1, 1e-9)
  h.almost(shapes.value("rectsine", 0.75, {}), 1)
end)

-- Sine²: same zeros as sine (-cos phasing) but peakier (|value| < |sine| off the extremes).
h.test("sine2 peakier than sine", function()
  h.almost(shapes.value("sine2", 0.0, {}), -1)
  h.almost(shapes.value("sine2", 0.5, {}), 1)
  h.almost(shapes.value("sine2", 0.25, {}), 0, 1e-9)
  local s  = math.abs(shapes.value("sine",  0.1, {}))
  local s2 = math.abs(shapes.value("sine2", 0.1, {}))
  h.truthy(s2 < s, "sine2 should be flatter than sine away from the extremes")
end)
```

- [ ] **Step 2: Run and confirm FAIL**

Run: `/c/Users/Dani/AppData/Local/Programs/Lua/bin/lua.exe tests/test_shapes.lua`
Expected: FAIL (trapezoid/rectsine/sine2 fall back to `base.sine`, so values are wrong).

- [ ] **Step 3: Add the imports and base functions.** In `Contour/core/shapes.lua`:

Change the imports line (~line 3) from:
```lua
local pi, cos, floor = math.pi, math.cos, math.floor
```
to:
```lua
local pi, cos, sin, floor, abs = math.pi, math.cos, math.sin, math.floor, math.abs
```

Add these three functions to the `base` table, right after `function base.sawdown(t) ... end` (~line 24):
```lua
-- Trapezoid: square with linear ramps of width `edge` in [0,0.5]. edge=0 => square (high first
-- half), edge=0.5 => symmetric triangle (peak at 0.5).
function base.trapezoid(t, edge)
  edge = edge or 0.25
  if edge > 0.5 then edge = 0.5 elseif edge < 0 then edge = 0 end
  local x = t - floor(t)
  if edge < 1e-9 then return (x < 0.5) and 1 or -1 end
  if x < edge then return -1 + 2 * (x / edge)
  elseif x < 0.5 then return 1
  elseif x < 0.5 + edge then return 1 - 2 * ((x - 0.5) / edge)
  else return -1 end
end
-- Rectified sine: full-wave rectified humps (|sin|), two positive humps per cycle.
function base.rectsine(t) return 2 * abs(sin(2 * pi * t)) - 1 end
-- Sine squared (sign-preserving): same zeros/extrema as sine, sharper peaks / flatter middle.
function base.sine2(t) local s = -cos(2 * pi * t); return (s < 0 and -1 or 1) * s * s end
```

Add the three ids to the `dispatch` table (~lines 33-37), e.g. extend it to:
```lua
local dispatch = {
  sine = base.sine, square = base.square, triangle = base.triangle,
  saw = base.sawup, parametric = base.sine,
  sawup = base.sawup, sawdown = base.sawdown, none = base.none,
  trapezoid = base.trapezoid, rectsine = base.rectsine, sine2 = base.sine2,
}
```

In `M.value` (~lines 58-59), extend the per-shape argument dispatch so trapezoid receives `p.edge`:
```lua
  if shape == "square" then v = fn(tt, p.pulseWidth)
  elseif shape == "trapezoid" then v = fn(tt, p.edge)
  else v = fn(tt) end
```

- [ ] **Step 4: Run and confirm PASS**

Run: `/c/Users/Dani/AppData/Local/Programs/Lua/bin/lua.exe tests/test_shapes.lua`
Expected: PASS (all new + existing shape tests).

- [ ] **Step 5: Commit**

```bash
git add Contour/core/shapes.lua tests/test_shapes.lua
git commit -m "feat: trapezoid / rectified-sine / sine2 base waveforms"
```

---

### Task 3: Random + Drift emitter (`core/lfo.lua`)

**Files:**
- Modify: `Contour/core/lfo.lua` (add `generateRandom`; add dispatch branches in `M.generate`; remove the now-dead generic `random` branch in `sampleValue`)
- Test: `tests/test_lfo.lua`

**Interfaces:**
- Consumes: `shapes.randomAt(seed, cyc)` (Task 1).
- Produces: `M.generate(span, {shape="random"|"drift", seed=N, rate=..., amplitude=baseHalf, baseline=center, ...})` returns points; each point has `value` and a `shape` field (0=step for random, 2=slow-start for drift).

- [ ] **Step 1: Write the failing tests** — append to `tests/test_lfo.lua` before `h.run()`:

```lua
-- Random (S&H): one value per cycle, held flat (step CC shape 0); values differ non-monotonically.
h.test("random S&H: per-cycle held random values, step shape", function()
  local pts = lfo.generate({ t0 = 0, t1 = 4 },
    { shape = "random", rate = { mode = "free", cycles = 4 }, amplitude = 1, baseline = 0, seed = 7 })
  h.truthy(#pts >= 4, "at least one point per cycle")
  for _, p in ipairs(pts) do h.eq(p.shape, 0, "S&H uses step interpolation") end
  -- not a monotonic ramp: at least one direction change across the cycle values
  local ups, downs = 0, 0
  for i = 2, #pts do if pts[i].value > pts[i-1].value then ups = ups + 1 elseif pts[i].value < pts[i-1].value then downs = downs + 1 end end
  h.truthy(ups > 0 and downs > 0, "random should go both up and down")
end)

-- Drift: same per-cycle random targets as Random, but smooth (slow start/end CC shape 2).
h.test("drift: smooth-interp random (slow shape)", function()
  local r = lfo.generate({ t0 = 0, t1 = 4 },
    { shape = "random", rate = { mode = "free", cycles = 4 }, amplitude = 1, baseline = 0, seed = 7 })
  local d = lfo.generate({ t0 = 0, t1 = 4 },
    { shape = "drift",  rate = { mode = "free", cycles = 4 }, amplitude = 1, baseline = 0, seed = 7 })
  for _, p in ipairs(d) do h.eq(p.shape, 2, "drift uses slow start/end interpolation") end
  -- same seed => the per-cycle anchor values match Random's (first 4 cycle starts)
  for i = 1, 4 do h.almost(d[i].value, r[i].value, 1e-9) end
end)
```

- [ ] **Step 2: Run and confirm FAIL**

Run: `/c/Users/Dani/AppData/Local/Programs/Lua/bin/lua.exe tests/test_lfo.lua`
Expected: FAIL (drift unsupported; random currently dense via generic sampler with no `shape` field).

- [ ] **Step 3: Add `generateRandom` to `Contour/core/lfo.lua`**, right BEFORE `function M.generate(span, params)` (~line 338):

```lua
-- Random (Sample & Hold) and Drift (smooth random) share one emitter: one random value per cycle
-- (shapes.randomAt(seed, cycleIndex)). They differ only in interpolation between cycle values:
-- S&H holds flat (step CC shape 0); Drift eases (slow start/end CC shape 2). Sparse: one anchor per
-- cycle start + an end anchor. Honors amplitude/amp-skew/tilt/fade; freq-skew/swing are not applied
-- (no musical meaning for held random). smoothInterp=true selects Drift.
local function generateRandom(t0, t1, spanLen, totalCycles, p, amp, baseV, ampSkew, tiltOffset, smoothInterp)
  local seed = p.seed or 0
  local N = totalCycles
  local ccShape = smoothInterp and 2 or 0
  local function emit(pts, rel, cyc)
    if rel < 0 then rel = 0 elseif rel > 1 then rel = 1 end
    local depth = M.fadeDepth(rel, p.fadeIn, p.fadeOut)
    local half = ampHalf(amp, ampSkew, rel)
    local sv = shapes.randomAt(seed, cyc)
    pts[#pts + 1] = { time = t0 + rel * spanLen, value = baseV + half * sv * depth + tiltOffset * rel, shape = ccShape }
  end
  local pts = {}
  local c = 0
  while c / N < 1 - 1e-9 do
    emit(pts, c / N, c)
    c = c + 1
  end
  -- End anchor: Drift eases toward the NEXT target (cyc=c); S&H holds the LAST value (cyc=c-1).
  emit(pts, 1, smoothInterp and c or math.max(0, c - 1))
  return pts
end
```

- [ ] **Step 4: Wire the dispatch in `M.generate`.** Immediately after the `if spanLen <= 0 then return {} end` guard's block where `amp`, `baseV`, `ampSkew`, `tiltOffset`, `totalCycles` are defined (i.e. right before the `-- ANCHORED native shapes` comment, ~line 368), add:

```lua
  -- Random / Drift: dedicated sparse emitters (one random value per cycle). Selected up front so
  -- Steps/Smooth never reroute them (held random doesn't smooth/quantize meaningfully here).
  if p.shape == "random" then
    return generateRandom(t0, t1, spanLen, totalCycles, p, amp, baseV, ampSkew, tiltOffset, false)
  end
  if p.shape == "drift" then
    return generateRandom(t0, t1, spanLen, totalCycles, p, amp, baseV, ampSkew, tiltOffset, true)
  end
```

- [ ] **Step 5: Remove the now-dead generic `random` branch.** In `sampleValue` (the generic sampler, ~lines 405-410), delete the `if p.shape == "random" then sv = shapes.randomAt(seed, cyc) else` / `end` wrapper so it becomes just:

```lua
    local sv = shapes.value(p.shape, tInCycle, p)
```
(The dedicated emitter now owns `random`, so this branch is unreachable; removing it keeps the sampler clean. `seed` may become unused in `M.generate` — that is fine, or delete its `local seed = p.seed or 0` line if the linter complains.)

- [ ] **Step 6: Run and confirm PASS**

Run: `/c/Users/Dani/AppData/Local/Programs/Lua/bin/lua.exe tests/test_lfo.lua`
Expected: PASS (random + drift tests).

- [ ] **Step 7: Commit**

```bash
git add Contour/core/lfo.lua tests/test_lfo.lua
git commit -m "feat: Random (S&H) + Drift dedicated emitter"
```

---

### Task 4: Pump emitter (`core/lfo.lua`)

**Files:**
- Modify: `Contour/core/lfo.lua` (add `generatePump`; add a dispatch branch)
- Test: `tests/test_lfo.lua`

**Interfaces:**
- Produces: `M.generate(span, {shape="pump", curve=0..100, ...})`. Per cycle: a duck point (−1) at the cycle start that recovers to peak (+1) by the cycle end, with the recovery segment carrying a bezier CC shape (5) whose tension scales with `curve` (0 ⇒ linear). Depth = `amplitude`.

- [ ] **Step 1: Write the failing test** — append to `tests/test_lfo.lua` before `h.run()`:

```lua
-- Pump: per cycle a duck (-1) at the start that recovers to peak (+1); 2 cycles over the span =>
-- two duck->recover ramps. Curve>0 => the duck point carries a bezier shape (5).
h.test("pump: duck then recover per cycle", function()
  local pts = lfo.generate({ t0 = 0, t1 = 4 },
    { shape = "pump", rate = { mode = "free", cycles = 2 }, amplitude = 1, baseline = 0, curve = 60 })
  h.almost(pts[1].value, -1, 1e-9)          -- starts ducked
  h.eq(pts[1].shape, 5, "curved recovery uses bezier")
  -- somewhere a recovered peak (+1) exists before each re-duck
  local sawPeak = false
  for _, p in ipairs(pts) do if p.value > 0.99 then sawPeak = true end end
  h.truthy(sawPeak, "recovers to full")
end)
h.test("pump curve=0 is linear recovery", function()
  local pts = lfo.generate({ t0 = 0, t1 = 4 },
    { shape = "pump", rate = { mode = "free", cycles = 2 }, amplitude = 1, baseline = 0, curve = 0 })
  h.eq(pts[1].shape, 1, "no curve => linear")
end)
```

- [ ] **Step 2: Run and confirm FAIL**

Run: `/c/Users/Dani/AppData/Local/Programs/Lua/bin/lua.exe tests/test_lfo.lua`
Expected: FAIL (pump unsupported → falls to generic sampler → base.sine).

- [ ] **Step 3: Add `generatePump`** to `Contour/core/lfo.lua`, right after `generateRandom` (before `M.generate`):

```lua
-- Pump (sidechain duck): per cycle, an instant duck to -1 at the cycle start that RECOVERS to +1 by
-- the cycle end (an exponential Saw Up). The recovery segment carries a bezier CC shape whose tension
-- scales with `curve` (0..100 => linear..strongly bulged). Depth = amplitude. Sparse, like generateSaw.
local function generatePump(t0, t1, spanLen, totalCycles, p, amp, baseV, ampSkew, tiltOffset)
  local N = totalCycles
  local curve = max(0, min(1, (p.curve or 0) / 100))
  local tension = curve * 0.9
  local rampShape = (curve > 1e-9) and 5 or 1   -- bezier when curved, else linear
  local eps = 1e-4
  local function emit(pts, rel, sv, shp, ten)
    if rel < 0 then rel = 0 elseif rel > 1 then rel = 1 end
    local depth = M.fadeDepth(rel, p.fadeIn, p.fadeOut)
    local half = ampHalf(amp, ampSkew, rel)
    pts[#pts + 1] = { time = t0 + rel * spanLen, value = baseV + half * sv * depth + tiltOffset * rel, shape = shp, tension = ten }
  end
  local pts = {}
  emit(pts, 0, -1, rampShape, tension)           -- first duck, curved recovery
  local c = 1
  while c / N < 1 - 1e-9 do
    local rel = c / N
    emit(pts, rel, 1, 1, 0)                       -- recovered peak (end of cycle c-1)
    emit(pts, rel + eps, -1, rampShape, tension)  -- re-duck (start of cycle c)
    c = c + 1
  end
  local fracEnd = N - floor(N)
  emit(pts, 1, (fracEnd < 1e-9) and 1 or (2 * fracEnd - 1), 1, 0)   -- recovered value at span end
  return pts
end
```

- [ ] **Step 4: Wire the dispatch** in `M.generate`, right after the `drift` branch added in Task 3:

```lua
  if p.shape == "pump" then
    return generatePump(t0, t1, spanLen, totalCycles, p, amp, baseV, ampSkew, tiltOffset)
  end
```

- [ ] **Step 5: Run and confirm PASS**

Run: `/c/Users/Dani/AppData/Local/Programs/Lua/bin/lua.exe tests/test_lfo.lua`
Expected: PASS.

- [ ] **Step 6: Commit**

```bash
git add Contour/core/lfo.lua tests/test_lfo.lua
git commit -m "feat: Pump (sidechain-duck) emitter"
```

---

### Task 5: AD emitter (`core/lfo.lua`)

**Files:**
- Modify: `Contour/core/lfo.lua` (add `generateAD`; add a dispatch branch)
- Test: `tests/test_lfo.lua`

**Interfaces:**
- Produces: `M.generate(span, {shape="ad", attack=1..99, curve=0..100, ...})`. Per cycle: rise −1→+1 over the Attack fraction `a=attack/100`, then fall +1→−1 over the rest; both segments carry a bezier shape scaled by `curve`. The peak lands at cycle-fraction `a`.

- [ ] **Step 1: Write the failing test** — append to `tests/test_lfo.lua` before `h.run()`:

```lua
-- AD: rise to a peak at the Attack fraction, then decay. 1 cycle over a span of length 1, attack=25%
-- => the peak (+1) point sits near t=0.25.
h.test("ad: peak lands at the attack fraction", function()
  local pts = lfo.generate({ t0 = 0, t1 = 1 },
    { shape = "ad", rate = { mode = "free", cycles = 1 }, amplitude = 1, baseline = 0, attack = 25, curve = 50 })
  h.almost(pts[1].value, -1, 1e-9)             -- starts at trough
  local peakT
  for _, p in ipairs(pts) do if p.value > 0.99 then peakT = p.time end end
  h.truthy(peakT ~= nil, "has a peak")
  h.almost(peakT, 0.25, 1e-6)                  -- peak at the attack fraction
end)
```

- [ ] **Step 2: Run and confirm FAIL**

Run: `/c/Users/Dani/AppData/Local/Programs/Lua/bin/lua.exe tests/test_lfo.lua`
Expected: FAIL (ad unsupported).

- [ ] **Step 3: Add `generateAD`** to `Contour/core/lfo.lua`, right after `generatePump`:

```lua
-- AD (attack-decay hump): per cycle, rise -1->+1 over the Attack fraction a=attack/100, then fall
-- +1->-1 over the remaining 1-a. Both segments carry a bezier CC shape scaled by `curve`. Sparse:
-- a trough at each cycle start, a peak at cycle-fraction a.
local function generateAD(t0, t1, spanLen, totalCycles, p, amp, baseV, ampSkew, tiltOffset)
  local N = totalCycles
  local a = max(0.01, min(0.99, (p.attack or 50) / 100))
  local curve = max(0, min(1, (p.curve or 0) / 100))
  local tension = curve * 0.9
  local seg = (curve > 1e-9) and 5 or 1
  local function emit(pts, rel, sv)
    if rel < 0 then rel = 0 elseif rel > 1 then rel = 1 end
    local depth = M.fadeDepth(rel, p.fadeIn, p.fadeOut)
    local half = ampHalf(amp, ampSkew, rel)
    pts[#pts + 1] = { time = t0 + rel * spanLen, value = baseV + half * sv * depth + tiltOffset * rel, shape = seg, tension = tension }
  end
  local pts = {}
  emit(pts, 0, -1)                              -- start trough (attack begins)
  local c = 0
  while true do
    local peakRel = (c + a) / N
    if peakRel >= 1 - 1e-9 then break end
    emit(pts, peakRel, 1)                       -- peak (decay begins)
    local troughRel = (c + 1) / N
    if troughRel < 1 - 1e-9 then emit(pts, troughRel, -1) end  -- next trough
    c = c + 1
  end
  emit(pts, 1, -1)                              -- span end at trough
  return pts
end
```

- [ ] **Step 4: Wire the dispatch** in `M.generate`, right after the `pump` branch:

```lua
  if p.shape == "ad" then
    return generateAD(t0, t1, spanLen, totalCycles, p, amp, baseV, ampSkew, tiltOffset)
  end
```

- [ ] **Step 5: Run and confirm PASS**

Run: `/c/Users/Dani/AppData/Local/Programs/Lua/bin/lua.exe tests/test_lfo.lua`
Expected: PASS.

- [ ] **Step 6: Run the FULL suite — native match must still be green**

Run: `LUA="/c/Users/Dani/AppData/Local/Programs/Lua/bin/lua.exe"; for t in tests/test_*.lua; do "$LUA" "$t" >/dev/null 2>&1 && echo "PASS $t" || echo "FAIL $t"; done`
Expected: all PASS, including `tests/test_native_match.lua` (no new shape touched the native emitters).

- [ ] **Step 7: Commit**

```bash
git add Contour/core/lfo.lua tests/test_lfo.lua
git commit -m "feat: AD (attack-decay) emitter"
```

---

### Task 6: Dropdown — rename Saw→Saw Up, family reorder, register new ids

**Files:**
- Modify: `Contour/ui/generate.lua` (`SHAPES` ~lines 24-31; `SHAPE_OUTPUT` ~lines 103-110)

**Interfaces:**
- Consumes: engine ids from Tasks 2–5 (`sawdown`, `trapezoid`, `rectsine`, `sine2`, `pump`, `ad`, `random`, `drift`) — all now valid.
- Produces: the dropdown list + per-shape `outputFor` data the panel uses. `currentShapeId`/`buildParams` already read `SHAPES[idx+1].id`, so no other change is needed here.

- [ ] **Step 1: Replace the `SHAPES` table** (~lines 24-31) with the family-ordered list (None stays index 0 so `DEFAULTS.shapeIdx = 0` still means None; Sine stays index 1):

```lua
local SHAPES = {
  { id = "none",       label = "None" },
  { id = "sine",       label = "Sine" },
  { id = "triangle",   label = "Triangle" },
  { id = "saw",        label = "Saw Up" },
  { id = "sawdown",    label = "Saw Down" },
  { id = "square",     label = "Square" },
  { id = "trapezoid",  label = "Trapezoid" },
  { id = "parametric", label = "Parametric" },
  { id = "rectsine",   label = "Rectified sine" },
  { id = "sine2",      label = "Sine\xc2\xb2" },     -- "Sine²" (UTF-8 superscript two)
  { id = "pump",       label = "Pump" },
  { id = "ad",         label = "AD" },
  { id = "random",     label = "Random (S&H)" },
  { id = "drift",      label = "Drift" },
}
```

- [ ] **Step 2: Add `SHAPE_OUTPUT` entries** for the new ids (~lines 103-110). Extend the table to:

```lua
local SHAPE_OUTPUT = {
  none       = { ppc = 1,  ccShape = 0 },
  sine       = { ppc = 8,  ccShape = 2 },
  triangle   = { ppc = 2,  ccShape = 1 },
  saw        = { ppc = 2,  ccShape = 1 },
  square     = { ppc = 2,  ccShape = 0 },
  parametric = { ppc = 4,  ccShape = 4 },
  -- Generic-sampler shapes (no per-point shape tag) -> dense points + fallback CC shape:
  sawdown    = { ppc = 16, ccShape = 1 },   -- descending ramp (linear)
  trapezoid  = { ppc = 24, ccShape = 1 },   -- linear ramps + holds
  rectsine   = { ppc = 24, ccShape = 1 },   -- humps approximated by dense linear points
  sine2      = { ppc = 24, ccShape = 1 },
  -- Dedicated emitters tag their own per-point shapes; ppc/ccShape here are inert fallbacks:
  pump       = { ppc = 2,  ccShape = 1 },
  ad         = { ppc = 2,  ccShape = 1 },
  random     = { ppc = 1,  ccShape = 0 },
  drift      = { ppc = 1,  ccShape = 2 },
}
```

- [ ] **Step 3: Syntax-check + full suite** (the UI file isn't headless-tested, but it must compile; engine tests must stay green):

Run:
```bash
LUA="/c/Users/Dani/AppData/Local/Programs/Lua/bin/lua.exe"
"$LUA" -e 'assert(loadfile("Contour/ui/generate.lua")); print("compile ok")'
for t in tests/test_*.lua; do "$LUA" "$t" >/dev/null 2>&1 && echo "PASS $t" || echo "FAIL $t"; done
```
Expected: "compile ok" and all tests PASS.

- [ ] **Step 4: Commit**

```bash
git add Contour/ui/generate.lua
git commit -m "feat: dropdown family reorder + Saw->Saw Up + register new shapes"
```

---

### Task 7: UI controls — Steps, Smooth, Curve, Attack, Edge + buildParams plumbing

**Files:**
- Modify: `Contour/ui/generate.lua` (`DEFAULTS` ~line 158; `state.gen` init ~lines 199-214; the "Shaping" draw block ~lines 610-631; `buildParams` ~lines 281-296)

**Interfaces:**
- Consumes: engine params `smooth`, `quantizeSteps`, `curve`, `attack`, `edge` (Tasks 2–5 read them).
- Produces: panel state fields `g.steps`, `g.smooth`, `g.curve`, `g.attack`, `g.edge` and their conversion in `buildParams`.

- [ ] **Step 1: Add DEFAULTS** — in the `DEFAULTS` table (~lines 158-175), add after `swing = 0.0,`:

```lua
  steps      = 0,        -- 0 = off; >=2 quantizes any shape to N levels
  smooth     = 0,        -- 0..100 % blend toward sine
  curve      = 0,        -- 0..100 (Pump/AD recovery/ease steepness)
  attack     = 50,       -- 1..99 % of cycle (AD peak position)
  edge       = 50,       -- 0..100 % (Trapezoid edge width; /200 => [0,0.5])
```

- [ ] **Step 2: Add state init** — in the `state.gen = { ... }` block (~lines 199-214), add after `swing = DEFAULTS.swing,`:

```lua
      steps     = DEFAULTS.steps,
      smooth    = DEFAULTS.smooth,
      curve     = DEFAULTS.curve,
      attack    = DEFAULTS.attack,
      edge      = DEFAULTS.edge,
```

- [ ] **Step 3: Add the controls to the "Shaping" block.** Inside the `do ... end` shaping block (~lines 612-631), the Pulse-width line is currently always shown. Replace the single pulse-width line:

```lua
    -- Pulse width 0.01..0.99 (native is 1..99%): never a degenerate all-low/all-high square.
    changed, g.pulseWidth = reaper.ImGui_SliderDouble(ctx, "Pulse width##gen_pw", g.pulseWidth, 0.01, 0.99, "%.2f")
    acc(changed); acc(tickReset(ctx, g, "pulseWidth", 0.01, 0.99, 0.5))
```
with a shape-aware block (uses `currentShapeId`, defined later in the file at ~line 348 — it's a module-level local so it is in scope here):
```lua
    -- Pulse width only for Square.
    if currentShapeId(g) == "square" then
      changed, g.pulseWidth = reaper.ImGui_SliderDouble(ctx, "Pulse width##gen_pw", g.pulseWidth, 0.01, 0.99, "%.2f")
      acc(changed); acc(tickReset(ctx, g, "pulseWidth", 0.01, 0.99, 0.5))
    end
    -- Edge only for Trapezoid (0 = square, 100 = triangle).
    if currentShapeId(g) == "trapezoid" then
      changed, g.edge = reaper.ImGui_SliderInt(ctx, "Edge##gen_edge", g.edge, 0, 100, "%d")
      acc(changed); acc(tickReset(ctx, g, "edge", 0, 100, 50))
    end
    -- Attack only for AD (peak position, % of cycle).
    if currentShapeId(g) == "ad" then
      changed, g.attack = reaper.ImGui_SliderInt(ctx, "Attack##gen_attack", g.attack, 1, 99, "%d")
      acc(changed); acc(tickReset(ctx, g, "attack", 1, 99, 50))
    end
    -- Curve for Pump + AD (recovery / ease steepness).
    if currentShapeId(g) == "pump" or currentShapeId(g) == "ad" then
      changed, g.curve = reaper.ImGui_SliderInt(ctx, "Curve##gen_curve", g.curve, 0, 100, "%d")
      acc(changed); acc(tickReset(ctx, g, "curve", 0, 100, 0))
    end
```

Then, after the `Swing` slider line (`acc(changed); acc(tickReset(ctx, g, "swing", -1.0, 1.0, 0.0))`, ~line 630), add the two GLOBAL modifiers:
```lua
    -- Global modifiers (apply to ANY shape). Steps quantizes to N levels; Smooth rounds toward sine.
    changed, g.steps = reaper.ImGui_SliderInt(ctx, "Steps##gen_steps", g.steps, 0, 32, g.steps < 2 and "off" or "%d")
    acc(changed); acc(tickReset(ctx, g, "steps", 0, 32, 0))
    changed, g.smooth = reaper.ImGui_SliderInt(ctx, "Smooth##gen_smooth", g.smooth, 0, 100, "%d")
    acc(changed); acc(tickReset(ctx, g, "smooth", 0, 100, 0))
```

- [ ] **Step 4: Plumb into `buildParams`** — in the `params = { ... }` table (~lines 281-296), add these fields (after `seed = g.seed or 0,`):

```lua
    smooth        = (g.smooth or 0) / 100,                                  -- 0..1 blend toward sine
    quantizeSteps = (g.steps and g.steps >= 2) and g.steps or nil,         -- nil = off
    curve         = g.curve or 0,                                          -- Pump/AD ease (0..100)
    attack        = g.attack or 50,                                        -- AD peak position (%)
    edge          = (g.edge or 50) / 200,                                  -- Trapezoid edge -> [0,0.5]
```

- [ ] **Step 5: Syntax-check, then manual reasoning check.**

Run:
```bash
LUA="/c/Users/Dani/AppData/Local/Programs/Lua/bin/lua.exe"
"$LUA" -e 'assert(loadfile("Contour/ui/generate.lua")); print("compile ok")'
for t in tests/test_*.lua; do "$LUA" "$t" >/dev/null 2>&1 && echo "PASS $t" || echo "FAIL $t"; done
```
Expected: "compile ok" and all engine tests PASS (native match included).

Confirm by reading: at default state (`steps=0`, `smooth=0`) `buildParams` sets `quantizeSteps=nil` and `smooth=0`, so native shapes still route to their exact emitters in `lfo.generate` (the `(p.smooth or 0)==0 and not p.quantizeSteps` guard holds) — native match preserved.

- [ ] **Step 6: Commit**

```bash
git add Contour/ui/generate.lua
git commit -m "feat: Steps/Smooth/Curve/Attack/Edge controls + buildParams plumbing"
```

---

## Final verification (after all tasks)

- [ ] Run the full suite; expect every file PASS incl. `tests/test_native_match.lua`:
```bash
LUA="/c/Users/Dani/AppData/Local/Programs/Lua/bin/lua.exe"; for t in tests/test_*.lua; do "$LUA" "$t" >/dev/null 2>&1 && echo "PASS $t" || echo "FAIL $t"; done
```
- [ ] Syntax-gate every touched source: `"$LUA" -e 'for _,f in ipairs({"Contour/core/shapes.lua","Contour/core/lfo.lua","Contour/ui/generate.lua"}) do assert(loadfile(f)) end print("ok")'`
- [ ] **Do NOT push.** Leave commits local; report to the user and await the word to push.
- [ ] Hand off for user REAPER testing of each new shape (Random/Drift movement, Pump on a Volume envelope, AD swell, Trapezoid edges, Steps/Smooth on various shapes).

## Notes / out of scope

- **Steps & Smooth scope:** they apply to the sampler-based shapes (the 5 natives + Saw Down / Trapezoid / Rectified sine / Sine²). The dedicated emitters (Pump, AD, Random, Drift) ignore Steps/Smooth by design for v1 — they're already stepped/curved. Quantizing/smoothing those is a possible later addition.
- Exp/log ramp shapes (the user dropped these — Curve/skew already covers them).
- Phase / freq-skew / swing for Random/Drift/Pump/AD (not applied; can be added later).
- Saw Down stays on the generic dense sampler (works; modulator-aware via that path). A dedicated sparse descending emitter is a possible later polish, not required.
