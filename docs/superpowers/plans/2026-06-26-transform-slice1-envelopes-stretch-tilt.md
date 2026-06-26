# Transform — Slice 1 (Track Envelopes · Stretch + Tilt) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Ship the Transform overlay's first usable slice — arm from Contour (or hotkey) on a track envelope, draw zones over the selected/in-time-selection points, and drag to **Stretch** (time) or **Tilt** (value) the real points live, committing as one undo point.

**Architecture:** Pure transform math (`core/transform.lua`) and pure coordinate mapping (`core/arrangecoords.lua`) are headless-tested. The overlay (`ui/overlay.lua` + entry `contour_transform.lua`) is the Reaper-bound engine: a transparent ReaImGui window positioned over the arrange via js_ReaScriptAPI, mouse read via js, lane/time geometry via native API + SWS hit-test. The write **reuses** the existing `target:read` + `target:writeBulk(…, rawShape=true)` path (same replace-in-range model as Reduce), wrapped in `PreventUIRefresh`, inside one undo block.

**Tech Stack:** Lua 5.4 · ReaImGui (`reaper.ImGui_*`) · js_ReaScriptAPI (`reaper.JS_*`) · SWS (`reaper.BR_*`) · native ReaScript envelope/arrange API · headless tests via `lua.exe`.

## Global Constraints

- Pure core modules (`core/transform.lua`, `core/arrangecoords.lua`) contain **zero `reaper.*`** — headless-testable.
- Headless tests run with: `/c/Users/Dani/AppData/Local/Programs/Lua/bin/lua.exe tests/test_<name>.lua` (lua.exe is NOT on PATH; use the full path).
- Tests use the existing harness: `local h = require("harness")`, `h.test(name, fn)`, `h.eq(a,b[,msg])`, `h.almost(a,b,tol[,msg])`, `h.truthy(v[,msg])`, `h.run()`. Each test file begins with `package.path = package.path .. ";./?.lua;./tests/?.lua"`.
- Run all tests from the repo root `C:\Users\Dani\reaper-lfo-toolkit`.
- Point list shape used throughout: an array of `{ t=<number>, v=<number>, shape=<int>, tension=<number>, sel=<bool> }`. `t` is project seconds; `v` is the envelope's DISPLAY-domain value (fader scaling converted by the overlay before/after). Transform functions PRESERVE `shape`/`tension`/`sel` and change only `t` (stretch) or `v` (tilt).
- Slice 1 targets **track envelopes only** (automation items = slice 3, MIDI CC = slice 4). Use the existing `ENV` target in `core/target.lua`.
- Dependencies must be guarded at launch with a friendly message if missing (mirror the ReaImGui guard in `contour.lua`): require `reaper.JS_Window_FindChildByID` (js_ReaScriptAPI), `reaper.ImGui_CreateContext` (ReaImGui), `reaper.BR_GetMouseCursorContext` (SWS).
- Curve knob is `-100..100`; steepness `w = 2^(knob/100 * 2.2)`; `knob=0 ⇒ w=1 ⇒ linear`.
- Commit message trailer for every commit: `Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>`.

---

### Task 1: `core/transform.lua` — the curve function

**Files:**
- Create: `core/transform.lua`
- Test: `tests/test_transform.lua`

**Interfaces:**
- Produces: `transform.curve(x, knob, shape) -> number`. `x∈[0,1]`, `knob∈[-100,100]`, `shape∈{"power","sine"}`. Returns `f∈[0,1]`, monotonic non-decreasing, `f(0)=0`, `f(1)=1`. `knob=0` ⇒ identity for power.

- [ ] **Step 1: Write the failing test**

Create `tests/test_transform.lua`:

```lua
package.path = package.path .. ";./?.lua;./tests/?.lua"
local h = require("harness")
local tr = require("core.transform")

h.test("curve: endpoints fixed for any knob/shape", function()
  for _, k in ipairs({-100, -40, 0, 40, 100}) do
    for _, s in ipairs({"power", "sine"}) do
      h.almost(tr.curve(0, k, s), 0, 1e-9, "f(0)")
      h.almost(tr.curve(1, k, s), 1, 1e-9, "f(1)")
    end
  end
end)

h.test("curve: knob 0 power is identity", function()
  h.almost(tr.curve(0.25, 0, "power"), 0.25, 1e-9)
  h.almost(tr.curve(0.5, 0, "power"), 0.5, 1e-9)
end)

h.test("curve: positive knob bends below the diagonal (power)", function()
  h.truthy(tr.curve(0.5, 100, "power") < 0.5, "steeper => 0.5^w < 0.5")
  h.truthy(tr.curve(0.5, 40, "power") < 0.5)
end)

h.test("curve: monotonic non-decreasing", function()
  local prev = -1
  for i = 0, 20 do
    local x = i / 20
    local f = tr.curve(x, 60, "sine")
    h.truthy(f >= prev - 1e-9, "monotonic at x=" .. x)
    prev = f
  end
end)

h.run()
```

- [ ] **Step 2: Run test to verify it fails**

Run: `/c/Users/Dani/AppData/Local/Programs/Lua/bin/lua.exe tests/test_transform.lua`
Expected: FAIL (`module 'core.transform' not found`).

- [ ] **Step 3: Write minimal implementation**

Create `core/transform.lua`:

```lua
-- core/transform.lua — PURE geometric transforms for the Transform overlay. Zero reaper.*, headless.
-- Points are arrays of { t=<sec>, v=<display value>, shape, tension, sel }; transforms PRESERVE the
-- non-coordinate fields and change only t (time ops) or v (value ops).
local M = {}

-- Shared bend curve. x,f in [0,1]; f(0)=0, f(1)=1; monotonic. knob -100..100 (0=linear); shape:
-- "power" => x^w ; "sine" => ((1-cos(pi x))/2)^w. w = 2^(knob/100 * 2.2) so knob 0 => w 1 (straight).
function M.curve(x, knob, shape)
  if x <= 0 then return 0 elseif x >= 1 then return 1 end
  local w = 2 ^ ((knob or 0) / 100 * 2.2)
  if shape == "sine" then
    local s = (1 - math.cos(math.pi * x)) / 2
    return s ^ w
  end
  return x ^ w
end

return M
```

- [ ] **Step 4: Run test to verify it passes**

Run: `/c/Users/Dani/AppData/Local/Programs/Lua/bin/lua.exe tests/test_transform.lua`
Expected: PASS (4 passed, 0 failed).

- [ ] **Step 5: Commit**

```bash
git add core/transform.lua tests/test_transform.lua
git commit -m "Add transform curve function (pure)

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"
```

---

### Task 2: `core/transform.lua` — Stretch (time)

**Files:**
- Modify: `core/transform.lua`
- Test: `tests/test_transform.lua`

**Interfaces:**
- Produces: `transform.stretch(points, anchorT, factor) -> newPoints`. Returns a NEW array of shallow-copied points with `t' = anchorT + factor*(t - anchorT)`; `v`/`shape`/`tension`/`sel` copied unchanged. `factor=1` ⇒ identity. Negative factor reverses order in time (caller re-sorts on write).

- [ ] **Step 1: Write the failing test**

Append to `tests/test_transform.lua` (before `h.run()`):

```lua
local function P(t, v) return { t = t, v = v, shape = 1, tension = 0, sel = true } end

h.test("stretch: factor 1 is identity", function()
  local out = tr.stretch({ P(0,0.2), P(1,0.5), P(2,0.8) }, 2, 1)
  h.eq(out[1].t, 0); h.eq(out[2].t, 1); h.eq(out[3].t, 2)
  h.eq(out[2].v, 0.5); h.eq(out[2].sel, true)  -- value + fields preserved
end)

h.test("stretch: factor 2 about right anchor expands to the left", function()
  local out = tr.stretch({ P(0,0), P(1,0), P(2,0) }, 2, 2)  -- anchor t=2
  h.almost(out[1].t, -2, 1e-9)   -- 2 + 2*(0-2)
  h.almost(out[2].t, 0,  1e-9)   -- 2 + 2*(1-2)
  h.almost(out[3].t, 2,  1e-9)   -- anchor fixed
end)

h.test("stretch: returns a new array, does not mutate input", function()
  local src = { P(0,0), P(1,0) }
  local out = tr.stretch(src, 1, 3)
  h.eq(src[1].t, 0, "input untouched")
  h.truthy(out ~= src)
end)
```

- [ ] **Step 2: Run test to verify it fails**

Run: `/c/Users/Dani/AppData/Local/Programs/Lua/bin/lua.exe tests/test_transform.lua`
Expected: FAIL (`attempt to call a nil value (field 'stretch')`).

- [ ] **Step 3: Write minimal implementation**

Add to `core/transform.lua` (before `return M`):

```lua
-- Shallow-copy a point, overriding t and/or v.
local function copy(p, t, v)
  return { t = t or p.t, v = v or p.v, shape = p.shape, tension = p.tension, sel = p.sel }
end

-- Stretch positions in time about anchorT by factor: t' = anchorT + factor*(t-anchorT).
function M.stretch(points, anchorT, factor)
  local out = {}
  for i = 1, #points do
    local p = points[i]
    out[i] = copy(p, anchorT + factor * (p.t - anchorT), nil)
  end
  return out
end
```

- [ ] **Step 4: Run test to verify it passes**

Run: `/c/Users/Dani/AppData/Local/Programs/Lua/bin/lua.exe tests/test_transform.lua`
Expected: PASS (7 passed, 0 failed).

- [ ] **Step 5: Commit**

```bash
git add core/transform.lua tests/test_transform.lua
git commit -m "Add transform stretch (time) (pure)

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"
```

---

### Task 3: `core/transform.lua` — Tilt (value)

**Files:**
- Modify: `core/transform.lua`
- Test: `tests/test_transform.lua`

**Interfaces:**
- Produces: `transform.tilt(points, tmin, tmax, delta, opts) -> newPoints`. `opts = { knob=<-100..100>, shape="power"|"sine", side="left"|"right", symmetrical=<bool> }`. `v' = v + delta * g`, where (with `relT=(t-tmin)/(tmax-tmin)`): `symmetrical` ⇒ `g=curve(1-|2relT-1|)` (dome); else `side=="left"` ⇒ `g=curve(1-relT)`; else `g=curve(relT)`. `t`/fields preserved. Values are NOT clamped here (the writer clamps to the envelope range).

- [ ] **Step 1: Write the failing test**

Append to `tests/test_transform.lua` (before `h.run()`):

```lua
local function vals(out) local r={} for i=1,#out do r[i]=out[i].v end return r end

h.test("tilt right (linear): left end fixed, right end lifts by delta", function()
  local pts = { P(0,0.5), P(0.5,0.5), P(1,0.5) }
  local out = tr.tilt(pts, 0, 1, 0.4, { knob=0, shape="power", side="right", symmetrical=false })
  h.almost(out[1].v, 0.5, 1e-9)   -- relT 0, g 0
  h.almost(out[2].v, 0.7, 1e-9)   -- relT .5, g .5
  h.almost(out[3].v, 0.9, 1e-9)   -- relT 1, g 1
  h.eq(out[1].t, 0)               -- time preserved
end)

h.test("tilt left (linear): right end fixed, left end lifts", function()
  local out = tr.tilt({ P(0,0.5), P(1,0.5) }, 0, 1, 0.4, { knob=0, shape="power", side="left", symmetrical=false })
  h.almost(out[1].v, 0.9, 1e-9)
  h.almost(out[2].v, 0.5, 1e-9)
end)

h.test("tilt symmetrical: ends fixed, centre lifts (dome)", function()
  local out = tr.tilt({ P(0,0.5), P(0.5,0.5), P(1,0.5) }, 0, 1, 0.4, { knob=0, shape="power", side="right", symmetrical=true })
  h.almost(out[1].v, 0.5, 1e-9)
  h.almost(out[2].v, 0.9, 1e-9)   -- m=1 at centre
  h.almost(out[3].v, 0.5, 1e-9)
end)
```

- [ ] **Step 2: Run test to verify it fails**

Run: `/c/Users/Dani/AppData/Local/Programs/Lua/bin/lua.exe tests/test_transform.lua`
Expected: FAIL (`attempt to call a nil value (field 'tilt')`).

- [ ] **Step 3: Write minimal implementation**

Add to `core/transform.lua` (before `return M`):

```lua
-- Tilt values: pivot one end (or dome if symmetrical), distributed across the span by the curve.
function M.tilt(points, tmin, tmax, delta, opts)
  opts = opts or {}
  local span = (tmax - tmin)
  local out = {}
  for i = 1, #points do
    local p = points[i]
    local relT = span > 0 and (p.t - tmin) / span or 0
    if relT < 0 then relT = 0 elseif relT > 1 then relT = 1 end
    local g
    if opts.symmetrical then
      g = M.curve(1 - math.abs(2 * relT - 1), opts.knob, opts.shape)
    elseif opts.side == "left" then
      g = M.curve(1 - relT, opts.knob, opts.shape)
    else
      g = M.curve(relT, opts.knob, opts.shape)
    end
    out[i] = copy(p, nil, p.v + delta * g)
  end
  return out
end
```

- [ ] **Step 4: Run test to verify it passes**

Run: `/c/Users/Dani/AppData/Local/Programs/Lua/bin/lua.exe tests/test_transform.lua`
Expected: PASS (10 passed, 0 failed).

- [ ] **Step 5: Commit**

```bash
git add core/transform.lua tests/test_transform.lua
git commit -m "Add transform tilt (value) (pure)

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"
```

---

### Task 4: `core/arrangecoords.lua` — time/value ↔ pixel mapping

**Files:**
- Create: `core/arrangecoords.lua`
- Test: `tests/test_arrangecoords.lua`

**Interfaces:**
- Produces:
  - `arrangecoords.timeToX(t, t0, t1, x0, x1) -> x`
  - `arrangecoords.xToTime(x, t0, t1, x0, x1) -> t`
  - `arrangecoords.valueToY(v, vlo, vhi, yTop, yBot) -> y`  (screen Y: `yTop < yBot`; higher value ⇒ nearer `yTop`)
  - `arrangecoords.yToValue(y, vlo, vhi, yTop, yBot) -> v`
  - All linear; degenerate ranges (`t1==t0`, `vhi==vlo`) return the low endpoint coordinate without dividing by zero.

- [ ] **Step 1: Write the failing test**

Create `tests/test_arrangecoords.lua`:

```lua
package.path = package.path .. ";./?.lua;./tests/?.lua"
local h = require("harness")
local ac = require("core.arrangecoords")

h.test("timeToX maps endpoints and midpoint", function()
  h.almost(ac.timeToX(10, 10, 20, 100, 300), 100, 1e-9)
  h.almost(ac.timeToX(20, 10, 20, 100, 300), 300, 1e-9)
  h.almost(ac.timeToX(15, 10, 20, 100, 300), 200, 1e-9)
end)

h.test("xToTime is the inverse of timeToX", function()
  for _, t in ipairs({10, 12.5, 17, 20}) do
    h.almost(ac.xToTime(ac.timeToX(t,10,20,100,300),10,20,100,300), t, 1e-9)
  end
end)

h.test("valueToY: higher value is nearer the top (smaller y)", function()
  -- value range 0..1 over screen y [50 (top) .. 250 (bottom)]
  h.almost(ac.valueToY(1, 0, 1, 50, 250), 50,  1e-9)  -- max -> top
  h.almost(ac.valueToY(0, 0, 1, 50, 250), 250, 1e-9)  -- min -> bottom
  h.almost(ac.valueToY(0.5, 0, 1, 50, 250), 150, 1e-9)
end)

h.test("yToValue is the inverse of valueToY", function()
  for _, v in ipairs({0, 0.3, 0.75, 1}) do
    h.almost(ac.yToValue(ac.valueToY(v,0,1,50,250),0,1,50,250), v, 1e-9)
  end
end)

h.test("degenerate ranges do not divide by zero", function()
  h.eq(ac.timeToX(5, 5, 5, 100, 300), 100)
  h.eq(ac.valueToY(0.5, 1, 1, 50, 250), 250)  -- vhi==vlo -> bottom (low endpoint)
end)

h.run()
```

- [ ] **Step 2: Run test to verify it fails**

Run: `/c/Users/Dani/AppData/Local/Programs/Lua/bin/lua.exe tests/test_arrangecoords.lua`
Expected: FAIL (`module 'core.arrangecoords' not found`).

- [ ] **Step 3: Write minimal implementation**

Create `core/arrangecoords.lua`:

```lua
-- core/arrangecoords.lua — PURE linear maps between project time / display value and screen pixels.
-- Zero reaper.*. The overlay fetches the inputs (view time range + pixel extents, lane Y rect + value
-- range) from REAPER and feeds them here. Fader scaling is converted by the overlay BEFORE calling
-- these (they operate in the display/linear value domain).
local M = {}

function M.timeToX(t, t0, t1, x0, x1)
  if t1 == t0 then return x0 end
  return x0 + (t - t0) * (x1 - x0) / (t1 - t0)
end

function M.xToTime(x, t0, t1, x0, x1)
  if x1 == x0 then return t0 end
  return t0 + (x - x0) * (t1 - t0) / (x1 - x0)
end

-- Screen Y grows downward; yTop is the lane's top pixel (smaller), yBot the bottom (larger). Higher
-- value maps nearer yTop.
function M.valueToY(v, vlo, vhi, yTop, yBot)
  if vhi == vlo then return yBot end
  return yBot - (v - vlo) * (yBot - yTop) / (vhi - vlo)
end

function M.yToValue(y, vlo, vhi, yTop, yBot)
  if yBot == yTop then return vlo end
  return vlo + (yBot - y) * (vhi - vlo) / (yBot - yTop)
end

return M
```

- [ ] **Step 4: Run test to verify it passes**

Run: `/c/Users/Dani/AppData/Local/Programs/Lua/bin/lua.exe tests/test_arrangecoords.lua`
Expected: PASS (5 passed, 0 failed).

- [ ] **Step 5: Run the WHOLE suite to confirm no regressions**

Run: `for t in tests/test_*.lua; do /c/Users/Dani/AppData/Local/Programs/Lua/bin/lua.exe "$t" | tail -1; done`
Expected: every line `N passed, 0 failed`.

- [ ] **Step 6: Commit**

```bash
git add core/arrangecoords.lua tests/test_arrangecoords.lua
git commit -m "Add arrangecoords time/value<->pixel mapping (pure)

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"
```

---

### Task 5: `dump_arrange.lua` — verify the live coordinate math in REAPER

A diagnostic to confirm the (non-pure) REAPER coordinate fetchers BEFORE building the overlay on top
of them. No automated test is possible; this is the in-REAPER verification artifact.

**Files:**
- Create: `dump_arrange.lua`

**Interfaces:**
- Produces (conventions the overlay relies on): arrange view via `GetSet_ArrangeView2(0,false,0,W,t0,t1)`;
  arrange client width `W` via `JS_Window_GetClientRect(JS_Window_FindChildByID(mainHWND, 0x3E8))`
  ("trackview" = child id 1000 / 0x3E8); envelope lane screen rect via
  `track I_TCPSCREENY + GetEnvelopeInfo_Value(env,"I_TCPY_USED")` with height `I_TCPH_USED`;
  scaling via `GetEnvelopeScalingMode(env)` + `ScaleFromEnvelopeMode`.

- [ ] **Step 1: Write the diagnostic**

Create `dump_arrange.lua`:

```lua
-- dump_arrange.lua — verify the arrange/envelope coordinate inputs the Transform overlay needs.
-- Select a track envelope (and optionally some points / a time selection), run this, paste the output.
local function need(fn) return reaper[fn] ~= nil end
if not need("JS_Window_FindChildByID") then reaper.ShowConsoleMsg("js_ReaScriptAPI missing\n") return end

local env = reaper.GetSelectedEnvelope(0)
if not env then reaper.ShowConsoleMsg("No selected envelope.\n") return end
local _, ename = reaper.GetEnvelopeName(env, "")

-- arrange view: time range across the trackview client width
local main = reaper.GetMainHwnd()
local trackview = reaper.JS_Window_FindChildByID(main, 0x3E8)  -- 1000 = arrange "trackview"
local okR, l, t, r, b = reaper.JS_Window_GetClientRect(trackview)
local W = (r or 0) - (l or 0)
local t0, t1 = reaper.GetSet_ArrangeView2(0, false, 0, W, 0, 0)  -- returns (start_time, end_time)
reaper.ShowConsoleMsg(("=== Envelope: %s ===\n"):format(ename))
reaper.ShowConsoleMsg(("trackview client: l=%d t=%d r=%d b=%d  W=%d\n"):format(l or -1,t or -1,r or -1,b or -1,W))
reaper.ShowConsoleMsg(("arrange view time: t0=%.4f t1=%.4f  (px/sec=%.3f)\n"):format(t0, t1, (t1>t0) and W/(t1-t0) or 0))

-- envelope lane screen rect
local track = reaper.GetEnvelopeInfo_Value(env, "P_TRACK")
local tcpScreenY = reaper.GetMediaTrackInfo_Value(track, "I_TCPSCREENY")
local laneY = reaper.GetEnvelopeInfo_Value(env, "I_TCPY_USED")
local laneH = reaper.GetEnvelopeInfo_Value(env, "I_TCPH_USED")
reaper.ShowConsoleMsg(("lane: track I_TCPSCREENY=%.1f  env I_TCPY_USED=%.1f  I_TCPH_USED=%.1f  => yTop=%.1f yBot=%.1f\n")
  :format(tcpScreenY, laneY, laneH, tcpScreenY+laneY, tcpScreenY+laneY+laneH))

-- scaling + value range sanity
local mode = reaper.GetEnvelopeScalingMode(env)
reaper.ShowConsoleMsg(("scaling mode=%d  ScaleFrom(0.5)=%.4f  ScaleFrom(1.0)=%.4f\n")
  :format(mode, reaper.ScaleFromEnvelopeMode(mode, 0.5), reaper.ScaleFromEnvelopeMode(mode, 1.0)))

-- first 4 points: project time -> expected screen x
for i = 0, math.min(reaper.CountEnvelopePoints(env), 4) - 1 do
  local ok, ptt, ptv = reaper.GetEnvelopePoint(env, i)
  local x = (t1>t0) and ((l or 0) + (ptt - t0) * W / (t1 - t0)) or -1
  reaper.ShowConsoleMsg(("  pt#%d t=%.4f v=%.4f  -> screenX=%.1f\n"):format(i, ptt, ptv, x))
end
```

- [ ] **Step 2: Verify in REAPER**

Run in REAPER: select a Volume (fader-scaled) and a Pan (linear) envelope in turn; run the action.
Expected: `t0<t1`, `W>0`, `yBot>yTop`, scaling mode 1 for Volume / 0 for Pan, and `screenX` for the first
points falls within `[l, r]` and visually lines up with the points. If a value looks wrong, this is where
to catch it before the overlay depends on it.

- [ ] **Step 3: Commit**

```bash
git add dump_arrange.lua
git commit -m "Add dump_arrange.lua coordinate diagnostic

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"
```

---

### Task 6: `ui/overlay.lua` + `contour_transform.lua` — armed overlay that draws the box (no drag yet)

Build the engine spine: detect target+region, capture the original points, open the undo block, and run a
defer loop that positions a transparent ReaImGui window over the arrange and draws the bounding box +
zone handles at the right place. No transform yet — this isolates the hardest part (window + coords).

**Files:**
- Create: `ui/overlay.lua`
- Create: `contour_transform.lua`

**Interfaces:**
- Consumes: `core.context` (`detect()` → `{target, details, hasTimeSel, t0, t1}`), `core.target` (`fromContext`, `:read`, `:valueRange`, `:kind`), `core.arrangecoords`.
- Produces:
  - `overlay.start(ctx, detected) -> ok, err` — resolves target + region (selected points else time selection), reads the in-scope points (DISPLAY domain), computes the box, opens the undo block. Returns false+message if not a track envelope / no points.
  - `overlay.frame(ctx) -> boolean` — one defer cycle; returns `true` to keep running, `false` when the gesture ended (Esc / click-away / target lost). Positions the window, draws box+handles.
  - `overlay.finish()` — close the undo block + composited window; safe to call twice (atexit guard).

- [ ] **Step 1: Write `ui/overlay.lua`**

Create `ui/overlay.lua`:

```lua
-- ui/overlay.lua — Transform mouse-overlay engine (Reaper-bound). A transparent, click-through ReaImGui
-- window is floated over the arrange (positioned via js_ReaScriptAPI); zones are drawn over the in-scope
-- envelope points. Slice 1: track envelopes; draw only (drag wired in Task 7).
local M = {}
local target = require("core.target")
local ac     = require("core.arrangecoords")

local ACCENT   = 0x2E8B9BFF
local ACCENT_H = 0x53C9D6FF
local BOXCOL   = 0x2E8B9BCC
local GHOST    = 0x46505BAA

local g = nil  -- gesture state table while armed

-- arrange trackview client rect (screen coords) + width.
local function trackviewRect()
  local main = reaper.GetMainHwnd()
  local tv = reaper.JS_Window_FindChildByID(main, 0x3E8)  -- 1000 = arrange trackview
  if not tv then return nil end
  local ok, l, t, r, b = reaper.JS_Window_GetClientRect(tv)
  if not ok then return nil end
  return { l = l, t = t, r = r, b = b, w = r - l, h = b - t }
end

-- envelope lane screen rect (yTop/yBot) for a TRACK envelope.
local function laneRect(env)
  local track = reaper.GetEnvelopeInfo_Value(env, "P_TRACK")
  if not track then return nil end
  local sy = reaper.GetMediaTrackInfo_Value(track, "I_TCPSCREENY")
  local ly = reaper.GetEnvelopeInfo_Value(env, "I_TCPY_USED")
  local lh = reaper.GetEnvelopeInfo_Value(env, "I_TCPH_USED")
  if not lh or lh <= 0 then return nil end
  return { yTop = sy + ly, yBot = sy + ly + lh }
end

-- Read in-scope points in the DISPLAY value domain, tagged with their envelope index. Selected points
-- win; else the time selection. Returns points[], t0, t1 (region), or nil.
local function readScope(detected)
  local d = detected.details
  local env = d and d.env
  if not env then return nil, "No envelope" end
  local mode = reaper.GetEnvelopeScalingMode(env)
  local cnt = reaper.CountEnvelopePoints(env)
  local sel, all = {}, {}
  for i = 0, cnt - 1 do
    local ok, t, v, shape, tension, selected = reaper.GetEnvelopePoint(env, i)
    if ok then
      local pt = { idx = i, t = t, v = reaper.ScaleFromEnvelopeMode(mode, v),
                   shape = shape, tension = tension, sel = selected and true or false }
      all[#all+1] = pt
      if selected then sel[#sel+1] = pt end
    end
  end
  local scope = (#sel > 0) and sel or nil
  local t0, t1
  if scope then
    t0, t1 = scope[1].t, scope[1].t
    for _, p in ipairs(scope) do if p.t < t0 then t0 = p.t end; if p.t > t1 then t1 = p.t end end
    -- include unselected points within [t0,t1] so a replace-in-range write preserves them
    local region = {}
    for _, p in ipairs(all) do if p.t >= t0 and p.t <= t1 then region[#region+1] = p end end
    return region, t0, t1, mode
  elseif detected.hasTimeSel then
    t0, t1 = detected.t0, detected.t1
    local region = {}
    for _, p in ipairs(all) do if p.t >= t0 and p.t <= t1 then region[#region+1] = p end end
    return region, t0, t1, mode
  end
  return nil, "Select points or make a time selection"
end

function M.start(ctx, detected)
  if not detected or detected.target ~= "envelope" then
    return false, "Slice 1 supports track envelopes only — select one"
  end
  local region, t0, t1, mode, err = readScope(detected)
  if not region then return false, t0 or err or "Nothing to transform" end
  if #region == 0 then return false, "No points in the region" end
  local tgt = target.fromContext(detected)
  if not tgt then return false, "No target" end
  local vlo, vhi = tgt:valueRange()
  -- value range in display domain
  local dlo, dhi = reaper.ScaleFromEnvelopeMode(mode, vlo), reaper.ScaleFromEnvelopeMode(mode, vhi)
  if dhi < dlo then dlo, dhi = dhi, dlo end
  g = { detected = detected, tgt = tgt, env = detected.details.env, mode = mode,
        orig = region, t0 = t0, t1 = t1, vlo = dlo, vhi = dhi,
        snap = tgt:snapshot(), zone = nil }
  reaper.Undo_BeginBlock2(0)
  g.undoOpen = true
  return true
end

-- screen->canvas helpers using the live view each frame
local function viewNow()
  local tvr = trackviewRect(); if not tvr then return nil end
  local t0, t1 = reaper.GetSet_ArrangeView2(0, false, 0, tvr.w, 0, 0)  -- returns (start_time, end_time)
  return tvr, t0, t1
end

function M.frame(ctx)
  if not g then return false end
  -- end on Escape
  if reaper.ImGui_IsKeyPressed and reaper.ImGui_IsKeyPressed(ctx, reaper.ImGui_Key_Escape()) then
    return false
  end
  local tvr, vt0, vt1 = viewNow()
  local lr = laneRect(g.env)
  if not tvr or not lr or vt1 <= vt0 then return true end  -- transient; keep waiting

  -- transparent click-through window over the trackview
  reaper.ImGui_SetNextWindowPos(ctx, tvr.l, tvr.t)
  reaper.ImGui_SetNextWindowSize(ctx, tvr.w, tvr.h)
  local flags = reaper.ImGui_WindowFlags_NoDecoration() | reaper.ImGui_WindowFlags_NoMove()
    | reaper.ImGui_WindowFlags_NoBackground() | reaper.ImGui_WindowFlags_NoInputs()
    | reaper.ImGui_WindowFlags_NoNav() | reaper.ImGui_WindowFlags_NoSavedSettings()
  local vis = reaper.ImGui_Begin(ctx, "##contour_overlay", true, flags)
  if vis then
    local dl = reaper.ImGui_GetWindowDrawList(ctx)
    local function X(t) return ac.timeToX(t, vt0, vt1, tvr.l, tvr.r) end
    local function Y(v) return ac.valueToY(v, g.vlo, g.vhi, lr.yTop, lr.yBot) end
    -- box from current orig bounds
    local b = M._bounds(g.orig)
    local x0,x1,yb,yt = X(b.tmin), X(b.tmax), Y(b.vmin), Y(b.vmax)
    reaper.ImGui_DrawList_AddRect(dl, x0, yt, x1, yb, BOXCOL, 0, 0, 1.5)
    -- handles: L/R mid (stretch), top/bottom-left & -right corners (tilt)
    M._drawHandle(dl, x0, (yt+yb)/2)       -- stretch L
    M._drawHandle(dl, x1, (yt+yb)/2)       -- stretch R
    M._drawHandle(dl, x0, yt)              -- tilt left (top-left)
    M._drawHandle(dl, x1, yt)              -- tilt right (top-right)
  end
  reaper.ImGui_End(ctx)
  return true
end

function M._bounds(pts)
  local b = { tmin=1e18, tmax=-1e18, vmin=1e18, vmax=-1e18 }
  for _, p in ipairs(pts) do
    if p.t<b.tmin then b.tmin=p.t end; if p.t>b.tmax then b.tmax=p.t end
    if p.v<b.vmin then b.vmin=p.v end; if p.v>b.vmax then b.vmax=p.v end
  end
  if b.tmax<=b.tmin then b.tmax=b.tmin+1e-6 end
  if b.vmax<=b.vmin then b.vmin=b.vmin-0.01; b.vmax=b.vmax+0.01 end
  return b
end

function M._drawHandle(dl, x, y)
  reaper.ImGui_DrawList_AddRectFilled(dl, x-6, y-6, x+6, y+6, ACCENT)
  reaper.ImGui_DrawList_AddRect(dl, x-6, y-6, x+6, y+6, 0x0B2226FF, 0, 0, 2)
end

function M.finish()
  if g and g.undoOpen then
    reaper.Undo_EndBlock2(0, "Contour: Transform envelope", -1)
    g.undoOpen = false
  end
  g = nil
end

return M
```

- [ ] **Step 2: Write `contour_transform.lua`**

Create `contour_transform.lua`:

```lua
-- contour_transform.lua — entry for the Transform overlay. Runnable as its own action (hotkey-bindable)
-- and launchable from Contour. Slice 1: track envelopes, draw-only (drag in Task 7).
local sep = package.config:sub(1,1)
local src = debug.getinfo(1,"S").source:match("^@?(.*[/\\])") or ("."..sep)
package.path = src .. "?.lua;" .. package.path

-- dependency guards
local missing = {}
if not reaper.ImGui_CreateContext then missing[#missing+1] = "ReaImGui" end
if not reaper.JS_Window_FindChildByID then missing[#missing+1] = "js_ReaScriptAPI" end
if not reaper.BR_GetMouseCursorContext then missing[#missing+1] = "SWS" end
if #missing > 0 then
  reaper.ShowMessageBox("Contour Transform needs: " .. table.concat(missing, ", ") ..
    ".\nInstall via ReaPack, then retry.", "Contour Transform — missing dependency", 0)
  return
end

local context = require("core.context")
local overlay = require("ui.overlay")

local ctx = reaper.ImGui_CreateContext("Contour Transform")
reaper.atexit(function() pcall(overlay.finish) end)

local detected = context.detect()
local ok, err = overlay.start(ctx, detected)
if not ok then
  reaper.ShowMessageBox(err or "Nothing to transform.", "Contour Transform", 0)
  return
end

local function loop()
  if overlay.frame(ctx) then
    reaper.defer(loop)
  else
    overlay.finish()
  end
end
reaper.defer(loop)
```

- [ ] **Step 3: Parse-check both files headlessly**

Run: `/c/Users/Dani/AppData/Local/Programs/Lua/bin/lua.exe -e "assert(loadfile('ui/overlay.lua')); assert(loadfile('contour_transform.lua')); print('parse OK')"`
Expected: `parse OK`.

- [ ] **Step 4: Verify in REAPER**

Load `contour_transform.lua` as an action and run it with a track envelope selected and a few points
selected (or a time selection). Expected: a teal dashed box with four handle squares appears **over the
envelope lane**, aligned to the selected points' bounding box; it tracks arrange scroll/zoom; **Esc**
closes it. The arrange stays fully interactive (clicks pass through). If the box is misaligned, re-run
`dump_arrange.lua` and compare.

- [ ] **Step 5: Commit**

```bash
git add ui/overlay.lua contour_transform.lua
git commit -m "Add Transform overlay spine: armed box over the envelope lane (draw-only)

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"
```

---

### Task 7: Drag the handles → Stretch / Tilt live, single undo

Add mouse capture (js, since the window is click-through), zone hit-testing, and the drag→transform→write
loop reusing `target:writeBulk(…, rawShape=true)` under `PreventUIRefresh`.

**Files:**
- Modify: `ui/overlay.lua`

**Interfaces:**
- Consumes: `core.transform` (`stretch`, `tilt`), `JS_Mouse_GetState`, `GetMousePosition`.
- Produces: live edits to the envelope; `overlay.frame` now returns `false` on a click OUTSIDE the box
  (commit + end) as well as on Esc.

- [ ] **Step 1: Add mouse + transform to `ui/overlay.lua`**

At the top of `ui/overlay.lua`, after `local ac = require("core.arrangecoords")`, add:

```lua
local tr = require("core.transform")
```

Add this helper (mouse state in screen coords + left button) above `M.frame`:

```lua
-- left mouse + screen position via js (the overlay window is click-through, so ImGui input is off)
local function mouseNow()
  local state = reaper.JS_Mouse_GetState(1)          -- bit 0 = left button
  local x, y = reaper.GetMousePosition()
  return (state & 1) == 1, x, y
end

local HR = 9  -- handle hit radius (screen px)
local function hit(mx, my, hx, hy) return math.abs(mx-hx) <= HR and math.abs(my-hy) <= HR end

-- write the current orig transformed by the active drag, under PreventUIRefresh
local function writeTransformed(newPts)
  -- convert display values back to storage domain handled inside writeBulk? No: target writes display
  -- values for non-scaled; for fader-scaled we must convert here.
  local out = {}
  for i = 1, #newPts do
    local p = newPts[i]
    out[i] = { time = p.t, value = reaper.ScaleToEnvelopeMode(g.mode, p.v),
               shape = p.shape, tension = p.tension, sel = p.sel }
  end
  reaper.PreventUIRefresh(1)
  g.tgt:writeBulk(g.snap, out, g.t0, g.t1, { noUndo = true, rawShape = true })
  reaper.PreventUIRefresh(-1)
end
```

> Note: `writeBulk → ENV:write → envReplace` already inserts with `noSortIn=true` + one `Envelope_SortPoints`,
> i.e. the fast pattern; `PreventUIRefresh` coalesces the per-frame redraw. `value` is converted back to
> the storage domain here because `envReplace` writes raw values directly.

Replace the body of `M.frame` between the `if vis then` block's handle drawing and `reaper.ImGui_End` —
i.e. extend the function to read the mouse and act. Update `M.frame` to:

```lua
function M.frame(ctx)
  if not g then return false end
  if reaper.ImGui_IsKeyPressed and reaper.ImGui_IsKeyPressed(ctx, reaper.ImGui_Key_Escape()) then return false end
  local tvr, vt0, vt1 = viewNow()
  local lr = laneRect(g.env)
  if not tvr or not lr or vt1 <= vt0 then return true end

  local function X(t) return ac.timeToX(t, vt0, vt1, tvr.l, tvr.r) end
  local function Y(v) return ac.valueToY(v, g.vlo, g.vhi, lr.yTop, lr.yBot) end
  local b = M._bounds(g.orig)
  local x0,x1 = X(b.tmin), X(b.tmax)
  local yt,yb = Y(b.vmax), Y(b.vmin)
  local cy = (yt+yb)/2

  local handles = {
    { id="stretchL", x=x0, y=cy }, { id="stretchR", x=x1, y=cy },
    { id="tiltL", x=x0, y=yt },    { id="tiltR", x=x1, y=yt },
  }

  local down, mx, my = mouseNow()
  -- begin drag
  if down and not g.zone then
    for _, hnd in ipairs(handles) do
      if hit(mx, my, hnd.x, hnd.y) then
        g.zone = hnd.id; g.startX = mx; g.startY = my
        g.box = b  -- snapshot box at grab
        break
      end
    end
    -- click outside any handle AND outside the box => commit + end
    if not g.zone and (mx < x0-HR or mx > x1+HR or my < yt-HR or my > yb+HR) then
      return false
    end
  end

  -- during drag: compute params and write
  if g.zone and down then
    local p = require("core.context") and nil  -- (no-op; keep requires at top)
    if g.zone == "stretchL" or g.zone == "stretchR" then
      local anchorT = (g.zone == "stretchL") and g.box.tmax or g.box.tmin
      local edgeT   = (g.zone == "stretchL") and g.box.tmin or g.box.tmax
      local mouseT  = ac.xToTime(mx, vt0, vt1, tvr.l, tvr.r)
      local denom   = (edgeT - anchorT)
      local factor  = (denom ~= 0) and ((mouseT - anchorT) / denom) or 1
      writeTransformed(tr.stretch(g.orig, anchorT, factor))
      g.status = ("Stretch %d%%"):format(math.floor(factor*100+0.5))
    else -- tilt
      local side = (g.zone == "tiltL") and "left" or "right"
      local mouseV = ac.yToValue(my, g.vlo, g.vhi, lr.yTop, lr.yBot)
      local endV   = (side == "left") and g.box.vmax or g.box.vmax  -- handle drawn at top
      local delta  = mouseV - endV
      writeTransformed(tr.tilt(g.orig, g.box.tmin, g.box.tmax, delta,
        { knob = g.knob or 0, shape = g.shape or "power", side = side, symmetrical = g.symmetrical or false }))
      g.status = ("Tilt %s%.0f"):format(delta>=0 and "+" or "", delta*1000)
    end
  end

  -- end drag (button released): keep the result, allow another grab; do NOT close
  if g.zone and not down then g.zone = nil end

  -- draw
  reaper.ImGui_SetNextWindowPos(ctx, tvr.l, tvr.t)
  reaper.ImGui_SetNextWindowSize(ctx, tvr.w, tvr.h)
  local flags = reaper.ImGui_WindowFlags_NoDecoration() | reaper.ImGui_WindowFlags_NoMove()
    | reaper.ImGui_WindowFlags_NoBackground() | reaper.ImGui_WindowFlags_NoInputs()
    | reaper.ImGui_WindowFlags_NoNav() | reaper.ImGui_WindowFlags_NoSavedSettings()
  if reaper.ImGui_Begin(ctx, "##contour_overlay", true, flags) then
    local dl = reaper.ImGui_GetWindowDrawList(ctx)
    reaper.ImGui_DrawList_AddRect(dl, x0, yt, x1, yb, BOXCOL, 0, 0, 1.5)
    for _, hnd in ipairs(handles) do
      local col = (g.zone == hnd.id) and ACCENT_H or ACCENT
      reaper.ImGui_DrawList_AddRectFilled(dl, hnd.x-6, hnd.y-6, hnd.x+6, hnd.y+6, col)
      reaper.ImGui_DrawList_AddRect(dl, hnd.x-6, hnd.y-6, hnd.x+6, hnd.y+6, 0x0B2226FF, 0, 0, 2)
    end
  end
  reaper.ImGui_End(ctx)
  return true
end
```

(Delete the now-superseded earlier `M.frame` body and the stray `local p = require(...)` no-op line —
keep all `require`s at the top of the file.)

- [ ] **Step 2: Parse-check**

Run: `/c/Users/Dani/AppData/Local/Programs/Lua/bin/lua.exe -e "assert(loadfile('ui/overlay.lua')); print('parse OK')"`
Expected: `parse OK`.

- [ ] **Step 3: Verify in REAPER**

Run the action on a track envelope with points selected. Drag the **L/R** handles → points stretch in
time about the far edge (drag past the anchor → reverse). Drag the **top corner** handles → the left/right
end tilts in value. The change is live and smooth (no freeze) on a dense Volume envelope. Release keeps
the result; grab again to chain. **Click outside the box** (or Esc) → the overlay closes and the whole
session is a **single** undo point (Ctrl+Z restores the original). Verify fader-scaled Volume tilts the
right amount (scaling round-trip correct) and Pan works too.

- [ ] **Step 4: Commit**

```bash
git add ui/overlay.lua
git commit -m "Transform overlay: drag handles to Stretch/Tilt envelopes live (single undo)

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"
```

---

### Task 8: Launch Transform from the Contour panel

Add a Transform op body in Contour with a **Launch** button (runs `contour_transform.lua` via its action
command id) plus the Curve / Power-Sine / Symmetrical controls that the overlay reads, and a status line.

**Files:**
- Modify: `ui/shell.lua` (the `state.op == "transform"` branch)
- Create: `ui/transform_panel.lua`
- Modify: `ui/overlay.lua` (read shared params from a module table)

**Interfaces:**
- Consumes: a shared params table so the panel and the overlay agree on `knob`, `shape`, `symmetrical`.
- Produces: `transform_panel.draw(ctx, state)` and `transform_panel.params` (`{ knob, shape, symmetrical }`).

- [ ] **Step 1: Create `ui/transform_panel.lua`**

```lua
-- ui/transform_panel.lua — Contour's Transform op body: launch the overlay + the shared shaping params.
local M = {}
M.params = { knob = 0, shape = "power", symmetrical = false }

local COLOR_HINT = 0xC0A040FF
local COLOR_OK   = 0x60C080FF

-- Resolve this script's own action command id so the Launch button can fire the overlay action.
-- The transform script must be imported as an action; NamedCommandLookup finds it by the _RS<hash>
-- name printed in the Action list. Stored once the user pastes it (or we fall back to a hint).
function M.draw(ctx, state)
  local p = M.params
  reaper.ImGui_Text(ctx, "Transform (mouse overlay)")
  reaper.ImGui_TextColored(ctx, COLOR_HINT, "Select points or make a time selection, then Launch.")
  reaper.ImGui_Separator(ctx)

  if reaper.ImGui_Button(ctx, "Launch Transform##tr_launch") then
    local cmd = reaper.NamedCommandLookup("_Contour_Transform")  -- set if installed with this name
    if cmd ~= 0 then reaper.Main_OnCommand(cmd, 0)
    else M.status = "Bind a hotkey to contour_transform.lua, or import it named _Contour_Transform." end
  end
  reaper.ImGui_SameLine(ctx)
  reaper.ImGui_TextColored(ctx, COLOR_HINT, "(or a hotkey on contour_transform.lua)")

  reaper.ImGui_Separator(ctx)
  do
    local changed
    changed, p.knob = reaper.ImGui_SliderInt(ctx, "Curve##tr_curve", p.knob, -100, 100, p.knob==0 and "linear" or "%d")
    local cP = reaper.ImGui_RadioButton(ctx, "Power##tr_pow", p.shape=="power"); reaper.ImGui_SameLine(ctx)
    local cS = reaper.ImGui_RadioButton(ctx, "Sine##tr_sine", p.shape=="sine")
    if cP then p.shape="power" end; if cS then p.shape="sine" end
    local cSym, sym = reaper.ImGui_Checkbox(ctx, "Symmetrical##tr_sym", p.symmetrical)
    if cSym then p.symmetrical = sym end
  end
  if M.status then reaper.ImGui_TextColored(ctx, COLOR_OK, M.status) end
end

return M
```

- [ ] **Step 2: Wire it into `ui/shell.lua`**

In `ui/shell.lua`, add near the other requires:

```lua
local transform_panel = require("ui.transform_panel")
```

Replace the transform placeholder branch:

```lua
  else
    reaper.ImGui_TextWrapped(ctx, "Transform: panel coming in a later slice.")
  end
```

with:

```lua
  else
    transform_panel.draw(ctx, state)
  end
```

- [ ] **Step 3: Make the overlay read the shared params**

In `ui/overlay.lua`, add near the top requires:

```lua
local panel = require("ui.transform_panel")
```

and in `M.start`, after building `g`, seed the params from the panel:

```lua
  g.knob = panel.params.knob; g.shape = panel.params.shape; g.symmetrical = panel.params.symmetrical
```

and at the top of `M.frame`, refresh them each cycle so panel tweaks during a session apply:

```lua
  if g then g.knob = panel.params.knob; g.shape = panel.params.shape; g.symmetrical = panel.params.symmetrical end
```

(Place this immediately after the `if not g then return false end` guard.)

- [ ] **Step 4: Parse-check + full suite**

Run:
```
/c/Users/Dani/AppData/Local/Programs/Lua/bin/lua.exe -e "assert(loadfile('ui/transform_panel.lua')); assert(loadfile('ui/shell.lua')); assert(loadfile('ui/overlay.lua')); print('parse OK')"
for t in tests/test_*.lua; do /c/Users/Dani/AppData/Local/Programs/Lua/bin/lua.exe "$t" | tail -1; done
```
Expected: `parse OK`; every test line `N passed, 0 failed`.

- [ ] **Step 5: Verify in REAPER**

In Contour, switch to **Transform**: the panel shows Launch + Curve + Power/Sine + Symmetrical. Select
envelope points, click **Launch** (after binding the action / naming it `_Contour_Transform`), drag to
Stretch/Tilt; change Curve mid-session and confirm Tilt's bend responds. One undo per session.

- [ ] **Step 6: Commit**

```bash
git add ui/transform_panel.lua ui/shell.lua ui/overlay.lua
git commit -m "Launch Transform overlay from the Contour panel + shared curve/symmetrical params

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"
```

---

## Self-Review

**Spec coverage (slice 1 scope):**
- Launch from Contour / hotkey → Task 6 (entry) + Task 8 (button). ✓
- Launch on selected points OR time selection (points win) → `readScope` in Task 6. ✓
- Track envelopes, Stretch + Tilt → Tasks 2, 3, 7. ✓
- Overlay positioned over arrange via js, click-through, draw zones → Task 6. ✓
- Coordinate mapping (time↔x, value↔y + fader scaling) → Task 4 (pure) + Task 5 (verify) + Task 6/7 (fetch). ✓
- Fast write + PreventUIRefresh + single undo → Task 7 (reuses `writeBulk` rawShape; `PreventUIRefresh` wrap; `Undo_BeginBlock2/EndBlock2` in Task 6). ✓
- Curve knob + Power/Sine + Symmetrical (Tilt uses them) → Task 1 (curve) + Task 8 (panel) + Task 7 (applied). ✓
- Dependency guards → Task 6 entry. ✓
- Headless tests for pure modules → Tasks 1–4. ✓
- Out of scope held back: Scale/Compress/Warp/Reverse/Flip (slice 2), automation items (slice 3), MIDI CC (slice 4). ✓

**Placeholder scan:** No TBD/TODO; all code shown. The one runtime caveat (the Launch button needs the
action installed/named `_Contour_Transform`, else it shows a hint) is explicit, not a placeholder.

**Type consistency:** Point fields `{t,v,shape,tension,sel,idx}` used consistently; transform functions
take/return `{t,v,…}`; `writeTransformed` maps to the target's `{time,value,shape,tension,sel}` write
shape (matching `core/target.lua`'s existing `:writeBulk` contract). `curve(x,knob,shape)`,
`stretch(points,anchorT,factor)`, `tilt(points,tmin,tmax,delta,opts)` signatures match across tasks.

**Known follow-ups (not slice 1):** the click-through overlay reads the mouse via `JS_Mouse_GetState`;
if a future REAPER/ImGui combo lets the overlay receive drags directly we can drop that. The
`_Contour_Transform` naming for the Launch button is a slice-1 convenience; a cleaner cross-script launch
(e.g. storing the command id) can come in slice 2.
