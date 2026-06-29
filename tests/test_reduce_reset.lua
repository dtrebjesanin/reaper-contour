-- tests/test_reduce_reset.lua — Reduce's "Reset / 0% restores the PRE-REDUCE original" promise, tested
-- against a STATEFUL envelope (writes actually mutate what reads return, so a re-read after a reduce
-- sees the thinned points — that's what exposes the baseline getting re-captured from reduced data).
package.path = package.path .. ";./Contour/?.lua;./?.lua;./tests/?.lua"

local stub   = require("reaper_stub")
stub.install()

-- Stateful track-envelope store layered over the stub (the stub only records writes; here writes mutate
-- the read fixture so round-trips are real). Pan range [-1,1], mode 0.
local envPts = {}
local function inRange(t, a, b) return t >= a - 1e-9 and t <= b + 1e-9 end
reaper.CountEnvelopePoints = function() return #envPts end
reaper.GetEnvelopePoint = function(_e, i)
  local p = envPts[i + 1]; if not p then return false end
  return true, p.time, p.value, p.shape, p.tension or 0, p.sel and true or false
end
reaper.DeleteEnvelopePointRange = function(_e, t0, t1)
  local keep = {}; for _, p in ipairs(envPts) do if not inRange(p.time, t0, t1) then keep[#keep + 1] = p end end
  envPts = keep
end
reaper.InsertEnvelopePoint = function(_e, t, v, sh, ten, sel)
  envPts[#envPts + 1] = { time = t, value = v, shape = sh, tension = ten, sel = sel }; return true
end
reaper.Envelope_SortPoints = function() table.sort(envPts, function(a, b) return a.time < b.time end) end

local h      = require("harness")
local reduce = require("ui.reduce")

-- ONE detected/env reused across calls (a fresh {} each call would change the baseline key).
local ENV = {}
local function det() return { target = "envelope", label = "Pan", hasTimeSel = true, t0 = 0, t1 = 4, details = { env = ENV } } end

local function seed(n, sel)
  envPts = {}
  for i = 0, n - 1 do
    envPts[#envPts + 1] = { time = (i / (n - 1)) * 4, value = math.sin(i / (n - 1) * 6.283) * 0.9,
                            shape = 0, tension = 0, sel = sel and true or false }
  end
end

-- 0% with no prior reduce is a no-op baseline (sanity that the harness round-trips).
h.test("baseline: simple in-session Reset restores the original (Time selection scope)", function()
  reduce.cleanup(); seed(20, false)
  local g = { amount = 80, scope = 0, curveFit = false }
  reduce.run({}, det(), g)
  h.truthy(#envPts < 20, "reduce should have thinned (got " .. #envPts .. ")")
  g.amount = 0
  reduce.run({}, det(), g)               -- Reset
  h.eq(#envPts, 20, "Reset must restore all 20 original points")
end)

h.test("Reset restores the original after SEVERAL successive reduces (no compounding)", function()
  reduce.cleanup(); seed(20, false)
  local g = { scope = 0, curveFit = false }
  for _, amt in ipairs({ 40, 70, 90 }) do g.amount = amt; reduce.run({}, det(), g) end
  h.truthy(#envPts < 20, "reduced to " .. #envPts)
  g.amount = 0; reduce.run({}, det(), g)   -- Reset
  h.eq(#envPts, 20, "Reset after multiple reduces must restore all 20 original points")
end)

h.test("REGRESSION: Reset after an op-switch (cleanup) still restores the original", function()
  reduce.cleanup(); seed(20, false)
  local g = { amount = 80, scope = 0, curveFit = false }
  reduce.run({}, det(), g)
  h.truthy(#envPts < 20, "reduce thinned to " .. #envPts)
  reduce.cleanup()                       -- user toggled to Generate and back (no external edit)
  g.amount = 0
  reduce.run({}, det(), g)               -- Reset
  h.eq(#envPts, 20, "Reset after op-switch must still restore the 20 original points, not the thinned set")
end)

h.test("REGRESSION: Reset in Selected-points scope restores the original", function()
  reduce.cleanup(); seed(20, true)       -- all points selected
  local g = { amount = 80, scope = 2, curveFit = false }   -- 2 = SCOPE_SELECTED
  reduce.run({}, det(), g)
  h.truthy(#envPts < 20, "selected reduce thinned to " .. #envPts)
  g.amount = 0
  reduce.run({}, det(), g)               -- Reset
  h.eq(#envPts, 20, "Reset in selected scope must restore the 20 original points")
end)

-- The legitimate re-baseline: if the lane is edited EXTERNALLY (e.g. Generate writes a new shape) the
-- baseline SHOULD move to that new content, so a later Reset restores the new shape, not the stale one.
h.test("external edit between reduces re-baselines (Reset restores the NEW content)", function()
  reduce.cleanup(); seed(20, false)
  local g = { amount = 80, scope = 0, curveFit = false }
  reduce.run({}, det(), g)               -- baseline = 20-pt sine
  -- simulate an external edit: replace the lane with a different 8-point shape
  envPts = {}; for i = 0, 7 do envPts[#envPts + 1] = { time = i / 7 * 4, value = (i % 2) * 0.5, shape = 0, tension = 0 } end
  reduce.cleanup()
  g.amount = 0
  reduce.run({}, det(), g)               -- Reset
  h.eq(#envPts, 8, "after an external edit, Reset restores the new 8-point content (not the old 20)")
end)

h.run()
