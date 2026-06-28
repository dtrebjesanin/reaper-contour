-- core/reduce.lua — pure vertical-distance Ramer–Douglas–Peucker thinning. No Reaper, no I/O.
-- Distance is measured VERTICALLY: |value - the value linearly interpolated between the segment
-- endpoints at this point's time|. This keeps the tolerance purely in value units and invariant to
-- the span's time scale, so the same Reduction amount thins a 2-second and a 200-second span
-- identically (design spec, "Phase 1B — Reduce": tolerance normalized against the value range).
-- Perpendicular distance would mix time and value units and break that span-invariance.
local M = {}
local abs = math.abs
local customshape = require("core.customshape")   -- REAPER's exact shape-5 bezier (customshape.bezierFrac)

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
local CANDIDATES = {
  { shape = 1, ease = function(x) return customshape.segEase(1, x, 0) end },   -- linear
  { shape = 2, ease = function(x) return customshape.segEase(2, x, 0) end },   -- slow start/end (S-curve)
  { shape = 3, ease = function(x) return customshape.segEase(3, x, 0) end },   -- fast start (ease-out)
  { shape = 4, ease = function(x) return customshape.segEase(4, x, 0) end },   -- fast end  (ease-in)
}

local function withShape(p, shape, tension)
  return { time = p.time, value = p.value, shape = shape, tension = tension or 0, sel = p.sel }
end

-- Max vertical error (and where it peaks) of REAPER's shape-5 bezier with tension T over the chord's
-- interior points. value(x) = p0.value + dv * bezierFrac(x, T) — exactly what REAPER will render.
local function maxBezErr(points, i, j, p0, dt, dv, T)
  local maxErr, maxK = 0, i + 1
  for k = i + 1, j - 1 do
    local pk = points[k]
    local x = (dt == 0) and 0 or (pk.time - p0.time) / dt
    local e = abs(pk.value - (p0.value + dv * customshape.bezierFrac(x, T)))
    if e > maxErr then maxErr, maxK = e, k end
  end
  return maxErr, maxK
end

-- Best bezier tension for the chord, by a coarse-to-fine 1-D scan over T in [-1,1] (the error surface
-- isn't guaranteed unimodal, so scan rather than ternary-search). Returns tension, its max error, and
-- the peak index. Only worth calling as a "rescue" when the fixed shapes don't fit.
local function fitBezier(points, i, j, p0, dt, dv)
  local bestT, bestErr, bestK = 0, nil, i + 1
  for n = 0, 20 do                                   -- coarse: T = -1 .. 1 step 0.1
    local T = -1 + n * 0.1
    local e, k = maxBezErr(points, i, j, p0, dt, dv, T)
    if not bestErr or e < bestErr then bestErr, bestT, bestK = e, T, k end
  end
  local c = bestT
  for n = -9, 9 do                                   -- fine: +/-0.09 around the coarse best, step 0.01
    local T = c + n * 0.01
    if T >= -1 and T <= 1 and n ~= 0 then
      local e, k = maxBezErr(points, i, j, p0, dt, dv, T)
      if e < bestErr then bestErr, bestT, bestK = e, T, k end
    end
  end
  return bestT, bestErr, bestK
end

-- Best-fitting candidate for the chord points[i]..points[j]: the shape with the smallest MAX vertical
-- error over the interior points, plus that error and the interior index where it peaks (split point).
-- If NO fixed shape (linear/sine eases) fits within eps, try a fitted bezier as a rescue: when it fits,
-- the whole stretch stays 2 points (shape 5 + tension) instead of splitting. Fixed shapes always win
-- when they fit, so existing output is unchanged except where bezier now captures a would-be split.
local function fitOne(points, i, j, eps)
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
    if not best or maxErr < best.err then best = { shape = cand.shape, err = maxErr, splitIdx = maxK, tension = 0 } end
  end
  if best.err > eps and dv ~= 0 and dt ~= 0 then     -- rescue: only when no fixed shape fits a non-flat,
    local bt, be, bk = fitBezier(points, i, j, p0, dt, dv)   -- non-vertical stretch (dt==0 -> every x=0,
    if be and be <= eps then best = { shape = 5, err = be, splitIdx = bk, tension = bt } end   -- futile)
  end
  return best
end

-- Kept points for the half-open range [i, j) (i included, j NOT — the caller appends the final point).
-- Accept the whole stretch as one curved segment if a candidate fits within eps, else split at the
-- worst point and recurse.
local function fitRange(points, i, j, eps, linearShape)
  if j <= i + 1 then return { withShape(points[i], linearShape) } end   -- adjacent: straight chord
  local best = fitOne(points, i, j, eps)
  if best.err <= eps then
    local s = (best.shape == 1) and linearShape or best.shape
    return { withShape(points[i], s, best.tension) }
  end
  local out = fitRange(points, i, best.splitIdx, eps, linearShape)
  for _, p in ipairs(fitRange(points, best.splitIdx, j, eps, linearShape)) do out[#out + 1] = p end
  return out
end

-- Curve-aware thinning. `amount`/`valueRange` mirror M.thin (eps = amount * value-range). opts:
--   { envConvention = bool }  -- emit linear as 0 (envelope/AI) instead of 1 (CC). Curves 2-5 are
--                                identical across conventions. Returns kept point COPIES with .shape
--                                (target convention) and .tension (nonzero only for rescued shape-5
--                                bezier segments; 0 for all others).
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
