# Generate Shape Consolidation Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add a bipolar Curve knob to Saw Up/Down and Attack+Curve to Triangle, then retire Pump (= curved Saw Up) and AD (= Triangle + Attack + Curve).

**Architecture:** Saw gets bezier-tension on its ramp-start points (reset stays linear). Triangle's anchored emitter is generalized to place the peak at Attack and bend its segments via bezier. Both keep the default (Curve 0 / Attack 50) byte-identical to today's native emitters. Pump/AD are removed from the dropdown and engine.

**Tech Stack:** Lua 5.4, ReaImGui, the Contour test harness. Run headless tests with `/c/Users/Dani/AppData/Local/Programs/Lua/bin/lua.exe tests/test_*.lua`.

## Global Constraints

- BUILD LOCAL ONLY — commit locally, do NOT `git push`.
- `tests/test_native_match.lua` (35 tests) is the GATE: the DEFAULT saw (Curve 0) and DEFAULT triangle (Attack 50, Curve 0) must stay byte-identical. Run it after every task; it must stay green.
- Curve param: UI SliderInt **-100..100**, default **0**; engine uses `curve/100` clamped to [-1,1], tension `= curve/100 * 0.9` (the mapping Pump/AD already use). 0 = linear.
- Attack param: UI SliderInt **1..99**, default **50** (% of cycle, the peak position).
- A point's CC shape governs its OUTGOING segment. CC shape ints: 1=linear, 5=bezier (with `tension`).
- `buildParams` already passes `curve = g.curve or 0` and `attack = g.attack or 50` to every shape — no buildParams change is needed; the params simply start applying to saw/triangle.
- Run the FULL suite after each task: `for t in tests/test_*.lua; do /c/Users/Dani/AppData/Local/Programs/Lua/bin/lua.exe "$t" >/dev/null 2>&1 && echo "PASS $t" || echo "FAIL $t"; done`

## File Structure

- `Contour/core/lfo.lua` — `generateSaw` (+curve), `emitAnchored` (triangle attack+curve), remove `generatePump`/`generateAD` + dispatch branches.
- `Contour/ui/generate.lua` — `SHAPES` & `SHAPE_OUTPUT` (drop pump/ad), `special` set, Curve/Attack visibility.
- `tests/test_lfo.lua` — add saw-curve + triangle-attack/curve tests; remove pump/AD tests.
- `tests/test_lfo_shapes_regression.lua` — drop the `pump`/`ad` CASES.

---

### Task 1: Saw Up / Saw Down — Curve

**Files:**
- Modify: `Contour/core/lfo.lua` (`generateSaw`)
- Modify: `Contour/ui/generate.lua` (Curve visibility: add saw/sawdown)
- Test: `tests/test_lfo.lua`

**Interfaces:**
- Consumes: `p.curve` (already plumbed by buildParams).
- Produces: saw/sawdown points whose ramp-start points carry shape 5 + `tension` when `curve != 0`.

- [ ] **Step 1: Write the failing tests**

Append to `tests/test_lfo.lua` (just before `h.run()`):

```lua
-- Saw Curve: the RAMP bends (bezier), the RESET stays instant (linear). Curve 0 = native saw.
h.test("saw curve bends the ramp, reset stays linear", function()
  local function gen(curve)
    return lfo.generate({ t0 = 0, t1 = 4 },
      { shape = "saw", rate = { mode = "free", cycles = 4 }, amplitude = 1, baseline = 0, curve = curve })
  end
  for _, p in ipairs(gen(0)) do h.eq(p.shape, 1, "curve 0 -> all linear") end
  local hasBez, peaksLinear = false, true
  for _, p in ipairs(gen(60)) do
    if math.abs(p.value - (-1)) < 1e-6 then               -- ramp-start (trough)
      if p.shape == 5 and (p.tension or 0) > 0 then hasBez = true end
    elseif math.abs(p.value - 1) < 1e-6 then               -- peak (reset point)
      if p.shape ~= 1 then peaksLinear = false end
    end
  end
  h.truthy(hasBez, "ramp-start points should be bezier with +tension")
  h.truthy(peaksLinear, "peak points stay linear (instant reset)")
end)

-- Curve must not change the point count (no densify) and works for saw down too.
h.test("saw curve keeps point count; saw down curves as well", function()
  local function gen(shape, curve)
    return lfo.generate({ t0 = 0, t1 = 4 },
      { shape = shape, rate = { mode = "free", cycles = 4 }, amplitude = 1, baseline = 0, curve = curve })
  end
  h.eq(#gen("saw", 0), #gen("saw", 60), "curve must not change saw point count")
  local bez = false
  for _, p in ipairs(gen("sawdown", -60)) do if p.shape == 5 and (p.tension or 0) < 0 then bez = true end end
  h.truthy(bez, "saw down curve -> bezier points with -tension")
end)
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `/c/Users/Dani/AppData/Local/Programs/Lua/bin/lua.exe tests/test_lfo.lua`
Expected: FAIL (ramp-start points are currently shape 1, no tension).

- [ ] **Step 3: Implement Curve in `generateSaw`**

In `Contour/core/lfo.lua`, find `generateSaw`. Replace its body from the `local lo, hi` line through the `emit` function, and the three `emit(...)` call sites, so the ramp-start points carry the curve. The full function becomes:

```lua
local function generateSaw(t0, t1, spanLen, totalCycles, p, amp, baseV, ampSkew, freqSkew, tiltOffset, desc)
  local N = totalCycles
  local phase = p.phase or 0
  local swing = max(-1, min(1, p.swing or 0))
  local eps = 1e-4                             -- ~1 tick reset gap (the writer snaps to the grid)
  local lo, hi = -1, 1                         -- Saw Up: trough -> peak
  if desc then lo, hi = 1, -1 end              -- Saw Down: peak -> trough
  -- CURVE: bend the RAMP via a bezier CC shape on the ramp-start points; the reset (peak) stays
  -- linear so the drop is instant. Bipolar tension; curve 0 -> linear (byte-identical native saw).
  local curve = max(-1, min(1, (p.curve or 0) / 100))
  local tension = curve * 0.9
  local rampShape = (abs(curve) > 1e-9) and 5 or 1
  local function emit(pts, rel, sv, shp, ten)
    if rel < 0 then rel = 0 elseif rel > 1 then rel = 1 end
    local depth = M.fadeDepth(rel, p.fadeIn, p.fadeOut)
    local half = ampHalf(amp, ampSkew, rel)
    pts[#pts + 1] = { time = t0 + rel * spanLen, value = baseV + half * sv * depth + tiltOffset * rel, shape = shp, tension = ten }
  end
  -- Ramp value at cycle-position cp: PHASE shifts the waveform (shape-phase = cp - phase); each cycle
  -- ramps lo -> hi. Used for the partial values at the span edges.
  local function rampVal(cp) local f = cp - phase; f = f - floor(f); return lo + (hi - lo) * f end
  -- Cycle-position of the j-th reset boundary: (j + phase), with odd-index resets swing-shifted by
  -- swing*0.5 (the pair feel). At phase=0 this is exactly the old boundaryCP, and the j=1 start +
  -- rampVal(0)=lo make the whole emitter byte-identical to the native saw.
  local function resetCP(j) return (j % 2 == 1) and (j + phase + swing * 0.5) or (j + phase) end
  local pts = {}
  emit(pts, 0, rampVal(0), rampShape, tension)  -- partial ramp value at the span start (lo when phase=0)
  local j = (phase > 1e-9) and 0 or 1           -- phase>0 can place a reset inside the first cycle
  while true do
    local prog = resetCP(j) / N
    if prog >= 1 - 1e-9 then break end
    if prog > 1e-9 then
      local relB = M.freqWarpInverse(prog, freqSkew)
      emit(pts, relB, hi, 1, 0)                  -- ramp end (peak) -> reset stays linear/instant
      emit(pts, relB + eps, lo, rampShape, tension)  -- reset (next ramp start) -> curved
    end
    j = j + 1
  end
  -- Final point at the span end = the partial ramp value at the SWUNG, phase-shifted end position
  -- (a whole cycle -> hi, the ramp peak; a partial cycle -> interpolated lo->hi). No outgoing segment.
  local endCP = M.swingCyclePos(N, swing) - phase
  local fracEnd = endCP - floor(endCP)
  emit(pts, 1, (fracEnd < 1e-9) and hi or (lo + (hi - lo) * fracEnd), 1, 0)
  return pts
end
```

- [ ] **Step 4: Show Curve for saw/sawdown in the panel**

In `Contour/ui/generate.lua`, find the Curve block (currently shown for pump/ad) and add saw/sawdown:

```lua
    -- Curve for Pump + AD + Saw Up/Down (ease steepness). Bipolar: 0 = linear, + bends one way, - the other.
    if currentShapeId(g) == "pump" or currentShapeId(g) == "ad"
       or currentShapeId(g) == "saw" or currentShapeId(g) == "sawdown" then
      changed, g.curve = reaper.ImGui_SliderInt(ctx, "Curve##gen_curve", g.curve, -100, 100, "%d")
      acc(changed); acc(tickReset(ctx, g, "curve", -100, 100, 0))
    end
```

- [ ] **Step 5: Run the tests + full suite (native match is the gate)**

Run: `/c/Users/Dani/AppData/Local/Programs/Lua/bin/lua.exe tests/test_lfo.lua` → PASS.
Then the full suite (command in Global Constraints) → every file PASS, **especially `test_native_match.lua`** (curve 0 saw byte-identical) and `test_lfo_shapes_regression.lua`.
Also compile-gate the UI: `/c/Users/Dani/AppData/Local/Programs/Lua/bin/lua.exe -e 'assert(loadfile("Contour/ui/generate.lua")) print("compile ok")'`.

- [ ] **Step 6: Commit (LOCAL ONLY)**

```bash
git add Contour/core/lfo.lua Contour/ui/generate.lua tests/test_lfo.lua
git commit -m "feat(generate): bipolar Curve on Saw Up/Down (bezier ramp, instant reset)"
```

---

### Task 2: Triangle — Attack + Curve

**Files:**
- Modify: `Contour/core/lfo.lua` (`emitAnchored`)
- Modify: `Contour/ui/generate.lua` (Attack + Curve visibility: add triangle)
- Test: `tests/test_lfo.lua`

**Interfaces:**
- Consumes: `p.attack` (default 50), `p.curve` (default 0) — already plumbed by buildParams.
- Produces: triangle points with a peak at `attack/100` and bezier (shape 5 + `tension`) segments when `curve != 0`. Sine/Parametric/Sine² are unchanged.

- [ ] **Step 1: Write the failing tests**

Append to `tests/test_lfo.lua` (just before `h.run()`):

```lua
-- Triangle Attack moves the peak; Attack 50 + Curve 0 = today's native triangle (all linear).
h.test("triangle attack moves the peak; default stays linear", function()
  local def = lfo.generate({ t0 = 0, t1 = 1 },
    { shape = "triangle", rate = { mode = "free", cycles = 1 }, amplitude = 1, baseline = 0 })
  for _, p in ipairs(def) do h.eq(p.shape, 1, "default triangle is linear") end
  local function peakTime(attack)
    local pts = lfo.generate({ t0 = 0, t1 = 1 },
      { shape = "triangle", rate = { mode = "free", cycles = 1 }, amplitude = 1, baseline = 0, attack = attack })
    for _, p in ipairs(pts) do if math.abs(p.value - 1) < 1e-6 then return p.time end end
  end
  h.almost(peakTime(50), 0.5, 1e-6, "attack 50 -> peak at mid")
  h.almost(peakTime(25), 0.25, 1e-6, "attack 25 -> peak at quarter")
end)

-- Triangle Curve bends the rise/fall via bezier.
h.test("triangle curve bends the segments (bezier)", function()
  local pts = lfo.generate({ t0 = 0, t1 = 1 },
    { shape = "triangle", rate = { mode = "free", cycles = 1 }, amplitude = 1, baseline = 0, curve = 60 })
  local bez = false
  for _, p in ipairs(pts) do if p.shape == 5 and (p.tension or 0) > 0 then bez = true end end
  h.truthy(bez, "triangle curve -> bezier points with +tension")
end)
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `/c/Users/Dani/AppData/Local/Programs/Lua/bin/lua.exe tests/test_lfo.lua`
Expected: FAIL (attack 25 peak is at 0.5 today; curve does nothing on triangle).

- [ ] **Step 3: Generalize `emitAnchored` for the triangle**

In `Contour/core/lfo.lua`, replace the whole `emitAnchored` function (from `local function emitAnchored` through its final `return pts`/`end`) with this version. Triangle now uses a movable peak (`triA`) with a piecewise-linear value function (`triVal`) and bezier when curved; every other shape path is unchanged (`-cos`, same `shapeFor`, `tension = 0`):

```lua
local function emitAnchored(shape, t0, t1, spanLen, totalCycles, p, amp, baseV, ampSkew, freqSkew, tiltOffset)
  local phase = p.phase or 0
  local swing = max(-1, min(1, p.swing or 0))
  local N = totalCycles
  -- Triangle gains Attack (movable peak) + Curve (bent segments). triA in [0.01,0.99]; triCurve
  -- bipolar. Other shapes ignore these.
  local triA = max(0.01, min(0.99, (p.attack or 50) / 100))
  local triCurve = max(-1, min(1, (p.curve or 0) / 100))
  local triTension = triCurve * 0.9
  local triShape = (shape == "triangle") and ((abs(triCurve) > 1e-9) and 5 or 1) or nil
  local sampleSet =
        (shape == "triangle") and { 0, triA }
     or ((shape == "parametric" or shape == "sine2") and { 0, 0.25, 0.5, 0.75 } or { 0, 0.5 })

  -- Waveform value at shape-phase x. Triangle = a piecewise-linear peak at triA (NOT -cos, whose peak
  -- only lands at 0.5); all other shapes keep the -cos model. At triA=0.5 the two agree at every
  -- sampled point used by the native-match configs, so the default triangle is byte-identical.
  local function waveVal(x)
    if shape == "triangle" then
      local f = x - floor(x)
      if f < triA then return -1 + 2 * (f / triA) else return 1 - 2 * ((f - triA) / (1 - triA)) end
    end
    return -cos(2 * pi * x)
  end

  local function valueAt(rel, sv)
    local depth = M.fadeDepth(rel, p.fadeIn, p.fadeOut)
    local half = ampHalf(amp, ampSkew, rel)
    return baseV + half * sv * depth + tiltOffset * rel
  end

  -- Per-point CC interpolation shape (int). Triangle: linear, or bezier when Curve != 0.
  --   sine -> slow start/end (2); parametric -> fast end (4) at extrema / fast start (3) at mids;
  --   sine2 -> slow start/end (2) on every point.
  local function shapeFor(sp)
    if shape == "triangle" then return triShape end
    if shape == "parametric" then
      local ext = (sp < 1e-9) or (abs(sp - 0.5) < 1e-9)
      return ext and 4 or 3
    end
    if shape == "sine2" then return 2 end
    return 2
  end

  -- Collect {rel, sv, shp, ten}. A sample at phase position pp = c + swingWarp(sp) has time-progress
  -- prog = (pp + phase)/N which must lie in the OPEN (0,1) (the 0/1 edges are anchors).
  local samp = {}
  for c = floor(-phase) - 1, ceil(N) + 1 do
    for _, sp in ipairs(sampleSet) do
      local prog = (c + M.swingWarp(sp, swing) + phase) / N
      if prog > 1e-9 and prog < 1 - 1e-9 then
        samp[#samp + 1] = { rel = M.freqWarpInverse(prog, freqSkew), sv = waveVal(sp), shp = shapeFor(sp), ten = triTension }
      end
    end
  end
  -- Span-edge anchors. warpInverse(0)=0, warpInverse(1)=1, so the shape-phase at the edges is
  -- -phase (rel 0) and N-phase (rel 1); value = waveVal(shapePhase).
  samp[#samp + 1] = { rel = 0, sv = waveVal(-phase), shp = shapeFor(0), ten = triTension }
  samp[#samp + 1] = { rel = 1, sv = waveVal(N - phase), shp = shapeFor(0), ten = triTension }

  table.sort(samp, function(a, b) return a.rel < b.rel end)

  local pts, lastRel = {}, nil
  for _, s in ipairs(samp) do
    if lastRel == nil or s.rel - lastRel > 1e-6 then
      pts[#pts + 1] = { time = t0 + s.rel * spanLen, value = valueAt(s.rel, s.sv), shape = s.shp, tension = s.ten }
      lastRel = s.rel
    end
  end
  return pts
end
```

Note: `triTension` is 0 for every non-triangle shape (triCurve defaults to 0 and only the triangle path emits shape 5), and `shapeFor` returns the same ints as before for sine/parametric/sine2, so those shapes are unchanged.

- [ ] **Step 4: Show Attack + Curve for triangle in the panel**

In `Contour/ui/generate.lua`: extend the Attack block (currently ad-only) and the Curve block (from Task 1) to include triangle.

Attack:
```lua
    -- Attack for AD + Triangle (peak position, % of cycle).
    if currentShapeId(g) == "ad" or currentShapeId(g) == "triangle" then
      changed, g.attack = reaper.ImGui_SliderInt(ctx, "Attack##gen_attack", g.attack, 1, 99, "%d")
      acc(changed); acc(tickReset(ctx, g, "attack", 1, 99, 50))
    end
```

Curve (replace the Task 1 version to also include triangle):
```lua
    -- Curve for Pump + AD + Saw Up/Down + Triangle (ease steepness). Bipolar: 0 = linear.
    if currentShapeId(g) == "pump" or currentShapeId(g) == "ad"
       or currentShapeId(g) == "saw" or currentShapeId(g) == "sawdown" or currentShapeId(g) == "triangle" then
      changed, g.curve = reaper.ImGui_SliderInt(ctx, "Curve##gen_curve", g.curve, -100, 100, "%d")
      acc(changed); acc(tickReset(ctx, g, "curve", -100, 100, 0))
    end
```

- [ ] **Step 5: Run the tests + full suite (native match gate)**

Run `tests/test_lfo.lua` → PASS. Then the full suite → every file PASS, **especially `test_native_match.lua`** (default triangle byte-identical) and `test_shapes.lua` + `test_lfo_shapes_regression.lua`. Compile-gate the UI as in Task 1.

- [ ] **Step 6: Commit (LOCAL ONLY)**

```bash
git add Contour/core/lfo.lua Contour/ui/generate.lua tests/test_lfo.lua
git commit -m "feat(generate): Triangle gains Attack (movable peak) + Curve (bezier segments)"
```

---

### Task 3: Retire Pump & AD

**Files:**
- Modify: `Contour/core/lfo.lua` (remove `generatePump`, `generateAD`, their dispatch branches)
- Modify: `Contour/ui/generate.lua` (`SHAPES`, `SHAPE_OUTPUT`, `special`, Curve/Attack visibility)
- Modify: `tests/test_lfo.lua` (remove pump/AD tests)
- Modify: `tests/test_lfo_shapes_regression.lua` (remove pump/ad CASES)

**Interfaces:**
- Consumes: nothing new.
- Produces: a shape list without pump/ad; Curve shown for saw/sawdown/triangle only, Attack for triangle only.

- [ ] **Step 1: Remove Pump & AD from the dropdown and output table**

In `Contour/ui/generate.lua`, delete these two lines from `SHAPES`:
```lua
  { id = "pump",       label = "Pump" },
  { id = "ad",         label = "AD" },
```
And delete the `pump` and `ad` entries from `SHAPE_OUTPUT`:
```lua
  pump       = { ppc = 2,  ccShape = 1 },
  ad         = { ppc = 2,  ccShape = 1 },
```

- [ ] **Step 2: Drop pump/ad from `special` and the Curve/Attack visibility**

In `Contour/ui/generate.lua`:

`special` becomes random/drift only:
```lua
    local special = (sid == "random" or sid == "drift")
```

Attack — triangle only:
```lua
    -- Attack for Triangle (peak position, % of cycle).
    if currentShapeId(g) == "triangle" then
      changed, g.attack = reaper.ImGui_SliderInt(ctx, "Attack##gen_attack", g.attack, 1, 99, "%d")
      acc(changed); acc(tickReset(ctx, g, "attack", 1, 99, 50))
    end
```

Curve — saw/sawdown/triangle only:
```lua
    -- Curve for Saw Up/Down + Triangle (ease steepness). Bipolar: 0 = linear, + one way, - the other.
    if currentShapeId(g) == "saw" or currentShapeId(g) == "sawdown" or currentShapeId(g) == "triangle" then
      changed, g.curve = reaper.ImGui_SliderInt(ctx, "Curve##gen_curve", g.curve, -100, 100, "%d")
      acc(changed); acc(tickReset(ctx, g, "curve", -100, 100, 0))
    end
```

- [ ] **Step 3: Remove the engine emitters + dispatch branches**

In `Contour/core/lfo.lua`, delete the `generatePump` function (its whole `local function generatePump ... end` block, including the doc comment) and the `generateAD` function block. Then delete their dispatch branches:
```lua
  if p.shape == "pump" then
    return generatePump(t0, t1, spanLen, totalCycles, p, amp, baseV, ampSkew, tiltOffset)
  end
  if p.shape == "ad" then
    return generateAD(t0, t1, spanLen, totalCycles, p, amp, baseV, ampSkew, tiltOffset)
  end
```

- [ ] **Step 4: Remove pump/AD tests**

In `tests/test_lfo.lua`, delete every `h.test(...)` block whose body generates `shape = "pump"` or `shape = "ad"` (search the file for `"pump"` and `"ad"`). Do NOT touch the saw/triangle tests added in Tasks 1–2.

In `tests/test_lfo_shapes_regression.lua`, delete these two lines from the `CASES` table:
```lua
  { name = "pump",      p = { shape = "pump",  curve = 50 } },
  { name = "ad",        p = { shape = "ad",    curve = 50, attack = 30 } },
```

- [ ] **Step 5: Run the full suite + compile gate**

Run the full suite → every file PASS (no references to pump/ad remain). `test_native_match.lua` still 35 green. Compile-gate both sources:
`/c/Users/Dani/AppData/Local/Programs/Lua/bin/lua.exe -e 'for _,f in ipairs({"Contour/core/lfo.lua","Contour/ui/generate.lua"}) do assert(loadfile(f)) end print("ok")'`
Also grep to confirm nothing still references the removed shapes: `grep -rn '"pump"\|"ad"\|generatePump\|generateAD' Contour/ tests/` should return nothing (outside historical comments you may leave).

- [ ] **Step 6: Commit (LOCAL ONLY)**

```bash
git add Contour/core/lfo.lua Contour/ui/generate.lua tests/test_lfo.lua tests/test_lfo_shapes_regression.lua
git commit -m "feat(generate): retire Pump & AD (now covered by Saw+Curve and Triangle+Attack+Curve)"
```

---

## Self-Review

**Spec coverage:** Saw Curve (Task 1) — bezier ramp, instant reset, native at curve 0. Triangle Attack+Curve (Task 2) — movable peak via triVal, bezier segments, native at attack 50/curve 0, composes with all modifiers (emitAnchored already applies phase/swing/freq-skew/amp-skew/tilt/fade). Retire Pump & AD (Task 3) — dropdown, SHAPE_OUTPUT, dispatch, emitters, special set, Curve/Attack visibility, tests. Param visibility per spec (Curve → saw/sawdown/triangle; Attack → triangle). buildParams already plumbs curve/attack (spec note). Native-match gate run every task.

**Placeholder scan:** none — full code + exact commands in every step.

**Type consistency:** `p.curve`/`p.attack` engine params; UI `g.curve` (-100..100, def 0) / `g.attack` (1..99, def 50); points carry `shape` + `tension`; `triA`/`triCurve`/`triTension`/`triShape`/`waveVal`/`shapeFor` consistent within Task 2; `currentShapeId(g)`, `tickReset`, `acc` are existing helpers used as elsewhere in the file.

**One accepted divergence (from the spec):** a *plain* triangle at fractional cycle counts or non-zero Phase now uses true linear-triangle edge values (`triVal`) instead of the old `-cos`-based values — more correct, and invisible at the native-match configs (integer cycles, phase 0). The reviewer should treat this as intended.
