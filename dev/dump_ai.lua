-- dump_ai.lua — report the SELECTED automation item's properties and its first few envelope points
-- (time + value + shape), to diagnose Contour's Automation Item Generate. Select an envelope, then
-- select ONE automation item on it (click it so it's highlighted), run this, paste the console output.
-- Useful when an AI is looped, stretched (play rate != 1), has a start offset, is pooled, or sits on a
-- fader-scaled (Volume) envelope — the cases beyond the default 1:1 project-time mapping.

local env = reaper.GetSelectedEnvelope(0)
if not env then reaper.ShowConsoleMsg("No selected envelope. Select the envelope (and an automation item on it).\n") return end

local _, ename = reaper.GetEnvelopeName(env, "")
local mode = (reaper.GetEnvelopeScalingMode and reaper.GetEnvelopeScalingMode(env)) or -1
reaper.ShowConsoleMsg(("=== Envelope: %s ===\nScalingMode = %s\n"):format(ename, tostring(mode)))

-- Find the selected automation item (matches Contour's context.lua detection: D_UISEL > 0).
local aiCount = reaper.CountAutomationItems(env)
reaper.ShowConsoleMsg(("AutomationItems on envelope: %d\n"):format(aiCount))
local sel = nil
for i = 0, aiCount - 1 do
  if reaper.GetSetAutomationItemInfo(env, i, "D_UISEL", 0, false) > 0 then sel = i; break end
end
if not sel then reaper.ShowConsoleMsg("No automation item is selected (click one so it highlights).\n") return end

local function ai(key) return reaper.GetSetAutomationItemInfo(env, sel, key, 0, false) end
local pos, len = ai("D_POSITION"), ai("D_LENGTH")
reaper.ShowConsoleMsg(("=== Automation Item #%d ===\n"):format(sel))
for _, k in ipairs({ "D_POOL_ID", "D_POSITION", "D_LENGTH", "D_STARTOFFS", "D_PLAYRATE",
                     "D_BASELINE", "D_AMPLITUDE", "D_LOOPSRC", "D_POOL_QNLEN" }) do
  reaper.ShowConsoleMsg(("  %-13s = %s\n"):format(k, tostring(ai(k))))
end
reaper.ShowConsoleMsg(("  => project bounds [%.4f, %.4f]\n"):format(pos, pos + len))

-- Points inside the item. The time should read as ABSOLUTE PROJECT seconds (i.e. within the bounds
-- printed above). If instead the first point reads near 0 (relative to item start) the time domain
-- differs from what Contour assumes — that's the thing to flag.
local cnt = reaper.CountEnvelopePointsEx(env, sel)
reaper.ShowConsoleMsg(("Points in item: %d\n"):format(cnt))
for i = 0, math.min(cnt, 16) - 1 do
  local ok, t, val, shape, tension = reaper.GetEnvelopePointEx(env, sel, i)
  if ok then
    reaper.ShowConsoleMsg(("  #%d  t=%.4f  val=%.6f  shape=%d  tension=%.3f  (in-bounds=%s)\n"):format(
      i, t or -1, val or 0, shape or -1, tension or 0, tostring(t and t >= pos - 1e-6 and t <= pos + len + 1e-6)))
  end
end
