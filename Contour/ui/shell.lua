-- ui/shell.lua — top-level shell: operation switcher (Generate/Reduce/Transform) + shared
-- target tabs (Envelope/Automation Item/MIDI CC) + the active operation's body.
-- The active tab follows the detected context (edge-triggered) unless the user clicks a tab,
-- and can be toggled off via "Follow selection".
local M = {}

local generate        = require("ui.generate")
local reduce          = require("ui.reduce")
local transform_panel = require("ui.transform_panel")

local OPS = {
  { id = "generate",  label = "Generate" },
  { id = "reduce",    label = "Reduce" },
  { id = "transform", label = "Transform" },
}

local TARGETS = {
  { id = "envelope", label = "Envelope" },
  { id = "ai",       label = "Automation Item" },
  { id = "cc",       label = "MIDI CC" },
}

local ACCENT   = 0x2E8B9BFF   -- teal (selected)
local ACCENT_H = 0x3FB6C4FF   -- teal hover
local MUTE     = 0x3A3A3AFF   -- gray (unselected)
local MUTE_H   = 0x4A4A4AFF   -- gray hover

local FLAG_SETSEL = reaper.ImGui_TabItemFlags_SetSelected and reaper.ImGui_TabItemFlags_SetSelected() or 0

local function opSwitcher(ctx, state)
  for i, op in ipairs(OPS) do
    if i > 1 then reaper.ImGui_SameLine(ctx) end
    local sel = state.op == op.id
    reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_Button(),        sel and ACCENT or MUTE)
    reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_ButtonHovered(), sel and ACCENT_H or MUTE_H)
    reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_ButtonActive(),  ACCENT)
    if reaper.ImGui_Button(ctx, op.label) then
      -- Leaving an op mid-drag would dangle its live undo block; close it cleanly.
      if op.id ~= state.op then
        if state.op == "generate" and generate.cleanup then pcall(generate.cleanup) end
        if state.op == "reduce"   and reduce.cleanup   then pcall(reduce.cleanup)   end
      end
      state.op = op.id
    end
    reaper.ImGui_PopStyleColor(ctx, 3)
  end
end

local function targetTabs(ctx, state)
  if reaper.ImGui_BeginTabBar(ctx, "contour_targets") then
    for _, t in ipairs(TARGETS) do
      local flags = (state.forceTarget == t.id) and FLAG_SETSEL or 0
      if reaper.ImGui_BeginTabItem(ctx, t.label, nil, flags) then
        state.target = t.id
        reaper.ImGui_EndTabItem(ctx)
      end
    end
    reaper.ImGui_EndTabBar(ctx)
  end
  state.forceTarget = nil   -- one-frame pulse
end

function M.draw(ctx, state, detected)
  -- Edge-triggered follow: snap the tab to the detected target only when the detection changes,
  -- so manual tab clicks aren't yanked back every frame.
  if state.follow and detected.target and detected.target ~= state.lastDetected then
    state.forceTarget = detected.target
  end
  state.lastDetected = detected.target

  opSwitcher(ctx, state)
  reaper.ImGui_Separator(ctx)
  targetTabs(ctx, state)
  reaper.ImGui_Separator(ctx)

  local rv, follow = reaper.ImGui_Checkbox(ctx, "Follow selection", state.follow)
  if rv then state.follow = follow end

  reaper.ImGui_Text(ctx, "Detected: " .. detected.label)
  if detected.hasTimeSel then
    reaper.ImGui_Text(ctx, ("Time selection: %.3f .. %.3f s"):format(detected.t0, detected.t1))
  else
    reaper.ImGui_TextColored(ctx, 0xC0A040FF, "No time selection")
  end
  reaper.ImGui_Separator(ctx)
  reaper.ImGui_Text(ctx, ("Operation: %s    Active tab: %s"):format(state.op, state.target))
  reaper.ImGui_Separator(ctx)

  -- Operation body.
  if state.op == "generate" then
    generate.draw(ctx, state, detected)
  elseif state.op == "reduce" then
    reduce.draw(ctx, state, detected)
  else
    transform_panel.draw(ctx, state)
  end
end

return M
