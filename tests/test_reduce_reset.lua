-- tests/test_reduce_reset.lua — Reduce's "Reset / 0% restores the PRE-REDUCE original" promise, tested
-- against a MULTI-LANE STATEFUL envelope (writes mutate what reads return, keyed by the envelope handle,
-- so multiple targets are independent). This exposes the baseline getting re-captured from already-reduced
-- data across op-switch, span/scope changes, multiple lanes, and shape-only external edits.
package.path = package.path .. ";./Contour/?.lua;./?.lua;./tests/?.lua"

local stub = require("reaper_stub")
stub.install()

-- Multi-lane stateful track-envelope store layered over the stub. lanes[envHandle] = { points }.
local lanes = {}
local function pts(e) lanes[e] = lanes[e] or {}; return lanes[e] end
local function inRange(t, a, b) return t >= a - 1e-9 and t <= b + 1e-9 end
reaper.CountEnvelopePoints = function(e) return #pts(e) end
reaper.GetEnvelopePoint = function(e, i)
  local p = pts(e)[i + 1]; if not p then return false end
  return true, p.time, p.value, p.shape, p.tension or 0, p.sel and true or false
end
reaper.DeleteEnvelopePointRange = function(e, t0, t1)
  local keep = {}; for _, p in ipairs(pts(e)) do if not inRange(p.time, t0, t1) then keep[#keep + 1] = p end end
  lanes[e] = keep
end
reaper.InsertEnvelopePoint = function(e, t, v, sh, ten, sel)
  local L = pts(e); L[#L + 1] = { time = t, value = v, shape = sh, tension = ten, sel = sel }; return true
end
reaper.Envelope_SortPoints = function(e) table.sort(pts(e), function(a, b) return a.time < b.time end) end

local h      = require("harness")
local reduce = require("ui.reduce")

local function det(env, t0, t1) return { target = "envelope", label = "Pan", hasTimeSel = true, t0 = t0 or 0, t1 = t1 or 4, details = { env = env } } end

-- seed n points sampling a sine over [a,b] on lane `env` (all selected if `sel`)
local function seed(env, n, a, b, sel)
  lanes[env] = {}
  for i = 0, n - 1 do
    local f = i / (n - 1)
    pts(env)[#pts(env) + 1] = { time = a + f * (b - a), value = math.sin(f * 6.283) * 0.9, shape = 0, tension = 0, sel = sel and true or false }
  end
end
-- A FRESH lane handle per test: the per-target baseline store is module-level and persists across drags
-- (by design — that's the op-switch fix), so each test must isolate on its own lane.
local function freshEnv() return {} end

-- ---- baseline behaviours (these already worked) ----------------------------------------------
h.test("simple in-session Reset restores the original (Time selection scope)", function()
  local E = freshEnv(); reduce.cleanup(); seed(E, 20, 0, 4)
  local g = { amount = 80, scope = 0, curveFit = false }
  reduce.run({}, det(E), g); h.truthy(#pts(E) < 20, "thinned to " .. #pts(E))
  g.amount = 0; reduce.run({}, det(E), g)
  h.eq(#pts(E), 20, "Reset must restore all 20 original points")
end)

h.test("Reset restores the original after SEVERAL successive reduces (no compounding)", function()
  local E = freshEnv(); reduce.cleanup(); seed(E, 20, 0, 4)
  local g = { scope = 0, curveFit = false }
  for _, amt in ipairs({ 40, 70, 90 }) do g.amount = amt; reduce.run({}, det(E), g) end
  g.amount = 0; reduce.run({}, det(E), g)
  h.eq(#pts(E), 20, "Reset after multiple reduces must restore all 20 original points")
end)

h.test("Reset after an op-switch (cleanup) still restores the original", function()
  local E = freshEnv(); reduce.cleanup(); seed(E, 20, 0, 4)
  local g = { amount = 80, scope = 0, curveFit = false }
  reduce.run({}, det(E), g); reduce.cleanup()
  g.amount = 0; reduce.run({}, det(E), g)
  h.eq(#pts(E), 20, "Reset after op-switch must restore the 20 original points")
end)

h.test("Reset in Selected-points scope restores the original", function()
  local E = freshEnv(); reduce.cleanup(); seed(E, 20, 0, 4, true)
  local g = { amount = 80, scope = 2, curveFit = false }
  reduce.run({}, det(E), g); h.truthy(#pts(E) < 20, "thinned to " .. #pts(E))
  g.amount = 0; reduce.run({}, det(E), g)
  h.eq(#pts(E), 20, "Reset in selected scope must restore the 20 original points")
end)

h.test("an external edit between reduces re-baselines (Reset restores the NEW content)", function()
  local E = freshEnv(); reduce.cleanup(); seed(E, 20, 0, 4)
  local g = { amount = 80, scope = 0, curveFit = false }
  reduce.run({}, det(E), g)
  lanes[E] = {}; for i = 0, 7 do pts(E)[#pts(E) + 1] = { time = i / 7 * 4, value = (i % 2) * 0.5, shape = 0, tension = 0 } end
  reduce.cleanup()
  g.amount = 0; reduce.run({}, det(E), g)
  h.eq(#pts(E), 8, "after an external edit, Reset restores the new 8-point content")
end)

-- ---- the gaps the review found ----------------------------------------------------------------
h.test("REGRESSION #1: Reset after the TIME SELECTION changed restores the original", function()
  local E = freshEnv(); reduce.cleanup(); seed(E, 16, 0, 8)   -- points span [0,8]
  local g = { amount = 85, scope = 0, curveFit = false }
  reduce.run({}, det(E, 0, 4), g)                              -- reduce only the [0,4] half
  h.truthy(#pts(E) < 16, "reduced [0,4] -> total " .. #pts(E))
  g.amount = 0; reduce.run({}, det(E, 0, 8), g)                -- selection now [0,8], then Reset
  h.eq(#pts(E), 16, "Reset under a changed time selection must still restore all 16 original points")
end)

h.test("REGRESSION #3: Reset on lane A still restores A after lane B was reduced", function()
  local A, B = freshEnv(), freshEnv(); reduce.cleanup(); seed(A, 20, 0, 4); seed(B, 14, 0, 4)
  local g = { amount = 80, scope = 0, curveFit = false }
  reduce.run({}, det(A), g)                                    -- reduce A
  reduce.run({}, det(B), g)                                    -- reduce B (would clobber a single-slot baseline)
  g.amount = 0; reduce.run({}, det(A), g)                      -- back to A, Reset
  h.eq(#pts(A), 20, "Reset on A must restore A's 20 points even after B was reduced")
end)

h.test("REGRESSION #4: a shape-only external edit re-baselines (Reset does NOT revert it)", function()
  local E = freshEnv(); reduce.cleanup(); seed(E, 20, 0, 4)
  local g = { amount = 80, scope = 0, curveFit = false }
  reduce.run({}, det(E), g)
  for _, p in ipairs(pts(E)) do p.shape = 5 end                -- external edit: change ONLY segment shapes
  reduce.cleanup()
  g.amount = 0; reduce.run({}, det(E), g)                      -- Reset
  local allFive = true; for _, p in ipairs(pts(E)) do if p.shape ~= 5 then allFive = false end end
  h.truthy(allFive, "Reset must NOT revert a shape-only external edit (laneMatchesWritten must see shape)")
end)

h.run()
