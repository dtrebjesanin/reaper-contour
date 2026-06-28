-- core/genpreset.lua — Generate-panel preset store + ExtState-safe serialization. PURE (no REAPER).
-- A preset captures the documented Generate controls (shape + rate + level + every modulator) as a flat
-- key->number map, PLUS an optional opaque `points` string (the embedded custom drawing, so a preset on
-- the Custom shape is self-contained). A preset: { name, params = { key=number }, points = <string?> };
-- a store: array of presets. Single-line serialization (ExtState persist=true breaks on newlines):
--   store  = preset ("|" preset)*
--   preset = escName "~" ( key "=" num (";" key "=" num)* ) "~" escPoints
-- Names/keys/points percent-escape the delimiters (| ~ ; = %); numbers via %.6g. The `points` string is
-- OPAQUE here (the caller encodes/decodes it via customshape) so genpreset stays decoupled. The CALLER
-- owns which keys to capture/apply (the panel's DEFAULTS).
local M = {}

local ESC = { ["%"] = "%25", ["|"] = "%7C", ["~"] = "%7E", [";"] = "%3B", ["="] = "%3D" }
local function esc(s) return (tostring(s):gsub("[%%|~;=]", ESC)) end
local function unesc(s) return (tostring(s):gsub("%%(%x%x)", function(h) return string.char(tonumber(h, 16)) end)) end
local function num(v) return string.format("%.6g", tonumber(v) or 0) end

function M.encode(store)
  local out = {}
  for _, pr in ipairs(store or {}) do
    local keys = {}
    for k in pairs(pr.params or {}) do keys[#keys + 1] = k end
    table.sort(keys)                                   -- stable, deterministic order
    local kv = {}
    for _, k in ipairs(keys) do kv[#kv + 1] = esc(k) .. "=" .. num(pr.params[k]) end
    out[#out + 1] = esc(pr.name or "") .. "~" .. table.concat(kv, ";") .. "~" .. esc(pr.points or "")
  end
  return table.concat(out, "|")
end

function M.decode(str)
  local store = {}
  if not str or str == "" then return store end
  for chunk in (str .. "|"):gmatch("(.-)|") do
    if chunk:find("~", 1, true) then
      local parts = {}                                 -- up to 3 ~-sections: name, params, points
      for seg in (chunk .. "~"):gmatch("(.-)~") do parts[#parts + 1] = seg end
      local params = {}
      for kv in ((parts[2] or "") .. ";"):gmatch("(.-);") do
        if kv ~= "" then
          local k, v = kv:match("^([^=]*)=([^=]*)$")
          if k and tonumber(v) then params[unesc(k)] = tonumber(v) end
        end
      end
      local preset = { name = unesc(parts[1] or ""), params = params }
      if parts[3] and parts[3] ~= "" then preset.points = unesc(parts[3]) end
      store[#store + 1] = preset
    end
  end
  return store
end

return M
