-- core/context.lua — detect what the user is currently pointed at in REAPER and return a
-- target descriptor. Read-only; the only Reaper-bound piece touched in this slice.
-- Returns: { target = "envelope"|"ai"|"cc"|nil, label = string,
--            hasTimeSel = bool, t0 = number, t1 = number, details = table|nil,
--            -- the range Contour works on (razor areas on the target lane, else the time selection):
--            rangeSource = "razor"|"timesel", ranges = { {t0, t1}, ... }, hasRange = bool,
--            razorOutside = bool,    -- the lane has razor areas but all fall outside the target's bounds
--            -- razor areas, whatever the target (see "razor areas" below):
--            razorLanes = { {guid=, env=, label="Track: Envelope"}, ... },
--            razorSwitchTo = env|nil }  -- set on the ONE frame a settled drag covers exactly one lane
-- hasTimeSel/t0/t1 always describe the time selection, whatever the range is.
local razor = require("core.razor")

local M = {}

-- Focus-recency memory: which surface (MIDI editor vs arrange) the user most recently engaged. A selected
-- envelope/AI in the arrange and a CC selection in the MIDI editor BOTH persist at once, so neither alone
-- says which the user is working on now — only recency does. detect() runs ~30x/s; this carries between
-- frames. M._resetRecency() exists for tests.
local lastSide   -- "midi" | "arrange" | nil
local prevEnv    -- last selected-envelope handle seen (for the changed-envelope backstop)

function M._resetRecency() lastSide, prevEnv = nil, nil end  -- test-only

-- The user engaged the arrange (e.g. picked a lane from the razor chooser). Without this, picking the
-- envelope that is ALREADY selected changes nothing while a MIDI CC selection is active: the changed-
-- envelope backstop in detect() only fires when the handle differs from the last one seen.
function M.engageArrange() lastSide = "arrange" end

local function timeSelection()
  local t0, t1 = reaper.GetSet_LoopTimeRange(false, false, 0, 0, false)
  return t0, t1
end

local function envDescriptor(env)
  local _, ename = reaper.GetEnvelopeName(env, "")
  if ename == "" then ename = "(unnamed)" end
  -- TAKE envelope (Volume/Pan/Mute/Pitch on a media item take): its own descriptor, checked FIRST —
  -- take envelopes have no automation items, and the target layer needs the take handle for the
  -- project<->take time conversion. Target id stays "envelope" (same tab/gates); details.take marks it.
  if reaper.Envelope_GetParentTake then
    local take = reaper.Envelope_GetParentTake(env)
    if take and (not reaper.ValidatePtr2 or reaper.ValidatePtr2(0, take, "MediaItem_Take*")) then
      return { target = "envelope", label = "Take envelope: " .. ename,
               details = { env = env, take = take } }
    end
  end
  -- Is an automation item within this envelope selected? Then it's the AI target.
  local selAi, aiCount = nil, reaper.CountAutomationItems(env)
  for i = 0, aiCount - 1 do
    if reaper.GetSetAutomationItemInfo(env, i, "D_UISEL", 0, false) > 0 then selAi = i; break end
  end
  if selAi then
    return { target = "ai", label = ("Automation item #%d on %s"):format(selAi, ename),
             details = { env = env, aiIndex = selAi } }
  end
  return { target = "envelope", label = "Envelope: " .. ename, details = { env = env } }
end

local function ccDescriptor(take, me)
  local _, tname = reaper.GetSetMediaItemTakeInfo_String(take, "P_NAME", "", false)
  if tname == "" then tname = "(unnamed take)" end
  return { target = "cc", label = "MIDI take: " .. tname, details = { take = take, midiEditor = me } }
end

-- Which surface is OS-focused right now: "midi" (the MIDI editor or its CC/note view), "arrange" (the
-- arrange trackview), or nil when focus is elsewhere (the Contour panel, the TCP, a menu) or
-- js_ReaScriptAPI is absent. Deliberately precise: ONLY the trackview counts as arrange (not the whole
-- main frame), so clicking the Contour window — even when it's docked in the main window — never reads as
-- an arrange engagement and so never spuriously flips the target.
local function focusedSide(me)
  if not (reaper.JS_Window_GetFocus and reaper.JS_Window_FindChildByID) then return nil end
  local f = reaper.JS_Window_GetFocus()
  if not f then return nil end
  if me then
    if f == me then return "midi" end
    local mv = reaper.JS_Window_FindChildByID(me, 0x3E9)    -- 1001 = MIDI editor CC/note view
    if mv and f == mv then return "midi" end
  end
  local main = reaper.GetMainHwnd and reaper.GetMainHwnd()
  if main then
    local tv = reaper.JS_Window_FindChildByID(main, 0x3E8)  -- 1000 = arrange trackview
    if tv and f == tv then return "arrange" end
  end
  return nil
end

local function fill(out, d)
  out.target, out.label, out.details = d.target, d.label, d.details
  return out
end

-- ── razor areas ──────────────────────────────────────────────────────────────────────────────────────
-- A razor area on the target's lane is its range (core/razor.lua holds the pure logic). Contour keeps ONE
-- snapshot of every track's P_RAZOREDITS, re-read at most every RAZOR_READ_SEC. Each read also feeds a
-- settler: a change counts only after RAZOR_SETTLE_SEC of stability with the left mouse button up, and the
-- first read is a baseline, so areas that exist when Contour starts never switch the lane (the first read after
-- the current project changes is a baseline too). When a settled change adds areas to exactly one resolvable
-- envelope lane (razor.dragLanes), detect() reports it once in razorSwitchTo.
-- Razor support needs the track API below; without it (or if a read throws) the range is the time
-- selection, exactly as before.
local RAZOR_READ_SEC   = 0.1
local RAZOR_SETTLE_SEC = 0.25

local rz            -- last read: { snap, lanes, at = clock time or nil, switchTo = env|nil }
local settler       -- razor.newSettler, created on the first read
local settledSnap   -- the snapshot at the last settled state (dragLanes compares against it)
local shownErr      -- the last razor error message printed to the console (once per distinct message)
local rzProject     -- the project (reaper.EnumProjects(-1)) rz / settler / settledSnap belong to; nil without the API

-- M._razorError is the last razor read's error (nil after a good read); the console gets each distinct message once.
function M._resetRazor()  -- test-only
  rz, settler, settledSnap, shownErr, rzProject, M._razorError = nil, nil, nil, nil, nil, nil
end

local RAZOR_API = {
  "GetMasterTrack", "CountTracks", "GetTrack", "GetSetMediaTrackInfo_String",
  "CountTrackEnvelopes", "GetTrackEnvelope", "GetSetEnvelopeInfo_String",
}
local function razorApi()
  for i = 1, #RAZOR_API do
    if not reaper[RAZOR_API[i]] then return false end
  end
  return true
end

-- An envelope's GUID the way core/razor writes it: "{...}", no quotes, upper case. nil when REAPER gives none.
local function envGuid(env)
  local _, g = reaper.GetSetEnvelopeInfo_String(env, "GUID", "", false)
  if type(g) ~= "string" then return nil end
  g = g:gsub('"', ""):match("^%s*(.-)%s*$"):upper()
  return g ~= "" and g or nil
end

local function copySpans(spans)
  local out = {}
  for i = 1, #spans do out[i] = { spans[i][1], spans[i][2] } end
  return out
end

-- The master track (index 0) and every track (1-based) with its raw razor string.
local function readTracks()
  local list, idxOf = {}, {}
  local function add(tr, idx)
    local _, raw = reaper.GetSetMediaTrackInfo_String(tr, "P_RAZOREDITS", "", false)
    list[#list + 1] = { track = tr, raw = raw }
    idxOf[tr] = idx
  end
  local master = reaper.GetMasterTrack(0)
  if master then add(master, 0) end
  for i = 0, (reaper.CountTracks(0) or 0) - 1 do
    local tr = reaper.GetTrack(0, i)
    if tr then add(tr, i + 1) end
  end
  return razor.snapshot(list), idxOf
end

local function trackLabel(tr, idx)
  if idx == 0 then return "Master" end
  local _, name = reaper.GetSetMediaTrackInfo_String(tr, "P_NAME", "", false)
  if type(name) ~= "string" or name == "" then return "Track " .. tostring(idx) end
  return name
end

-- The covered envelope lanes whose GUID names a real envelope on its track (REAPER has no envelope-by-GUID
-- lookup, so walk the track's envelopes). A stale GUID is left out: never listed, never switched to.
-- Returns the lane list in snapshot order and { [guid] = env }.
local function resolveLanes(snap, idxOf)
  local lanes, byGuid = {}, {}
  for _, guid in ipairs(snap.order) do
    local tr = snap.env[guid].track
    local env
    for i = 0, (reaper.CountTrackEnvelopes(tr) or 0) - 1 do
      local e = reaper.GetTrackEnvelope(tr, i)
      if e and envGuid(e) == guid then env = e; break end
    end
    if env then
      local _, ename = reaper.GetEnvelopeName(env, "")
      if type(ename) ~= "string" or ename == "" then ename = "(unnamed)" end
      lanes[#lanes + 1] = { guid = guid, env = env, label = trackLabel(tr, idxOf[tr]) .. ": " .. ename }
      byGuid[guid] = env
    end
  end
  return lanes, byGuid
end

local function leftMouseDown()
  if not reaper.JS_Mouse_GetState then return false end
  local m = reaper.JS_Mouse_GetState(1)
  return type(m) == "number" and (math.floor(m) & 1) ~= 0
end

-- The project the razor state is about (REAPER's current project tab); nil when EnumProjects is missing.
local function currentProject()
  if not reaper.EnumProjects then return nil end
  return (reaper.EnumProjects(-1))
end

-- The current razor state (throttled), or nil without the track API. The second result is true on a real
-- read, false when the last snapshot is reused; only a real read can carry a switchTo.
local function razorState()
  if not razorApi() then return nil end
  -- Another project tab has its own razor areas: they are not "new" here. Start over, so the next read is a
  -- baseline (and never a stale snapshot of the first project, whatever the throttle says).
  local proj = currentProject()
  if proj ~= rzProject then
    rz, settler, settledSnap = nil, nil, nil
    rzProject = proj
  end
  local now = reaper.time_precise and reaper.time_precise() or nil
  -- A clock that went backwards (new session, tests) must not freeze the snapshot. The 1e-9 is float
  -- slack: 0.6 - 0.5 is a hair under 0.1 and must still count as a full interval.
  if rz and now and rz.at and now >= rz.at and now - rz.at < RAZOR_READ_SEC - 1e-9 then return rz, false end

  local snap, idxOf = readTracks()
  local lanes, byGuid = resolveLanes(snap, idxOf)
  settler = settler or razor.newSettler(RAZOR_SETTLE_SEC)
  local settled = settler:feed(razor.sigOf(snap), now or os.clock(), leftMouseDown())
  local switchTo
  if settledSnap == nil then
    settledSnap = snap                      -- first read: the baseline, never a change
  elseif settled then
    -- dragLanes, not changedLanes: a drag over two lanes where one already had that span changes only the
    -- other, and that must not read as "one lane". Two or more lanes (or a lane we cannot resolve among
    -- them) is the chooser's job, never a guess.
    local hit = razor.dragLanes(settledSnap, snap)
    if #hit == 1 and byGuid[hit[1]] then switchTo = byGuid[hit[1]] end
    settledSnap = snap
  end
  rz = { snap = snap, lanes = lanes, at = now, switchTo = switchTo }
  return rz, true
end

-- The target's razor spans clamped to its bounds: a (possibly empty) list when the target's lane has razor
-- areas, nil when it has none (or the target never uses razor: MIDI CC, nothing selected).
local function razorRangeFor(d, snap)
  local det = d.details
  if not det then return nil end
  if d.target == "ai" then
    if next(snap.env) == nil then return nil end
    local guid = envGuid(det.env)
    local raw = guid and razor.envSpans(snap, guid) or {}
    if #raw == 0 then return nil end
    local pos = reaper.GetSetAutomationItemInfo(det.env, det.aiIndex, "D_POSITION", 0, false)
    local len = reaper.GetSetAutomationItemInfo(det.env, det.aiIndex, "D_LENGTH", 0, false)
    if type(pos) ~= "number" or type(len) ~= "number" then return nil end
    return razor.clamp(raw, pos, pos + len)
  elseif d.target == "envelope" and det.take then
    -- a take envelope has no lane of its own: the item lane under its item is where the razor goes
    if next(snap.item) == nil then return nil end
    local item = reaper.GetMediaItemTake_Item and reaper.GetMediaItemTake_Item(det.take)
    local tr = item and reaper.GetMediaItem_Track and reaper.GetMediaItem_Track(item)
    local raw = tr and razor.itemSpans(snap, tr) or {}
    if #raw == 0 then return nil end
    local pos = reaper.GetMediaItemInfo_Value(item, "D_POSITION")
    local len = reaper.GetMediaItemInfo_Value(item, "D_LENGTH")
    if type(pos) ~= "number" or type(len) ~= "number" then return nil end
    return razor.clamp(raw, pos, pos + len)
  elseif d.target == "envelope" then
    if next(snap.env) == nil then return nil end
    local guid = envGuid(det.env)
    local raw = guid and razor.envSpans(snap, guid) or {}
    if #raw == 0 then return nil end
    return copySpans(raw)                   -- envSpans hands out the stored table
  end
  return nil
end

-- One razor read for this frame: the covered lanes, the switch (nil unless this frame's read settled a
-- change) and the target's razor spans (nil = the target has none).
local function razorRead(d)
  local st, fresh = razorState()
  if not st then return nil, nil, nil end
  return st.lanes, fresh and st.switchTo or nil, razorRangeFor(d, st.snap)
end

-- Adds rangeSource / ranges / hasRange / razorOutside / razorLanes / razorSwitchTo to a detected descriptor.
local function addRanges(out)
  local ok, lanes, switchTo, spans = pcall(razorRead, out)
  if ok then
    M._razorError = nil
  else
    -- razor is simply off this frame; say why once per distinct message, as contour.lua does for draw errors
    local msg = tostring(lanes)
    M._razorError = msg
    if msg ~= shownErr then
      shownErr = msg
      if reaper.ShowConsoleMsg then reaper.ShowConsoleMsg("Contour razor error: " .. msg .. "\n") end
    end
    lanes, switchTo, spans = nil, nil, nil
  end
  out.razorLanes = lanes or {}
  out.razorSwitchTo = switchTo
  if spans then
    out.rangeSource, out.ranges = "razor", spans
  else
    out.rangeSource = "timesel"
    out.ranges = out.hasTimeSel and { { out.t0, out.t1 } } or {}
  end
  out.hasRange = #out.ranges > 0
  out.razorOutside = out.rangeSource == "razor" and not out.hasRange
  return out
end

local function detectTarget()
  local out = { target = nil, label = "(nothing selected)", hasTimeSel = false }
  local t0, t1 = timeSelection()
  out.t0, out.t1 = t0, t1
  out.hasTimeSel = (t1 > t0)

  -- Live candidates from current selection state.
  local me = reaper.MIDIEditor_GetActive()
  local meTake = me and reaper.MIDIEditor_GetTake(me)
  if meTake and not reaper.ValidatePtr2(0, meTake, "MediaItem_Take*") then meTake = nil end
  local cc  = meTake and ccDescriptor(meTake, me) or nil
  local env = reaper.GetSelectedEnvelope(0)
  local arr = env and envDescriptor(env) or nil

  -- Recency, primary signal: OS window focus says which surface the user is actually working on, so a
  -- lingering selection on the OTHER surface stops winning. Updates only when the focused surface has a
  -- valid candidate.
  local side = focusedSide(me)
  if side == "midi" and cc then lastSide = "midi"
  elseif side == "arrange" and arr then lastSide = "arrange" end

  -- Recency, backstop: switching from one envelope to another is an unambiguous arrange engagement even
  -- when focus landed somewhere focusedSide doesn't classify (e.g. picking the new envelope from the TCP).
  -- Guarded to a real change (prevEnv set) so first-sight of an envelope never overrides the focus signal.
  if env and prevEnv and env ~= prevEnv and arr then lastSide = "arrange" end
  prevEnv = env

  -- Resolve by recency; fall back gracefully when the remembered surface has no candidate (or it's a cold
  -- start / js_ReaScriptAPI is absent): a live CC selection still beats a stale envelope, then envelope/AI,
  -- then a plain open editor. The target tabs + "Follow selection" remain the manual override.
  if lastSide == "midi" and cc then return fill(out, cc) end
  if lastSide == "arrange" and arr then return fill(out, arr) end
  if cc and reaper.MIDI_EnumSelCC and reaper.MIDI_EnumSelCC(meTake, -1) ~= -1 then return fill(out, cc) end
  if arr then return fill(out, arr) end
  if cc then return fill(out, cc) end
  return out
end

function M.detect()
  return addRanges(detectTarget())
end

return M
