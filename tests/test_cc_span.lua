-- tests/test_cc_span.lua — spanFor must clamp a CC time selection to the MIDI item's bounds, the same
-- rule automation items and take envelopes already follow (and Transform enforces via
-- targetTimeBounds). Unclamped, a selection wider than the item converted to out-of-item (even
-- negative) ticks and Generate/Reduce wrote or deleted events outside the take. fullSpan is
-- loop-aware, so this also stops a time selection writing past a looped item's first pass.
-- Stub geometry: the CC take's item TITEM spans project 3..8s.
package.path = package.path .. ";./Contour/?.lua;./?.lua;./tests/?.lua"

local stub = require("reaper_stub")
stub.install()

local h = require("harness")
local target = require("core.target")
local common = require("ui.common")

local function detCC(t0, t1)
  return { target = "cc", label = "CC1", hasTimeSel = true, t0 = t0, t1 = t1,
           details = { take = "TAKE", midiEditor = "ME" } }
end

h.test("CC time selection wider than the item clamps to the item bounds", function()
  stub.reset()
  local det = detCC(0, 9)
  local tgt = target.fromContext(det)
  local a, b = common.spanFor(tgt, det, { scope = common.SCOPE_TIMESEL })
  h.almost(a, 3, 1e-9, "span start = item start, not selection start")
  h.almost(b, 8, 1e-9, "span end = item end, not selection end")
end)

h.test("CC time selection inside the item passes through unchanged", function()
  stub.reset()
  local det = detCC(4, 6)
  local tgt = target.fromContext(det)
  local a, b = common.spanFor(tgt, det, { scope = common.SCOPE_TIMESEL })
  h.almost(a, 4, 1e-9); h.almost(b, 6, 1e-9)
end)

h.test("looped CC item: the time selection clamps to the first loop pass", function()
  stub.reset()
  stub.LOOP_SRC, stub.SRC_LEN_QN = 1, 24        -- first-iteration end at 6s (see test_cc_loop)
  local det = detCC(4, 7.5)
  local tgt = target.fromContext(det)
  local a, b = common.spanFor(tgt, det, { scope = common.SCOPE_TIMESEL })
  h.almost(a, 4, 1e-9); h.almost(b, 6, 1e-9, "clamped to the loop boundary")
end)

h.test("track envelope time selection stays unclamped (no item)", function()
  stub.reset()
  local det = { target = "envelope", label = "Env", hasTimeSel = true, t0 = 0, t1 = 9,
                details = { env = "ENV" } }
  local tgt = target.fromContext(det)
  local a, b = common.spanFor(tgt, det, { scope = common.SCOPE_TIMESEL })
  h.almost(a, 0, 1e-9); h.almost(b, 9, 1e-9)
end)

h.run()
