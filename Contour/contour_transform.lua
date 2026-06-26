-- @noindex
--
-- This file is published as PART of the "Contour" package: contour.lua's @provides lists it with the
-- [main] option, so ReaPack registers it as a second Action List entry ("Contour Transform"). @noindex
-- stops reapack-index from ALSO treating this file as its own standalone package. All package metadata
-- (@version, @provides, @about, ...) lives in contour.lua — do not duplicate it here.

-- contour_transform.lua — entry for the Transform overlay (track envelopes, automation items, MIDI CC).
-- Runnable as its own action (hotkey-bindable) and launchable from the Contour panel.
local sep = package.config:sub(1,1)
local src = debug.getinfo(1,"S").source:match("^@?(.*[/\\])") or ("."..sep)
package.path = src .. "?.lua;" .. package.path

-- Record this action's own command id so Contour's "Launch" button can fire it via Main_OnCommand — which
-- works from any focused window (a Main-section hotkey won't fire while the MIDI editor has focus).
do local _, _, _, cmdID = reaper.get_action_context()
   if cmdID and cmdID ~= 0 then reaper.SetExtState("Contour", "tr_cmd", tostring(cmdID), true) end end

-- dependency guards
local missing = {}
if not reaper.ImGui_CreateContext then missing[#missing+1] = "ReaImGui" end
if not reaper.JS_Window_FindChildByID then missing[#missing+1] = "js_ReaScriptAPI" end
if not reaper.BR_GetMouseCursorContext then missing[#missing+1] = "SWS" end
if #missing > 0 then
  reaper.ShowMessageBox("Contour Transform needs: " .. table.concat(missing, ", ") ..
    ".\nInstall via ReaPack, then retry.", "Contour Transform — missing dependency", 0)
  return
end

local context = require("core.context")
local overlay = require("ui.overlay")

local ctx = reaper.ImGui_CreateContext("Contour Transform")
reaper.atexit(function() pcall(overlay.finish) end)

local detected = context.detect()
local ok, err = overlay.start(ctx, detected)
if not ok then
  reaper.ShowMessageBox(err or "Nothing to transform.", "Contour Transform", 0)
  return
end

local function loop()
  if overlay.frame(ctx) then
    reaper.defer(loop)
  else
    overlay.finish()
  end
end
reaper.defer(loop)
