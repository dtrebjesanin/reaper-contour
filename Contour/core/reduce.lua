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

return M
