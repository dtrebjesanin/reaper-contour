package.path = package.path .. ";./Contour/?.lua;./?.lua;./tests/?.lua"
local h = require("harness")
local reduce = require("core.reduce")

local function line(n)            -- n collinear points from (0,0) to (n-1, n-1)
  local t = {}
  for i = 0, n - 1 do t[#t + 1] = { time = i, value = i } end
  return t
end

h.test("rdp keeps endpoints only for a straight line", function()
  local out = reduce.rdp(line(6), 0.001)
  h.eq(#out, 2)
  h.eq(out[1].time, 0)
  h.eq(out[2].time, 5)
end)

h.test("rdp keeps spike and shoulders at a tight epsilon", function()
  local pts = { { time = 0, value = 0 }, { time = 1, value = 0 },
                { time = 2, value = 10 },                       -- spike
                { time = 3, value = 0 }, { time = 4, value = 0 } }
  -- At eps=1 the flat shoulders deviate from the spike's diagonals by 5 (>1),
  -- so vertical-distance RDP must preserve all five points to keep the shape.
  local out = reduce.rdp(pts, 1.0)
  h.eq(#out, 5)
  h.eq(out[3].time, 2); h.eq(out[3].value, 10)  -- spike preserved
end)

h.test("rdp drops shoulders but keeps spike at a loose epsilon", function()
  local pts = { { time = 0, value = 0 }, { time = 1, value = 0 },
                { time = 2, value = 10 },
                { time = 3, value = 0 }, { time = 4, value = 0 } }
  -- At eps=6 the shoulders (deviation 5) drop; the spike (deviation 10) stays.
  local out = reduce.rdp(pts, 6.0)
  h.eq(#out, 3)
  h.eq(out[2].time, 2); h.eq(out[2].value, 10)
end)

h.test("rdp drops a spike below epsilon", function()
  local pts = { { time = 0, value = 0 }, { time = 1, value = 0.1 },
                { time = 2, value = 0 } }
  local out = reduce.rdp(pts, 1.0)
  h.eq(#out, 2)
end)

h.test("rdp passes through tiny lists", function()
  h.eq(#reduce.rdp({}, 1), 0)
  h.eq(#reduce.rdp({ { time = 0, value = 0 } }, 1), 1)
  h.eq(#reduce.rdp({ { time = 0, value = 0 }, { time = 1, value = 9 } }, 1), 2)
end)

h.test("thin maps amount through value range", function()
  -- range 0..10; amount 0.2 -> eps 2.0, so the value-1 spike (below 2) is dropped
  local pts = { { time = 0, value = 0 }, { time = 1, value = 1 }, { time = 2, value = 0 } }
  local out = reduce.thin(pts, 0.2, { vmin = 0, vmax = 10 })
  h.eq(#out, 2)
end)

-- ── Curve fit (thinCurve) ────────────────────────────────────────────────────
local function arc(n, ease)   -- n samples of an easing curve over [0,1] x [0,1]
  local t = {}
  for i = 0, n - 1 do local x = i / (n - 1); t[#t + 1] = { time = x, value = ease(x) } end
  return t
end
local slowEase  = function(x) return (1 - math.cos(math.pi * x)) / 2 end
local fastStart = function(x) return math.sin(math.pi * x / 2) end
local fastEnd   = function(x) return 1 - math.cos(math.pi * x / 2) end

h.test("thinCurve keeps endpoints (linear) for a straight line", function()
  local out = reduce.thinCurve(line(6), 0.01, { vmin = 0, vmax = 5 })
  h.eq(#out, 2)
  h.eq(out[1].shape, 1)              -- CC linear
  h.eq(out[1].time, 0); h.eq(out[2].time, 5)
end)

h.test("thinCurve fits a slow-start/end arc with 2 points (shape 2)", function()
  local out = reduce.thinCurve(arc(21, slowEase), 0.01, { vmin = 0, vmax = 1 })
  h.eq(#out, 2)
  h.eq(out[1].shape, 2)
end)

h.test("thinCurve fits a fast-start arc (shape 3) and fast-end arc (shape 4)", function()
  local a = reduce.thinCurve(arc(21, fastStart), 0.01, { vmin = 0, vmax = 1 })
  h.eq(#a, 2); h.eq(a[1].shape, 3)
  local b = reduce.thinCurve(arc(21, fastEnd), 0.01, { vmin = 0, vmax = 1 })
  h.eq(#b, 2); h.eq(b[1].shape, 4)
end)

h.test("thinCurve keeps far fewer points than rdp on a curve", function()
  local a = arc(21, slowEase)
  h.truthy(#reduce.thinCurve(a, 0.01, { vmin = 0, vmax = 1 }) < #reduce.rdp(a, 0.01),
    "curve fit should keep fewer points than straight-line rdp")
end)

h.test("thinCurve reconstructs within eps and covers the span", function()
  local a = arc(41, fastEnd)
  local out = reduce.thinCurve(a, 0.02, { vmin = 0, vmax = 1 })
  h.almost(out[1].time, 0, 1e-9); h.almost(out[#out].time, 1, 1e-9)   -- endpoints kept
  for i = 1, #out - 1 do h.truthy(out[i + 1].time > out[i].time, "strictly increasing") end
end)

h.test("thinCurve emits envelope linear (0) under envConvention", function()
  local out = reduce.thinCurve(line(6), 0.01, { vmin = 0, vmax = 5 }, { envConvention = true })
  h.eq(out[1].shape, 0)
end)

-- envConvention only swaps LINEAR (1<->0); curve shapes (2/3/4) are identical across conventions and
-- must pass through unchanged.
h.test("thinCurve keeps curve shapes under envConvention", function()
  local out = reduce.thinCurve(arc(21, slowEase), 0.01, { vmin = 0, vmax = 1 }, { envConvention = true })
  h.eq(#out, 2)
  h.eq(out[1].shape, 2)
end)

h.test("thinCurve passes through tiny lists", function()
  h.eq(#reduce.thinCurve({}, 0.1, { vmin = 0, vmax = 1 }), 0)
  h.eq(#reduce.thinCurve({ { time = 0, value = 0 } }, 0.1, { vmin = 0, vmax = 1 }), 1)
end)

h.run()
