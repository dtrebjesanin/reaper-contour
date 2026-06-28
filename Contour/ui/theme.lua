-- ui/theme.lua — a coherent dark/teal Dear ImGui theme for Contour. Pushed once per frame AROUND the
-- whole window (style colors + style vars), with an optional UI font pushed around the content. It
-- cascades to every widget, so panels need no per-widget styling.
--
-- ROBUSTNESS: every Col_/StyleVar_/font API is GUARDED (only used if it exists in this ReaImGui build)
-- and the pop count always matches what was actually pushed — so the theme degrades gracefully across
-- ReaImGui versions instead of erroring. If styling is entirely unavailable the app still runs (plain).
--
-- Colors are 0xRRGGBBAA. Tweak the palette in C below (accent = the teal) to restyle everything.
local M = {}

local C = {
  text      = 0xDCE1E6FF, textDim   = 0x77818CFF,
  winBg     = 0x1B1E23FF, childBg   = 0x20242AFF, popupBg = 0x22262CFF,
  frame     = 0x2B3138FF, frameH    = 0x343B44FF, frameA  = 0x3C444EFF,
  accent    = 0x2E8B9BFF, accentH   = 0x3FB6C4FF, accentA = 0x53C9D6FF, accentDim = 0x2A6A75FF,
  tab       = 0x262B31FF, tabH      = 0x3FB6C4FF, tabSel  = 0x2E8B9BFF,
  sep       = 0x39404AFF,
  scrollBg  = 0x1B1E23FF, scrollGrab= 0x3C444EFF, scrollGrabH = 0x4A535EFF,
  header    = 0x2E8B9B33, headerH   = 0x2E8B9B55, headerA = 0x2E8B9B77,
  button    = 0x2B3138FF, buttonH   = 0x343B44FF, buttonA = 0x2E8B9BFF,
}

-- { Col_ enum fn name, color }. Both the legacy (TabActive/TabUnfocused) and the newer
-- (TabSelected/TabDimmed) tab-color names are listed and guarded — on any given build only the
-- existing ones are pushed, so there's no double-push.
local COLORS = {
  { "ImGui_Col_Text", C.text }, { "ImGui_Col_TextDisabled", C.textDim },
  { "ImGui_Col_WindowBg", C.winBg }, { "ImGui_Col_ChildBg", C.childBg }, { "ImGui_Col_PopupBg", C.popupBg },
  { "ImGui_Col_Border", 0x00000000 },
  { "ImGui_Col_FrameBg", C.frame }, { "ImGui_Col_FrameBgHovered", C.frameH }, { "ImGui_Col_FrameBgActive", C.frameA },
  { "ImGui_Col_TitleBg", C.childBg }, { "ImGui_Col_TitleBgActive", C.frame }, { "ImGui_Col_TitleBgCollapsed", C.childBg },
  { "ImGui_Col_Button", C.button }, { "ImGui_Col_ButtonHovered", C.buttonH }, { "ImGui_Col_ButtonActive", C.buttonA },
  { "ImGui_Col_SliderGrab", C.accent }, { "ImGui_Col_SliderGrabActive", C.accentA },
  { "ImGui_Col_CheckMark", C.accentH },
  { "ImGui_Col_Header", C.header }, { "ImGui_Col_HeaderHovered", C.headerH }, { "ImGui_Col_HeaderActive", C.headerA },
  { "ImGui_Col_Separator", C.sep }, { "ImGui_Col_SeparatorHovered", C.accent }, { "ImGui_Col_SeparatorActive", C.accentH },
  { "ImGui_Col_Tab", C.tab }, { "ImGui_Col_TabHovered", C.tabH }, { "ImGui_Col_TabActive", C.tabSel },
  { "ImGui_Col_TabUnfocused", C.tab }, { "ImGui_Col_TabUnfocusedActive", C.accentDim },
  { "ImGui_Col_TabSelected", C.tabSel }, { "ImGui_Col_TabDimmed", C.tab }, { "ImGui_Col_TabDimmedSelected", C.accentDim },
  { "ImGui_Col_ScrollbarBg", C.scrollBg }, { "ImGui_Col_ScrollbarGrab", C.scrollGrab },
  { "ImGui_Col_ScrollbarGrabHovered", C.scrollGrabH }, { "ImGui_Col_ScrollbarGrabActive", C.accent },
}

-- { StyleVar_ enum fn name, val1, val2_or_nil }. Two-component vars (padding/spacing) pass both.
local VARS = {
  { "ImGui_StyleVar_WindowRounding", 6 }, { "ImGui_StyleVar_ChildRounding", 6 },
  { "ImGui_StyleVar_PopupRounding", 6 }, { "ImGui_StyleVar_FrameRounding", 5 },
  { "ImGui_StyleVar_GrabRounding", 4 }, { "ImGui_StyleVar_TabRounding", 5 },
  { "ImGui_StyleVar_ScrollbarRounding", 6 },
  { "ImGui_StyleVar_WindowBorderSize", 0 }, { "ImGui_StyleVar_FrameBorderSize", 0 },
  { "ImGui_StyleVar_GrabMinSize", 12 }, { "ImGui_StyleVar_ScrollbarSize", 13 },
  { "ImGui_StyleVar_WindowPadding", 12, 10 }, { "ImGui_StyleVar_FramePadding", 8, 5 },
  { "ImGui_StyleVar_ItemSpacing", 8, 7 }, { "ImGui_StyleVar_ItemInnerSpacing", 6, 5 },
}

local font                  -- created + attached once (nil if unavailable)
local fontPushed = false
local pushedColors, pushedVars = 0, 0
local fontBaseSize = 14
-- Dear ImGui >= 1.92 (version num 19200) switched to dynamic fonts: ImGui_PushFont then REQUIRES an
-- explicit size — (ctx, font, size) — while older builds take (ctx, font). REAPER's API dispatcher
-- raises the "expected N arguments minimum" error OUTSIDE Lua's pcall, so we cannot try/catch it; we
-- must call the RIGHT arity. Default to the modern size-required form; only narrow to 2-arg when the
-- reported Dear ImGui version is confirmed older.
local pushNeedsSize = true

-- Create + attach the UI font ONCE, and detect the PushFont arity. Call right after CreateContext.
-- If the font can't be created/attached it stays nil and the font push/pop become no-ops.
function M.init(ctx)
  if reaper.ImGui_GetVersion then
    local ok, _vstr, vnum = pcall(reaper.ImGui_GetVersion)   -- (imgui_ver, imgui_ver_num, reaimgui_ver)
    if ok and type(vnum) == "number" then pushNeedsSize = vnum >= 19200 end
  end
  if font or not (reaper.ImGui_CreateFont and reaper.ImGui_Attach) then return end
  local ok, f = pcall(reaper.ImGui_CreateFont, "sans-serif", fontBaseSize)
  if ok and f and pcall(reaper.ImGui_Attach, ctx, f) then font = f end
end

-- Push the whole theme. Call BEFORE ImGui_Begin so WindowBg/rounding/padding apply to the window.
function M.push(ctx)
  if not reaper.ImGui_PushStyleColor then return end
  pushedColors = 0
  for _, c in ipairs(COLORS) do
    local fn = reaper[c[1]]
    if fn then reaper.ImGui_PushStyleColor(ctx, fn(), c[2]); pushedColors = pushedColors + 1 end
  end
  pushedVars = 0
  for _, v in ipairs(VARS) do
    local fn = reaper[v[1]]
    if fn then
      if v[3] then reaper.ImGui_PushStyleVar(ctx, fn(), v[2], v[3])
      else         reaper.ImGui_PushStyleVar(ctx, fn(), v[2]) end
      pushedVars = pushedVars + 1
    end
  end
end

-- Pop everything push() pushed (reverse order). Call AFTER ImGui_End.
function M.pop(ctx)
  if not reaper.ImGui_PopStyleColor then return end
  if pushedVars   > 0 then reaper.ImGui_PopStyleVar(ctx, pushedVars);     pushedVars = 0 end
  if pushedColors > 0 then reaper.ImGui_PopStyleColor(ctx, pushedColors); pushedColors = 0 end
end

-- Font push/pop around the window CONTENT (inside Begin/End). Handles both PushFont signatures
-- (with and without an explicit size) and is a no-op if no font attached.
function M.pushFont(ctx)
  fontPushed = false
  if not (font and reaper.ImGui_PushFont) then return end
  -- Correct arity per the detected ReaImGui generation (see pushNeedsSize). No pcall: the dispatcher's
  -- arg-count error isn't catchable, so calling the right arity is the only safe option.
  if pushNeedsSize then reaper.ImGui_PushFont(ctx, font, fontBaseSize)
  else                  reaper.ImGui_PushFont(ctx, font) end
  fontPushed = true
end
function M.popFont(ctx)
  if fontPushed and reaper.ImGui_PopFont then pcall(reaper.ImGui_PopFont, ctx); fontPushed = false end
end

return M
