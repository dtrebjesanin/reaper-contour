# Transform — Slice 2 (Track Envelopes · Scale · Compress · Warp · Reverse · Flip) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Grow the proven Transform overlay (Stretch + Tilt from slice 1) into the full track-envelope op set — **Scale**, **Compress** (Scale's curved sibling, unified under the Curve knob), **Warp** (axis by dominant first move), and the **Reverse** / **Flip** one-shots — and move all shaping controls into the tool's own **compact HUD**, leaving Contour with only a Scope toggle + Launch.

**Architecture:** Pure geometric math lands in `core/transform.lua` (`vscale`, `warp`, `reverse`, `flip`) and is headless-tested. The Reaper-bound overlay (`ui/overlay.lua`) gains the new drag zones and a small floating ImGui HUD that *owns* the shaping params (Curve/Power-Sine/Symmetrical/Flip-mode) — the overlay is a single script instance, so these params need no cross-process sync. Contour's Transform panel (`ui/transform_panel.lua`) shrinks to a Scope radio + Launch; the chosen scope is handed to the tool once at launch via ExtState (`Contour/tr_scope`). Live writes reuse slice 1's `writeTransformed` → `target:writeBulk(rawShape=true)` path under `PreventUIRefresh`, one undo point per gesture.

**Tech Stack:** Lua 5.4 · ReaImGui (`reaper.ImGui_*`) · js_ReaScriptAPI (`reaper.JS_*`) · SWS (`reaper.BR_*`) · native ReaScript envelope/arrange API · headless tests via `lua.exe`.

## Global Constraints

- Pure core modules (`core/transform.lua`, `core/arrangecoords.lua`) contain **zero `reaper.*`** — headless-testable.
- Headless tests run with: `/c/Users/Dani/AppData/Local/Programs/Lua/bin/lua.exe tests/test_<name>.lua` (lua.exe is NOT on PATH; use the full path). Run from repo root `C:\Users\Dani\reaper-lfo-toolkit`.
- Tests use the existing harness: `local h = require("harness")`, `h.test(name, fn)`, `h.eq(a,b[,msg])`, `h.almost(a,b,tol[,msg])`, `h.truthy(v[,msg])`, `h.run()`. Each test file begins with `package.path = package.path .. ";./?.lua;./tests/?.lua"`.
- Point list shape used throughout: an array of `{ t=<number>, v=<number>, shape=<int>, tension=<number>, sel=<bool> }`. `t` is project seconds; `v` is the envelope's **raw STORAGE-domain value** (what the lane draws linearly — same domain Reduce/Generate use; NO ScaleFrom/To). Transform functions PRESERVE `shape`/`tension`/`sel` and change only `t` or `v`.
- All transforms operate on the in-scope points captured at grab and return a NEW array (never mutate input), reusing the existing private `copy(p, t, v)` helper in `core/transform.lua`.
- Curve knob is `-100..100`; steepness `w = 2^(knob/100 * 2.2)`; `knob=0 ⇒ w=1 ⇒ linear`. Shapes: `"power"` (`x^w`) and `"sine"` (`((1-cos(πx))/2)^w`). All curve-using ops call the existing `M.curve(x, knob, shape)`.
- **Scale/Compress are unified:** one value-remap function `vscale` driven by the Curve knob — `knob=0` ⇒ pure affine Scale; `knob≠0` ⇒ Compress (near-boundary points move most). There is no separate Compress handle.
- Slice 2 targets **track envelopes only** (automation items = slice 3, MIDI CC = slice 4). Use the existing `ENV` target in `core/target.lua` (`:valueRange`, `:snapshot`, `:writeBulk`).
- **All shaping controls live in the overlay HUD** (single Lua state — params are local, no ExtState bus). Contour's Transform op is **Scope toggle + Launch only**. The only cross-process handoff is the scope choice at launch via `reaper.SetExtState("Contour","tr_scope", "points"|"timesel", false)`.
- Reaper-bound files must stay loadable: every overlay/panel task ends with a syntax gate `lua.exe -e "assert(loadfile('<file>'))"` (compiles without executing `reaper.*`). Functional behavior is verified in REAPER with the user (the established loop) — each such task lists explicit **Manual verification** checks for that pass.
- Commit message trailer for every commit: `Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>`.

---

### Task 1: `core/transform.lua` — `vscale` (Scale + Compress, unified)

**Files:**
- Modify: `core/transform.lua` (add `M.vscale`)
- Test: `tests/test_transform.lua` (append cases)

**Interfaces:**
- Consumes: existing private `copy(p, t, v)` and `M.curve(x, knob, shape)` in `core/transform.lua`.
- Produces: `transform.vscale(points, anchorV, boundaryV, targetV, opts) -> points'`. Remaps each point's value so the dragged boundary edge (`boundaryV`) moves to `targetV` while the anchor edge (`anchorV`) stays fixed. `opts = { knob, shape }`. `knob=0` ⇒ affine Scale; `knob≠0` ⇒ Compress. Formula: `u = (v-anchorV)/(boundaryV-anchorV)`; `v' = v + (targetV-boundaryV) * sign(u) * curve(|u|, knob, shape)`. (For symmetrical Scale the caller passes `anchorV` = box centre, so points on the far side have `u<0` and mirror correctly.)

- [ ] **Step 1: Write the failing tests** — append to `tests/test_transform.lua` (before the final `h.run()`):

```lua
h.test("vscale: knob 0 is affine (boundary->target, anchor fixed)", function()
  local out = tr.vscale({ P(0,0), P(1,0.5), P(2,1) }, 0, 1, 2, { knob=0, shape="power" })
  h.almost(out[1].v, 0,   1e-9)  -- anchor (v=0) fixed
  h.almost(out[2].v, 1.0, 1e-9)  -- v=0.5 -> 2x -> 1.0
  h.almost(out[3].v, 2.0, 1e-9)  -- boundary (v=1) -> target 2
  h.eq(out[2].t, 1); h.eq(out[2].sel, true)  -- coords/fields preserved
end)

h.test("vscale: anchor point never moves", function()
  local out = tr.vscale({ P(0,0.3), P(1,0.9) }, 0.3, 0.9, 0.6, { knob=50, shape="sine" })
  h.almost(out[1].v, 0.3, 1e-9)  -- v==anchorV => u=0 => unchanged for any knob/shape
end)

h.test("vscale: boundary always lands on target for any knob", function()
  for _, k in ipairs({-100, 0, 60, 100}) do
    local out = tr.vscale({ P(0,0), P(1,1) }, 0, 1, 1.5, { knob=k, shape="power" })
    h.almost(out[2].v, 1.5, 1e-9, "boundary->target at knob="..k)
    h.almost(out[1].v, 0,   1e-9, "anchor fixed at knob="..k)
  end
end)

h.test("vscale: positive knob compresses interior (moves less than affine)", function()
  local affine = tr.vscale({ P(0,0.5) }, 0, 1, 2, { knob=0,   shape="power" })[1].v  -- = 1.0
  local comp   = tr.vscale({ P(0,0.5) }, 0, 1, 2, { knob=100, shape="power" })[1].v
  h.truthy(comp < affine, "compressed interior point moves less")
  h.truthy(comp > 0.5,    "but still moves toward the boundary")
end)

h.test("vscale: symmetrical (anchor=centre) mirrors the far edge", function()
  -- box [0,1], centre 0.5; drag top (1) to 1.5 => bottom (0) mirrors to -0.5
  local out = tr.vscale({ P(0,0), P(1,0.5), P(2,1) }, 0.5, 1, 1.5, { knob=0, shape="power" })
  h.almost(out[2].v, 0.5,  1e-9)  -- centre fixed
  h.almost(out[3].v, 1.5,  1e-9)  -- top -> target
  h.almost(out[1].v, -0.5, 1e-9)  -- bottom mirrors
end)
```

- [ ] **Step 2: Run to verify it fails**

Run: `/c/Users/Dani/AppData/Local/Programs/Lua/bin/lua.exe tests/test_transform.lua`
Expected: FAIL (`attempt to call a nil value (field 'vscale')`).

- [ ] **Step 3: Implement** — add to `core/transform.lua` (after `M.stretch`, before `M.tilt`):

```lua
-- Scale/Compress values. The dragged boundary edge (boundaryV) moves to targetV; the anchor edge
-- (anchorV, the opposite edge — or the box centre when symmetrical) stays fixed. knob=0 ⇒ affine Scale;
-- knob≠0 ⇒ Compress (the curve weights interior motion toward the boundary). For symmetrical the caller
-- passes anchorV = centre, so the far side (u<0) mirrors via sign(u).
function M.vscale(points, anchorV, boundaryV, targetV, opts)
  opts = opts or {}
  local span = boundaryV - anchorV
  local move = targetV - boundaryV
  local out = {}
  for i = 1, #points do
    local p = points[i]
    local u = (span ~= 0) and (p.v - anchorV) / span or 0
    local s = (u < 0) and -1 or 1
    local a = math.abs(u); if a > 1 then a = 1 end
    local g = M.curve(a, opts.knob, opts.shape)
    out[i] = copy(p, nil, p.v + move * s * g)
  end
  return out
end
```

- [ ] **Step 4: Run to verify it passes**

Run: `/c/Users/Dani/AppData/Local/Programs/Lua/bin/lua.exe tests/test_transform.lua`
Expected: PASS (all previous + 5 new).

- [ ] **Step 5: Commit**

```bash
git add core/transform.lua tests/test_transform.lua
git commit -m "Transform: add vscale (unified Scale/Compress) pure math

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"
```

---

### Task 2: `core/transform.lua` — `warp`

**Files:**
- Modify: `core/transform.lua` (add `M.warp` + private `tent`)
- Test: `tests/test_transform.lua` (append cases)

**Interfaces:**
- Consumes: `copy`, `M.curve`.
- Produces: `transform.warp(points, axis, tmin, tmax, cursorRelT, delta, opts) -> points'`. `axis` is `"time"` or `"value"`. A tent weight peaks (`=1`) at `cursorRelT∈[0,1]` and tapers to `0` at the box time-edges, curve-shaped by `opts={knob,shape}`. Each point shifts by `delta*weight` on the chosen axis (`t` for `"time"`, `v` for `"value"`); the time-edge points stay pinned. `relT` for each point is `(t-tmin)/(tmax-tmin)` clamped to `[0,1]`.

- [ ] **Step 1: Write the failing tests** — append to `tests/test_transform.lua` (before `h.run()`):

```lua
h.test("warp value: edge points pinned, cursor point lifts by ~delta", function()
  -- box t∈[0,2]; cursor over the middle (relT 0.5); lift by 0.4
  local out = tr.warp({ P(0,0.5), P(1,0.5), P(2,0.5) }, "value", 0, 2, 0.5, 0.4, { knob=0, shape="power" })
  h.almost(out[1].v, 0.5, 1e-9)  -- left edge pinned (weight 0)
  h.almost(out[3].v, 0.5, 1e-9)  -- right edge pinned
  h.almost(out[2].v, 0.9, 1e-9)  -- peak: 0.5 + 0.4*1
  h.eq(out[2].t, 1)              -- value-warp leaves time untouched
end)

h.test("warp value: knob 0 power gives a linear (triangular) ramp to the peak", function()
  local out = tr.warp({ P(0,0), P(0.5,0), P(1,0) }, "value", 0, 1, 1.0, 1.0, { knob=0, shape="power" })
  h.almost(out[1].v, 0.0, 1e-9)  -- relT 0   -> weight 0
  h.almost(out[2].v, 0.5, 1e-9)  -- relT 0.5 -> weight 0.5 (peak at relT 1)
  h.almost(out[3].v, 1.0, 1e-9)  -- relT 1   -> weight 1
end)

h.test("warp time: edges pinned in time, interior shifts", function()
  local out = tr.warp({ P(0,0), P(1,0), P(2,0) }, "time", 0, 2, 0.5, 0.5, { knob=0, shape="power" })
  h.almost(out[1].t, 0, 1e-9)    -- left edge pinned
  h.almost(out[3].t, 2, 1e-9)    -- right edge pinned
  h.almost(out[2].t, 1.5, 1e-9)  -- middle (peak) shifts by delta
  h.eq(out[2].v, 0)              -- time-warp leaves value untouched
end)

h.test("warp: delta 0 is identity", function()
  local out = tr.warp({ P(0,0.2), P(1,0.8) }, "value", 0, 1, 0.5, 0, { knob=40, shape="sine" })
  h.almost(out[1].v, 0.2, 1e-9); h.almost(out[2].v, 0.8, 1e-9)
end)
```

- [ ] **Step 2: Run to verify it fails**

Run: `/c/Users/Dani/AppData/Local/Programs/Lua/bin/lua.exe tests/test_transform.lua`
Expected: FAIL (`attempt to call a nil value (field 'warp')`).

- [ ] **Step 3: Implement** — add to `core/transform.lua` (after `M.tilt`):

```lua
-- Tent weight: 1 at relT==c, 0 at relT 0 and 1, curve-shaped on each side. A cursor at an edge
-- (c<=0 or c>=1) is handled explicitly so that edge becomes the peak (not a pinned, zero-weight point).
local function tent(relT, c, knob, shape)
  local x
  if c <= 0 then x = 1 - relT          -- cursor at left edge => peak there
  elseif c >= 1 then x = relT          -- cursor at right edge => peak there
  else x = (relT <= c) and (relT / c) or ((1 - relT) / (1 - c)) end
  if x < 0 then x = 0 elseif x > 1 then x = 1 end
  return M.curve(x, knob, shape)
end

-- Warp: bend along `axis` ("time"|"value") toward the cursor. The bend peaks at cursorRelT and pins the
-- box's time-edges. Each point moves by delta*weight on the chosen axis.
function M.warp(points, axis, tmin, tmax, cursorRelT, delta, opts)
  opts = opts or {}
  local span = tmax - tmin
  local out = {}
  for i = 1, #points do
    local p = points[i]
    local relT = (span > 0) and (p.t - tmin) / span or 0
    if relT < 0 then relT = 0 elseif relT > 1 then relT = 1 end
    local w = tent(relT, cursorRelT, opts.knob, opts.shape)
    if axis == "time" then
      out[i] = copy(p, p.t + delta * w, nil)
    else
      out[i] = copy(p, nil, p.v + delta * w)
    end
  end
  return out
end
```

- [ ] **Step 4: Run to verify it passes**

Run: `/c/Users/Dani/AppData/Local/Programs/Lua/bin/lua.exe tests/test_transform.lua`
Expected: PASS (all previous + 4 new).

- [ ] **Step 5: Commit**

```bash
git add core/transform.lua tests/test_transform.lua
git commit -m "Transform: add warp (time/value, tent toward cursor) pure math

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"
```

---

### Task 3: `core/transform.lua` — `reverse` + `flip`

**Files:**
- Modify: `core/transform.lua` (add `M.reverse`, `M.flip`)
- Test: `tests/test_transform.lua` (append cases)

**Interfaces:**
- Consumes: `copy`.
- Produces:
  - `transform.reverse(points, tmin, tmax) -> points'` — mirror time about the box: `t' = tmin+tmax-t`, value untouched. (Reorders points in time; the overlay's write path sorts.)
  - `transform.flip(points, lo, hi) -> points'` — mirror value about `(lo+hi)/2`: `v' = lo+hi-v`, time untouched. The caller passes the lane range (`tgt:valueRange()`) for an **absolute** flip or the selection range (box `vmin/vmax`) for a **relative** flip.

- [ ] **Step 1: Write the failing tests** — append to `tests/test_transform.lua` (before `h.run()`):

```lua
h.test("reverse: mirrors time about the box, twice is identity", function()
  local out = tr.reverse({ P(0,0.1), P(0.5,0.2), P(2,0.3) }, 0, 2)
  h.almost(out[1].t, 2,   1e-9)  -- 0+2-0
  h.almost(out[2].t, 1.5, 1e-9)  -- 0+2-0.5
  h.almost(out[3].t, 0,   1e-9)  -- 0+2-2
  h.eq(out[1].v, 0.1)            -- value untouched
  local back = tr.reverse(out, 0, 2)
  h.almost(back[1].t, 0, 1e-9); h.almost(back[3].t, 2, 1e-9)
end)

h.test("flip: mirrors value about (lo+hi)/2, twice is identity", function()
  local out = tr.flip({ P(0,0), P(1,0.25), P(2,1) }, 0, 1)  -- centre 0.5
  h.almost(out[1].v, 1.0,  1e-9)
  h.almost(out[2].v, 0.75, 1e-9)
  h.almost(out[3].v, 0.0,  1e-9)
  h.eq(out[1].t, 0)            -- time untouched
  local back = tr.flip(out, 0, 1)
  h.almost(back[2].v, 0.25, 1e-9)
end)

h.test("flip: value at the centre stays put", function()
  local out = tr.flip({ P(0,0.5) }, 0, 1)
  h.almost(out[1].v, 0.5, 1e-9)
end)
```

- [ ] **Step 2: Run to verify it fails**

Run: `/c/Users/Dani/AppData/Local/Programs/Lua/bin/lua.exe tests/test_transform.lua`
Expected: FAIL (`attempt to call a nil value (field 'reverse')`).

- [ ] **Step 3: Implement** — add to `core/transform.lua` (after `M.warp`):

```lua
-- Mirror positions in time about the box: t' = tmin+tmax-t. One-shot.
function M.reverse(points, tmin, tmax)
  local out = {}
  for i = 1, #points do out[i] = copy(points[i], tmin + tmax - points[i].t, nil) end
  return out
end

-- Mirror values about (lo+hi)/2: v' = lo+hi-v. lo/hi = lane range (absolute) or selection range (relative).
function M.flip(points, lo, hi)
  local out = {}
  for i = 1, #points do out[i] = copy(points[i], nil, lo + hi - points[i].v) end
  return out
end
```

- [ ] **Step 4: Run to verify it passes**

Run: `/c/Users/Dani/AppData/Local/Programs/Lua/bin/lua.exe tests/test_transform.lua`
Expected: PASS (all previous + 3 new).

- [ ] **Step 5: Commit**

```bash
git add core/transform.lua tests/test_transform.lua
git commit -m "Transform: add reverse + flip pure math

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"
```

---

### Task 4: Explicit Scope (Contour Scope toggle + Launch handoff + overlay honors it)

**Files:**
- Modify: `ui/transform_panel.lua` (add Scope radio; write scope to ExtState on Launch)
- Modify: `ui/overlay.lua` (`readScope` takes an explicit scope; `M.start` reads it from ExtState and stores `g.scope`; `recapture` passes it)

**Interfaces:**
- Produces: ExtState `Contour/tr_scope` set to `"points"` or `"timesel"` by the panel at Launch; read once by `overlay.M.start`.
- `readScope(detected, scope)` returns `region, t0, t1, all` for the chosen scope, or `nil, message` if that scope is empty.

This task only adds the Scope control + handoff. The Curve/Power-Sine/Symmetrical UI currently in `transform_panel.lua` stays for now (it is replaced by the overlay HUD in Task 5).

- [ ] **Step 1: Add the Scope radio + Launch handoff** — in `ui/transform_panel.lua`, set a default scope on the module table and replace the launch block. Add near the top (after `M.params`):

```lua
M.scope = "points"  -- "points" | "timesel" — which region Launch hands to the tool
```

Replace the existing intro + Launch block:

```lua
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
```

with:

```lua
  reaper.ImGui_Text(ctx, "Transform (mouse overlay)")
  reaper.ImGui_TextColored(ctx, COLOR_HINT, "Pick a scope, then Launch — shaping controls are in the tool.")
  reaper.ImGui_Separator(ctx)

  -- Scope: which region the tool operates on (handed to the tool at launch via ExtState).
  local rPts = reaper.ImGui_RadioButton(ctx, "Selected points##tr_sp", M.scope == "points")
  reaper.ImGui_SameLine(ctx)
  local rTS  = reaper.ImGui_RadioButton(ctx, "Time selection##tr_ts", M.scope == "timesel")
  if rPts then M.scope = "points" end
  if rTS  then M.scope = "timesel" end

  if reaper.ImGui_Button(ctx, "Launch Transform##tr_launch") then
    reaper.SetExtState("Contour", "tr_scope", M.scope, false)  -- one-time scope handoff
    local cmd = reaper.NamedCommandLookup("_Contour_Transform")  -- set if installed with this name
    if cmd ~= 0 then reaper.Main_OnCommand(cmd, 0)
    else M.status = "Bind a hotkey to contour_transform.lua, or import it named _Contour_Transform." end
  end
  reaper.ImGui_SameLine(ctx)
  reaper.ImGui_TextColored(ctx, COLOR_HINT, "(or a hotkey on contour_transform.lua)")
```

- [ ] **Step 2: Make `readScope` honor the explicit scope** — in `ui/overlay.lua`, replace the whole `readScope` function:

```lua
-- Read in-scope points (raw STORAGE values), tagged with their envelope index, for the explicit scope:
-- "points" = the selected points (error if none); "timesel" = points inside the time selection (error if
-- none). Returns region[], t0, t1, all[]  — or nil, message.
local function readScope(detected, scope)
  local d = detected.details
  local env = d and d.env
  if not env then return nil, "No envelope" end
  local cnt = reaper.CountEnvelopePoints(env)
  local sel, all = {}, {}
  for i = 0, cnt - 1 do
    local ok, t, v, shape, tension, selected = reaper.GetEnvelopePoint(env, i)
    if ok then
      local pt = { idx = i, t = t, v = v,   -- raw STORAGE-domain value (lane draws it linearly)
                   shape = shape, tension = tension, sel = selected and true or false }
      all[#all+1] = pt
      if selected then sel[#sel+1] = pt end
    end
  end
  local t0, t1
  if scope == "timesel" then
    if not detected.hasTimeSel then return nil, "No time selection — make one, or use Selected points" end
    t0, t1 = detected.t0, detected.t1
  else
    if #sel == 0 then return nil, "No points selected — select some, or use Time selection" end
    t0, t1 = sel[1].t, sel[1].t
    for _, p in ipairs(sel) do if p.t < t0 then t0 = p.t end; if p.t > t1 then t1 = p.t end end
  end
  local region = {}
  for _, p in ipairs(all) do if p.t >= t0 and p.t <= t1 then region[#region+1] = p end end
  return region, t0, t1, all
end
```

- [ ] **Step 3: Read the scope in `M.start` and store it** — in `ui/overlay.lua`, inside `M.start`, replace:

```lua
  local region, t0, t1, all = readScope(detected)
  if not region then return false, t0 or "Nothing to transform" end  -- on failure readScope returns nil, msg
```

with:

```lua
  local scope = reaper.GetExtState("Contour", "tr_scope")
  if scope ~= "points" and scope ~= "timesel" then scope = "points" end
  local region, t0, t1, all = readScope(detected, scope)
  if not region then return false, t0 or "Nothing to transform" end  -- on failure readScope returns nil, msg
```

Then add `scope = scope,` to the `g = { ... }` table literal (e.g. right after `detected = detected,`).

- [ ] **Step 4: Pass the scope through `recapture`** — in `ui/overlay.lua`, in `recapture`, replace:

```lua
  local region, t0, t1, all = readScope(g.detected)
```

with:

```lua
  local region, t0, t1, all = readScope(g.detected, g.scope)
```

- [ ] **Step 5: Syntax gate**

Run: `/c/Users/Dani/AppData/Local/Programs/Lua/bin/lua.exe -e "assert(loadfile('ui/overlay.lua')); assert(loadfile('ui/transform_panel.lua')); print('ok')"`
Expected: prints `ok` (no syntax errors).

- [ ] **Step 6: Manual verification (in REAPER, with the user)** — controller runs these after the task:
  - Contour Transform op shows a **Selected points / Time selection** radio + Launch (no behavior change to Stretch/Tilt).
  - With "Selected points" and points selected → tool arms on those points. With none selected → tool shows "No points selected…" and does not arm.
  - With "Time selection" and a time selection → tool arms on points in range. With none → "No time selection…".

- [ ] **Step 7: Commit**

```bash
git add ui/overlay.lua ui/transform_panel.lua
git commit -m "Transform: explicit Scope toggle (points/time-sel) handed to the tool at launch

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"
```

---

### Task 5: Overlay HUD owns the shaping params (Curve / Power-Sine / Symmetrical) + live mouse gestures

**Files:**
- Modify: `ui/overlay.lua` (add overlay-owned `M.params`; draw a HUD window; read `M.params` instead of `panel.params`; add wheel/middle/right gestures; drop the `ui.transform_panel` require)
- Modify: `ui/transform_panel.lua` (remove the Curve/Power-Sine/Symmetrical widgets — leave Scope + Launch from Task 4)

**Interfaces:**
- Produces: `overlay.M.params = { knob=0, shape="power", symmetrical=false, flipMode="absolute" }` — the single source of truth for shaping, owned by the overlay process. The drag branches read `g.knob/g.shape/g.symmetrical` which are refreshed each frame from `M.params`.

- [ ] **Step 1: Give the overlay its own params; stop requiring the panel** — in `ui/overlay.lua`, replace the require line:

```lua
local panel  = require("ui.transform_panel")
```

with:

```lua
-- Shaping params live HERE (the overlay is its own script instance — no cross-process sync needed). The
-- HUD edits them; the drag branches read them via g.knob/g.shape/g.symmetrical each frame.
M.params = { knob = 0, shape = "power", symmetrical = false, flipMode = "absolute" }
```

- [ ] **Step 2: Source params from `M.params`** — in `ui/overlay.lua`:

In `M.start`, replace:
```lua
  g.knob = panel.params.knob; g.shape = panel.params.shape; g.symmetrical = panel.params.symmetrical
```
with:
```lua
  g.knob = M.params.knob; g.shape = M.params.shape; g.symmetrical = M.params.symmetrical
```

In `M.frame`, replace:
```lua
  if g then g.knob = panel.params.knob; g.shape = panel.params.shape; g.symmetrical = panel.params.symmetrical end
```
with:
```lua
  if g then g.knob = M.params.knob; g.shape = M.params.shape; g.symmetrical = M.params.symmetrical end
```

- [ ] **Step 3: Add live mouse gestures + draw the HUD** — in `ui/overlay.lua`, inside `M.frame`, just before the final overlay-window draw block (the line `reaper.ImGui_SetNextWindowPos(ctx, tvr.l, tvr.t)`), insert:

```lua
  -- Live param gestures over the arrange (not while interacting with a HUD widget): wheel = Curve,
  -- middle-click = Power/Sine, right-click = Symmetrical. The HUD reflects them since it reads M.params.
  if not reaper.ImGui_IsAnyItemActive(ctx) then
    local wv = reaper.ImGui_GetMouseWheel(ctx)
    if wv and wv ~= 0 then
      local k = (M.params.knob or 0) + (wv > 0 and 5 or -5)
      M.params.knob = (k < -100) and -100 or (k > 100) and 100 or k
    end
    if reaper.ImGui_IsMouseClicked(ctx, 2) then
      M.params.shape = (M.params.shape == "sine") and "power" or "sine"
    end
    if reaper.ImGui_IsMouseClicked(ctx, 1) then
      M.params.symmetrical = not M.params.symmetrical
    end
  end

  -- Compact HUD: a small, movable control panel that rides with the tool. Owns the shaping params.
  reaper.ImGui_SetNextWindowPos(ctx, tvr.l + 16, tvr.t + 16, reaper.ImGui_Cond_FirstUseEver())
  reaper.ImGui_SetNextWindowSize(ctx, 230, 0, reaper.ImGui_Cond_FirstUseEver())
  local hudFlags = reaper.ImGui_WindowFlags_NoCollapse() | reaper.ImGui_WindowFlags_NoSavedSettings()
  if reaper.ImGui_Begin(ctx, "Transform##contour_hud", true, hudFlags) then
    local p = M.params
    _, p.knob = reaper.ImGui_SliderInt(ctx, "Curve##hud_curve", p.knob, -100, 100, p.knob == 0 and "linear" or "%d")
    if reaper.ImGui_RadioButton(ctx, "Power##hud_pow", p.shape == "power") then p.shape = "power" end
    reaper.ImGui_SameLine(ctx)
    if reaper.ImGui_RadioButton(ctx, "Sine##hud_sine", p.shape == "sine") then p.shape = "sine" end
    local cSym, sym = reaper.ImGui_Checkbox(ctx, "Symmetrical##hud_sym", p.symmetrical)
    if cSym then p.symmetrical = sym end
    reaper.ImGui_Separator(ctx)
    reaper.ImGui_Text(ctx, (g and g.status) or "Grab a handle to transform")
    reaper.ImGui_TextColored(ctx, 0xC0A040FF, "wheel=Curve  mid=shape  right=Sym  Esc=close")
  end
  reaper.ImGui_End(ctx)
```

- [ ] **Step 4: Strip the moved controls from the Contour panel** — in `ui/transform_panel.lua`, remove the Curve/Power-Sine/Symmetrical block (it now lives in the HUD). Delete:

```lua
  reaper.ImGui_Separator(ctx)
  do
    _, p.knob = reaper.ImGui_SliderInt(ctx, "Curve##tr_curve", p.knob, -100, 100, p.knob==0 and "linear" or "%d")
    local cP = reaper.ImGui_RadioButton(ctx, "Power##tr_pow", p.shape=="power"); reaper.ImGui_SameLine(ctx)
    local cS = reaper.ImGui_RadioButton(ctx, "Sine##tr_sine", p.shape=="sine")
    if cP then p.shape="power" end; if cS then p.shape="sine" end
    local cSym, sym = reaper.ImGui_Checkbox(ctx, "Symmetrical##tr_sym", p.symmetrical)
    if cSym then p.symmetrical = sym end
  end
```

Also remove the now-unused `local p = M.params` line at the top of `draw` if nothing else uses it. Leave `M.params` defined (harmless) or remove it; do not break other readers — grep first: `git grep -n "transform_panel" -- '*.lua'` and `git grep -n "\.params" ui/transform_panel.lua`.

- [ ] **Step 5: Syntax gate**

Run: `/c/Users/Dani/AppData/Local/Programs/Lua/bin/lua.exe -e "assert(loadfile('ui/overlay.lua')); assert(loadfile('ui/transform_panel.lua')); print('ok')"`
Expected: prints `ok`.

- [ ] **Step 6: Manual verification (in REAPER, with the user):**
  - Launching the tool now shows a small **Transform** HUD (Curve / Power-Sine / Symmetrical + status line) alongside the box/handles; the Contour panel no longer has those controls.
  - Dragging a **Tilt** handle with Curve at 0 is linear; raising Curve bends the tilt ramp live; Power vs Sine changes the curve family; Symmetrical turns Tilt into an arch — **all driven from the HUD** (this also fixes the slice-1 latent bug where the knob never reached the tool).
  - Mouse **wheel** changes Curve, **middle-click** toggles Power/Sine, **right-click** toggles Symmetrical, and the HUD reflects each change.
  - The HUD is movable and does not steal the drag; Esc still closes the tool.

- [ ] **Step 7: Commit**

```bash
git add ui/overlay.lua ui/transform_panel.lua
git commit -m "Transform: overlay HUD owns shaping params (+ wheel/middle/right); Contour = scope+launch only

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"
```

---

### Task 6: Scale / Compress handles + symmetrical Stretch

**Files:**
- Modify: `ui/overlay.lua` (add `scaleT`/`scaleB` handles at the top/bottom edge mids; add the scale drag branch using `tr.vscale`; make Stretch pivot about the box centre when Symmetrical)

**Interfaces:**
- Consumes: `transform.vscale` (Task 1), `M.params.symmetrical`, the existing `g.box` snapshot, `ac.yToValue`.

- [ ] **Step 1: Add the Scale handles** — in `ui/overlay.lua`, in `M.frame`, after computing `cy` add a centre-x, and extend the handles table. Replace:

```lua
  local cy = (yt+yb)/2

  local handles = {
    { id="stretchL", x=x0, y=cy }, { id="stretchR", x=x1, y=cy },
    { id="tiltL", x=x0, y=yt },    { id="tiltR", x=x1, y=yt },
  }
```

with:

```lua
  local cy = (yt+yb)/2
  local cx = (x0+x1)/2

  local handles = {
    { id="stretchL", x=x0, y=cy }, { id="stretchR", x=x1, y=cy },
    { id="tiltL", x=x0, y=yt },    { id="tiltR", x=x1, y=yt },
    { id="scaleT", x=cx, y=yt },   { id="scaleB", x=cx, y=yb },
  }
```

- [ ] **Step 2: Symmetrical Stretch + the Scale branch** — in `ui/overlay.lua`, replace the Stretch branch:

```lua
    if g.zone == "stretchL" or g.zone == "stretchR" then
      local anchorT = (g.zone == "stretchL") and g.box.tmax or g.box.tmin
      local edgeT   = (g.zone == "stretchL") and g.box.tmin or g.box.tmax
      local mouseT  = ac.xToTime(mx, vt0, vt1, tvr.l, tvr.r)
      local denom   = (edgeT - anchorT)
      local factor  = (denom ~= 0) and ((mouseT - anchorT) / denom) or 1
      local newPts = tr.stretch(g.orig, anchorT, factor)
      g.pending = newPts
      writeTransformed(newPts)
      g.status = ("Stretch %d%%"):format(math.floor(factor*100+0.5))
    else -- tilt
```

with:

```lua
    if g.zone == "stretchL" or g.zone == "stretchR" then
      local edgeT   = (g.zone == "stretchL") and g.box.tmin or g.box.tmax
      local anchorT
      if g.symmetrical then anchorT = (g.box.tmin + g.box.tmax) / 2
      else anchorT = (g.zone == "stretchL") and g.box.tmax or g.box.tmin end
      local mouseT  = ac.xToTime(mx, vt0, vt1, tvr.l, tvr.r)
      local denom   = (edgeT - anchorT)
      local factor  = (denom ~= 0) and ((mouseT - anchorT) / denom) or 1
      local newPts = tr.stretch(g.orig, anchorT, factor)
      g.pending = newPts
      writeTransformed(newPts)
      g.status = ("Stretch %d%%"):format(math.floor(factor*100+0.5))
    elseif g.zone == "scaleT" or g.zone == "scaleB" then
      local boundaryV = (g.zone == "scaleT") and g.box.vmax or g.box.vmin
      local anchorV
      if g.symmetrical then anchorV = (g.box.vmin + g.box.vmax) / 2
      else anchorV = (g.zone == "scaleT") and g.box.vmin or g.box.vmax end
      local mouseV = ac.yToValue(my, g.vlo, g.vhi, lr.yTop, lr.yBot)
      local newPts = tr.vscale(g.orig, anchorV, boundaryV, mouseV, { knob = g.knob or 0, shape = g.shape or "power" })
      g.pending = newPts
      writeTransformed(newPts)
      local denom  = (boundaryV - anchorV)
      local factor = (denom ~= 0) and ((mouseV - anchorV) / denom) or 1
      g.status = ((g.knob or 0) ~= 0 and "Compress %d%%" or "Scale %d%%"):format(math.floor(factor*100+0.5))
    else -- tilt
```

(The existing tilt branch and the rest of the block are unchanged.)

- [ ] **Step 3: Syntax gate**

Run: `/c/Users/Dani/AppData/Local/Programs/Lua/bin/lua.exe -e "assert(loadfile('ui/overlay.lua')); print('ok')"`
Expected: prints `ok`.

- [ ] **Step 4: Manual verification (in REAPER, with the user):**
  - Top-edge and bottom-edge centre handles appear on the box. Dragging the **top** handle scales values about the bottom edge (and vice-versa); HUD reads "Scale NNN%".
  - With **Curve ≠ 0**, the same drag **compresses** (interior points lag the boundary; HUD reads "Compress NNN%"); Power vs Sine changes the curvature.
  - With **Symmetrical** on, Scale pivots about the box centre (both edges move oppositely); **Stretch** likewise pivots about the centre.
  - No point trail on shrink (the widest-extent clear from slice 1 still applies); outside points preserved.

- [ ] **Step 5: Commit**

```bash
git add ui/overlay.lua
git commit -m "Transform: Scale/Compress edge handles (Curve-driven) + symmetrical Stretch

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"
```

---

### Task 7: Warp center handle (axis by dominant first move)

**Files:**
- Modify: `ui/overlay.lua` (add a `warp` handle at the box centre; record grab pixel/anchor; add the warp drag branch using `tr.warp`)

**Interfaces:**
- Consumes: `transform.warp` (Task 2), `ac.xToTime`, `ac.yToValue`. Uses grab-time captures `g.grabMx/g.grabMy` (pixels) and `g.warpGrabT/g.warpGrabV` (data) + locked `g.warpAxis`.

- [ ] **Step 1: Add the Warp handle** — in `ui/overlay.lua`, extend the handles table (from Task 6) to include the centre:

```lua
    { id="scaleT", x=cx, y=yt },   { id="scaleB", x=cx, y=yb },
    { id="warp",   x=cx, y=cy },
```

- [ ] **Step 2: Capture grab anchors for warp** — in `ui/overlay.lua`, in the begin-drag loop, record the grab point on every grab so warp can measure its drag. Replace:

```lua
      if hit(mx, my, hnd.x, hnd.y) then
        g.zone = hnd.id
        g.box = b  -- snapshot box at grab
        g.wMin, g.wMax = b.tmin, b.tmax  -- seed the cleared range at the region's current extent
        reaper.Undo_BeginBlock2(0); g.dragUndo = true  -- one undo point per drag
        break
      end
```

with:

```lua
      if hit(mx, my, hnd.x, hnd.y) then
        g.zone = hnd.id
        g.box = b  -- snapshot box at grab
        g.wMin, g.wMax = b.tmin, b.tmax  -- seed the cleared range at the region's current extent
        g.grabMx, g.grabMy = mx, my  -- pixel anchor (warp axis detection)
        g.warpGrabT = ac.xToTime(mx, vt0, vt1, tvr.l, tvr.r)
        g.warpGrabV = ac.yToValue(my, g.vlo, g.vhi, lr.yTop, lr.yBot)
        g.warpAxis = nil
        reaper.Undo_BeginBlock2(0); g.dragUndo = true  -- one undo point per drag
        break
      end
```

- [ ] **Step 3: Add the Warp drag branch** — in `ui/overlay.lua`, insert a new branch before the `else -- tilt` line (i.e. after the `scaleT/scaleB` branch from Task 6):

```lua
    elseif g.zone == "warp" then
      local mouseT = ac.xToTime(mx, vt0, vt1, tvr.l, tvr.r)
      local mouseV = ac.yToValue(my, g.vlo, g.vhi, lr.yTop, lr.yBot)
      if not g.warpAxis then
        local dxpx, dypx = math.abs(mx - (g.grabMx or mx)), math.abs(my - (g.grabMy or my))
        if dxpx > 4 or dypx > 4 then g.warpAxis = (dxpx > dypx) and "time" or "value" end
      end
      if g.warpAxis then
        local span = g.box.tmax - g.box.tmin
        local cursorRelT = (span > 0) and ((g.warpGrabT - g.box.tmin) / span) or 0.5
        local delta = (g.warpAxis == "time") and (mouseT - g.warpGrabT) or (mouseV - g.warpGrabV)
        local newPts = tr.warp(g.orig, g.warpAxis, g.box.tmin, g.box.tmax, cursorRelT, delta,
          { knob = g.knob or 0, shape = g.shape or "power" })
        g.pending = newPts
        writeTransformed(newPts)
        g.status = ("Warp %s"):format(g.warpAxis)
      end
    else -- tilt
```

- [ ] **Step 4: Syntax gate**

Run: `/c/Users/Dani/AppData/Local/Programs/Lua/bin/lua.exe -e "assert(loadfile('ui/overlay.lua')); print('ok')"`
Expected: prints `ok`.

- [ ] **Step 5: Manual verification (in REAPER, with the user):**
  - A centre handle appears. Grabbing it and moving mostly **vertically** warps **values** (a hump toward the cursor, box time-edges pinned); moving mostly **horizontally** warps **time** (points bunch toward the cursor's time, edges pinned). HUD reads "Warp value"/"Warp time".
  - Curve/Power-Sine shape the hump; the chosen axis stays locked for the rest of that drag.
  - Time-warp can reorder points without leaving a trail (write path sorts + widest-extent clear).

- [ ] **Step 6: Commit**

```bash
git add ui/overlay.lua
git commit -m "Transform: Warp center handle (axis by dominant first move)

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"
```

---

### Task 8: Reverse / Flip one-shots in the HUD (+ Flip absolute/relative)

**Files:**
- Modify: `ui/overlay.lua` (HUD Reverse/Flip buttons + Flip-mode radios; consume a local pending one-shot in `M.frame`, applied as its own undo point)

**Interfaces:**
- Consumes: `transform.reverse`, `transform.flip` (Task 3), `M._bounds`, `M.params.flipMode`, `tgt:valueRange()`. One-shots are signalled by a plain local field `M._pendingOneShot` (same process — no ExtState).

- [ ] **Step 1: Add the HUD buttons + Flip mode** — in `ui/overlay.lua`, inside the HUD `Begin` block (Task 5), after the status/hint lines and before `end`, add:

```lua
    reaper.ImGui_Separator(ctx)
    if reaper.ImGui_Button(ctx, "Reverse##hud_rev") then M._pendingOneShot = "reverse" end
    reaper.ImGui_SameLine(ctx)
    if reaper.ImGui_Button(ctx, "Flip##hud_flip") then M._pendingOneShot = "flip" end
    if reaper.ImGui_RadioButton(ctx, "Absolute##hud_fa", p.flipMode == "absolute") then p.flipMode = "absolute" end
    reaper.ImGui_SameLine(ctx)
    if reaper.ImGui_RadioButton(ctx, "Relative##hud_fr", p.flipMode == "relative") then p.flipMode = "relative" end
```

- [ ] **Step 2: Apply the one-shot** — in `ui/overlay.lua`, in `M.frame`, after the live-undo/redo block and before `local tvr, vt0, vt1 = viewNow()`, insert:

```lua
  -- One-shot transforms (Reverse / Flip) from the HUD: apply once to the current region as their own
  -- undo point, then bake into g.orig so subsequent drags chain off the result. Only when not mid-drag.
  if g and not g.zone and M._pendingOneShot then
    local op = M._pendingOneShot; M._pendingOneShot = nil
    local b = M._bounds(g.orig)
    local newPts
    if op == "reverse" then
      newPts = tr.reverse(g.orig, b.tmin, b.tmax)
    elseif op == "flip" then
      local lo, hi
      if M.params.flipMode == "absolute" then lo, hi = g.vlo, g.vhi else lo, hi = b.vmin, b.vmax end
      newPts = tr.flip(g.orig, lo, hi)
    end
    if newPts then
      g.wMin, g.wMax = b.tmin, b.tmax
      reaper.Undo_BeginBlock2(0)
      writeTransformed(newPts)
      reaper.Undo_EndBlock2(0, "Contour: Transform " .. op, -1)
      g.orig = newPts
      g.status = (op == "reverse") and "Reversed" or ("Flipped (" .. (M.params.flipMode or "absolute") .. ")")
    end
  end
```

- [ ] **Step 3: Syntax gate**

Run: `/c/Users/Dani/AppData/Local/Programs/Lua/bin/lua.exe -e "assert(loadfile('ui/overlay.lua')); print('ok')"`
Expected: prints `ok`.

- [ ] **Step 4: Manual verification (in REAPER, with the user):**
  - HUD shows **Reverse** / **Flip** buttons + an **Absolute / Relative** toggle.
  - **Reverse** mirrors the selected shape left↔right in time (one undo).
  - **Flip / Absolute** mirrors values about the lane centre; **Flip / Relative** mirrors about the selection's own value range (one undo each).
  - After a one-shot, grabbing a handle continues from the new shape; Ctrl+Z (live undo) reverts the one-shot.

- [ ] **Step 5: Commit**

```bash
git add ui/overlay.lua
git commit -m "Transform: Reverse/Flip one-shots in the HUD (absolute/relative), single undo each

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"
```

---

## Self-Review (completed)

- **Spec coverage:** Scale ✅ (Task 6, `vscale` knob=0), Compress ✅ (Task 6, `vscale` knob≠0 — unified per the user's chosen zone model), Warp ✅ (Task 7, axis by dominant move), curve knob/Power-Sine/Symmetrical ✅ (Task 5 HUD, wired into Tilt/Scale/Warp), Reverse/Flip ✅ (Task 8). Contour = scope + launch only ✅ (Tasks 4–5). Controls in overlay HUD ✅ (Task 5). Single-undo-per-gesture preserved (slice-1 per-drag block; one-shots get their own block). Fast write reused ✅.
- **Type consistency:** point shape `{t,v,shape,tension,sel}` throughout; `vscale(points, anchorV, boundaryV, targetV, opts)`, `warp(points, axis, tmin, tmax, cursorRelT, delta, opts)`, `reverse(points, tmin, tmax)`, `flip(points, lo, hi)` — names/args identical between their pure tasks and their overlay call sites.
- **Placeholder scan:** none — every code step is complete.
- **Scope:** track envelopes only; AI (slice 3) and CC (slice 4) untouched. Reverse/Flip landed here per the spec's "can land in slice 2."
- **Deferred from slice 1:** M3 (surface live status in the panel) is now satisfied by the HUD status line; I2 (tilt readout units) remains a cosmetic nicety, optionally polished during Task 8 manual verification.
