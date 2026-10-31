-- ui/shell.lua — top-level shell: operation switcher (Generate/Reduce/Transform) + shared
-- target tabs (Envelope/Automation Item/MIDI CC) + one context line + the active operation's body.
-- The active tab follows the detected context (edge-triggered) unless the user clicks a tab,
-- and can be toggled off via the "Follow" checkbox on the context line.
--
-- Layout: the header (switcher, tabs, context line) is drawn in the outer window and never scrolls. The
-- op's body is drawn inside the ##contour_body child, which scrolls. Generate also has a footer (Live /
-- Generate / Reset / hints / status) drawn BELOW the child, pinned; the child is sized to leave room for it.
local M = {}

local generate        = require("ui.generate")
local reduce          = require("ui.reduce")
local transform_panel = require("ui.transform_panel")
local theme           = require("ui.theme")
local common          = require("ui.common")
local context         = require("core.context")

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

local FLAG_SETSEL = reaper.ImGui_TabItemFlags_SetSelected and reaper.ImGui_TabItemFlags_SetSelected() or 0

local function opSwitcher(ctx, state)
  -- Segmented-control look: the three ops share the row at equal widths; the selected one is
  -- accent-filled with bright text, the others sit muted with dim text.
  local availW = (reaper.ImGui_GetContentRegionAvail and select(1, reaper.ImGui_GetContentRegionAvail(ctx))) or 0
  local w = (availW and availW > 120) and math.floor((availW - 16) / 3) or nil   -- 2 gaps x ItemSpacing 8
  for i, op in ipairs(OPS) do
    if i > 1 then reaper.ImGui_SameLine(ctx) end
    local sel = state.op == op.id
    local C = theme.C   -- read per frame: the palette can change under us
    reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_Button(),        sel and C.accent or C.mute)
    reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_ButtonHovered(), sel and C.accentH or C.muteH)
    reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_ButtonActive(),  C.accent)
    reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_Text(),          sel and C.onAccent or C.textDim)
    local clicked
    if w then clicked = reaper.ImGui_Button(ctx, op.label, w) else clicked = reaper.ImGui_Button(ctx, op.label) end
    if clicked then
      -- Leaving an op mid-drag would dangle its live undo block; close it cleanly.
      if op.id ~= state.op then
        if state.op == "generate" and generate.cleanup then pcall(generate.cleanup) end
        if state.op == "reduce"   and reduce.cleanup   then pcall(reduce.cleanup)   end
      end
      state.op = op.id
    end
    reaper.ImGui_PopStyleColor(ctx, 4)
  end
end

-- The palette menu, a trailing "..." button at the end of the tab bar. Call it INSIDE the tab bar:
-- BeginTabBar pushes an ID scope, and OpenPopup / BeginPopup must see the same one (after EndTabBar the
-- IDs differ and the popup never opens). EndPopup only follows a BeginPopup that returned true; the body
-- runs in a pcall so a throw cannot leave the popup open (re-raised, as with the body child below).
local function paletteMenu(ctx)
  if not (reaper.ImGui_TabItemButton and reaper.ImGui_TabItemFlags_Trailing and reaper.ImGui_OpenPopup
          and reaper.ImGui_BeginPopup and reaper.ImGui_MenuItem) then return end
  if reaper.ImGui_TabItemButton(ctx, "...##palette", reaper.ImGui_TabItemFlags_Trailing()) then
    reaper.ImGui_OpenPopup(ctx, "##palette_menu")
  end
  if reaper.ImGui_BeginPopup(ctx, "##palette_menu") then
    local ok, err = pcall(function()
      reaper.ImGui_TextColored(ctx, theme.C.textDim, "Palette")
      local current = theme.paletteId()   -- read once: a click below changes it mid-loop
      for _, p in ipairs(theme.PALETTES) do
        if reaper.ImGui_MenuItem(ctx, p.name, nil, p.id == current) then theme.setPalette(p.id) end
      end
    end)
    reaper.ImGui_EndPopup(ctx)
    if not ok then error(err, 0) end
  end
end

local function targetTabs(ctx, state)
  if reaper.ImGui_BeginTabBar(ctx, "contour_targets") then
    -- EndTabBar must follow a BeginTabBar that returned true even when the palette menu throws (it re-raises
    -- from inside the bar), so the bar's contents run in a pcall and the error is re-raised after EndTabBar.
    local ok, err = pcall(function()
      for _, t in ipairs(TARGETS) do
        local flags = (state.forceTarget == t.id) and FLAG_SETSEL or 0
        if reaper.ImGui_BeginTabItem(ctx, t.label, nil, flags) then
          state.target = t.id
          reaper.ImGui_EndTabItem(ctx)
        end
      end
      paletteMenu(ctx)
    end)
    reaper.ImGui_EndTabBar(ctx)
    if not ok then error(err, 0) end
  end
  state.forceTarget = nil   -- one-frame pulse
end

-- Select the envelope `env` in REAPER (the arrange view takes focus) and mark the arrange as the surface the
-- user engaged, so detection lands on it even when it is already the selected envelope while a MIDI CC
-- selection is active. The ONE place that changes the target lane: the chooser pick and the settled-drag switch
-- both come here. When `env` already is the target's envelope nothing is re-selected: SetCursorContext(2, env)
-- could drop an automation-item selection on it, and the arrange is engaged either way.
local function selectLane(env, detected)
  local current = detected and detected.details and detected.details.env
  if reaper.SetCursorContext and env ~= current then reaper.SetCursorContext(2, env) end
  context.engageArrange()
end

-- The range text for razor areas on the target's lane: "Razor 1.200 .. 1.950 s" for one area, and for several
-- "Razor ×2, 1.000 .. 6.000 s" (the count, then the first start .. the last end).
local function razorRangeText(ranges)
  if #ranges == 1 then return ("Razor %.3f .. %.3f s"):format(ranges[1][1], ranges[1][2]) end
  return ("Razor ×%d, %.3f .. %.3f s"):format(#ranges, ranges[1][1], ranges[#ranges][2])
end

local CHOOSER_W = 170

-- "Razor on N lanes: [lane v]": the razor areas cover two or more envelope lanes, so Contour cannot tell which
-- one is meant. The preview names the target when it is one of them, else "choose a lane" (nothing is
-- written to any covered lane until one is picked). Returns the envelope picked this frame, or nil; the caller
-- applies it AFTER EndCombo. EndCombo only follows a BeginCombo that returned true; the entries run in a
-- pcall so a throw cannot leave the combo open (re-raised, as with the palette menu).
local function laneChooser(ctx, detected, lanes)
  local targetEnv = detected.details and detected.details.env
  local preview = "choose a lane"
  for _, lane in ipairs(lanes) do
    if lane.env == targetEnv then preview = lane.label; break end
  end

  reaper.ImGui_AlignTextToFramePadding(ctx)
  reaper.ImGui_TextColored(ctx, theme.C.textDim, ("Razor on %d lanes:"):format(#lanes))
  reaper.ImGui_SameLine(ctx)
  reaper.ImGui_SetNextItemWidth(ctx, CHOOSER_W)
  local picked
  if reaper.ImGui_BeginCombo(ctx, "##razor_lane", preview) then
    local ok, err = pcall(function()
      for i, lane in ipairs(lanes) do
        -- Two tracks can share a name, so each entry gets its own ID after the "##" (not shown); no ID scope to
        -- balance if Selectable throws.
        local clicked = reaper.ImGui_Selectable(ctx, lane.label .. "##lane" .. i, lane.env == targetEnv)
        if clicked then picked = lane.env end
      end
    end)
    reaper.ImGui_EndCombo(ctx)
    if not ok then error(err, 0) end
  end
  return picked
end

-- What the context line says about the range Contour works on, in which colour, and whether it is a razor text:
-- the razor areas on the target's lane (dim), the hint when they all fall outside, else the time selection or
-- the no-selection hint.
local function rangeText(detected)
  if detected.rangeSource == "razor" and detected.ranges and #detected.ranges >= 1 then
    return razorRangeText(detected.ranges), theme.C.textDim, true
  elseif detected.razorOutside then
    return common.razorOutsideText(detected), theme.C.hint, true
  elseif detected.hasTimeSel then
    return ("%.3f .. %.3f s"):format(detected.t0, detected.t1), theme.C.textDim, false
  end
  return "No time selection", theme.C.hint, false
end

-- Row 3: ONE context line — what was detected, the range Contour works on, and the Follow toggle pinned to the
-- right edge of the same line. Two things can take a second line under it (a third when both do):
--   * a RAZOR text (the range or the outside hint), when label + text + Follow do not fit on the line (the razor
--     texts are wider than the time selection's; the outside hint alone is wider than the panel at 360 px).
--     Follow stays on the first line. The time selection text and "No time selection" never wrap: for a user
--     without razor areas the line is exactly what it was, with Follow clamped to just after the text;
--   * the lane chooser (razor areas on two or more lanes) or the one-line note (one lane other than the target):
--     it never shares the line with the range text, which already fills most of the 360 px.
local function contextLine(ctx, state, detected)
  -- Measure BEFORE drawing: the row's left edge and the full width available to it give the right edge.
  local x0 = reaper.ImGui_GetCursorPosX and reaper.ImGui_GetCursorPosX(ctx)
  local availW = reaper.ImGui_GetContentRegionAvail and select(1, reaper.ImGui_GetContentRegionAvail(ctx))
  local text, textCol, isRazor = rangeText(detected)

  -- The Follow checkbox's width (square + inner spacing + label), and (razor texts only) whether the whole line
  -- fits. Without the geometry calls the old behaviour stands: one line, plain SameLine.
  local followW, wrapRange
  if reaper.ImGui_CalcTextSize and reaper.ImGui_GetFrameHeight and type(availW) == "number" then
    local boxH = reaper.ImGui_GetFrameHeight(ctx)
    local followTextW = reaper.ImGui_CalcTextSize(ctx, "Follow")
    if type(boxH) == "number" and type(followTextW) == "number" then
      local innerSpacing, itemSpacing = 6, 8   -- ItemInnerSpacing.x, ItemSpacing.x (ui/theme)
      followW = boxH + innerSpacing + followTextW
      if isRazor then
        local labelW = reaper.ImGui_CalcTextSize(ctx, detected.label)
        local textW = reaper.ImGui_CalcTextSize(ctx, text)
        wrapRange = type(labelW) == "number" and type(textW) == "number"
          and labelW + itemSpacing + textW + itemSpacing + followW > availW
      end
    end
  end

  reaper.ImGui_Text(ctx, detected.label)
  if not wrapRange then
    reaper.ImGui_SameLine(ctx)
    reaper.ImGui_TextColored(ctx, textCol, text)
  end

  -- Right-align the checkbox: content width minus the checkbox's own width. Never left of where the text
  -- ended; if any geometry call is missing the plain SameLine is the fallback.
  reaper.ImGui_SameLine(ctx)
  if followW and reaper.ImGui_SetCursorPosX and reaper.ImGui_GetCursorPosX and type(x0) == "number" then
    local x = x0 + availW - followW
    local curX = reaper.ImGui_GetCursorPosX(ctx)
    if type(curX) == "number" and x < curX then x = curX end
    reaper.ImGui_SetCursorPosX(ctx, x)
  end
  local rv, follow = reaper.ImGui_Checkbox(ctx, "Follow##follow", state.follow)
  if rv then state.follow = follow end

  if wrapRange then reaper.ImGui_TextColored(ctx, textCol, text) end

  local lanes = detected.razorLanes
  if lanes and #lanes >= 2 then
    local picked = laneChooser(ctx, detected, lanes)
    if picked then selectLane(picked, detected) end
  elseif lanes and #lanes == 1 and lanes[1].env ~= (detected.details and detected.details.env) then
    reaper.ImGui_TextColored(ctx, theme.C.textDim, "Razor on 1 other lane")
  end
end

-- Footer height guess for the very first Generate frame, before drawFooter has been measured: about two
-- rows (the Live/Generate/Reset row plus a hint or status line) and a little spacing.
local function estimateFooterH(ctx)
  local rowH = reaper.ImGui_GetFrameHeightWithSpacing and reaper.ImGui_GetFrameHeightWithSpacing(ctx)
  if type(rowH) ~= "number" then rowH = 34 end   -- frame height + item spacing at the theme's metrics
  return 2 * rowH + 8
end

local function winFlag(name)
  local fn = reaper[name]
  return fn and fn() or 0
end

-- opts (optional, from contour.lua): { scroll = fn, noWheel = bool }.
--   scroll  — the smooth-scroll step; called right after BeginChild, so it acts on the body child.
--   noWheel — true when scroll() drives the wheel itself, so the child must not also scroll with it.
function M.draw(ctx, state, detected, opts)
  opts = opts or {}

  -- A razor drag that settled on exactly one lane (context.detect reports it for ONE frame): select that lane
  -- and detection picks it up on the next frame. With Follow off the target never moves by itself.
  if state.follow and detected.razorSwitchTo then selectLane(detected.razorSwitchTo, detected) end

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
  contextLine(ctx, state, detected)
  reaper.ImGui_Separator(ctx)

  -- Scrolling body. Only Generate has a footer; for Reduce / Transform the child fills the rest of the
  -- window (height 0). A negative height means "the remaining space minus this much", so -footerH leaves
  -- exactly the footer's room below the child.
  local hasFooter = state.op == "generate"
  local footerH = hasFooter and (state.footerH or estimateFooterH(ctx)) or 0
  -- Always show the child's scrollbar: Generate is tall (scrolls) while Reduce / Transform are short, and
  -- an auto scrollbar popping in and out on op switch made the content width jump.
  local childFlags = winFlag("ImGui_WindowFlags_AlwaysVerticalScrollbar")
  if opts.noWheel then childFlags = childFlags | winFlag("ImGui_WindowFlags_NoScrollWithMouse") end

  -- The theme's ChildBg is a shade lighter than WindowBg; the body child should blend into the window around
  -- it, so draw it transparent. The colour is read when the child begins, so pop it right after BeginChild.
  local pushedBg = 0
  if reaper.ImGui_PushStyleColor and reaper.ImGui_Col_ChildBg then
    reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_ChildBg(), 0x00000000)
    pushedBg = 1
  end
  -- Arg 5 is `border` (bool) in ReaImGui 0.8 but `child_flags` (int) from 0.9 — nil is valid for both;
  -- arg 6 (window flags) means the same in both.
  reaper.ImGui_BeginChild(ctx, "##contour_body", 0, -footerH, nil, childFlags)
  if pushedBg > 0 then reaper.ImGui_PopStyleColor(ctx, pushedBg) end
  -- EndChild is required after EVERY BeginChild, whatever it returned, and contour.lua's pcall around this
  -- function would swallow a throw and leave the child open. So the body runs in its own pcall, EndChild
  -- always follows, and the error is re-raised afterwards (contour.lua still reports it).
  local ok, err = pcall(function()
    if opts.scroll then opts.scroll() end
    if state.op == "generate" then
      generate.drawBody(ctx, state, detected)
    elseif state.op == "reduce" then
      reduce.draw(ctx, state, detected)
    else
      transform_panel.draw(ctx, state, detected)
    end
  end)
  reaper.ImGui_EndChild(ctx)
  if not ok then error(err, 0) end

  -- Pinned footer, in the outer window. Measure it every frame (cursor Y before/after, which includes the
  -- trailing item spacing) so the child above always leaves exactly the right amount of room.
  if hasFooter then
    local y0 = reaper.ImGui_GetCursorPosY and reaper.ImGui_GetCursorPosY(ctx)
    generate.drawFooter(ctx, state, detected)
    local y1 = reaper.ImGui_GetCursorPosY and reaper.ImGui_GetCursorPosY(ctx)
    if type(y0) == "number" and type(y1) == "number" and y1 - y0 > 0 then state.footerH = y1 - y0 end
  end
end

return M
