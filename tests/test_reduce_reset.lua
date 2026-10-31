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

-- Selected scope must behave like Time-selection: changing the method/amount re-reduces the ORIGINAL
-- selection (it must not bring the thinned-away points back), and Reset restores + re-selects the original.
h.test("Selected scope: toggling Curve fit at a level re-reduces (does NOT bring points back)", function()
  local E = freshEnv(); reduce.cleanup(); seed(E, 20, 0, 4, true)
  local g = { amount = 50, scope = 2, curveFit = false }
  reduce.run({}, det(E), g); h.truthy(#pts(E) < 20, "RDP reduced to " .. #pts(E))
  g.curveFit = true; reduce.run({}, det(E), g)
  h.truthy(#pts(E) < 20, "toggling curve fit must re-reduce, not restore all 20 (got " .. #pts(E) .. ")")
end)

h.test("Selected scope: Reset restores ALL points + re-selects them (so a follow-up reduce still thins)", function()
  -- a lone interior spike: RDP keeps {start, spike, end}; the survivors do NOT cover the selection,
  -- which is exactly what exposed the selection-collapse bug.
  local E = freshEnv(); reduce.cleanup(); lanes[E] = {}
  for i = 0, 14 do pts(E)[#pts(E) + 1] = { time = i / 14 * 4, value = (i == 7) and 0.9 or 0.0, shape = 0, tension = 0, sel = true } end
  local g = { amount = 70, scope = 2, curveFit = false }
  reduce.run({}, det(E), g); h.truthy(#pts(E) < 15, "reduced to " .. #pts(E))
  g.amount = 0; reduce.run({}, det(E), g)
  h.eq(#pts(E), 15, "Reset must restore all 15 original points")
  local selN = 0; for _, p in ipairs(pts(E)) do if p.sel then selN = selN + 1 end end
  h.eq(selN, 15, "Reset must re-select the original selection (not just the survivors)")
  g.amount = 70; reduce.run({}, det(E), g)
  h.truthy(#pts(E) < 15, "a follow-up reduce after Reset must thin again (selection not collapsed), got " .. #pts(E))
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

h.test("REGRESSION: Time->Selected scope switch keeps the original (Reset restores it)", function()
  local E = freshEnv(); reduce.cleanup(); seed(E, 20, 0, 4, false)   -- reduced first in Time-selection scope
  local g = { amount = 80, scope = 0, curveFit = false }
  reduce.run({}, det(E), g); h.truthy(#pts(E) < 20, "time-sel reduced to " .. #pts(E))
  for _, p in ipairs(pts(E)) do p.sel = true end                     -- user switches to Selected scope + selects
  reduce.run({}, det(E), { amount = 0, scope = 2, curveFit = false })  -- Reset in Selected scope
  h.eq(#pts(E), 20, "a Time->Selected scope switch must not discard the original (Reset restores 20)")
end)

h.test("REGRESSION: a continuously-reused baseline survives the LRU cap (bump on reuse)", function()
  local A = freshEnv(); reduce.cleanup(); seed(A, 20, 0, 4)
  local g = { amount = 80, scope = 0, curveFit = false }
  reduce.run({}, det(A), g)
  for _ = 1, 80 do                                  -- touch 80 other lanes (> the 64 cap)...
    local L = freshEnv(); seed(L, 6, 0, 4); reduce.run({}, det(L), g)
    reduce.run({}, det(A), g)                       -- ...re-reducing A each time, which must bump its LRU slot
  end
  reduce.run({}, det(A), { amount = 0, scope = 0, curveFit = false })  -- Reset A
  h.eq(#pts(A), 20, "a reused baseline must not be evicted by the cap (Reset still restores 20)")
end)

-- ---- razor areas: Reduce works on SEVERAL spans at once -------------------------------------------------
-- A razor area on the target lane is the range, and a lane can carry several separate areas. Each area is
-- thinned on its own, the gap between them is never touched, and the whole write is ONE Undo step.
-- Descriptors built without the razor fields (every test above) must behave exactly as they always did.
local HINT_RANGE      = "Make a time selection or a razor area (or switch Scope to Entire item)."
local HINT_OUTSIDE_AI = "The razor area is outside this automation item"
local HINT_OUTSIDE_IT = "The razor area is outside this item"

-- A razor descriptor: the fields core/context.detect adds. det() still carries a time selection over the
-- whole lane (0..6), which a razor area must beat.
local function razorDet(env, ranges)
  local d = det(env, 0, 6)
  d.rangeSource, d.ranges, d.hasRange, d.razorOutside = "razor", ranges, #ranges > 0, false
  return d
end

-- A dense zigzag of small amplitude on a gentle ramp, one point every 0.25 s over [a,b]: it thins hard at
-- Reduce 80 %, so any span that is wrongly touched (or skipped) shows in the point counts.
local function zigzag(env, a, b)
  lanes[env] = {}
  local n = math.floor((b - a) / 0.25 + 0.5)
  for i = 0, n do
    local t = a + i * 0.25
    pts(env)[#pts(env) + 1] = { time = t, value = -0.4 + 0.8 * (t - a) / (b - a) + ((i % 2 == 0) and 0.05 or -0.05),
                                shape = 0, tension = 0, sel = false }
  end
end
local function copyPts(env)
  local out = {}
  for i, p in ipairs(pts(env)) do out[i] = { time = p.time, value = p.value, shape = p.shape, tension = p.tension, sel = p.sel } end
  return out
end
local function between(list, a, b, open)       -- points of `list` in [a,b], or in (a,b) when `open`
  local out = {}
  for _, p in ipairs(list) do
    local inside = open and (p.time > a + 1e-9 and p.time < b - 1e-9) or (not open and p.time >= a - 1e-9 and p.time <= b + 1e-9)
    if inside then out[#out + 1] = p end
  end
  return out
end
local function sameList(x, y)
  if #x ~= #y then return false, "count " .. #x .. " vs " .. #y end
  for i = 1, #x do
    if math.abs(x[i].time - y[i].time) > 1e-9 or math.abs(x[i].value - y[i].value) > 1e-9
       or (x[i].shape or 0) ~= (y[i].shape or 0) then
      return false, "point " .. i .. " differs"
    end
  end
  return true
end
-- Run fn with reaper.* fields temporarily replaced; always restored.
local function with(overrides, fn)
  local saved = {}
  for k, v in pairs(overrides) do saved[k] = rawget(reaper, k); rawset(reaper, k, v) end
  local ok, err = pcall(fn)
  for k in pairs(overrides) do rawset(reaper, k, saved[k]) end
  if not ok then error(err, 0) end
end

h.test("Reduce thins each razor area and leaves the gap untouched", function()
  local E = freshEnv(); reduce.cleanup(); zigzag(E, 0, 6)
  local before = copyPts(E)
  local g = { amount = 80, scope = 0, curveFit = false }
  local blocks0 = stub.rec.undoBlocks
  reduce.run({}, razorDet(E, { { 0, 2 }, { 4, 6 } }), g)
  h.truthy(not g.statusErr, "reduce errored: " .. tostring(g.status))
  local after = copyPts(E)
  h.truthy(#between(after, 0, 2) < #between(before, 0, 2),
    "area [0,2] must thin: " .. #between(before, 0, 2) .. " -> " .. #between(after, 0, 2))
  h.truthy(#between(after, 4, 6) < #between(before, 4, 6),
    "area [4,6] must thin: " .. #between(before, 4, 6) .. " -> " .. #between(after, 4, 6))
  local same, why = sameList(between(after, 2, 4, true), between(before, 2, 4, true))
  h.truthy(same, "the gap (2,4) must be untouched: " .. tostring(why))
  h.eq(stub.rec.undoBlocks - blocks0, 1, "two areas, ONE Undo step")
  local o = #between(before, 0, 2) + #between(before, 4, 6)     -- the points the two areas held
  local r = #between(after, 0, 2) + #between(after, 4, 6)       -- and what they hold now
  h.eq(g.status, ("Reduced %d -> %d points"):format(o, r), "status reports the totals over both areas")
end)

h.test("Reset after a two-area reduce restores both areas", function()
  local E = freshEnv(); reduce.cleanup(); zigzag(E, 0, 6)
  local before = copyPts(E)
  local d = razorDet(E, { { 0, 2 }, { 4, 6 } })
  local g = { amount = 80, scope = 0, curveFit = false }
  reduce.run({}, d, g); h.truthy(#pts(E) < #before, "thinned to " .. #pts(E))
  g.amount = 0; reduce.run({}, d, g)
  local same, why = sameList(copyPts(E), before)
  h.truthy(same, "Reset must restore the original in both areas: " .. tostring(why))
end)

h.test("a razor area is a range even without a time selection", function()
  local E = freshEnv(); reduce.cleanup(); zigzag(E, 0, 6)
  local n0 = #pts(E)
  local d = razorDet(E, { { 4, 6 } }); d.hasTimeSel = false
  local g = { amount = 80, scope = 0, curveFit = false }
  reduce.run({}, d, g)
  h.truthy(not g.statusErr, "reduce errored: " .. tostring(g.status))
  h.truthy(#pts(E) < n0, "the razor area was thinned")
end)

h.test("the baseline survives a change of razor areas, and Reset restores every area", function()
  local E = freshEnv(); reduce.cleanup(); zigzag(E, 0, 6)
  local before = copyPts(E)
  local g = { amount = 80, scope = 0, curveFit = false }
  reduce.run({}, razorDet(E, { { 0, 2 } }), g)                       -- reduce area A only
  local afterA = copyPts(E)
  reduce.run({}, razorDet(E, { { 0, 2 }, { 4, 6 } }), g)             -- now A and B: A re-derives, B thins
  h.truthy(#between(copyPts(E), 4, 6) < #between(before, 4, 6), "B thinned")
  h.truthy(sameList(between(copyPts(E), 0, 2), between(afterA, 0, 2)), "A re-derived from the SAME original, not thinned again")
  g.amount = 0; reduce.run({}, razorDet(E, { { 0, 2 }, { 4, 6 } }), g)
  local same, why = sameList(copyPts(E), before)
  h.truthy(same, "Reset restores both areas: " .. tostring(why))
end)

h.test("an external edit inside ONE area re-baselines (the original is kept only if EVERY area matches)", function()
  local E = freshEnv(); reduce.cleanup(); zigzag(E, 0, 6)
  local d = razorDet(E, { { 0, 2 }, { 4, 6 } })
  local g = { amount = 80, scope = 0, curveFit = false }
  reduce.run({}, d, g)
  local p = pts(E)[#pts(E) - 1]; p.value = p.value + 0.123           -- edit a survivor in area B only
  local edited = copyPts(E)
  reduce.cleanup()
  g.amount = 0; reduce.run({}, d, g)
  local same, why = sameList(copyPts(E), edited)
  h.truthy(same, "Reset must NOT revert an edit made inside the second area: " .. tostring(why))
end)

h.test("an area with no points is skipped, the other area still thins in one Undo step", function()
  local E = freshEnv(); reduce.cleanup(); zigzag(E, 0, 6)
  local n0 = #pts(E)
  local g = { amount = 80, scope = 0, curveFit = false }
  local blocks0 = stub.rec.undoBlocks
  reduce.run({}, razorDet(E, { { 0, 2 }, { 10, 12 } }), g)           -- [10,12] holds no points
  h.truthy(not g.statusErr, "reduce errored: " .. tostring(g.status))
  h.truthy(#pts(E) < n0, "area [0,2] thinned")
  h.eq(stub.rec.undoBlocks - blocks0, 1, "one Undo step")
end)

h.test("a single time-selection span keeps the write layer's own single Undo step", function()
  local E = freshEnv(); reduce.cleanup(); seed(E, 20, 0, 4)
  local blocks0 = stub.rec.undoBlocks
  reduce.run({}, det(E), { amount = 80, scope = 0, curveFit = false })
  h.eq(stub.rec.undoBlocks - blocks0, 1, "one Undo step for one span")
end)

h.test("a razor area outside the item writes nothing and says so (it never falls back to the time selection)", function()
  for _, c in ipairs({
    { d = { target = "ai", label = "AI", hasTimeSel = true, t0 = 0, t1 = 6, details = { env = freshEnv(), aiIndex = 0 } }, hint = HINT_OUTSIDE_AI },
    { d = { target = "envelope", label = "Pan", hasTimeSel = true, t0 = 0, t1 = 6, details = { env = freshEnv(), take = "TAKE" } }, hint = HINT_OUTSIDE_IT },
  }) do
    reduce.cleanup(); zigzag(c.d.details.env, 0, 6)
    local before = copyPts(c.d.details.env)
    c.d.rangeSource, c.d.ranges, c.d.hasRange, c.d.razorOutside = "razor", {}, false, true
    local g = { amount = 80, scope = 0, curveFit = false }
    local blocks0 = stub.rec.undoBlocks
    reduce.run({}, c.d, g)
    h.truthy(g.statusErr, "must fail: " .. tostring(g.status))
    h.eq(g.status, c.hint, "the outside text for " .. c.d.target)
    h.eq(stub.rec.undoBlocks - blocks0, 0, "no Undo step")
    h.truthy(sameList(copyPts(c.d.details.env), before), "the lane is untouched")
  end
end)

h.test("an automation item takes several razor areas too: one delete and rewrite per area, ONE Undo step", function()
  reduce.cleanup()
  stub.aiPoints = {}                               -- the same zigzag over [0,6], read through the *Ex calls
  for i = 0, 24 do
    local t = i * 0.25
    stub.aiPoints[#stub.aiPoints + 1] = { time = t, value = -0.4 + 0.8 * t / 6 + ((i % 2 == 0) and 0.05 or -0.05),
                                          shape = 0, tension = 0, sel = false }
  end
  local d = { target = "ai", label = "AI", hasTimeSel = true, t0 = 0, t1 = 6, details = { env = {}, aiIndex = 0 },
              rangeSource = "razor", ranges = { { 0, 2 }, { 4, 6 } }, hasRange = true, razorOutside = false }
  local blocks0, del0, ins0 = stub.rec.undoBlocks, #stub.rec.delRangeEx, #stub.rec.insEx
  local g = { amount = 80, scope = 0, curveFit = false }
  reduce.run({}, d, g)
  h.truthy(not g.statusErr, "reduce errored: " .. tostring(g.status))
  h.eq(#stub.rec.delRangeEx - del0, 2, "one range delete per area")
  h.eq(stub.rec.undoBlocks - blocks0, 1, "one Undo step")
  h.truthy(#stub.rec.insEx - ins0 < 18, "both areas thinned (18 points before), wrote " .. (#stub.rec.insEx - ins0))
  for i = ins0 + 1, #stub.rec.insEx do
    local t = stub.rec.insEx[i].t
    h.truthy((t >= 0 and t <= 2 + 1e-6) or (t >= 4 - 1e-6 and t <= 6 + 1e-6), "a point written in the gap: " .. t)
  end
end)

-- ---- hints (the panel text) -------------------------------------------------------------------------
local function hintsOf(state, d)
  local seen = {}
  with({ ImGui_TextColored = function(_c, _col, s) seen[#seen + 1] = s end }, function() reduce.draw("CTX", state, d) end)
  return table.concat(seen, "|")
end

h.test("hints: the range text, and the two outside texts", function()
  local function ai(extra)
    local d = { target = "ai", label = "AI", hasTimeSel = false, t0 = 0, t1 = 0, details = { env = freshEnv(), aiIndex = 0 } }
    for k, v in pairs(extra or {}) do d[k] = v end
    return d
  end
  local st = { op = "reduce" }
  -- no range at all (older descriptor, no razor fields)
  h.truthy(hintsOf(st, ai()):find(HINT_RANGE, 1, true), "no time selection and no razor -> the range text")
  h.truthy(not hintsOf(st, ai()):find("Make a time selection (or", 1, true), "the old single-source text is gone")
  -- a razor area is a range: no range hint, even without a time selection
  local razor = ai({ rangeSource = "razor", ranges = { { 1, 2 } }, hasRange = true, razorOutside = false })
  h.truthy(not hintsOf(st, razor):find("Make a time selection", 1, true), "a razor area satisfies the range")
  -- razor outside: the automation-item text and the item text, never the range text
  local out = ai({ rangeSource = "razor", ranges = {}, hasRange = false, razorOutside = true, hasTimeSel = true, t1 = 4 })
  local text = hintsOf(st, out)
  h.truthy(text:find(HINT_OUTSIDE_AI, 1, true), "automation item: " .. text)
  h.truthy(not text:find("Make a time selection", 1, true), "never the range text when the razor is outside")
  local take = ai({ target = "envelope", rangeSource = "razor", ranges = {}, hasRange = false, razorOutside = true })
  take.details.take = "TAKE"
  h.truthy(hintsOf(st, take):find(HINT_OUTSIDE_IT, 1, true), "take envelope: the item text")
  -- Entire item ignores razor areas, so "outside" is not shown there and the Reduce is ready
  st.red.scope = 1
  h.truthy(not hintsOf(st, take):find(HINT_OUTSIDE_IT, 1, true), "Entire item: the razor area does not matter")
end)

-- ---- the live gesture: ONE Undo block for the drag, closed when the lane (target) changes -----------------
h.test("live drag over two areas is ONE Undo block; a change of target ends it before the baseline is re-read", function()
  reduce.cleanup()
  local E1, E2 = freshEnv(), freshEnv()
  zigzag(E1, 0, 6); zigzag(E2, 0, 6)
  local before1, before2 = copyPts(E1), copyPts(E2)
  local st = { op = "reduce" }
  reduce.draw("CTX", st, razorDet(E1, { { 0, 2 }, { 4, 6 } }))   -- creates state.red
  st.red.live, st.red.scope, st.red.curveFit = true, 0, false
  local ends, dragging, edited = {}, true, true
  local function frame(d)
    with({
      ImGui_SliderInt = function(_c, label, v) if edited and label:find("red_amt", 1, true) then return true, 80 end return false, v end,
      ImGui_IsAnyItemActive = function() return dragging end,
      Undo_EndBlock2 = function(_p, label, flag) ends[#ends + 1] = { label = label, flag = flag } end,
    }, function() reduce.draw("CTX", st, d) end)
  end
  local blocks0 = stub.rec.undoBlocks
  frame(razorDet(E1, { { 0, 2 }, { 4, 6 } }))
  h.eq(stub.rec.undoBlocks - blocks0, 1, "first drag frame opens ONE block, both areas written inside it")
  h.eq(#ends, 0, "the block stays open while the drag goes on")
  h.truthy(#between(pts(E1), 0, 2) < #between(before1, 0, 2) and #between(pts(E1), 4, 6) < #between(before1, 4, 6),
    "both areas thinned live")
  edited = false; frame(razorDet(E1, { { 0, 2 }, { 4, 6 } }))      -- the drag goes on, nothing new
  h.eq(#ends, 0, "still open")
  -- REAPER selects another envelope mid-drag: the open gesture belongs to E1 and must end before E2's
  -- baseline is read; E2 then gets its own block.
  edited = true; frame(razorDet(E2, { { 0, 2 }, { 4, 6 } }))
  h.eq(#ends, 1, "the change of target closed the first gesture")
  h.eq(ends[1].label, "Contour: Reduce envelope", "closed with the Reduce label")
  h.eq(stub.rec.undoBlocks - blocks0, 2, "E2 got its own Undo block")
  h.truthy(#between(pts(E2), 0, 2) < #between(before2, 0, 2), "E2 thinned from ITS OWN original")
  dragging = false; edited = false; frame(razorDet(E2, { { 0, 2 }, { 4, 6 } }))   -- mouse released
  h.eq(#ends, 2, "the drag's end closed the second block")
  -- the first lane's original was recorded when its gesture ended, so Reset on it restores it
  st.red.amount = 0
  reduce.run({}, razorDet(E1, { { 0, 2 }, { 4, 6 } }), st.red)
  h.truthy(sameList(copyPts(E1), before1), "Reset on E1 restores its original")
end)

h.run()
