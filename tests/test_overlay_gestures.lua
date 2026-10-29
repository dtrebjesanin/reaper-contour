-- tests/test_overlay_gestures.lua — Transform overlay drag behaviour: grabs that don't jump, vertical
-- steps that keep their direction, saved HUD settings, Shift + centre handle = rigid vertical move,
-- small handles, no rewrite while the mouse holds still, and Begin/End pairing.
--
-- Stub geometry: time t -> x = 80*t (0..10 s over 800 px); value v -> y = 170 - 40*v (Pan lane -1..1
-- drawn at y 130..210). The default fixture points (0,-0.5) (2,0.6) (4,-0.2) give the box x 0..320,
-- y 146..190: Stretch R at (320,168), Tilt R at (320,146), Scale T at (160,146), centre at (160,168).
package.path = package.path .. ";./Contour/?.lua;./?.lua;./tests/?.lua"

local stub = require("reaper_stub")
stub.install()

local h = require("harness")
local overlay = require("ui.overlay")

local CTX = "CTX"
local function detEnv()
  return { target = "envelope", label = "Pan", hasTimeSel = true, t0 = 0, t1 = 4, details = { env = {} } }
end

-- Scripted mouse and modifiers. The stub's enum getters return 0, so Shift gets a real bit here.
local Mx, My, Down, Mods = 0, 0, false, 0
local SHIFT = 4096
reaper.ImGui_GetMousePos = function() return Mx, My end
reaper.ImGui_IsMouseDown = function() return Down end
reaper.ImGui_Mod_Shift   = function() return SHIFT end
reaper.ImGui_GetKeyMods  = function() return Mods end

local function defaults() return { knob = 0, shape = "power", symmetrical = false, flipMode = "absolute" } end

local function launch(points, ext)
  stub.reset()
  if points then stub.envPoints = points end
  for k, v in pairs(ext or {}) do stub.rec.extState[k] = v end
  overlay.params = defaults()
  Mx, My, Down, Mods = 400, 300, false, 0
  local ok, err = overlay.start(CTX, detEnv())
  h.truthy(ok, "start: " .. tostring(err))
end

-- One frame. Returns the points it inserted, and whether it wrote at all (one range delete per write).
local function frame()
  stub.rec.ins = {}
  local before = #stub.rec.delRange
  overlay.frame(CTX)
  return stub.rec.ins, #stub.rec.delRange > before
end

local function flatPoints()
  return { { time = 0, value = 0, shape = 0, tension = 0, sel = true },
           { time = 2, value = 0, shape = 0, tension = 0, sel = true },
           { time = 4, value = 0, shape = 0, tension = 0, sel = true } }
end

---------------------------------------------------------------------------------------------------
-- Grab without a jump: Stretch, Scale and Tilt follow the mouse MOVEMENT since the grab, not the
-- absolute mouse position against the box edge (a grab is allowed up to 10 px off the handle centre).
---------------------------------------------------------------------------------------------------
h.test("stretch: a grab off the handle centre does not move the points", function()
  launch()
  Mx, My, Down = 316, 168, true; frame()   -- 4 px left of the right Stretch handle
  Down = false; frame()
  h.almost(overlay._boundsNow().tmax, 4, 1e-9, "right edge stays at 4 s")
  overlay.finish()
end)

h.test("stretch: the edge follows the mouse movement since the grab", function()
  launch()
  Mx, My, Down = 316, 168, true; frame()
  Mx = 356; frame()                        -- +40 px = +0.5 s
  Down = false; frame()
  h.almost(overlay._boundsNow().tmax, 4.5, 1e-9, "right edge moved by 0.5 s")
  overlay.finish()
end)

h.test("scale: a grab off the handle centre does not move the points", function()
  launch()
  Mx, My, Down = 160, 150, true; frame()   -- 4 px below the top Scale handle
  Down = false; frame()
  h.almost(overlay._boundsNow().vmax, 0.6, 1e-9, "top stays at 0.6")
  overlay.finish()
end)

h.test("tilt: a grab off the handle centre does not move the points", function()
  launch()
  Mx, My, Down = 316, 150, true; frame()   -- 4 px off the right Tilt handle
  Down = false; frame()
  local b = overlay._boundsNow()
  h.almost(b.vmax, 0.6, 1e-9, "top stays at 0.6"); h.almost(b.vmin, -0.5, 1e-9, "bottom stays at -0.5")
  overlay.finish()
end)

h.test("flat shape: grabbing the widened box's Scale handle does not move the points", function()
  -- All values 0: the box is widened to 44 px for display, so the top Scale handle sits 22 px above
  -- the points. Grabbing it must not pull the points up to the mouse.
  launch(flatPoints())
  Mx, My, Down = 160, 148, true; frame()
  Down = false; frame()
  local b = overlay._boundsNow()
  h.almost(b.vmax, 0.01, 1e-9, "values stay at 0 (bounds pad a flat line by +/-0.01)")
  overlay.finish()
end)

---------------------------------------------------------------------------------------------------
-- Vertical steps: two points at one time. Their order decides the step's direction.
---------------------------------------------------------------------------------------------------
-- 12 steps from -0.4 up to 0.4, at t = 0.25, 0.5, ... 3.0. tension carries each point's list position.
local function stepPoints()
  local pts = {}
  for i = 1, 24 do
    pts[i] = { time = ((i + 1) // 2) * 0.25, value = (i % 2 == 0) and 0.4 or -0.4,
               shape = 0, tension = i / 100, sel = true }
  end
  return pts
end

-- true when every same-time pair in `ins` is written in its original order, and all 12 pairs are there
local function stepsIntact(ins, reversed)
  local pairs = 0
  for i = 2, #ins do
    if ins[i].t == ins[i - 1].t then
      pairs = pairs + 1
      local up = ins[i].tension > ins[i - 1].tension
      if up == (reversed or false) then return false, "pair at t=" .. ins[i].t .. " in the wrong order" end
    end
  end
  return pairs == 12, "found " .. pairs .. " same-time pairs, expected 12"
end

h.test("vertical steps keep their direction across repeated drags", function()
  launch(stepPoints())                     -- box x 20..240, widened to y 148..192; Scale T at (130,148)
  Mx, My, Down = 130, 148, true; frame()
  My = 144; frame()                        -- first drag: scale up a little
  Down = false; frame()                    -- release: the result becomes the new baseline
  Mx, My, Down = 130, 146, true; frame()   -- second drag on the moved handle
  My = 140; local ins = frame()
  Down = false; frame()
  h.truthy(stepsIntact(ins))
  overlay.finish()
end)

h.test("reverse mirrors each step: its two points swap order", function()
  launch(stepPoints())
  overlay._pendingOneShot = "reverse"
  local ins = frame()
  h.truthy(stepsIntact(ins, true))
  overlay.finish()
end)

---------------------------------------------------------------------------------------------------
-- Holding still: no rewrite while the mouse and the settings do not change.
---------------------------------------------------------------------------------------------------
h.test("holding a handle still does not rewrite the points", function()
  launch()
  Mx, My, Down = 320, 168, true; frame()
  Mx = 360
  local _, wrote = frame(); h.truthy(wrote, "a move writes")
  _, wrote = frame();       h.truthy(not wrote, "the same position must not write again")
  overlay.params.symmetrical = true
  _, wrote = frame();       h.truthy(wrote, "a setting change writes")
  Down = false; frame()
  overlay.finish()
end)

---------------------------------------------------------------------------------------------------
-- ImGui pairing: End only after a Begin that returned true (ReaImGui's rule; contour.lua follows it).
---------------------------------------------------------------------------------------------------
h.test("no ImGui_End when ImGui_Begin returns false", function()
  launch()
  local ends = 0
  local oldBegin = reaper.ImGui_Begin
  reaper.ImGui_Begin = function() return false end
  reaper.ImGui_End = function() ends = ends + 1 end
  frame()
  reaper.ImGui_Begin, reaper.ImGui_End = oldBegin, nil
  h.eq(ends, 0, "End calls")
  overlay.finish()
end)

---------------------------------------------------------------------------------------------------
-- Saved settings: Symmetrical, Power/Sine, Flip mode and Small handles survive a relaunch. Curve does
-- not: a forgotten curve would change the next result without a warning.
---------------------------------------------------------------------------------------------------
h.test("saved settings load at launch", function()
  stub.reset()
  stub.rec.extState["tr_sym"] = "1"
  stub.rec.extState["tr_shape"] = "sine"
  stub.rec.extState["tr_flipmode"] = "relative"
  stub.rec.extState["tr_handles"] = "small"
  overlay.params = defaults()
  h.truthy(overlay.start(CTX, detEnv()), "start")
  h.eq(overlay.params.symmetrical, true, "Symmetrical")
  h.eq(overlay.params.shape, "sine", "Power/Sine")
  h.eq(overlay.params.flipMode, "relative", "Flip mode")
  h.eq(overlay.params.smallHandles, true, "Small handles")
  overlay.finish()
end)

h.test("a changed setting is saved; Curve is not", function()
  launch()
  local p = overlay.params
  p.symmetrical, p.shape, p.flipMode, p.smallHandles, p.knob = true, "sine", "relative", true, 40
  frame()
  h.eq(stub.rec.extState["tr_sym"], "1", "Symmetrical")
  h.eq(stub.rec.extState["tr_shape"], "sine", "Power/Sine")
  h.eq(stub.rec.extState["tr_flipmode"], "relative", "Flip mode")
  h.eq(stub.rec.extState["tr_handles"], "small", "Small handles")
  for key in pairs(stub.rec.extState) do h.truthy(not key:find("knob") and not key:find("curve"), "saved " .. key) end
  overlay.finish()
end)

h.test("right-click toggles Symmetrical and the new state is saved", function()
  launch()
  reaper.ImGui_IsMouseClicked = function(_c, btn) return btn == 1 end
  frame()
  reaper.ImGui_IsMouseClicked = nil
  h.eq(stub.rec.extState["tr_sym"], "1")
  overlay.finish()
end)

---------------------------------------------------------------------------------------------------
-- Shift + centre handle: every point moves up or down by the same amount; times stay.
---------------------------------------------------------------------------------------------------
h.test("Shift + centre handle moves every point by the same amount; times stay", function()
  launch()
  Mods = SHIFT
  Mx, My, Down = 160, 168, true; frame()
  My = 160; local ins = frame()            -- 8 px up = +0.2
  Down = false; Mods = 0; frame()
  h.eq(#ins, 3, "points written")
  h.almost(ins[1].t, 0, 1e-9); h.almost(ins[1].v, -0.3, 1e-9)
  h.almost(ins[2].t, 2, 1e-9); h.almost(ins[2].v, 0.8, 1e-9)
  h.almost(ins[3].t, 4, 1e-9); h.almost(ins[3].v, 0.0, 1e-9)
  h.eq(overlay._statusNow(), "Move +10%", "status: 0.2 of the 2.0 lane range")
  overlay.finish()
end)

h.test("Shift-move: a point that reaches the lane top stops there; the others keep moving", function()
  launch()
  Mods = SHIFT
  Mx, My, Down = 160, 168, true; frame()
  My = 148; local ins = frame()            -- 20 px up = +0.5; 0.6 would go to 1.1
  Down = false; Mods = 0; frame()
  h.almost(ins[1].v, 0.0, 1e-9); h.almost(ins[2].v, 1.0, 1e-9); h.almost(ins[3].v, 0.3, 1e-9)
  overlay.finish()
end)

h.test("releasing Shift during the drag returns to the normal warp", function()
  launch()
  Mods = SHIFT
  Mx, My, Down = 160, 168, true; frame()
  My = 160; frame()
  Mods = 0; local ins = frame()            -- same mouse position, Shift released
  Down = false; frame()
  h.almost(ins[1].v, -0.5, 1e-9, "warp pins the left edge")
  h.almost(ins[3].v, -0.2, 1e-9, "warp pins the right edge")
  h.truthy(ins[2].v > 0.6, "warp lifts the point under the cursor")
  overlay.finish()
end)

---------------------------------------------------------------------------------------------------
-- Small handles: coloured dots, no arrows, a smaller grab area and a smaller minimum box.
---------------------------------------------------------------------------------------------------
local function countTriangles(fn)
  local n = 0
  reaper.ImGui_DrawList_AddTriangleFilled = function() n = n + 1 end
  fn()
  reaper.ImGui_DrawList_AddTriangleFilled = nil
  return n
end

h.test("full handles draw arrows; small handles draw none", function()
  launch(nil, { tr_hudcollapsed = "1" })   -- collapsed HUD: its Curve fader notches are triangles too
  h.truthy(countTriangles(frame) > 0, "full handles have arrow heads")
  overlay.params.smallHandles = true
  h.eq(countTriangles(frame), 0, "small handles have no arrow heads")
  overlay.finish()
end)

h.test("small handles: a press 8 px off a handle does not grab it", function()
  launch()
  overlay.params.smallHandles = true
  Mx, My, Down = 312, 168, true; frame()   -- inside the full grab area (10 px), outside the small one
  Mx = 352; frame()
  Down = false; frame()
  h.almost(overlay._boundsNow().tmax, 4, 1e-9, "no grab, so no stretch")
  overlay.finish()
end)

h.test("small handles: a flat shape gets a smaller minimum box", function()
  launch(flatPoints())
  overlay.params.smallHandles = true
  frame()
  local r = overlay._boxPxNow()
  h.almost(r.y1 - r.y0, 28, 1e-6, "minimum box height with small handles")
  overlay.finish()
end)

h.test("the HUD checkbox turns small handles on", function()
  launch()
  reaper.ImGui_Checkbox = function(_c, label, v)
    if label:find("hud_small", 1, true) then return true, true end
    return false, v
  end
  frame()
  reaper.ImGui_Checkbox = function(_c, _l, v) return false, v end
  h.eq(overlay.params.smallHandles, true, "param set")
  frame()
  h.eq(stub.rec.extState["tr_handles"], "small", "saved")
  overlay.finish()
end)

h.run()
