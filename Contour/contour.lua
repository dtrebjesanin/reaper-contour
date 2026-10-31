-- @description Contour
-- @version 1.2.6
-- @author Danilo Trebjesanin
-- @link https://github.com/dtrebjesanin/reaper-contour
-- @about
--   # Contour
--
--   A unified LFO / point-reduce / transform toolkit for REAPER track envelopes,
--   automation items, and MIDI CC — all in one ReaImGui panel.
--
--   - **Generate** — draw LFO shapes (sine, square, saw, triangle, parametric, ...) onto the target,
--     with a live, non-destructive preview that matches REAPER's native CC LFO.
--   - **Reduce** — thin point density with an adjustable tolerance (live, non-destructive).
--   - **Transform** — a mouse overlay to stretch / scale / compress / warp / tilt / reverse / flip the
--     selected points or time selection directly under the cursor.
--
--   ## Dependencies (install separately via ReaPack — NOT bundled)
--   - **ReaImGui** — the panel UI
--   - **js_ReaScriptAPI** — the Transform overlay
--   - **SWS extension** — optional (sharpens looped-item and FX-envelope edge cases)
--
--   ## Actions installed
--   - **Contour** — the main panel
--   - **Contour Transform** — the mouse-overlay tool (also runnable on its own / hotkey-bindable)
--
--   Licensed under the GNU GPL v3 (or later). See the LICENSE file in the repository.
-- @changelog
--   v1.2.6
--   Transform: Symmetrical, Power/Sine, the Flip mode and Small handles are remembered between
--   launches. Curve still starts linear every time.
--   Transform: Shift + the centre handle moves the points as a block on ONE axis, picked by the
--   direction you start in - up/down moves the values (points stop at the lane edge), left/right
--   moves the times (the whole group stops at the item edge). Release Shift mid-drag to warp again.
--   Transform: a "Small handles" option in the panel draws the handles as small coloured dots, for
--   short selections.
--   Transform: grabbing a handle off its centre no longer makes the points jump.
--   Transform: vertical steps (two points at the same time) keep their direction through repeated
--   drags, and Reverse mirrors them correctly.
--   Transform: holding a handle still no longer rewrites the points on every frame.
-- @provides
--   [main] contour_transform.lua
--   [nomain] core/arrangecoords.lua
--   [nomain] core/context.lua
--   [nomain] core/customshape.lua
--   [nomain] core/genpreset.lua
--   [nomain] core/lfo.lua
--   [nomain] core/midistream.lua
--   [nomain] core/razor.lua
--   [nomain] core/reduce.lua
--   [nomain] core/shapes.lua
--   [nomain] core/starters.lua
--   [nomain] core/target.lua
--   [nomain] core/transform.lua
--   [nomain] ui/common.lua
--   [nomain] ui/drawpad.lua
--   [nomain] ui/generate.lua
--   [nomain] ui/overlay.lua
--   [nomain] ui/reduce.lua
--   [nomain] ui/shell.lua
--   [nomain] ui/theme.lua
--   [nomain] ui/transform_panel.lua

-- contour.lua — entry point for the Contour toolkit (Generate, Reduce, and launching Transform) over
-- track envelopes, automation items, and MIDI CC.
-- Requires the ReaImGui extension. In REAPER: Actions > New action > Load ReaScript... > pick
-- this file > Run. (Install ReaImGui first via ReaPack if prompted.)

if not reaper.ImGui_CreateContext then
  reaper.ShowMessageBox(
    "Contour needs the ReaImGui extension.\n\n" ..
    "Install it via ReaPack:\n" ..
    "Extensions > ReaPack > Browse packages > search \"ReaImGui\" >\n" ..
    "install \"ReaImGui: ReaScript binding for Dear ImGui\".\n\n" ..
    "Then restart REAPER and run Contour again.",
    "Contour — ReaImGui missing", 0)
  return
end

-- Resolve module path relative to this script so require() finds core/ and ui/.
local sep = package.config:sub(1, 1)
local src = debug.getinfo(1, "S").source:match("^@?(.*[/\\])") or ("." .. sep)
package.path = src .. "?.lua;" .. package.path

local shell    = require("ui.shell")
local context  = require("core.context")
local generate = require("ui.generate")
local reduce   = require("ui.reduce")
local theme    = require("ui.theme")

local ctx = reaper.ImGui_CreateContext("Contour")
theme.init(ctx)   -- create + attach the UI font once (guarded; no-op if unavailable)

-- Guard against a dangling live-preview undo block if the script exits mid-drag.
local function cleanupAll()
  if generate.cleanup then pcall(generate.cleanup) end
  if reduce.cleanup   then pcall(reduce.cleanup)   end
end
reaper.atexit(cleanupAll)

local state = {
  op     = "generate",   -- generate | reduce | transform
  target = "envelope",   -- envelope | ai | cc  (active tab; follows detection)
  follow = true,         -- auto-select the detected target's tab
}

local lastDrawErr  -- throttles the panel-error console message to once per distinct message

-- Smooth in-panel scrolling. ImGui's wheel scroll snaps in discrete steps, which reads as choppy; instead
-- we keep a target scroll position and EASE the real scroll toward it each frame, so the wheel glides.
-- What scrolls is the shell's ##contour_body CHILD window (the header and Generate's footer stay put), so
-- the child gets WindowFlags_NoScrollWithMouse (shell does that when opts.noWheel is set) so ImGui stops
-- snapping; we drive the child's ScrollY ourselves. All scroll APIs are guarded — on an older ReaImGui
-- without them, SMOOTH_OK is false and default wheel scrolling is left on.
local SMOOTH_OK = reaper.ImGui_GetScrollY and reaper.ImGui_SetScrollY and reaper.ImGui_GetScrollMaxY
  and reaper.ImGui_GetMouseWheel and reaper.ImGui_WindowFlags_NoScrollWithMouse
local SCROLL_STEP = 120    -- pixels of travel per wheel notch (more = faster traversal)
local SCROLL_EASE = 0.50   -- 0..1 glide toward the target each frame (higher = snappier/less lag; ~32fps cap)
local scrollTarget, scrollApplied   -- target Y, and the Y we set last frame (to detect external scrolls)

-- Called by shell right after ImGui_BeginChild (the body child must be current; runs before its content is
-- laid out so the scroll applies this frame). No-op without the APIs.
local function smoothScroll()
  if not SMOOTH_OK then return end
  local maxY = reaper.ImGui_GetScrollMaxY(ctx)
  local curY = reaper.ImGui_GetScrollY(ctx)
  -- Resync to the live position if something ELSE moved it (scrollbar drag, keyboard, a programmatic
  -- jump) so we glide from where it actually is instead of fighting the user.
  if scrollTarget == nil or (scrollApplied and math.abs(curY - scrollApplied) > 1.0) then scrollTarget = curY end
  -- Wheel -> target, only while the panel (or its content) is hovered. NoPopupHierarchy is the key
  -- bit: ChildWindows alone also counts a COMBO/MENU POPUP spawned by this window as "hovered"
  -- (ImGui treats the popup's emitter as its parent), so scrolling an OPEN dropdown would scroll the
  -- panel and steal the wheel from the list. NoPopupHierarchy excludes popups. If that flag is
  -- missing on an older ReaImGui, fall back to default flags (0), which already exclude popups (an
  -- open popup blocks window hover) — so the dropdown-scroll bug stays fixed either way.
  local hovered = true
  if reaper.ImGui_IsWindowHovered then
    local child = reaper.ImGui_HoveredFlags_ChildWindows and reaper.ImGui_HoveredFlags_ChildWindows()
    local nopop = reaper.ImGui_HoveredFlags_NoPopupHierarchy and reaper.ImGui_HoveredFlags_NoPopupHierarchy()
    local f = (child and nopop) and (child | nopop) or 0
    hovered = reaper.ImGui_IsWindowHovered(ctx, f)
  end
  local wheel = reaper.ImGui_GetMouseWheel(ctx) or 0
  if hovered and wheel ~= 0 then scrollTarget = scrollTarget - wheel * SCROLL_STEP end
  if scrollTarget < 0 then scrollTarget = 0 elseif scrollTarget > maxY then scrollTarget = maxY end
  local newY = curY + (scrollTarget - curY) * SCROLL_EASE
  if math.abs(scrollTarget - newY) < 0.5 then newY = scrollTarget end   -- snap when essentially there
  reaper.ImGui_SetScrollY(ctx, newY)
  scrollApplied = newY
end

-- Handed to shell.draw: it calls scroll() inside the body child, and noWheel tells it to stop the child's own
-- (snapping) wheel scroll because smoothScroll drives it.
local shellOpts = { scroll = smoothScroll, noWheel = SMOOTH_OK and true or false }

local function loop()
  local ok, detected = pcall(context.detect)
  if not ok then
    detected = { target = nil, label = "detect error: " .. tostring(detected),
                 hasTimeSel = false, t0 = 0, t1 = 0 }
  end

  -- Theme is pushed BEFORE Begin so the window background, rounding and padding apply to the window
  -- itself; the font wraps the content inside Begin/End. push() and pop() are balanced once per frame.
  theme.push(ctx)
  -- Open big enough to show all content by default, but NEVER TALLER THAN THE SCREEN: the old fixed
  -- 1050px default overflowed shorter displays (laptops), pushing the bottom controls off-screen. The
  -- monitor work-area height caps the default AND manual resizes; it's re-read every frame, so moving
  -- REAPER to a taller monitor raises the cap. The window stays manually resizable above the light
  -- min-size (which stops a stray resize from collapsing it). All guarded for older ReaImGui.
  local workH
  if reaper.ImGui_GetMainViewport and reaper.ImGui_Viewport_GetWorkSize then
    local vp = reaper.ImGui_GetMainViewport(ctx)
    if vp then
      local _, wh = reaper.ImGui_Viewport_GetWorkSize(vp)
      workH = wh
    end
  end
  local maxH = (workH and workH > 300) and (workH - 40) or 100000
  if reaper.ImGui_SetNextWindowSizeConstraints then
    reaper.ImGui_SetNextWindowSizeConstraints(ctx, 360, 200, 100000, maxH)
  end
  local sizeCond = (reaper.ImGui_Cond_Once and reaper.ImGui_Cond_Once())
    or (reaper.ImGui_Cond_FirstUseEver and reaper.ImGui_Cond_FirstUseEver()) or 0
  -- Default width opens Generate in two columns: 720 minus the window padding (2 x 14) and the body's
  -- scrollbar (12) leaves 680 px of content, above common.TWO_COL_MIN_W (600).
  reaper.ImGui_SetNextWindowSize(ctx, 720, math.min(1050, maxH), sizeCond)
  -- The OUTER window never scrolls: the header and Generate's footer stay pinned, and the shell's body
  -- child (which has its own always-on scrollbar, so the content width is stable across ops) does the
  -- scrolling instead.
  local beginFlags = 0
  if reaper.ImGui_WindowFlags_NoScrollbar then
    beginFlags = beginFlags | reaper.ImGui_WindowFlags_NoScrollbar()
  end
  if reaper.ImGui_WindowFlags_NoScrollWithMouse then
    beginFlags = beginFlags | reaper.ImGui_WindowFlags_NoScrollWithMouse()
  end
  local visible, open = reaper.ImGui_Begin(ctx, "Contour", true, beginFlags)
  if visible then
    theme.pushFont(ctx)
    -- A panel throw must NOT brick the window. pcall keeps the outer Begin/End balanced (End always runs)
    -- and the defer loop alive; the error is surfaced once per distinct message instead of dying silently
    -- or spamming the console every frame. The shell DOES use BeginChild (the scrolling body) and the
    -- Generate panel BeginTable: Dear ImGui requires EndChild after EVERY BeginChild (and EndTable after a
    -- BeginTable that returned true), so each of those runs its contents in its own pcall, ends the
    -- child/table unconditionally and then re-raises (see shell.draw / generate.drawBody). A caught throw
    -- therefore leaves the ImGui stack balanced here, and is reported below.
    local okDraw, drawErr = pcall(shell.draw, ctx, state, detected, shellOpts)
    theme.popFont(ctx)
    reaper.ImGui_End(ctx)
    if not okDraw and drawErr ~= lastDrawErr then
      lastDrawErr = drawErr
      reaper.ShowConsoleMsg("Contour draw error: " .. tostring(drawErr) .. "\n")
    end
  end
  theme.pop(ctx)
  if open then
    reaper.defer(loop)
  else
    -- Window closed: close any open live-preview undo block so it doesn't dangle.
    cleanupAll()
  end
end

reaper.defer(loop)
