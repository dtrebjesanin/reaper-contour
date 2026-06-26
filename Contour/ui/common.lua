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
-- (CC item bounds, or an automation item's own bounds); envelopes are time-selection only (they have
-- no item). Automation items additionally clamp the time-selection span to their bounds, since REAPER
-- drops points outside the item. Identical to Generate's spanFor.
function M.spanFor(tgt, detected, g)
  local kind = tgt and tgt.kind and tgt:kind()
  if g.scope == M.SCOPE_ENTIRE and kind and kind ~= "envelope" and tgt.fullSpan then
    local a, b = tgt:fullSpan()
    if a and b and b > a then return a, b end
  end
  local t0, t1 = detected.t0, detected.t1
  if kind == "ai" and tgt.fullSpan then
    local a, b = tgt:fullSpan()
    if a and b then
      if t0 < a then t0 = a end
      if t1 > b then t1 = b end
    end
  end
  return t0, t1
end

-- Draw a small "notch" on the just-drawn slider at its default value (a fader detent). Call
-- IMMEDIATELY after the slider. Guarded for older ReaImGui without the DrawList APIs.
function M.drawDefaultTick(ctx, vmin, vmax, vdef)
  if not (reaper.ImGui_GetItemRectMin and reaper.ImGui_GetItemRectMax and reaper.ImGui_GetWindowDrawList
      and reaper.ImGui_DrawList_AddLine and reaper.ImGui_CalcItemWidth) then return end
  if vmax <= vmin then return end
  local x0, y0 = reaper.ImGui_GetItemRectMin(ctx)
  local _, y1 = reaper.ImGui_GetItemRectMax(ctx)
  local frameW = reaper.ImGui_CalcItemWidth(ctx)
  if not frameW or frameW <= 0 then return end
  local inset = math.min(7, frameW * 0.04)
  local frac = (vdef - vmin) / (vmax - vmin)
  if frac < 0 then frac = 0 elseif frac > 1 then frac = 1 end
  local x = x0 + inset + frac * (frameW - 2 * inset)
  local dl = reaper.ImGui_GetWindowDrawList(ctx)
  reaper.ImGui_DrawList_AddLine(dl, x, y0 + 2, x, y1 - 2, 0xFFFFFFA0, 1.0)
end

-- Draw the default notch AND snap g[key] back to vdef on a LABEL double-click (the slider head
-- consumes its own clicks, so double-click works on the label). Returns true if a reset happened.
function M.tickReset(ctx, g, key, vmin, vmax, vdef)
  M.drawDefaultTick(ctx, vmin, vmax, vdef)
  if reaper.ImGui_IsItemHovered and reaper.ImGui_IsMouseDoubleClicked
     and reaper.ImGui_IsItemHovered(ctx) and reaper.ImGui_IsMouseDoubleClicked(ctx, 0) then
    g[key] = vdef
    return true
  end
  return false
end

return M
