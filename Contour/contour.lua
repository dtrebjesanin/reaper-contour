-- @description Contour
-- @version 1.1.2
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
--   - **SWS extension** — the Transform overlay
--
--   ## Actions installed
--   - **Contour** — the main panel
--   - **Contour Transform** — the mouse-overlay tool (also runnable on its own / hotkey-bindable)
--
--   Licensed under the GNU GPL v3 (or later). See the LICENSE file in the repository.
-- @changelog
--   v1.1.2
--   Re-roll now works for the Drift shape too (previously Random / S&H only), so its random
--   pattern can be reshuffled instead of being fixed for the session.
-- @provides
--   [main] contour_transform.lua
--   [nomain] core/arrangecoords.lua
--   [nomain] core/context.lua
--   [nomain] core/customshape.lua
--   [nomain] core/genpreset.lua
--   [nomain] core/lfo.lua
--   [nomain] core/midistream.lua
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
-- The window gets WindowFlags_NoScrollWithMouse so ImGui stops snapping; we drive ScrollY ourselves. All
-- scroll APIs are guarded — on an older ReaImGui without them, SMOOTH_OK is false and default wheel
-- scrolling is left on.
local SMOOTH_OK = reaper.ImGui_GetScrollY and reaper.ImGui_SetScrollY and reaper.ImGui_GetScrollMaxY
  and reaper.ImGui_GetMouseWheel and reaper.ImGui_WindowFlags_NoScrollWithMouse
local SCROLL_STEP = 120    -- pixels of travel per wheel notch (more = faster traversal)
local SCROLL_EASE = 0.50   -- 0..1 glide toward the target each frame (higher = snappier/less lag; ~32fps cap)
local scrollTarget, scrollApplied   -- target Y, and the Y we set last frame (to detect external scrolls)

-- Call right after ImGui_Begin (window must be current; runs before content is laid out so the scroll
-- applies this frame). No-op without the APIs.
local function smoothScroll()
  if not SMOOTH_OK then return end
  local maxY = reaper.ImGui_GetScrollMaxY(ctx)
  local curY = reaper.ImGui_GetScrollY(ctx)
  -- Resync to the live position if something ELSE moved it (scrollbar drag, keyboard, a programmatic
  -- jump) so we glide from where it actually is instead of fighting the user.
  if scrollTarget == nil or (scrollApplied and math.abs(curY - scrollApplied) > 1.0) then scrollTarget = curY end
  -- Wheel -> target, only while the panel (or its content) is hovered.
  local hovered = true
  if reaper.ImGui_IsWindowHovered then
    local f = reaper.ImGui_HoveredFlags_ChildWindows and reaper.ImGui_HoveredFlags_ChildWindows() or 0
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

local function loop()
  local ok, detected = pcall(context.detect)
  if not ok then
    detected = { target = nil, label = "detect error: " .. tostring(detected),
                 hasTimeSel = false, t0 = 0, t1 = 0 }
  end

  -- Theme is pushed BEFORE Begin so the window background, rounding and padding apply to the window
  -- itself; the font wraps the content inside Begin/End. push() and pop() are balanced once per frame.
  theme.push(ctx)
  -- Open big enough to show all content by default, but keep the window MANUALLY RESIZABLE. Cond_Once
  -- applies the size on the first frame of each launch (overriding any previously-saved smaller size
  -- that would otherwise clip the taller themed layout), then the user can drag to any size for the
  -- rest of the session. A light min-size stops a stray resize from collapsing it. All guarded.
  if reaper.ImGui_SetNextWindowSizeConstraints then
    reaper.ImGui_SetNextWindowSizeConstraints(ctx, 360, 200, 100000, 100000)  -- min size; no max
  end
  local sizeCond = (reaper.ImGui_Cond_Once and reaper.ImGui_Cond_Once())
    or (reaper.ImGui_Cond_FirstUseEver and reaper.ImGui_Cond_FirstUseEver()) or 0
  reaper.ImGui_SetNextWindowSize(ctx, 460, 1050, sizeCond)
  local beginFlags = SMOOTH_OK and reaper.ImGui_WindowFlags_NoScrollWithMouse() or 0
  local visible, open = reaper.ImGui_Begin(ctx, "Contour", true, beginFlags)
  if visible then
    smoothScroll()   -- ease the wheel scroll (set before content is laid out this frame)
    theme.pushFont(ctx)
    -- A panel throw must NOT brick the window. pcall keeps the outer Begin/End balanced (End always runs)
    -- and the defer loop alive; the error is surfaced once per distinct message instead of dying silently
    -- or spamming the console every frame. (The panels use no BeginChild/Table/TreeNode, so a caught throw
    -- can't leave the ImGui stack unbalanced here.)
    local okDraw, drawErr = pcall(shell.draw, ctx, state, detected)
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
