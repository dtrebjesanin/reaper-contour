-- core/reduce.lua — pure vertical-distance Ramer–Douglas–Peucker thinning. No Reaper, no I/O.
-- Distance is measured VERTICALLY: |value - the value linearly interpolated between the segment
-- endpoints at this point's time|. This keeps the tolerance purely in value units and invariant to
-- the span's time scale, so the same Reduction amount thins a 2-second and a 200-second span
-- identically (design spec, "Phase 1B — Reduce": tolerance normalized against the value range).
-- Perpendicular distance would mix time and value units and break that span-invariance.
local M = {}
local abs = math.abs

function M.rdp(points, eps)
  local n = #points
  if n <= 2 then
    local out = {}
    for i = 1, n do out[i] = points[i] end
    return out
  end

  local first, last = points[1], points[n]
  local dx = last.time - first.time
  local maxd, idx = -1, 0
  for i = 2, n - 1 do
    local p = points[i]
    local yline
    if dx == 0 then
      yline = first.value
    else
      yline = first.value + (last.value - first.value) * (p.time - first.time) / dx
    end
    local d = abs(p.value - yline)
    if d > maxd then maxd = d; idx = i end
  end

  if maxd > eps then
    local left = {}
    for i = 1, idx do left[i] = points[i] end
    local right = {}
    for i = idx, n do right[#right + 1] = points[i] end
    local rl = M.rdp(left, eps)
    local rr = M.rdp(right, eps)
    local out = {}
    for i = 1, #rl do out[i] = rl[i] end
    for i = 2, #rr do out[#out + 1] = rr[i] end   -- skip the shared junction point
    return out
  else
    return { first, last }
  end
end

function M.thin(points, amount, valueRange)
  local span = (valueRange and (valueRange.vmax - valueRange.vmin)) or 1
  local eps = (amount or 0) * span
  return M.rdp(points, eps)
end

-- ── Curve-aware thinning (Curve fit) ─────────────────────────────────────────
-- Like rdp, but each stretch is tested against REAPER's PER-POINT interpolation shapes, not just a
-- straight chord. Where a curve fits within eps (VERTICAL error, value units — same metric as rdp),
-- only the two endpoints are kept and the first is tagged with that shape. Value = v0 + (v1-v0)*e(x).
-- The eases match REAPER's rendering: slow start/end is the native-sine arc; fast start/end are the
-- quarter-sine eases that compose the native parametric sine (both proven by test_native_match.lua).
local cos, sin, pi = math.cos, math.sin, math.pi
local CANDIDATES = {
  { shape = 1, ease = function(x) return x end },                       -- linear
  { shape = 2, ease = function(x) return (1 - cos(pi * x)) / 2 end },   -- slow start/end (S-curve)
  { shape = 3, ease = function(x) return sin(pi * x / 2) end },         -- fast start (ease-out)
  { shape = 4, ease = function(x) return 1 - cos(pi * x / 2) end },     -- fast end  (ease-in)
}

local function withShape(p, shape)
  return { time = p.time, value = p.value, shape = shape, tension = 0, sel = p.sel }
end

-- Best-fitting candidate for the chord points[i]..points[j]: the shape with the smallest MAX vertical
-- error over the interior points, plus that error and the interior index where it peaks (split point).
local function fitOne(points, i, j)
  local p0, p1 = points[i], points[j]
  local dt, dv = p1.time - p0.time, p1.value - p0.value
  local best
  for _, cand in ipairs(CANDIDATES) do
    local maxErr, maxK = 0, i + 1
    for k = i + 1, j - 1 do
      local pk = points[k]
      local x = (dt == 0) and 0 or (pk.time - p0.time) / dt
      local e = abs(pk.value - (p0.value + dv * cand.ease(x)))
      if e > maxErr then maxErr, maxK = e, k end
    end
    if not best or maxErr < best.err then best = { shape = cand.shape, err = maxErr, splitIdx = maxK } end
  end
  return best
end

-- Kept points for the half-open range [i, j) (i included, j NOT — the caller appends the final point).
-- Accept the whole stretch as one curved segment if a candidate fits within eps, else split at the
-- worst point and recurse.
local function fitRange(points, i, j, eps, linearShape)
  if j <= i + 1 then return { withShape(points[i], linearShape) } end   -- adjacent: straight chord
  local best = fitOne(points, i, j)
  if best.err <= eps then
    local s = (best.shape == 1) and linearShape or best.shape
    return { withShape(points[i], s) }
  end
  local out = fitRange(points, i, best.splitIdx, eps, linearShape)
  for _, p in ipairs(fitRange(points, best.splitIdx, j, eps, linearShape)) do out[#out + 1] = p end
  return out
end

-- Curve-aware thinning. `amount`/`valueRange` mirror M.thin (eps = amount * value-range). opts:
--   { envConvention = bool }  -- emit linear as 0 (envelope/AI) instead of 1 (CC). Curves 2-4 are
--                                identical across conventions. Returns kept point COPIES with .shape
--                                (target convention) and .tension = 0.
function M.thinCurve(points, amount, valueRange, opts)
  local n = #points
  opts = opts or {}
  local linearShape = opts.envConvention and 0 or 1
  if n <= 2 then
    local out = {}
    for k = 1, n do out[k] = withShape(points[k], linearShape) end
    return out
  end
  local span = (valueRange and (valueRange.vmax - valueRange.vmin)) or 1
  local eps = (amount or 0) * span
  local kept = fitRange(points, 1, n, eps, linearShape)
  kept[#kept + 1] = withShape(points[n], linearShape)   -- terminal point (no outgoing segment)
  return kept
end

return M
