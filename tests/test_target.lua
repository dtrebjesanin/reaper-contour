-- tests/test_target.lua — exercises the Reaper-bound target layer (core/target.lua) via a mock
-- `reaper` global. Focus: the AUTOMATION ITEM target added in the AI slice (correct *Ex point
-- functions, ABSOLUTE-PROJECT-TIME domain, span clamped to item bounds, edge insets, CC->ENV shape
-- swap) PLUS a regression guard that the shared envReplace refactor kept TRACK envelopes on the
-- NON-Ex functions. The mock records every point call so we can assert which API family ran.
package.path = package.path .. ";./Contour/?.lua;./?.lua;./tests/?.lua"

-- A recording mock REAPER. Reset rec between tests; install BEFORE requiring core.target so the
-- module's global `reaper` resolves to it at call time.
local rec
local function resetRec()
  rec = { ins = {}, insEx = {}, delRange = {}, delRangeEx = {}, sort = 0, sortEx = 0 }
end
resetRec()

_G.reaper = {
  -- value-range plumbing (envValueRange): a Pan envelope => linear range [-1,1], scaling mode 0.
  GetEnvelopeScalingMode = function() return 0 end,
  GetEnvelopeName        = function() return true, "Pan" end,
  -- automation-item geometry: item at project 10s, length 4s => bounds [10,14].
  GetSetAutomationItemInfo = function(_env, _idx, key)
    if key == "D_POSITION" then return 10.0 end
    if key == "D_LENGTH"   then return 4.0 end
    return 0.0
  end,
  -- point ops — TRACK envelope (non-Ex)
  DeleteEnvelopePointRange = function(_e, t0, t1) rec.delRange[#rec.delRange+1] = { t0, t1 } end,
  InsertEnvelopePoint = function(_e, t, v, shape, tension, selected)
    rec.ins[#rec.ins+1] = { t = t, v = v, shape = shape, tension = tension, sel = selected }; return not rec.failInsert
  end,
  Envelope_SortPoints = function() rec.sort = rec.sort + 1 end,
  -- point ops — AUTOMATION ITEM (Ex)
  DeleteEnvelopePointRangeEx = function(_e, idx, t0, t1) rec.delRangeEx[#rec.delRangeEx+1] = { idx, t0, t1 } end,
  InsertEnvelopePointEx = function(_e, idx, t, v, shape, tension, selected)
    rec.insEx[#rec.insEx+1] = { idx = idx, t = t, v = v, shape = shape, tension = tension, sel = selected }; return not rec.failInsert
  end,
  Envelope_SortPointsEx = function() rec.sortEx = rec.sortEx + 1 end,
  -- undo / repaint — no-ops for the test
  Undo_BeginBlock2 = function() end,
  Undo_EndBlock2   = function() end,
  UpdateArrange    = function() end,
}

-- Read-side fixtures + plumbing (for the :read methods Reduce uses). Tests set these tables, then
-- the mock MIDI/envelope readers iterate them. PPQ maps 1:1 at 100 ppq/sec for easy assertions.
local ccEvents, envPoints, aiPoints = {}, {}, {}
reaper.MIDI_GetPPQPosFromProjTime = function(_t, sec) return sec * 100 end
reaper.MIDI_GetProjTimeFromPPQPos = function(_t, ppq) return ppq / 100 end
reaper.MIDI_CountEvts = function() return true, 0, #ccEvents end
reaper.MIDI_GetCC = function(_t, i)
  local e = ccEvents[i + 1]; if not e then return false end
  return true, e.sel and true or false, false, e.ppq, 0xB0, e.chan or 0, e.lane, e.val
end
reaper.MIDI_GetCCShape = function(_t, i)
  local e = ccEvents[i + 1]; if not e then return false end
  return true, e.shape or 1, e.tension or 0
end
reaper.CountEnvelopePoints = function() return #envPoints end
reaper.GetEnvelopePoint = function(_e, i)
  local p = envPoints[i + 1]; if not p then return false end
  return true, p.time, p.value, p.shape, p.tension or 0, p.sel and true or false
end
reaper.CountEnvelopePointsEx = function() return #aiPoints end
reaper.GetEnvelopePointEx = function(_e, _idx, i)
  local p = aiPoints[i + 1]; if not p then return false end
  return true, p.time, p.value, p.shape, p.tension or 0, p.sel and true or false
end

local h      = require("harness")
local target = require("core.target")

local EPS = 1e-3  -- envReplace inset for a 4s span (min(1e-3, span*1e-3) = 1e-3)

-- ---- AI target -----------------------------------------------------------------------------------
h.test("AI target: kind/lane/channel", function()
  local ai = target.AI.new({}, 0)
  h.eq(ai:kind(), "ai")
  h.eq(ai:lane(), nil)
  h.eq(ai:channel(), 0)
end)

h.test("AI target: bounds/fullSpan from D_POSITION+D_LENGTH", function()
  local ai = target.AI.new({}, 0)
  local lo, hi = ai:bounds()
  h.eq(lo, 10.0); h.eq(hi, 14.0)
  local a, b = ai:fullSpan()
  h.eq(a, 10.0); h.eq(b, 14.0)
end)

h.test("AI target: valueRange delegates to parent envelope (Pan => -1..1)", function()
  local ai = target.AI.new({}, 0)
  local lo, hi = ai:valueRange()
  h.eq(lo, -1); h.eq(hi, 1)
end)

h.test("AI write: uses the *Ex functions, NOT the track-envelope ones", function()
  resetRec()
  local ai = target.AI.new({}, 0)
  local n = ai:write({ { time = 11.0, value = 0.5, shape = 1 } }, 10.0, 14.0, {})
  h.eq(n, 1)
  h.eq(#rec.insEx, 1, "should insert via InsertEnvelopePointEx")
  h.eq(#rec.ins, 0, "must NOT touch the non-Ex InsertEnvelopePoint")
  h.eq(#rec.delRangeEx, 1, "should delete via DeleteEnvelopePointRangeEx")
  h.eq(#rec.delRange, 0, "must NOT touch the non-Ex DeleteEnvelopePointRange")
  h.eq(rec.sortEx, 1); h.eq(rec.sort, 0)
  h.eq(rec.insEx[1].idx, 0, "writes to the right automation-item index")
end)

h.test("AI write: span clamps to item bounds (out-of-item ends pulled in)", function()
  resetRec()
  local ai = target.AI.new({}, 0)
  -- Ask for [8,16] which overruns the [10,14] item on BOTH sides.
  ai:write({ { time = 11.0, value = 0.0, shape = 1 } }, 8.0, 16.0, {})
  h.eq(#rec.delRangeEx, 1)
  h.eq(rec.delRangeEx[1][2], 10.0, "delete-range start clamped to item start")
  h.eq(rec.delRangeEx[1][3], 14.0, "delete-range end clamped to item end")
end)

h.test("AI write: point times are PROJECT seconds, edges inset off both boundaries", function()
  resetRec()
  local ai = target.AI.new({}, 0)
  -- Points exactly on both item boundaries + one interior. Times are absolute project seconds.
  ai:write({
    { time = 10.0, value = 0.0,  shape = 1 },  -- left edge
    { time = 12.0, value = 0.5,  shape = 1 },  -- interior
    { time = 14.0, value = -0.5, shape = 1 },  -- right edge
  }, 10.0, 14.0, {})
  h.eq(#rec.insEx, 3)
  -- left-edge point nudged INWARD (REAPER drops a point on the AI's left boundary)
  h.truthy(rec.insEx[1].t > 10.0, "left edge inset above item start")
  h.almost(rec.insEx[1].t, 10.0 + EPS, 1e-9)
  h.eq(rec.insEx[2].t, 12.0, "interior point kept at its project time")
  -- right-edge point nudged inward (DeleteEnvelopePointRange* won't clear a point exactly at t1)
  h.truthy(rec.insEx[3].t < 14.0, "right edge inset below item end")
  h.almost(rec.insEx[3].t, 14.0 - EPS, 1e-9)
end)

h.test("AI write: CC shape ints swap to ENVELOPE convention (0<->1; >=2 unchanged)", function()
  resetRec()
  local ai = target.AI.new({}, 0)
  ai:write({
    { time = 11.0, value = 0.0, shape = 0 },  -- CC square(0)  -> ENV 1
    { time = 12.0, value = 0.0, shape = 1 },  -- CC linear(1)  -> ENV 0
    { time = 13.0, value = 0.0, shape = 2 },  -- CC slow(2)    -> ENV 2 (identical)
  }, 10.0, 14.0, {})
  h.eq(rec.insEx[1].shape, 1)
  h.eq(rec.insEx[2].shape, 0)
  h.eq(rec.insEx[3].shape, 2)
end)

h.test("AI write: values clamp to the parent envelope range (Pan -1..1)", function()
  resetRec()
  local ai = target.AI.new({}, 0)
  ai:write({
    { time = 11.0, value =  5.0, shape = 1 },  -- over max
    { time = 12.0, value = -5.0, shape = 1 },  -- under min
  }, 10.0, 14.0, {})
  h.eq(rec.insEx[1].v, 1)
  h.eq(rec.insEx[2].v, -1)
end)

-- ---- Regression: TRACK envelope still uses the NON-Ex functions after the envReplace refactor ----
h.test("ENV write: still uses the non-Ex point functions (refactor guard)", function()
  resetRec()
  -- ENV isn't exported; route through fromContext (no take => track envelope, the non-Ex path).
  local tgt, err = target.fromContext({ target = "envelope", details = { env = {} } })
  h.truthy(tgt, "fromContext should build an envelope target: " .. tostring(err))
  tgt:write({ { time = 1.0, value = 0.0, shape = 1 } }, 0.0, 2.0, {})
  h.eq(#rec.ins, 1, "track envelope uses InsertEnvelopePoint")
  h.eq(#rec.insEx, 0, "track envelope must NOT use the Ex variant")
  h.eq(rec.sort, 1); h.eq(rec.sortEx, 0)
end)

-- ---- Factory routing ------------------------------------------------------------------------------
h.test("fromContext: 'ai' builds an AI target", function()
  local tgt, err = target.fromContext({ target = "ai", details = { env = {}, aiIndex = 2 } })
  h.truthy(tgt, "expected an AI target, got error: " .. tostring(err))
  h.eq(tgt:kind(), "ai")
end)

h.test("fromContext: 'ai' without an item index errors (no silent nil)", function()
  local tgt, err = target.fromContext({ target = "ai", details = { env = {} } })
  h.eq(tgt, nil)
  h.truthy(err and #err > 0, "should report a message")
end)

h.test("fromContext: 'ai' is no longer the 'coming next' stub", function()
  local _, err = target.fromContext({ target = "ai", details = { env = {}, aiIndex = 0 } })
  h.eq(err, nil, "ai should succeed now (no deferral message)")
end)

-- ---- read methods (Reduce reads existing points to thin them) ------------------------------------
h.test("CC:read returns in-range lane CCs, time-ascending, with shapes", function()
  ccEvents = {
    { ppq = 300, lane = 11, val = 90, shape = 2 },  -- out of order on purpose; t=3.0
    { ppq = 100, lane = 11, val = 64, shape = 1 },  -- t=1.0
    { ppq = 150, lane = 99, val = 10, shape = 1 },  -- wrong lane -> excluded
    { ppq = 250, lane = 11, val = 20, shape = 0 },  -- t=2.5
    { ppq = 900, lane = 11, val = 5,  shape = 1 },  -- t=9.0 -> out of [1,4] range
  }
  local cc = target.CC.new({}, nil, 11, 0)
  local pts = cc:read(1.0, 4.0)
  h.eq(#pts, 3, "three lane-11 CCs inside [1,4]")
  h.eq(pts[1].time, 1.0); h.eq(pts[1].value, 64); h.eq(pts[1].shape, 1)
  h.eq(pts[2].time, 2.5); h.eq(pts[2].value, 20); h.eq(pts[2].shape, 0)
  h.eq(pts[3].time, 3.0); h.eq(pts[3].value, 90); h.eq(pts[3].shape, 2)
end)

h.test("ENV:read returns only points within [t0,t1]", function()
  envPoints = {
    { time = 0.5, value = 0.0, shape = 0 },   -- before range
    { time = 1.0, value = 0.5, shape = 0 },
    { time = 2.0, value = -0.5, shape = 2 },
    { time = 5.0, value = 0.0, shape = 0 },   -- after range
  }
  local tgt = target.fromContext({ target = "envelope", details = { env = {} } })
  local pts = tgt:read(1.0, 3.0)
  h.eq(#pts, 2)
  h.eq(pts[1].time, 1.0); h.eq(pts[2].time, 2.0); h.eq(pts[2].shape, 2)
end)

h.test("AI:read clamps the range to the item bounds [10,14]", function()
  aiPoints = {
    { time = 9.0,  value = 0.0, shape = 0 },   -- before item start -> excluded by bounds clamp
    { time = 11.0, value = 0.3, shape = 0 },
    { time = 13.0, value = -0.3, shape = 0 },
    { time = 20.0, value = 0.0, shape = 0 },   -- after item end
  }
  local ai = target.AI.new({}, 0)
  local pts = ai:read(0.0, 100.0)   -- asks wide; AI:read clamps to [10,14]
  h.eq(#pts, 2)
  h.eq(pts[1].time, 11.0); h.eq(pts[2].time, 13.0)
end)

-- ---- rawShape: Reduce writes back already-native envelope shapes (no CC<->ENV swap) --------------
h.test("ENV write rawShape=true preserves native shapes (no 0<->1 swap)", function()
  resetRec()
  local tgt = target.fromContext({ target = "envelope", details = { env = {} } })
  tgt:write({
    { time = 1.0, value = 0.0, shape = 0 },   -- ENV linear stays 0
    { time = 1.5, value = 0.0, shape = 1 },   -- ENV square stays 1
    { time = 2.0, value = 0.0, shape = 2 },   -- slow start/end stays 2
  }, 0.0, 3.0, { rawShape = true })
  h.eq(rec.ins[1].shape, 0)
  h.eq(rec.ins[2].shape, 1)
  h.eq(rec.ins[3].shape, 2)
end)

h.test("AI write rawShape=true preserves native shapes (no swap)", function()
  resetRec()
  local ai = target.AI.new({}, 0)
  ai:write({
    { time = 11.0, value = 0.0, shape = 0 },
    { time = 12.0, value = 0.0, shape = 1 },
  }, 10.0, 14.0, { rawShape = true })
  h.eq(rec.insEx[1].shape, 0)
  h.eq(rec.insEx[2].shape, 1)
end)

-- ---- read fidelity: selection flag + CC bezier tension ------------------------------------------
h.test("CC:read captures bezier tension and selection flag", function()
  ccEvents = {
    { ppq = 100, lane = 11, val = 64, shape = 5, tension = 0.7, sel = true },
    { ppq = 200, lane = 11, val = 20, shape = 1, tension = 0.0, sel = false },
  }
  local cc = target.CC.new({}, nil, 11, 0)
  local pts = cc:read(0.5, 3.0)
  h.eq(#pts, 2)
  h.eq(pts[1].shape, 5); h.almost(pts[1].tension, 0.7, 1e-9); h.eq(pts[1].sel, true)
  h.eq(pts[2].sel, false)
end)

h.test("ENV:read reports selection and reads ALL points with nil bounds", function()
  envPoints = {
    { time = 0.5, value = 0.0, shape = 0, sel = false },
    { time = 1.0, value = 0.5, shape = 0, sel = true },
    { time = 5.0, value = 0.0, shape = 0, sel = true },
  }
  local tgt = target.fromContext({ target = "envelope", details = { env = {} } })
  local all = tgt:read(nil, nil)   -- unbounded -> every point
  h.eq(#all, 3)
  h.eq(all[2].sel, true); h.eq(all[1].sel, false)
end)

h.test("AI:read reports selection and reads ALL item points with nil bounds", function()
  aiPoints = {
    { time = 11.0, value = 0.3, shape = 0, sel = true },
    { time = 13.0, value = -0.3, shape = 0, sel = false },
  }
  local ai = target.AI.new({}, 0)
  local all = ai:read(nil, nil)
  h.eq(#all, 2)
  h.eq(all[1].sel, true); h.eq(all[2].sel, false)
end)

-- ---- rawShape boundary: a point exactly at t1 round-trips without duplication (Reduce 0% restore) -
h.test("ENV rawShape write: delete widens past t1 and a point at t1 stays at exact t1", function()
  resetRec()
  local tgt = target.fromContext({ target = "envelope", details = { env = {} } })
  tgt:write({
    { time = 1.0, value = 0.0, shape = 0 },
    { time = 3.0, value = 0.0, shape = 0 },   -- exactly at t1
  }, 0.0, 3.0, { rawShape = true })
  -- delete range widened just past t1 so REAPER's "won't delete a point at t1" survivor is cleared
  h.truthy(rec.delRange[1][2] > 3.0, "delete upper bound widened past t1")
  h.almost(rec.delRange[1][2], 3.0, 1e-6)
  -- the t1 point is re-inserted at EXACTLY t1 (no inset on the envelope reduce path)
  h.eq(rec.ins[2].t, 3.0)
end)

h.test("Generate (non-rawShape) envelope write keeps the eps inset (a point at t1 moves inside)", function()
  resetRec()
  local tgt = target.fromContext({ target = "envelope", details = { env = {} } })
  tgt:write({ { time = 3.0, value = 0.0, shape = 1 } }, 0.0, 3.0, {})  -- no rawShape => Generate path
  h.truthy(rec.ins[1].t < 3.0, "generate insets the trailing point off t1")
  h.eq(rec.delRange[1][2], 3.0, "generate does NOT widen the delete")
end)

-- ---- selection preserved through the write (Reduce keeps kept points selected) -----------------
h.test("ENV write preserves each point's selected flag", function()
  resetRec()
  local tgt = target.fromContext({ target = "envelope", details = { env = {} } })
  tgt:write({
    { time = 1.0, value = 0.0, shape = 0, sel = true },
    { time = 2.0, value = 0.0, shape = 0, sel = false },
  }, 0.0, 3.0, { rawShape = true })
  h.eq(rec.ins[1].sel, true)
  h.eq(rec.ins[2].sel, false)
end)

h.test("Generate envelope write inserts points unselected (no sel field)", function()
  resetRec()
  local tgt = target.fromContext({ target = "envelope", details = { env = {} } })
  tgt:write({ { time = 1.0, value = 0.0, shape = 1 } }, 0.0, 3.0, {})
  h.eq(rec.ins[1].sel, false)
end)

-- ---- silent-destructive guard: delete happened but no insert succeeded -> failure, not false success
h.test("ENV write reports failure (not success) when every insert fails after the delete", function()
  resetRec()
  rec.failInsert = true
  local tgt = target.fromContext({ target = "envelope", details = { env = {} } })
  local n, err = tgt:write({ { time = 1.0, value = 0.0, shape = 1 } }, 0.0, 3.0, {})
  rec.failInsert = false
  h.eq(n, nil, "must not report a wiped range as success")
  h.truthy(err and #err > 0, "should surface an error message")
end)

h.run()
