-- tests/test_overlay_bounds.lua — after an EXTREME transform, the baked baseline (and therefore the
-- re-rendered box) must stay within the lane's value range. The write layer clamps at insert time, so
-- the envelope itself is already clamped; without the bake-time clamp the in-memory points kept the
-- unclamped values and the box re-rendered outside the lane. The test scripts a real drag: grab the
-- top Scale handle, drag far above the lane, release, then check the baked bounds.
package.path = package.path .. ";./Contour/?.lua;./?.lua;./tests/?.lua"

local stub = require("reaper_stub")
stub.install()

local h = require("harness")
local overlay = require("ui.overlay")

local CTX = "CTX"
local function detEnv()
  return { target = "envelope", label = "Pan", hasTimeSel = true, t0 = 0, t1 = 4, details = { env = {} } }
end

-- scripted mouse (frame-by-frame): stub geometry puts the selection box at x 0..320, y 146..190
-- (values -0.5..0.6 on a -1..1 lane drawn at 130..210), so the top Scale handle sits at (160, 146).
local Mx, My, Down = 0, 0, false
reaper.ImGui_GetMousePos = function() return Mx, My end
reaper.ImGui_IsMouseDown = function() return Down end

h.test("extreme scale: baked bounds stay inside the lane's value range", function()
  stub.reset()
  overlay.params = { knob = 0, shape = "power", symmetrical = false, flipMode = "absolute" }
  local started, serr = overlay.start(CTX, detEnv())
  h.truthy(started, "start: " .. tostring(serr))

  Mx, My, Down = 160, 146, true       -- frame 1: press on the top Scale handle -> grab
  overlay.frame(CTX)
  Mx, My = 160, 100                   -- frame 2: drag far ABOVE the lane top (value ~1.75 on a -1..1 lane)
  overlay.frame(CTX)
  Down = false                        -- frame 3: release -> the transform bakes into the baseline
  overlay.frame(CTX)

  local b = overlay._boundsNow()
  h.truthy(b ~= nil, "bounds available")
  h.truthy(b.vmax <= 1 + 1e-9, "baked vmax must not exceed the lane top (1), got " .. tostring(b.vmax))
  h.truthy(b.vmin >= -1 - 1e-9, "baked vmin must not exceed the lane bottom (-1), got " .. tostring(b.vmin))
  overlay.finish()
end)

h.test("flattened shape: the box keeps a minimum on-screen size so handles stay usable", function()
  stub.reset()
  overlay.params = { knob = 0, shape = "power", symmetrical = false, flipMode = "absolute" }
  local started, serr = overlay.start(CTX, detEnv())
  h.truthy(started, "start: " .. tostring(serr))

  Mx, My, Down = 160, 146, true       -- press on the top Scale handle
  overlay.frame(CTX)
  Mx, My = 160, 190                   -- drag the top edge onto the BOTTOM edge -> shape scales to flat
  overlay.frame(CTX)
  Down = false                        -- release: flat shape bakes
  overlay.frame(CTX)
  Mx, My = 400, 300                   -- idle frame: box re-rendered around the flat baseline
  overlay.frame(CTX)

  local r = overlay._boxPxNow()
  h.truthy(r ~= nil, "box rect available")
  h.truthy(r.y1 - r.y0 >= 44 - 1e-6,
    "flat shape must keep a min-height box (handles separated), got " .. tostring(r.y1 - r.y0))
  overlay.finish()
end)

-- Horizontal (time) boundaries: automation items / take envelopes clamp WRITES to the item bounds,
-- and track envelopes can't go before project start — the baked baseline must match, or the box
-- stretches past boundaries the actual points piled up against.
local function detAI()
  return { target = "ai", label = "AI", hasTimeSel = true, t0 = 0, t1 = 4,
           details = { env = {}, aiIndex = 0 } }
end

h.test("extreme right-stretch on an automation item: baked times clamp to the item end", function()
  stub.reset()
  overlay.params = { knob = 0, shape = "power", symmetrical = false, flipMode = "absolute" }
  local started, serr = overlay.start(CTX, detAI())
  h.truthy(started, "start: " .. tostring(serr))
  -- AI fixture: sel points at t=1 and t=3 (box x 80..240), item bounds [0,10] (view maps 0..10 -> 0..800)
  Mx, My, Down = 240, 170, true       -- press the RIGHT Stretch handle (box is min-height-expanded; cy=170)
  overlay.frame(CTX)
  Mx = 1200                           -- drag far beyond the view: target time 15, item ends at 10
  overlay.frame(CTX)
  Down = false
  overlay.frame(CTX)
  local b = overlay._boundsNow()
  h.truthy(b.tmax <= 10 + 1e-9, "baked tmax must clamp to the item end (10), got " .. tostring(b.tmax))
  overlay.finish()
end)

h.test("extreme left-stretch on a track envelope: baked times clamp to project start", function()
  stub.reset()
  overlay.params = { knob = 0, shape = "power", symmetrical = false, flipMode = "absolute" }
  local started, serr = overlay.start(CTX, detEnv())
  h.truthy(started, "start: " .. tostring(serr))
  -- env fixture: sel points at t=0,2,4 (box x 0..320); grab the LEFT Stretch handle at (0, cy=168)
  Mx, My, Down = 0, 168, true
  overlay.frame(CTX)
  Mx = -400                           -- drag far left of the view: target time -5
  overlay.frame(CTX)
  Down = false
  overlay.frame(CTX)
  local b = overlay._boundsNow()
  h.truthy(b.tmin >= -1e-9, "baked tmin must clamp to project start (0), got " .. tostring(b.tmin))
  overlay.finish()
end)

-- CC follows the same rule as juliansader's Multi Tool: edits never leave the item bounds
-- (stub CC item "TITEM": project bounds [3, 8]; CC events at t=1,3 -> box x 100..300 via ppq*1px).
h.test("extreme right-stretch on MIDI CC: baked times clamp to the item end", function()
  stub.reset()
  overlay.params = { knob = 0, shape = "power", symmetrical = false, flipMode = "absolute" }
  local det = { target = "cc", label = "CC1", hasTimeSel = true, t0 = 0, t1 = 4,
                details = { take = "TAKE", midiEditor = "ME" } }
  local started, serr = overlay.start(CTX, det)
  h.truthy(started, "start: " .. tostring(serr))
  Mx, My, Down = 300, 551, true       -- press the RIGHT Stretch handle (box min-height-expanded, cy~551)
  overlay.frame(CTX)
  Mx = 1200                           -- drag to time 12; the item ends at 8
  overlay.frame(CTX)
  Down = false
  overlay.frame(CTX)
  local b = overlay._boundsNow()
  h.truthy(b.tmax <= 8 + 1e-9, "baked CC tmax must clamp to the item end (8), got " .. tostring(b.tmax))
  overlay.finish()
end)

-- STORED overshoot: points can hold values beyond the CURRENT lane range (written under a wider range
-- preference that was later changed back, other tools, imports). REAPER draws them clipped at the
-- rail — the box must hug the lane the same way at LAUNCH, not scale the overshoot off-screen.
h.test("launch on points holding values beyond the lane range: box top hugs the lane top", function()
  stub.reset()
  stub.envPoints = {
    { time = 0.0, value = 5.0,  shape = 0, tension = 0, sel = true },   -- far above the -1..1 lane
    { time = 2.0, value = -0.5, shape = 0, tension = 0, sel = true },
    { time = 4.0, value = 0.2,  shape = 0, tension = 0, sel = true },
  }
  overlay.params = { knob = 0, shape = "power", symmetrical = false, flipMode = "absolute" }
  local started, serr = overlay.start(CTX, detEnv())
  h.truthy(started, "start: " .. tostring(serr))
  overlay.frame(CTX)
  local px = overlay._boxPxNow()
  h.almost(px.y0, 130, 1e-6, "box top = lane top (Y at vhi=1), not off-screen at Y(5)")
  h.almost(px.y1, 190, 1e-6, "box bottom = Y(-0.5), unaffected")
  overlay.finish()
end)

h.test("launch on an AI point beyond the item end: box right edge hugs the item end", function()
  stub.reset()
  stub.aiPoints = {
    { time = 1.0,  value = 0.3,  shape = 0, tension = 0, sel = true },
    { time = 12.0, value = -0.3, shape = 0, tension = 0, sel = true },  -- beyond the item end (10)
  }
  overlay.params = { knob = 0, shape = "power", symmetrical = false, flipMode = "absolute" }
  local started, serr = overlay.start(CTX, detAI())
  h.truthy(started, "start: " .. tostring(serr))
  overlay.frame(CTX)
  local px = overlay._boxPxNow()
  h.truthy(px.x1 <= 800 + 1e-6, "box right edge at the item end (x 800), got " .. tostring(px.x1))
  overlay.finish()
end)

h.run()
