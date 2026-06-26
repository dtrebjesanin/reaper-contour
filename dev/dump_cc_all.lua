-- dump_cc_all.lua — dump EVERY CC lane that has events in the time selection, grouped by lane,
-- as (rel 0..1, value) pairs. Workflow: generate a different native CC LFO setting into each of
-- several CC lanes (e.g. CC1, CC2, CC3...), then run THIS ONCE to capture them all together.
-- Output -> ReaScript console. Paste it back to fit the LFO formulas to native.

local me = reaper.MIDIEditor_GetActive()
if not me then reaper.ShowConsoleMsg("No active MIDI editor.\n") return end
local take = reaper.MIDIEditor_GetTake(me)
if not take then reaper.ShowConsoleMsg("No active MIDI take.\n") return end
local t0, t1 = reaper.GetSet_LoopTimeRange(false, false, 0, 0, false)
if t1 <= t0 then reaper.ShowConsoleMsg("No time selection.\n") return end

local span = t1 - t0
local lanes, order = {}, {}
local _, _, ccCount = reaper.MIDI_CountEvts(take)
for i = 0, ccCount - 1 do
  local ok, _, _, ppq, chanmsg, _, msg2, msg3 = reaper.MIDI_GetCC(take, i)
  if ok and chanmsg == 0xB0 then
    local t = reaper.MIDI_GetProjTimeFromPPQPos(take, ppq)
    if t >= t0 - 1e-9 and t <= t1 + 1e-9 then
      if not lanes[msg2] then lanes[msg2] = {}; order[#order + 1] = msg2 end
      local L = lanes[msg2]
      L[#L + 1] = { rel = (t - t0) / span, val = msg3 }
    end
  end
end

if #order == 0 then reaper.ShowConsoleMsg("No CC events in the time selection.\n") return end
table.sort(order)
for _, lane in ipairs(order) do
  local L = lanes[lane]
  table.sort(L, function(a, b) return a.rel < b.rel end)
  local vmin, vmax = 1000, -1
  for _, p in ipairs(L) do
    if p.val < vmin then vmin = p.val end
    if p.val > vmax then vmax = p.val end
  end
  reaper.ShowConsoleMsg(string.format("=== CC%d : %d events, min=%d max=%d ===\n", lane, #L, vmin, vmax))
  for _, p in ipairs(L) do reaper.ShowConsoleMsg(string.format("%.4f\t%d\n", p.rel, p.val)) end
  reaper.ShowConsoleMsg("\n")
end
