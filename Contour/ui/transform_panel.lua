-- ui/transform_panel.lua — Contour's Transform op body: a Scope toggle + Launch button. The overlay tool
-- owns the shaping controls (Curve / Power-Sine / Symmetrical) and the live readout, not this panel.
local M = {}
M.scope = "points"  -- "points" | "timesel" — which region Launch hands to the tool

local COLOR_HINT = 0xC0A040FF
local COLOR_OK   = 0x60C080FF

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

function M.draw(ctx, state)
  reaper.ImGui_Text(ctx, "Transform (mouse overlay)")
  reaper.ImGui_TextColored(ctx, COLOR_HINT, "Pick a scope, then Launch — shaping controls are in the tool.")
  reaper.ImGui_Separator(ctx)

  -- Scope: which region the tool operates on (handed to the tool at launch via ExtState).
  local rPts = reaper.ImGui_RadioButton(ctx, "Selected points##tr_sp", M.scope == "points")
  reaper.ImGui_SameLine(ctx)
  local rTS  = reaper.ImGui_RadioButton(ctx, "Time selection##tr_ts", M.scope == "timesel")
  if rPts then M.scope = "points" end
  if rTS  then M.scope = "timesel" end

  if reaper.ImGui_Button(ctx, "Launch Transform##tr_launch") then
    reaper.SetExtState("Contour", "tr_scope", M.scope, false)  -- one-time scope handoff
    local cmd = resolveCmd()
    if cmd ~= 0 then reaper.Main_OnCommand(cmd, 0); M.status = nil  -- clear any stale prior-launch error
    else M.status = "Couldn't locate contour_transform.lua — run it once from the Action list." end
  end
  reaper.ImGui_SameLine(ctx)
  reaper.ImGui_TextColored(ctx, COLOR_HINT, "(or a hotkey on contour_transform.lua)")

  if M.status then reaper.ImGui_TextColored(ctx, COLOR_OK, M.status) end
end

return M
