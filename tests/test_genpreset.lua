package.path = package.path .. ";./Contour/?.lua;./?.lua;./tests/?.lua"
local h = require("harness")
local gp = require("core.genpreset")

h.test("encode/decode round-trips a multi-preset store", function()
  local store = {
    { name = "Pad wobble", params = { shapeIdx = 1, amplitude = 50, swing = 0.33, tilt = -20, steps = 0 } },
    { name = "Stutter", params = { shapeIdx = 5, steps = 8, smooth = 40, tiltR = 75 } },
  }
  local back = gp.decode(gp.encode(store))
  h.eq(#back, 2)
  h.eq(back[1].name, "Pad wobble")
  h.eq(back[1].params.shapeIdx, 1); h.eq(back[1].params.amplitude, 50)
  h.almost(back[1].params.swing, 0.33); h.eq(back[1].params.tilt, -20)
  h.eq(back[2].name, "Stutter")
  h.eq(back[2].params.steps, 8); h.eq(back[2].params.tiltR, 75)
end)

h.test("names with delimiters survive the round-trip", function()
  local store = { { name = "A|B~C;D=E %x", params = { phase = 25 } } }
  local back = gp.decode(gp.encode(store))
  h.eq(back[1].name, "A|B~C;D=E %x")
  h.eq(back[1].params.phase, 25)
end)

h.test("a preset carries an opaque embedded points string round-trip", function()
  local store = { { name = "Wob", params = { shapeIdx = 12, swing = 0.2 },
    points = "0,-1,1,0;0.5,1,5,0.6;1,-1,1,0" } }     -- contains ; and , (genpreset must escape ;)
  local back = gp.decode(gp.encode(store))
  h.eq(#back, 1)
  h.eq(back[1].points, "0,-1,1,0;0.5,1,5,0.6;1,-1,1,0")
  h.eq(back[1].params.shapeIdx, 12); h.almost(back[1].params.swing, 0.2)
end)

h.test("a preset WITHOUT points decodes with points = nil", function()
  local back = gp.decode(gp.encode({ { name = "NoShape", params = { shapeIdx = 1 } } }))
  h.eq(#back, 1)
  h.truthy(back[1].points == nil, "no embedded points")
end)

h.test("decode tolerates empty / malformed input", function()
  h.eq(#gp.decode(""), 0)
  h.eq(#gp.decode(nil), 0)
  local back = gp.decode("Only a name~")     -- no params -> empty params, still a preset
  h.eq(#back, 1); h.eq(back[1].name, "Only a name")
end)

h.test("a preset with no params encodes/decodes safely", function()
  local back = gp.decode(gp.encode({ { name = "Empty", params = {} } }))
  h.eq(#back, 1); h.eq(back[1].name, "Empty")
  local n = 0; for _ in pairs(back[1].params) do n = n + 1 end
  h.eq(n, 0)
end)

h.run()
