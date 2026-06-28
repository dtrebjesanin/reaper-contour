package.path = package.path .. ";./Contour/?.lua;./?.lua;./tests/?.lua"
local h = require("harness")
local cs = require("core.customshape")

h.test("defaultPreset is a valid 3-point preset", function()
  local p = cs.defaultPreset()
  h.truthy(p.name and #p.name > 0, "has a name")
  h.eq(#p.points, 3)
  h.eq(p.points[1].x, 0); h.eq(p.points[#p.points].x, 1)
end)

h.test("encode/decode round-trips a multi-preset store (with tricky names)", function()
  local store = {
    { name = "Wub|3 ;,~ test", points = { { x = 0, y = -1, shape = 1, tension = 0 },
      { x = 0.4, y = 0.5, shape = 5, tension = -0.3 }, { x = 1, y = 1, shape = 2, tension = 0 } } },
    { name = "Plain", points = { { x = 0, y = 0, shape = 1, tension = 0 }, { x = 1, y = 0, shape = 1, tension = 0 } } },
  }
  local back = cs.decode(cs.encode(store))
  h.eq(#back, 2)
  h.eq(back[1].name, "Wub|3 ;,~ test")
  h.eq(#back[1].points, 3)
  h.almost(back[1].points[2].x, 0.4); h.almost(back[1].points[2].y, 0.5)
  h.eq(back[1].points[2].shape, 5); h.almost(back[1].points[2].tension, -0.3)
  h.eq(back[2].name, "Plain")
end)

h.test("decode tolerates empty / malformed input", function()
  h.eq(#cs.decode(""), 0)
  h.eq(#cs.decode("garbage~~~|||"), 0)   -- no valid presets -> empty store, no error
end)

h.test("clampPoints sorts, clamps, and pins endpoints", function()
  local out = cs.clampPoints({ { x = 0.9, y = 5, shape = 9, tension = 3 },
    { x = -0.2, y = -5, shape = 1, tension = 0 }, { x = 0.5, y = 0, shape = 5, tension = -0.4 } })
  h.eq(#out, 3)
  h.eq(out[1].x, 0); h.eq(out[#out].x, 1)                 -- endpoints pinned
  for _, p in ipairs(out) do
    h.truthy(p.y >= -1 and p.y <= 1, "y clamped")
    h.truthy(p.shape >= 0 and p.shape <= 5, "shape clamped")
    h.truthy(p.tension >= -1 and p.tension <= 1, "tension clamped")
  end
  for i = 2, #out do h.truthy(out[i].x >= out[i-1].x, "x ascending") end
end)

h.run()
