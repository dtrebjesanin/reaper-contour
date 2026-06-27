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

-- square (default 50% duty): first half +1, second half -1
h.test("square halves", function()
  h.eq(shapes.value("square", 0.1, {}), 1)
  h.eq(shapes.value("square", 0.6, {}), -1)
end)

-- triangle: 0->0, .25->1, .5->0, .75->-1
h.test("triangle peaks", function()
  h.almost(shapes.value("triangle", 0.0, {}), 0)
  h.almost(shapes.value("triangle", 0.25, {}), 1)
  h.almost(shapes.value("triangle", 0.5, {}), 0)
  h.almost(shapes.value("triangle", 0.75, {}), -1)
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

-- pulse width changes square duty
h.test("pulse width duty", function()
  h.eq(shapes.value("square", 0.2, { pulseWidth = 0.25 }), 1)
  h.eq(shapes.value("square", 0.3, { pulseWidth = 0.25 }), -1)
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
  h.almost(shapes.value("triangle", 0.1, { smooth = 0 }), 0.4)        -- 4*0.1
  h.almost(shapes.value("triangle", 0.1, { smooth = 1 }), -math.cos(2 * math.pi * 0.1))
end)

-- randomAt is deterministic and in range
h.test("randomAt deterministic in range", function()
  local a = shapes.randomAt(42, 3)
  local b = shapes.randomAt(42, 3)
  h.eq(a, b)
  h.truthy(a >= -1 and a <= 1, "in [-1,1]")
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

h.run()
