-- core/starters.lua — "starting point" shapes for the custom draw pad, built from the toolkit's OWN
-- developed waveforms. One cycle of shapes.value(id) is densely sampled, then thinned with
-- reduce.thinCurve so the result is a SPARSE set of custom points (REAPER CC ease shapes + tension)
-- that reproduces the real shape within tolerance. Using shapes.value guarantees a starter IS the same
-- shape Generate produces (same phase: sine starts at the trough, square starts low, etc.).
-- PURE (no Reaper): requires only core.shapes + core.reduce. (reduce->customshape; no cycle here.)
local shapes = require("core.shapes")
local reduce = require("core.reduce")
local M = {}

-- Offered as starting points (ids accepted by shapes.value), in dropdown order. Periodic waveforms
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

local N = 256        -- dense one-cycle sampling resolution
local EPS = 0.004    -- reduce amount (eps = EPS * value range 2 = 0.008 value units)

-- Custom points { x, y, shape, tension } reproducing one cycle of shape `id` (CC ease convention).
-- Falls back to a flat line for an unknown id.
function M.points(id)
  local raw = {}
  for i = 0, N do local x = i / N; raw[#raw + 1] = { time = x, value = shapes.value(id, x) } end
  local kept = reduce.thinCurve(raw, EPS, { vmin = -1, vmax = 1 })   -- CC convention (linear = 1)
  local pts = {}
  for _, p in ipairs(kept) do
    pts[#pts + 1] = { x = p.time, y = p.value, shape = p.shape or 1, tension = p.tension or 0 }
  end
  if #pts < 2 then pts = { { x = 0, y = 0, shape = 1, tension = 0 }, { x = 1, y = 0, shape = 1, tension = 0 } } end
  return pts
end

return M
