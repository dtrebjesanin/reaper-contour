-- tests/test_drawpad.lua — unit tests for the draw pad's PURE helpers (exposed test seams). The pad's
-- draw() is interactive (covered for crashes by test_render_smoke); here we pin the coordinate mapping
-- (data <-> screen) and the grid snapping that add/move points rely on, since those are easy to get
-- subtly wrong and have no other coverage. No reaper needed (these helpers never touch the API).
package.path = package.path .. ";./Contour/?.lua;./?.lua;./tests/?.lua"

local h       = require("harness")
local drawpad = require("ui.drawpad")

local X0, Y0, W, HGT = 100, 50, 360, 140

h.test("toScreen/toData round-trip across the pad interior", function()
  for _, x in ipairs({ 0, 0.25, 0.5, 0.9, 1 }) do
    for _, y in ipairs({ -1, -0.4, 0, 0.7, 1 }) do
      local sx, sy = drawpad._toScreen(x, y, X0, Y0, W, HGT)
      local rx, ry = drawpad._toData(sx, sy, X0, Y0, W, HGT)
      h.almost(rx, x, 1e-9, ("x round-trip %.3f"):format(x))
      h.almost(ry, y, 1e-9, ("y round-trip %.3f"):format(y))
    end
  end
end)

h.test("toScreen maps y=+1 to the top and y=-1 to the bottom (y is inverted on screen)", function()
  local _, topY = drawpad._toScreen(0.5, 1, X0, Y0, W, HGT)
  local _, botY = drawpad._toScreen(0.5, -1, X0, Y0, W, HGT)
  local _, midY = drawpad._toScreen(0.5, 0, X0, Y0, W, HGT)
  h.almost(topY, Y0, 1e-9)
  h.almost(botY, Y0 + HGT, 1e-9)
  h.almost(midY, Y0 + HGT / 2, 1e-9)
end)

h.test("toData clamps to the pad bounds [0,1] x [-1,1]", function()
  local x, y = drawpad._toData(X0 - 500, Y0 - 500, X0, Y0, W, HGT)   -- far above-left
  h.eq(x, 0); h.eq(y, 1)                                             -- x clamps to 0, y (inverted) to +1
  x, y = drawpad._toData(X0 + W + 500, Y0 + HGT + 500, X0, Y0, W, HGT)  -- far below-right
  h.eq(x, 1); h.eq(y, -1)
end)

h.test("snapTo snaps to the nearest of `divs` grid lines", function()
  h.almost(drawpad._snapTo(0.10, 0, 1, 4), 0.00)   -- 0.10*4=0.4 -> 0
  h.almost(drawpad._snapTo(0.13, 0, 1, 4), 0.25)   -- 0.13*4=0.52 -> 1
  h.almost(drawpad._snapTo(0.60, 0, 1, 4), 0.50)   -- 0.60*4=2.4 -> 2
  h.almost(drawpad._snapTo(0.90, 0, 1, 4), 1.00)   -- 0.90*4=3.6 -> 4
  -- grid for [-1,1] divs=2 is {-1, 0, 1}; 0.30 is nearest 0
  h.almost(drawpad._snapTo(0.30, -1, 1, 2), 0.00)
  h.almost(drawpad._snapTo(0.80, -1, 1, 2), 1.00)  -- nearest 1
end)

h.test("snapTo with divs<1 is a no-op (returns the value unchanged)", function()
  h.eq(drawpad._snapTo(0.37, 0, 1, 0), 0.37)
end)

h.run()
