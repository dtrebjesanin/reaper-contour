package.path = package.path .. ";./Contour/?.lua;./?.lua;./tests/?.lua"
local h   = require("harness")
local num = require("core.num")

-- clamp
h.test("clamp: below lo", function() h.eq(num.clamp(-5, 0, 1), 0) end)
h.test("clamp: above hi", function() h.eq(num.clamp(10, 0, 1), 1) end)
h.test("clamp: in range", function() h.eq(num.clamp(0.5, 0, 1), 0.5) end)
h.test("clamp: at lo boundary", function() h.eq(num.clamp(0, 0, 1), 0) end)
h.test("clamp: at hi boundary", function() h.eq(num.clamp(1, 0, 1), 1) end)
h.test("clamp: negative range midpoint", function() h.eq(num.clamp(-0.3, -1, 1), -0.3) end)
h.test("clamp: below negative lo", function() h.eq(num.clamp(-2, -1, 1), -1) end)
h.test("clamp: above negative hi", function() h.eq(num.clamp(2, -1, 1), 1) end)

-- clamp01
h.test("clamp01: negative", function() h.eq(num.clamp01(-0.1), 0) end)
h.test("clamp01: above 1", function() h.eq(num.clamp01(1.1), 1) end)
h.test("clamp01: midpoint", function() h.eq(num.clamp01(0.5), 0.5) end)
h.test("clamp01: zero", function() h.eq(num.clamp01(0), 0) end)
h.test("clamp01: one", function() h.eq(num.clamp01(1), 1) end)

-- lerp
h.test("lerp: t=0 returns a", function() h.eq(num.lerp(2, 8, 0), 2) end)
h.test("lerp: t=1 returns b", function() h.eq(num.lerp(2, 8, 1), 8) end)
h.test("lerp: t=0.5 midpoint", function() h.eq(num.lerp(2, 8, 0.5), 5) end)
h.test("lerp: negative range", function() h.almost(num.lerp(-1, 1, 0.5), 0) end)
h.test("lerp: t=0.25", function() h.almost(num.lerp(0, 4, 0.25), 1) end)

-- frac
h.test("frac: positive integer", function() h.eq(num.frac(3.0), 0) end)
h.test("frac: positive fraction", function() h.almost(num.frac(2.75), 0.75) end)
h.test("frac: negative (floor-based)", function() h.almost(num.frac(-0.25), 0.75) end)
h.test("frac: zero", function() h.eq(num.frac(0), 0) end)
h.test("frac: result always in [0,1)", function()
  for _, x in ipairs({ -3.7, -1, -0.1, 0, 0.5, 1, 2.9, 100.0 }) do
    local f = num.frac(x)
    h.truthy(f >= 0 and f < 1, "frac("..tostring(x)..") = "..tostring(f))
  end
end)

h.run()
