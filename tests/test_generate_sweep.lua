-- tests/test_generate_sweep.lua — headless OPTION-MATRIX sweep for Generate. This automates the bulk
-- of what was previously tested by hand: it drives the panel's REAL param assembly (generate._buildParams,
-- the native-%-slider -> value-unit conversion) -> the engine (lfo.generate) across EVERY shape x a
-- modifier matrix x both value ranges ([-1,1] envelope/Pan, [0,127] CC), asserting structural invariants
-- on the output (sane count, finite values/times, times within span and non-decreasing). It then runs a
-- few end-to-end generate.M.run() ENVELOPE writes through the recording stub to cover the
-- panel -> buildParams -> target.write wiring (CC<->ENV shape swap, range clamp). The pure engine's
-- numeric correctness is covered elsewhere (test_lfo, test_native_match, test_shapes); this guards the
-- COMBINATORIAL option space the UI exposes.
package.path = package.path .. ";./Contour/?.lua;./?.lua;./tests/?.lua"

local stub = require("reaper_stub")
stub.install()                          -- MUST precede the ui.* require (module-level reaper.* reads)

local h        = require("harness")
local lfo      = require("core.lfo")
local target   = require("core.target")
local generate = require("ui.generate")

-- SHAPES order in ui/generate.lua: 0=None then these. (id -> combo index)
local SHAPES = {
  { id = "sine", idx = 1 }, { id = "triangle", idx = 2 }, { id = "saw", idx = 3 },
  { id = "sawdown", idx = 4 }, { id = "square", idx = 5 }, { id = "trapezoid", idx = 6 },
  { id = "parametric", idx = 7 }, { id = "rectsine", idx = 8 }, { id = "sine2", idx = 9 },
  { id = "random", idx = 10 }, { id = "drift", idx = 11 }, { id = "custom", idx = 12 },
}

local RANGES = { { name = "env", vmin = -1, vmax = 1 }, { name = "cc", vmin = 0, vmax = 127 } }

-- A full panel state (every field _buildParams reads), defaulted to a benign mid-setting.
local function baseG()
  local g = {
    shapeIdx = 1, rateMode = 1, cycles = 4, hz = 2,
    lengthIdx = 6, feelIdx = 0, freqIdx = 8,
    baseline = 0, amplitude = 100, tilt = 0, tiltR = 0, phase = 0,
    ampSkew = 0, pulseWidth = 0.5, freqSkew = 0, swing = 0, seed = 1,
    smooth = 0, steps = 0, curve = 0, attack = 50, edge = 50,
  }
  -- a custom drawing so shapeIdx=custom resolves points without ExtState
  g.custom = { idx = 1, store = { { name = "T", points = {
    { x = 0, y = -1, shape = 1, tension = 0 },
    { x = 0.4, y = 1, shape = 5, tension = -0.3 },
    { x = 0.7, y = 0.2, shape = 0, tension = 0 },
    { x = 1, y = -1, shape = 1, tension = 0 },
  } } } }
  return g
end

local T0, T1 = 0.0, 4.0

local function assertInvariants(label, pts, vmin, vmax)
  h.truthy(type(pts) == "table" and #pts >= 2, label .. ": expected >=2 points, got " .. tostring(pts and #pts))
  local prev = -math.huge
  local span = vmax - vmin
  for i, p in ipairs(pts) do
    h.truthy(p.value == p.value, label .. ": NaN value at " .. i)                       -- NaN ~= NaN
    h.truthy(p.value ~= math.huge and p.value ~= -math.huge, label .. ": inf value at " .. i)
    h.truthy(p.time == p.time, label .. ": NaN time at " .. i)
    h.truthy(p.time >= T0 - 1e-6 and p.time <= T1 + 1e-6, label .. ": time " .. p.time .. " outside span at " .. i)
    h.truthy(p.time >= prev - 1e-6, label .. ": times not non-decreasing at " .. i)
    -- Pre-clamp values can legitimately exceed the range (amplitude>100% clips at write time); only
    -- assert they're not absurd (within 3x the half-range past the bounds) to catch runaway math.
    h.truthy(p.value >= vmin - 2 * span and p.value <= vmax + 2 * span,
      label .. ": value " .. p.value .. " runaway at " .. i)
    prev = p.time
  end
end

-- The modifier matrix: each is a mutation applied to a fresh baseG before building.
local VARIANTS = {
  { "plain",       function() end },
  { "steps8",      function(g) g.steps = 8 end },
  { "steps2",      function(g) g.steps = 2 end },
  { "smooth60",    function(g) g.smooth = 60 end },
  { "swing+",      function(g) g.swing = 0.6 end },
  { "swing-",      function(g) g.swing = -0.6 end },
  { "tiltL",       function(g) g.tilt = 80 end },
  { "tiltR",       function(g) g.tiltR = -80 end },
  { "tiltLR",      function(g) g.tilt = 50; g.tiltR = 50 end },
  { "ampSkew",     function(g) g.ampSkew = 90 end },
  { "freqSkew",    function(g) g.freqSkew = -90 end },
  { "phase",       function(g) g.phase = 75 end },
  { "pulse",       function(g) g.pulseWidth = 0.15 end },
  { "ampNeg",      function(g) g.amplitude = -150 end },
  { "ampClip",     function(g) g.amplitude = 200 end },
  { "baseHigh",    function(g) g.baseline = 80 end },
  { "curve",       function(g) g.curve = 70 end },
  { "attack",      function(g) g.attack = 20 end },
  { "edge",        function(g) g.edge = 25 end },
  { "rateMusical", function(g) g.rateMode = 0 end },
  { "rateHz",      function(g) g.rateMode = 2; g.hz = 6 end },
  { "feelTriplet", function(g) g.rateMode = 0; g.feelIdx = 1 end },
  { "feelDotted",  function(g) g.rateMode = 0; g.feelIdx = 2 end },
  { "lengthShort", function(g) g.rateMode = 0; g.lengthIdx = 2 end },
  { "freqHigh",    function(g) g.rateMode = 0; g.freqIdx = 11 end },
  { "freeCycles8", function(g) g.rateMode = 1; g.cycles = 8 end },
}

h.test("every shape x modifier x value-range builds + generates with sane structure", function()
  local combos = 0
  for _, shp in ipairs(SHAPES) do
    for _, rng in ipairs(RANGES) do
      for _, v in ipairs(VARIANTS) do
        local g = baseG(); g.shapeIdx = shp.idx; v[2](g)
        local label = ("%s/%s/%s"):format(shp.id, rng.name, v[1])
        local okB, params, ccShape = pcall(generate._buildParams, g, T0, rng.vmin, rng.vmax)
        h.truthy(okB, label .. ": _buildParams threw: " .. tostring(params))
        h.eq(params.shape, shp.id, label .. ": shape id mismatch")
        local okG, pts = pcall(lfo.generate, { t0 = T0, t1 = T1 }, params)
        h.truthy(okG, label .. ": lfo.generate threw: " .. tostring(pts))
        assertInvariants(label, pts, rng.vmin, rng.vmax)
        combos = combos + 1
      end
    end
  end
  h.truthy(combos == #SHAPES * #RANGES * #VARIANTS, "swept " .. combos .. " combos")
end)

-- Tilt semantics carried through buildParams: Tilt L is left-anchored (tiltOffset), Tilt R right-anchored
-- (tiltOffsetR). Guards the two-slider model end-to-end from panel % to value units.
h.test("buildParams maps Tilt L/R to the correct value-unit offsets", function()
  local g = baseG(); g.tilt = 100; g.tiltR = 0
  local p = generate._buildParams(g, T0, -1, 1)
  h.almost(p.tiltOffset, (100 / 100) * (1 - -1), 1e-9)   -- (vmax-vmin)=2
  h.eq(p.tiltOffsetR, 0)
  g = baseG(); g.tilt = 0; g.tiltR = 50
  p = generate._buildParams(g, T0, 0, 127)
  h.eq(p.tiltOffset, 0)
  h.almost(p.tiltOffsetR, (50 / 100) * 127, 1e-9)
end)

-- Steps below 2 must disable quantization (nil), not pass 0/1 through to the engine.
h.test("buildParams: steps<2 disables quantize; >=2 forwards it", function()
  local p0 = generate._buildParams((function() local g = baseG(); g.steps = 1; return g end)(), T0, -1, 1)
  h.truthy(p0.quantizeSteps == nil, "steps=1 must be off")
  local p8 = generate._buildParams((function() local g = baseG(); g.steps = 8; return g end)(), T0, -1, 1)
  h.eq(p8.quantizeSteps, 8)
end)

-- Custom + Swing must stay SPARSE (regression b90fb56: Swing wrongly densified a basic custom shape via
-- the generic SSS sampler). The dense path (Steps) is the contrast: custom+swing << custom+steps.
h.test("custom + swing stays sparse (not densified)", function()
  local function ptsFor(mut)
    local g = baseG(); g.shapeIdx = 12; mut(g)
    return lfo.generate({ t0 = T0, t1 = T1 }, generate._buildParams(g, T0, -1, 1))
  end
  local swing = ptsFor(function(g) g.swing = 0.6 end)
  local steps = ptsFor(function(g) g.steps = 8 end)        -- routes custom through the dense SSS sampler
  h.truthy(#swing < #steps, ("custom+swing (%d) should be sparser than custom+steps (%d)"):format(#swing, #steps))
  h.truthy(#swing <= 40, "custom+swing point count should be sparse, got " .. #swing)
end)

-- End-to-end wiring: generate.M.run -> generateAndWrite -> target.write, recorded by the stub.
local function detEnv() return { target = "envelope", label = "Pan", hasTimeSel = true, t0 = T0, t1 = T1, details = { env = {} } } end
local function detCC()  return { target = "cc", label = "CC1", hasTimeSel = true, t0 = T0, t1 = T1, details = { take = "TAKE", midiEditor = "ME" } } end

h.test("M.run writes recorded envelope points, clipped to the Pan range at 300% amplitude", function()
  for _, shp in ipairs({ SHAPES[1], SHAPES[5], SHAPES[12] }) do   -- sine, square, custom
    stub.reset()
    -- 300% half-swing around centre 0 forces the write past +/-1 so the range clamp is actually exercised
    -- (at the default 100% the values are in-range regardless of clamping -> a near-vacuous assertion).
    local g = baseG(); g.shapeIdx = shp.idx; g.scope = 0; g.amplitude = 300; g.baseline = 0
    generate.run({}, detEnv(), g)
    h.truthy(not g.statusErr, shp.id .. ": M.run reported error: " .. tostring(g.status))
    h.truthy(#stub.rec.ins >= 2, shp.id .. ": expected recorded envelope inserts, got " .. #stub.rec.ins)
    local lo, hi = math.huge, -math.huge
    for _, ins in ipairs(stub.rec.ins) do
      h.truthy(ins.v >= -1 - 1e-9 and ins.v <= 1 + 1e-9, shp.id .. ": value not clamped to Pan range: " .. ins.v)
      h.truthy(ins.t >= T0 - 1e-6 and ins.t <= T1 + 1e-6, shp.id .. ": written time out of span: " .. ins.t)
      if ins.v < lo then lo = ins.v end
      if ins.v > hi then hi = ins.v end
    end
    h.almost(lo, -1, 1e-9, shp.id .. ": 300% amplitude should clip to the lower rail")
    h.almost(hi,  1, 1e-9, shp.id .. ": 300% amplitude should clip to the upper rail")
  end
end)

-- Write-layer clamp in ISOLATION (not via the panel's redundant pre-clamp): CC:write must itself clamp
-- and floor values, so removing JUST the write-layer clamp can't slip through behind the pre-clamp.
h.test("CC:write clamps + floors values at the write layer, independent of any caller pre-clamp", function()
  stub.reset()
  local tgt = target.CC.new("TAKE", nil, stub.CC_LANE, 0)
  tgt:write({
    { time = 0.5, value = 200,  shape = 1 },   -- over max  -> 127
    { time = 1.5, value = -50,  shape = 1 },   -- under min -> 0
    { time = 2.5, value = 63.7, shape = 1 },   -- floored   -> 63
  }, 0, 4, {})
  local cc = stub.ccOnLane(stub.CC_LANE)   -- ascending by tick
  h.eq(#cc, 3)
  h.eq(cc[1].val, 127, "200 must clamp to 127 at the write layer")
  h.eq(cc[2].val, 0,   "-50 must clamp to 0 at the write layer")
  h.eq(cc[3].val, 63,  "63.7 must floor to 63 at the write layer")
end)

-- CC is the most-used Generate path: drive it end-to-end (M.run -> CC:write) and assert the things the
-- ENV sweep can't — integer values floored into 0..127, amplitude>100% hard-clipping, valid CC shapes.
h.test("M.run on CC writes integer values clamped to 0..127, with clipping + valid shapes", function()
  for _, shp in ipairs({ SHAPES[1], SHAPES[5], SHAPES[3], SHAPES[12] }) do   -- sine, square, saw, custom
    stub.reset()
    local g = baseG(); g.shapeIdx = shp.idx; g.scope = 0; g.ccNum = stub.CC_LANE
    g.amplitude = 300; g.baseline = 0   -- 300% half-swing around centre => must clip at both rails
    generate.run({}, detCC(), g)
    h.truthy(not g.statusErr, shp.id .. ": M.run errored: " .. tostring(g.status))
    local cc = stub.ccOnLane(stub.CC_LANE)
    h.truthy(#cc >= 2, shp.id .. ": expected CC events written, got " .. #cc)
    local lo, hi = 999, -1
    for _, e in ipairs(cc) do
      h.eq(e.val, math.floor(e.val), shp.id .. ": CC value not an integer: " .. tostring(e.val))
      h.truthy(e.val >= 0 and e.val <= 127, shp.id .. ": CC value out of 0..127: " .. e.val)
      h.truthy(e.shape >= 0 and e.shape <= 5, shp.id .. ": invalid CC shape int: " .. tostring(e.shape))
      if e.val < lo then lo = e.val end
      if e.val > hi then hi = e.val end
    end
    h.eq(lo, 0,   shp.id .. ": 300% amplitude should clip to 0")
    h.eq(hi, 127, shp.id .. ": 300% amplitude should clip to 127")
  end
end)

h.test("M.run refuses to write when no shape is selected (None)", function()
  stub.reset()
  local g = baseG(); g.shapeIdx = 0; g.scope = 0   -- None
  generate.run({}, detEnv(), g)
  h.truthy(g.statusErr, "None must not write")
  h.eq(#stub.rec.ins, 0)
end)

-- ---- Generate-preset capture/recall (the panel logic above the genpreset codec) ------------------
local genpreset = require("core.genpreset")

h.test("Generate preset: capture -> encode -> decode -> recall round-trips every control", function()
  stub.reset()
  local g = baseG()
  g.shapeIdx = 5; g.amplitude = 137; g.swing = 0.4; g.tilt = -25; g.tiltR = 60; g.steps = 6; g.smooth = 30
  local params = generate._captureParams(g)
  local back = genpreset.decode(genpreset.encode({ { name = "My Preset", params = params } }))
  h.eq(#back, 1)
  local g2 = baseG()
  g2.shapeIdx = 0; g2.amplitude = 0; g2.swing = 0; g2.tilt = 0; g2.tiltR = 0; g2.steps = 0; g2.smooth = 0
  generate._recallGenPreset(g2, back[1])
  for k, v in pairs(params) do h.eq(g2[k], v, "control " .. k .. " did not round-trip") end
  h.eq(g2.shapeIdx, 5); h.eq(g2.tiltR, 60); h.eq(g2.steps, 6)
end)

h.test("Generate preset: a Custom-based preset embeds + materialises its drawing on recall", function()
  stub.reset()
  local g = baseG(); g.shapeIdx = 12   -- Custom (baseG seeds g.custom with a drawing)
  local pts = generate._genPresetPoints(g)
  h.truthy(type(pts) == "string" and #pts > 0, "Custom preset must embed an encoded drawing")
  local back = genpreset.decode(genpreset.encode({ { name = "Wobble", params = generate._captureParams(g), points = pts } }))
  h.eq(back[1].points, pts, "embedded drawing must survive the codec")
  local g2 = baseG(); g2.custom = nil   -- force recall to rebuild the store from scratch
  generate._recallGenPreset(g2, back[1])
  h.truthy(g2.custom and g2.custom.store, "recall should create the Custom store")
  local found = false
  for _, sh in ipairs(g2.custom.store) do if sh.name == "Wobble" then found = true end end
  h.truthy(found, "recall should materialise the drawing as a Shape named after the preset")
  h.eq(g2.custom.store[g2.custom.idx].name, "Wobble", "and select it")
end)

h.test("Generate preset: a non-Custom preset embeds no drawing", function()
  stub.reset()
  local g = baseG(); g.shapeIdx = 1   -- Sine
  h.truthy(generate._genPresetPoints(g) == nil, "non-Custom shapes must not embed points")
end)

-- ---- Custom draw-pad ghost overlay (one normalized cycle, per-cycle modifiers only) --------------
local function ov(mut) local g = baseG(); g.shapeIdx = 12; mut(g); return generate._customOverlayPoints(g) end
local function shapeStr(o) local s = {}; for _, p in ipairs(o) do s[#s + 1] = ("%.5f,%.5f"):format(p.x, p.y) end; return table.concat(s, ";") end

h.test("custom overlay: normalized one-cycle curve for custom, nil for other shapes", function()
  local o = ov(function() end)
  h.truthy(o and #o >= 2, "custom should produce an overlay polyline")
  for _, p in ipairs(o) do
    h.truthy(p.x >= -1e-9 and p.x <= 1 + 1e-9, "x out of [0,1]: " .. p.x)
    h.truthy(p.y >= -1 - 1e-9 and p.y <= 1 + 1e-9, "y out of [-1,1]: " .. p.y)
  end
  local g = baseG(); g.shapeIdx = 1
  h.truthy(generate._customOverlayPoints(g) == nil, "non-custom shape must return nil")
end)

h.test("custom overlay: REFLECTS the per-cycle modifiers (swing / steps / smooth)", function()
  local plain = shapeStr(ov(function() end))
  h.truthy(shapeStr(ov(function(g) g.steps = 4 end)) ~= plain, "Steps should reshape the overlay")
  h.truthy(shapeStr(ov(function(g) g.smooth = 80 end)) ~= plain, "Smooth should reshape the overlay")
  h.truthy(shapeStr(ov(function(g) g.swing = 0.6 end)) ~= plain, "Swing should reshape the overlay")
end)

h.test("custom overlay: IGNORES span-wide modifiers (tilt / skew / amplitude / baseline)", function()
  local plain = shapeStr(ov(function() end))
  h.eq(shapeStr(ov(function(g) g.tilt = 100 end)),     plain, "Tilt L must not affect the per-cycle overlay")
  h.eq(shapeStr(ov(function(g) g.tiltR = -100 end)),   plain, "Tilt R must not affect the per-cycle overlay")
  h.eq(shapeStr(ov(function(g) g.ampSkew = 90 end)),   plain, "amp-skew must not affect the per-cycle overlay")
  h.eq(shapeStr(ov(function(g) g.freqSkew = 90 end)),  plain, "freq-skew must not affect the per-cycle overlay")
  h.eq(shapeStr(ov(function(g) g.amplitude = 300 end)),plain, "amplitude (level) must not affect the per-cycle overlay")
  h.eq(shapeStr(ov(function(g) g.baseline = 80 end)),  plain, "baseline (level) must not affect the per-cycle overlay")
end)

h.run()
