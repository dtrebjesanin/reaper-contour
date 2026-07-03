-- tests/test_overlay_ordering.lua — transforms that REORDER points in time (Reverse; a Stretch dragged
-- across its anchor) baked a DESCENDING-time baseline into g.orig. warp2d's anti-fold guard assumes
-- time-ascending input ("never let a point pass its neighbour"), so on a descending baseline it fired
-- on every point and collapsed the whole shape into an epsilon stack at the right edge — the live
-- write committed the destruction on the first drag frame. The baked baseline must stay ascending.
-- Stub geometry (see test_overlay_bounds): env points at t=0,2,4 (values -0.5, 0.6, -0.2) on a -1..1
-- lane drawn at y 130..210; view maps t 0..10 -> x 0..800. Box x 0..320, y 146..190, center (160,168).
package.path = package.path .. ";./Contour/?.lua;./?.lua;./tests/?.lua"

local stub = require("reaper_stub")
stub.install()

local h = require("harness")
local overlay = require("ui.overlay")

local CTX = "CTX"
local function detEnv()
  return { target = "envelope", label = "Pan", hasTimeSel = true, t0 = 0, t1 = 4, details = { env = {} } }
end

local Mx, My, Down = 0, 0, false
reaper.ImGui_GetMousePos = function() return Mx, My end
reaper.ImGui_IsMouseDown = function() return Down end

h.test("warp after Reverse keeps the shape's time extent (no epsilon-stack collapse)", function()
  stub.reset()
  overlay.params = { knob = 0, shape = "power", symmetrical = false, flipMode = "absolute" }
  local started, serr = overlay.start(CTX, detEnv())
  h.truthy(started, "start: " .. tostring(serr))

  overlay._pendingOneShot = "reverse"
  Mx, My, Down = 400, 300, false
  overlay.frame(CTX)                   -- applies Reverse, bakes the mirrored baseline

  Mx, My, Down = 160, 168, true        -- grab the center Warp handle
  overlay.frame(CTX)
  Mx = 200                             -- nudge the peak right by ~0.5s
  overlay.frame(CTX)
  Down = false                         -- release: bake
  overlay.frame(CTX)

  local b = overlay._boundsNow()
  h.truthy(b.tmax - b.tmin > 3,
    "time span must survive a warp after Reverse, got " .. tostring(b.tmax - b.tmin))
  overlay.finish()
end)

h.test("stretch dragged across its anchor bakes an ascending baseline (warp survives)", function()
  stub.reset()
  overlay.params = { knob = 0, shape = "power", symmetrical = true, flipMode = "absolute" }
  local started, serr = overlay.start(CTX, detEnv())
  h.truthy(started, "start: " .. tostring(serr))

  Mx, My, Down = 320, 168, true        -- grab the RIGHT Stretch handle (symmetrical: anchor = center t=2)
  overlay.frame(CTX)
  Mx = 80                              -- drag it to t=1, PAST the anchor: factor -0.5, times mirror to 3,2,1
  overlay.frame(CTX)
  Down = false
  overlay.frame(CTX)                   -- bake the crossed-over result

  local b0 = overlay._boundsNow()
  h.truthy(b0.tmax - b0.tmin > 1.5, "crossed stretch spans ~2s, got " .. tostring(b0.tmax - b0.tmin))

  Mx, My, Down = 160, 168, true        -- warp nudge on the new box (center unchanged at x=160)
  overlay.frame(CTX)
  Mx = 180
  overlay.frame(CTX)
  Down = false
  overlay.frame(CTX)

  local b = overlay._boundsNow()
  h.truthy(b.tmax - b.tmin > 1.5,
    "time span must survive a warp after a crossed stretch, got " .. tostring(b.tmax - b.tmin))
  overlay.finish()
end)

h.run()
