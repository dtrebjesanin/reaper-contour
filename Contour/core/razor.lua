-- core/razor.lua — pure razor-area logic: parse REAPER's P_RAZOREDITS strings, merge/clamp spans,
-- snapshot a project's razor state, diff two snapshots, and debounce ("settle") a changing state.
-- No Reaper, no I/O: core/context.lua reads REAPER and feeds the raw strings in here.
--
-- A REAPER razor string is a flat list of triples:  start end "guid"
--   guid == ""        -> the track's media-item lane
--   guid == "{...}"   -> that envelope's lane
-- Spans are plain arrays {t0, t1} (index 1 and 2). Parsed triples carry named fields {t0, t1, guid}.
-- GUID keys are stored WITHOUT the surrounding quotes, e.g. "{A}", everywhere (snapshot.env, order,
-- changedLanes, envSpans), and UPPER-CASE.
local M = {}

local EPS_SPAN = 1e-9    -- spans shorter than this are empty; spans closer than this are touching
local EPS_DIFF = 1e-6    -- two span ends within this are "the same" when diffing snapshots
local EPS_TIME = 1e-9    -- float slack when comparing elapsed time against settleSec

-- Finite number or nil. tonumber() already rejects "nan"/"inf" text, but "1e999" parses to inf.
local function num(s)
  local v = tonumber(s)
  if v == nil or v ~= v or v == math.huge or v == -math.huge then return nil end
  return v
end

local function copySpans(spans)
  local out = {}
  for i = 1, #spans do out[i] = { spans[i][1], spans[i][2] } end
  return out
end

--- Parse a P_RAZOREDITS string into { {t0=, t1=, guid=}, ... }. guid is "" for the item lane.
--- Accepts quoted ("{A}", "") and unquoted ({A}) GUIDs, upper-cased so they match however REAPER
--- spells a GUID (context.lua upper-cases the envelope side the same way). Skips triples whose times do
--- not parse or that are zero-length (t1 - t0 <= 1e-9); an incomplete trailing triple is ignored.
function M.parse(s)
  local out = {}
  if type(s) ~= "string" or s == "" then return out end
  local toks = {}
  for tok in s:gmatch("%S+") do toks[#toks + 1] = tok end
  for i = 1, #toks - 2, 3 do
    local t0, t1 = num(toks[i]), num(toks[i + 1])
    if t0 and t1 and t1 - t0 > EPS_SPAN then
      out[#out + 1] = { t0 = t0, t1 = t1, guid = (toks[i + 2]:gsub('"', "")):upper() }
    end
  end
  return out
end

--- Sort by t0 and merge spans that overlap or touch (gap <= 1e-9). Returns new tables.
function M.mergeSpans(spans)
  local sorted = copySpans(spans)
  table.sort(sorted, function(a, b)
    if a[1] ~= b[1] then return a[1] < b[1] end
    return a[2] < b[2]
  end)
  local out = {}
  for i = 1, #sorted do
    local sp, last = sorted[i], out[#out]
    if last and sp[1] <= last[2] + EPS_SPAN then
      if sp[2] > last[2] then last[2] = sp[2] end
    else
      out[#out + 1] = sp
    end
  end
  return out
end

--- Keep only the part of each span inside [a, b]. Spans left with no length are dropped.
function M.clamp(spans, a, b)
  local out = {}
  for i = 1, #spans do
    local t0 = spans[i][1] > a and spans[i][1] or a
    local t1 = spans[i][2] < b and spans[i][2] or b
    if t1 - t0 > EPS_SPAN then out[#out + 1] = { t0, t1 } end
  end
  return out
end

--- Build a snapshot from { {track=any, raw=string|nil}, ... }.
--- Snap = { env = { [guid] = { track=, spans= } }, item = { [track] = spans }, order = { guid, ... } }
--- Spans are merged. order lists envelope GUIDs by first appearance, tracks in the given order.
--- If the same GUID shows up on two tracks (should not happen) the first track keeps it.
function M.snapshot(tracks)
  local snap = { env = {}, item = {}, order = {} }
  for _, t in ipairs(tracks or {}) do
    for _, r in ipairs(M.parse(t.raw)) do
      if r.guid == "" then
        if t.track ~= nil then
          local list = snap.item[t.track]
          if not list then list = {}; snap.item[t.track] = list end
          list[#list + 1] = { r.t0, r.t1 }
        end
      else
        local lane = snap.env[r.guid]
        if not lane then
          lane = { track = t.track, spans = {} }
          snap.env[r.guid] = lane
          snap.order[#snap.order + 1] = r.guid
        end
        lane.spans[#lane.spans + 1] = { r.t0, r.t1 }
      end
    end
  end
  for _, lane in pairs(snap.env) do lane.spans = M.mergeSpans(lane.spans) end
  for track, list in pairs(snap.item) do snap.item[track] = M.mergeSpans(list) end
  return snap
end

--- Merged spans of an envelope lane, or {} when there are none.
function M.envSpans(snap, guid)
  local lane = snap and snap.env and snap.env[guid]
  return lane and lane.spans or {}
end

--- Merged spans of a track's item lane, or {} when there are none.
function M.itemSpans(snap, track)
  return snap and snap.item and track ~= nil and snap.item[track] or {}
end

local function spansSig(spans)
  local parts = {}
  for i = 1, #spans do parts[i] = string.format("%.17g,%.17g", spans[i][1], spans[i][2]) end
  return table.concat(parts, ";")
end

--- A string that is equal for equal snapshots and differs for any span change, added or removed
--- lane. Envelope lanes go in snap.order; item lanes are sorted by tostring(track) so the result
--- does not depend on table iteration order.
function M.sigOf(snap)
  local parts = {}
  for _, guid in ipairs(snap.order or {}) do
    parts[#parts + 1] = "E" .. guid .. "=" .. spansSig(M.envSpans(snap, guid))
  end
  local keys = {}
  for track in pairs(snap.item or {}) do keys[#keys + 1] = track end
  table.sort(keys, function(a, b)
    local sa, sb = tostring(a), tostring(b)
    if sa ~= sb then return sa < sb end
    return type(a) < type(b)
  end)
  for _, track in ipairs(keys) do
    parts[#parts + 1] = "I" .. tostring(track) .. "=" .. spansSig(snap.item[track])
  end
  return table.concat(parts, "\n")
end

local function hasSpan(spans, sp)
  for i = 1, #spans do
    if math.abs(spans[i][1] - sp[1]) <= EPS_DIFF and math.abs(spans[i][2] - sp[2]) <= EPS_DIFF then
      return true
    end
  end
  return false
end

--- Envelope lanes of `cur` that have at least one span not present in `prev` (both ends within
--- 1e-6). A lane whose spans only shrank away or disappeared is not reported. prev == nil means
--- everything is new. Result follows cur.order.
function M.changedLanes(prev, cur)
  local out = {}
  for _, guid in ipairs(cur.order) do
    local old = prev and M.envSpans(prev, guid) or {}
    local changed = false
    for _, sp in ipairs(M.envSpans(cur, guid)) do
      if not hasSpan(old, sp) then changed = true; break end
    end
    if changed then out[#out + 1] = guid end
  end
  return out
end

--- The envelope lanes one drag touched, as a list of GUIDs in cur.order: the changed lanes plus every
--- other envelope lane of `cur` that has one of their NEW spans too (both ends within 1e-6). A drag over
--- several lanes gives them all the same span, but changedLanes only reports the ones whose spans differ
--- from `prev`: when one of the lanes already had that span, only the other shows as changed. A caller
--- that switches lanes must act only when this list has exactly one member. Item lanes do not count.
function M.dragLanes(prev, cur)
  local inSet = {}
  for _, guid in ipairs(M.changedLanes(prev, cur)) do
    inSet[guid] = true
    local old = prev and M.envSpans(prev, guid) or {}
    for _, sp in ipairs(M.envSpans(cur, guid)) do
      if not hasSpan(old, sp) then
        for _, other in ipairs(cur.order) do
          if other ~= guid and hasSpan(M.envSpans(cur, other), sp) then inSet[other] = true end
        end
      end
    end
  end
  local out = {}
  for _, guid in ipairs(cur.order) do
    if inSet[guid] then out[#out + 1] = guid end
  end
  return out
end

-- ── settler ──────────────────────────────────────────────────────────────────

local Settler = {}
Settler.__index = Settler

--- A debouncer for a changing signature. feed() returns true exactly once per new state: when the
--- signature differs from the last settled one, has stayed equal for >= settleSec, and the mouse
--- is up. The very first feed only sets the baseline.
function M.newSettler(settleSec)
  return setmetatable({ settleSec = settleSec, started = false }, Settler)
end

function Settler:feed(sig, now, mouseDown)
  if not self.started then
    self.started = true
    self.settled = sig
    self.pending = sig
    self.since = now
    return false
  end
  if sig ~= self.pending then
    self.pending = sig
    self.since = now
  end
  if self.pending == self.settled then return false end
  if mouseDown then return false end
  if now - self.since >= self.settleSec - EPS_TIME then
    self.settled = self.pending
    return true
  end
  return false
end

return M
