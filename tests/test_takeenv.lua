-- tests/test_takeenv.lua — TAKE-envelope support: the takeenv target converts project<->take time at
-- the boundary (fixture: env "TENV" on take "TAKE", item at 3s, length 5s, playrate 2.0 — take-time
-- range 0..10 maps to project 3..8), detection labels it, the panels span it (incl. Entire-item), and
-- the Transform overlay runs on it using the ITEM's screen rect as the value lane.
package.path = package.path .. ";./Contour/?.lua;./?.lua;./tests/?.lua"

local stub = require("reaper_stub")
stub.install()                          -- MUST precede the ui.* requires

local h = require("harness")
local target   = require("core.target")
local common   = require("ui.common")
local context  = require("core.context")
local generate = require("ui.generate")
local reduce   = require("ui.reduce")
local overlay  = require("ui.overlay")

local CTX = "CTX"
local function detTake()
  return { target = "envelope", label = "Take envelope: Pan", hasTimeSel = true, t0 = 3, t1 = 8,
           details = { env = "TENV", take = "TAKE" } }
end
local function detTrack()
  return { target = "envelope", label = "Envelope: Pan", hasTimeSel = true, t0 = 0, t1 = 4,
           details = { env = "ENV" } }
end

-- ── target resolution ─────────────────────────────────────────────────────────
h.test("fromContext: a take envelope resolves to the takeenv target (no more refusal)", function()
  stub.reset()
  local tgt, err = target.fromContext(detTake())
  h.truthy(tgt ~= nil, "target: " .. tostring(err))
  h.eq(tgt:kind(), "takeenv")
end)

h.test("fromContext: track envelopes still resolve to the envelope target", function()
  stub.reset()
  local tgt = target.fromContext(detTrack())
  h.eq(tgt:kind(), "envelope")
end)

-- ── time conversion ───────────────────────────────────────────────────────────
h.test("read converts take-relative times to project seconds", function()
  stub.reset()
  local tgt = target.fromContext(detTake())
  local pts = tgt:read(nil, nil)
  h.eq(#pts, 3)
  h.almost(pts[1].time, 3.0)   -- take 0  -> 3 + 0/2
  h.almost(pts[2].time, 5.0)   -- take 4  -> 3 + 4/2
  h.almost(pts[3].time, 8.0)   -- take 10 -> 3 + 10/2
end)

h.test("read honors project-time bounds", function()
  stub.reset()
  local tgt = target.fromContext(detTake())
  local pts = tgt:read(4.0, 8.0)
  h.eq(#pts, 2)
  h.almost(pts[1].time, 5.0); h.almost(pts[2].time, 8.0)
end)

h.test("write converts the span and point times to take time (playrate 2)", function()
  stub.reset()
  local tgt = target.fromContext(detTake())
  local n, err = tgt:write({ { time = 4.0, value = 0.5 }, { time = 6.0, value = -0.5 } }, 3.0, 8.0, {})
  h.eq(n, 2, "wrote 2: " .. tostring(err))
  h.eq(#stub.rec.delRange, 1)
  h.almost(stub.rec.delRange[1][1], 0.0)    -- (3-3)*2
  h.almost(stub.rec.delRange[1][2], 10.0)   -- (8-3)*2
  h.almost(stub.rec.ins[1].t, 2.0)          -- (4-3)*2
  h.almost(stub.rec.ins[2].t, 6.0)          -- (6-3)*2
end)

h.test("write does not mutate the caller's point tables (baseline safety)", function()
  stub.reset()
  local tgt = target.fromContext(detTake())
  local pts = { { time = 4.0, value = 0.5 } }
  tgt:write(pts, 3.0, 8.0, {})
  h.almost(pts[1].time, 4.0, 1e-12, "caller's table must keep PROJECT time")
end)

h.test("write clamps the span to the item bounds", function()
  stub.reset()
  local tgt = target.fromContext(detTake())
  local n = tgt:write({ { time = 4.0, value = 0.5 } }, 0.0, 20.0, {})
  h.eq(n, 1)
  h.almost(stub.rec.delRange[1][1], 0.0)    -- span start clamped to item start (proj 3 -> take 0)
  h.almost(stub.rec.delRange[1][2], 10.0)   -- span end clamped to item end (proj 8 -> take 10)
end)

-- ── spans / scopes ────────────────────────────────────────────────────────────
h.test("fullSpan + Entire-item scope = the item's project bounds", function()
  stub.reset()
  local tgt = target.fromContext(detTake())
  local a, b = tgt:fullSpan()
  h.almost(a, 3.0); h.almost(b, 8.0)
  local s0, s1 = common.spanFor(tgt, detTake(), { scope = common.SCOPE_ENTIRE })
  h.almost(s0, 3.0); h.almost(s1, 8.0)
end)

h.test("timesel scope clamps to the item bounds (like automation items)", function()
  stub.reset()
  local tgt = target.fromContext(detTake())
  local det = detTake(); det.t0, det.t1 = 0.0, 20.0
  local s0, s1 = common.spanFor(tgt, det, { scope = common.SCOPE_TIMESEL })
  h.almost(s0, 3.0); h.almost(s1, 8.0)
end)

-- ── detection ─────────────────────────────────────────────────────────────────
h.test("context.detect labels a selected take envelope and carries the take", function()
  stub.reset()
  context._resetRecency()
  local sME, sEnv = reaper.MIDIEditor_GetActive, reaper.GetSelectedEnvelope
  reaper.MIDIEditor_GetActive = function() return nil end
  reaper.GetSelectedEnvelope  = function() return "TENV" end
  local det = context.detect()
  reaper.MIDIEditor_GetActive, reaper.GetSelectedEnvelope = sME, sEnv
  h.eq(det.target, "envelope")
  h.truthy(det.label:find("Take envelope") ~= nil, "label: " .. tostring(det.label))
  h.eq(det.details.take, "TAKE")
end)

-- ── panels end-to-end ─────────────────────────────────────────────────────────
h.test("Generate writes an LFO into the take domain", function()
  stub.reset()
  local st = { op = "generate", target = "envelope", follow = true }
  generate.draw(CTX, st, detTake())          -- init panel state (no live write: nothing edited)
  local g = st.gen
  g.shapeIdx = 1                             -- Sine
  g.live = false
  generate.run(st, detTake(), g)
  h.truthy(#stub.rec.ins > 0, "generate wrote points: " .. tostring(g.status))
  local lastT = -1
  for _, p in ipairs(stub.rec.ins) do
    h.truthy(p.t >= -1e-9 and p.t <= 10 + 1e-9, "take-domain time in [0,10], got " .. tostring(p.t))
    h.truthy(p.t >= lastT - 1e-9, "times ascending")
    lastT = p.t
  end
end)

h.test("Reduce thins a take envelope (writes back in the take domain)", function()
  stub.reset()
  local pts = {}                             -- dense take-domain zigzag for RDP to thin
  for i = 0, 20 do
    pts[#pts + 1] = { time = i * 0.5, value = (i % 2 == 0) and -0.001 or 0.001, shape = 0, tension = 0, sel = true }
  end
  stub.takeEnvPoints = pts
  local st = { op = "reduce", target = "envelope", follow = true }
  reduce.draw(CTX, st, detTake())
  local g = st.red
  g.live = false; g.scope = 0; g.amount = 80
  reduce.run(st, detTake(), g)
  h.truthy(#stub.rec.ins > 0, "reduce rewrote points: " .. tostring(g.status))
  h.truthy(#stub.rec.ins < 21, "fewer points than the original 21, got " .. #stub.rec.ins)
  for _, p in ipairs(stub.rec.ins) do
    h.truthy(p.t >= -1e-9 and p.t <= 10 + 1e-9, "take-domain time, got " .. tostring(p.t))
  end
end)

-- ── Transform overlay ─────────────────────────────────────────────────────────
-- With SEVERAL take envelopes visible on one item, REAPER stacks them in strips; the box must map the
-- CLICKED envelope's own strip (I_TCPY_USED/I_TCPH_USED, track-relative), not the whole item body.
h.test("overlay lane rect: uses the take envelope's OWN strip, not the whole item", function()
  stub.reset()
  local lr = overlay._laneRect("TENV", "TAKE")
  h.almost(lr.topOff, 145)   -- track I_TCPY (120) + envelope strip Y (25)
  h.almost(lr.h, 30)         -- the strip height, NOT the item height (60)
end)

h.test("overlay lane rect: falls back to the item body when the strip fields are empty", function()
  stub.reset()
  local lr = overlay._laneRect("TENV0", "TAKE")
  h.almost(lr.topOff, 140)   -- track I_TCPY (120) + item I_LASTY (20)
  h.almost(lr.h, 60)         -- item height
end)

h.test("Transform overlay runs on a take envelope (item-rect lane; one-shot writes)", function()
  stub.reset()
  overlay.params = { knob = 0, shape = "power", symmetrical = false, flipMode = "absolute" }
  local started, serr = overlay.start(CTX, detTake())
  h.truthy(started, "start: " .. tostring(serr))
  local ok, err = pcall(function()
    overlay.frame(CTX); overlay.frame(CTX)
    overlay._pendingOneShot = "flip"; overlay.frame(CTX)
  end)
  h.truthy(ok, "frames threw: " .. tostring(err))
  h.truthy(#stub.rec.ins > 0, "flip should have written take-envelope points")
  overlay.finish()
end)

h.test("Transform overlay on a take envelope under macOS-style flipped coords (no crash)", function()
  stub.reset()
  local saved = reaper.ImGui_PointConvertNative
  reaper.ImGui_PointConvertNative = function(_ctx, x, y) return x * 2, 1200 - y * 2 end
  local ok, err = pcall(function()
    overlay.params = { knob = 20, shape = "sine", symmetrical = true, flipMode = "relative" }
    local started, serr = overlay.start(CTX, detTake())
    h.truthy(started, "start under flipped coords: " .. tostring(serr))
    overlay.frame(CTX); overlay.frame(CTX)
    overlay._pendingOneShot = "reverse"; overlay.frame(CTX)
    overlay.finish()
  end)
  reaper.ImGui_PointConvertNative = saved
  h.truthy(ok, "flipped take-env overlay threw: " .. tostring(err))
end)

h.run()
