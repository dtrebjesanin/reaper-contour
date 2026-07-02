-- core/context.lua — detect what the user is currently pointed at in REAPER and return a
-- target descriptor. Read-only; the only Reaper-bound piece touched in this slice.
-- Returns: { target = "envelope"|"ai"|"cc"|nil, label = string,
--            hasTimeSel = bool, t0 = number, t1 = number, details = table|nil }
local M = {}

-- Focus-recency memory: which surface (MIDI editor vs arrange) the user most recently engaged. A selected
-- envelope/AI in the arrange and a CC selection in the MIDI editor BOTH persist at once, so neither alone
-- says which the user is working on now — only recency does. detect() runs ~30x/s; this carries between
-- frames. M._resetRecency() exists for tests.
local lastSide   -- "midi" | "arrange" | nil
local prevEnv    -- last selected-envelope handle seen (for the changed-envelope backstop)

function M._resetRecency() lastSide, prevEnv = nil, nil end  -- test-only

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

function M.detect()
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

return M
