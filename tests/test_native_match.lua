package.path = package.path .. ";./Contour/?.lua;./?.lua;./tests/?.lua"
local h = require("harness")
local lfo = require("core.lfo")

-- ===========================================================================
-- ACCEPTANCE GATE: Contour's PURE engine MUST reproduce REAPER's native CC LFO
-- to the integer. Fixtures CC1..CC37 are a full single-session capture (tempo 120,
-- 4/4, 2-bar time selection) dumped via dump_cc_all.lua. BASE preset: Sine,
-- Baseline 0 (center 63.5), Amplitude 50 (baseHalf 31.75), Phase/Amp skew/Freq
-- skew/Tilt/Swing 0, Pulse width 50, Frequency 1/2 + Length 1/4 => 2 cycles over
-- the span. Each lane changes ONE setting (see label). Frequency/Length lanes change
-- the cycle count: cycles = frequency / length (verified across CC27-30 and CC36-37).
--
-- The Reaper write layer clamps to [0,127] then FLOORs (native truncates 31.75 -> 31);
-- core stays range-agnostic, so we floor+clamp here before asserting. rel within 1e-3,
-- value EXACT — except the FINAL point, which native places 1 tick before t1 while the
-- pure core places it at t1; on a sloped/peak region that is a <=1 LSB sub-tick
-- difference, so the last point tolerates +/-1.
--
-- SHAPE NOTE: native distinguishes Sine vs Triangle ONLY by the CC interpolation flag
-- (bezier vs linear) — the emitted points are byte-identical (CC1 == CC2). Parametric is
-- the same sine waveform sampled at 4 pts/cycle. The flag itself is applied by the Reaper
-- write layer (target.lua ccShape), not visible in these (rel,value) fixtures.
--
-- CC8 (baseline -50... captured as baseline 50) is intentionally OMITTED: it came back
-- [0,127] (= full-range, identical to amplitude-high CC10/CC11), a capture slip. The
-- baseline model is confirmed to the integer by CC7 (-50) and CC9 (+100).
-- ===========================================================================

local MID, HALF = 63.5, 63.5
local VMIN, VMAX = 0, 127

local function quant(v)
  if v < VMIN then v = VMIN elseif v > VMAX then v = VMAX end
  return math.floor(v)
end

local SPAN = { t0 = 0, t1 = 1 }

-- Build lfo.generate params from native % settings (mirrors ui/generate.lua buildParams).
local function P(o)
  o = o or {}
  local p = {
    shape    = o.shape or "sine",
    rate     = { mode = "free", cycles = o.cycles or 2 },
    amplitude = ((o.amp or 50) / 100) * HALF,        -- baseHalf (value units)
    baseline  = MID + ((o.base or 0) / 100) * HALF,  -- center (value units)
  }
  if o.tilt     then p.tiltOffset = (o.tilt / 100) * (VMAX - VMIN) end
  if o.ampSkew  then p.ampSkew    = o.ampSkew / 100 end
  if o.freqSkew then p.freqSkew   = o.freqSkew / 100 end
  if o.phase    then p.phase      = o.phase / 100 end   -- slider 0..100 -> cycles 0..1
  if o.swing    then p.swing      = o.swing / 100 end   -- native -100..100 -> [-1,1]
  if o.pw       then p.pulseWidth = o.pw / 100 end       -- native 1..99 -> 0..1
  return p
end

-- Assert a generated point list matches {rel, flooredValue} pairs. Last point => +/-1 LSB.
local function assertFixture(name, pts, fixture)
  h.eq(#pts, #fixture, name .. " point count")
  for i, want in ipairs(fixture) do
    local got = pts[i]
    local rel = (got.time - SPAN.t0) / (SPAN.t1 - SPAN.t0)
    if math.abs(rel - want[1]) > 1e-3 then
      error(string.format("%s point %d: rel expected ~%.4f got %.4f", name, i, want[1], rel), 2)
    end
    local val = quant(got.value)
    local tol = (want[1] >= 0.999) and 1 or 0   -- final tick-snapped point: <=1 LSB
    if math.abs(val - want[2]) > tol then
      error(string.format("%s point %d (rel %.4f): value expected %d got %d (raw %.4f)",
        name, i, want[1], want[2], val, got.value), 2)
    end
  end
end

local function lane(name, opts, fixture)
  h.test("native " .. name, function()
    assertFixture(name, lfo.generate(SPAN, P(opts)), fixture)
  end)
end

-- ---- SHAPES (CC1-5) -------------------------------------------------------
lane("CC1 sine", { shape = "sine" }, {
  { 0, 31 }, { 0.25, 95 }, { 0.5, 31 }, { 0.75, 95 }, { 1.0, 31 } })
lane("CC2 triangle (== sine points)", { shape = "triangle" }, {
  { 0, 31 }, { 0.25, 95 }, { 0.5, 31 }, { 0.75, 95 }, { 1.0, 31 } })
lane("CC3 saw", { shape = "saw" }, {
  { 0, 31 }, { 0.5, 95 }, { 0.5003, 31 }, { 0.9997, 94 } })
lane("CC4 square", { shape = "square" }, {
  { 0, 31 }, { 0.25, 95 }, { 0.5, 31 }, { 0.75, 95 } })
lane("CC5 parametric", { shape = "parametric" }, {
  { 0, 31 }, { 0.125, 63 }, { 0.25, 95 }, { 0.375, 63 }, { 0.5, 31 },
  { 0.625, 63 }, { 0.75, 95 }, { 0.875, 63 }, { 1.0, 31 } })

-- ---- BASELINE (CC7, CC9) --------------------------------------------------
lane("CC7 baseline -50", { base = -50 }, {
  { 0, 0 }, { 0.25, 63 }, { 0.5, 0 }, { 0.75, 63 }, { 1.0, 0 } })
lane("CC9 baseline 100", { base = 100 }, {
  { 0, 95 }, { 0.25, 127 }, { 0.5, 95 }, { 0.75, 127 }, { 1.0, 95 } })

-- ---- AMPLITUDE (CC10-12) --------------------------------------------------
lane("CC10 amplitude 100", { amp = 100 }, {
  { 0, 0 }, { 0.25, 127 }, { 0.5, 0 }, { 0.75, 127 }, { 1.0, 0 } })
lane("CC11 amplitude 200 (clips)", { amp = 200 }, {
  { 0, 0 }, { 0.25, 127 }, { 0.5, 0 }, { 0.75, 127 }, { 1.0, 0 } })
lane("CC12 amplitude -50 (inverts)", { amp = -50 }, {
  { 0, 95 }, { 0.25, 31 }, { 0.5, 95 }, { 0.75, 31 }, { 0.9997, 94 } })

-- ---- PHASE (CC13-15) ------------------------------------------------------
lane("CC13 phase 25", { phase = 25 }, {
  { 0, 63 }, { 0.125, 31 }, { 0.375, 95 }, { 0.625, 31 }, { 0.875, 95 }, { 0.9997, 63 } })
lane("CC14 phase 50", { phase = 50 }, {
  { 0, 95 }, { 0.25, 31 }, { 0.5, 95 }, { 0.75, 31 }, { 0.9997, 94 } })
lane("CC15 phase 75", { phase = 75 }, {
  { 0, 63 }, { 0.125, 95 }, { 0.375, 31 }, { 0.625, 95 }, { 0.875, 31 }, { 0.9997, 62 } })

-- ---- AMP SKEW (CC16-17) ---------------------------------------------------
lane("CC16 amp skew 50", { ampSkew = 50 }, {
  { 0, 47 }, { 0.25, 83 }, { 0.5, 39 }, { 0.75, 91 }, { 1.0, 31 } })
lane("CC17 amp skew -100", { ampSkew = -100 }, {
  { 0, 31 }, { 0.25, 87 }, { 0.5, 47 }, { 0.75, 71 }, { 1.0, 63 } })

-- ---- FREQ SKEW (CC18-19) — the quadratic warp -----------------------------
lane("CC18 freq skew 50", { freqSkew = 50 }, {
  { 0, 31 }, { 0.3438, 95 }, { 0.625, 31 }, { 0.8438, 95 }, { 1.0, 31 } })
lane("CC19 freq skew -100", { freqSkew = -100 }, {
  { 0, 31 }, { 0.0625, 95 }, { 0.25, 31 }, { 0.5625, 95 }, { 1.0, 31 } })

-- ---- TILT (CC20-21) -------------------------------------------------------
lane("CC20 tilt 50", { tilt = 50 }, {
  { 0, 31 }, { 0.25, 111 }, { 0.5, 63 }, { 0.75, 127 }, { 1.0, 95 } })
lane("CC21 tilt -100", { tilt = -100 }, {
  { 0, 31 }, { 0.25, 63 }, { 0.5, 0 }, { 0.75, 0 }, { 1.0, 0 } })

-- ---- SWING (CC22-24) — intra-cycle peak shift -----------------------------
lane("CC22 swing 25", { swing = 25 }, {
  { 0, 31 }, { 0.2813, 95 }, { 0.5, 31 }, { 0.7813, 95 }, { 1.0, 31 } })
lane("CC23 swing 50", { swing = 50 }, {
  { 0, 31 }, { 0.3125, 95 }, { 0.5, 31 }, { 0.8125, 95 }, { 1.0, 31 } })
lane("CC24 swing -50", { swing = -50 }, {
  { 0, 31 }, { 0.1875, 95 }, { 0.5, 31 }, { 0.6875, 95 }, { 1.0, 31 } })

-- ---- PULSE WIDTH (CC25-26) — square duty ----------------------------------
lane("CC25 square pw 25", { shape = "square", pw = 25 }, {
  { 0, 31 }, { 0.375, 95 }, { 0.5, 31 }, { 0.875, 95 } })
lane("CC26 square pw 75", { shape = "square", pw = 75 }, {
  { 0, 31 }, { 0.125, 95 }, { 0.5, 31 }, { 0.625, 95 } })

-- ---- FREQUENCY (CC27-30) — cycles = frequency / length --------------------
lane("CC27 frequency 1/4 (1 cycle)", { cycles = 1 }, {
  { 0, 31 }, { 0.5, 95 }, { 1.0, 31 } })
lane("CC28 frequency 1 (4 cycles)", { cycles = 4 }, {
  { 0, 31 }, { 0.125, 95 }, { 0.25, 31 }, { 0.375, 95 }, { 0.5, 31 },
  { 0.625, 95 }, { 0.75, 31 }, { 0.875, 95 }, { 1.0, 31 } })
lane("CC29 frequency 1/8 (0.5 cycle)", { cycles = 0.5 }, {
  { 0, 31 }, { 0.9997, 94 } })
lane("CC30 frequency 2 (8 cycles)", { cycles = 8 }, {
  { 0, 31 }, { 0.0625, 95 }, { 0.125, 31 }, { 0.1875, 95 }, { 0.25, 31 },
  { 0.3125, 95 }, { 0.375, 31 }, { 0.4375, 95 }, { 0.5, 31 }, { 0.5625, 95 },
  { 0.625, 31 }, { 0.6875, 95 }, { 0.75, 31 }, { 0.8125, 95 }, { 0.875, 31 },
  { 0.9375, 95 }, { 1.0, 31 } })

-- ---- COMBOS (CC31-32) -----------------------------------------------------
lane("CC31 amp skew 100 + tilt 100", { ampSkew = 100, tilt = 100 }, {
  { 0, 63 }, { 0.25, 103 }, { 0.5, 111 }, { 0.75, 127 }, { 1.0, 127 } })
lane("CC32 freq skew 100 + phase 50", { freqSkew = 100, phase = 50 }, {
  { 0, 95 }, { 0.4375, 31 }, { 0.75, 95 }, { 0.9375, 31 }, { 0.9997, 94 } })

-- ---- CROSS-SHAPE SPOT CHECKS (CC33-35) ------------------------------------
lane("CC33 square + tilt 100", { shape = "square", tilt = 100 }, {
  { 0, 31 }, { 0.25, 127 }, { 0.5, 95 }, { 0.75, 127 } })
lane("CC34 triangle + freq skew 100", { shape = "triangle", freqSkew = 100 }, {
  { 0, 31 }, { 0.4375, 95 }, { 0.75, 31 }, { 0.9375, 95 }, { 1.0, 31 } })
lane("CC35 saw + amp skew 100", { shape = "saw", ampSkew = 100 }, {
  { 0, 63 }, { 0.5, 79 }, { 0.5003, 47 }, { 0.9997, 94 } })

-- ---- LENGTH (CC36-37) -----------------------------------------------------
lane("CC36 length 1/2 (1 cycle)", { cycles = 1 }, {
  { 0, 31 }, { 0.5, 95 }, { 1.0, 31 } })
lane("CC37 length 1/8 (4 cycles)", { cycles = 4 }, {
  { 0, 31 }, { 0.125, 95 }, { 0.25, 31 }, { 0.375, 95 }, { 0.5, 31 },
  { 0.625, 95 }, { 0.75, 31 }, { 0.875, 95 }, { 1.0, 31 } })

h.run()
