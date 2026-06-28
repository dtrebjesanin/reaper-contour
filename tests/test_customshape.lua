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

-- bezierFrac reproduces REAPER's shape-5 bezier (schwa's tension->control-point model). Locking these
-- anchors guards the draw-pad preview against drifting away from REAPER's rendered curve.
h.test("bezierFrac matches REAPER's bezier (endpoints, neutral, sign, schwa anchors)", function()
  for _, T in ipairs({ -1, -0.5, 0, 0.4, 1 }) do                       -- endpoints exact for any tension
    h.almost(cs.bezierFrac(0, T), 0, 1e-9); h.almost(cs.bezierFrac(1, T), 1, 1e-9)
  end
  for _, t in ipairs({ 0.1, 0.25, 0.5, 0.75, 0.9 }) do                 -- no tension -> linear (T=0 is the chord)
    h.almost(cs.bezierFrac(t, 0), t, 1e-6)
  end
  h.almost(cs.bezierFrac(0.5, -0.6), 0.8748, 5e-3, "T=-0.6 midpoint (schwa-verified)")
  h.almost(cs.bezierFrac(0.5,  0.6), 0.1252, 5e-3, "T=+0.6 midpoint (schwa-verified)")
  h.truthy(cs.bezierFrac(0.5, -0.5) > 0.5, "negative tension reaches the end value early")
  h.truthy(cs.bezierFrac(0.5,  0.5) < 0.5, "positive tension clings to the start value")
  h.almost(cs.bezierFrac(0.5, -0.5) + cs.bezierFrac(0.5, 0.5), 1, 1e-6, "symmetric about T at the midpoint")
end)

h.test("bezierFrac is monotonic increasing in t", function()
  for _, T in ipairs({ -0.8, -0.3, 0.3, 0.8 }) do
    local prev = -1
    for i = 0, 20 do
      local f = cs.bezierFrac(i / 20, T)
      h.truthy(f >= prev - 1e-9, "monotone for T=" .. T)
      prev = f
    end
  end
end)

-- generateCustom repeats the preset at the Rate, scales by amplitude/baseline, carries shapes/tensions.
local lfo = require("core.lfo")
local function customPts(extra)
  local p = { shape = "custom", rate = { mode = "free", cycles = 3 }, amplitude = 1, baseline = 0,
    customPoints = { { x = 0, y = -1, shape = 1, tension = 0 }, { x = 0.5, y = 1, shape = 5, tension = 0.5 },
      { x = 1, y = -1, shape = 1, tension = 0 } } }
  for k, v in pairs(extra or {}) do p[k] = v end
  return lfo.generate({ t0 = 0, t1 = 3 }, p)
end

h.test("custom repeats at the rate and covers the span", function()
  local pts = customPts()
  h.truthy(#pts >= 3, "produced points")
  h.almost(pts[1].time, 0, 1e-9); h.almost(pts[#pts].time, 3, 1e-9)
  for i = 2, #pts do h.truthy(pts[i].time > pts[i-1].time, "strictly increasing") end
  -- 3 cycles -> at least 3 peaks (value near +1) somewhere
  local peaks = 0
  for _, p in ipairs(pts) do if math.abs(p.value - 1) < 1e-6 then peaks = peaks + 1 end end
  h.truthy(peaks >= 3, "one peak per cycle (got " .. peaks .. ")")
end)

h.test("custom carries per-point bezier shape + tension", function()
  local bez = false
  for _, p in ipairs(customPts()) do if p.shape == 5 and math.abs((p.tension or 0) - 0.5) < 1e-9 then bez = true end end
  h.truthy(bez, "the mid point's bezier shape+tension is carried through")
end)

h.test("custom amp/freq skew does not densify (count stable)", function()
  local a = customPts()
  local b = customPts({ ampSkew = 0.7, freqSkew = 0.8 })
  h.eq(#a, #b, "skew must not change the custom point count")
end)

h.test("custom degenerate (no points) is a safe flat line", function()
  local pts = lfo.generate({ t0 = 0, t1 = 2 }, { shape = "custom", customPoints = {},
    rate = { mode = "free", cycles = 2 }, amplitude = 1, baseline = 0 })
  h.truthy(#pts >= 2, "still covers the span")
  h.almost(pts[1].time, 0, 1e-9); h.almost(pts[#pts].time, 2, 1e-9)
end)

h.test("custom discontinuous shape ends on the cycle-END value", function()
  local pts = lfo.generate({ t0 = 0, t1 = 3 }, { shape = "custom",
    rate = { mode = "free", cycles = 3 }, amplitude = 1, baseline = 0,
    customPoints = { { x = 0, y = -1, shape = 1, tension = 0 }, { x = 1, y = 1, shape = 1, tension = 0 } } })
  h.almost(pts[#pts].time, 3, 1e-9)
  h.almost(pts[#pts].value, 1, 1e-6, "a rising-ramp custom must end at +1 (cycle end), not -1")
end)

h.run()
