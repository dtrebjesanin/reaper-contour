-- dump_env.lua — report the SELECTED envelope's name, scaling mode, SWS value range, and its first
-- few points (time + value + shape), to diagnose Contour's envelope Generate. Select an envelope
-- (ideally after generating with Contour so the points show), run this, paste the console output.

local env = reaper.GetSelectedEnvelope(0)
if not env then reaper.ShowConsoleMsg("No selected envelope.\n") return end

local _, name = reaper.GetEnvelopeName(env, "")
local mode = (reaper.GetEnvelopeScalingMode and reaper.GetEnvelopeScalingMode(env)) or -1
reaper.ShowConsoleMsg(("=== Envelope: %s ===\nGetEnvelopeScalingMode = %s\n"):format(name, tostring(mode)))

-- SWS BR_EnvGetProperties: print EVERY return value in order so we can see the real signature.
if reaper.BR_EnvAlloc and reaper.BR_EnvGetProperties and reaper.BR_EnvFree then
  local ok, parts = pcall(function()
    local br = reaper.BR_EnvAlloc(env, false)
    if not br then return "BR_EnvAlloc returned nil" end
    local r = { reaper.BR_EnvGetProperties(br) }
    reaper.BR_EnvFree(br, false)
    local s = {}
    for i = 1, #r do s[i] = ("  [%d] = %s"):format(i, tostring(r[i])) end
    return table.concat(s, "\n")
  end)
  reaper.ShowConsoleMsg("BR_EnvGetProperties returns:\n" .. tostring(parts) .. "\n")
else
  reaper.ShowConsoleMsg("SWS BR_EnvGetProperties NOT available.\n")
end

-- Scaling round-trip sanity for a few real values.
if reaper.ScaleToEnvelopeMode and reaper.ScaleFromEnvelopeMode then
  for _, v in ipairs({ 0.0, 0.5, 1.0 }) do
    reaper.ShowConsoleMsg(("ScaleToEnvelopeMode(%s,%.2f)=%s  ScaleFromEnvelopeMode(%s,%.2f)=%s\n"):format(
      tostring(mode), v, tostring(reaper.ScaleToEnvelopeMode(mode, v)),
      tostring(mode), v, tostring(reaper.ScaleFromEnvelopeMode(mode, v))))
  end
end

-- Existing points (the first 12) — value is what Contour actually wrote.
local cnt = reaper.CountEnvelopePoints(env)
reaper.ShowConsoleMsg(("Points: %d\n"):format(cnt))
for i = 0, math.min(cnt, 12) - 1 do
  local ok, t, val, shape = reaper.GetEnvelopePoint(env, i)
  if ok then
    reaper.ShowConsoleMsg(("  #%d  t=%.4f  val=%.6f  shape=%d\n"):format(i, t or -1, val or 0, shape or -1))
  end
end
