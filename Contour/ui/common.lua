-- ui/common.lua — small UI helpers shared by the operation panels (Generate / Reduce / Transform):
-- the Scope selector + write-span resolution, and the fader default-notch + double-click reset.
-- Pure ReaImGui; no engine logic. (Generate predates this module and still carries its own copies;
-- new panels use these so the behavior stays identical without re-duplicating it further.)
local M = {}

-- Scope: write across the Time selection, or the target's Entire item/envelope.
M.SCOPE_MODES = { "Time selection", "Entire item" }
M.SCOPE_ITEMS = ""
for _, s in ipairs(M.SCOPE_MODES) do M.SCOPE_ITEMS = M.SCOPE_ITEMS .. s .. "\0" end
M.SCOPE_TIMESEL, M.SCOPE_ENTIRE = 0, 1

-- Resolve the write span (project seconds) from g.scope. Entire-item uses the target's fullSpan()
-- (CC item bounds, an automation item's own bounds, or a take envelope's item bounds); TRACK envelopes
-- are time-selection only (they have no item). Automation items AND take envelopes additionally clamp
-- the time-selection span to their item bounds (points outside the item are dropped / never play).
function M.spanFor(tgt, detected, g)
  local kind = tgt and tgt.kind and tgt:kind()
  if g.scope == M.SCOPE_ENTIRE and kind and kind ~= "envelope" and tgt.fullSpan then
    local a, b = tgt:fullSpan()
    if a and b and b > a then return a, b end
  end
  local t0, t1 = detected.t0, detected.t1
  if (kind == "ai" or kind == "takeenv") and tgt.fullSpan then
    local a, b = tgt:fullSpan()
    if a and b then
      if t0 < a then t0 = a end
      if t1 > b then t1 = b end
    end
  end
  return t0, t1
end

-- Fader polish, drawn OVER the just-drawn slider (call IMMEDIATELY after it):
--   * a translucent accent FILL from the default notch to the current value — the fader reads as
--     "deviation from default" (bipolar faders fill from their centre, unipolar from their zero);
--   * the default NOTCH itself, brightening on hover — it's the double-click reset target, so it
--     should invite the gesture.
-- Overdraw only: the stock widget keeps all interaction, so nothing here can break input. The
-- value->x mapping mirrors ImGui's own grab centring (2px grab padding + GrabMinSize), so the fill's
-- end stays tucked under the grab head even where the approximation is a couple of px off (integer
-- sliders with few steps get a wider grab). All APIs guarded for older ReaImGui.
local function drawFaderPolish(ctx, v, vmin, vmax, vdef, hovered, disp)
  if not (reaper.ImGui_GetItemRectMin and reaper.ImGui_GetItemRectMax and reaper.ImGui_GetWindowDrawList
      and reaper.ImGui_DrawList_AddLine and reaper.ImGui_DrawList_AddRectFilled
      and reaper.ImGui_CalcItemWidth) then return end
  if vmax <= vmin then return end
  -- While the fader is in TEXT-INPUT mode (Ctrl+click type-in: item active with the mouse button UP),
  -- draw NOTHING — the cap/fill/readout would sit on top of the input box and hide the caret and the
  -- typed value (worst at far-left values, where the cap covered the left-aligned input text).
  local active = reaper.ImGui_IsItemActive and reaper.ImGui_IsItemActive(ctx)
  local held = reaper.ImGui_IsMouseDown and reaper.ImGui_IsMouseDown(ctx, 0)
  if active and not held then return end
  local x0, y0 = reaper.ImGui_GetItemRectMin(ctx)
  local _, y1 = reaper.ImGui_GetItemRectMax(ctx)
  local frameW = reaper.ImGui_CalcItemWidth(ctx)
  if not frameW or frameW <= 0 then return end
  local dl = reaper.ImGui_GetWindowDrawList(ctx)
  local gs, pad = 14, 2                      -- GrabMinSize + ImGui's internal grab padding
  local usable = frameW - pad * 2 - gs
  if usable <= 0 then return end
  local function xFor(val)
    local t = (val - vmin) / (vmax - vmin)
    if t < 0 then t = 0 elseif t > 1 then t = 1 end
    return x0 + pad + gs * 0.5 + usable * t
  end
  local xv, xd = xFor(tonumber(v) or vmin), xFor(vdef)
  if math.abs(xv - xd) > 0.5 then            -- deviation fill: default -> current value
    local a, b = math.min(xv, xd), math.max(xv, xd)
    reaper.ImGui_DrawList_AddRectFilled(dl, a, y0 + 2, b, y1 - 2, 0x2E8B9B4D, 4)
  end
  -- default DETENT marker: two small inward-pointing wedges at the frame's top/bottom edges — the
  -- classic mixer centre-detent mark. Unlike the old full-height line it never slices through the
  -- value text; teal-bright while hovered (it's the double-click reset target).
  local mcol = hovered and 0x53C9D6E6 or 0x8B97A296
  if reaper.ImGui_DrawList_AddTriangleFilled then
    reaper.ImGui_DrawList_AddTriangleFilled(dl, xd - 3, y0 + 1, xd + 3, y0 + 1, xd, y0 + 5, mcol)
    reaper.ImGui_DrawList_AddTriangleFilled(dl, xd - 3, y1 - 1, xd + 3, y1 - 1, xd, y1 - 5, mcol)
  else
    reaper.ImGui_DrawList_AddLine(dl, xd, y0 + 3, xd, y1 - 3, mcol, 2)
  end
  -- FADER HEAD: a dimensional cap drawn over the (deliberately muted) stock grab — dark surround for
  -- depth, state-aware body, and a lit-left / shaded-right split whose VERTICAL seam at the cap's
  -- centre doubles as the position marker (the job the old white line did, far more quietly). The
  -- surround is 2px wider than the body so the stock grab stays fully hidden even where ImGui widens
  -- it (integer sliders with few steps). Drawn before the value text, which the caller renders on top.
  local body = active and 0x53C9D6FF or (hovered and 0x3FB6C4FF or 0x359DADFF)
  local cx, hw = xv, 7
  local ct, cb = y0 + 2, y1 - 2
  local FLL = reaper.ImGui_DrawFlags_RoundCornersLeft and reaper.ImGui_DrawFlags_RoundCornersLeft() or 0
  local FLR = reaper.ImGui_DrawFlags_RoundCornersRight and reaper.ImGui_DrawFlags_RoundCornersRight() or 0
  reaper.ImGui_DrawList_AddRectFilled(dl, cx - hw - 2, ct - 1, cx + hw + 2, cb + 1, 0x0E1317D9, 5)  -- surround / shadow
  reaper.ImGui_DrawList_AddRectFilled(dl, cx - hw, ct, cx + hw, cb, body, 4)                        -- body
  reaper.ImGui_DrawList_AddRectFilled(dl, cx - hw, ct, cx, cb, 0xFFFFFF22, 4, FLL)                  -- lit left half
  reaper.ImGui_DrawList_AddRectFilled(dl, cx, ct, cx + hw, cb, 0x00000026, 4, FLR)                  -- shaded right half
  -- VALUE readout, re-drawn ON TOP of the cap: the cap is opaque and would otherwise swallow the
  -- widget's own centred text whenever the head sits over it (dead centre for bipolar defaults). Same
  -- string, same centred position as stock, so it overlays the original pixels exactly.
  if disp and reaper.ImGui_CalcTextSize and reaper.ImGui_DrawList_AddText then
    local tw, th = reaper.ImGui_CalcTextSize(ctx, disp)
    if tw then
      reaper.ImGui_DrawList_AddText(dl, x0 + (frameW - tw) / 2, y0 + ((y1 - y0) - (th or 13)) / 2,
        0xE9EEF2FF, disp)
    end
  end
end

-- Draw the default notch AND snap g[key] back to vdef on a double-click ANYWHERE on the fader —
-- frame or label. The frame is the tricky half: clicking it GRABS the slider, and an ACTIVE slider
-- re-writes its value from the mouse position every frame while the button is held — which silently
-- overwrote a naive one-frame reset on the very next frame (that's why only the label used to work).
-- So the reset LATCHES: from the double-click until the mouse button is released, the value is
-- re-pinned to vdef each frame AFTER the slider has run (tickReset is always called right after its
-- slider), so the still-held grab loses the fight instead of winning it. The latch is keyed per
-- (state table, field) and clears itself the moment the button is up. Returns true on any frame it
-- wrote vdef.
local pinned = {}   -- [g] = { [key] = vdef } — latched double-click resets, cleared on mouse release
-- `disp` (optional): the fader's displayed value string, re-drawn above the cap (see drawFaderPolish).
function M.tickReset(ctx, g, key, vmin, vmax, vdef, disp)
  local hovered = reaper.ImGui_IsItemHovered and reaper.ImGui_IsItemHovered(ctx)
  drawFaderPolish(ctx, g[key], vmin, vmax, vdef, hovered, disp)
  local p = pinned[g]
  if p and p[key] ~= nil then
    g[key] = p[key]
    local held = reaper.ImGui_IsMouseDown and reaper.ImGui_IsMouseDown(ctx, 0)
    if not held then p[key] = nil end   -- released: one final pin, then back to normal
    return true
  end
  if hovered and reaper.ImGui_IsMouseDoubleClicked and reaper.ImGui_IsMouseDoubleClicked(ctx, 0) then
    g[key] = vdef
    -- Latch only when the button is still down (a frame click that grabbed the slider). A label
    -- double-click never grabs, so it resets immediately with no latch — exactly as before.
    if reaper.ImGui_IsMouseDown and reaper.ImGui_IsMouseDown(ctx, 0) then
      pinned[g] = pinned[g] or {}
      pinned[g][key] = vdef
    end
    return true
  end
  return false
end

return M
