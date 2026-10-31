-- dump_razor.lua — razor-area spike (throwaway). Danilo runs this in REAPER and pastes the console.
-- Polls every 0.1 s, never every frame. For the master track and every track it prints ONLY a change
-- of P_RAZOREDITS or P_RAZOREDITS_EXT, with time_precise() and the left mouse button (JS_Mouse_GetState(1)).
-- Separately, on any tick where the selected envelope changes (razor activity or not) it prints
-- "selected env: <old> -> <new>". Stop it from the Actions list (terminate instances).
--
-- Run MODE = "dump" FIRST. It answers (a) raw strings, (b) change during drag or on mouse-up,
-- (c) does a razor drag on an envelope lane select that envelope. (b) needs js_ReaScriptAPI for the
-- mouse state, so install it (ReaPack) before this run.
--
-- MODE = "select" answers (d) and only acts after a SETTLED razor drag: no razor change for 1 s and the
-- mouse button up (when js_ReaScriptAPI is present). It then prints a prompt: click into your floating
-- Contour (or any ReaImGui) window within 3 s. After 3 s it clears the envelope selection
-- (SetCursorContext(2, nil), prints GetSelectedEnvelope(0), expected none), takes the first envelope GUID
-- of the last changed razor string, finds that envelope and calls SetCursorContext(2, env). It prints
-- GetSelectedEnvelope(0) == env right after and 0.1 s later. The foreground and focus windows are read
-- right before the call, right after it and 0.1 s later (needs js_ReaScriptAPI). Watch the Contour window.
local MODE = "dump" -- "dump" or "select"
local INTERVAL = 0.1
local SETTLE = 1.0 -- seconds without a razor change before select mode goes on
local GRACE = 3.0  -- seconds Danilo gets to click into the Contour window

local KEYS = { "P_RAZOREDITS", "P_RAZOREDITS_EXT" }
local now = reaper.time_precise or os.clock

local function out(s) reaper.ShowConsoleMsg(s .. "\n") end

local function mouse()
  if reaper.JS_Mouse_GetState then return tostring(reaper.JS_Mouse_GetState(1)) end
  return "n/a"
end

local function mouseUp()
  if not reaper.JS_Mouse_GetState then return true end
  return reaper.JS_Mouse_GetState(1) % 2 == 0
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
  if not (reaper.JS_Window_GetForeground and reaper.JS_Window_GetFocus) then return {} end
  return { fg = reaper.JS_Window_GetForeground(), fo = reaper.JS_Window_GetFocus() }
end

local function reportWindows(label, ref)
  local w = windows()
  if not w.fg then out("  " .. label .. ": foreground/focus n/a (no js_ReaScriptAPI)") return end
  out(("  %s: foreground unchanged: %s  focus unchanged: %s"):format(label, tostring(w.fg == ref.fg), tostring(w.fo == ref.fo)))
end

local last, lastSel, pending, arm = {}, guidOf(reaper.GetSelectedEnvelope(0)), nil, nil

local function trySelect(guid)
  local env = findEnv(guid)
  if not env then out("  envelope " .. guid .. " not found") return end
  local base = windows()
  reaper.SetCursorContext(2, nil)
  out("  cleared selection -> GetSelectedEnvelope(0): " .. guidOf(reaper.GetSelectedEnvelope(0)) .. " (expected none)")
  local pre = windows()
  if pre.fg then
    out(("  before select: foreground is REAPER main window: %s (expected false after your click)  clear changed foreground/focus: %s")
      :format(tostring(pre.fg == reaper.GetMainHwnd()), tostring(pre.fg ~= base.fg or pre.fo ~= base.fo)))
  end
  reaper.SetCursorContext(2, env)
  out("  SetCursorContext(2, env) -> GetSelectedEnvelope(0) == env: " .. tostring(reaper.GetSelectedEnvelope(0) == env))
  reportWindows("right after", pre)
  pending = { env = env, pre = pre }
end

local function tick()
  local t = now()
  if pending then
    out("  0.1 s later: GetSelectedEnvelope(0) == env: " .. tostring(reaper.GetSelectedEnvelope(0) == pending.env))
    reportWindows("0.1 s later", pending.pre)
    pending = nil
  end

  local sel = guidOf(reaper.GetSelectedEnvelope(0))
  if sel ~= lastSel then
    out(("%.3f mouse=%s selected env: %s -> %s"):format(t, mouse(), lastSel, sel))
    lastSel = sel
  end

  local changed, hit = false, nil
  eachTrack(function(tr, label)
    for _, key in ipairs(KEYS) do
      local _, s = reaper.GetSetMediaTrackInfo_String(tr, key, "", false)
      local id = label .. key
      if s ~= (last[id] or "") then
        last[id] = s
        changed = true
        out(("%.3f mouse=%s %s %s <%s>"):format(t, mouse(), label, key, s))
        hit = hit or s:match('"(%b{})"')
      end
    end
  end)

  if MODE ~= "select" then return end
  if changed then -- any razor change restarts the settle timer
    arm = arm or {}
    arm.stage, arm.at, arm.guid = "settle", t, hit or arm.guid
    if not arm.guid then arm = nil end
  end
  if arm and arm.stage == "settle" and t - arm.at >= SETTLE and mouseUp() then
    out(("  razor settled. Click into your floating Contour (or any ReaImGui) window within %g s; SetCursorContext fires after that."):format(GRACE))
    arm.stage, arm.at = "wait", t
  elseif arm and arm.stage == "wait" and t - arm.at >= GRACE then
    local guid = arm.guid
    arm = nil
    trySelect(guid)
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
