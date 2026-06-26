-- core/arrangecoords.lua — PURE linear maps between project time / envelope value and screen pixels.
-- Zero reaper.*. The overlay fetches the inputs (view time range + pixel extents, lane Y rect + value
-- range) from REAPER and feeds them here. Values are in the envelope's raw STORAGE domain (which the
-- lane draws linearly), so no scaling conversion is needed here.
local M = {}

function M.timeToX(t, t0, t1, x0, x1)
  if t1 == t0 then return x0 end
  return x0 + (t - t0) * (x1 - x0) / (t1 - t0)
end

function M.xToTime(x, t0, t1, x0, x1)
  if x1 == x0 then return t0 end
  return t0 + (x - x0) * (t1 - t0) / (x1 - x0)
end

-- Screen Y grows downward; yTop is the lane's top pixel (smaller), yBot the bottom (larger). Higher
-- value maps nearer yTop.
function M.valueToY(v, vlo, vhi, yTop, yBot)
  if vhi == vlo then return yBot end
  return yBot - (v - vlo) * (yBot - yTop) / (vhi - vlo)
end

function M.yToValue(y, vlo, vhi, yTop, yBot)
  if yBot == yTop then return vlo end
  return vlo + (yBot - y) * (vhi - vlo) / (yBot - yTop)
end

return M
