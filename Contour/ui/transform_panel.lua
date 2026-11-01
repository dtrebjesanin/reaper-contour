-- ui/transform_panel.lua — Contour's Transform op body: a Scope dropdown + Launch button. The overlay tool
-- owns the shaping controls (Curve / Power-Sine / Symmetrical) and the live readout, not this panel.
local M = {}
local theme = require("ui.theme")
local common = require("ui.common")
M.scope = "points"  -- "points" | "timesel" — which region Launch hands to the tool

-- Resolve the contour_transform action's command id so Launch can fire it via Main_OnCommand — which works
-- regardless of which window is focused (a Main-section hotkey won't fire while the MIDI editor has focus).
-- Resolve the ACTUAL installed file FIRST: AddRemoveReaScript registers it if needed and returns its current
-- command id, so a stale cached id (e.g. left over from a moved/renamed script) can never hijack the button.
-- Refresh the cache from it. Fall back to the cache, then a _Contour_Transform named-command lookup, only if
-- AddRemoveReaScript is unavailable.
local SEP  = package.config:sub(1, 1)
local ROOT = (debug.getinfo(1, "S").source:match("^@?(.*)[/\\]ui[/\\]")) or "."
local function resolveCmd()
  if reaper.AddRemoveReaScript then
    local id = reaper.AddRemoveReaScript(true, 0, ROOT .. SEP .. "contour_transform.lua", true)
    if id and id ~= 0 then reaper.SetExtState("Contour", "tr_cmd", tostring(id), true); return id end
  end
  local cached = tonumber(reaper.GetExtState("Contour", "tr_cmd")) or 0
  if cached ~= 0 then return cached end
  return reaper.NamedCommandLookup("_Contour_Transform")
end

-- Shown (and Launch disabled) when the range scope (the dropdown then reads "Razor areas") would take several
-- razor areas of the target lane:
-- the overlay has one box, so it needs one span. Same text as ui/overlay.lua's refusal. The Selected points
-- scope never asks for a razor area, so it never warns and Launch works (if the overlay later falls back to
-- the time-selection scope it refuses on its own). The text lives in ui/common.lua.
function M.draw(ctx, state, detected)
  local severalAreas = detected ~= nil and detected.rangeSource == "razor"
                        and type(detected.ranges) == "table" and #detected.ranges > 1
  theme.sectionHeader(ctx, "Transform (mouse overlay)")
  reaper.ImGui_TextColored(ctx, theme.C.hint, "Pick a scope, then Launch — shaping controls are in the tool.")
  reaper.ImGui_Separator(ctx)

  -- Scope: which region the tool operates on (handed to the tool at launch via ExtState). The same dropdown as
  -- Generate and Reduce: the range option first, named after the lane's range (common.rangeLabel), then
  -- Selected points.
  do
    local cur = (M.scope == "timesel") and 0 or 1
    local items = common.rangeLabel(detected) .. "\0Selected points\0"
    reaper.ImGui_SetNextItemWidth(ctx, common.SCOPE_W)
    local changed, idx = reaper.ImGui_Combo(ctx, "Scope##tr_scope", cur, items, #items)
    if changed and idx == 0 then M.scope = "timesel" elseif changed and idx == 1 then M.scope = "points" end
  end
  local manyAreas = severalAreas and M.scope == "timesel"   -- after the dropdown pick: this frame's scope

  if manyAreas then reaper.ImGui_TextColored(ctx, theme.C.warn, common.MSG_ONE_AREA) end

  -- Launch: disabled while the Time selection scope has several razor areas to take. A disabled button
  -- reports no click, but the click is ignored in code too, so nothing reaches ExtState however the button
  -- was drawn.
  local function launch()
    if theme.accentButton(ctx, "Launch Transform##tr_launch") and not manyAreas then
      reaper.SetExtState("Contour", "tr_scope", M.scope, false)  -- one-time scope handoff
      local cmd = resolveCmd()
      if cmd ~= 0 then reaper.Main_OnCommand(cmd, 0); M.status = nil  -- clear any stale prior-launch error
      else M.status = "Couldn't locate contour_transform.lua — run it once from the Action list." end
    end
  end
  if reaper.ImGui_BeginDisabled then
    -- EndDisabled must follow every BeginDisabled, so a throw inside launch() cannot leave the panel greyed
    -- out (it is re-raised afterwards, and contour.lua still reports it).
    reaper.ImGui_BeginDisabled(ctx, manyAreas)
    local ok, err = pcall(launch)
    reaper.ImGui_EndDisabled(ctx)
    if not ok then error(err, 0) end
  elseif not manyAreas then
    launch()  -- an older ReaImGui cannot grey the button out, so it is simply not drawn
  end
  reaper.ImGui_SameLine(ctx)
  reaper.ImGui_TextColored(ctx, theme.C.hint, "(or a hotkey on contour_transform.lua)")

  if M.status then reaper.ImGui_TextColored(ctx, theme.C.warn, M.status) end
end

return M
