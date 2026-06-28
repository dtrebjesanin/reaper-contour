-- core/num.lua — pure numeric helpers. No Reaper, no I/O.
local M = {}
local floor = math.floor

--- Clamp v to [lo, hi].
function M.clamp(v, lo, hi)
  if v < lo then return lo elseif v > hi then return hi else return v end
end

--- Clamp v to [0, 1].
function M.clamp01(v)
  if v < 0 then return 0 elseif v > 1 then return 1 else return v end
end

--- Linear interpolation between a and b at t (unclamped).
function M.lerp(a, b, t) return a + (b - a) * t end

--- Fractional part: x - floor(x). Always in [0, 1).
function M.frac(x) return x - floor(x) end

return M
