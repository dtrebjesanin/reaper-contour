package.path = package.path .. ";./Contour/?.lua;./?.lua;./tests/?.lua"
local h = require("harness")
local ac = require("core.arrangecoords")

h.test("timeToX maps endpoints and midpoint", function()
  h.almost(ac.timeToX(10, 10, 20, 100, 300), 100, 1e-9)
  h.almost(ac.timeToX(20, 10, 20, 100, 300), 300, 1e-9)
  h.almost(ac.timeToX(15, 10, 20, 100, 300), 200, 1e-9)
end)

h.test("xToTime is the inverse of timeToX", function()
  for _, t in ipairs({10, 12.5, 17, 20}) do
    h.almost(ac.xToTime(ac.timeToX(t,10,20,100,300),10,20,100,300), t, 1e-9)
  end
end)

h.test("valueToY: higher value is nearer the top (smaller y)", function()
  -- value range 0..1 over screen y [50 (top) .. 250 (bottom)]
  h.almost(ac.valueToY(1, 0, 1, 50, 250), 50,  1e-9)  -- max -> top
  h.almost(ac.valueToY(0, 0, 1, 50, 250), 250, 1e-9)  -- min -> bottom
  h.almost(ac.valueToY(0.5, 0, 1, 50, 250), 150, 1e-9)
end)

h.test("yToValue is the inverse of valueToY", function()
  for _, v in ipairs({0, 0.3, 0.75, 1}) do
    h.almost(ac.yToValue(ac.valueToY(v,0,1,50,250),0,1,50,250), v, 1e-9)
  end
end)

h.test("degenerate ranges do not divide by zero", function()
  h.eq(ac.timeToX(5, 5, 5, 100, 300), 100)
  h.eq(ac.valueToY(0.5, 1, 1, 50, 250), 250)  -- vhi==vlo -> bottom (low endpoint)
end)

h.run()
