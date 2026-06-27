package.path = package.path .. ";./Contour/?.lua;./?.lua;./tests/?.lua"
local h = require("harness")
local shapes = require("core.shapes")

-- NATIVE MATCH: sine is -cos(2*pi*t) (starts at the TROUGH to match REAPER's native
-- CC LFO): 0 -> -1, .25 -> 0, .5 -> +1, .75 -> 0.
h.test("sine quarters", function()
  h.almost(shapes.value("sine", 0.0, {}), -1)
  h.almost(shapes.value("sine", 0.25, {}), 0, 1e-9)
  h.almost(shapes.value("sine", 0.5, {}), 1)
  h.almost(shapes.value("sine", 0.75, {}), 0, 1e-9)
end)

-- square (default 50% duty): starts LOW, HIGH in the last pw -- matches the native square emitter
-- (generateSquare) so toggling Smooth doesn't flip the wave.
h.test("square halves", function()
  h.eq(shapes.value("square", 0.1, {}), -1)
  h.eq(shapes.value("square", 0.6, {}), 1)
end)

-- triangle (trough-start, -cos phase, matching the anchored triangle): 0->-1, .25->0, .5->1, .75->0
h.test("triangle peaks", function()
  h.almost(shapes.value("triangle", 0.0, {}), -1)
  h.almost(shapes.value("triangle", 0.25, {}), 0)
  h.almost(shapes.value("triangle", 0.5, {}), 1)
  h.almost(shapes.value("triangle", 0.75, {}), 0)
end)

-- saws span -1..1
h.test("saws", function()
  h.almost(shapes.value("sawup", 0.0, {}), -1)
  h.almost(shapes.value("sawup", 1.0 - 1e-12, {}), 1, 1e-6)
  h.almost(shapes.value("sawdown", 0.0, {}), 1)
end)

h.test("none is flat zero", function()
  h.eq(shapes.value("none", 0.3, {}), 0)
end)

-- pulse width changes square duty: HIGH occupies the LAST pw of the cycle (low first)
h.test("pulse width duty", function()
  h.eq(shapes.value("square", 0.5, { pulseWidth = 0.25 }), -1)   -- LOW until the final 25%
  h.eq(shapes.value("square", 0.8, { pulseWidth = 0.25 }), 1)    -- HIGH in the final pw
end)

-- NATIVE MATCH (v2.4): freqSkew + ampSkew are now GLOBAL modulators in lfo.generate,
-- NOT per-cycle waveform warps. shapes.value MUST ignore them entirely (only the raw
-- waveform + optional smooth survive here). Passing them leaves the shape unchanged.
h.test("shapes.value ignores freqSkew/ampSkew (now global)", function()
  local plain = shapes.value("sine", 0.5, {})
  h.almost(shapes.value("sine", 0.5, { freqSkew = 0.5 }), plain, 1e-12)
  h.almost(shapes.value("sine", 0.5, { ampSkew = 0.5 }), plain, 1e-12)
  h.almost(shapes.value("sine", 0.125, { freqSkew = -0.8, ampSkew = 0.9 }),
    shapes.value("sine", 0.125, {}), 1e-12)
end)

-- smooth=0 leaves the triangle unchanged; smooth=1 makes it equal sine (-cos phasing).
h.test("smooth blends to sine", function()
  h.almost(shapes.value("triangle", 0.1, { smooth = 0 }), -0.6)       -- -1 + 4*0.1 (trough-start)
  h.almost(shapes.value("triangle", 0.1, { smooth = 1 }), -math.cos(2 * math.pi * 0.1))
end)

-- randomAt is deterministic and in range
h.test("randomAt deterministic in range", function()
  local a = shapes.randomAt(42, 3)
  local b = shapes.randomAt(42, 3)
  h.eq(a, b)
  h.truthy(a >= -1 and a < 1, "in [-1,1)")
end)

-- different cycle index generally differs
h.test("randomAt varies by index", function()
  h.truthy(shapes.randomAt(42, 0) ~= shapes.randomAt(42, 1), "expected different values")
end)

-- REGRESSION: randomAt used to seed an LCG linearly by index, producing a staircase (near-constant
-- consecutive deltas that wrap). Real noise must NOT march by a constant step and must spread the range.
h.test("randomAt is noise, not a staircase", function()
  local v = {}
  for i = 0, 31 do v[i] = shapes.randomAt(12345, i) end
  local d0 = v[1] - v[0]
  local sameStep = 0
  for i = 1, 31 do if math.abs((v[i] - v[i-1]) - d0) < 0.02 then sameStep = sameStep + 1 end end
  h.truthy(sameStep < 10, "consecutive deltas are ~constant => staircase, not random")
  local lo, hi = 2, -2
  for i = 0, 31 do lo = math.min(lo, v[i]); hi = math.max(hi, v[i]) end
  h.truthy(hi - lo > 1.0, "random values should spread across the range")
end)

-- Trapezoid: square with linear ramps of width `edge` in [0,0.5]. edge=0 => high first half /
-- low second half; edge=0.5 => symmetric triangle peaking at 0.5.
h.test("trapezoid edges", function()
  h.eq(shapes.value("trapezoid", 0.1, { edge = 0 }), 1)        -- edge 0 => high first half
  h.eq(shapes.value("trapezoid", 0.6, { edge = 0 }), -1)       -- low second half
  h.almost(shapes.value("trapezoid", 0.0, { edge = 0.25 }), -1)-- ramp starts at trough
  h.almost(shapes.value("trapezoid", 0.25, { edge = 0.25 }), 1)-- reached high by end of ramp
  h.almost(shapes.value("trapezoid", 0.5, { edge = 0.5 }), 1)  -- edge 0.5 => triangle peak at 0.5
end)

-- Rectified sine: full-wave |sin| humps. -1 at 0 and 0.5, +1 at 0.25 and 0.75 (two humps/cycle).
h.test("rectified sine humps", function()
  h.almost(shapes.value("rectsine", 0.0, {}), -1)
  h.almost(shapes.value("rectsine", 0.25, {}), 1)
  h.almost(shapes.value("rectsine", 0.5, {}), -1, 1e-9)
  h.almost(shapes.value("rectsine", 0.75, {}), 1)
end)

-- Sine²: same zeros as sine (-cos phasing) but peakier (|value| < |sine| off the extremes).
h.test("sine2 peakier than sine", function()
  h.almost(shapes.value("sine2", 0.0, {}), -1)
  h.almost(shapes.value("sine2", 0.5, {}), 1)
  h.almost(shapes.value("sine2", 0.25, {}), 0, 1e-9)
  local s  = math.abs(shapes.value("sine",  0.1, {}))
  local s2 = math.abs(shapes.value("sine2", 0.1, {}))
  h.truthy(s2 < s, "sine2 should be flatter than sine away from the extremes")
end)

h.run()
