-- core/customshape.lua — custom-shape preset data model + ExtState-safe serialization. PURE (no REAPER).
-- A point: { x in [0,1], y in [-1,1], shape (0..5 CC int), tension in [-1,1] }. A preset: { name, points }.
-- A store: array of presets. Serialization is SINGLE-LINE (ExtState persist=true breaks on newlines):
--   store   = preset ("|" preset)*
--   preset  = escName "~" point (";" point)*
--   point   = x "," y "," shape "," tension     (numbers via %.6g)
-- Names percent-escape the 5 delimiters so any name survives.
local M = {}
local floor = math.floor
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

local ESC = { ["%"] = "%25", ["|"] = "%7C", ["~"] = "%7E", [";"] = "%3B", [","] = "%2C" }
local function esc(s) return (tostring(s):gsub("[%%|~;,]", ESC)) end
local function unesc(s) return (tostring(s):gsub("%%(%x%x)", function(h) return string.char(tonumber(h, 16)) end)) end
local function num(v) return string.format("%.6g", tonumber(v) or 0) end

function M.encode(store)
  local presets = {}
  for _, pr in ipairs(store or {}) do
    local pts = {}
    for _, p in ipairs(pr.points or {}) do
      pts[#pts + 1] = table.concat({ num(p.x), num(p.y), num(p.shape or 1), num(p.tension or 0) }, ",")
    end
    presets[#presets + 1] = esc(pr.name or "") .. "~" .. table.concat(pts, ";")
  end
  return table.concat(presets, "|")
end

function M.decode(str)
  local store = {}
  if not str or str == "" then return store end
  for chunk in (str .. "|"):gmatch("(.-)|") do
    local namePart, ptsPart = chunk:match("^(.-)~(.*)$")
    if namePart then
      local pts = {}
      for ptStr in (ptsPart .. ";"):gmatch("(.-);") do
        if ptStr ~= "" then
          local x, y, sh, ten = ptStr:match("^([^,]*),([^,]*),([^,]*),([^,]*)$")
          if x then pts[#pts + 1] = { x = tonumber(x) or 0, y = tonumber(y) or 0,
            shape = tonumber(sh) or 1, tension = tonumber(ten) or 0 } end
        end
      end
      if #pts >= 1 then store[#store + 1] = { name = unesc(namePart), points = pts } end
    end
  end
  return store
end

return M
