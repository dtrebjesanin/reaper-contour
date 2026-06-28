package.path = package.path .. ";./Contour/?.lua;./?.lua;./tests/?.lua"
local h = require("harness")
local tr = require("core.transform")

h.test("curve: endpoints fixed for any knob/shape", function()
  for _, k in ipairs({-100, -40, 0, 40, 100}) do
    for _, s in ipairs({"power", "sine"}) do
      h.almost(tr.curve(0, k, s), 0, 1e-9, "f(0)")
      h.almost(tr.curve(1, k, s), 1, 1e-9, "f(1)")
    end
  end
end)

h.test("curve: knob 0 power is identity", function()
  h.almost(tr.curve(0.25, 0, "power"), 0.25, 1e-9)
  h.almost(tr.curve(0.5, 0, "power"), 0.5, 1e-9)
end)

h.test("curve: positive knob bends below the diagonal (power)", function()
  h.truthy(tr.curve(0.5, 100, "power") < 0.5, "steeper => 0.5^w < 0.5")
  h.truthy(tr.curve(0.5, 40, "power") < 0.5)
end)

h.test("curve: monotonic non-decreasing", function()
  local prev = -1
  for i = 0, 20 do
    local x = i / 20
    local f = tr.curve(x, 60, "sine")
    h.truthy(f >= prev - 1e-9, "monotonic at x=" .. x)
    prev = f
  end
end)

local function P(t, v) return { t = t, v = v, shape = 1, tension = 0, sel = true } end

h.test("stretch: factor 1 is identity", function()
  local out = tr.stretch({ P(0,0.2), P(1,0.5), P(2,0.8) }, 2, 1)
  h.eq(out[1].t, 0); h.eq(out[2].t, 1); h.eq(out[3].t, 2)
  h.eq(out[2].v, 0.5); h.eq(out[2].sel, true)  -- value + fields preserved
end)

h.test("stretch: factor 2 about right anchor expands to the left", function()
  local out = tr.stretch({ P(0,0), P(1,0), P(2,0) }, 2, 2)  -- anchor t=2
  h.almost(out[1].t, -2, 1e-9)   -- 2 + 2*(0-2)
  h.almost(out[2].t, 0,  1e-9)   -- 2 + 2*(1-2)
  h.almost(out[3].t, 2,  1e-9)   -- anchor fixed
end)

h.test("stretch: returns a new array, does not mutate input", function()
  local src = { P(0,0), P(1,0) }
  local out = tr.stretch(src, 1, 3)
  h.eq(src[1].t, 0, "input untouched")
  h.truthy(out ~= src)
end)

h.test("tilt right (linear): left end fixed, right end lifts by delta", function()
  local pts = { P(0,0.5), P(0.5,0.5), P(1,0.5) }
  local out = tr.tilt(pts, 0, 1, 0.4, { knob=0, shape="power", side="right", symmetrical=false })
  h.almost(out[1].v, 0.5, 1e-9)   -- relT 0, g 0
  h.almost(out[2].v, 0.7, 1e-9)   -- relT .5, g .5
  h.almost(out[3].v, 0.9, 1e-9)   -- relT 1, g 1
  h.eq(out[1].t, 0)               -- time preserved
end)

h.test("tilt left (linear): right end fixed, left end lifts", function()
  local out = tr.tilt({ P(0,0.5), P(1,0.5) }, 0, 1, 0.4, { knob=0, shape="power", side="left", symmetrical=false })
  h.almost(out[1].v, 0.9, 1e-9)
  h.almost(out[2].v, 0.5, 1e-9)
end)

h.test("tilt symmetrical: ends fixed, centre lifts (dome)", function()
  local out = tr.tilt({ P(0,0.5), P(0.5,0.5), P(1,0.5) }, 0, 1, 0.4, { knob=0, shape="power", side="right", symmetrical=true })
  h.almost(out[1].v, 0.5, 1e-9)
  h.almost(out[2].v, 0.9, 1e-9)   -- m=1 at centre
  h.almost(out[3].v, 0.5, 1e-9)
end)

h.test("vscale: knob 0 is affine (boundary->target, anchor fixed)", function()
  local out = tr.vscale({ P(0,0), P(1,0.5), P(2,1) }, 0, 1, 2, { knob=0, shape="power" })
  h.almost(out[1].v, 0,   1e-9)  -- anchor (v=0) fixed
  h.almost(out[2].v, 1.0, 1e-9)  -- v=0.5 -> 2x -> 1.0
  h.almost(out[3].v, 2.0, 1e-9)  -- boundary (v=1) -> target 2
  h.eq(out[2].t, 1); h.eq(out[2].sel, true)  -- coords/fields preserved
end)

h.test("vscale: anchor point never moves", function()
  local out = tr.vscale({ P(0,0.3), P(1,0.9) }, 0.3, 0.9, 0.6, { knob=50, shape="sine" })
  h.almost(out[1].v, 0.3, 1e-9)  -- v==anchorV => u=0 => unchanged for any knob/shape
end)

h.test("vscale: boundary always lands on target for any knob", function()
  for _, k in ipairs({-100, 0, 60, 100}) do
    local out = tr.vscale({ P(0,0), P(1,1) }, 0, 1, 1.5, { knob=k, shape="power" })
    h.almost(out[2].v, 1.5, 1e-9, "boundary->target at knob="..k)
    h.almost(out[1].v, 0,   1e-9, "anchor fixed at knob="..k)
  end
end)

h.test("vscale: positive knob compresses interior (moves less than affine)", function()
  local affine = tr.vscale({ P(0,0.5) }, 0, 1, 2, { knob=0,   shape="power" })[1].v  -- = 1.0
  local comp   = tr.vscale({ P(0,0.5) }, 0, 1, 2, { knob=100, shape="power" })[1].v
  h.truthy(comp < affine, "compressed interior point moves less")
  h.truthy(comp > 0.5,    "but still moves toward the boundary")
end)

h.test("vscale: symmetrical (anchor=centre) mirrors the far edge", function()
  -- box [0,1], centre 0.5; drag top (1) to 1.5 => bottom (0) mirrors to -0.5
  local out = tr.vscale({ P(0,0), P(1,0.5), P(2,1) }, 0.5, 1, 1.5, { knob=0, shape="power" })
  h.almost(out[2].v, 0.5,  1e-9)  -- centre fixed
  h.almost(out[3].v, 1.5,  1e-9)  -- top -> target
  h.almost(out[1].v, -0.5, 1e-9)  -- bottom mirrors
end)

-- Regression: copy() must respect a computed 0 on either axis (Lua falsy-zero trap). Common in slice 2:
-- values scaled/flipped to exactly 0 (pan/pitch/mute lanes), or times reversed to project start.
h.test("copy: a value computed to exactly 0 is kept (not the original)", function()
  local out = tr.vscale({ P(0, 1) }, 0, 1, 0, { knob = 0, shape = "power" })  -- boundary v=1 -> target 0
  h.almost(out[1].v, 0, 1e-9)  -- must be 0, not the original 1
end)

h.test("copy: a time computed to exactly 0 is kept (not the original)", function()
  local out = tr.stretch({ P(4, 0.5) }, 2, -1)  -- t' = 2 + (-1)*(4-2) = 0
  h.almost(out[1].t, 0, 1e-9)  -- must be 0, not the original 4
end)

h.test("warp value: edge points pinned, cursor point lifts by ~delta", function()
  -- box t∈[0,2]; cursor over the middle (relT 0.5); lift by 0.4
  local out = tr.warp({ P(0,0.5), P(1,0.5), P(2,0.5) }, "value", 0, 2, 0.5, 0.4, { knob=0, shape="power" })
  h.almost(out[1].v, 0.5, 1e-9)  -- left edge pinned (weight 0)
  h.almost(out[3].v, 0.5, 1e-9)  -- right edge pinned
  h.almost(out[2].v, 0.9, 1e-9)  -- peak: 0.5 + 0.4*1
  h.eq(out[2].t, 1)              -- value-warp leaves time untouched
end)

h.test("warp value: knob 0 power gives a linear (triangular) ramp to the peak", function()
  local out = tr.warp({ P(0,0), P(0.5,0), P(1,0) }, "value", 0, 1, 1.0, 1.0, { knob=0, shape="power" })
  h.almost(out[1].v, 0.0, 1e-9)  -- relT 0   -> weight 0
  h.almost(out[2].v, 0.5, 1e-9)  -- relT 0.5 -> weight 0.5 (peak at relT 1)
  h.almost(out[3].v, 1.0, 1e-9)  -- relT 1   -> weight 1
end)

h.test("warp time: edges pinned in time, interior shifts", function()
  local out = tr.warp({ P(0,0), P(1,0), P(2,0) }, "time", 0, 2, 0.5, 0.5, { knob=0, shape="power" })
  h.almost(out[1].t, 0, 1e-9)    -- left edge pinned
  h.almost(out[3].t, 2, 1e-9)    -- right edge pinned
  h.almost(out[2].t, 1.5, 1e-9)  -- middle (peak) shifts by delta
  h.eq(out[2].v, 0)              -- time-warp leaves value untouched
end)

h.test("warp: delta 0 is identity", function()
  local out = tr.warp({ P(0,0.2), P(1,0.8) }, "value", 0, 1, 0.5, 0, { knob=40, shape="sine" })
  h.almost(out[1].v, 0.2, 1e-9); h.almost(out[2].v, 0.8, 1e-9)
end)

h.test("reverse: mirrors time about the box, twice is identity", function()
  local out = tr.reverse({ P(0,0.1), P(0.5,0.2), P(2,0.3) }, 0, 2)
  h.almost(out[1].t, 2,   1e-9)  -- 0+2-0
  h.almost(out[2].t, 1.5, 1e-9)  -- 0+2-0.5
  h.almost(out[3].t, 0,   1e-9)  -- 0+2-2
  h.eq(out[1].v, 0.1)            -- value untouched
  local back = tr.reverse(out, 0, 2)
  h.almost(back[1].t, 0, 1e-9); h.almost(back[3].t, 2, 1e-9)
end)

h.test("flip: mirrors value about (lo+hi)/2, twice is identity", function()
  local out = tr.flip({ P(0,0), P(1,0.25), P(2,1) }, 0, 1)  -- centre 0.5
  h.almost(out[1].v, 1.0,  1e-9)
  h.almost(out[2].v, 0.75, 1e-9)
  h.almost(out[3].v, 0.0,  1e-9)
  h.eq(out[1].t, 0)            -- time untouched
  local back = tr.flip(out, 0, 1)
  h.almost(back[2].v, 0.25, 1e-9)
end)

h.test("flip: value at the centre stays put", function()
  local out = tr.flip({ P(0,0.5) }, 0, 1)
  h.almost(out[1].v, 0.5, 1e-9)
end)

h.test("warp2d: peak follows the cursor in BOTH t and v, edges pinned", function()
  local out = tr.warp2d({ P(0,0.5), P(1,0.5), P(2,0.5) }, 0, 2, 0.5, 0.3, 0.4, { knob=0, shape="power" })
  h.almost(out[1].t, 0,   1e-9); h.almost(out[1].v, 0.5, 1e-9)  -- left edge pinned both axes
  h.almost(out[3].t, 2,   1e-9); h.almost(out[3].v, 0.5, 1e-9)  -- right edge pinned both axes
  h.almost(out[2].t, 1.3, 1e-9)  -- peak time: 1 + 0.3*1
  h.almost(out[2].v, 0.9, 1e-9)  -- peak value: 0.5 + 0.4*1
end)

h.test("warp2d: zero deltas is identity", function()
  local out = tr.warp2d({ P(0,0.2), P(1,0.8) }, 0, 1, 0.5, 0, 0, { knob=40, shape="sine" })
  h.almost(out[1].t, 0, 1e-9); h.almost(out[1].v, 0.2, 1e-9)
  h.almost(out[2].t, 1, 1e-9); h.almost(out[2].v, 0.8, 1e-9)
end)

h.test("warp2d: a hard time-warp keeps times strictly increasing (no folding)", function()
  -- raw warp would collapse t=3,4,5 onto 5 (1,3,5,5,5); the monotonic clamp must keep them ordered
  local out = tr.warp2d({ P(1,0), P(2,0), P(3,0), P(4,0), P(5,0) }, 1, 5, 0.5, 2, 0, { knob=0, shape="power" })
  for i = 2, #out do h.truthy(out[i].t > out[i-1].t, "strictly increasing at index " .. i) end
end)

-- Degenerate span: vscale with anchorV==boundaryV (zero-height box) must return input unchanged
-- and produce no NaN.
h.test("vscale: zero-height box (anchorV==boundaryV) returns input unchanged, no NaN", function()
  local pts = { P(0, 0.5), P(1, 0.8) }
  -- anchorV == boundaryV: span=0, every u is 0, no scaling occurs
  local out = tr.vscale(pts, 0.5, 0.5, 1.5, { knob = 0, shape = "power" })
  for i = 1, #pts do
    h.truthy(out[i].v == out[i].v, "no NaN at index " .. i)  -- NaN != NaN
    h.almost(out[i].v, pts[i].v, 1e-9, "value unchanged at index " .. i)
  end
end)

-- Degenerate time span: tilt with tmin==tmax must return finite, unchanged values.
h.test("tilt: zero time span (tmin==tmax) returns finite, unchanged values", function()
  local pts = { P(5, 0.3), P(5, 0.7) }
  local out = tr.tilt(pts, 5, 5, 0.4, { knob = 0, shape = "power", side = "right", symmetrical = false })
  for i = 1, #pts do
    h.truthy(out[i].v == out[i].v, "no NaN at index " .. i)
    h.almost(out[i].v, pts[i].v, 1e-9, "value unchanged at index " .. i)
  end
end)

-- Degenerate time span: warp with tmin==tmax must return finite, unchanged values.
h.test("warp: zero time span (tmin==tmax) returns finite, unchanged values", function()
  local pts = { P(3, 0.2), P(3, 0.9) }
  local out = tr.warp(pts, "value", 3, 3, 0.5, 0.4, { knob = 0, shape = "power" })
  for i = 1, #pts do
    h.truthy(out[i].v == out[i].v, "no NaN at index " .. i)
    h.almost(out[i].t, pts[i].t, 1e-9, "time unchanged at index " .. i)
  end
end)

h.run()
