-- tests/test_cclane_stack.lua — multi-lane CC support for the Transform overlay: the VELLANE stack
-- parser (pure seams) + overlay smoke with MULTIPLE visible CC lanes. The overlay must start and map
-- the ACTIVE lane's own strip (the old code refused with "show only ONE CC lane"), refuse cleanly when
-- the active lane isn't visible, and survive macOS-style flipped+scaled coordinates over the stack.
package.path = package.path .. ";./Contour/?.lua;./?.lua;./tests/?.lua"

local stub = require("reaper_stub")
stub.install()                          -- MUST precede the ui.* requires

local h = require("harness")
local overlay = require("ui.overlay")

local CTX = "CTX"
local function detCC()
  return { target = "cc", label = "CC1", hasTimeSel = true, t0 = 0, t1 = 4,
           details = { take = "TAKE", midiEditor = "ME" } }
end

-- chunk builder: CFGEDITVIEW + one VELLANE per {laneId, height}, in on-screen top-to-bottom order
local function chunkFor(lanes)
  local s = "CFGEDITVIEW 0 1.0 0 0 0\n"
  for _, e in ipairs(lanes) do s = s .. ("VELLANE %d %d 0\n"):format(e[1], e[2]) end
  return s
end

-- ── pure stack math (seams) ──────────────────────────────────────────────────
h.test("parseVellanes reads every lane + height in chunk (top-to-bottom) order", function()
  local lanes = overlay._parseVellanes(chunkFor({ { -1, 60 }, { 1, 90 }, { 11, 50 } }))
  h.eq(#lanes, 3)
  h.eq(lanes[1].lane, -1); h.eq(lanes[1].h, 60)   -- velocity lane on top
  h.eq(lanes[2].lane, 1);  h.eq(lanes[2].h, 90)
  h.eq(lanes[3].lane, 11); h.eq(lanes[3].h, 50)
end)

h.test("laneSlot: bottom lane offset 0; middle sums the lanes below; missing lane is nil", function()
  local lanes = overlay._parseVellanes(chunkFor({ { -1, 60 }, { 1, 90 }, { 11, 50 } }))
  local hgt, off = overlay._laneSlot(lanes, 11)   -- bottom of the stack -> anchored to the midiview bottom
  h.eq(hgt, 50); h.eq(off, 0)
  hgt, off = overlay._laneSlot(lanes, 1)          -- middle: CC11 (50 px) sits below it
  h.eq(hgt, 90); h.eq(off, 50)
  hgt, off = overlay._laneSlot(lanes, -1)         -- top: 90 + 50 px below
  h.eq(hgt, 60); h.eq(off, 140)
  h.eq(overlay._laneSlot(lanes, 64), nil)         -- not in the stack
end)

h.test("single visible lane is the degenerate case: offset 0 (old behavior preserved)", function()
  local lanes = overlay._parseVellanes(chunkFor({ { 1, 90 } }))
  local hgt, off = overlay._laneSlot(lanes, 1)
  h.eq(hgt, 90); h.eq(off, 0)
end)

-- ── overlay smoke with a multi-lane stack ────────────────────────────────────
local function wrote() return stub.rec.ccIns > 0 or stub.rec.setAllEvts > 0 end

h.test("overlay CC starts + transforms with multiple visible lanes (active in the middle)", function()
  stub.reset()
  stub.itemChunk = chunkFor({ { -1, 60 }, { stub.CC_LANE, 90 }, { 11, 50 } })
  overlay.params = { knob = 0, shape = "power", symmetrical = false, flipMode = "absolute" }
  local started, serr = overlay.start(CTX, detCC())
  h.truthy(started, "start must succeed with multiple visible lanes: " .. tostring(serr))
  local ok, err = pcall(function()
    overlay.frame(CTX); overlay.frame(CTX)
    overlay._pendingOneShot = "flip"; overlay.frame(CTX)
  end)
  h.truthy(ok, "frames threw: " .. tostring(err))
  h.truthy(wrote(), "the flip one-shot should have written")
  overlay.finish()
end)

h.test("overlay CC multi-lane under macOS-style flipped + scaled coords (no crash)", function()
  stub.reset()
  stub.itemChunk = chunkFor({ { -1, 60 }, { stub.CC_LANE, 90 }, { 11, 50 } })
  local saved = reaper.ImGui_PointConvertNative
  reaper.ImGui_PointConvertNative = function(_ctx, x, y) return x * 2, 1200 - y * 2 end  -- Retina-ish 2x + Y-flip
  local ok, err = pcall(function()
    overlay.params = { knob = 20, shape = "sine", symmetrical = true, flipMode = "relative" }
    local started, serr = overlay.start(CTX, detCC())
    h.truthy(started, "start under flipped coords: " .. tostring(serr))
    overlay.frame(CTX); overlay.frame(CTX)
    overlay._pendingOneShot = "reverse"; overlay.frame(CTX)
    overlay.finish()
  end)
  reaper.ImGui_PointConvertNative = saved     -- always restore, even if the body threw
  h.truthy(ok, "flipped multi-lane overlay threw: " .. tostring(err))
end)

h.test("active lane hidden (not in the visible stack) -> clean refusal, no mis-mapping", function()
  stub.reset()
  stub.itemChunk = chunkFor({ { -1, 60 }, { 11, 50 } })   -- the clicked lane (CC_LANE) is not visible
  local started, serr = overlay.start(CTX, detCC())
  h.eq(started, false, "must refuse when the clicked lane isn't visible")
  h.truthy(tostring(serr):find("visible") ~= nil, "error should say the lane isn't visible, got: " .. tostring(serr))
end)

h.run()
