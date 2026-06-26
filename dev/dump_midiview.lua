-- dump_midiview.lua — READ-ONLY diagnostic for cracking MIDI-editor CC coordinates (Transform slice 4).
--
-- HOW TO RUN (no hotkey needed):
--   1. Open a MIDI item in the MIDI editor and show a CC lane (e.g. CC1/Mod) with a few CC events in it.
--   2. Run this action (double-click it in the Action list, or any way you like).
--   3. A countdown tooltip appears — move the mouse OVER a CC event in that lane and HOLD it there.
--   4. When the countdown hits 0 it samples wherever the mouse is, and prints to the ReaScript console.
--   Repeat 2-3 times hovering DIFFERENT events (low value near the LEFT, then high value near the RIGHT).
--   The console accumulates all runs — then copy everything and paste it back.

local DELAY = 3.5  -- seconds to position the mouse before sampling
local function log(s) reaper.ShowConsoleMsg(tostring(s) .. "\n") end

local function winInfo(hwnd)
  local cls = reaper.JS_Window_GetClassName and select(2, reaper.JS_Window_GetClassName(hwnd, "")) or "?"
  local id  = reaper.JS_Window_GetLong and reaper.JS_Window_GetLong(hwnd, "ID") or -1
  local ok, l, t, r, b = reaper.JS_Window_GetClientRect(hwnd)
  return string.format("class=%-20s id=%-8s rect=[%d,%d,%d,%d]", tostring(cls), tostring(math.floor(id or -1)),
    ok and l or -1, ok and t or -1, ok and r or -1, ok and b or -1)
end

local function gather()
  log("\n\n================= dump_midiview RUN =================")
  for _, fn in ipairs({ "JS_Window_GetClientRect", "BR_GetMouseCursorContext", "MIDIEditor_GetActive" }) do
    if not reaper[fn] then log("MISSING API: reaper." .. fn) end
  end

  local me = reaper.MIDIEditor_GetActive()
  if not me then log("No active MIDI editor."); return end
  local take = reaper.MIDIEditor_GetTake(me)
  if not (take and reaper.ValidatePtr2(0, take, "MediaItem_Take*")) then log("No valid take."); return end
  local item = reaper.GetMediaItemTake_Item(take)

  local mx, my = reaper.GetMousePosition()
  log(string.format("Mouse screen pos: (%d, %d)", mx, my))

  -- The window directly under the cursor = the midiview (when hovering the CC lane). The key one.
  log("\n-- WINDOW UNDER MOUSE (midiview when hovering the CC lane) --")
  if reaper.JS_Window_FromPoint then
    local w = reaper.JS_Window_FromPoint(mx, my)
    log(w and ("  " .. winInfo(w)) or "  (none)")
  end

  -- Best-effort full descendant list (guarded against large counts).
  log("\n-- editor descendant windows (mouseInside marked) --")
  if reaper.JS_Window_ArrayAllChild and reaper.new_array then
    local CAP = 2048
    local arr = reaper.new_array(CAP)
    local n = math.max(0, math.min(math.floor(reaper.JS_Window_ArrayAllChild(me, arr) or 0), CAP))
    local ok, addrs = pcall(function() return n > 0 and arr.table(1, n) or {} end)
    if ok and addrs then
      for _, a in ipairs(addrs) do
        local hwnd = reaper.JS_Window_HandleFromAddress(a)
        if hwnd then
          local okr, l, t, r, b = reaper.JS_Window_GetClientRect(hwnd)
          local inside = (okr and mx >= l and mx <= r and my >= t and my <= b) and "  <== MOUSE INSIDE" or ""
          log("  " .. winInfo(hwnd) .. inside)
        end
      end
    end
  end

  log("\n-- editor settings --")
  local function geti(k) return reaper.MIDIEditor_GetSetting_int and reaper.MIDIEditor_GetSetting_int(me, k) end
  log("  last_clicked_cc_lane = " .. tostring(geti("last_clicked_cc_lane")))
  log("  active_note_row      = " .. tostring(geti("active_note_row")))

  log("\n-- time / ppq references --")
  local pos = reaper.GetMediaItemInfo_Value(item, "D_POSITION")
  local len = reaper.GetMediaItemInfo_Value(item, "D_LENGTH")
  log(string.format("  item pos=%.4f  len=%.4f", pos, len))
  log(string.format("  item ppq range: [%.2f .. %.2f]",
    reaper.MIDI_GetPPQPosFromProjTime(take, pos), reaper.MIDI_GetPPQPosFromProjTime(take, pos + len)))
  if reaper.BR_GetMidiSourceLenPPQ then log("  BR_GetMidiSourceLenPPQ = " .. tostring(reaper.BR_GetMidiSourceLenPPQ(take))) end

  log("\n-- take/item chunk view lines (CFGEDITVIEW / VELLANE) --")
  local okc, chunk = reaper.GetItemStateChunk(item, "", false)
  if okc and chunk then
    for line in chunk:gmatch("[^\r\n]+") do
      if line:match("^%s*CFGEDITVIEW") or line:match("^%s*VELLANE") or line:match("^%s*CFGEDIT ") then
        log("  " .. line)
      end
    end
  else
    log("  (could not read item chunk)")
  end

  log("\n-- MOUSE SAMPLE (under the cursor right now) --")
  if reaper.BR_GetMouseCursorContext then
    local window, seg, det = reaper.BR_GetMouseCursorContext()
    local _, inl, noteRow, ccLane, ccLaneVal, ccLaneId = reaper.BR_GetMouseCursorContext_MIDI()
    local posT = reaper.BR_GetMouseCursorContext_Position and reaper.BR_GetMouseCursorContext_Position() or -1
    local ppq = (posT and posT >= 0) and reaper.MIDI_GetPPQPosFromProjTime(take, posT) or -1
    log("  window/segment/detail: " .. tostring(window) .. " / " .. tostring(seg) .. " / " .. tostring(det))
    log(string.format("  ccLane=%s  ccLaneVal=%s  ccLaneId=%s  noteRow=%s",
      tostring(ccLane), tostring(ccLaneVal), tostring(ccLaneId), tostring(noteRow)))
    log(string.format("  projTime=%.4f  ppq=%.2f", posT or -1, ppq))
    log("  ==> screen X " .. mx .. " maps to ppq " .. string.format("%.2f", ppq))
    log("  ==> screen Y " .. my .. " maps to CC value " .. tostring(ccLaneVal))
  end
  log("\n----- (run again over a different event; copy ALL runs when done) -----")
end

-- Countdown, then sample wherever the mouse is.
if not reaper.MIDIEditor_GetActive() then
  reaper.ShowConsoleMsg("No active MIDI editor — open a MIDI item in the editor first, then run again.\n"); return
end
reaper.ShowConsoleMsg(("\nMove the mouse over a CC event — sampling in %.1fs...\n"):format(DELAY))
local t0 = reaper.time_precise()
local function loop()
  local remain = DELAY - (reaper.time_precise() - t0)
  if remain > 0 then
    local mx, my = reaper.GetMousePosition()
    if reaper.TrackCtl_SetToolTip then
      reaper.TrackCtl_SetToolTip(("Contour: hover a CC event — sampling in %.1fs"):format(remain), mx + 18, my + 18, true)
    end
    reaper.defer(loop)
  else
    if reaper.TrackCtl_SetToolTip then reaper.TrackCtl_SetToolTip("", 0, 0, false) end
    gather()
  end
end
loop()
