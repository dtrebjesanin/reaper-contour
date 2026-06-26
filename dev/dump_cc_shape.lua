-- dump_cc_shape.lua — print the active CC lane's events in the time selection together with
-- their CC SHAPE and bezier tension. Used to learn what curve REAPER's native CC LFO actually
-- writes for the smooth shapes (Sine / Parametric), so Contour can reproduce the EXACT curvature.
--
-- USAGE: generate a NATIVE CC LFO (e.g. Parametric, then Sine) onto a CC lane, click that lane,
-- make/keep a time selection, run this script. Paste the console output back.
--
-- CC shape ints: 0=square/step, 1=linear, 2=slow start/end (S-curve), 3=fast start,
--                4=fast end, 5=bezier (tension in the last column).

local me = reaper.MIDIEditor_GetActive()
if not me then reaper.ShowConsoleMsg("No active MIDI editor.\n") return end
local take = reaper.MIDIEditor_GetTake(me)
if not take then reaper.ShowConsoleMsg("No active MIDI take.\n") return end

local lane = reaper.MIDIEditor_GetSetting_int(me, "last_clicked_cc_lane")
if lane < 0 or lane > 127 then
  reaper.ShowConsoleMsg("Click a standard CC lane (0-127) first. Got lane " .. tostring(lane) .. "\n") return
end

local t0, t1 = reaper.GetSet_LoopTimeRange(false, false, 0, 0, false)
if t1 <= t0 then reaper.ShowConsoleMsg("No time selection.\n") return end

local NAMES = { [0] = "square/step", [1] = "linear", [2] = "slow start/end",
                [3] = "fast start", [4] = "fast end", [5] = "bezier" }
if not reaper.MIDI_GetCCShape then
  reaper.ShowConsoleMsg("MIDI_GetCCShape unavailable in this REAPER build.\n") return
end

local _, _, ccCount = reaper.MIDI_CountEvts(take)
reaper.ShowConsoleMsg(string.format("=== CC%d : shapes in the time selection ===\n", lane))
reaper.ShowConsoleMsg("rel\tvalue\tshape\ttension\n")
local n = 0
for i = 0, (ccCount or 0) - 1 do
  local ok, _, _, ppq, chanmsg, _, msg2, msg3 = reaper.MIDI_GetCC(take, i)
  if ok and chanmsg == 0xB0 and msg2 == lane then
    local t = reaper.MIDI_GetProjTimeFromPPQPos(take, ppq)
    if t >= t0 - 1e-9 and t <= t1 + 1e-9 then
      local okS, shp, tens = reaper.MIDI_GetCCShape(take, i)
      local rel = (t - t0) / (t1 - t0)
      reaper.ShowConsoleMsg(string.format("%.4f\t%d\t%d (%s)\t%.4f\n",
        rel, msg3, shp or -1, NAMES[shp] or "?", tens or 0))
      n = n + 1
    end
  end
end
if n == 0 then reaper.ShowConsoleMsg("No CC events on this lane in the time selection.\n") end
