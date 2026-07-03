-- dev/dump_takeenv.lua — diagnostic for the take-envelope Transform box mapping.
-- USAGE: click the PROBLEMATIC take envelope so it's selected, then run this script once
-- (Actions > Load ReaScript). Paste the [TE-DIAG] console output.
local env = reaper.GetSelectedEnvelope(0)
if not env then reaper.ShowConsoleMsg("[TE-DIAG] no envelope selected\n") return end

local _, name = reaper.GetEnvelopeName(env, "")
local take = reaper.Envelope_GetParentTake and reaper.Envelope_GetParentTake(env)
local mode = reaper.GetEnvelopeScalingMode and reaper.GetEnvelopeScalingMode(env)

local okV, volr = reaper.get_config_var_string("volenvrange")
local okP, pitr = reaper.get_config_var_string("pitchenvrange")

local cnt = reaper.CountEnvelopePoints(env) or 0
local mn, mx = math.huge, -math.huge
for i = 0, cnt - 1 do
  local ok, _, v = reaper.GetEnvelopePoint(env, i)
  if ok then
    if v < mn then mn = v end
    if v > mx then mx = v end
  end
end

local eyU = reaper.GetEnvelopeInfo_Value(env, "I_TCPY_USED")
local ehU = reaper.GetEnvelopeInfo_Value(env, "I_TCPH_USED")
local ey  = reaper.GetEnvelopeInfo_Value(env, "I_TCPY")
local eh  = reaper.GetEnvelopeInfo_Value(env, "I_TCPH")

local item = take and reaper.GetMediaItemTake_Item(take)
local iy = item and reaper.GetMediaItemInfo_Value(item, "I_LASTY")
local ih = item and reaper.GetMediaItemInfo_Value(item, "I_LASTH")
local track = item and reaper.GetMediaItem_Track(item)
local ty = track and reaper.GetMediaTrackInfo_Value(track, "I_TCPY")
local th = track and reaper.GetMediaTrackInfo_Value(track, "I_TCPH")

local unscaled = ""
if mode and mode ~= 0 and reaper.ScaleFromEnvelopeMode and cnt > 0 then
  unscaled = ("  linear(min)=%.4f linear(max)=%.4f\n"):format(
    reaper.ScaleFromEnvelopeMode(mode, mn), reaper.ScaleFromEnvelopeMode(mode, mx))
end

reaper.ShowConsoleMsg(("[TE-DIAG] env=%s take=%s scalingMode=%s\n" ..
  "  volenvrange=%s pitchenvrange=%s\n" ..
  "  points=%d rawValMin=%s rawValMax=%s\n%s" ..
  "  env I_TCPY_USED=%s I_TCPH_USED=%s | I_TCPY=%s I_TCPH=%s\n" ..
  "  item I_LASTY=%s I_LASTH=%s | track I_TCPY=%s I_TCPH=%s\n")
  :format(tostring(name), tostring(take), tostring(mode),
    okV and volr or "?", okP and pitr or "?",
    cnt, tostring(mn), tostring(mx), unscaled,
    tostring(eyU), tostring(ehU), tostring(ey), tostring(eh),
    tostring(iy), tostring(ih), tostring(ty), tostring(th)))
