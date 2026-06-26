-- dump_cc.lua — print the active CC lane's events within the time selection as
-- (relative position 0..1, value) pairs, to empirically match REAPER's native CC LFO.
--
-- USAGE: in the MIDI editor, click the CC lane, make a time selection, generate a
-- native CC LFO with KNOWN settings, then run this script. It prints to the ReaScript
-- console. Paste the output back so the LFO formulas can be fitted to native's output.

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

local _, _, ccCount = reaper.MIDI_CountEvts(take)
local rows, vmin, vmax = {}, 1000, -1
for i = 0, ccCount - 1 do
  local ok, _, _, ppq, chanmsg, _, msg2, msg3 = reaper.MIDI_GetCC(take, i)
  if ok and chanmsg == 0xB0 and msg2 == lane then
    local t = reaper.MIDI_GetProjTimeFromPPQPos(take, ppq)
    if t >= t0 - 1e-9 and t <= t1 + 1e-9 then
      local rel = (t - t0) / (t1 - t0)
      rows[#rows + 1] = string.format("%.4f\t%d", rel, msg3)
      if msg3 < vmin then vmin = msg3 end
      if msg3 > vmax then vmax = msg3 end
    end
  end
end

reaper.ShowConsoleMsg(string.format("=== CC%d : %d events in the time selection ===\n", lane, #rows))
reaper.ShowConsoleMsg(string.format("value min=%d max=%d   (rel = 0..1 position across the selection)\n", vmin, vmax))
reaper.ShowConsoleMsg("rel\tvalue\n")
for _, r in ipairs(rows) do reaper.ShowConsoleMsg(r .. "\n") end
