-- tests/test_hud_place.lua — Transform HUD placement + collapse + drag persistence. The HUD's home is
-- the VIEW's top-right corner (fixed, predictable); a user-dragged (parked) position beats it and is
-- stored view-relative + clamped; double-click empty panel space returns to the corner. Collapsed =
-- a slim status strip, persisted. (Stub view: trackview client rect 0,0..800,600; HUD 250x236/28.)
package.path = package.path .. ";./Contour/?.lua;./?.lua;./tests/?.lua"

local stub = require("reaper_stub")
stub.install()

local h = require("harness")
local overlay = require("ui.overlay")

local CTX = "CTX"
local function detEnv()
  return { target = "envelope", label = "Pan", hasTimeSel = true, t0 = 0, t1 = 4, details = { env = {} } }
end

-- Default home = the ORIGINAL placement: off the selection BOX's top-right corner, clamped into the
-- view. Under the stub the box is x0=0..x1=320 (times 0..4 over a 0..10s view, 800px wide) with
-- yt=146, so: x = 320+14 = 334; y = 146-236-16 = -106 -> clamped to the view top margin (4).
h.test("default home: off the box's top-right corner (original placement)", function()
  stub.reset()
  overlay.params = { knob = 0, shape = "power", symmetrical = false, flipMode = "absolute" }
  local started, serr = overlay.start(CTX, detEnv())
  h.truthy(started, "start: " .. tostring(serr))
  overlay.frame(CTX)
  local r = overlay._hudRectNow()
  h.truthy(r ~= nil, "hud rect available")
  h.almost(r.x, 334, 1e-6, "x = box right edge + 14")
  h.almost(r.y, 4, 1e-6, "y clamped to the view top (no headroom above the box)")
  overlay.finish()
end)

h.test("overlay runs with the HUD collapsed (persisted via ExtState)", function()
  stub.reset()
  stub.rec.extState["tr_hudcollapsed"] = "1"
  overlay.params = { knob = 0, shape = "power", symmetrical = false, flipMode = "absolute" }
  local started, serr = overlay.start(CTX, detEnv())
  h.truthy(started, "start: " .. tostring(serr))
  local ok, err = pcall(function() overlay.frame(CTX); overlay.frame(CTX) end)
  h.truthy(ok, "collapsed frame threw: " .. tostring(err))
  local r = overlay._hudRectNow()
  h.almost(r.h, 28, 1e-6, "collapsed = slim strip")
  overlay.finish()
end)

-- The dragged position is SESSION-ONLY: a leftover tr_hudpos (e.g. written by an older build) must be
-- ignored — every launch starts at the default spot off the box's top-right corner.
h.test("a stale tr_hudpos ExtState is ignored: every launch starts at the default spot", function()
  stub.reset()
  stub.rec.extState["tr_hudpos"] = "500,300"
  local started, serr = overlay.start(CTX, detEnv())
  h.truthy(started, "start: " .. tostring(serr))
  overlay.frame(CTX)
  local r = overlay._hudRectNow()
  h.almost(r.x, 334, 1e-6, "default x (not the stale 500)")
  h.almost(r.y, 4, 1e-6, "default y (not the stale 300)")
  overlay.finish()
end)

h.run()
