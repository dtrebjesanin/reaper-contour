-- core/lfo.lua — pure composition of shapes into {time,value} points. No Reaper, no I/O.
local M = {}
local floor, ceil, min, max, abs = math.floor, math.ceil, math.min, math.max, math.abs
local cos, pi, sqrt = math.cos, math.pi, math.sqrt
local shapes = require("core.shapes")

function M.cycleLength(rate, spanLen)
  if rate.mode == "free" then
    return spanLen / max(1e-9, rate.cycles)
  elseif rate.mode == "hz" then
    return 1 / max(1e-9, rate.hz)
  elseif rate.mode == "sync" then
    if not rate.cycleSec then error("sync rate requires a precomputed cycleSec") end
    return rate.cycleSec
  end
  error("unknown rate mode: " .. tostring(rate.mode))
end

-- NATIVE MUSICAL RATE: REAPER's CC LFO sets the period from a Length note value (× a
-- straight/triplet/dotted modifier) and a Frequency multiplier. Empirically (verified to the
-- integer against the CC27-30 frequency sweep and CC36-37 length sweep, all at a 2-bar / 8-QN
-- selection): period = 8 * (lengthFrac * modeMult) / frequency QUARTER NOTES per cycle. Pure
-- arithmetic; the Reaper layer converts QN->seconds via the tempo map. Examples (8 QN selection):
--   length 1/4, freq 1/2 -> 4 QN/cycle -> 2 cycles ; freq 1 -> 2 QN -> 4 cycles ;
--   length 1/2, freq 1/2 -> 8 QN -> 1 cycle ; length 1/8, freq 1/2 -> 2 QN -> 4 cycles.
function M.musicalBeatsPerCycle(lengthFrac, modeMult, freq)
  if not lengthFrac or lengthFrac <= 0 then lengthFrac = 0.25 end
  if not modeMult or modeMult <= 0 then modeMult = 1 end
  if not freq or freq <= 0 then freq = 1 end
  return 8 * lengthFrac * modeMult / freq
end

function M.quantizeBipolar(v, steps)
  if not steps or steps < 2 then return v end
  local level = floor(((v + 1) / 2) * (steps - 1) + 0.5)
  return (level / (steps - 1)) * 2 - 1
end

-- Swing warps the PAIRING of consecutive cycles for a long-short shuffle feel.
-- It is a pure transform on the continuous cycle position (cyclePos), applied
-- *before* flooring into a cycle index, so each cycle's internal waveform is
-- unchanged in shape — only WHERE each cycle begins/ends in time shifts.
--
-- swing in [-1, 1], default 0. 0 = no change (bit-identical to omitting swing).
--
-- Formula (pair-local position):
--   Treat cycles in pairs. For a continuous cyclePos:
--     pair      = floor(cyclePos / 2)
--     posInPair = cyclePos - pair*2          -- in [0, 2)
--   The boundary between the two cycles of the pair (normally at 1) is moved
--   away from the midpoint by swing:
--     boundary  = 1 + swing*0.5              -- in [0.5, 1.5] for swing in [-1,1]
--   The first cycle occupies pair-local [0, boundary) and is mapped onto its
--   normal slot [0, 1); the second occupies [boundary, 2) and is mapped onto
--   [1, 2). This stretches the first cycle and compresses the second (or vice
--   versa for swing<0) while the pair still spans the same two-cycle duration:
--     if posInPair < boundary:               -- first (warped) cycle
--       warped = posInPair / boundary
--     else:                                  -- second (warped) cycle
--       warped = 1 + (posInPair - boundary) / (2 - boundary)
--     out = pair*2 + warped
--   At swing=0, boundary=1, so warped == posInPair in both branches and
--   out == cyclePos exactly (no floating-point change).
function M.swingCyclePos(cyclePos, swing)
  if not swing or swing == 0 then return cyclePos end
  -- Clamp to the documented domain so an out-of-range external caller can't drive
  -- boundary to 0 or 2 (divide-by-zero). Identity for swing in [-1,1], so behavior
  -- for valid inputs (including the swing=0 fast path above) is unchanged.
  swing = max(-1, min(1, swing))
  local pair = floor(cyclePos / 2)
  local posInPair = cyclePos - pair * 2
  local boundary = 1 + swing * 0.5
  local warped
  if posInPair < boundary then
    warped = posInPair / boundary
  else
    warped = 1 + (posInPair - boundary) / (2 - boundary)
  end
  return pair * 2 + warped
end

function M.fadeDepth(rel, fadeIn, fadeOut)
  local d = 1
  if fadeIn and fadeIn > 0 and rel < fadeIn then d = min(d, rel / fadeIn) end
  if fadeOut and fadeOut > 0 and rel > 1 - fadeOut then d = min(d, (1 - rel) / fadeOut) end
  if d < 0 then d = 0 end
  return d
end

-- ===========================================================================
-- NATIVE CC LFO MODEL (Generate v2.4) — global modulators, range-agnostic.
--
-- The engine reproduces REAPER's native CC LFO. All modulators are GLOBAL across
-- the selection (NOT per-cycle). Everything is in VALUE UNITS (e.g. CC 0..127) so
-- the core stays range-agnostic: the UI converts its % sliders to value units
-- (center, half-amplitude, value-unit tilt offset) before calling generate.
--
-- For a point at time-fraction rel in [0,1] across the selection:
--   center             baseline value (e.g. CC 63.5 = MID for baseline 0%)
--   baseHalf           half-swing in value units (e.g. 31.75 for amplitude 50%)
--   AMP SKEW (s_a in [-1,1], anchored global amplitude ramp):
--     leftHalf  = baseHalf*(1 - max(0,  s_a))
--     rightHalf = baseHalf*(1 - max(0, -s_a))
--     half(rel) = leftHalf + (rightHalf-leftHalf)*rel
--   TILT (value-unit, anchored left, applied *rel):
--     tiltOffset(rel) = tiltOffset * rel
--   FREQ SKEW (s_f in [-1,1], global phase time-warp) — EXACT QUADRATIC, verified to the
--   integer from native dumps (CC18 +50, CC19 -50, D4 +100, D5 -100):
--     rel(prog) = prog + s_f*prog*(1-prog)          (phase-progress prog -> time-fraction rel)
--   At s_f=+1 => rel = 1-(1-prog)^2 (cycles bunch toward the right); s_f=-1 => rel = prog^2
--   (bunch toward the left). prog(0)=rel 0, prog(1)=rel 1: total cycle count is preserved.
--   (Earlier builds used a power law e=1-0.5|s_f|; it only coincided with native at ±100 and
--   was wrong at intermediate values — CC18's +50 peak is at exactly rel 0.3438, the quadratic.)
--   value(rel) = center + half(rel)*shape(phase(rel)) + tiltOffset(rel)
-- Core does NOT clamp or floor: the Reaper write layer clamps to [vmin,vmax] and
-- FLOORs (native truncates). Headless tests floor+clamp to compare to the dumps.

-- freqWarpInverse: phase-progress prog -> time-fraction rel. Used to PLACE extrema.
-- This is the closed-form native warp; identity at s_f=0.
function M.freqWarpInverse(prog, s_f)
  if not s_f or s_f == 0 then return prog end
  s_f = max(-1, min(1, s_f))
  return prog + s_f * prog * (1 - prog)
end

-- freqWarp: time-fraction rel -> phase-progress prog (inverse of freqWarpInverse). Used by
-- the generic dense sampler. Invert rel = prog*(1+s_f) - s_f*prog^2 via the quadratic formula:
--   s_f*prog^2 - (1+s_f)*prog + rel = 0  ->  prog = ((1+s_f) - sqrt((1+s_f)^2 - 4*s_f*rel))/(2*s_f)
function M.freqWarp(rel, s_f)
  if not s_f or abs(s_f) < 1e-12 then return rel end   -- guard tiny |s_f|, not just exact 0
  s_f = max(-1, min(1, s_f))
  local disc = (1 + s_f) ^ 2 - 4 * s_f * rel
  if disc < 0 then disc = 0 end
  -- Numerically stable conjugate form of ((1+s_f)-sqrt(disc))/(2*s_f): the direct form divides
  -- by a tiny 2*s_f for small skew (ill-conditioned, can overflow before clamping). This form
  -- has no small denominator and yields prog -> rel as s_f -> 0.
  local prog = (2 * rel) / ((1 + s_f) + sqrt(disc))
  if prog < 0 then prog = 0 elseif prog > 1 then prog = 1 end
  return prog
end

-- half(rel): global amplitude ramp anchored by amp skew s_a in [-1,1].
local function ampHalf(baseHalf, s_a, rel)
  if not s_a or s_a == 0 then return baseHalf end
  s_a = max(-1, min(1, s_a))
  local leftHalf = baseHalf * (1 - max(0, s_a))
  local rightHalf = baseHalf * (1 - max(0, -s_a))
  return leftHalf + (rightHalf - leftHalf) * rel
end

-- ===========================================================================
-- ANCHORED native shapes: SINE / TRIANGLE / PARAMETRIC.
-- These three share the SAME extremum/anchor placement and differ only in (a) sample
-- DENSITY — parametric also samples the quarter-phases (4 pts/cycle) — and (b) the CC
-- interpolation flag the Reaper write layer applies (sine/parametric=bezier, triangle=
-- linear). Native CC1 (sine) and CC2 (triangle) dumps are byte-identical for this reason.
--
-- A point sits at every waveform sample-phase sp (sine/triangle: {0=trough, 0.5=peak};
-- parametric: {0, 0.25, 0.5, 0.75}). The emitted value is:
--   center + half(rel)*(-cos(2*pi*sp))*depth + tiltOffset*rel
-- where half(rel) carries the global amp-skew ramp and tiltOffset is value-unit (applied
-- *rel, fade-independent). Modulators:
--   * PHASE shifts the waveform RIGHT by `phase` cycles (native DELAYS for +phase) and
--     adds anchor points at rel=0 and rel=1 (native always anchors the span edges).
--   * FREQ SKEW time-warps each sample via freqWarpInverse (the exact quadratic).
--   * SWING (intra-cycle): the mid-cycle sample (sp=0.5) moves to cycle-fraction
--     0.5 + swing*0.25, piecewise-linear, with cycle boundaries fixed (matches CC22-24).
local function emitAnchored(shape, t0, t1, spanLen, totalCycles, p, amp, baseV, ampSkew, freqSkew, tiltOffset)
  local phase = p.phase or 0
  local swing = max(-1, min(1, p.swing or 0))
  local N = totalCycles
  local sampleSet = (shape == "parametric" or shape == "sine2") and { 0, 0.25, 0.5, 0.75 } or { 0, 0.5 }

  local function valueAt(rel, sv)
    local depth = M.fadeDepth(rel, p.fadeIn, p.fadeOut)
    local half = ampHalf(amp, ampSkew, rel)
    return baseV + half * sv * depth + tiltOffset * rel
  end

  -- Per-point CC interpolation shape (int), read from native dumps CC30/CC31:
  --   sine       -> slow start/end (2) on EVERY point: the S-curve draws a true sine through the
  --                 2-pts/cycle extrema.
  --   triangle   -> linear (1): straight segments between the same extrema.
  --   parametric -> fast end (4) at the extrema (sp 0/0.5), fast start (3) at the mid/zero-cross
  --                 points (sp 0.25/0.75). The alternating eases give each quarter-cycle the
  --                 correct sine curvature (flat at the extremes, steep at the crossings) — far
  --                 more prominent than a tension-0 bezier (the user-reported "not prominent").
  local function shapeFor(sp)
    if shape == "triangle" then return 1 end
    if shape == "parametric" then
      local ext = (sp < 1e-9) or (abs(sp - 0.5) < 1e-9)
      return ext and 4 or 3
    end
    if shape == "sine2" then
      -- Sine² (peakier sine): same -cos anchors as parametric (-1,0,+1,0 at the quarter phases) but
      -- SLOW start/end on EVERY point. The s^2 curve has a flat tangent at all four (slope 0 at the
      -- extrema AND the zero-crossings), so flat-ended S-curves between them read as a smooth, centre-
      -- flattened sine -- NOT the spike that fast eases produced.
      return 2
    end
    return 2
  end

  -- Swing warps an intra-cycle sample-phase sp -> g(sp): the sp=0.5 point moves to
  -- m = 0.5 + swing*0.25; each half maps linearly. Identity when swing=0.
  local function swingWarp(sp)
    if swing == 0 then return sp end
    local m = 0.5 + swing * 0.25
    if sp <= 0.5 then return sp * (m / 0.5) end
    return m + (sp - 0.5) * ((1 - m) / 0.5)
  end

  -- Collect {rel, sv, shp}. A sample at phase position pp = c + g(sp) has time-progress
  -- prog = (pp + phase)/N which must lie in the OPEN (0,1) (the 0/1 edges are anchors).
  local samp = {}
  for c = floor(-phase) - 1, ceil(N) + 1 do
    for _, sp in ipairs(sampleSet) do
      local prog = (c + swingWarp(sp) + phase) / N
      if prog > 1e-9 and prog < 1 - 1e-9 then
        samp[#samp + 1] = { rel = M.freqWarpInverse(prog, freqSkew), sv = -cos(2 * pi * sp), shp = shapeFor(sp) }
      end
    end
  end
  -- Span-edge anchors (troughs/extrema). warpInverse(0)=0, warpInverse(1)=1, so the shape-phase
  -- at the edges is -phase (rel 0) and N-phase (rel 1); value = -cos(2*pi*shapePhase).
  samp[#samp + 1] = { rel = 0, sv = -cos(2 * pi * (-phase)), shp = shapeFor(0) }
  samp[#samp + 1] = { rel = 1, sv = -cos(2 * pi * (N - phase)), shp = shapeFor(0) }

  table.sort(samp, function(a, b) return a.rel < b.rel end)

  local pts, lastRel = {}, nil
  for _, s in ipairs(samp) do
    if lastRel == nil or s.rel - lastRel > 1e-6 then
      pts[#pts + 1] = { time = t0 + s.rel * spanLen, value = valueAt(s.rel, s.sv), shape = s.shp }
      lastRel = s.rel
    end
  end
  return pts
end

-- Explicit-edge SQUARE emitter. NATIVE MATCH: a default square (phase 0, pw 0.5) starts LOW at
-- the cycle start and steps UP to HIGH at cycle-fraction (1 - pulseWidth) — the HIGH portion is
-- the LAST pw of each cycle (native CC4 starts at the trough; our old emitter started HIGH, the
-- user-reported bug). The step CC shape holds each value FORWARD, so NO trailing point at t1 is
-- emitted (the last edge holds to the end).
--
-- Edges are placed by the SAME phase->time mapping as emitAnchored, so the square honors PHASE,
-- FREQ SKEW (edges warp via freqWarpInverse) and SWING (the HIGH step-up edge shifts like a sine
-- peak). This keeps the square crisp + correctly-phased under freq skew instead of falling to the
-- generic sampler, which used an INVERTED waveform (the user-reported "square freq skew broken").
-- Only smooth/quantize route a square elsewhere. ppq is value-model aware (amp-skew half, tilt).
local function generateSquare(t0, t1, spanLen, totalCycles, p, amp, baseV, ampSkew, freqSkew, tiltOffset)
  local phase = p.phase or 0
  local swing = max(-1, min(1, p.swing or 0))
  local pw = p.pulseWidth or 0.5
  if pw < 0 then pw = 0 elseif pw > 1 then pw = 1 end
  local hi = 1 - pw                            -- HIGH begins at cycle-fraction (1-pw)
  local N = totalCycles

  local function valueAt(rel, sv)
    sv = M.quantizeBipolar(sv, p.quantizeSteps)
    local depth = M.fadeDepth(rel, p.fadeIn, p.fadeOut)
    local half = ampHalf(amp, ampSkew, rel)
    return baseV + half * sv * depth + tiltOffset * rel
  end
  -- Swing shifts the HIGH (step-up) edge like the sine peak: cycle-fraction 0.5 -> 0.5+swing*0.25,
  -- piecewise-linear; cycle starts (sp=0) are unmoved.
  local function swingWarp(sp)
    if swing == 0 then return sp end
    local m = 0.5 + swing * 0.25
    if sp <= 0.5 then return sp * (m / 0.5) end
    return m + (sp - 0.5) * ((1 - m) / 0.5)
  end
  -- Value the step holds at fractional shape-phase x: LOW in [0,hi), HIGH in [hi,1).
  local function heldValue(x) local f = x - floor(x); return (f < hi - 1e-9) and -1 or 1 end

  -- Edges: LOW at each cycle start (sp=0), HIGH at sp=hi. An edge at shape-phase (k+sp) has
  -- prog = (k + swingWarp(sp) + phase)/N -> rel = freqWarpInverse(prog) (open interval; rel 0 is
  -- the held-value anchor; the step holds to t1 so there is no rel=1 point).
  local samp = {}
  for k = floor(-phase) - 1, ceil(N) + 1 do
    local progLo = (k + swingWarp(0) + phase) / N
    if progLo > 1e-9 and progLo < 1 - 1e-9 then
      samp[#samp + 1] = { rel = M.freqWarpInverse(progLo, freqSkew), sv = -1 }
    end
    local progHi = (k + swingWarp(hi) + phase) / N
    if progHi > 1e-9 and progHi < 1 - 1e-9 then
      samp[#samp + 1] = { rel = M.freqWarpInverse(progHi, freqSkew), sv = 1 }
    end
  end
  samp[#samp + 1] = { rel = 0, sv = heldValue(-phase) }   -- value held at the span start

  table.sort(samp, function(a, b) return a.rel < b.rel end)
  local pts, lastRel = {}, nil
  for _, s in ipairs(samp) do
    if lastRel == nil or s.rel - lastRel > 1e-6 then
      pts[#pts + 1] = { time = t0 + s.rel * spanLen, value = valueAt(s.rel, s.sv), shape = 0 }  -- step
      lastRel = s.rel
    end
  end
  return pts
end

-- Rising SAW emitter (native "Saw"): a linear ramp from trough at each cycle start to peak at the
-- cycle end, then a near-instant reset. Emits a trough at rel 0; at each interior cycle boundary a
-- PEAK (ramp end) then a reset TROUGH one tick later; and a final point at the span end. Stays
-- SPARSE (a few points) under BOTH freq skew and swing — it never falls to the dense generic
-- sampler (the user-reported "saw gets denser with freq skew/swing").
--   * FREQ SKEW warps each boundary's time via freqWarpInverse (ramps stay linear).
--   * SWING shuffles the boundaries long-short: a saw has no mid-cycle extremum, so swing instead
--     shifts ODD reset boundaries by swing*0.5 in cycle-position (the pair feel — the inverse of
--     swingCyclePos at the resets), stretching one ramp and compressing the next. Sparse, so it
--     responds to swing without densifying. Value model (amp-skew half, tilt) applies.
-- Rising SAW (native "Saw") or, with desc=true, descending SAW ("Saw Down"). Both are SPARSE: a ramp
-- per cycle (start -> end) plus a near-instant reset, freq-skew/swing aware. desc flips the ramp
-- direction (lo/hi); the desc=false path is byte-identical to the original native saw.
local function generateSaw(t0, t1, spanLen, totalCycles, p, amp, baseV, ampSkew, freqSkew, tiltOffset, desc)
  local N = totalCycles
  local swing = max(-1, min(1, p.swing or 0))
  local eps = 1e-4                             -- ~1 tick reset gap (the writer snaps to the grid)
  local lo, hi = -1, 1                         -- Saw Up: trough -> peak
  if desc then lo, hi = 1, -1 end              -- Saw Down: peak -> trough
  local function emit(pts, rel, sv)
    if rel < 0 then rel = 0 elseif rel > 1 then rel = 1 end
    local depth = M.fadeDepth(rel, p.fadeIn, p.fadeOut)
    local half = ampHalf(amp, ampSkew, rel)
    pts[#pts + 1] = { time = t0 + rel * spanLen, value = baseV + half * sv * depth + tiltOffset * rel, shape = 1 }
  end
  -- Raw cycle-position of the c-th reset boundary (odd boundaries swing-shifted), then freq-warped.
  local function boundaryCP(c) return (c % 2 == 1) and (c + swing * 0.5) or c end
  local pts = {}
  emit(pts, 0, lo)                             -- first ramp start
  local c = 1
  while true do
    local prog = boundaryCP(c) / N
    if prog >= 1 - 1e-9 then break end
    local relB = M.freqWarpInverse(prog, freqSkew)
    emit(pts, relB, hi)                        -- ramp end of cycle c-1
    emit(pts, relB + eps, lo)                  -- reset (cycle c start)
    c = c + 1
  end
  -- Final point at the span end = the ramp value at the SWUNG end position (integer -> hi; partial
  -- -> a partial ramp value interpolated lo->hi).
  local endCP = M.swingCyclePos(N, swing)
  local fracEnd = endCP - floor(endCP)
  emit(pts, 1, (fracEnd < 1e-9) and hi or (lo + (hi - lo) * fracEnd))
  return pts
end

-- Trapezoid: SPARSE emitter placing points only at the 4 corners per cycle (trough, ramp-up end,
-- hold end, ramp-down end), linear between. edge in [0,0.5]: ~0 = near-square, 0.5 = triangle. amp
-- skew / tilt / fade apply; phase/swing/freq-skew are not warped (utility shape). Span edges are
-- anchored from the waveform value so coverage runs t0..t1.
local function generateTrapezoid(t0, t1, spanLen, totalCycles, p, amp, baseV, ampSkew, tiltOffset)
  local N = totalCycles
  local e = p.edge or 0.25
  if e > 0.5 then e = 0.5 elseif e < 0.001 then e = 0.001 end   -- avoid the degenerate edge=0 case
  local function emit(pts, rel, sv)
    local depth = M.fadeDepth(rel, p.fadeIn, p.fadeOut)
    local half = ampHalf(amp, ampSkew, rel)
    pts[#pts + 1] = { time = t0 + rel * spanLen, value = baseV + half * sv * depth + tiltOffset * rel, shape = 1 }
  end
  local corners = { { 0, -1 }, { e, 1 }, { 0.5, 1 }, { 0.5 + e, -1 } }   -- {phase, value} per cycle
  local samp = {}
  for c = 0, ceil(N) do
    for _, k in ipairs(corners) do
      local rel = (c + k[1]) / N
      if rel > 1e-9 and rel < 1 - 1e-9 then samp[#samp + 1] = { rel = rel, sv = k[2] } end
    end
  end
  samp[#samp + 1] = { rel = 0, sv = shapes.value("trapezoid", 0, { edge = e }) }
  samp[#samp + 1] = { rel = 1, sv = shapes.value("trapezoid", N, { edge = e }) }
  table.sort(samp, function(a, b) return a.rel < b.rel end)
  local pts, lastRel = {}, nil
  for _, s in ipairs(samp) do
    if lastRel == nil or s.rel - lastRel > 1e-6 then emit(pts, s.rel, s.sv); lastRel = s.rel end
  end
  return pts
end

-- Rectified sine: |sin| humps (two per cycle). SPARSE anchored emitter — cusps (-1, at phase 0/0.5)
-- and peaks (+1, at 0.25/0.75) per cycle. A point's CC shape governs the OUTGOING segment, so cusps
-- get fast START (steep leaving the sharp bottom, flattening into the peak) and peaks get fast END
-- (flat at the peak, steepening into the next cusp) -> ROUNDED humps with crisp cusps. Amp skew /
-- tilt / fade apply. Smooth/Steps route it to the generic sampler instead.
local function generateRectsine(t0, t1, spanLen, totalCycles, p, amp, baseV, ampSkew, tiltOffset)
  local N = totalCycles
  local function emit(pts, rel, sv, shp)
    local depth = M.fadeDepth(rel, p.fadeIn, p.fadeOut)
    local half = ampHalf(amp, ampSkew, rel)
    pts[#pts + 1] = { time = t0 + rel * spanLen, value = baseV + half * sv * depth + tiltOffset * rel, shape = shp }
  end
  local anchors = { { 0, -1, 3 }, { 0.25, 1, 4 }, { 0.5, -1, 3 }, { 0.75, 1, 4 } }  -- {phase, value, ccShape}
  -- Ease for an arbitrary phase: a rising quarter ([0,.25) & [.5,.75)) leaves a cusp -> fast start (3);
  -- a falling quarter approaches a cusp -> fast end (4).
  local function easeAt(ph) local f = ph - floor(ph); return (f < 0.25 or (f >= 0.5 and f < 0.75)) and 3 or 4 end
  local samp = {}
  for c = 0, ceil(N) do
    for _, k in ipairs(anchors) do
      local rel = (c + k[1]) / N
      if rel > 1e-9 and rel < 1 - 1e-9 then samp[#samp + 1] = { rel = rel, sv = k[2], shp = k[3] } end
    end
  end
  samp[#samp + 1] = { rel = 0, sv = shapes.value("rectsine", 0, {}), shp = easeAt(0) }
  samp[#samp + 1] = { rel = 1, sv = shapes.value("rectsine", N, {}), shp = easeAt(N) }
  table.sort(samp, function(a, b) return a.rel < b.rel end)
  local pts, lastRel = {}, nil
  for _, s in ipairs(samp) do
    if lastRel == nil or s.rel - lastRel > 1e-6 then emit(pts, s.rel, s.sv, s.shp); lastRel = s.rel end
  end
  return pts
end

-- Random (Sample & Hold) and Drift (smooth random) share one emitter: one random value per cycle
-- (shapes.randomAt(seed, cycleIndex)). They differ only in interpolation between cycle values:
-- S&H holds flat (step CC shape 0); Drift eases (slow start/end CC shape 2). Sparse: one anchor per
-- cycle start + an end anchor. Honors amplitude/amp-skew/tilt/fade; freq-skew/swing are not applied
-- (no musical meaning for held random). smoothInterp=true selects Drift.
local function generateRandom(t0, t1, spanLen, totalCycles, p, amp, baseV, ampSkew, tiltOffset, smoothInterp)
  local seed = p.seed or 0
  local N = totalCycles
  local ccShape = smoothInterp and 2 or 0
  local function emit(pts, rel, cyc)
    if rel < 0 then rel = 0 elseif rel > 1 then rel = 1 end
    local depth = M.fadeDepth(rel, p.fadeIn, p.fadeOut)
    local half = ampHalf(amp, ampSkew, rel)
    local sv = shapes.randomAt(seed, cyc)
    pts[#pts + 1] = { time = t0 + rel * spanLen, value = baseV + half * sv * depth + tiltOffset * rel, shape = ccShape }
  end
  local pts = {}
  local c = 0
  while c / N < 1 - 1e-9 do
    emit(pts, c / N, c)
    c = c + 1
  end
  -- End anchor: Drift eases toward the NEXT target (cyc=c); S&H holds the LAST value (cyc=c-1).
  emit(pts, 1, smoothInterp and c or math.max(0, c - 1))
  return pts
end

-- Pump (sidechain duck): per cycle, an instant duck to -1 at the cycle start that RECOVERS to +1 by
-- the cycle end (an exponential Saw Up). The recovery segment carries a bezier CC shape whose tension
-- scales with `curve` (0..100 => linear..strongly bulged). Depth = amplitude. Sparse, like generateSaw.
local function generatePump(t0, t1, spanLen, totalCycles, p, amp, baseV, ampSkew, tiltOffset)
  local N = totalCycles
  local curve = max(-1, min(1, (p.curve or 0) / 100))   -- bipolar: sign = which way the ease bends
  local tension = curve * 0.9
  local rampShape = (abs(curve) > 1e-9) and 5 or 1   -- bezier when curved (either sign), else linear
  local eps = math.min(1e-4, 0.25 / N)
  local function emit(pts, rel, sv, shp, ten)
    if rel < 0 then rel = 0 elseif rel > 1 then rel = 1 end
    local depth = M.fadeDepth(rel, p.fadeIn, p.fadeOut)
    local half = ampHalf(amp, ampSkew, rel)
    pts[#pts + 1] = { time = t0 + rel * spanLen, value = baseV + half * sv * depth + tiltOffset * rel, shape = shp, tension = ten }
  end
  local pts = {}
  emit(pts, 0, -1, rampShape, tension)           -- first duck, curved recovery
  local c = 1
  while c / N < 1 - 1e-9 do
    local rel = c / N
    emit(pts, rel, 1, 1, 0)                       -- recovered peak (end of cycle c-1)
    emit(pts, rel + eps, -1, rampShape, tension)  -- re-duck (start of cycle c)
    c = c + 1
  end
  local fracEnd = N - floor(N)
  emit(pts, 1, (fracEnd < 1e-9) and 1 or (2 * fracEnd - 1), 1, 0)   -- recovered value at span end
  return pts
end

-- AD (attack-decay hump): per cycle, rise -1->+1 over the Attack fraction a=attack/100, then fall
-- +1->-1 over the remaining 1-a. Both segments carry a bezier CC shape scaled by `curve`. Sparse:
-- a trough at each cycle start, a peak at cycle-fraction a.
local function generateAD(t0, t1, spanLen, totalCycles, p, amp, baseV, ampSkew, tiltOffset)
  local N = totalCycles
  local a = max(0.01, min(0.99, (p.attack or 50) / 100))
  local curve = max(-1, min(1, (p.curve or 0) / 100))   -- bipolar: sign = which way the ease bends
  local tension = curve * 0.9
  local seg = (abs(curve) > 1e-9) and 5 or 1
  local function emit(pts, rel, sv)
    if rel < 0 then rel = 0 elseif rel > 1 then rel = 1 end
    local depth = M.fadeDepth(rel, p.fadeIn, p.fadeOut)
    local half = ampHalf(amp, ampSkew, rel)
    pts[#pts + 1] = { time = t0 + rel * spanLen, value = baseV + half * sv * depth + tiltOffset * rel, shape = seg, tension = tension }
  end
  local pts = {}
  emit(pts, 0, -1)                              -- start trough (attack begins)
  local c = 0
  while true do
    local peakRel = (c + a) / N
    if peakRel >= 1 - 1e-9 then break end
    emit(pts, peakRel, 1)                       -- peak (decay begins)
    local troughRel = (c + 1) / N
    if troughRel < 1 - 1e-9 then emit(pts, troughRel, -1) end  -- next trough
    c = c + 1
  end
  emit(pts, 1, -1)                              -- span end at trough
  return pts
end

function M.generate(span, params)
  local t0, t1 = span.t0, span.t1
  local spanLen = t1 - t0
  if spanLen <= 0 then return {} end

  local p = params
  local cycleLen = M.cycleLength(p.rate, spanLen)
  local ppc = max(1, p.density or 16)
  -- Steps/Smooth force the dense generic sampler: bump density so a quantized staircase has enough
  -- points per level and a smoothed shape reads as a clean curve (the per-shape ppc is tuned for the
  -- SPARSE emitters, which would be far too coarse on the generic path).
  if p.quantizeSteps and p.quantizeSteps >= 2 then ppc = max(ppc, 4 * p.quantizeSteps) end
  if (p.smooth or 0) > 0 then ppc = max(ppc, 24) end
  local dt = cycleLen / ppc
  local n = max(1, floor(spanLen / dt + 0.5))

  local amp = p.amplitude or 1     -- baseHalf: half-swing in value units
  local baseV = p.baseline or 0    -- center value
  local seed = p.seed or 0
  local phase = p.phase or 0
  local swing = p.swing or 0
  local ampSkew = p.ampSkew or 0   -- global amplitude ramp anchor, [-1,1]
  local freqSkew = p.freqSkew or 0 -- global phase time-warp, [-1,1]

  -- TILT — value-unit GLOBAL offset across the WHOLE span, anchored at the left
  -- (rel=0), applied as tiltOffset*rel. Native is FULL-RANGE (e.g. +127 at the
  -- right edge for tilt 100%). The UI passes `tiltOffset` directly in value units.
  -- Back-compat: older callers pass `tilt` as a [-1,1] MULTIPLIER of amplitude, so
  -- when tiltOffset is absent we derive tiltOffset = amp*tilt (identical behavior).
  local tiltOffset = p.tiltOffset
  if tiltOffset == nil then tiltOffset = amp * (p.tilt or 0) end

  -- Total cycle count over the selection (preserved by the freq-skew warp).
  local totalCycles = spanLen / cycleLen

  -- Random / Drift: dedicated sparse emitters (one random value per cycle). Selected up front so
  -- Steps/Smooth never reroute them (held random doesn't smooth/quantize meaningfully here).
  if p.shape == "random" then
    return generateRandom(t0, t1, spanLen, totalCycles, p, amp, baseV, ampSkew, tiltOffset, false)
  end
  if p.shape == "drift" then
    return generateRandom(t0, t1, spanLen, totalCycles, p, amp, baseV, ampSkew, tiltOffset, true)
  end
  if p.shape == "pump" then
    return generatePump(t0, t1, spanLen, totalCycles, p, amp, baseV, ampSkew, tiltOffset)
  end
  if p.shape == "ad" then
    return generateAD(t0, t1, spanLen, totalCycles, p, amp, baseV, ampSkew, tiltOffset)
  end

  -- ---------------------------------------------------------------------------
  -- ANCHORED native shapes (SINE / TRIANGLE / PARAMETRIC): sparse extremum (+ quarter-
  -- phase for parametric) placement reproduces native to the integer. emitAnchored now
  -- handles phase, swing, freqSkew, ampSkew and tilt directly (the old phase/swing guards
  -- that bounced these onto the dense sampler are GONE). Only a shape MODIFIER that bends
  -- the per-sample geometry — smooth or quantize — falls through to the generic sampler.
  if (p.shape == "sine" or p.shape == "triangle" or p.shape == "parametric" or p.shape == "sine2")
     and (p.smooth or 0) == 0 and not p.quantizeSteps then
    return emitAnchored(p.shape, t0, t1, spanLen, totalCycles, p,
      amp, baseV, ampSkew, freqSkew, tiltOffset)
  end

  -- SQUARE: explicit LOW/HIGH edges, now PHASE/FREQ-SKEW/SWING aware (stays crisp under all of
  -- them — the edges warp but the steps stay hard). Only smooth/quantize route it elsewhere
  -- (quantize is a no-op on a +/-1 square anyway, so effectively only smooth does).
  if p.shape == "square" and (p.smooth or 0) == 0 then
    return generateSquare(t0, t1, spanLen, totalCycles, p, amp, baseV, ampSkew, freqSkew, tiltOffset)
  end

  -- SAW: native rising ramp (== sawup) with a sharp reset. Now FREQ-SKEW aware and SPARSE under
  -- all modulators (warped boundaries, linear ramps); only smooth routes it elsewhere. The legacy
  -- "sawup"/"sawdown" extras still use the dense sampler (their behavior is unchanged).
  if p.shape == "saw" and (p.smooth or 0) == 0 and not p.quantizeSteps then
    return generateSaw(t0, t1, spanLen, totalCycles, p, amp, baseV, ampSkew, freqSkew, tiltOffset)
  end

  -- SAW DOWN: descending ramp, sparse like Saw Up. Steps/Smooth route it to the generic sampler
  -- (a stepped ramp -> staircase, a smoothed ramp -> rounded).
  if p.shape == "sawdown" and (p.smooth or 0) == 0 and not p.quantizeSteps then
    return generateSaw(t0, t1, spanLen, totalCycles, p, amp, baseV, ampSkew, freqSkew, tiltOffset, true)
  end

  -- TRAPEZOID: sparse 4-corner emitter (routes to the generic sampler only when smooth/quantize bend it).
  if p.shape == "trapezoid" and (p.smooth or 0) == 0 and not p.quantizeSteps then
    return generateTrapezoid(t0, t1, spanLen, totalCycles, p, amp, baseV, ampSkew, tiltOffset)
  end

  -- RECTIFIED SINE: sparse |sin| humps (rounded, with crisp cusps). Smooth/Steps route to generic.
  if p.shape == "rectsine" and (p.smooth or 0) == 0 and not p.quantizeSteps then
    return generateRectsine(t0, t1, spanLen, totalCycles, p, amp, baseV, ampSkew, tiltOffset)
  end

  -- Generic ppc sampler (smoothed/quantized waveforms, plus rectsine/sine2 when a modifier bends them).
  -- Flows through the GLOBAL value model: amp-skew ramp on the half-amplitude, freq-skew
  -- phase warp on the cycle position, value-unit tilt offset. PHASE is subtracted (native
  -- delays for +phase: shape-phase = totalCycles*warp(rel) - phase), consistent with
  -- emitAnchored. value(rel) = center + half(rel)*sv*depth + tiltOffset*rel.
  local function sampleValue(rel)
    -- Global freq-skew warp on the phase position, then swing, then split into cycle.
    local warpedCycles = totalCycles * M.freqWarp(rel, freqSkew)
    local cyclePos = M.swingCyclePos(warpedCycles - phase, swing)
    local cyc = floor(cyclePos)
    local tInCycle = cyclePos - cyc
    local sv = shapes.value(p.shape, tInCycle, p)
    sv = M.quantizeBipolar(sv, p.quantizeSteps)
    local depth = M.fadeDepth(rel, p.fadeIn, p.fadeOut)
    local half = ampHalf(amp, ampSkew, rel)
    -- Tilt is a GLOBAL drift NOT scaled by fade depth (only the waveform sv*depth fades).
    return baseV + half * sv * depth + tiltOffset * rel
  end

  local pts = {}
  for i = 0, n do
    local T = t0 + i * dt
    if T > t1 then T = t1 end
    local rel = (T - t0) / spanLen
    pts[#pts + 1] = { time = T, value = sampleValue(rel) }
    if T >= t1 then break end
  end

  -- Guarantee: last point's time must equal t1 (loop may end short when
  -- spanLen/dt is not an integer, e.g. density=3 over an exact cycle).
  if #pts > 0 and pts[#pts].time < t1 then
    pts[#pts + 1] = { time = t1, value = sampleValue(1) }
  end

  return pts
end

return M
