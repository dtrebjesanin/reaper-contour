-- core/genpreset.lua — Generate-panel preset store + ExtState-safe serialization. PURE (no REAPER).
-- A preset captures the documented Generate controls (shape + rate + level + every modulator) as a flat
-- key->number map. A preset: { name = <string>, params = { <key> = <number>, ... } }; a store: array of
-- presets. Single-line serialization (ExtState persist=true breaks on newlines):
--   store  = preset ("|" preset)*
--   preset = escName "~" ( key "=" num (";" key "=" num)* )
-- Names/keys percent-escape the delimiters (| ~ ; = %); numbers via %.6g. Keys are plain identifiers
-- but are escaped anyway for safety. The CALLER owns which keys to capture/apply (the panel's DEFAULTS).
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
    out[#out + 1] = esc(pr.name or "") .. "~" .. table.concat(kv, ";")
  end
  return table.concat(out, "|")
end

function M.decode(str)
  local store = {}
  if not str or str == "" then return store end
  for chunk in (str .. "|"):gmatch("(.-)|") do
    local namePart, kvPart = chunk:match("^(.-)~(.*)$")
    if namePart then
      local params = {}
      for kv in ((kvPart or "") .. ";"):gmatch("(.-);") do
        if kv ~= "" then
          local k, v = kv:match("^([^=]*)=([^=]*)$")
          if k and tonumber(v) then params[unesc(k)] = tonumber(v) end
        end
      end
      store[#store + 1] = { name = unesc(namePart), params = params }
    end
  end
  return store
end

return M
