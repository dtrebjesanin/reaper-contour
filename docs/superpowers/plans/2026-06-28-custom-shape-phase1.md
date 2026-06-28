# Custom Shape — Phase 1 Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add a **Custom** LFO shape: an in-panel draw pad (points + bendable bezier segments) defining one cycle, saved as named presets, repeated at the Rate by a `generateCustom` emitter.

**Architecture:** Pure core first — `core/customshape.lua` (preset data model + ExtState-safe serialization) and a `generateCustom` sparse emitter in `core/lfo.lua` (modeled on `generateSaw`/`generateTrapezoid`). Then the REAPER-bound UI — `ui/drawpad.lua` (a DrawList canvas that edits a points list) and `ui/generate.lua` integration (a `custom` shape, preset store/controls, draw pad, control visibility).

**Tech Stack:** Lua 5.4, ReaImGui, REAPER ExtState, the Contour test harness. Lua interpreter (NOT on PATH): `/c/Users/Dani/AppData/Local/Programs/Lua/bin/lua.exe`.

## Global Constraints

- BUILD LOCAL ONLY — commit locally, do NOT `git push`.
- `tests/test_native_match.lua` (35) stays green: Custom is a NEW, isolated path; touch no existing shape's code.
- Custom lives UNDER Generate (a `SHAPES` entry), reusing target detection / Rate / Amplitude / Baseline / Fade / live preview / write path. NOT a new top-level tab.
- Point data model: `{ x, y, shape, tension }` — x∈[0,1] (ascending; first 0, last 1), y∈[-1,1], shape int (1=linear … 5=bezier), tension∈[-1,1] (bezier only). Phase 1 freehand uses shape 1 (straight) and 5 (bent).
- Custom controls (Phase 1): Rate, Amplitude, Baseline, Phase, Amp skew, Tilt, Fade, Freq skew. HIDE Swing, Steps, Smooth, Pulse width, Edge, Attack, Curve.
- Presets persist in ExtState section `"Contour"`. ExtState `persist=true` values must be SINGLE-LINE (the .ini store breaks on newlines) — serialization uses inline delimiters with percent-escaping, never newlines.
- Run the FULL suite after every task: `for t in tests/test_*.lua; do /c/Users/Dani/AppData/Local/Programs/Lua/bin/lua.exe "$t" >/dev/null 2>&1 && echo "PASS $t" || echo "FAIL $t"; done`

## File Structure

- `Contour/core/customshape.lua` — NEW, pure: `defaultPreset()`, `encode(store)`, `decode(str)`, `clampPoints(points)`. No REAPER.
- `Contour/core/lfo.lua` — add `generateCustom` + a `custom` dispatch branch.
- `Contour/ui/drawpad.lua` — NEW, ReaImGui: `draw(ctx, points, opts) -> changed` (renders + edits a points list in place).
- `Contour/ui/generate.lua` — `SHAPES`/`SHAPE_OUTPUT` gain `custom`; state holds the preset store; preset controls + ExtState load/save; `buildParams` passes the active points; control visibility; draw pad call.
- `tests/test_customshape.lua` — NEW: serialization round-trip + `generateCustom`.

---

### Task 1: `core/customshape.lua` — data model + serialization

**Files:**
- Create: `Contour/core/customshape.lua`
- Test: `tests/test_customshape.lua` (create)

**Interfaces:**
- Produces:
  - `customshape.defaultPreset()` → `{ name="Triangle", points={ {x=0,y=-1,shape=1,tension=0}, {x=0.5,y=1,shape=1,tension=0}, {x=1,y=-1,shape=1,tension=0} } }`
  - `customshape.encode(store)` → single-line string. `store` = array of presets `{name, points}`.
  - `customshape.decode(str)` → `store` (array of presets); tolerant of malformed/empty input (returns `{}`).
  - `customshape.clampPoints(points)` → returns points sorted by x, x∈[0,1] (first forced to 0, last to 1), y clamped [-1,1], shape in {0..5}, tension [-1,1].

- [ ] **Step 1: Write the failing tests**

Create `tests/test_customshape.lua`:

```lua
package.path = package.path .. ";./Contour/?.lua;./?.lua;./tests/?.lua"
local h = require("harness")
local cs = require("core.customshape")

h.test("defaultPreset is a valid 3-point preset", function()
  local p = cs.defaultPreset()
  h.truthy(p.name and #p.name > 0, "has a name")
  h.eq(#p.points, 3)
  h.eq(p.points[1].x, 0); h.eq(p.points[#p.points].x, 1)
end)

h.test("encode/decode round-trips a multi-preset store (with tricky names)", function()
  local store = {
    { name = "Wub|3 ;,~ test", points = { { x = 0, y = -1, shape = 1, tension = 0 },
      { x = 0.4, y = 0.5, shape = 5, tension = -0.3 }, { x = 1, y = 1, shape = 2, tension = 0 } } },
    { name = "Plain", points = { { x = 0, y = 0, shape = 1, tension = 0 }, { x = 1, y = 0, shape = 1, tension = 0 } } },
  }
  local back = cs.decode(cs.encode(store))
  h.eq(#back, 2)
  h.eq(back[1].name, "Wub|3 ;,~ test")
  h.eq(#back[1].points, 3)
  h.almost(back[1].points[2].x, 0.4); h.almost(back[1].points[2].y, 0.5)
  h.eq(back[1].points[2].shape, 5); h.almost(back[1].points[2].tension, -0.3)
  h.eq(back[2].name, "Plain")
end)

h.test("decode tolerates empty / malformed input", function()
  h.eq(#cs.decode(""), 0)
  h.eq(#cs.decode("garbage~~~|||"), 0)   -- no valid presets -> empty store, no error
end)

h.test("clampPoints sorts, clamps, and pins endpoints", function()
  local out = cs.clampPoints({ { x = 0.9, y = 5, shape = 9, tension = 3 },
    { x = -0.2, y = -5, shape = 1, tension = 0 }, { x = 0.5, y = 0, shape = 5, tension = -0.4 } })
  h.eq(#out, 3)
  h.eq(out[1].x, 0); h.eq(out[#out].x, 1)                 -- endpoints pinned
  for _, p in ipairs(out) do
    h.truthy(p.y >= -1 and p.y <= 1, "y clamped")
    h.truthy(p.shape >= 0 and p.shape <= 5, "shape clamped")
    h.truthy(p.tension >= -1 and p.tension <= 1, "tension clamped")
  end
  for i = 2, #out do h.truthy(out[i].x >= out[i-1].x, "x ascending") end
end)

h.run()
```

- [ ] **Step 2: Run to verify failure**

Run: `/c/Users/Dani/AppData/Local/Programs/Lua/bin/lua.exe tests/test_customshape.lua`
Expected: FAIL — `module 'core.customshape' not found`.

- [ ] **Step 3: Implement `core/customshape.lua`**

Create `Contour/core/customshape.lua`:

```lua
-- core/customshape.lua — custom-shape preset data model + ExtState-safe serialization. PURE (no REAPER).
-- A point: { x in [0,1], y in [-1,1], shape (0..5 CC int), tension in [-1,1] }. A preset: { name, points }.
-- A store: array of presets. Serialization is SINGLE-LINE (ExtState persist=true breaks on newlines):
--   store   = preset ("|" preset)*
--   preset  = escName "~" point (";" point)*
--   point   = x "," y "," shape "," tension     (numbers via %.6g)
-- Names percent-escape the 5 delimiters so any name survives.
local M = {}
local floor = math.floor
local function clampn(v, lo, hi) v = tonumber(v) or 0; if v < lo then return lo elseif v > hi then return hi end return v end

function M.defaultPreset()
  return { name = "Triangle", points = {
    { x = 0, y = -1, shape = 1, tension = 0 },
    { x = 0.5, y = 1, shape = 1, tension = 0 },
    { x = 1, y = -1, shape = 1, tension = 0 },
  } }
end

-- Sort by x, clamp fields, pin first x=0 / last x=1.
function M.clampPoints(points)
  local out = {}
  for _, p in ipairs(points or {}) do
    out[#out + 1] = { x = clampn(p.x, 0, 1), y = clampn(p.y, -1, 1),
      shape = clampn(floor((tonumber(p.shape) or 1) + 0.5), 0, 5), tension = clampn(p.tension, -1, 1) }
  end
  table.sort(out, function(a, b) return a.x < b.x end)
  if #out > 0 then out[1].x = 0; out[#out].x = 1 end
  return out
end

local ESC = { ["%"] = "%25", ["|"] = "%7C", ["~"] = "%7E", [";"] = "%3B", [","] = "%2C" }
local function esc(s) return (tostring(s):gsub("[%%|~;,]", ESC)) end
local function unesc(s) return (tostring(s):gsub("%%(%x%x)", function(h) return string.char(tonumber(h, 16)) end)) end
local function num(v) return string.format("%.6g", tonumber(v) or 0) end

function M.encode(store)
  local presets = {}
  for _, pr in ipairs(store or {}) do
    local pts = {}
    for _, p in ipairs(pr.points or {}) do
      pts[#pts + 1] = table.concat({ num(p.x), num(p.y), num(p.shape or 1), num(p.tension or 0) }, ",")
    end
    presets[#presets + 1] = esc(pr.name or "") .. "~" .. table.concat(pts, ";")
  end
  return table.concat(presets, "|")
end

function M.decode(str)
  local store = {}
  if not str or str == "" then return store end
  for chunk in (str .. "|"):gmatch("(.-)|") do
    local namePart, ptsPart = chunk:match("^(.-)~(.*)$")
    if namePart then
      local pts = {}
      for ptStr in (ptsPart .. ";"):gmatch("(.-);") do
        if ptStr ~= "" then
          local x, y, sh, ten = ptStr:match("^([^,]*),([^,]*),([^,]*),([^,]*)$")
          if x then pts[#pts + 1] = { x = tonumber(x) or 0, y = tonumber(y) or 0,
            shape = tonumber(sh) or 1, tension = tonumber(ten) or 0 } end
        end
      end
      if #pts >= 1 then store[#store + 1] = { name = unesc(namePart), points = pts } end
    end
  end
  return store
end

return M
```

- [ ] **Step 4: Run to verify pass**

Run: `/c/Users/Dani/AppData/Local/Programs/Lua/bin/lua.exe tests/test_customshape.lua` → PASS (4 tests).

- [ ] **Step 5: Full suite + commit (LOCAL ONLY)**

Run the full suite (Global Constraints) → all PASS. Then:
```bash
git add Contour/core/customshape.lua tests/test_customshape.lua
git commit -m "feat(custom): customshape preset data model + ExtState-safe serialization"
```

---

### Task 2: `generateCustom` emitter

**Files:**
- Modify: `Contour/core/lfo.lua` (add `generateCustom` + dispatch)
- Modify: `Contour/ui/generate.lua` (`SHAPE_OUTPUT.custom`)
- Test: `tests/test_customshape.lua` (append)

**Interfaces:**
- Consumes: `p.customPoints` = `{ {x,y,shape,tension}, ... }` (clamped, x-ascending, first 0 / last 1).
- Produces: `lfo.generate({t0,t1}, {shape="custom", customPoints=…, rate=…, amplitude, baseline, …})` returns the placed points.

- [ ] **Step 1: Write the failing tests**

Append to `tests/test_customshape.lua` BEFORE its `h.run()` (note: this file already requires `cs`; add `lfo`):

```lua
-- (add near the top, after the cs require:)  local lfo = require("core.lfo")
-- generateCustom repeats the preset at the Rate, scales by amplitude/baseline, carries shapes/tensions.
local lfo = require("core.lfo")
local function customPts(extra)
  local p = { shape = "custom", rate = { mode = "free", cycles = 3 }, amplitude = 1, baseline = 0,
    customPoints = { { x = 0, y = -1, shape = 1, tension = 0 }, { x = 0.5, y = 1, shape = 5, tension = 0.5 },
      { x = 1, y = -1, shape = 1, tension = 0 } } }
  for k, v in pairs(extra or {}) do p[k] = v end
  return lfo.generate({ t0 = 0, t1 = 3 }, p)
end

h.test("custom repeats at the rate and covers the span", function()
  local pts = customPts()
  h.truthy(#pts >= 3, "produced points")
  h.almost(pts[1].time, 0, 1e-9); h.almost(pts[#pts].time, 3, 1e-9)
  for i = 2, #pts do h.truthy(pts[i].time > pts[i-1].time, "strictly increasing") end
  -- 3 cycles -> at least 3 peaks (value near +1) somewhere
  local peaks = 0
  for _, p in ipairs(pts) do if math.abs(p.value - 1) < 1e-6 then peaks = peaks + 1 end end
  h.truthy(peaks >= 3, "one peak per cycle (got " .. peaks .. ")")
end)

h.test("custom carries per-point bezier shape + tension", function()
  local bez = false
  for _, p in ipairs(customPts()) do if p.shape == 5 and math.abs((p.tension or 0) - 0.5) < 1e-9 then bez = true end end
  h.truthy(bez, "the mid point's bezier shape+tension is carried through")
end)

h.test("custom amp/freq skew does not densify (count stable)", function()
  local a = customPts()
  local b = customPts({ ampSkew = 0.7, freqSkew = 0.8 })
  h.eq(#a, #b, "skew must not change the custom point count")
end)

h.test("custom degenerate (no points) is a safe flat line", function()
  local pts = lfo.generate({ t0 = 0, t1 = 2 }, { shape = "custom", customPoints = {},
    rate = { mode = "free", cycles = 2 }, amplitude = 1, baseline = 0 })
  h.truthy(#pts >= 2, "still covers the span")
  h.almost(pts[1].time, 0, 1e-9); h.almost(pts[#pts].time, 2, 1e-9)
end)
```

- [ ] **Step 2: Run to verify failure**

Run: `/c/Users/Dani/AppData/Local/Programs/Lua/bin/lua.exe tests/test_customshape.lua`
Expected: FAIL — custom shape not handled (empty/garbage points).

- [ ] **Step 3: Implement `generateCustom` + dispatch**

In `Contour/core/lfo.lua`, add `generateCustom` next to `generateTrapezoid`/`generateRectsine` (it uses the same in-scope helpers: `floor`, `ceil`, `max`, `min`, `M.freqWarpInverse`, `M.fadeDepth`, `ampHalf`):

```lua
-- Custom: a user-drawn one-cycle shape (points {x in [0,1], y in [-1,1], shape, tension}) repeated at
-- the Rate. SPARSE emitter like generateSaw: interior points per cycle + a saw-style boundary (cycle-
-- END value then next cycle-START value one eps later) so a discontinuous boundary renders as a jump
-- and a seamless one is a harmless flat eps-segment. PHASE/FREQ-SKEW/AMP-SKEW/TILT/FADE apply.
local function generateCustom(t0, t1, spanLen, totalCycles, p, amp, baseV, ampSkew, freqSkew, tiltOffset)
  local N = totalCycles
  local phase = p.phase or 0
  local cp = p.customPoints or {}
  local function emit(pts, rel, y, shp, ten)
    if rel < 0 then rel = 0 elseif rel > 1 then rel = 1 end
    local depth = M.fadeDepth(rel, p.fadeIn, p.fadeOut)
    local half = ampHalf(amp, ampSkew, rel)
    pts[#pts + 1] = { time = t0 + rel * spanLen, value = baseV + half * y * depth + tiltOffset * rel, shape = shp, tension = ten }
  end
  if #cp < 2 then
    local y = (cp[1] and cp[1].y) or 0
    local pts = {}; emit(pts, 0, y, 1, 0); emit(pts, 1, y, 1, 0); return pts
  end
  -- linear value of the custom curve at shape-phase x (span-edge anchors only; per-segment SHAPE is
  -- carried on the emitted points, not recomputed here).
  local function valAtX(x)
    x = x - floor(x)
    for i = 1, #cp - 1 do
      if x >= cp[i].x - 1e-12 and x <= cp[i + 1].x + 1e-12 then
        local w = cp[i + 1].x - cp[i].x
        local t = (w > 1e-9) and (x - cp[i].x) / w or 0
        return cp[i].y + (cp[i + 1].y - cp[i].y) * t
      end
    end
    return cp[#cp].y
  end
  local eps = math.min(1e-4, 0.25 / N)
  local samp = {}
  for c = floor(-phase) - 1, ceil(N) + 1 do
    for i = 1, #cp do
      local x = cp[i].x
      if x > 1e-9 and x < 1 - 1e-9 then
        local prog = (c + x + phase) / N
        if prog > 1e-9 and prog < 1 - 1e-9 then
          samp[#samp + 1] = { rel = M.freqWarpInverse(prog, freqSkew), y = cp[i].y, shp = cp[i].shape or 1, ten = cp[i].tension or 0 }
        end
      end
    end
    local prog = (c + phase) / N                              -- cycle boundary at shape-phase c
    if prog > 1e-9 and prog < 1 - 1e-9 then
      local relB = M.freqWarpInverse(prog, freqSkew)
      samp[#samp + 1] = { rel = relB, y = cp[#cp].y, shp = 1, ten = 0 }                                    -- prev cycle end (x=1) -> wrap
      samp[#samp + 1] = { rel = relB + eps, y = cp[1].y, shp = cp[1].shape or 1, ten = cp[1].tension or 0 } -- this cycle start (x=0)
    end
  end
  samp[#samp + 1] = { rel = 0, y = valAtX(-phase), shp = cp[1].shape or 1, ten = cp[1].tension or 0 }
  samp[#samp + 1] = { rel = 1, y = valAtX(N - phase), shp = 1, ten = 0 }
  table.sort(samp, function(a, b) return a.rel < b.rel end)
  local pts, lastRel = {}, nil
  for _, s in ipairs(samp) do
    if lastRel == nil or s.rel - lastRel > 1e-9 then emit(pts, s.rel, s.y, s.shp, s.ten); lastRel = s.rel end
  end
  return pts
end
```

Add the dispatch branch in `M.generate` next to the trapezoid/rectsine branches (BEFORE the generic sampler):

```lua
  -- CUSTOM: user-drawn one-cycle shape repeated at the Rate. (Smooth/Steps are Phase 2; the guard is
  -- inert now since they're hidden for Custom.)
  if p.shape == "custom" and (p.smooth or 0) == 0 and not p.quantizeSteps then
    return generateCustom(t0, t1, spanLen, totalCycles, p, amp, baseV, ampSkew, freqSkew, tiltOffset)
  end
```

In `Contour/ui/generate.lua`, add to `SHAPE_OUTPUT` (near the other dedicated emitters):
```lua
  custom     = { ppc = 8,  ccShape = 1 },   -- user-drawn; dedicated emitter tags per-point shapes
```

- [ ] **Step 4: Run to verify pass**

Run: `/c/Users/Dani/AppData/Local/Programs/Lua/bin/lua.exe tests/test_customshape.lua` → PASS.

- [ ] **Step 5: Full suite (native match green) + commit**

Full suite → all PASS, incl. `test_native_match.lua` (35) unaffected. Then:
```bash
git add Contour/core/lfo.lua Contour/ui/generate.lua tests/test_customshape.lua
git commit -m "feat(custom): generateCustom emitter (one-cycle drawn shape repeated at the rate)"
```

---

### Task 3: `ui/drawpad.lua` — the draw pad widget

**Files:**
- Create: `Contour/ui/drawpad.lua`

**Interfaces:**
- Consumes: a `points` table (`{ {x,y,shape,tension}, ... }`, clamped) it edits IN PLACE; `core.customshape.clampPoints` for re-normalizing after edits.
- Produces: `drawpad.draw(ctx, points, opts) -> changed` (boolean). `opts = { width, height, id }`. Renders a grid + the curve + draggable point handles; handles add/move/delete points and segment-bend (bezier tension). Returns true if `points` changed this frame (so Generate's Live re-applies).

REAPER-bound: NO headless test. Verification = the compile gate + in-REAPER use with the user. The code below is the starting point; interaction (hit radii, bend feel) gets tuned in REAPER.

- [ ] **Step 1: Create `Contour/ui/drawpad.lua`**

```lua
-- ui/drawpad.lua — in-panel custom-shape draw pad (ReaImGui DrawList). Edits a points list in place:
--   click empty -> add point; drag point -> move; right-click / double-click point -> delete
--   (endpoints x are pinned to 0/1, y movable); drag a segment's middle -> bend it (bezier tension).
-- Pure-ish: no ExtState; the caller owns persistence. Guarded so it no-ops if DrawList APIs are absent.
local M = {}
local cs = require("core.customshape")
local floor, abs, min, max = math.floor, math.abs, math.min, math.max

local GRID = 0x3A434BFF
local AXIS = 0x55636EFF
local CURVE = 0x48C6D4FF
local PT = 0x9FE9F1FF
local PTHOT = 0xFFFFFFFF
local BG = 0x10151AFF

local drag = { idx = nil, seg = nil }   -- which point or segment is being dragged (module-level, single pad)

-- map data (x in [0,1], y in [-1,1]) <-> screen
local function toScreen(px, py, x0, y0, w, hgt) return x0 + px * w, y0 + (1 - (py + 1) / 2) * hgt end
local function toData(sx, sy, x0, y0, w, hgt)
  local x = (w > 0) and (sx - x0) / w or 0
  local y = (hgt > 0) and (1 - (sy - y0) / hgt) * 2 - 1 or 0
  return max(0, min(1, x)), max(-1, min(1, y))
end

-- bezier value-fraction model (matches the engine's freq-skew quadratic; calibrate vs REAPER bezier)
local function ease(shape, t, ten)
  if shape == 5 then return t + ten * t * (1 - t) end
  if shape == 2 then return (1 - math.cos(math.pi * t)) / 2 end
  if shape == 3 then return math.sin(math.pi * t / 2) end
  if shape == 4 then return 1 - math.cos(math.pi * t / 2) end
  return t
end

function M.draw(ctx, points, opts)
  opts = opts or {}
  if not (reaper.ImGui_GetWindowDrawList and reaper.ImGui_DrawList_AddLine and reaper.ImGui_InvisibleButton
      and reaper.ImGui_GetCursorScreenPos and reaper.ImGui_GetMousePos) then
    reaper.ImGui_Text(ctx, "(draw pad needs a newer ReaImGui)"); return false
  end
  local w = opts.width or 360
  local hgt = opts.height or 140
  local x0, y0 = reaper.ImGui_GetCursorScreenPos(ctx)
  reaper.ImGui_InvisibleButton(ctx, opts.id or "##drawpad", w, hgt)
  local hovered = reaper.ImGui_IsItemHovered(ctx)
  local active = reaper.ImGui_IsItemActive(ctx)
  local mx, my = reaper.ImGui_GetMousePos(ctx)
  local dl = reaper.ImGui_GetWindowDrawList(ctx)
  local changed = false

  -- background + grid
  reaper.ImGui_DrawList_AddRectFilled(dl, x0, y0, x0 + w, y0 + hgt, BG, 4)
  for i = 0, 4 do local gx = x0 + i / 4 * w; reaper.ImGui_DrawList_AddLine(dl, gx, y0, gx, y0 + hgt, GRID, 1) end
  reaper.ImGui_DrawList_AddLine(dl, x0, y0 + hgt / 2, x0 + w, y0 + hgt / 2, AXIS, 1)   -- center (y=0)

  -- pointer hit-test (nearest point)
  local HR = 9
  local hotPt = nil
  if hovered then
    for i, p in ipairs(points) do
      local sx, sy = toScreen(p.x, p.y, x0, y0, w, hgt)
      if abs(mx - sx) <= HR and abs(my - sy) <= HR then hotPt = i; break end
    end
  end

  -- begin gestures on mouse-down
  if active and reaper.ImGui_IsMouseClicked(ctx, 0) then
    if hotPt then drag.idx, drag.seg = hotPt, nil
    else
      -- segment under cursor? (between two points, away from a point) -> bend; else add a point
      local seg = nil
      for i = 1, #points - 1 do
        local ax, ay = toScreen(points[i].x, points[i].y, x0, y0, w, hgt)
        local bx, by = toScreen(points[i + 1].x, points[i + 1].y, x0, y0, w, hgt)
        if mx >= min(ax, bx) - 2 and mx <= max(ax, bx) + 2 then
          local t = (bx - ax ~= 0) and (mx - ax) / (bx - ax) or 0
          local ly = ay + (by - ay) * t
          if abs(my - ly) <= 8 then seg = i; break end
        end
      end
      if seg then drag.idx, drag.seg = nil, seg
      else
        local nx, ny = toData(mx, my, x0, y0, w, hgt)
        points[#points + 1] = { x = nx, y = ny, shape = 1, tension = 0 }
        local clamped = cs.clampPoints(points)
        for k = #points, 1, -1 do points[k] = nil end
        for k = 1, #clamped do points[k] = clamped[k] end
        changed = true; drag.idx, drag.seg = nil, nil
      end
    end
  end

  -- delete on right-click / double-click a point (not endpoints)
  if hotPt and hotPt > 1 and hotPt < #points
     and (reaper.ImGui_IsMouseClicked(ctx, 1) or reaper.ImGui_IsMouseDoubleClicked(ctx, 0)) then
    table.remove(points, hotPt); changed = true; drag.idx, drag.seg = nil, nil
  end

  -- continue drag
  if active and reaper.ImGui_IsMouseDown(ctx, 0) then
    if drag.idx then
      local p = points[drag.idx]
      if p then
        local nx, ny = toData(mx, my, x0, y0, w, hgt)
        if drag.idx == 1 then nx = 0 elseif drag.idx == #points then nx = 1
        else nx = max(points[drag.idx - 1].x + 1e-3, min(points[drag.idx + 1].x - 1e-3, nx)) end
        p.x, p.y = nx, ny; changed = true
      end
    elseif drag.seg then
      local a, b = points[drag.seg], points[drag.seg + 1]
      if a and b then
        local ax, ay = toScreen(a.x, a.y, x0, y0, w, hgt)
        local bx, by = toScreen(b.x, b.y, x0, y0, w, hgt)
        local midY = (ay + by) / 2
        local ten = max(-1, min(1, (midY - my) / (hgt / 2)))   -- drag up -> +tension
        a.shape = (abs(ten) > 1e-3) and 5 or 1; a.tension = ten; changed = true
      end
    end
  end
  if not reaper.ImGui_IsMouseDown(ctx, 0) then drag.idx, drag.seg = nil, nil end

  -- draw the curve (sample each segment by its ease)
  for i = 1, #points - 1 do
    local a, b = points[i], points[i + 1]
    local ax, ay = toScreen(a.x, a.y, x0, y0, w, hgt)
    local bx, by = toScreen(b.x, b.y, x0, y0, w, hgt)
    local steps = (a.shape == 1) and 1 or 16
    local px, py = ax, ay
    for s = 1, steps do
      local t = s / steps
      local yv = a.y + (b.y - a.y) * ease(a.shape or 1, t, a.tension or 0)
      local qx, qy = toScreen(a.x + (b.x - a.x) * t, yv, x0, y0, w, hgt)
      reaper.ImGui_DrawList_AddLine(dl, px, py, qx, qy, CURVE, 2)
      px, py = qx, qy
    end
  end
  -- draw point handles
  for i, p in ipairs(points) do
    local sx, sy = toScreen(p.x, p.y, x0, y0, w, hgt)
    reaper.ImGui_DrawList_AddCircleFilled(dl, sx, sy, (i == hotPt) and 5 or 3.5, (i == hotPt) and PTHOT or PT)
  end

  return changed
end

return M
```

- [ ] **Step 2: Compile gate**

Run: `/c/Users/Dani/AppData/Local/Programs/Lua/bin/lua.exe -e 'assert(loadfile("Contour/ui/drawpad.lua")) print("compile ok")'`
Expected: `compile ok`.

- [ ] **Step 3: Full suite (unaffected) + commit**

Full suite → all PASS (no engine change). Then:
```bash
git add Contour/ui/drawpad.lua
git commit -m "feat(custom): draw pad widget (points + bendable segments)"
```

REAPER verification deferred to Task 4 (the pad isn't wired into the panel until then).

---

### Task 4: Integrate Custom into the Generate panel

**Files:**
- Modify: `Contour/ui/generate.lua` (`SHAPES`, state init, ExtState preset store, preset controls, draw pad call, `buildParams`, control visibility)

**Interfaces:**
- Consumes: `core.customshape` (`defaultPreset`, `encode`, `decode`, `clampPoints`); `ui.drawpad.draw`; `core.lfo` `generateCustom` (via `shape="custom"` + `customPoints`).
- Produces: a working **Custom** shape in the panel.

REAPER-bound: verification = compile gate + full suite + in-REAPER use with the user.

- [ ] **Step 1: Add `custom` to the dropdown + requires**

In `Contour/ui/generate.lua`, add to `SHAPES` (after `sine2`, before `random`):
```lua
  { id = "custom",     label = "Custom (draw)" },
```
Add near the top requires:
```lua
local customshape = require("core.customshape")
local drawpad = require("ui.drawpad")
```

- [ ] **Step 2: Preset store in state + ExtState load/save helpers**

In the `ui(state)` initializer (where `state.gen` is built), after the existing fields add the custom store (loaded from ExtState once):
```lua
      custom = nil,   -- { store = { presets }, idx = <active 1-based> }; lazily loaded from ExtState
```
Add these module-local helpers above `M.draw` (ExtState section `"Contour"`, key `"customPresets"` / `"customIdx"`):
```lua
local function loadCustom()
  local store = customshape.decode(reaper.GetExtState("Contour", "customPresets") or "")
  if #store == 0 then store = { customshape.defaultPreset() } end
  for _, pr in ipairs(store) do pr.points = customshape.clampPoints(pr.points) end
  local idx = tonumber(reaper.GetExtState("Contour", "customIdx") or "") or 1
  if idx < 1 or idx > #store then idx = 1 end
  return { store = store, idx = idx }
end
local function saveCustom(c)
  reaper.SetExtState("Contour", "customPresets", customshape.encode(c.store), true)
  reaper.SetExtState("Contour", "customIdx", tostring(c.idx), true)
end
local function activePoints(g)
  if not g.custom then g.custom = loadCustom() end
  local pr = g.custom.store[g.custom.idx]
  return pr and pr.points or {}
end
```

- [ ] **Step 3: Draw pad + preset controls (shown only for Custom)**

In `M.draw`, right after the Shape combo block, insert:
```lua
    if currentShapeId(g) == "custom" then
      if not g.custom then g.custom = loadCustom() end
      local c = g.custom
      -- preset dropdown
      local names = {}
      for _, pr in ipairs(c.store) do names[#names + 1] = pr.name end
      local items = table.concat(names, "\0") .. "\0"
      local chg, idx = reaper.ImGui_Combo(ctx, "Preset##cust_preset", c.idx - 1, items, #items)
      if chg then c.idx = idx + 1; saveCustom(c); acc(true) end
      reaper.ImGui_SameLine(ctx)
      if reaper.ImGui_Button(ctx, "New##cust_new") then
        c.store[#c.store + 1] = { name = "Custom " .. (#c.store + 1), points = customshape.clampPoints(customshape.defaultPreset().points) }
        c.idx = #c.store; saveCustom(c); acc(true)
      end
      reaper.ImGui_SameLine(ctx)
      if reaper.ImGui_Button(ctx, "Del##cust_del") and #c.store > 1 then
        table.remove(c.store, c.idx); if c.idx > #c.store then c.idx = #c.store end; saveCustom(c); acc(true)
      end
      -- rename (inline text)
      do
        local pr = c.store[c.idx]
        local rv, nm = reaper.ImGui_InputText(ctx, "Name##cust_name", pr.name or "")
        if rv then pr.name = nm; saveCustom(c) end
      end
      -- the pad
      local padW = reaper.ImGui_GetContentRegionAvail and select(1, reaper.ImGui_GetContentRegionAvail(ctx)) or 360
      local padChanged = drawpad.draw(ctx, c.store[c.idx].points, { width = padW, height = 140, id = "##cust_pad" })
      if padChanged then c.store[c.idx].points = customshape.clampPoints(c.store[c.idx].points); saveCustom(c); acc(true) end
    end
```
(`acc` is the panel's existing edit accumulator — a change here drives Live re-apply, same as the sliders.)

- [ ] **Step 4: Pass the active points in `buildParams`**

In `buildParams`, add to the returned `params` table:
```lua
    customPoints  = (shape == "custom") and activePoints(g) or nil,
```

- [ ] **Step 5: Control visibility for Custom**

Custom is a normal periodic shape minus Swing/Steps/Smooth. Where the panel hides per-shape controls, gate them so Custom hides Swing, Steps, and Smooth (it already won't show Pulse width/Edge/Attack/Curve, which are matched to other shapes). Concretely:
- Swing block: change `if not special and sid ~= "triangle" then` to `if not special and sid ~= "triangle" and sid ~= "custom" then`.
- Steps block: add `and sid ~= "custom"` to its condition.
- Smooth block: add `and sid ~= "custom"` to its condition.
(Rate, Amplitude, Baseline, Phase, Amp skew, Tilt, Fade, Freq skew remain shown — they are not shape-gated.)

- [ ] **Step 6: Compile gate + full suite**

Run: `/c/Users/Dani/AppData/Local/Programs/Lua/bin/lua.exe -e 'for _,f in ipairs({"Contour/ui/generate.lua","Contour/ui/drawpad.lua","Contour/core/customshape.lua","Contour/core/lfo.lua"}) do assert(loadfile(f)) end print("ok")'` → `ok`.
Full suite → all PASS (`test_native_match.lua` 35 green; nothing else regressed).

- [ ] **Step 7: Commit (LOCAL ONLY)**

```bash
git add Contour/ui/generate.lua
git commit -m "feat(custom): wire Custom shape into the Generate panel (preset store + draw pad)"
```

- [ ] **Step 8: REAPER verification (with the user)**

In REAPER: Shape → Custom (draw). Confirm: the pad shows; add/move/delete points; bend a segment; Generate writes the repeated custom shape on envelope/AI/CC; presets New/Del/Rename persist across a panel reload; Phase/Amp/Freq-skew compose. Iterate hit radii / bend feel as needed.

---

## Self-Review

**Spec coverage:** data model `{x,y,shape,tension}` (Task 1); ExtState-safe single-line serialization (Task 1, Global Constraints); `generateCustom` sparse emitter repeating at Rate with boundary jumps + phase/freq-skew/amp-skew/tilt/fade (Task 2); draw pad add/move/delete/bend (Task 3); placement under Generate as a `SHAPES` entry, reusing all Generate plumbing (Task 4); multiple presets New/Save(implicit on edit)/Rename/Delete persisted in ExtState (Task 4); control visibility = Rate/Amp/Baseline/Phase/Amp-skew/Tilt/Fade/Freq-skew, hide Swing/Steps/Smooth (Task 4 Step 5); native match isolated (Tasks 2/4 run it). Pure core headless-tested; UI compile-gated + REAPER-verified (matches the codebase's UI testing norm).

**Placeholder scan:** none — full code for the pure core, complete concrete code for the UI, exact commands.

**Type consistency:** point `{x,y,shape,tension}` and preset `{name,points}` consistent across customshape (Task 1), generateCustom `p.customPoints` (Task 2), drawpad `points` (Task 3), and the panel's `activePoints`/`buildParams.customPoints` (Task 4). `customshape.{defaultPreset,encode,decode,clampPoints}` and `drawpad.draw(ctx,points,opts)->changed` signatures match their call sites.

**Note (Phase 2/3 ready):** `point.shape` already carries 0–5, so Phase 2 (Steps/Smooth → a value-sampling path) and Phase 3 (stamp palette populating shapes 2/3/4) are additive. The draw pad's `ease()` covers all shapes already for preview.
