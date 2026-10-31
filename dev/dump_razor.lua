-- dump_razor.lua — razor-area spike (throwaway). Danilo runs this in REAPER and pastes the console.
-- Polls every 0.1 s, never every frame. For the master track and every track it prints ONLY a change
-- of P_RAZOREDITS or P_RAZOREDITS_EXT, with time_precise() and the left mouse button (JS_Mouse_GetState(1)),
-- then the GUID of the currently selected envelope. Stop it from the Actions list (terminate instances).
--
--   MODE = "dump"    answers (a) raw strings, (b) change during drag or on mouse-up, (c) does a razor
--                    drag on an envelope lane select that envelope (see the "selected env" line).
--   MODE = "select"  as "dump", plus: takes the first envelope GUID in a changed razor string, finds
--                    that envelope, calls SetCursorContext(2, env) and prints GetSelectedEnvelope(0) == env
--                    right away and once more 0.1 s later. Also prints whether the foreground and focus
--                    windows changed. Answers (d). Keep a floating Contour window open and watch it.
local MODE = "dump" -- "dump" or "select"
local INTERVAL = 0.1

local KEYS = { "P_RAZOREDITS", "P_RAZOREDITS_EXT" }
local now = reaper.time_precise or os.clock

local function out(s) reaper.ShowConsoleMsg(s .. "\n") end

local function mouse()
  if reaper.JS_Mouse_GetState then return tostring(reaper.JS_Mouse_GetState(1)) end
  return "n/a"
end

local function guidOf(env)
  if not env then return "none" end
  local _, g = reaper.GetSetEnvelopeInfo_String(env, "GUID", "", false)
  return g
end

local function eachTrack(f)
  f(reaper.GetMasterTrack(0), "M")
  for i = 0, reaper.CountTracks(0) - 1 do f(reaper.GetTrack(0, i), "T" .. (i + 1)) end
end

local function findEnv(guid)
  local found
  eachTrack(function(tr)
    for e = 0, reaper.CountTrackEnvelopes(tr) - 1 do
      local env = reaper.GetTrackEnvelope(tr, e)
      if not found and guidOf(env):upper() == guid:upper() then found = env end
    end
  end)
  return found
end

local function windows()
  if not (reaper.JS_Window_GetForeground and reaper.JS_Window_GetFocus) then return nil end
  return reaper.JS_Window_GetForeground(), reaper.JS_Window_GetFocus()
end

local last, pending = {}, nil

local function trySelect(guid)
  local env = findEnv(guid)
  if not env then out("  envelope " .. guid .. " not found") return end
  local fg0, fo0 = windows()
  reaper.SetCursorContext(2, env)
  local fg1, fo1 = windows()
  out("  SetCursorContext(2, env) -> GetSelectedEnvelope(0) == env: "
    .. tostring(reaper.GetSelectedEnvelope(0) == env))
  if fg0 then
    out(("  foreground unchanged: %s  focus unchanged: %s"):format(tostring(fg0 == fg1), tostring(fo0 == fo1)))
  else
    out("  foreground/focus: n/a (no js_ReaScriptAPI)")
  end
  pending = env
end

local function tick()
  if pending then
    out("  0.1 s later: GetSelectedEnvelope(0) == env: " .. tostring(reaper.GetSelectedEnvelope(0) == pending))
    pending = nil
  end

  local changed, hit = false, nil
  eachTrack(function(tr, label)
    for _, key in ipairs(KEYS) do
      local _, s = reaper.GetSetMediaTrackInfo_String(tr, key, "", false)
      local id = label .. key
      if s ~= (last[id] or "") then
        last[id] = s
        changed = true
        out(("%.3f mouse=%s %s %s <%s>"):format(now(), mouse(), label, key, s))
        hit = hit or s:match('"(%b{})"')
      end
    end
  end)

  if changed then
    out("  selected env: " .. guidOf(reaper.GetSelectedEnvelope(0)))
    if MODE == "select" and hit then trySelect(hit) end
  end
end

local nextAt = 0
local function loop()
  if now() >= nextAt then
    nextAt = now() + INTERVAL
    tick()
  end
  reaper.defer(loop)
end

out(("dump_razor: MODE=%s, js_ReaScriptAPI=%s"):format(MODE, tostring(reaper.JS_Mouse_GetState ~= nil)))
reaper.atexit(function() out("dump_razor: stopped") end)
loop()
