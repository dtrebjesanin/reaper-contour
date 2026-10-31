package.path = package.path .. ";./Contour/?.lua;./?.lua;./tests/?.lua"
local h = require("harness")
local razor = require("core.razor")

-- Deep-compare two span lists ({{t0, t1}, ...}) and fail with a readable message.
local function eqSpans(got, want, msg)
  h.eq(#got, #want, (msg or "") .. " span count")
  for i = 1, #want do
    h.almost(got[i][1], want[i][1], 1e-12, (msg or "") .. " span " .. i .. " t0")
    h.almost(got[i][2], want[i][2], 1e-12, (msg or "") .. " span " .. i .. " t1")
  end
end

local function eqList(got, want, msg)
  h.eq(#got, #want, (msg or "") .. " length")
  for i = 1, #want do h.eq(got[i], want[i], (msg or "") .. " [" .. i .. "]") end
end

-- ── parse ────────────────────────────────────────────────────────────────────

h.test("parse reads an item lane and a quoted envelope lane", function()
  local out = razor.parse('1.0 2.0 "" 3.5 4.0 "{A}"')
  h.eq(#out, 2)
  h.almost(out[1].t0, 1.0); h.almost(out[1].t1, 2.0); h.eq(out[1].guid, "")
  h.almost(out[2].t0, 3.5); h.almost(out[2].t1, 4.0); h.eq(out[2].guid, "{A}")
end)

h.test("parse accepts an unquoted GUID", function()
  local out = razor.parse('1 2 {A}')
  h.eq(#out, 1)
  h.eq(out[1].guid, "{A}")
  h.almost(out[1].t0, 1); h.almost(out[1].t1, 2)
end)

h.test("parse of empty or nil input is an empty list", function()
  h.eq(#razor.parse(''), 0)
  h.eq(#razor.parse(nil), 0)
end)

h.test("parse of an incomplete triple is an empty list", function()
  h.eq(#razor.parse('1 2'), 0)
end)

h.test("parse skips a zero-length triple [RF 1]", function()
  h.eq(#razor.parse('2 2 "{A}"'), 0)
end)

h.test("parse skips reversed and unparsable triples but keeps the good ones", function()
  local out = razor.parse('3 2 "{A}" x 5 "{B}" 6 7 "{C}"')
  h.eq(#out, 1)
  h.eq(out[1].guid, "{C}")
end)

-- ── mergeSpans ───────────────────────────────────────────────────────────────

h.test("mergeSpans sorts and joins touching spans [RF 2]", function()
  eqSpans(razor.mergeSpans({ { 2, 3 }, { 1, 2 } }), { { 1, 3 } })
end)

h.test("mergeSpans joins overlapping spans [RF 2]", function()
  eqSpans(razor.mergeSpans({ { 1, 2.5 }, { 2, 3 } }), { { 1, 3 } })
end)

h.test("mergeSpans keeps separated spans apart [RF 2]", function()
  eqSpans(razor.mergeSpans({ { 1, 2 }, { 4, 5 } }), { { 1, 2 }, { 4, 5 } })
end)

h.test("mergeSpans keeps a span nested inside another", function()
  eqSpans(razor.mergeSpans({ { 1, 10 }, { 2, 3 } }), { { 1, 10 } })
end)

h.test("mergeSpans does not mutate its input", function()
  local input = { { 2, 3 }, { 1, 2 } }
  razor.mergeSpans(input)
  h.eq(input[1][1], 2); h.eq(input[1][2], 3)
  h.eq(input[2][1], 1); h.eq(input[2][2], 2)
end)

-- ── clamp ────────────────────────────────────────────────────────────────────

h.test("clamp trims a partial span", function()
  eqSpans(razor.clamp({ { 0, 5 } }, 1, 4), { { 1, 4 } })
end)

h.test("clamp drops a span outside the window", function()
  eqSpans(razor.clamp({ { 5, 6 } }, 1, 4), {})
end)

h.test("clamp drops a span that touches the window only at its edge [RF 4]", function()
  eqSpans(razor.clamp({ { 0, 1 } }, 1, 4), {})
end)

-- ── snapshot ─────────────────────────────────────────────────────────────────

local function twoTrackSnap()
  return razor.snapshot({
    { track = "T1", raw = '1 3 "{A}" 0 2 ""' },
    { track = "T2", raw = '1 3 "{B}"' },
  })
end

h.test("snapshot collects envelope and item lanes in order", function()
  local s = twoTrackSnap()
  eqList(s.order, { "{A}", "{B}" })
  eqSpans(razor.envSpans(s, "{A}"), { { 1, 3 } })
  eqSpans(razor.envSpans(s, "{B}"), { { 1, 3 } })
  eqSpans(razor.itemSpans(s, "T1"), { { 0, 2 } })
  h.eq(s.env["{A}"].track, "T1")
  h.eq(s.env["{B}"].track, "T2")
end)

h.test("snapshot orders by first appearance within one track [RF 3]", function()
  local s = razor.snapshot({ { track = "T1", raw = '1 3 "{A}" 1 3 "{P}"' } })
  eqList(s.order, { "{A}", "{P}" })
end)

h.test("snapshot merges spans within a lane", function()
  local s = razor.snapshot({ { track = "T1", raw = '2 3 "{A}" 1 2 "{A}" 0 1 ""  1 2 ""' } })
  eqSpans(razor.envSpans(s, "{A}"), { { 1, 3 } })
  eqSpans(razor.itemSpans(s, "T1"), { { 0, 2 } })
  eqList(s.order, { "{A}" })
end)

h.test("snapshot accepts tracks with nil or empty raw", function()
  local s = razor.snapshot({ { track = "T1" }, { track = "T2", raw = "" }, { track = "T3", raw = '1 2 {C}' } })
  eqList(s.order, { "{C}" })
  eqSpans(razor.itemSpans(s, "T1"), {})
end)

h.test("envSpans and itemSpans return {} for an unknown lane", function()
  local s = twoTrackSnap()
  eqSpans(razor.envSpans(s, "{nope}"), {})
  eqSpans(razor.itemSpans(s, "nope"), {})
  eqSpans(razor.itemSpans(s, "T2"), {})
end)

-- ── sigOf ────────────────────────────────────────────────────────────────────

h.test("sigOf is stable for equal snapshots", function()
  h.eq(razor.sigOf(twoTrackSnap()), razor.sigOf(twoTrackSnap()))
end)

h.test("sigOf differs for any span change", function()
  local base = razor.sigOf(twoTrackSnap())
  local moved = razor.sigOf(razor.snapshot({
    { track = "T1", raw = '2 4 "{A}" 0 2 ""' }, { track = "T2", raw = '1 3 "{B}"' } }))
  local itemMoved = razor.sigOf(razor.snapshot({
    { track = "T1", raw = '1 3 "{A}" 0 2.5 ""' }, { track = "T2", raw = '1 3 "{B}"' } }))
  local removed = razor.sigOf(razor.snapshot({
    { track = "T1", raw = '1 3 "{A}" 0 2 ""' } }))
  h.truthy(moved ~= base, "env span moved")
  h.truthy(itemMoved ~= base, "item span moved")
  h.truthy(removed ~= base, "lane removed")
end)

h.test("sigOf of an empty snapshot is a string", function()
  h.eq(type(razor.sigOf(razor.snapshot({}))), "string")
end)

-- ── changedLanes ─────────────────────────────────────────────────────────────

h.test("changedLanes against no previous snapshot returns every lane in order", function()
  eqList(razor.changedLanes(nil, twoTrackSnap()), { "{A}", "{B}" })
end)

h.test("changedLanes of an unchanged snapshot is empty", function()
  local s = twoTrackSnap()
  eqList(razor.changedLanes(s, s), {})
  eqList(razor.changedLanes(twoTrackSnap(), twoTrackSnap()), {})
end)

h.test("changedLanes reports a lane whose span moved", function()
  local prev = twoTrackSnap()
  local cur = razor.snapshot({
    { track = "T1", raw = '2 4 "{A}" 0 2 ""' }, { track = "T2", raw = '1 3 "{B}"' } })
  eqList(razor.changedLanes(prev, cur), { "{A}" })
end)

h.test("changedLanes excludes a lane that was only removed", function()
  local prev = twoTrackSnap()
  local cur = razor.snapshot({ { track = "T1", raw = '1 3 "{A}" 0 2 ""' } })
  eqList(razor.changedLanes(prev, cur), {})
end)

h.test("changedLanes excludes a lane that only lost one of its spans", function()
  local prev = razor.snapshot({ { track = "T1", raw = '1 3 "{A}" 5 6 "{A}"' } })
  local cur = razor.snapshot({ { track = "T1", raw = '1 3 "{A}"' } })
  eqList(razor.changedLanes(prev, cur), {})
end)

h.test("changedLanes reports a lane that gained a span", function()
  local prev = razor.snapshot({ { track = "T1", raw = '1 3 "{A}"' } })
  local cur = razor.snapshot({ { track = "T1", raw = '1 3 "{A}" 5 6 "{A}"' } })
  eqList(razor.changedLanes(prev, cur), { "{A}" })
end)

h.test("changedLanes reports a brand-new lane", function()
  local prev = razor.snapshot({ { track = "T1", raw = '1 3 "{A}"' } })
  local cur = razor.snapshot({ { track = "T1", raw = '1 3 "{A}" 1 3 "{N}"' } })
  eqList(razor.changedLanes(prev, cur), { "{N}" })
end)

h.test("changedLanes ignores sub-tolerance jitter and reports beyond it", function()
  local prev = razor.snapshot({ { track = "T1", raw = '1 3 "{A}"' } })
  local jitter = razor.snapshot({ { track = "T1", raw = '1.0000005 3.0000005 "{A}"' } })
  local moved = razor.snapshot({ { track = "T1", raw = '1.00001 3 "{A}"' } })
  eqList(razor.changedLanes(prev, jitter), {})
  eqList(razor.changedLanes(prev, moved), { "{A}" })
end)

h.test("changedLanes follows cur.order", function()
  local prev = razor.snapshot({ { track = "T1", raw = '1 2 "{A}" 1 2 "{B}" 1 2 "{C}"' } })
  local cur = razor.snapshot({ { track = "T1", raw = '1 2 "{A}" 5 6 "{B}" 5 6 "{C}"' } })
  eqList(razor.changedLanes(prev, cur), { "{B}", "{C}" })
end)

-- ── dragLanes ────────────────────────────────────────────────────────────────

h.test("dragLanes of a drag on one new lane is that lane alone", function()
  local prev = razor.snapshot({ { track = "T1", raw = '1 3 "{A}"' } })
  local cur = razor.snapshot({ { track = "T1", raw = '1 3 "{A}"' }, { track = "T2", raw = '5 6 "{B}"' } })
  eqList(razor.dragLanes(prev, cur), { "{B}" })
end)

h.test("dragLanes [F1]: a new span that another lane already has belongs to a multi-lane drag", function()
  -- Synth: Volume already had 1..3 s; a drag of 1..3 s across Synth and Pad changes only Pad.
  local prev = razor.snapshot({ { track = "T1", raw = '1 3 "{A}"' } })
  local cur = razor.snapshot({ { track = "T1", raw = '1 3 "{A}"' }, { track = "T2", raw = '1 3 "{B}"' } })
  eqList(razor.changedLanes(prev, cur), { "{B}" })
  eqList(razor.dragLanes(prev, cur), { "{A}", "{B}" })
end)

h.test("dragLanes counts a shared span within the 1e-6 tolerance, not beyond it", function()
  local prev = razor.snapshot({ { track = "T1", raw = '1 3 "{A}"' } })
  local near = razor.snapshot({ { track = "T1", raw = '1 3 "{A}"' }, { track = "T2", raw = '1.0000005 3.0000005 "{B}"' } })
  local far = razor.snapshot({ { track = "T1", raw = '1 3 "{A}"' }, { track = "T2", raw = '1.00001 3 "{B}"' } })
  eqList(razor.dragLanes(prev, near), { "{A}", "{B}" })
  eqList(razor.dragLanes(prev, far), { "{B}" })
end)

h.test("dragLanes does not count a lane that merely overlaps the new span", function()
  local prev = razor.snapshot({ { track = "T1", raw = '0 10 "{A}"' } })
  local cur = razor.snapshot({ { track = "T1", raw = '0 10 "{A}"' }, { track = "T2", raw = '1 3 "{B}"' } })
  eqList(razor.dragLanes(prev, cur), { "{B}" })
end)

h.test("dragLanes ignores item lanes and the changed lane's own spans", function()
  local prev = razor.snapshot({ { track = "T1", raw = '' } })
  local cur = razor.snapshot({ { track = "T1", raw = '1 3 "{A}" 1 3 ""' } })
  eqList(razor.dragLanes(prev, cur), { "{A}" })
end)

h.test("dragLanes of two new lanes sharing a span is both, in cur.order", function()
  local cur = razor.snapshot({ { track = "T1", raw = '1 3 "{A}"' }, { track = "T2", raw = '1 3 "{B}"' } })
  eqList(razor.dragLanes(nil, cur), { "{A}", "{B}" })
  eqList(razor.dragLanes(razor.snapshot({}), cur), { "{A}", "{B}" })
end)

h.test("dragLanes of an unchanged snapshot is empty", function()
  local s = twoTrackSnap()
  eqList(razor.dragLanes(s, s), {})
end)

h.test("dragLanes pulls in every lane that shares the new span", function()
  local prev = razor.snapshot({ { track = "T1", raw = '1 3 "{A}"' } })
  local cur = razor.snapshot({ { track = "T1", raw = '1 3 "{A}"' }, { track = "T2", raw = '1 3 "{B}" 1 3 "{C}"' } })
  eqList(razor.dragLanes(prev, cur), { "{A}", "{B}", "{C}" })
end)

-- ── settler ──────────────────────────────────────────────────────────────────

h.test("settler fires once after the signature has been stable", function()
  local s = razor.newSettler(0.25)
  h.eq(s:feed("x", 0, false), false)       -- baseline
  h.eq(s:feed("y", 0.1, false), false)     -- change seen
  h.eq(s:feed("y", 0.3, false), false)     -- 0.2 s stable, not enough
  h.eq(s:feed("y", 0.36, false), true)     -- 0.26 s stable
  h.eq(s:feed("y", 0.5, false), false)     -- already reported
end)

h.test("settler waits for the mouse to come up", function()
  local s = razor.newSettler(0.25)
  h.eq(s:feed("x", 0, false), false)
  h.eq(s:feed("z", 1, false), false)
  h.eq(s:feed("z", 2, true), false)        -- stable, but mouse still down
  h.eq(s:feed("z", 2.1, false), true)
end)

h.test("settler restarts its timer when the signature changes again", function()
  local s = razor.newSettler(0.25)
  s:feed("x", 0, false)
  s:feed("y", 1.0, false)
  h.eq(s:feed("z", 1.2, false), false)     -- y never settled; z timer starts here
  h.eq(s:feed("z", 1.4, false), false)     -- 0.2 s
  h.eq(s:feed("z", 1.46, false), true)     -- 0.26 s
end)

h.test("settler stays quiet when the signature returns to the settled one", function()
  local s = razor.newSettler(0.25)
  s:feed("x", 0, false)
  s:feed("y", 1, false)
  h.eq(s:feed("x", 2, false), false)
  h.eq(s:feed("x", 3, false), false)
end)

h.test("settler fires again for the next new state", function()
  local s = razor.newSettler(0.25)
  s:feed("x", 0, false)
  s:feed("y", 1, false)
  h.eq(s:feed("y", 1.3, false), true)
  s:feed("w", 2, false)
  h.eq(s:feed("w", 2.3, false), true)
end)

h.test("settler tolerates a float boundary at exactly settleSec", function()
  local s = razor.newSettler(0.25)
  s:feed("x", 0, false)
  s:feed("y", 0.1, false)
  h.eq(s:feed("y", 0.35, false), true)     -- 0.35 - 0.1 is 0.24999999999999997 in floats
end)

h.run()
