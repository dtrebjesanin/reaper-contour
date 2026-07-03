-- tests/test_cc_editor_view.lua — ccSetup must read the ACTIVE take's view state and honor the MIDI
-- editor's timebase. One item chunk holds every take's CFGEDITVIEW/VELLANE lines, so an un-sliced
-- match read take 1's zoom/lanes while editing take 2 (box at the wrong x, drags writing wrong times).
-- And CFGEDITVIEW's zoom field is pixels-per-TICK only in Beats timebase (CFGEDIT field 19 = 0/4);
-- in "Time (project)"/"Sync to arrange" it is pixels-per-SECOND (juliansader's Multi Tool rule).
-- Also: chunk floats can be scientific notation ("6.5e-05" at extreme zoom-out) — the old [%d%.]
-- pattern silently truncated the exponent, inflating the zoom ~100000x.
package.path = package.path .. ";./Contour/?.lua;./?.lua;./tests/?.lua"

local stub = require("reaper_stub")
stub.install()

local h = require("harness")
local overlay = require("ui.overlay")

local function detCC()
  return { target = "cc", label = "CC1", hasTimeSel = true, t0 = 0, t1 = 4,
           details = { take = "TAKE", midiEditor = "ME" } }
end

-- Two-take item: take 1 (CFGEDITVIEW 999 9.9, lane 7 only) + take 2 (CFGEDITVIEW 0 1.0, lane 1).
local TWO_TAKES = "CFGEDITVIEW 999 9.9 0 0 0\nVELLANE 7 90 0\n" ..
                  "TAKE SEL\nNAME \"take 2\"\nCFGEDITVIEW 0 1.0 0 0 0\nVELLANE 1 90 0\n"

h.test("multi-take item: ccSetup reads the ACTIVE take's view, not the first take's", function()
  stub.reset()
  stub.itemChunk = TWO_TAKES
  stub.TAKE_NUM = 1                       -- editing the SECOND take
  local cc, err = overlay._ccSetup(detCC(), 1)
  h.truthy(cc, "setup: " .. tostring(err))
  h.almost(cc.leftTick, 0, 1e-9, "take 2's leftTick, not take 1's 999")
  h.almost(cc.pxPerTick, 1.0, 1e-9, "take 2's zoom, not take 1's 9.9")
end)

h.test("first take of a multi-take item still resolves its own view (regression)", function()
  stub.reset()
  stub.itemChunk = "CFGEDITVIEW 5 2.0 0 0 0\nVELLANE 1 90 0\n" ..
                   "TAKE\nNAME \"take 2\"\nCFGEDITVIEW 999 9.9 0 0 0\nVELLANE 7 90 0\n"
  stub.TAKE_NUM = 0
  local cc, err = overlay._ccSetup(detCC(), 1)
  h.truthy(cc, "setup: " .. tostring(err))
  h.almost(cc.leftTick, 5, 1e-9)
  h.almost(cc.pxPerTick, 2.0, 1e-9)
end)

h.test("editor timebase 'time': zoom is flagged px-per-SECOND with the left edge as time", function()
  stub.reset()
  stub.itemChunk = "CFGEDIT 4 0 0 0 0 0 0 1 0 0 0 0 0 0 0 0 0 0 2 0 0 0\n" ..
                   "CFGEDITVIEW 0 50.0 0 0 0\nVELLANE 1 90 0\n"
  local cc, err = overlay._ccSetup(detCC(), 1)
  h.truthy(cc, "setup: " .. tostring(err))
  h.truthy(cc.timeMode, "CFGEDIT field 19 = 2 -> time-linear x axis")
  h.almost(cc.leftTime, 0, 1e-9, "left edge converted to project time")
end)

h.test("editor timebase beats (0/4) and missing CFGEDIT stay tick-linear (regression)", function()
  stub.reset()
  stub.itemChunk = "CFGEDIT 4 0 0 0 0 0 0 1 0 0 0 0 0 0 0 0 0 0 4 0 0 0\n" ..
                   "CFGEDITVIEW 0 1.0 0 0 0\nVELLANE 1 90 0\n"
  local cc = overlay._ccSetup(detCC(), 1)
  h.truthy(cc and not cc.timeMode, "timebase 4 = source beats -> ticks")
  stub.reset()                            -- stock chunk has no CFGEDIT line at all
  cc = overlay._ccSetup(detCC(), 1)
  h.truthy(cc and not cc.timeMode, "no CFGEDIT -> ticks (old behavior)")
end)

h.test("scientific-notation zoom parses fully instead of dropping the exponent", function()
  stub.reset()
  stub.itemChunk = "CFGEDITVIEW 0 6.5e-05 0 0 0\nVELLANE 1 90 0\n"
  local cc, err = overlay._ccSetup(detCC(), 1)
  h.truthy(cc, "setup: " .. tostring(err))
  h.almost(cc.pxPerTick, 6.5e-05, 1e-12, "full 6.5e-05, not a truncated 6.5")
end)

h.test("time mode end-to-end: the box lands at time-linear x positions", function()
  stub.reset()
  stub.itemChunk = "CFGEDIT 4 0 0 0 0 0 0 1 0 0 0 0 0 0 0 0 0 0 2 0 0 0\n" ..
                   "CFGEDITVIEW 0 50.0 0 0 0\nVELLANE 1 90 0\n"
  -- events INSIDE the CC item's bounds [3, 8] so the display clamp stays out of the picture
  stub.ccList = {
    { ppq = 400, chan = 0, lane = 1, val = 64, shape = 1, tension = 0, sel = true },
    { ppq = 600, chan = 0, lane = 1, val = 90, shape = 1, tension = 0, sel = true },
  }
  overlay.params = { knob = 0, shape = "power", symmetrical = false, flipMode = "absolute" }
  local started, serr = overlay.start("CTX", detCC())
  h.truthy(started, "start: " .. tostring(serr))
  overlay.frame("CTX")
  local px = overlay._boxPxNow()
  h.truthy(px ~= nil, "box rect available")
  -- events at t=4s and t=6s, px/sec = 50, left edge t=0 at x=0 -> box x 200..300
  h.almost(px.x0, 200, 1e-6, "x0 = 4s * 50 px/s (tick math would give 20000)")
  h.almost(px.x1, 300, 1e-6, "x1 = 6s * 50 px/s")
  overlay.finish()
end)

h.run()
