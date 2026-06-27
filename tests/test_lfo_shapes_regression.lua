package.path = package.path .. ";./Contour/?.lua;./?.lua;./tests/?.lua"
local h = require("harness")
local lfo = require("core.lfo")

-- Regression guards for the NEW Generate shapes against failure modes the native shapes hit:
--  (1) DENSIFICATION: amp/freq skew must NOT change the point count (the old bug routed skewed
--      shapes to the dense sampler). (2) ENDPOINTS: first point at t0, last at t1 (full coverage).
--  (3) NO STRAY/DUP/FOLDED POINTS: times strictly increasing. (4) FINITE values.
local SPAN = { t0 = 0, t1 = 4 }
local CASES = {
  { name = "sawdown",   p = { shape = "sawdown" } },
  { name = "trapezoid", p = { shape = "trapezoid", edge = 0.25 } },
  { name = "rectsine",  p = { shape = "rectsine" } },
  { name = "sine2",     p = { shape = "sine2" } },
  { name = "random",    p = { shape = "random", seed = 7 } },
  { name = "drift",     p = { shape = "drift",  seed = 7 } },
  { name = "pump",      p = { shape = "pump",  curve = 50 } },
  { name = "ad",        p = { shape = "ad",    curve = 50, attack = 30 } },
}

local function params(base, extra)
  local p = { rate = { mode = "free", cycles = 4 }, amplitude = 1, baseline = 0 }
  for k, v in pairs(base) do p[k] = v end
  if extra then for k, v in pairs(extra) do p[k] = v end end
  return p
end

-- checkCase runs both invariant checks for a single shape case at the given cycle count.
local function checkCase(c, cycles)
  local tag = c.name .. " (cycles=" .. tostring(cycles) .. ")"

  h.test(tag .. ": amp/freq skew does not densify (point count stable)", function()
    local plain  = lfo.generate(SPAN, params(c.p, { rate = { mode = "free", cycles = cycles } }))
    local skewed = lfo.generate(SPAN, params(c.p, { rate = { mode = "free", cycles = cycles }, freqSkew = 0.8, ampSkew = 0.7 }))
    h.eq(#skewed, #plain, tag .. " point count changed under skew")
  end)

  h.test(tag .. ": clean point set (endpoints, strictly increasing, finite)", function()
    local pts = lfo.generate(SPAN, params(c.p, { rate = { mode = "free", cycles = cycles } }))
    h.truthy(#pts >= 2, tag .. " produced too few points")
    h.almost(pts[1].time,    SPAN.t0, 1e-9, tag .. " first point not at t0")
    h.almost(pts[#pts].time, SPAN.t1, 1e-9, tag .. " last point not at t1")
    for i = 1, #pts do
      local v = pts[i].value
      h.truthy(v == v and v ~= math.huge and v ~= -math.huge, tag .. " non-finite value")
      if i > 1 then
        h.truthy(pts[i].time > pts[i-1].time, tag .. " times not strictly increasing (stray/dup/folded)")
      end
    end
  end)
end

for _, c in ipairs(CASES) do
  checkCase(c, 4)
  checkCase(c, 2.5)
end

h.run()
