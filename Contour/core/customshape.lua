-- core/customshape.lua — custom-shape preset data model + ExtState-safe serialization. PURE (no REAPER).
-- A point: { x in [0,1], y in [-1,1], shape (0..5 CC int), tension in [-1,1] }. A preset: { name, points }.
-- A store: array of presets. Serialization is SINGLE-LINE (ExtState persist=true breaks on newlines):
--   store   = preset ("|" preset)*
--   preset  = escName "~" point (";" point)*
--   point   = x "," y "," shape "," tension     (numbers via %.6g)
-- Names percent-escape the 5 delimiters so any name survives.
local M = {}
local floor, cos, sin, pi = math.floor, math.cos, math.sin, math.pi
local function clampn(v, lo, hi) v = tonumber(v) or 0; if v < lo then return lo elseif v > hi then return hi end return v end

function M.defaultPreset()
  return { name = "Triangle", points = {
    { x = 0, y = -1, shape = 1, tension = 0 },
    { x = 0.5, y = 1, shape = 1, tension = 0 },
    { x = 1, y = -1, shape = 1, tension = 0 },
  } }
end

-- Sort by x, clamp fields, pin first x=0 / last x=1.
function M.clampPoints(points)
  local out = {}
  for _, p in ipairs(points or {}) do
    out[#out + 1] = { x = clampn(p.x, 0, 1), y = clampn(p.y, -1, 1),
      shape = clampn(floor((tonumber(p.shape) or 1) + 0.5), 0, 5), tension = clampn(p.tension, -1, 1) }
  end
  table.sort(out, function(a, b) return a.x < b.x end)
  if #out > 0 then out[1].x = 0; out[#out].x = 1 end
  return out
end

-- REAPER's shape-5 "bezier" curve, reproduced EXACTLY from schwa's (Cockos dev) tension->control-point
-- model (forum.cockos.com/showthread.php?t=177451): normalized endpoints P0=(0,1) P3=(1,-1); the two
-- interior control points are a piecewise-linear function of tension T in [-1,1], anchored at
--   T=-1 -> (0,-1)(0,-1);  T=0 -> (0.25,0.5)(0.75,-0.5);  T=+1 -> (1,1)(1,1).
-- It is PARAMETRIC (control-point x is non-uniform), so the value at horizontal fraction t is found by
-- solving X(u)=t then taking Y(u). Returns the value FRACTION in [0,1] (0 = segment start value, 1 =
-- end value). This makes the draw pad's preview match REAPER's rendered envelope/CC bezier.
local function bezCP(T)
  if T < -1 then T = -1 elseif T > 1 then T = 1 end
  if T <= 0 then
    local f = T + 1                                        -- blend tension -1 -> 0
    return 0.25 * f, -1 + 1.5 * f, 0.75 * f, -1 + 0.5 * f
  end
  local f = T                                              -- blend tension 0 -> +1
  return 0.25 + 0.75 * f, 0.5 + 0.5 * f, 0.75 + 0.25 * f, -0.5 + 1.5 * f
end
local function cubic(c0, c1, c2, c3, u)                    -- 1-D cubic Bernstein
  local m = 1 - u
  return m * m * m * c0 + 3 * m * m * u * c1 + 3 * m * u * u * c2 + u * u * u * c3
end
function M.bezierFrac(t, tension)
  if t <= 0 then return 0 elseif t >= 1 then return 1 end
  local p1x, p1y, p2x, p2y = bezCP(tension or 0)
  local lo, hi = 0.0, 1.0                                  -- solve X(u)=t (X is monotonic in u)
  for _ = 1, 20 do
    local mid = (lo + hi) * 0.5
    if cubic(0, p1x, p2x, 1, mid) < t then lo = mid else hi = mid end
  end
  local u = (lo + hi) * 0.5
  return (1 - cubic(1, p1y, p2y, -1, u)) * 0.5            -- normalized y [+1..-1] -> fraction [0..1]
end

-- Parametric point on the same bezier at curve parameter u in [0,1]: returns (xFrac, yFrac), both in
-- [0,1]. Stepping u (rather than x) tessellates densely where the curve bends, so the near-vertical
-- extremes draw smoothly instead of faceting. This is how REAPER itself draws the curve.
function M.bezierXY(u, tension)
  local p1x, p1y, p2x, p2y = bezCP(tension or 0)
  return cubic(0, p1x, p2x, 1, u), (1 - cubic(1, p1y, p2y, -1, u)) * 0.5
end

-- Value FRACTION for a single segment: shape 5 -> bezierFrac; 2/3/4 -> sine eases; 0 -> step hold; else linear.
-- t is the intra-segment fraction in [0,1]; tension is used only by shape 5.
function M.segEase(shape, t, tension)
  if shape == 5 then return M.bezierFrac(t, tension)
  elseif shape == 2 then return (1 - cos(pi * t)) / 2
  elseif shape == 3 then return sin(pi * t / 2)
  elseif shape == 4 then return 1 - cos(pi * t / 2)
  elseif shape == 0 then return 0
  else return t end
end

-- Value of the custom one-cycle curve at intra-cycle position t in [0,1) (wraps). Evaluates the
-- piecewise CC eases (bezier via bezierFrac; sine eases 2/3/4; step 0; linear). Lets the generic
-- sampler quantize / smooth / swing a custom shape just like the built-in shapes (Phase 2).
function M.valueAt(points, t)
  local n = points and #points or 0
  if n == 0 then return 0 end
  if n == 1 then return points[1].y end
  t = t - floor(t)
  for i = 1, n - 1 do
    local a, b = points[i], points[i + 1]
    if t < b.x - 1e-12 or i == n - 1 then            -- half-open: at a breakpoint, use the next segment
      local w = b.x - a.x
      local tt = (w > 1e-12) and (t - a.x) / w or 0
      if tt < 0 then tt = 0 elseif tt > 1 then tt = 1 end
      return a.y + (b.y - a.y) * M.segEase(a.shape or 1, tt, a.tension or 0)
    end
  end
  return points[n].y
end

local ESC = { ["%"] = "%25", ["|"] = "%7C", ["~"] = "%7E", [";"] = "%3B", [","] = "%2C" }
local function esc(s) return (tostring(s):gsub("[%%|~;,]", ESC)) end
local function unesc(s) return (tostring(s):gsub("%%(%x%x)", function(h) return string.char(tonumber(h, 16)) end)) end
local function num(v) return string.format("%.6g", tonumber(v) or 0) end

-- Serialize a single point list to the ";"-separated "x,y,shape,tension" form (no name). Reused by
-- M.encode and by genpreset (to embed a custom drawing inside a Generate preset).
function M.encodePoints(points)
  local pts = {}
  for _, p in ipairs(points or {}) do
    pts[#pts + 1] = table.concat({ num(p.x), num(p.y), num(p.shape or 1), num(p.tension or 0) }, ",")
  end
  return table.concat(pts, ";")
end

function M.decodePoints(str)
  local pts = {}
  for ptStr in ((str or "") .. ";"):gmatch("(.-);") do
    if ptStr ~= "" then
      local x, y, sh, ten = ptStr:match("^([^,]*),([^,]*),([^,]*),([^,]*)$")
      if x then pts[#pts + 1] = { x = tonumber(x) or 0, y = tonumber(y) or 0,
        shape = tonumber(sh) or 1, tension = tonumber(ten) or 0 } end
    end
  end
  return pts
end

function M.encode(store)
  local presets = {}
  for _, pr in ipairs(store or {}) do
    presets[#presets + 1] = esc(pr.name or "") .. "~" .. M.encodePoints(pr.points)
  end
  return table.concat(presets, "|")
end

function M.decode(str)
  local store = {}
  if not str or str == "" then return store end
  for chunk in (str .. "|"):gmatch("(.-)|") do
    local namePart, ptsPart = chunk:match("^(.-)~(.*)$")
    if namePart then
      local pts = M.decodePoints(ptsPart)
      if #pts >= 1 then store[#store + 1] = { name = unesc(namePart), points = pts } end
    end
  end
  return store
end

return M
