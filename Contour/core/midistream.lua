-- core/midistream.lua — PURE MIDI all-events stream codec. Zero reaper.*, no I/O.
--
-- Mirrors REAPER's MIDI_GetAllEvts / MIDI_SetAllEvts binary buffer format so the
-- live-write path can do a single atomic SetAllEvts per frame instead of per-event
-- Insert/Delete + Sort.
--
-- Buffer layout, little-endian, no padding (verified format):
--   per event = int32 delta-ticks  +  uint8 flags  +  uint32 msglen  +  msg[msglen]
--   string.pack/unpack format string: "<i4Bs4"
--     '<'  little-endian
--     'i4' signed 32-bit delta (offset from previous event's PPQ)
--     'B'  flags byte
--     's4' 4-byte-LE-length-prefixed raw bytes (msglen + msg, atomic)
--
-- flags byte: bit0 (0x01) selected, bit1 (0x02) muted, high nibble (bits4-7) = CC shape
--   for CC/pitchwheel/chan-pressure/program events:
--     0x00 square/step, 0x10 linear, 0x20 slow start/end, 0x30 fast start,
--     0x40 fast end, 0x50 bezier
--
-- The buffer ALWAYS ends with a mandatory end-of-take All-Notes-Off sentinel event
-- (msg = 0xB0 0x7B 0x00). It must be preserved verbatim; we capture it as raw bytes
-- and re-append it unchanged.

local M = {}

local spack, sunpack = string.pack, string.unpack
local FMT = "<i4Bs4"

-- CC shape integer (0..5) -> flags high-nibble bits.
local CCSHAPE_BITS = { [0] = 0x00, [1] = 0x10, [2] = 0x20, [3] = 0x30, [4] = 0x40, [5] = 0x50 }

-- flags low bits we preserve on generated CCs (none by default: not selected/muted).
local function flagsForCCShape(ccShape)
  local bits = CCSHAPE_BITS[ccShape] or 0x00
  return bits  -- low nibble 0
end

-- decode(blob) -> { events = { {ppq=<abs>, flags=<int>, msg=<bytestring>} ... }, eot = <rawbytes> }
-- Converts delta offsets to absolute PPQ. The trailing end-of-take sentinel is NOT
-- included in events; it is captured verbatim in `.eot` so encode() can re-append it.
function M.decode(blob)
  blob = blob or ""
  local events = {}
  local pos = 1
  local running = 0
  local n = #blob
  -- Loop bound n-12 leaves the 12-byte end-of-take sentinel for `eot`.
  -- (Any event is >= 9 bytes; the sentinel All-Notes-Off is exactly 12 bytes.)
  while pos <= n - 12 do
    local offset, flags, msg, nextpos = sunpack(FMT, blob, pos)
    running = running + offset
    events[#events + 1] = { ppq = running, flags = flags, msg = msg }
    pos = nextpos
  end
  local eot = (pos <= n) and blob:sub(pos) or ""
  return { events = events, eot = eot }
end

-- Stable sort by ppq (preserves relative order of equal-ppq events: e.g. a CCBZ meta
-- event keeps following the CC it modifies; chord notes keep their order).
local function stableSortByPpq(events)
  local n = #events
  local idx = {}
  for i = 1, n do idx[i] = i end
  table.sort(idx, function(a, b)
    local ea, eb = events[a], events[b]
    if ea.ppq ~= eb.ppq then return ea.ppq < eb.ppq end
    return a < b  -- stable tiebreak on original index
  end)
  local out = {}
  for i = 1, n do out[i] = events[idx[i]] end
  return out
end

-- encode(eventsTable) -> blob
-- Accepts the table returned by decode (with .events and .eot) OR a plain array of
-- {ppq, flags, msg} events. Recomputes deltas, sorts by ppq (stable), and re-appends
-- the preserved end-of-take sentinel verbatim. If no eot was supplied, a standard
-- All-Notes-Off sentinel is synthesized with a correct delta.
function M.encode(eventsTable)
  eventsTable = eventsTable or {}
  local events = eventsTable.events or eventsTable
  local eot = eventsTable.eot  -- may be nil/"" when encoding a plain array

  local sorted = stableSortByPpq(events)

  local out = {}
  local last = 0
  for i = 1, #sorted do
    local ev = sorted[i]
    -- PPQ (ticks) must be an integer; generated CCs come from MIDI_GetPPQPosFromProjTime
    -- (a float), so floor defensively before packing the int32 delta.
    local ppq = math.floor(ev.ppq + 0.5)
    out[#out + 1] = spack(FMT, ppq - last, ev.flags, ev.msg)
    last = ppq
  end

  if eot and #eot > 0 then
    -- Re-append the original sentinel verbatim. Its stored offset was relative to the
    -- last real event in the ORIGINAL buffer; REAPER's sentinel uses an offset that
    -- rewinds/positions independent of our edits, so verbatim preservation is the
    -- documented safe idiom.
    out[#out + 1] = eot
  else
    -- Synthesize a standard end-of-take All-Notes-Off at delta 0 from the last event.
    out[#out + 1] = spack(FMT, 0, 0x00, "\176\123\000")  -- 0xB0 0x7B 0x00
  end

  return table.concat(out)
end

-- isCCOnLaneChan(msg, chan, lane) -> bool
-- True iff msg is a Control Change on the given channel (0-15) carrying the given
-- controller/lane number. CC status byte = 0xB0 | chan; msg[2] = controller number.
local function isCCOnLaneChan(msg, chan, lane)
  if #msg < 2 then return false end
  local status = msg:byte(1)
  if (status & 0xF0) ~= 0xB0 then return false end
  if (status & 0x0F) ~= (chan & 0x0F) then return false end
  return msg:byte(2) == lane
end

-- isCCBZ(msg) -> bool : REAPER bezier meta event (always follows its CC).
local function isCCBZ(msg)
  return #msg >= 6 and msg:byte(1) == 0xFF and msg:sub(2, 6) == "CCBZ "
end

-- replaceCCInRange(events, chan, lane, ppq0, ppq1, newCCs) -> events
--   Removes ONLY CC events of chan+lane whose ppq is within [ppq0, ppq1] (inclusive),
--   plus any CCBZ bezier meta event immediately following such a removed CC. Keeps every
--   other event (notes, other-lane CC, other-channel CC, sysex, CCBZ of kept CCs, the end
--   marker carried separately). Inserts newCCs (encoded as CC messages with the requested
--   CC shape in the flags nibble). Result is a NEW decoded-style table {events=, eot=}
--   when given one, or a plain array when given a plain array — sorted by ppq.
--
--   newCCs = { { ppq=<abs>, value=<0..127 int>, shape=<ccShape int 0..5> } ... }
function M.replaceCCInRange(events, chan, lane, ppq0, ppq1, newCCs)
  local srcList = events.events or events
  local eot = events.eot
  newCCs = newCCs or {}

  if ppq1 < ppq0 then ppq0, ppq1 = ppq1, ppq0 end

  local kept = {}
  local i = 1
  local nsrc = #srcList
  while i <= nsrc do
    local ev = srcList[i]
    local drop = false
    if ev.ppq >= ppq0 and ev.ppq <= ppq1 and isCCOnLaneChan(ev.msg, chan, lane) then
      drop = true
      -- Also drop a CCBZ bezier meta event that immediately follows this CC (REAPER
      -- stores the bezier tension as the very next event AT THE SAME PPQ). Require
      -- nxt.ppq == ev.ppq so an unrelated CCBZ at a different PPQ is never dropped.
      local nxt = srcList[i + 1]
      if nxt and nxt.ppq == ev.ppq and isCCBZ(nxt.msg) then
        i = i + 1  -- skip the meta too
      end
    end
    if not drop then kept[#kept + 1] = ev end
    i = i + 1
  end

  -- Insert generated CCs.
  for _, cc in ipairs(newCCs) do
    local value = cc.value or 0
    if value < 0 then value = 0 elseif value > 127 then value = 127 end
    value = value // 1  -- integer
    local status = 0xB0 | (chan & 0x0F)
    local msg = string.char(status, lane & 0x7F, value & 0x7F)
    kept[#kept + 1] = { ppq = math.floor((cc.ppq or 0) + 0.5),
                        flags = flagsForCCShape(cc.shape or 0) | (cc.sel and 0x01 or 0), msg = msg }
  end

  local sorted = stableSortByPpq(kept)

  if events.events then
    return { events = sorted, eot = eot }
  end
  return sorted
end

-- ===========================================================================
-- LIVE FAST PATH (perf): the per-frame replaceCCInRange + encode re-FILTERS and re-SORTS the
-- WHOLE take (all notes included) every frame — O(n log n) Lua work that scales with take size
-- and causes fps dips on dense takes during a live drag. But during a gesture the only thing that
-- changes is our lane's CC inside [ppq0,ppq1]; every other event is immutable. So split ONCE at
-- gesture start (splitForRange) and per frame only MERGE the few new CCs into the pre-sorted kept
-- list (encodeMerged) — no per-frame filter scan, no per-frame n-log-n closure sort.

-- splitForRange(events, chan, lane, ppq0, ppq1) -> { kept = <sorted events NOT on chan+lane in
-- [ppq0,ppq1]>, eot }. Mirrors replaceCCInRange's drop logic (incl. dropping a CCBZ that
-- immediately follows a removed CC). Call ONCE at gesture start; reuse `kept` every frame.
function M.splitForRange(events, chan, lane, ppq0, ppq1)
  local srcList = events.events or events
  local eot = events.eot
  if ppq1 < ppq0 then ppq0, ppq1 = ppq1, ppq0 end
  local kept = {}
  local i, nsrc = 1, #srcList
  while i <= nsrc do
    local ev = srcList[i]
    local drop = false
    if ev.ppq >= ppq0 and ev.ppq <= ppq1 and isCCOnLaneChan(ev.msg, chan, lane) then
      drop = true
      local nxt = srcList[i + 1]
      if nxt and nxt.ppq == ev.ppq and isCCBZ(nxt.msg) then i = i + 1 end
    end
    if not drop then kept[#kept + 1] = ev end
    i = i + 1
  end
  return { kept = stableSortByPpq(kept), eot = eot }   -- sorted ONCE here, not per frame
end

-- encodeMerged(kept, chan, lane, newCCs, eot) -> blob. `kept` is the pre-sorted immutable list
-- from splitForRange. Builds CC events from newCCs (same value-clamp + msg + shape nibble as
-- replaceCCInRange), sorts ONLY the small newCCs list, then two-pointer MERGES into kept (kept
-- first at equal ppq, matching the old stable order) and packs — no whole-take sort. The result
-- is byte-identical to encode(replaceCCInRange(...)).
function M.encodeMerged(kept, chan, lane, newCCs, eot)
  newCCs = newCCs or {}
  local newEvents = {}
  for _, cc in ipairs(newCCs) do
    local value = cc.value or 0
    if value < 0 then value = 0 elseif value > 127 then value = 127 end
    value = value // 1
    local status = 0xB0 | (chan & 0x0F)
    newEvents[#newEvents + 1] = {
      ppq = math.floor((cc.ppq or 0) + 0.5),
      flags = flagsForCCShape(cc.shape or 0) | (cc.sel and 0x01 or 0),  -- bit0 = selected (preserved on reduce)
      msg = string.char(status, lane & 0x7F, value & 0x7F),
    }
  end
  table.sort(newEvents, function(a, b) return a.ppq < b.ppq end)   -- small (m ~ points)

  local out, last = {}, 0
  local i, j, nk, nn = 1, 1, #kept, #newEvents
  local function emit(ev)
    local ppq = math.floor(ev.ppq + 0.5)
    out[#out + 1] = spack(FMT, ppq - last, ev.flags, ev.msg)
    last = ppq
  end
  while i <= nk and j <= nn do
    if kept[i].ppq <= newEvents[j].ppq then emit(kept[i]); i = i + 1
    else emit(newEvents[j]); j = j + 1 end
  end
  while i <= nk do emit(kept[i]); i = i + 1 end
  while j <= nn do emit(newEvents[j]); j = j + 1 end

  if eot and #eot > 0 then out[#out + 1] = eot
  else out[#out + 1] = spack(FMT, 0, 0x00, "\176\123\000") end
  return table.concat(out)
end

-- Expose helpers for tests / callers.
M.CCSHAPE_BITS = CCSHAPE_BITS
M._isCCOnLaneChan = isCCOnLaneChan

return M
