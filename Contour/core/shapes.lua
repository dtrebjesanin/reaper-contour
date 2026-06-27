-- core/shapes.lua — pure waveform math. Returns values in [-1, 1]. No Reaper, no I/O.
local M = {}
local pi, cos, floor = math.pi, math.cos, math.floor

local function clamp(x, lo, hi)
  if x < lo then return lo elseif x > hi then return hi else return x end
end
local function frac(x) return x - floor(x) end

-- Base shapes: t in [0,1), returns [-1,1].
local base = {}
-- NATIVE MATCH (Generate v2.4): REAPER's native CC LFO sine starts at the TROUGH
-- (-1) at phase 0 and peaks (+1) at mid-cycle. That is -cos(2*pi*t), NOT sin(2*pi*t):
--   t=0   -> -1 (trough),  t=0.25 -> 0,  t=0.5 -> +1 (peak),  t=0.75 -> 0.
-- The extremum point placement in lfo.generate relies on this phasing.
function base.sine(t) return -cos(2 * pi * t) end
function base.square(t, pw) pw = pw or 0.5; return (t < pw) and 1 or -1 end
function base.triangle(t)
  if t < 0.25 then return 4 * t
  elseif t < 0.75 then return 2 - 4 * t
  else return 4 * t - 4 end
end
function base.sawup(t) return 2 * t - 1 end
function base.sawdown(t) return 1 - 2 * t end
function base.none(_) return 0 end
M.base = base

-- NATIVE MATCH: REAPER's native CC LFO basic shapes are Sine / Triangle / Saw / Square /
-- Parametric. "saw" is the native rising saw (== sawup). "parametric" shares the sine
-- waveform (-cos); lfo.generate samples it at quarter-phases (4 pts/cycle) instead of just
-- the extrema, with a bezier CC shape, so it renders as a denser/smoother sine.
-- sawup/sawdown/random remain as Contour EXTRAS (not native), available to the engine.
local dispatch = {
  sine = base.sine, square = base.square, triangle = base.triangle,
  saw = base.sawup, parametric = base.sine,
  sawup = base.sawup, sawdown = base.sawdown, none = base.none,
}

local function applySmooth(v, vSine, smooth)
  if smooth <= 0 then return v end
  if smooth >= 1 then return vSine end
  return v * (1 - smooth) + vSine * smooth
end

-- M.value returns the NORMALIZED per-cycle waveform sample in [-1,1] for an
-- intra-cycle phase t in [0,1). It is PURELY the waveform shape.
--
-- NATIVE MATCH (Generate v2.4): amplitude skew and frequency skew used to live here
-- as PER-CYCLE warps. They are now GLOBAL modulators applied across the whole
-- selection by lfo.generate (global amp ramp on the half-amplitude, global phase
-- time-warp on the cycle position). They have been REMOVED from here so the engine
-- matches REAPER's native CC LFO (which applies them globally, not per-cycle).
-- shapes.value therefore ignores p.ampSkew / p.freqSkew entirely.
function M.value(shape, t, p)
  p = p or {}
  local tt = frac(t)
  local fn = dispatch[shape] or base.sine
  local v
  if shape == "square" then v = fn(tt, p.pulseWidth) else v = fn(tt) end
  -- Smoothing blends toward a sine of the same phase, so other shapes can be rounded.
  v = applySmooth(v, base.sine(tt), p.smooth or 0)
  return clamp(v, -1, 1)
end

-- Deterministic LCG-based PRNG; returns a closure yielding (0,1). Kept for any external callers.
function M.prng(seed)
  local state = (seed or 0) % 2147483647
  if state <= 0 then state = state + 2147483646 end
  return function()
    state = (state * 16807) % 2147483647
    return state / 2147483647
  end
end

-- splitmix64 finalizer: a strong integer mixing hash. Lua 5.4 integer ops wrap mod 2^64
-- (two's complement), which is exactly what the hash wants.
local function mix64(x)
  x = (x ~ (x >> 30)) * 0xbf58476d1ce4e5b9
  x = (x ~ (x >> 27)) * 0x94d049bb133111eb
  return x ~ (x >> 31)
end

-- Deterministic value in [-1,1) for a (seed, cycle index) pair (sample & hold). Uses a hash so
-- CONSECUTIVE indices decorrelate (the old LCG-seeded-by-index approach produced a staircase).
function M.randomAt(seed, index)
  local h = mix64((seed or 0) * 0x9E3779B97F4A7C15 + (index or 0))
  local u = (h & 0x1FFFFFFFFFFFFF) / 0x20000000000000  -- low 53 bits -> [0,1)
  return u * 2 - 1
end

M._clamp = clamp
M._frac = frac
return M
