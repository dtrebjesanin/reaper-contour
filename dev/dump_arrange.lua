-- dump_arrange.lua — verify the arrange/envelope coordinate inputs the Transform overlay needs.
-- Select a track envelope (and optionally some points / a time selection), run this, paste the output.
local function need(fn) return reaper[fn] ~= nil end
if not need("JS_Window_FindChildByID") then reaper.ShowConsoleMsg("js_ReaScriptAPI missing\n") return end

local env = reaper.GetSelectedEnvelope(0)
if not env then reaper.ShowConsoleMsg("No selected envelope.\n") return end
local _, ename = reaper.GetEnvelopeName(env, "")

-- arrange view: time range across the trackview client width
local main = reaper.GetMainHwnd()
local trackview = reaper.JS_Window_FindChildByID(main, 0x3E8)  -- 1000 = arrange "trackview"
local okR, l, t, r, b = reaper.JS_Window_GetClientRect(trackview)
local W = (r or 0) - (l or 0)
local t0, t1 = reaper.GetSet_ArrangeView2(0, false, l, r, 0, 0)  -- screen-x anchors = trackview edges (not 0..W)
reaper.ShowConsoleMsg(("=== Envelope: %s ===\n"):format(ename))
reaper.ShowConsoleMsg(("trackview client: l=%d t=%d r=%d b=%d  W=%d\n"):format(l or -1,t or -1,r or -1,b or -1,W))
reaper.ShowConsoleMsg(("arrange view time: t0=%.4f t1=%.4f  (px/sec=%.3f)\n"):format(t0, t1, (t1>t0) and W/(t1-t0) or 0))

-- envelope lane screen rect
local track = reaper.GetEnvelopeInfo_Value(env, "P_TRACK")
local tcpScreenY = reaper.GetMediaTrackInfo_Value(track, "I_TCPSCREENY")
local laneY = reaper.GetEnvelopeInfo_Value(env, "I_TCPY_USED")
local laneH = reaper.GetEnvelopeInfo_Value(env, "I_TCPH_USED")
reaper.ShowConsoleMsg(("lane: track I_TCPSCREENY=%.1f  env I_TCPY_USED=%.1f  I_TCPH_USED=%.1f  => yTop=%.1f yBot=%.1f\n")
  :format(tcpScreenY, laneY, laneH, tcpScreenY+laneY, tcpScreenY+laneY+laneH))

-- lane value range in the STORAGE/raw domain GetEnvelopePoint uses (what the overlay maps to Y).
-- The overlay uses ENV:valueRange = ScaleToEnvelopeMode(mode, linearMin..linearMax); for volume that's
-- linear 0..2 -> raw. These ScaleTo values should bracket the raw point values printed below.
local mode = reaper.GetEnvelopeScalingMode(env)
reaper.ShowConsoleMsg(("scaling mode=%d  raw ScaleTo(0)=%.2f  ScaleTo(1)=%.2f  ScaleTo(2)=%.2f  (lane maps these to Y)\n")
  :format(mode, reaper.ScaleToEnvelopeMode(mode, 0), reaper.ScaleToEnvelopeMode(mode, 1), reaper.ScaleToEnvelopeMode(mode, 2)))

-- first 4 points: project time -> expected screen x
for i = 0, math.min(reaper.CountEnvelopePoints(env), 4) - 1 do
  local ok, ptt, ptv = reaper.GetEnvelopePoint(env, i)
  local x = (t1>t0) and ((l or 0) + (ptt - t0) * W / (t1 - t0)) or -1
  reaper.ShowConsoleMsg(("  pt#%d t=%.4f v=%.4f  -> screenX=%.1f\n"):format(i, ptt, ptv, x))
end
