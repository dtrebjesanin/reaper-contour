-- core/starters.lua — "starting point" shapes for the custom draw pad, taken straight from the
-- toolkit's OWN emitters. One cycle of lfo.generate(id) IS the canonical sparse representation Generate
-- produces (right phase, right per-point CC shapes), so a starter is byte-identical to the generated
-- shape: sine = 3 pts (shape 2), rectified sine = 5 symmetric pts (3/4), square = 2 step pts (0), etc.
-- PURE (no Reaper): requires only core.lfo (+ core.shapes for the cycle-end value). lfo->shapes; no cycle.
local lfo = require("core.lfo")
local shapes = require("core.shapes")
local M = {}

-- Offered as starting points (ids accepted by lfo.generate), in dropdown order. Periodic waveforms
-- only — None/Random/Drift/Custom aren't meaningful seeds; Parametric is the same wave as Sine.
M.list = {
  { id = "sine",      name = "Sine" },
  { id = "triangle",  name = "Triangle" },
  { id = "saw",       name = "Saw Up" },
  { id = "sawdown",   name = "Saw Down" },
  { id = "square",    name = "Square" },
  { id = "trapezoid", name = "Trapezoid" },
  { id = "rectsine",  name = "Rectified sine" },
  { id = "sine2",     name = "Sine\xc2\xb2" },
}

local function clamp1(v) if v < -1 then return -1 elseif v > 1 then return 1 end return v end

-- Custom points { x, y, shape, tension } = one cycle of shape `id` (full -1..1, CC ease convention).
function M.points(id)
  local raw = lfo.generate({ t0 = 0, t1 = 1 },
    { shape = id, rate = { mode = "free", cycles = 1 }, amplitude = 1, baseline = 0 })
  local pts = {}
  for _, q in ipairs(raw) do
    local x = q.time; if x < 0 then x = 0 elseif x > 1 then x = 1 end
    pts[#pts + 1] = { x = x, y = clamp1(q.value), shape = q.shape or 1, tension = q.tension or 0 }
  end
  -- Some shapes (e.g. square) end their last segment before x=1 (the final edge is the cycle boundary).
  -- The custom model needs an x=1 anchor or clampPoints would stretch the last point to 1. Add the
  -- cycle-END value so the loop boundary stays a clean jump.
  if #pts >= 1 and pts[#pts].x < 1 - 1e-6 then
    pts[#pts + 1] = { x = 1, y = clamp1(shapes.value(id, 1 - 1e-6)), shape = 1, tension = 0 }
  end
  if #pts < 2 then pts = { { x = 0, y = 0, shape = 1, tension = 0 }, { x = 1, y = 0, shape = 1, tension = 0 } } end
  return pts
end

return M
