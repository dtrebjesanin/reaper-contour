-- @description Contour
-- @version 1.1
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
--   v1.1
--   New shapes: Trapezoid, Rectified sine, Sine², Random (S&H), Drift. Saw & Triangle gain a bipolar
--   Curve; Triangle gains Attack (movable peak). Pump & AD retired (now Saw+Curve / Triangle+Attack).
--   Custom (draw) shape: draw your own LFO in a grid pad (add/move/delete points, Alt-drag to bend a
--   segment), start from a built-in shape, grid density + snap, a stretchable pad, save/recall drawings,
--   and a live ghost preview of how Swing/Steps/Smooth/Phase reshape it.
--   Two Tilt sliders: Tilt L (anchored left) + Tilt R (anchored right).
--   Generate presets: save/recall the whole Generate config (the drawing travels with the preset).
--   Shaping controls grouped into Cycle shape / Across the selection.
--   Reduce: Curve fit (keeps a curve's shape with far fewer points); Reset reliably restores the
--   pre-reduce original across op-switch, time-selection / scope changes, and multiple lanes.
--   Fixes: Launch Transform crash; draw-pad bezier matches REAPER's exact curve; CC per-point shapes
--   render correctly (no stair-stepping); many Phase/Swing/Steps consistency fixes.
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
  local visible, open = reaper.ImGui_Begin(ctx, "Contour", true)
  if visible then
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
