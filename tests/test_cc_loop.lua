-- tests/test_cc_loop.lua — loop-extended MIDI items: REAPER's PPQ<->time conversions do NOT wrap
-- loop iterations, so a span over iteration 2+ converted to ticks past the source end and events were
-- written outside the take (inaudible; could push the end marker and shift every repeat). The editable
-- window of a looped item is its FIRST iteration - exactly what the MIDI editor shows; anything
-- written there repeats in every pass. fullSpan and the write paths must clamp to it.
-- Stub geometry: item TITEM at 3..8s; source length in QN with tick 0 at project 0 (QN = sec * 2)
-- and take PLAYRATE 2.0 (source QNs compress by the playrate in project QN), so SRC_LEN_QN = 24
-- puts the first-iteration end at 24/2 = 12 project QN = 6s.
package.path = package.path .. ";./Contour/?.lua;./?.lua;./tests/?.lua"

local stub = require("reaper_stub")
stub.install()

local h = require("harness")
local target = require("core.target")

local function detCC()
  return { target = "cc", label = "CC1", hasTimeSel = true, t0 = 0, t1 = 4,
           details = { take = "TAKE", midiEditor = "ME" } }
end

h.test("looped item: fullSpan ends at the first iteration, not the loop-extended item end", function()
  stub.reset()
  stub.LOOP_SRC, stub.SRC_LEN_QN = 1, 24
  local t0, t1 = target.fromContext(detCC()):fullSpan()
  h.almost(t0, 3, 1e-9, "item start")
  h.almost(t1, 6, 1e-9, "source end (6s), not item end (8s)")
end)

h.test("non-looped item keeps the full item span (regression)", function()
  stub.reset()                       -- LOOP_SRC defaults to 0
  local t0, t1 = target.fromContext(detCC()):fullSpan()
  h.almost(t0, 3, 1e-9); h.almost(t1, 8, 1e-9)
end)

h.test("write over the loop boundary clamps its ticks to the first iteration", function()
  stub.reset()
  stub.LOOP_SRC, stub.SRC_LEN_QN = 1, 24
  local tgt = target.fromContext(detCC())
  local n, err = tgt:write({ { time = 5.5, value = 40 }, { time = 7.0, value = 90 } }, 5.0, 7.0)
  h.truthy(n and n > 0, "write ok: " .. tostring(err))
  local maxTick = 0
  for _, e in ipairs(stub.ccList) do if e.ppq > maxTick then maxTick = e.ppq end end
  h.truthy(maxTick <= 600, "no event past the source end tick (600), got " .. tostring(maxTick))
end)

h.test("SWS path: BR_GetMidiSourceLenPPQ (ticks) wins over the QN estimate", function()
  stub.reset()
  stub.LOOP_SRC, stub.SRC_LEN_QN = 1, 9999          -- QN estimate would say no clamp...
  reaper.BR_GetMidiSourceLenPPQ = function() return 600 end   -- ...but SWS knows: 600 ticks = 6s
  local t0, t1 = target.fromContext(detCC()):fullSpan()
  reaper.BR_GetMidiSourceLenPPQ = nil
  h.almost(t0, 3, 1e-9); h.almost(t1, 6, 1e-9, "tick-exact source end from SWS")
end)

h.test("write entirely past the loop boundary refuses with guidance", function()
  stub.reset()
  stub.LOOP_SRC, stub.SRC_LEN_QN = 1, 24
  local tgt = target.fromContext(detCC())
  local n, err = tgt:write({ { time = 7.0, value = 90 } }, 6.5, 7.5)
  h.truthy(n == nil, "write must refuse")
  h.truthy(err and err:find("loop") ~= nil, "error explains the loop: " .. tostring(err))
end)

h.run()
