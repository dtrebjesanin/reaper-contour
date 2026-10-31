-- ui/theme.lua — a coherent Dear ImGui theme for Contour, with selectable colour palettes. Pushed once per
-- frame AROUND the whole window (style colors + style vars), with an optional UI font pushed around the
-- content. It cascades to every widget, so panels need no per-widget styling.
--
-- ROBUSTNESS: every Col_/StyleVar_/font API is GUARDED (only used if it exists in this ReaImGui build)
-- and the pop count always matches what was actually pushed — so the theme degrades gracefully across
-- ReaImGui versions instead of erroring. If styling is entirely unavailable the app still runs (plain).
--
-- Colors are 0xRRGGBBAA. The live palette is M.C: ONE table for the whole run, overwritten IN PLACE when
-- the palette changes. Panels must read theme.C.<key> when they DRAW — a module-level copy never sees a
-- palette change.
local M = {}

-- ---- colour maths (pure) -------------------------------------------------------------------------------
-- Internal colours here are 0xRRGGBB integers; only the finished palette carries the alpha byte.
local function rgb(c) return (c >> 16) & 0xFF, (c >> 8) & 0xFF, c & 0xFF end
local function pack(r, g, b)
  local function ch(v) return math.max(0, math.min(255, math.floor(v + 0.5))) end
  return (ch(r) << 16) | (ch(g) << 8) | ch(b)
end
local function mix(a, b, t)   -- a moved toward b by t (0..1)
  local ar, ag, ab = rgb(a); local br, bg, bb = rgb(b)
  return pack(ar + (br - ar) * t, ag + (bg - ag) * t, ab + (bb - ab) * t)
end
local function lin(v) v = v / 255; return v <= 0.04045 and v / 12.92 or ((v + 0.055) / 1.055) ^ 2.4 end
local function lum(c)   -- WCAG relative luminance
  local r, g, b = rgb(c)
  return 0.2126 * lin(r) + 0.7152 * lin(g) + 0.0722 * lin(b)
end
local function contrast(a, b)
  local la, lb = lum(a), lum(b)
  if la < lb then la, lb = lb, la end
  return (la + 0.05) / (lb + 0.05)
end
local function rgba(c, a) return (c << 8) | a end

-- fg moved toward white or black, by the fewest 5% steps, until it reaches `minC` against EVERY colour in
-- `refs`. `preferDark` only orders the two directions (ties go to the first). If neither extreme gets there
-- the one with the better worst-case contrast wins.
local function ensure(fg, refs, minC, preferDark)
  local function worst(c)
    local w = math.huge
    for _, r in ipairs(refs) do w = math.min(w, contrast(c, r)) end
    return w
  end
  if worst(fg) >= minC then return fg end
  local targets = preferDark and { 0x000000, 0xFFFFFF } or { 0xFFFFFF, 0x000000 }
  local best, bestStep
  for _, tgt in ipairs(targets) do
    for i = 1, 20 do
      local c = mix(fg, tgt, i / 20)
      if worst(c) >= minC then
        if not bestStep or i < bestStep then best, bestStep = c, i end
        break
      end
    end
  end
  if best then return best end
  return worst(0xFFFFFF) >= worst(0x000000) and 0xFFFFFF or 0x000000
end

-- Alpha variant of a 0xRRGGBBAA colour: `col` keeps its RGB, `a` (0..255) replaces the alpha byte.
function M.withAlpha(col, a) return (col & 0xFFFFFF00) | (a & 0xFF) end

-- ---- the palettes ----------------------------------------------------------------------------------------
-- "contour" is an explicit FULL table: the original dark/teal look, value for value (accent = the teal).
local CONTOUR = {
  text      = 0xE3E8ECFF, textDim   = 0x8B97A2FF,
  winBg     = 0x1B1E23FF, childBg   = 0x20242AFF, popupBg = 0x22262CFF,
  frame     = 0x262D34FF, frameH    = 0x303842FF, frameA  = 0x3A424DFF,
  accent    = 0x2E8B9BFF, accentH   = 0x3FB6C4FF, accentA = 0x53C9D6FF, accentDim = 0x2A6A75FF,
  tab       = 0x262B31FF, tabH      = 0x3FB6C4FF, tabSel  = 0x2E8B9BFF,
  sep       = 0x323A44FF,
  scrollBg  = 0x1B1E23FF, scrollGrab= 0x3C444EFF, scrollGrabH = 0x4A535EFF,
  header    = 0x2E8B9B33, headerH   = 0x2E8B9B55, headerA = 0x2E8B9B77,
  button    = 0x262D34FF, buttonH   = 0x303842FF, buttonA = 0x2E8B9BFF,
  onAccent  = 0xF3FBFCFF,   -- text on accent-filled controls
  check     = 0x3FB6C4FF, sliderGrab = 0x3A424DFF, sliderGrabA = 0x4A535EFF,
  -- Panel colours that used to be hardcoded in the panels (shell, generate, reduce, transform_panel,
  -- drawpad, common, overlay).
  mute      = 0x3A3A3AFF, muteH     = 0x4A4A4AFF,                  -- op switcher, unselected
  sectionHdr= 0x3FB6C4FF,                                          -- section header text
  hint      = 0xC0A040FF, ok        = 0x60C080FF, err = 0xE05050FF, warn = 0xE0A060FF,
  grip      = 0x6A737BFF,                                          -- custom-pad resize grip
  padBg     = 0x10151AFF, padGrid   = 0x3A434BFF, padAxis = 0x55636EFF,
  padCurve  = 0x48C6D4FF, padPoint  = 0x9FE9F1FF,
  faderFill = 0x2E8B9B4D, faderCap  = 0x359DADFF, faderShadow = 0x0E1317D9, faderText = 0xE9EEF2FF,
  faderCapH = 0x3FB6C4FF, faderCapA = 0x53C9D6FF,                  -- fader cap, hovered / pressed
  hudBg     = 0x12242BF7,                                          -- Transform overlay HUD panel
}

-- Expand a palette SPEC into the full key set. PURE (no reaper.* calls), so it can be unit-tested.
-- spec, all 0xRRGGBB: bg, text, accent (required); field, dim, onAccent, hdr, grab (optional).
--   field = input / button surface        hdr  = section-header text
--   dim   = secondary text                grab = fader cap, slider grab and check mark
-- Contrast floors (WCAG): text vs bg and vs field >= 4.5, dim vs bg >= 4.5, onAccent vs accent >= 4.5. A
-- colour that falls short moves toward white (toward black on a light background).
function M.derive(spec)
  local bg, accent = spec.bg, spec.accent
  local light = lum(bg) > 0.5
  local field = spec.field or mix(bg, spec.text, 0.08)
  local text = ensure(spec.text, { bg, field }, 4.5, light)
  local dim = ensure(spec.dim or mix(text, bg, 0.45), { bg }, 4.5, light)
  local onAccent = spec.onAccent
    or (contrast(0x101010, accent) >= contrast(0xF8F8F8, accent) and 0x101010 or 0xF8F8F8)
  onAccent = ensure(onAccent, { accent }, 4.5, lum(accent) > 0.3)
  local hdr = ensure(spec.hdr or accent, { bg }, 3.0, light)
  local grab = spec.grab or accent

  local toward = light and 0x000000 or 0xFFFFFF   -- the direction "lighter" means against this background
  local accentH = mix(accent, toward, light and 0.20 or 0.25)
  local accentA = mix(accent, toward, light and 0.35 or 0.45)
  local frameH, frameA = mix(field, text, 0.08), mix(field, text, 0.16)
  local padBg = light and field or mix(bg, 0x000000, 0.35)
  -- Status colours keep their hue in every palette; on a light background they switch to a darker variant.
  local function status(base)
    return ensure(light and mix(base, 0x000000, 0.25) or base, { bg }, 3.0, light)
  end

  return {
    text = rgba(text, 0xFF), textDim = rgba(dim, 0xFF),
    winBg = rgba(bg, 0xFF), childBg = rgba(mix(bg, text, 0.03), 0xFF), popupBg = rgba(mix(bg, text, 0.05), 0xFF),
    frame = rgba(field, 0xFF), frameH = rgba(frameH, 0xFF), frameA = rgba(frameA, 0xFF),
    accent = rgba(accent, 0xFF), accentH = rgba(accentH, 0xFF), accentA = rgba(accentA, 0xFF),
    accentDim = rgba(mix(accent, bg, 0.3), 0xFF),
    -- the selected tab is labelled with Col_Text, so it has to stay readable under it
    tab = rgba(mix(field, bg, 0.3), 0xFF), tabH = rgba(accentH, 0xFF),
    tabSel = rgba(ensure(accent, { text }, 3.0, light), 0xFF),
    sep = rgba(mix(bg, text, 0.15), 0xFF),
    scrollBg = rgba(bg, 0xFF), scrollGrab = rgba(mix(bg, text, 0.2), 0xFF), scrollGrabH = rgba(mix(bg, text, 0.3), 0xFF),
    header = rgba(accent, 0x33), headerH = rgba(accent, 0x55), headerA = rgba(accent, 0x77),
    button = rgba(field, 0xFF), buttonH = rgba(frameH, 0xFF), buttonA = rgba(accent, 0xFF),
    onAccent = rgba(onAccent, 0xFF),
    check = rgba(grab, 0xFF), sliderGrab = rgba(grab, 0xFF), sliderGrabA = rgba(mix(grab, toward, 0.25), 0xFF),
    mute = rgba(frameH, 0xFF), muteH = rgba(frameA, 0xFF),
    sectionHdr = rgba(hdr, 0xFF),
    hint = rgba(status(0xC0A040), 0xFF), ok = rgba(status(0x60C080), 0xFF),
    err = rgba(status(0xE05050), 0xFF), warn = rgba(status(0xE0A060), 0xFF),
    grip = rgba(mix(bg, text, 0.4), 0xFF),
    padBg = rgba(padBg, 0xFF), padGrid = rgba(mix(padBg, text, 0.18), 0xFF), padAxis = rgba(mix(padBg, text, 0.32), 0xFF),
    padCurve = rgba(ensure(grab, { padBg }, 3.0, light), 0xFF), padPoint = rgba(mix(grab, toward, 0.45), 0xFF),
    faderFill = rgba(accent, 0x4D), faderCap = rgba(grab, 0xFF),
    faderShadow = rgba(mix(bg, 0x000000, 0.45), 0xD9), faderText = rgba(text, 0xFF),
    -- hover / press shades come from the CAP colour, not the accent: where grab differs from accent
    -- (Klimt) accent-based shades would make the cap go darker on hover
    faderCapH = rgba(mix(grab, toward, 0.25), 0xFF), faderCapA = rgba(mix(grab, toward, 0.45), 0xFF),
    hudBg = rgba(light and mix(bg, accent, 0.08) or mix(mix(bg, 0x000000, 0.25), accent, 0.10), 0xF7),
  }
end

-- Auto: map the REAPER theme onto a spec. `read(key)` returns a theme colour as 0xRRGGBB, or nil when the
-- key is missing; the first key that exists wins. Returns nil when bg, text or accent cannot be found (the
-- caller then uses the Contour table). Pure, so it can be fed a fake theme.
function M.autoSpec(read)
  local function first(keys, usable)
    for _, k in ipairs(keys) do
      local v = read(k)
      if v and (not usable or usable(v)) then return v end
    end
  end
  local bg     = first({ "col_main_bg2", "col_main_bg" })
  local field  = first({ "col_main_editbk", "genlist_bg" })
  local text   = first({ "genlist_fg", "col_main_text2", "col_main_text" })
  local accent = bg and first({ "col_toolbar_text_on", "genlist_selbg" }, function(v) return contrast(v, bg) >= 2 end)
  if not (bg and text and accent) then return nil end
  return { bg = bg, field = field, text = text, accent = accent, hdr = accent, grab = accent }
end

-- Cassatt, Kandinsky, Tam, Paquin and Klimt derive from MetBrewer by Blake Robert Mills
-- (https://github.com/BlakeRMills/MetBrewer, CC0).
-- Menu order. The fixed palettes are small specs for derive(); "auto" is resolved from the REAPER theme.
M.PALETTES = {
  { id = "auto",       name = "Auto (REAPER theme)" },
  { id = "contour",    name = "Contour",     full = CONTOUR },
  { id = "danitreble", name = "Dani Treble", spec = { bg = 0x121415, field = 0x1E2224, text = 0xE6E1D8, dim = 0x8A948D,
      accent = 0x4FA9CF, onAccent = 0x0E1A20, hdr = 0x4FA9CF, grab = 0x4FA9CF } },
  { id = "cassatt",    name = "Cassatt",     spec = { bg = 0x0F1A11, field = 0x1C2E1E, text = 0xECEFE4, dim = 0x9AAA96,
      accent = 0x7FA074, onAccent = 0x0E2810, hdr = 0xC1D1AA, grab = 0x7FA074 } },
  { id = "kandinsky",  name = "Kandinsky",   spec = { bg = 0x1C1C1E, field = 0x2C2B2F, text = 0xE8E6E3, dim = 0x989CA8,
      accent = 0xCE9642, onAccent = 0x2A1C08, hdr = 0xCE9642, grab = 0xCE9642 } },
  { id = "tam",        name = "Tam",         spec = { bg = 0x170F1F, field = 0x261A31, text = 0xF2E8E0, dim = 0xA898A8,
      accent = 0xEF8737, onAccent = 0x2A1405, hdr = 0xFFD353, grab = 0xEF8737 } },
  { id = "paquin",     name = "Paquin",      spec = { bg = 0x1A0F0E, field = 0x2C1918, text = 0xF4E9E2, dim = 0xAE9A95,
      accent = 0xF05B43, onAccent = 0x2A0806, hdr = 0xF7DEA3, grab = 0xF05B43 } },
  { id = "klimt",      name = "Klimt",       spec = { bg = 0x15101A, field = 0x251B2C, text = 0xF1E8F0, dim = 0xA897A8,
      accent = 0x924099, onAccent = 0xFFFFFF, hdr = 0xDF9ED4, grab = 0xDF9ED4 } },
}
local byId = {}
for _, p in ipairs(M.PALETTES) do byId[p.id] = p end

-- ---- selection, persistence, refresh -------------------------------------------------------------------
-- The live palette. ONE table object for the whole run (see the header): apply() overwrites its fields.
local C = {}
local currentId = "auto"
local autoSig = ""      -- what the applied Auto palette was built from, so a REAPER theme change is noticed
local lastCheck         -- reaper.time_precise() of the last ExtState / theme re-read
local derived = {}      -- [id] = the derived full table of a fixed palette (computed once)

local function now()
  local t = reaper and reaper.time_precise and reaper.time_precise()
  return type(t) == "number" and t or nil
end

-- One REAPER theme colour as 0xRRGGBB, or nil. GetThemeColor reports failure as -1; some values carry flag
-- bits in the high byte, so the native colour is masked before ColorFromNative converts it.
local function readThemeColor(key)
  if not (reaper and reaper.GetThemeColor and reaper.ColorFromNative) then return nil end
  local ok, col = pcall(reaper.GetThemeColor, key, 0)
  if not ok or type(col) ~= "number" or col == -1 then return nil end
  col = math.tointeger(col)
  if not col then return nil end
  local ok2, r, g, b = pcall(reaper.ColorFromNative, col & 0xFFFFFF)
  if not (ok2 and type(r) == "number" and type(g) == "number" and type(b) == "number") then return nil end
  return pack(r, g, b)
end

local function sigOf(spec)
  if not spec then return "none" end
  return ("%06X:%s:%06X:%06X"):format(spec.bg, spec.field and ("%06X"):format(spec.field) or "-", spec.text, spec.accent)
end

local function readId()
  local s = reaper and reaper.GetExtState and reaper.GetExtState("Contour", "palette")
  return byId[s] and s or "auto"
end

local function apply(id)
  local full
  autoSig = ""
  if id == "contour" then
    full = CONTOUR
  elseif id == "auto" then
    local spec = M.autoSpec(readThemeColor)
    autoSig = sigOf(spec)
    full = spec and M.derive(spec) or CONTOUR
  else
    derived[id] = derived[id] or M.derive(byId[id].spec)
    full = derived[id]
  end
  currentId = id
  lastCheck = now()
  for k, v in pairs(full) do C[k] = v end   -- IN PLACE: panels hold theme.C, never a copy of it
end

-- Re-read the saved palette id (so the Transform overlay, its own Lua state, follows a change made in the
-- panel) and, for Auto, the REAPER theme. At most once a second; re-applies only when something changed.
local function refresh()
  local t = now()
  if t and lastCheck and t >= lastCheck and t - lastCheck < 1 then return end
  lastCheck = t
  local id = readId()
  if id ~= currentId then apply(id); return end
  if id == "auto" and sigOf(M.autoSpec(readThemeColor)) ~= autoSig then apply(id) end
end

function M.paletteId() return currentId end

-- Save the choice (ExtState Contour/palette, persisted) and apply it at once.
function M.setPalette(id)
  if not byId[id] then id = "auto" end
  if reaper and reaper.SetExtState then reaper.SetExtState("Contour", "palette", id, true) end
  apply(id)
end

-- { Col_ enum fn name, palette KEY (or a literal color) }. The key is looked up in C on every push, so a
-- palette change shows up on the next frame. Both the legacy (TabActive/TabUnfocused) and the newer
-- (TabSelected/TabDimmed) tab-color names are listed and guarded — on any given build only the
-- existing ones are pushed, so there's no double-push.
local COLORS = {
  { "ImGui_Col_Text", "text" }, { "ImGui_Col_TextDisabled", "textDim" },
  { "ImGui_Col_WindowBg", "winBg" }, { "ImGui_Col_ChildBg", "childBg" }, { "ImGui_Col_PopupBg", "popupBg" },
  { "ImGui_Col_Border", 0x00000000 },
  { "ImGui_Col_FrameBg", "frame" }, { "ImGui_Col_FrameBgHovered", "frameH" }, { "ImGui_Col_FrameBgActive", "frameA" },
  { "ImGui_Col_TitleBg", "childBg" }, { "ImGui_Col_TitleBgActive", "frame" }, { "ImGui_Col_TitleBgCollapsed", "childBg" },
  { "ImGui_Col_Button", "button" }, { "ImGui_Col_ButtonHovered", "buttonH" }, { "ImGui_Col_ButtonActive", "buttonA" },
  -- Muted gray grab: the real faders draw their own dimensional cap over it (ui/common drawFaderPolish),
  -- so the stock grab must not fight it; the few utility sliders without the cap (Grid X/Y) still read.
  { "ImGui_Col_SliderGrab", "sliderGrab" }, { "ImGui_Col_SliderGrabActive", "sliderGrabA" },
  { "ImGui_Col_CheckMark", "check" },
  { "ImGui_Col_Header", "header" }, { "ImGui_Col_HeaderHovered", "headerH" }, { "ImGui_Col_HeaderActive", "headerA" },
  { "ImGui_Col_Separator", "sep" }, { "ImGui_Col_SeparatorHovered", "accent" }, { "ImGui_Col_SeparatorActive", "accentH" },
  { "ImGui_Col_Tab", "tab" }, { "ImGui_Col_TabHovered", "tabH" }, { "ImGui_Col_TabActive", "tabSel" },
  { "ImGui_Col_TabUnfocused", "tab" }, { "ImGui_Col_TabUnfocusedActive", "accentDim" },
  { "ImGui_Col_TabSelected", "tabSel" }, { "ImGui_Col_TabDimmed", "tab" }, { "ImGui_Col_TabDimmedSelected", "accentDim" },
  { "ImGui_Col_ScrollbarBg", "scrollBg" }, { "ImGui_Col_ScrollbarGrab", "scrollGrab" },
  { "ImGui_Col_ScrollbarGrabHovered", "scrollGrabH" }, { "ImGui_Col_ScrollbarGrabActive", "accent" },
}

-- { StyleVar_ enum fn name, val1, val2_or_nil }. Two-component vars (padding/spacing) pass both.
local VARS = {
  { "ImGui_StyleVar_WindowRounding", 8 }, { "ImGui_StyleVar_ChildRounding", 6 },
  { "ImGui_StyleVar_PopupRounding", 6 }, { "ImGui_StyleVar_FrameRounding", 6 },
  { "ImGui_StyleVar_GrabRounding", 6 }, { "ImGui_StyleVar_TabRounding", 5 },
  { "ImGui_StyleVar_ScrollbarRounding", 6 },
  { "ImGui_StyleVar_WindowBorderSize", 0 }, { "ImGui_StyleVar_FrameBorderSize", 0 },
  { "ImGui_StyleVar_GrabMinSize", 14 }, { "ImGui_StyleVar_ScrollbarSize", 12 },
  { "ImGui_StyleVar_WindowPadding", 14, 12 }, { "ImGui_StyleVar_FramePadding", 9, 6 },
  { "ImGui_StyleVar_ItemSpacing", 8, 8 }, { "ImGui_StyleVar_ItemInnerSpacing", 6, 5 },
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
-- colorsOnly=true pushes the PALETTE without the spacing/rounding vars — for windows with their own
-- fixed metrics (the Transform overlay HUD) that should match Contour's colors, not its geometry.
function M.push(ctx, colorsOnly)
  refresh()   -- first, so this frame already draws in the current palette
  if not reaper.ImGui_PushStyleColor then return end
  pushedColors = 0
  for _, c in ipairs(COLORS) do
    local fn = reaper[c[1]]
    if fn then
      local col = type(c[2]) == "string" and C[c[2]] or c[2]
      reaper.ImGui_PushStyleColor(ctx, fn(), col); pushedColors = pushedColors + 1
    end
  end
  pushedVars = 0
  if colorsOnly then return end
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

-- The live palette, exposed READ-ONLY so panels can color one-off text (dim labels, values) consistently.
-- Don't mutate it — pick a palette with M.setPalette, or edit CONTOUR / the specs above. Always read
-- theme.C.<key> at draw time (see the header).
M.C = C

-- Section header: a small breather, the label in the accent tint, and a hairline running from the
-- label to the right edge of the space it sits in (the window's content region, or one table column).
-- Pure DrawList + Text — no stateful widgets (no BeginChild/tree), so the panels' balanced-ImGui-stack
-- safety invariant is untouched. Guarded: degrades to plain text.
function M.sectionHeader(ctx, label)
  if reaper.ImGui_Dummy then reaper.ImGui_Dummy(ctx, 1, 3) end
  -- The line must end where the AVAILABLE space ends, not at the window edge: inside a table column the
  -- window edge would run the hairline into the next column. Read both BEFORE the text moves the cursor.
  local x0, availW
  if reaper.ImGui_GetCursorScreenPos and reaper.ImGui_GetContentRegionAvail then
    x0 = reaper.ImGui_GetCursorScreenPos(ctx)
    availW = reaper.ImGui_GetContentRegionAvail(ctx)
  end
  if reaper.ImGui_TextColored then reaper.ImGui_TextColored(ctx, C.sectionHdr, label)
  else reaper.ImGui_Text(ctx, label) end
  if reaper.ImGui_GetItemRectMin and reaper.ImGui_GetItemRectMax and reaper.ImGui_GetWindowDrawList
     and reaper.ImGui_DrawList_AddLine then
    local _, y0 = reaper.ImGui_GetItemRectMin(ctx)
    local x1, y1 = reaper.ImGui_GetItemRectMax(ctx)
    local xEnd
    if type(x0) == "number" and type(availW) == "number" then
      xEnd = x0 + availW
    elseif reaper.ImGui_GetWindowPos and reaper.ImGui_GetWindowSize then
      -- Fallback (no cursor/avail APIs): the window's right edge, stopping short of the scrollbar.
      local wx = reaper.ImGui_GetWindowPos(ctx)
      local ww = reaper.ImGui_GetWindowSize(ctx)
      if wx and ww then xEnd = wx + ww - 26 end
    end
    if x1 and y0 and y1 and xEnd then
      local cy = math.floor((y0 + y1) / 2) + 1
      reaper.ImGui_DrawList_AddLine(reaper.ImGui_GetWindowDrawList(ctx),
        x1 + 8, cy, xEnd, cy, M.withAlpha(C.sep, 0x80), 1)   -- sep tint at half alpha
    end
  end
end

-- Primary-action button (accent-filled): THE action of a panel should read at a glance, so Generate /
-- Reduce / Launch use this while secondary buttons (Reset, presets) stay muted. Pops exactly what it
-- pushed; degrades to a plain button when styling is unavailable. Returns Button's clicked result.
function M.accentButton(ctx, label)
  local pushed = 0
  if reaper.ImGui_PushStyleColor then
    local function pc(fn, col)
      if reaper[fn] then reaper.ImGui_PushStyleColor(ctx, reaper[fn](), col); pushed = pushed + 1 end
    end
    pc("ImGui_Col_Button", C.accent); pc("ImGui_Col_ButtonHovered", C.accentH)
    pc("ImGui_Col_ButtonActive", C.accentA); pc("ImGui_Col_Text", C.onAccent)
  end
  local clicked = reaper.ImGui_Button(ctx, label)
  if pushed > 0 then reaper.ImGui_PopStyleColor(ctx, pushed) end
  return clicked
end

apply(readId())   -- once at load, so the very first frame is already in the saved palette

return M
