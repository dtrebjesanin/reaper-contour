package.path = package.path .. ";./Contour/?.lua;./?.lua;./tests/?.lua"
local h = require("harness")
local lfo = require("core.lfo")

h.test("cycleLength free", function()
  h.almost(lfo.cycleLength({ mode = "free", cycles = 4 }, 8.0), 2.0)
end)
h.test("cycleLength hz", function()
  h.almost(lfo.cycleLength({ mode = "hz", hz = 2 }, 8.0), 0.5)
end)
h.test("cycleLength sync passthrough", function()
  h.almost(lfo.cycleLength({ mode = "sync", cycleSec = 0.75 }, 8.0), 0.75)
end)

-- Native musical rate: period (QN/cycle) = 8 * lengthFrac * feelMult / freq. Verified by the
-- cycle counts in a 2-bar / 8-QN selection (cycles = 8 / QNPerCycle) against the native dumps.
h.test("musicalBeatsPerCycle matches native cycle counts", function()
  local function cyclesIn8(L, mult, F) return 8 / lfo.musicalBeatsPerCycle(L, mult, F) end
  h.almost(cyclesIn8(0.25, 1, 0.5), 2)    -- CC1:  length 1/4, freq 1/2 -> 2 cycles
  h.almost(cyclesIn8(0.25, 1, 1.0), 4)    -- CC28: freq 1               -> 4 cycles
  h.almost(cyclesIn8(0.25, 1, 0.25), 1)   -- CC27: freq 1/4             -> 1 cycle
  h.almost(cyclesIn8(0.5, 1, 0.5), 1)     -- CC36: length 1/2           -> 1 cycle
  h.almost(cyclesIn8(0.125, 1, 0.5), 4)   -- CC37: length 1/8           -> 4 cycles
  -- triplet shortens the period (more cycles), dotted lengthens it (fewer):
  h.almost(lfo.musicalBeatsPerCycle(0.25, 2/3, 1), lfo.musicalBeatsPerCycle(0.25, 1, 1) * 2/3)
  h.almost(lfo.musicalBeatsPerCycle(0.25, 1.5, 1), lfo.musicalBeatsPerCycle(0.25, 1, 1) * 1.5)
end)
h.test("cycleLength sync without cycleSec errors", function()
  h.eq(pcall(lfo.cycleLength, { mode = "sync" }, 8.0), false)
end)

h.test("quantize off is identity", function()
  h.almost(lfo.quantizeBipolar(0.3, nil), 0.3)
  h.almost(lfo.quantizeBipolar(0.3, 1), 0.3)
end)
h.test("quantize 2 steps snaps to -1/+1", function()
  h.eq(lfo.quantizeBipolar(0.2, 2), 1)
  h.eq(lfo.quantizeBipolar(-0.2, 2), -1)
end)
h.test("quantize 3 steps has a zero", function()
  h.almost(lfo.quantizeBipolar(0.1, 3), 0)
end)

h.test("fadeDepth no fades is full", function()
  h.eq(lfo.fadeDepth(0.0, 0, 0), 1)
  h.eq(lfo.fadeDepth(0.5, 0, 0), 1)
end)
h.test("fadeDepth ramps in and out", function()
  h.almost(lfo.fadeDepth(0.0, 0.2, 0), 0)     -- start of a fade-in
  h.almost(lfo.fadeDepth(0.1, 0.2, 0), 0.5)   -- halfway through fade-in
  h.almost(lfo.fadeDepth(1.0, 0, 0.2), 0)     -- end of a fade-out
end)

local shapes = require("core.shapes")

-- NATIVE MATCH (v2.4): sine uses ULTRA-SPARSE extremum placement (one point per
-- waveform extremum: trough at integer phase, peak at half-integer phase) + a final
-- point at rel=1; density is IGNORED for sine. 1 cycle over [0,1] => extrema at
-- rel 0 (trough) and 0.5 (peak), plus the rel=1 endpoint (trough) => 3 points.
h.test("generate sine extremum placement and endpoints", function()
  local pts = lfo.generate({ t0 = 0, t1 = 1 }, {
    shape = "sine", rate = { mode = "free", cycles = 1 },
    amplitude = 1, baseline = 0, density = 4,
  })
  h.eq(#pts, 3)
  h.almost(pts[1].time, 0)
  h.almost(pts[#pts].time, 1)
  h.almost(pts[1].value, -1, 1e-9)        -- trough at phase 0 (-cos(0) = -1)
  h.almost(pts[2].time, 0.5)
  h.almost(pts[2].value, 1, 1e-9)         -- peak at mid-cycle (-cos(pi) = +1)
  h.almost(pts[3].value, -1, 1e-9)        -- trough again at the cycle end
end)

-- baseline + amplitude scaling
h.test("generate scales by amplitude and baseline", function()
  local pts = lfo.generate({ t0 = 0, t1 = 1 }, {
    shape = "sine", rate = { mode = "free", cycles = 1 },
    amplitude = 50, baseline = 64, density = 4,
  })
  h.almost(pts[2].value, 114, 1e-6)       -- pts[2] = peak at rel 0.5: 64 + 50*1
end)

-- random shape holds one value across the whole single cycle
h.test("generate random is stepped per cycle", function()
  local pts = lfo.generate({ t0 = 0, t1 = 1 }, {
    shape = "random", rate = { mode = "free", cycles = 1 },
    amplitude = 1, baseline = 0, density = 4, seed = 7,
  })
  for i = 2, #pts - 1 do h.almost(pts[i].value, pts[1].value) end
end)

-- fade-in ramps the first point's depth to zero
h.test("generate honors fade in", function()
  local pts = lfo.generate({ t0 = 0, t1 = 1 }, {
    shape = "sine", rate = { mode = "free", cycles = 1 },
    amplitude = 1, baseline = 0, density = 4, fadeIn = 0.5,
  })
  h.almost(pts[1].value, 0, 1e-9)         -- depth 0 at the very start
end)

-- empty/zero-length span yields no points
h.test("generate empty span", function()
  local pts = lfo.generate({ t0 = 2, t1 = 2 }, {
    shape = "sine", rate = { mode = "free", cycles = 1 },
  })
  h.eq(#pts, 0)
end)

-- last point must equal t1 even when spanLen/dt is not an integer
-- density=3, cycles=1, span=1s => dt=1/3, n=floor(3.5)=3, n*dt=0.999... < 1.0
h.test("generate last point equals t1 (non-integer steps)", function()
  local pts = lfo.generate({ t0 = 0, t1 = 1 }, {
    shape = "sine", rate = { mode = "free", cycles = 1 },
    amplitude = 1, baseline = 0, density = 3,
  })
  h.almost(pts[#pts].time, 1.0)
end)

-- A smooth modifier routes a shape through the dense generic sampler and blends it toward
-- the -cos sine. (NATIVE MATCH: a plain triangle now takes the SPARSE anchored path — extrema
-- only — so smooth=0 has no 1/8-cycle point to compare; smooth>0 forces the dense path.)
h.test("generate forwards smooth modifier (blends toward sine)", function()
  local smoothed = lfo.generate({ t0 = 0, t1 = 1 },
    { shape = "triangle", rate = { mode = "free", cycles = 1 },
      amplitude = 1, baseline = 0, density = 8, smooth = 1 })
  local function valAt(pts, rel)
    for _, p in ipairs(pts) do if math.abs(p.time - rel) < 1e-6 then return p.value end end
  end
  -- at 1/8 cycle a full-smooth triangle equals the -cos sine waveform there.
  h.almost(valAt(smoothed, 0.125), -math.cos(2 * math.pi * 0.125), 1e-9)
end)

-- swing=0 must be bit-identical to omitting swing (identity)
h.test("generate swing=0 is identical to no swing", function()
  local base = { shape = "sine", rate = { mode = "free", cycles = 4 },
    amplitude = 50, baseline = 64, density = 8 }
  local noSwing = lfo.generate({ t0 = 0, t1 = 2 }, base)
  local withParams = {}
  for k, v in pairs(base) do withParams[k] = v end
  withParams.swing = 0
  local zeroSwing = lfo.generate({ t0 = 0, t1 = 2 }, withParams)
  h.eq(#zeroSwing, #noSwing)
  for i = 1, #noSwing do
    -- bit-identical: exact equality, not approximate
    h.eq(zeroSwing[i].time, noSwing[i].time)
    h.eq(zeroSwing[i].value, noSwing[i].value)
  end
end)

-- swing=0 helper is a strict identity on cyclePos
h.test("swingCyclePos swing=0 is exact identity", function()
  for _, cp in ipairs({ 0, 0.3, 1.0, 1.7, 2.0, 3.49, 5.25 }) do
    h.eq(lfo.swingCyclePos(cp, 0), cp)
    h.eq(lfo.swingCyclePos(cp, nil), cp)
  end
end)

-- swing>0 shifts where the first cycle ends: the boundary at pair-local 1.0
-- moves to 1+swing*0.5, so the value sampled at a fixed time differs from swing=0
h.test("generate swing>0 shifts the cycle boundary", function()
  local base = { shape = "sawup", rate = { mode = "free", cycles = 4 },
    amplitude = 1, baseline = 0, density = 8 }
  local noSwing = lfo.generate({ t0 = 0, t1 = 2 }, base)
  local swung = {}
  for k, v in pairs(base) do swung[k] = v end
  swung.swing = 0.5
  local swungPts = lfo.generate({ t0 = 0, t1 = 2 }, swung)
  -- Find a point whose value moved. With swing=0.5 the first cycle is
  -- stretched, so the sawtooth ramp at a fixed sample time reads differently.
  local moved = false
  for i = 1, math.min(#noSwing, #swungPts) do
    if math.abs(swungPts[i].value - noSwing[i].value) > 1e-6 then
      moved = true
      break
    end
  end
  h.truthy(moved, "expected at least one point value to differ under swing>0")
end)

-- swing must never push values outside baseline +/- amplitude
h.test("generate swing keeps values within baseline +/- amplitude", function()
  local base = { shape = "sine", rate = { mode = "free", cycles = 6 },
    amplitude = 40, baseline = 64, density = 12, swing = 0.8 }
  local pts = lfo.generate({ t0 = 0, t1 = 3 }, base)
  h.truthy(#pts > 0)
  for i = 1, #pts do
    h.truthy(pts[i].value <= 64 + 40 + 1e-9, "value above baseline+amplitude")
    h.truthy(pts[i].value >= 64 - 40 - 1e-9, "value below baseline-amplitude")
  end
end)

-- Extreme swing (the domain endpoints) must stay bounded within baseline +/- amplitude.
h.test("generate swing=1 and swing=-1 stay bounded", function()
  for _, sw in ipairs({ 1, -1 }) do
    local base = { shape = "sine", rate = { mode = "free", cycles = 6 },
      amplitude = 40, baseline = 64, density = 12, swing = sw }
    local pts = lfo.generate({ t0 = 0, t1 = 3 }, base)
    h.truthy(#pts > 0)
    for i = 1, #pts do
      h.truthy(pts[i].value <= 64 + 40 + 1e-9, "swing=" .. sw .. " value above baseline+amplitude")
      h.truthy(pts[i].value >= 64 - 40 - 1e-9, "swing=" .. sw .. " value below baseline-amplitude")
    end
  end
end)

-- Swing combined with a nonzero phase stays bounded AND differs from swing alone
-- (phase offset shifts where each warped cycle is sampled).
h.test("generate swing+phase stays bounded and differs from swing alone", function()
  local base = { shape = "sine", rate = { mode = "free", cycles = 6 },
    amplitude = 40, baseline = 64, density = 12, swing = 0.7 }
  local swingOnly = lfo.generate({ t0 = 0, t1 = 3 }, base)

  local withPhase = {}
  for k, v in pairs(base) do withPhase[k] = v end
  withPhase.phase = 0.3
  local swingPhase = lfo.generate({ t0 = 0, t1 = 3 }, withPhase)

  h.truthy(#swingPhase > 0)
  for i = 1, #swingPhase do
    h.truthy(swingPhase[i].value <= 64 + 40 + 1e-9, "swing+phase value above baseline+amplitude")
    h.truthy(swingPhase[i].value >= 64 - 40 - 1e-9, "swing+phase value below baseline-amplitude")
  end

  -- The phase offset must actually change the result vs swing alone.
  local differs = false
  for i = 1, math.min(#swingOnly, #swingPhase) do
    if math.abs(swingPhase[i].value - swingOnly[i].value) > 1e-6 then
      differs = true
      break
    end
  end
  h.truthy(differs, "expected swing+phase to differ from swing alone")
end)

-- tilt=0 must be bit-identical to omitting tilt (exact identity)
h.test("generate tilt=0 is identical to no tilt", function()
  local base = { shape = "sine", rate = { mode = "free", cycles = 4 },
    amplitude = 50, baseline = 64, density = 8 }
  local noTilt = lfo.generate({ t0 = 0, t1 = 2 }, base)
  local withParams = {}
  for k, v in pairs(base) do withParams[k] = v end
  withParams.tilt = 0
  local zeroTilt = lfo.generate({ t0 = 0, t1 = 2 }, withParams)
  h.eq(#zeroTilt, #noTilt)
  for i = 1, #noTilt do
    h.eq(zeroTilt[i].time, noTilt[i].time)
    h.eq(zeroTilt[i].value, noTilt[i].value)
  end
end)

-- tilt=0 must be bit-identical to omitting tilt for the SQUARE shape too (covers the
-- explicit-edge generateSquare path, which applies tilt independently of the generic sampler).
h.test("generate square tilt=0 is identical to no tilt", function()
  local base = { shape = "square", rate = { mode = "free", cycles = 4 },
    amplitude = 50, baseline = 64, density = 2 }
  local noTilt = lfo.generate({ t0 = 0, t1 = 2 }, base)
  local withParams = {}
  for k, v in pairs(base) do withParams[k] = v end
  withParams.tilt = 0
  local zeroTilt = lfo.generate({ t0 = 0, t1 = 2 }, withParams)
  h.eq(#zeroTilt, #noTilt)
  for i = 1, #noTilt do
    h.eq(zeroTilt[i].time, noTilt[i].time)
    h.eq(zeroTilt[i].value, noTilt[i].value)
  end
end)

-- tilt>0 leaves the FIRST point (rel=0, anchored left) unchanged but raises a
-- later point (the right side tilts up).
h.test("generate tilt>0 anchors left and raises right", function()
  local base = { shape = "sine", rate = { mode = "free", cycles = 4 },
    amplitude = 50, baseline = 64, density = 8 }
  local noTilt = lfo.generate({ t0 = 0, t1 = 2 }, base)
  local up = {}
  for k, v in pairs(base) do up[k] = v end
  up.tilt = 0.5
  local upPts = lfo.generate({ t0 = 0, t1 = 2 }, up)
  -- first point (rel=0): tilt offset is amp*tilt*0 = 0 -> unchanged
  h.almost(upPts[1].value, noTilt[1].value, 1e-9)
  -- last point (rel=1): tilt offset is amp*tilt*1 = 50*0.5 = 25 above no-tilt
  h.almost(upPts[#upPts].value - noTilt[#noTilt].value, 25, 1e-6)
  h.truthy(upPts[#upPts].value > noTilt[#noTilt].value, "right side must be higher")
end)

-- tilt<0 lowers the right side while still anchoring the left.
h.test("generate tilt<0 lowers right", function()
  local base = { shape = "sine", rate = { mode = "free", cycles = 4 },
    amplitude = 50, baseline = 64, density = 8 }
  local noTilt = lfo.generate({ t0 = 0, t1 = 2 }, base)
  local down = {}
  for k, v in pairs(base) do down[k] = v end
  down.tilt = -0.5
  local downPts = lfo.generate({ t0 = 0, t1 = 2 }, down)
  h.almost(downPts[1].value, noTilt[1].value, 1e-9)            -- left anchored
  h.almost(downPts[#downPts].value - noTilt[#noTilt].value, -25, 1e-6)
  h.truthy(downPts[#downPts].value < noTilt[#noTilt].value, "right side must be lower")
end)

-- RIGHT-ANCHORED tilt (Tilt R, via tiltOffsetR): 0 at the right edge, full at the left -> the LEFT end
-- moves while the right stays put. tiltOffsetR=0 is identity, so native-match never sees it.
h.test("generate tiltR>0 anchors right and raises left", function()
  local base = { shape = "sine", rate = { mode = "free", cycles = 4 }, amplitude = 50, baseline = 64, density = 8 }
  local none = lfo.generate({ t0 = 0, t1 = 2 }, base)
  local r = {}; for k, v in pairs(base) do r[k] = v end; r.tiltOffsetR = 25
  local rp = lfo.generate({ t0 = 0, t1 = 2 }, r)
  h.almost(rp[1].value - none[1].value, 25, 1e-6, "left edge raised by full offset")
  h.almost(rp[#rp].value, none[#none].value, 1e-9, "right edge anchored (unchanged)")
end)

h.test("generate tiltR<0 lowers left, right anchored", function()
  local base = { shape = "sine", rate = { mode = "free", cycles = 4 }, amplitude = 50, baseline = 64, density = 8 }
  local none = lfo.generate({ t0 = 0, t1 = 2 }, base)
  local r = {}; for k, v in pairs(base) do r[k] = v end; r.tiltOffsetR = -25
  local rp = lfo.generate({ t0 = 0, t1 = 2 }, r)
  h.almost(rp[1].value - none[1].value, -25, 1e-6, "left edge lowered")
  h.almost(rp[#rp].value, none[#none].value, 1e-9, "right edge anchored")
end)

-- The two tilts are independent and combine: Tilt L (left-anchored) is full at the RIGHT edge, Tilt R
-- (right-anchored) is full at the LEFT edge; each edge sees only its own slider.
h.test("generate Tilt L and Tilt R combine independently", function()
  local base = { shape = "sine", rate = { mode = "free", cycles = 4 }, amplitude = 50, baseline = 64, density = 8 }
  local none = lfo.generate({ t0 = 0, t1 = 2 }, base)
  local both = {}; for k, v in pairs(base) do both[k] = v end
  both.tiltOffset = 20    -- Tilt L: +20 at the right edge (rel=1), 0 at the left
  both.tiltOffsetR = 10   -- Tilt R: +10 at the left edge (rel=0), 0 at the right
  local bp = lfo.generate({ t0 = 0, t1 = 2 }, both)
  h.almost(bp[1].value - none[1].value, 10, 1e-6, "left edge: only Tilt R")
  h.almost(bp[#bp].value - none[#none].value, 20, 1e-6, "right edge: only Tilt L")
end)

-- NATIVE MATCH: a default square (phase 0, pw 0.5) starts LOW at the cycle start and steps
-- UP at cycle-fraction (1 - pulseWidth) — the HIGH portion is the LAST pw of each cycle
-- (native CC4 begins at the trough; our old emitter started HIGH, the user-reported bug).
-- The step CC shape holds each value forward, so there is NO trailing point at t1.
h.test("square starts low and steps up at (1-pulseWidth) [native]", function()
  -- 2 cycles over [0,2]: cycleLen=1. Edges: t0(LOW), 0.5(HIGH), 1.0(LOW), 1.5(HIGH).
  local pts = lfo.generate({ t0 = 0, t1 = 2 }, {
    shape = "square", rate = { mode = "free", cycles = 2 },
    amplitude = 1, baseline = 0, density = 2,
  })
  h.almost(pts[1].time, 0)
  h.almost(pts[1].value, -1, 1e-9)   -- starts LOW (native begins at the trough)
  local function valueAt(t)
    for _, p in ipairs(pts) do if math.abs(p.time - t) < 1e-6 then return p.value end end
    return nil
  end
  h.almost(valueAt(0.5), 1, 1e-9)    -- steps UP at the (1-pw)=0.5 boundary
  h.almost(valueAt(1.0), -1, 1e-9)   -- next cycle starts low
  h.almost(valueAt(1.5), 1, 1e-9)
  h.truthy(pts[#pts].time < 2.0, "no trailing t1 point: the step shape holds to the end")
end)

-- NATIVE MATCH: the HIGH edge tracks pulseWidth (HIGH = the last pw of the cycle).
h.test("square HIGH edge tracks pulseWidth", function()
  -- 1 cycle over [0,1], pw=0.25: LOW on [0,0.75), HIGH on [0.75,1).
  local pts = lfo.generate({ t0 = 0, t1 = 1 }, {
    shape = "square", rate = { mode = "free", cycles = 1 },
    amplitude = 1, baseline = 0, density = 2, pulseWidth = 0.25,
  })
  local function valueAt(t)
    for _, p in ipairs(pts) do if math.abs(p.time - t) < 1e-6 then return p.value end end
    return nil
  end
  h.almost(pts[1].value, -1, 1e-9)       -- starts LOW
  h.almost(valueAt(0.75), 1, 1e-9)       -- steps up exactly at (1-pw)
  h.eq(valueAt(0.5), nil)                -- no edge at 0.5 for a single cycle
end)

-- phase offset shifts the square edges in time but keeps it crisp (+1/-1 only) and bounded.
h.test("square with phase stays crisp and bounded", function()
  local pts = lfo.generate({ t0 = 0, t1 = 2 }, {
    shape = "square", rate = { mode = "free", cycles = 2 },
    amplitude = 40, baseline = 64, density = 2, phase = 0.25,
  })
  h.truthy(#pts >= 2)
  for _, p in ipairs(pts) do
    -- every value is either baseline+amp or baseline-amp (no in-between => crisp)
    local hi = math.abs(p.value - (64 + 40)) < 1e-6
    local lo = math.abs(p.value - (64 - 40)) < 1e-6
    h.truthy(hi or lo, "square value must be exactly high or low (crisp)")
  end
  h.almost(pts[1].time, 0)
end)

-- square respects global tilt (the right side drifts) while edges stay crisp steps.
h.test("square + tilt: starts low, right side drifts up, edges crisp", function()
  local pts = lfo.generate({ t0 = 0, t1 = 2 }, {
    shape = "square", rate = { mode = "free", cycles = 2 },
    amplitude = 40, baseline = 64, density = 2, tilt = 0.5,
  })
  -- first point (rel=0): LOW, no tilt offset -> 64-40 = 24 (native starts at the trough)
  h.almost(pts[1].value, 64 - 40, 1e-6)
  -- last point is the HIGH edge at rel 0.75 (t=1.5): 64 + 40 + (40*0.5)*0.75 = 119
  h.almost(pts[#pts].value, 64 + 40 + (40 * 0.5) * 0.75, 1e-6)
end)

-- A freqSkew-warped square stays CRISP (hard steps) on the explicit-edge emitter — the edges
-- warp in time but the values remain exactly high/low (the old behavior fell to the generic
-- sampler with an INVERTED waveform; the user-reported "square freq skew broken"). Edges must
-- also be non-uniformly spaced (the warp bunches them).
h.test("square with freqSkew stays crisp, bounded, and warped", function()
  local pts = lfo.generate({ t0 = 0, t1 = 2 }, {
    shape = "square", rate = { mode = "free", cycles = 2 },
    amplitude = 40, baseline = 64, density = 8, freqSkew = 0.5,
  })
  h.truthy(#pts >= 4, "explicit edges (LOW/HIGH per cycle) + start anchor")
  for _, p in ipairs(pts) do
    local hi = math.abs(p.value - (64 + 40)) < 1e-6
    local lo = math.abs(p.value - (64 - 40)) < 1e-6
    h.truthy(hi or lo, "value must stay exactly high or low (crisp) under freqSkew")
  end
  -- Warp => edge TIMES shift vs the un-skewed square (which has its first HIGH step at t=0.5).
  local function firstHigh(ps)
    for _, p in ipairs(ps) do if math.abs(p.value - 104) < 1e-6 then return p.time end end
  end
  local flat = lfo.generate({ t0 = 0, t1 = 2 }, {
    shape = "square", rate = { mode = "free", cycles = 2 },
    amplitude = 40, baseline = 64, density = 8, freqSkew = 0,
  })
  h.truthy(math.abs(firstHigh(pts) - firstHigh(flat)) > 1e-3, "freqSkew must warp the edge times")
end)

-- NATIVE per-point CC interpolation shapes (read from dumps CC30/CC31): Sine = slow start/end (2)
-- on every point; Parametric = fast end (4) at extrema, fast start (3) at the mid/zero-crossings.
h.test("native per-point shapes: sine=slow start/end, parametric=fast-end/fast-start", function()
  local sine = lfo.generate({ t0 = 0, t1 = 1 },
    { shape = "sine", rate = { mode = "free", cycles = 2 }, amplitude = 1, baseline = 0 })
  for _, p in ipairs(sine) do h.eq(p.shape, 2) end
  local para = lfo.generate({ t0 = 0, t1 = 1 },
    { shape = "parametric", rate = { mode = "free", cycles = 2 }, amplitude = 1, baseline = 0 })
  for _, p in ipairs(para) do
    if math.abs(math.abs(p.value) - 1) < 1e-6 then
      h.eq(p.shape, 4)                       -- extremum (value +/-1) -> fast end
    elseif math.abs(p.value) < 1e-6 then
      h.eq(p.shape, 3)                       -- mid/zero-cross (value 0) -> fast start
    end
  end
  -- triangle = linear, square = step, saw = linear:
  local tri = lfo.generate({ t0 = 0, t1 = 1 }, { shape = "triangle", rate = { mode = "free", cycles = 2 }, amplitude = 1, baseline = 0 })
  for _, p in ipairs(tri) do h.eq(p.shape, 1) end
  local sq = lfo.generate({ t0 = 0, t1 = 1 }, { shape = "square", rate = { mode = "free", cycles = 2 }, amplitude = 1, baseline = 0 })
  for _, p in ipairs(sq) do h.eq(p.shape, 0) end
end)

-- REGRESSION (phase + curve): the span-EDGE anchor's CC shape must follow the QUARTER it lands in as
-- phase shifts it across the waveform, not stay pinned to shapeFor(0). Parametric alternates fast-end
-- (4) on extrema-led quarters (0,2) and fast-start (3) on mid-led quarters (1,3), so the left edge's
-- shape MUST change with phase. Pinning it caused the user-reported "parametric curve changes form
-- once a point goes out of bounds": the edge flipped character whenever an interior sample crossed out.
h.test("parametric edge shape tracks phase (the quarter it lands in), not a fixed value", function()
  local function leftShape(phase)
    local pts = lfo.generate({ t0 = 0, t1 = 1 },
      { shape = "parametric", rate = { mode = "free", cycles = 2 }, amplitude = 1, baseline = 0, phase = phase })
    return pts[1].shape   -- pts[1] is the rel=0 edge anchor (smallest rel after the sort)
  end
  h.eq(leftShape(0),   4, "phase 0: left edge on the trough extremum -> fast end (4); native-unchanged")
  h.eq(leftShape(0.1), 3, "phase 0.1: edge at shape-phase 0.9 (mid-led quarter 3) -> fast start (3)")
  h.eq(leftShape(0.4), 4, "phase 0.4: edge at shape-phase 0.6 (extremum-led quarter 2) -> fast end (4)")
end)

-- Saw stays SPARSE under freqSkew (warped ramp, not densely sampled) — user-reported regression.
h.test("saw with freqSkew stays sparse and linear", function()
  local pts = lfo.generate({ t0 = 0, t1 = 1 },
    { shape = "saw", rate = { mode = "free", cycles = 2 }, amplitude = 1, baseline = 0, freqSkew = 0.5 })
  h.truthy(#pts <= 6, "saw must stay sparse under freqSkew (got " .. #pts .. ")")
  for _, p in ipairs(pts) do h.eq(p.shape, 1) end
  -- the middle reset boundary must have moved off the un-skewed 0.5 (warp applied):
  local flat = lfo.generate({ t0 = 0, t1 = 1 },
    { shape = "saw", rate = { mode = "free", cycles = 2 }, amplitude = 1, baseline = 0, freqSkew = 0 })
  h.truthy(math.abs(pts[2].time - flat[2].time) > 1e-3, "freqSkew must warp the saw boundary")
end)

-- Saw RESPONDS to swing (the reset boundary shuffles long-short) while staying SPARSE — the user
-- reported swing stopped affecting saw after it was made warp-aware.
h.test("saw with swing stays sparse and shifts the reset boundary", function()
  local base = { shape = "saw", rate = { mode = "free", cycles = 2 }, amplitude = 1, baseline = 0 }
  local flat = lfo.generate({ t0 = 0, t1 = 1 }, base)
  local sw = {}; for k, v in pairs(base) do sw[k] = v end; sw.swing = 0.5
  local swung = lfo.generate({ t0 = 0, t1 = 1 }, sw)
  h.truthy(#swung <= 6, "saw stays sparse under swing (got " .. #swung .. ")")
  -- pts[2] is the first peak (reset boundary); swing must move it off 0.5.
  h.truthy(math.abs(swung[2].time - flat[2].time) > 1e-3, "swing must shift the saw boundary")
end)

-- Saw swing is SYMMETRIC for +/- on an ODD cycle count. A negative swing used to pull the j==N
-- reset (which coincides with the span end) below the boundary and emit a spurious extra partial
-- ramp that positive swing didn't — an asymmetry only visible on odd cycle counts. +0.7 and -0.7
-- must now yield the same number of reset/peak points (and the same total point count).
h.test("saw swing +/- symmetric reset count on odd cycles", function()
  local function peaks(sw)
    local pts = lfo.generate({ t0 = 0, t1 = 3 },
      { shape = "saw", rate = { mode = "free", cycles = 3 }, amplitude = 1, baseline = 0, swing = sw })
    local n = 0
    for _, p in ipairs(pts) do if math.abs(p.value - 1) < 1e-9 then n = n + 1 end end
    return #pts, n
  end
  local totPos, peakPos = peaks(0.7)
  local totNeg, peakNeg = peaks(-0.7)
  h.eq(peakNeg, peakPos, "+/- swing must emit the same number of peak/reset points on odd cycles")
  h.eq(totNeg, totPos, "+/- swing must emit the same total point count on odd cycles")
end)

-- Random (S&H): one value per cycle, held flat (step CC shape 0); values differ non-monotonically.
h.test("random S&H: per-cycle held random values, step shape", function()
  local pts = lfo.generate({ t0 = 0, t1 = 4 },
    { shape = "random", rate = { mode = "free", cycles = 4 }, amplitude = 1, baseline = 0, seed = 7 })
  h.truthy(#pts >= 4, "at least one point per cycle")
  for _, p in ipairs(pts) do h.eq(p.shape, 0, "S&H uses step interpolation") end
  -- not a monotonic ramp: at least one direction change across the cycle values
  local ups, downs = 0, 0
  for i = 2, #pts do if pts[i].value > pts[i-1].value then ups = ups + 1 elseif pts[i].value < pts[i-1].value then downs = downs + 1 end end
  h.truthy(ups > 0 and downs > 0, "random should go both up and down")
end)

-- Drift: same per-cycle random targets as Random, but smooth (slow start/end CC shape 2).
h.test("drift: smooth-interp random (slow shape)", function()
  local r = lfo.generate({ t0 = 0, t1 = 4 },
    { shape = "random", rate = { mode = "free", cycles = 4 }, amplitude = 1, baseline = 0, seed = 7 })
  local d = lfo.generate({ t0 = 0, t1 = 4 },
    { shape = "drift",  rate = { mode = "free", cycles = 4 }, amplitude = 1, baseline = 0, seed = 7 })
  for _, p in ipairs(d) do h.eq(p.shape, 2, "drift uses slow start/end interpolation") end
  -- same seed => the per-cycle anchor values match Random's (first 4 cycle starts)
  for i = 1, 4 do h.almost(d[i].value, r[i].value, 1e-9) end
end)

-- Saw Down: descending ramp, SPARSE like Saw Up (dedicated emitter, not the dense sampler).
h.test("saw down is sparse and descends", function()
  local pts = lfo.generate({ t0 = 0, t1 = 4 },
    { shape = "sawdown", rate = { mode = "free", cycles = 4 }, amplitude = 1, baseline = 0 })
  h.truthy(#pts <= 12, "saw down must be sparse (got " .. #pts .. ")")
  for _, p in ipairs(pts) do h.eq(p.shape, 1, "linear ramp") end
  h.almost(pts[1].value, 1, 1e-9)              -- starts at the peak, descends from there
  h.almost(pts[#pts].value, -1, 1e-9)          -- ends at the trough (integer cycles)
end)

-- Trapezoid: SPARSE 4-corner emitter (points only at +/-1 corners; ramps are interpolated).
h.test("trapezoid is sparse with corner values", function()
  local pts = lfo.generate({ t0 = 0, t1 = 4 },
    { shape = "trapezoid", rate = { mode = "free", cycles = 4 }, amplitude = 1, baseline = 0, edge = 0.25 })
  h.truthy(#pts <= 24, "trapezoid must be sparse (got " .. #pts .. ")")
  for _, p in ipairs(pts) do
    h.eq(p.shape, 1, "linear segments")
    h.truthy(math.abs(math.abs(p.value) - 1) < 1e-9, "only +/-1 corner values")
  end
end)

-- Sine2: anchored + SPARSE (4 samples/cycle, values -1,0,+1,0 like parametric) with SLOW start/end
-- (shape 2) on EVERY point. The s^2 curve has a flat tangent at all four quarter points, so flat-
-- ended S-curves between them read as a smooth, centre-flattened sine (not a spike, not a triangle).
h.test("sine2 is sparse and smoothly eased (no spike)", function()
  local pts = lfo.generate({ t0 = 0, t1 = 2 },
    { shape = "sine2", rate = { mode = "free", cycles = 2 }, amplitude = 1, baseline = 0 })
  h.truthy(#pts <= 12, "sine2 must be sparse (got " .. #pts .. ")")
  for _, p in ipairs(pts) do h.eq(p.shape, 2, "every sine2 point uses slow start/end") end
end)

-- Rectified sine: sparse |sin| humps. Cusps (value -1) get fast START (3) so they leave the sharp
-- bottom steeply and round into the peak; peaks (value +1) get fast END (4). Two humps per cycle.
h.test("rectsine is sparse with rounded-hump eases (crisp cusps)", function()
  local pts = lfo.generate({ t0 = 0, t1 = 2 },
    { shape = "rectsine", rate = { mode = "free", cycles = 2 }, amplitude = 1, baseline = 0 })
  h.truthy(#pts <= 12, "rectsine must be sparse (got " .. #pts .. ")")
  local cusps, peaks = 0, 0
  for _, p in ipairs(pts) do
    if math.abs(p.value - (-1)) < 1e-6 then h.eq(p.shape, 3, "cusp -> fast start"); cusps = cusps + 1
    elseif math.abs(p.value - 1) < 1e-6 then h.eq(p.shape, 4, "peak -> fast end"); peaks = peaks + 1 end
  end
  h.truthy(cusps >= 2 and peaks >= 2, "two humps per cycle (got cusps=" .. cusps .. " peaks=" .. peaks .. ")")
end)

-- Trapezoid (and rectsine) honor Phase: shifting phase moves the waveform, so the value at the span
-- start changes. (Was a no-op: the sparse emitters ignored phase entirely.)
h.test("trapezoid honors phase", function()
  local function startVal(ph)
    local pts = lfo.generate({ t0 = 0, t1 = 4 }, { shape = "trapezoid",
      rate = { mode = "free", cycles = 4 }, amplitude = 1, baseline = 0, edge = 0.25, phase = ph })
    return pts[1].value
  end
  h.truthy(math.abs(startVal(0) - startVal(0.5)) > 0.5, "phase 0.5 should shift the trapezoid start value")
end)

-- Saw (and Saw Down) honor Phase: shifting phase moves the ramp, changing the span-start value.
-- Phase 0 stays byte-identical to the native saw (guarded by test_native_match).
h.test("saw honors phase", function()
  local function startVal(shape, ph)
    local pts = lfo.generate({ t0 = 0, t1 = 4 }, { shape = shape,
      rate = { mode = "free", cycles = 4 }, amplitude = 1, baseline = 0, phase = ph })
    return pts[1].value
  end
  h.truthy(math.abs(startVal("saw", 0) - startVal("saw", 0.5)) > 0.5, "saw phase 0.5 shifts the start value")
  h.truthy(math.abs(startVal("sawdown", 0) - startVal("sawdown", 0.5)) > 0.5, "saw down phase shifts too")
end)

-- Steps/Smooth must NOT shift a shape's phase: routing triangle/square to the generic sampler now
-- starts at the SAME value as the dedicated emitter (was the user-reported "out of phase" / flip bug).
h.test("steps/smooth preserve triangle & square phase", function()
  local function startVal(shape, mods)
    local p = { shape = shape, rate = { mode = "free", cycles = 4 }, amplitude = 1, baseline = 0 }
    for k, v in pairs(mods or {}) do p[k] = v end
    return lfo.generate({ t0 = 0, t1 = 4 }, p)[1].value
  end
  h.almost(startVal("triangle", {}), startVal("triangle", { smooth = 0.5 }), 1e-6, "triangle smooth phase")
  h.almost(startVal("triangle", {}), startVal("triangle", { quantizeSteps = 4 }), 1e-6, "triangle steps phase")
  h.almost(startVal("square", {}),   startVal("square",   { smooth = 0.5 }), 1e-6, "square smooth phase flip")
end)

-- Trapezoid (and rectsine) now respond to Swing and Freq skew: corner TIMES warp, point count stable.
h.test("trapezoid responds to swing and freq skew", function()
  local function times(mods)
    local p = { shape = "trapezoid", rate = { mode = "free", cycles = 4 }, amplitude = 1, baseline = 0, edge = 0.25 }
    for k, v in pairs(mods) do p[k] = v end
    local t = {}; for _, pp in ipairs(lfo.generate({ t0 = 0, t1 = 4 }, p)) do t[#t + 1] = pp.time end
    return t
  end
  local plain, swung, skewed = times({}), times({ swing = 0.6 }), times({ freqSkew = 0.6 })
  h.eq(#swung, #plain, "swing keeps trapezoid point count")
  h.eq(#skewed, #plain, "freq skew keeps trapezoid point count")
  local function moved(a, b) for i = 1, #a do if math.abs(a[i] - b[i]) > 1e-6 then return true end end return false end
  h.truthy(moved(plain, swung), "swing should move trapezoid corner times")
  h.truthy(moved(plain, skewed), "freq skew should move trapezoid corner times")
end)

-- Steps now quantizes a Saw into a real staircase: values collapse to ~N levels and the density is
-- bumped so each level shows (previously Steps was a no-op on saw).
h.test("steps quantizes a saw into a staircase", function()
  local pts = lfo.generate({ t0 = 0, t1 = 2 },
    { shape = "saw", rate = { mode = "free", cycles = 2 }, amplitude = 1, baseline = 0, quantizeSteps = 4 })
  h.truthy(#pts >= 16, "stepped saw is densely sampled (got " .. #pts .. ")")
  local levels = {}
  for _, p in ipairs(pts) do levels[string.format("%.4f", p.value)] = true end
  local n = 0; for _ in pairs(levels) do n = n + 1 end
  h.truthy(n <= 4, "saw values quantized to <= 4 levels (got " .. n .. ")")
end)

-- Smooth now rounds a Square toward a sine: values land strictly inside (-1,+1), not only +/-1, and
-- the density is bumped so the curve is clean.
h.test("smooth rounds a square", function()
  local pts = lfo.generate({ t0 = 0, t1 = 2 },
    { shape = "square", rate = { mode = "free", cycles = 2 }, amplitude = 1, baseline = 0, smooth = 1 })
  h.truthy(#pts >= 16, "smoothed square is densely sampled (got " .. #pts .. ")")
  local mid = false
  for _, p in ipairs(pts) do if math.abs(p.value) < 0.9 then mid = true; break end end
  h.truthy(mid, "smoothed square should have intermediate values")
end)

-- Saw Curve: the RAMP bends (bezier), the RESET stays instant (linear). Curve 0 = native saw.
h.test("saw curve bends the ramp, reset stays linear", function()
  local function gen(curve)
    return lfo.generate({ t0 = 0, t1 = 4 },
      { shape = "saw", rate = { mode = "free", cycles = 4 }, amplitude = 1, baseline = 0, curve = curve })
  end
  for _, p in ipairs(gen(0)) do h.eq(p.shape, 1, "curve 0 -> all linear") end
  local hasBez, peaksLinear = false, true
  for _, p in ipairs(gen(60)) do
    if math.abs(p.value - (-1)) < 1e-6 then               -- ramp-start (trough)
      if p.shape == 5 and (p.tension or 0) > 0 then hasBez = true end
    elseif math.abs(p.value - 1) < 1e-6 then               -- peak (reset point)
      if p.shape ~= 1 then peaksLinear = false end
    end
  end
  h.truthy(hasBez, "ramp-start points should be bezier with +tension")
  h.truthy(peaksLinear, "peak points stay linear (instant reset)")
end)

-- Curve must not change the point count (no densify) and works for saw down too.
h.test("saw curve keeps point count; saw down curves as well", function()
  local function gen(shape, curve)
    return lfo.generate({ t0 = 0, t1 = 4 },
      { shape = shape, rate = { mode = "free", cycles = 4 }, amplitude = 1, baseline = 0, curve = curve })
  end
  h.eq(#gen("saw", 0), #gen("saw", 60), "curve must not change saw point count")
  local bez = false
  for _, p in ipairs(gen("sawdown", -60)) do if p.shape == 5 and (p.tension or 0) < 0 then bez = true end end
  h.truthy(bez, "saw down curve -> bezier points with -tension")
end)

-- Triangle Attack moves the peak; Attack 50 + Curve 0 = today's native triangle (all linear).
h.test("triangle attack moves the peak; default stays linear", function()
  local def = lfo.generate({ t0 = 0, t1 = 1 },
    { shape = "triangle", rate = { mode = "free", cycles = 1 }, amplitude = 1, baseline = 0 })
  for _, p in ipairs(def) do h.eq(p.shape, 1, "default triangle is linear"); h.eq(p.tension or 0, 0, "default triangle tension 0") end
  local function peakTime(attack)
    local pts = lfo.generate({ t0 = 0, t1 = 1 },
      { shape = "triangle", rate = { mode = "free", cycles = 1 }, amplitude = 1, baseline = 0, attack = attack })
    for _, p in ipairs(pts) do if math.abs(p.value - 1) < 1e-6 then return p.time end end
  end
  h.almost(peakTime(50), 0.5, 1e-6, "attack 50 -> peak at mid")
  h.almost(peakTime(25), 0.25, 1e-6, "attack 25 -> peak at quarter")
end)

-- Triangle Curve bends the rise/fall via bezier.
h.test("triangle curve bends the segments (bezier)", function()
  local pts = lfo.generate({ t0 = 0, t1 = 1 },
    { shape = "triangle", rate = { mode = "free", cycles = 1 }, amplitude = 1, baseline = 0, curve = 60 })
  local bez = false
  for _, p in ipairs(pts) do if p.shape == 5 and (p.tension or 0) > 0 then bez = true end end
  h.truthy(bez, "triangle curve -> bezier points with +tension")
end)

-- A stale non-zero Curve must NOT leak onto non-triangle anchored shapes (sine/parametric/sine2):
-- their points always carry tension 0.
h.test("curve does not leak tension onto non-triangle anchored shapes", function()
  for _, shape in ipairs({ "sine", "parametric", "sine2" }) do
    local pts = lfo.generate({ t0 = 0, t1 = 2 },
      { shape = shape, rate = { mode = "free", cycles = 2 }, amplitude = 1, baseline = 0, curve = 60 })
    for _, p in ipairs(pts) do h.eq(p.tension or 0, 0, shape .. " must emit tension 0") end
  end
end)

-- Triangle Curve is bipolar: negative curve -> bezier with negative tension.
h.test("triangle negative curve -> bezier with -tension", function()
  local pts = lfo.generate({ t0 = 0, t1 = 1 },
    { shape = "triangle", rate = { mode = "free", cycles = 1 }, amplitude = 1, baseline = 0, curve = -60 })
  local neg = false
  for _, p in ipairs(pts) do if p.shape == 5 and (p.tension or 0) < 0 then neg = true end end
  h.truthy(neg, "triangle curve -60 -> bezier points with negative tension")
end)

-- Triangle ignores Swing (its Attack is the peak control). Swing must not move triangle points.
h.test("triangle ignores swing", function()
  local function gen(sw)
    return lfo.generate({ t0 = 0, t1 = 4 },
      { shape = "triangle", rate = { mode = "free", cycles = 4 }, amplitude = 1, baseline = 0, swing = sw })
  end
  local a, b = gen(0), gen(0.6)
  h.eq(#a, #b, "swing must not change triangle point count")
  for i = 1, #a do h.almost(a[i].time, b[i].time, 1e-9, "swing must not move triangle points") end
end)

-- Steps routes triangle to the generic sampler, which now honors Attack: the peak stays near the
-- attack fraction (not snapped back to the symmetric 0.5) -> no jump when engaging Steps.
h.test("steps on triangle preserves the attack peak", function()
  local pts = lfo.generate({ t0 = 0, t1 = 4 }, { shape = "triangle",
    rate = { mode = "free", cycles = 4 }, amplitude = 1, baseline = 0, attack = 20, quantizeSteps = 8 })
  local bestT, bestV = nil, -2
  for _, p in ipairs(pts) do if p.time < 1 and p.value > bestV then bestV, bestT = p.value, p.time end end
  h.truthy(bestT ~= nil and bestT < 0.35, "stepped triangle peak should sit near attack 0.2, got " .. tostring(bestT))
end)

-- swingWarpInverse is the exact inverse of swingWarp (so the generic path swings the same way the
-- sparse anchored emitters do).
h.test("swingWarpInverse inverts swingWarp", function()
  for _, sw in ipairs({ -0.7, -0.3, 0, 0.3, 0.6, 1.0 }) do
    for _, sp in ipairs({ 0, 0.2, 0.5, 0.7, 0.99 }) do
      h.almost(lfo.swingWarpInverse(lfo.swingWarp(sp, sw), sw), sp, 1e-9)
    end
  end
end)

-- The generic (Steps/Smooth) sampler swings the sine family with the PER-CYCLE swingWarp model, not
-- the pair-based one — so toggling Smooth on a swung sine doesn't jump. (smooth=1 on a sine is value-
-- identical to no smooth; it just forces the generic path.) Check a sample in the SECOND half of a
-- cycle, where the two swing models diverge.
h.test("generic swing uses the per-cycle model for the sine family", function()
  local swing = 0.6
  local pts = lfo.generate({ t0 = 0, t1 = 4 }, { shape = "sine", rate = { mode = "free", cycles = 4 },
    amplitude = 1, baseline = 0, swing = swing, smooth = 1, density = 64 })
  local best, bd = nil, 1e9
  for _, p in ipairs(pts) do local d = math.abs(p.time - 0.9); if d < bd then bd, best = d, p end end
  local cp0 = best.time                      -- cycles=4 over [0,4], no freq skew => cp0 == time
  local frac = cp0 - math.floor(cp0)
  local expected = -math.cos(2 * math.pi * lfo.swingWarpInverse(frac, swing))
  h.almost(best.value, expected, 1e-6, "generic sine swing must follow swingWarpInverse")
end)

-- freqWarp / freqWarpInverse round-trip and anchor checks.
h.test("freqWarp/freqWarpInverse round-trip: inverse(warp(prog, s_f)) == prog", function()
  local skews  = { -1, -0.5, 0, 1e-6, 0.3, 1 }
  local progs  = { 0, 0.1, 0.2, 0.3, 0.4, 0.5, 0.6, 0.7, 0.8, 0.9, 1.0 }
  for _, s_f in ipairs(skews) do
    for _, prog in ipairs(progs) do
      local rel  = lfo.freqWarpInverse(prog, s_f)
      local back = lfo.freqWarp(rel, s_f)
      h.almost(back, prog, 1e-9, "round-trip s_f=" .. s_f .. " prog=" .. prog)
    end
  end
end)

h.test("freqWarp/freqWarpInverse: anchors at 0 and 1 for any s_f", function()
  for _, s_f in ipairs({ -1, -0.5, 0, 0.3, 1 }) do
    h.almost(lfo.freqWarp(0, s_f), 0, 1e-12, "freqWarp(0,s_f) anchor s_f=" .. s_f)
    h.almost(lfo.freqWarp(1, s_f), 1, 1e-12, "freqWarp(1,s_f) anchor s_f=" .. s_f)
    h.almost(lfo.freqWarpInverse(0, s_f), 0, 1e-12, "freqWarpInverse(0,s_f) anchor s_f=" .. s_f)
    h.almost(lfo.freqWarpInverse(1, s_f), 1, 1e-12, "freqWarpInverse(1,s_f) anchor s_f=" .. s_f)
  end
end)

h.test("freqWarp identity when s_f==0", function()
  for _, prog in ipairs({ 0, 0.25, 0.5, 0.75, 1.0 }) do
    h.almost(lfo.freqWarp(prog, 0), prog, 1e-12, "freqWarp identity at s_f=0, prog=" .. prog)
  end
end)

h.run()
