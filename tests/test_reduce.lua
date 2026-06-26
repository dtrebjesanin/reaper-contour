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

h.run()
