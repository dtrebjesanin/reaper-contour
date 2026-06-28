# Reduce Curve Fit Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add a "Curve fit" mode to Reduce that keeps the shape of a curved contour with far fewer points by choosing a REAPER per-point interpolation per segment, instead of always assuming straight lines.

**Architecture:** A new pure function `M.thinCurve` in `core/reduce.lua` recursively fits each stretch of points to the best REAPER easing shape (linear / slow start-end / fast start / fast end) within the existing vertical tolerance, keeping only the endpoints where a curve fits. `ui/reduce.lua` gains a "Curve fit" checkbox that routes `reducedAt` to `thinCurve`. The existing writer already applies per-point shape + tension, so there is no write-path change.

**Tech Stack:** Lua 5.4, ReaImGui (UI), existing Contour test harness (`tests/harness.lua`). Headless tests run with `/c/Users/Dani/AppData/Local/Programs/Lua/bin/lua.exe tests/test_*.lua`.

## Global Constraints

- BUILD LOCAL ONLY — do not `git push` to GitHub/ReaPack. Commit locally.
- Straight-line Reduce behavior MUST be unchanged when Curve fit is off (`reduce.rdp`/`reduce.thin` untouched).
- All existing tests stay green, especially `tests/test_native_match.lua` and `tests/test_reduce.lua`.
- Tolerance reuses the Reduction slider: `eps = amount * (vmax - vmin)`, error measured VERTICALLY (value units) — identical to `reduce.rdp`/`reduce.thin`.
- A point's CC/envelope shape governs its OUTGOING segment (the segment from that point to the next).
- `thinCurve` emits shapes in the TARGET'S native convention: linear is `1` for CC, `0` for envelope/AI; curve shapes `2`/`3`/`4` are identical in both conventions. Selected via `opts.envConvention`.
- Easing models (CC-convention shape ints), value `= v0 + (v1-v0)*e(x)`, `x` in [0,1]:
  - `1 linear`: `e = x`
  - `2 slow start/end`: `e = (1 - cos(pi*x)) / 2`
  - `3 fast start`: `e = sin(pi*x/2)`
  - `4 fast end`: `e = 1 - cos(pi*x/2)`
  These match REAPER's rendering (slow start/end is the native-sine arc; fast start/end are the quarter-sine eases that compose the native parametric sine — both verified by `test_native_match.lua`).

## File Structure

- `Contour/core/reduce.lua` — pure thinning. ADD curve-fit (`thinCurve` + private easing table + recursion). `rdp`/`thin` unchanged.
- `Contour/ui/reduce.lua` — Reduce panel. ADD `curveFit` state, a checkbox, and a branch in `reducedAt`.
- `tests/test_reduce.lua` — ADD curve-fit tests beside the existing RDP tests.

---

### Task 1: Curve-aware thinning in `core/reduce.lua`

**Files:**
- Modify: `Contour/core/reduce.lua` (add curve-fit section; do not touch `rdp`/`thin`)
- Test: `tests/test_reduce.lua` (append)

**Interfaces:**
- Consumes: nothing new (pure Lua).
- Produces: `reduce.thinCurve(points, amount, valueRange, opts)` → returns a list of kept points, each a copy `{ time, value, shape, tension = 0, sel }` with `shape` in the target's native convention. `amount`/`valueRange` mirror `reduce.thin` (`eps = amount * (vmax - vmin)`). `opts = { envConvention = bool }` (emit linear as 0 instead of 1).

- [ ] **Step 1: Write the failing tests**

Append to `tests/test_reduce.lua` (the file already defines `line(n)` and requires `h`/`reduce`):

```lua
-- ── Curve fit (thinCurve) ────────────────────────────────────────────────────
local function arc(n, ease)   -- n samples of an easing curve over [0,1] x [0,1]
  local t = {}
  for i = 0, n - 1 do local x = i / (n - 1); t[#t + 1] = { time = x, value = ease(x) } end
  return t
end
local slowEase  = function(x) return (1 - math.cos(math.pi * x)) / 2 end
local fastStart = function(x) return math.sin(math.pi * x / 2) end
local fastEnd   = function(x) return 1 - math.cos(math.pi * x / 2) end

h.test("thinCurve keeps endpoints (linear) for a straight line", function()
  local out = reduce.thinCurve(line(6), 0.01, { vmin = 0, vmax = 5 })
  h.eq(#out, 2)
  h.eq(out[1].shape, 1)              -- CC linear
  h.eq(out[1].time, 0); h.eq(out[2].time, 5)
end)

h.test("thinCurve fits a slow-start/end arc with 2 points (shape 2)", function()
  local out = reduce.thinCurve(arc(21, slowEase), 0.01, { vmin = 0, vmax = 1 })
  h.eq(#out, 2)
  h.eq(out[1].shape, 2)
end)

h.test("thinCurve fits a fast-start arc (shape 3) and fast-end arc (shape 4)", function()
  local a = reduce.thinCurve(arc(21, fastStart), 0.01, { vmin = 0, vmax = 1 })
  h.eq(#a, 2); h.eq(a[1].shape, 3)
  local b = reduce.thinCurve(arc(21, fastEnd), 0.01, { vmin = 0, vmax = 1 })
  h.eq(#b, 2); h.eq(b[1].shape, 4)
end)

h.test("thinCurve keeps far fewer points than rdp on a curve", function()
  local a = arc(21, slowEase)
  h.truthy(#reduce.thinCurve(a, 0.01, { vmin = 0, vmax = 1 }) < #reduce.rdp(a, 0.01),
    "curve fit should keep fewer points than straight-line rdp")
end)

h.test("thinCurve reconstructs within eps and covers the span", function()
  local a = arc(41, fastEnd)
  local out = reduce.thinCurve(a, 0.02, { vmin = 0, vmax = 1 })
  h.almost(out[1].time, 0, 1e-9); h.almost(out[#out].time, 1, 1e-9)   -- endpoints kept
  for i = 1, #out - 1 do h.truthy(out[i + 1].time > out[i].time, "strictly increasing") end
end)

h.test("thinCurve emits envelope linear (0) under envConvention", function()
  local out = reduce.thinCurve(line(6), 0.01, { vmin = 0, vmax = 5 }, { envConvention = true })
  h.eq(out[1].shape, 0)
end)

h.test("thinCurve passes through tiny lists", function()
  h.eq(#reduce.thinCurve({}, 0.1, { vmin = 0, vmax = 1 }), 0)
  h.eq(#reduce.thinCurve({ { time = 0, value = 0 } }, 0.1, { vmin = 0, vmax = 1 }), 1)
end)
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `/c/Users/Dani/AppData/Local/Programs/Lua/bin/lua.exe tests/test_reduce.lua`
Expected: FAIL — `attempt to call a nil value (field 'thinCurve')`.

- [ ] **Step 3: Implement `thinCurve`**

Insert into `Contour/core/reduce.lua` AFTER `M.thin` (keep `function M.rdp`/`function M.thin` exactly as they are) and BEFORE `return M`. Note `local abs = math.abs` already exists at the top of the file:

```lua
-- ── Curve-aware thinning (Curve fit) ─────────────────────────────────────────
-- Like rdp, but each stretch is tested against REAPER's PER-POINT interpolation shapes, not just a
-- straight chord. Where a curve fits within eps (VERTICAL error, value units — same metric as rdp),
-- only the two endpoints are kept and the first is tagged with that shape. Value = v0 + (v1-v0)*e(x).
-- The eases match REAPER's rendering: slow start/end is the native-sine arc; fast start/end are the
-- quarter-sine eases that compose the native parametric sine (both proven by test_native_match.lua).
local cos, sin, pi = math.cos, math.sin, math.pi
local CANDIDATES = {
  { shape = 1, ease = function(x) return x end },                       -- linear
  { shape = 2, ease = function(x) return (1 - cos(pi * x)) / 2 end },   -- slow start/end (S-curve)
  { shape = 3, ease = function(x) return sin(pi * x / 2) end },         -- fast start (ease-out)
  { shape = 4, ease = function(x) return 1 - cos(pi * x / 2) end },     -- fast end  (ease-in)
}

local function withShape(p, shape)
  return { time = p.time, value = p.value, shape = shape, tension = 0, sel = p.sel }
end

-- Best-fitting candidate for the chord points[i]..points[j]: the shape with the smallest MAX vertical
-- error over the interior points, plus that error and the interior index where it peaks (split point).
local function fitOne(points, i, j)
  local p0, p1 = points[i], points[j]
  local dt, dv = p1.time - p0.time, p1.value - p0.value
  local best
  for _, cand in ipairs(CANDIDATES) do
    local maxErr, maxK = 0, i + 1
    for k = i + 1, j - 1 do
      local pk = points[k]
      local x = (dt == 0) and 0 or (pk.time - p0.time) / dt
      local e = abs(pk.value - (p0.value + dv * cand.ease(x)))
      if e > maxErr then maxErr, maxK = e, k end
    end
    if not best or maxErr < best.err then best = { shape = cand.shape, err = maxErr, splitIdx = maxK } end
  end
  return best
end

-- Kept points for the half-open range [i, j) (i included, j NOT — the caller appends the final point).
-- Accept the whole stretch as one curved segment if a candidate fits within eps, else split at the
-- worst point and recurse.
local function fitRange(points, i, j, eps, linearShape)
  if j <= i + 1 then return { withShape(points[i], linearShape) } end   -- adjacent: straight chord
  local best = fitOne(points, i, j)
  if best.err <= eps then return { withShape(points[i], best.shape) } end
  local out = fitRange(points, i, best.splitIdx, eps, linearShape)
  for _, p in ipairs(fitRange(points, best.splitIdx, j, eps, linearShape)) do out[#out + 1] = p end
  return out
end

-- Curve-aware thinning. `amount`/`valueRange` mirror M.thin (eps = amount * value-range). opts:
--   { envConvention = bool }  -- emit linear as 0 (envelope/AI) instead of 1 (CC). Curves 2-4 are
--                                identical across conventions. Returns kept point COPIES with .shape
--                                (target convention) and .tension = 0.
function M.thinCurve(points, amount, valueRange, opts)
  local n = #points
  opts = opts or {}
  local linearShape = opts.envConvention and 0 or 1
  if n <= 2 then
    local out = {}
    for k = 1, n do out[k] = withShape(points[k], linearShape) end
    return out
  end
  local span = (valueRange and (valueRange.vmax - valueRange.vmin)) or 1
  local eps = (amount or 0) * span
  local kept = fitRange(points, 1, n, eps, linearShape)
  kept[#kept + 1] = withShape(points[n], linearShape)   -- terminal point (no outgoing segment)
  return kept
end
```

- [ ] **Step 4: Run the tests to verify they pass**

Run: `/c/Users/Dani/AppData/Local/Programs/Lua/bin/lua.exe tests/test_reduce.lua`
Expected: PASS (all curve-fit tests + the original 6 RDP tests).

- [ ] **Step 5: Run the full suite (no regressions)**

Run: `for t in tests/test_*.lua; do /c/Users/Dani/AppData/Local/Programs/Lua/bin/lua.exe "$t" >/dev/null 2>&1 && echo "PASS $t" || echo "FAIL $t"; done`
Expected: every file PASS (including `test_native_match.lua`).

- [ ] **Step 6: Commit (LOCAL ONLY)**

```bash
git add Contour/core/reduce.lua tests/test_reduce.lua
git commit -m "feat(reduce): curve-aware thinning (thinCurve) — pure core + tests"
```

---

### Task 2: "Curve fit" checkbox + wiring in `ui/reduce.lua`

**Files:**
- Modify: `Contour/ui/reduce.lua` (state default, `reducedAt`, the draw block)

**Interfaces:**
- Consumes: `reduce.thinCurve(points, amount, valueRange, opts)` from Task 1; `base.tgt:kind()` (returns `"cc"`/`"envelope"`/`"ai"`); `base.tgt:valueRange()`.
- Produces: a `g.curveFit` boolean in `state.red`; no new external API.

- [ ] **Step 1: Add the state default**

In `Contour/ui/reduce.lua`, the `ui(state)` initializer currently reads:

```lua
  if not state.red then
    state.red = { amount = 0, scope = SCOPE_TIMESEL, live = true, status = "", statusErr = false }
  end
```

Change it to add `curveFit`:

```lua
  if not state.red then
    state.red = { amount = 0, scope = SCOPE_TIMESEL, live = true, status = "", statusErr = false, curveFit = false }
  end
```

- [ ] **Step 2: Branch `reducedAt` to the chosen thinner**

Replace the whole `reducedAt` function with this (it adds a local `thin` that picks `thinCurve` when `g.curveFit`, in both range and selected scopes):

```lua
local function reducedAt(g)
  local pts = base.orig
  if (g.amount or 0) <= 0 then return pts end
  local vmin, vmax = base.tgt:valueRange()
  local eps = amountFor(g.amount)
  local vr = { vmin = vmin, vmax = vmax }
  local function thin(p)
    if g.curveFit then
      return reduce.thinCurve(p, eps, vr, { envConvention = base.tgt:kind() ~= "cc" })
    end
    return reduce.thin(p, eps, vr)
  end
  if not base.selectedMode then
    return thin(pts)
  end
  local sel, unsel = {}, {}
  for _, p in ipairs(pts) do if p.sel then sel[#sel + 1] = p else unsel[#unsel + 1] = p end end
  local keptSel = thin(sel)
  local merged = {}
  for _, p in ipairs(unsel) do merged[#merged + 1] = p end
  for _, p in ipairs(keptSel) do merged[#merged + 1] = p end
  table.sort(merged, function(a, b) return a.time < b.time end)
  return merged
end
```

- [ ] **Step 3: Add the checkbox to the draw block**

In `M.draw`, the Scope combo block is immediately followed by the Reduction slider block:

```lua
  -- Reduction amount (0 = restore original; raise to thin). Notch + label double-click reset.
  do
    local changed
    changed, g.amount = reaper.ImGui_SliderInt(ctx, "Reduction##red_amt", g.amount, 0, 100, "%d%%")
    acc(changed); acc(common.tickReset(ctx, g, "amount", 0, 100, 0))
  end
```

Insert this block IMMEDIATELY BEFORE that Reduction block:

```lua
  -- Curve fit: thin using curved segments (REAPER per-point shapes) instead of straight lines, so a
  -- curve keeps its shape with far fewer points. Off = exact straight-line reduction.
  do
    local rv, v = reaper.ImGui_Checkbox(ctx, "Curve fit##red_curve", g.curveFit)
    if rv then g.curveFit = v; acc(true) end
  end
```

- [ ] **Step 4: Compile gate**

Run: `/c/Users/Dani/AppData/Local/Programs/Lua/bin/lua.exe -e 'assert(loadfile("Contour/ui/reduce.lua")) print("compile ok")'`
Expected: `compile ok`.

- [ ] **Step 5: Full suite (no regressions)**

Run: `for t in tests/test_*.lua; do /c/Users/Dani/AppData/Local/Programs/Lua/bin/lua.exe "$t" >/dev/null 2>&1 && echo "PASS $t" || echo "FAIL $t"; done`
Expected: every file PASS. (The UI itself is ReaImGui and not unit-tested in this codebase; correctness of `thinCurve` is covered by Task 1. The user verifies the checkbox in REAPER.)

- [ ] **Step 6: Commit (LOCAL ONLY)**

```bash
git add Contour/ui/reduce.lua
git commit -m "feat(reduce): Curve fit checkbox wired to thinCurve"
```

---

### Task 3 (OPTIONAL — needs REAPER calibration): bezier shape with fitted tension

Adds a 5th candidate — bezier (CC shape `5`) with a continuously-fitted tension — so a segment's bulge AMOUNT can be tuned, keeping even fewer points than the four fixed shapes. **Do Tasks 1–2 first and confirm them in REAPER before this.** The bezier easing model below is the one un-proven curve: if REAPER renders shape 5 differently from `e(x) = x + T*x*(1-x)`, the *result* (not the headless tests) will look off, and only the easing in `bez` needs adjusting.

**Files:**
- Modify: `Contour/core/reduce.lua` (`fitOne` gains a bezier branch)
- Test: `tests/test_reduce.lua` (append)

**Interfaces:**
- Consumes: the Task 1 internals (`CANDIDATES`, `fitOne`, `withShape`).
- Produces: kept points may now carry `shape = 5` with a non-zero `.tension` in [-1, 1]. (`withShape` must accept a tension argument — see Step 3.)

- [ ] **Step 1: Write the failing test**

Append to `tests/test_reduce.lua`:

```lua
h.test("thinCurve fits a bezier bulge with tension (shape 5)", function()
  -- A symmetric bulge above the chord that is NOT one of the fixed eases: value = x + 0.6*x*(1-x).
  local t = {}
  for i = 0, 20 do local x = i / 20; t[#t + 1] = { time = x, value = x + 0.6 * x * (1 - x) } end
  local out = reduce.thinCurve(t, 0.005, { vmin = 0, vmax = 1.5 })
  h.eq(#out, 2)
  h.eq(out[1].shape, 5)
  h.almost(out[1].tension, 0.6, 0.06)   -- tension recovered within the search step
end)
```

- [ ] **Step 2: Run it to verify it fails**

Run: `/c/Users/Dani/AppData/Local/Programs/Lua/bin/lua.exe tests/test_reduce.lua`
Expected: FAIL — the bulge currently fits the nearest fixed shape (not `5`), or tension stays 0.

- [ ] **Step 3: Implement the bezier branch**

In `Contour/core/reduce.lua`, change `withShape` to accept a tension:

```lua
local function withShape(p, shape, tension)
  return { time = p.time, value = p.value, shape = shape, tension = tension or 0, sel = p.sel }
end
```

Add the bezier easing + a 1-D tension search, then fold it into `fitOne`. Replace `fitOne` with:

```lua
-- Bezier easing: e(x) = x + T*x*(1-x), T in [-1,1] (T=0 linear; +bulge up, -bulge down). Same quadratic
-- form as the engine's freq-skew warp. NOTE: calibrate against REAPER's shape-5 rendering.
local function bezEase(x, T) return x + T * x * (1 - x) end

-- Max vertical error of a candidate ease over the interior of [i,j], with the peak index.
local function segErr(points, i, j, easeFn)
  local p0, p1 = points[i], points[j]
  local dt, dv = p1.time - p0.time, p1.value - p0.value
  local maxErr, maxK = 0, i + 1
  for k = i + 1, j - 1 do
    local pk = points[k]
    local x = (dt == 0) and 0 or (pk.time - p0.time) / dt
    local e = abs(pk.value - (p0.value + dv * easeFn(x)))
    if e > maxErr then maxErr, maxK = e, k end
  end
  return maxErr, maxK
end

local function fitOne(points, i, j)
  local best
  for _, cand in ipairs(CANDIDATES) do
    local err, k = segErr(points, i, j, cand.ease)
    if not best or err < best.err then best = { shape = cand.shape, tension = 0, err = err, splitIdx = k } end
  end
  -- Bezier: coarse scan of tension then refine, tracking the min-max-error fit.
  local bT, bErr, bK = 0, math.huge, i + 1
  for s = -10, 10 do
    local T = s / 10
    local err, k = segErr(points, i, j, function(x) return bezEase(x, T) end)
    if err < bErr then bT, bErr, bK = T, err, k end
  end
  local step = 0.05
  for _ = 1, 4 do
    for _, T in ipairs({ bT - step, bT + step }) do
      if T >= -1 and T <= 1 then
        local err, k = segErr(points, i, j, function(x) return bezEase(x, T) end)
        if err < bErr then bT, bErr, bK = T, err, k end
      end
    end
    step = step / 2
  end
  if bErr < best.err then best = { shape = 5, tension = bT, err = bErr, splitIdx = bK } end
  return best
end
```

Update `fitRange` to carry the tension through (the accept branch tags the point with `best.tension`):

```lua
local function fitRange(points, i, j, eps, linearShape)
  if j <= i + 1 then return { withShape(points[i], linearShape) } end
  local best = fitOne(points, i, j)
  if best.err <= eps then return { withShape(points[i], best.shape, best.tension) } end
  local out = fitRange(points, i, best.splitIdx, eps, linearShape)
  for _, p in ipairs(fitRange(points, best.splitIdx, j, eps, linearShape)) do out[#out + 1] = p end
  return out
end
```

- [ ] **Step 4: Run the tests to verify they pass**

Run: `/c/Users/Dani/AppData/Local/Programs/Lua/bin/lua.exe tests/test_reduce.lua`
Expected: PASS — including the new bezier test and all Task 1 tests (a pure slow/fast arc still prefers its exact fixed shape because that error is ~0, below any bezier fit).

- [ ] **Step 5: Full suite**

Run: `for t in tests/test_*.lua; do /c/Users/Dani/AppData/Local/Programs/Lua/bin/lua.exe "$t" >/dev/null 2>&1 && echo "PASS $t" || echo "FAIL $t"; done`
Expected: every file PASS.

- [ ] **Step 6: REAPER calibration (manual)**

In REAPER, Curve-fit a hand-drawn bulge on an envelope and a CC lane. If the kept bezier segments visibly bulge MORE or LESS than the original, adjust `bezEase` (the relationship between tension and curvature) and re-run Steps 4–5. The fixed shapes (1–4) need no calibration.

- [ ] **Step 7: Commit (LOCAL ONLY)**

```bash
git add Contour/core/reduce.lua tests/test_reduce.lua
git commit -m "feat(reduce): bezier candidate with fitted tension (calibrated in REAPER)"
```

---

## Self-Review

**Spec coverage:** fit-and-split algorithm (Task 1), candidate shapes 1–4 with exact models (Task 1, Global Constraints), bezier shape 5 + tension search (Task 3), vertical tolerance reuse (Task 1 `thinCurve`), native shape convention via `envConvention` (Task 1), `rawShape` write path unchanged (no write task needed — verified in spec), "Curve fit" checkbox + `reducedAt` branch + selected-scope handling (Task 2), non-destructive baseline/scopes/Reset/Live unchanged (Task 2 only swaps the thinner), straight-line behavior unchanged when off (Task 2 branch), tests incl. reconstruct-within-eps and fewer-than-rdp (Task 1). Bezier deferred to an explicitly-optional task to keep the proven core shippable first.

**Placeholder scan:** none — all steps carry full code and exact commands.

**Type consistency:** `thinCurve(points, amount, valueRange, opts)`, `opts.envConvention`, `withShape(p, shape[, tension])`, `fitOne`→`{shape, tension, err, splitIdx}`, `fitRange(points, i, j, eps, linearShape)`, point shape `.shape`/`.tension` are consistent across Tasks 1 and 3. `base.tgt:kind()` and `base.tgt:valueRange()` are existing target methods used in Task 2.
