package.path = package.path .. ";./Contour/?.lua;./?.lua;./tests/?.lua"
local h = require("harness")
local starters = require("core.starters")
local shapes = require("core.shapes")
local cs = require("core.customshape")

-- Evaluate a custom point list's value at intra-cycle x in [0,1] using the SAME eases the pad/engine
-- use (bezier via customshape.bezierFrac, the sine eases, linear), so we can compare to shapes.value.
local function evalCurve(pts, x)
  for i = 1, #pts - 1 do
    local a, b = pts[i], pts[i + 1]
    if x >= a.x - 1e-9 and x <= b.x + 1e-9 then
      local t = (b.x > a.x) and (x - a.x) / (b.x - a.x) or 0
      local s, e = a.shape or 1, nil
      if s == 5 then e = cs.bezierFrac(t, a.tension or 0)
      elseif s == 2 then e = (1 - math.cos(math.pi * t)) / 2
      elseif s == 3 then e = math.sin(math.pi * t / 2)
      elseif s == 4 then e = 1 - math.cos(math.pi * t / 2)
      else e = t end
      return a.y + (b.y - a.y) * e
    end
  end
  return pts[#pts].y
end

h.test("starters.list is non-empty and well-formed", function()
  h.truthy(#starters.list >= 5, "several starting shapes")
  for _, s in ipairs(starters.list) do
    h.truthy(s.id and #s.id > 0, "has id")
    h.truthy(s.name and #s.name > 0, "has name")
  end
end)

h.test("each starter is a valid sparse point list (endpoints, ascending x)", function()
  for _, s in ipairs(starters.list) do
    local pts = starters.points(s.id)
    h.truthy(#pts >= 2, s.name .. ": >=2 points")
    h.almost(pts[1].x, 0, 1e-9, s.name .. ": starts at x=0")
    h.almost(pts[#pts].x, 1, 1e-9, s.name .. ": ends at x=1")
    for i = 2, #pts do h.truthy(pts[i].x >= pts[i - 1].x, s.name .. ": x ascending") end
    for _, p in ipairs(pts) do
      h.truthy(p.y >= -1.0001 and p.y <= 1.0001, s.name .. ": y in range")
      h.truthy(p.shape >= 0 and p.shape <= 5, s.name .. ": valid shape")
    end
  end
end)

h.test("each starter reproduces the toolkit's OWN shape (matches shapes.value within tolerance)", function()
  for _, s in ipairs(starters.list) do
    local pts = starters.points(s.id)
    local maxErr = 0
    for i = 0, 256 do
      local x = i / 256
      local e = math.abs(evalCurve(pts, x) - shapes.value(s.id, x))
      if e > maxErr then maxErr = e end
    end
    h.truthy(maxErr <= 0.012, s.name .. ": reconstructs shapes.value (maxErr=" .. string.format("%.4f", maxErr) .. ")")
  end
end)

h.test("sine starter is the -cos phase (starts at the trough, peaks mid-cycle)", function()
  local pts = starters.points("sine")
  h.almost(evalCurve(pts, 0), -1, 0.01, "sine starts at -1 (trough), like base.sine")
  h.almost(evalCurve(pts, 0.5), 1, 0.01, "sine peaks at mid-cycle")
end)

h.run()
