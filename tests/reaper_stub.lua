-- tests/reaper_stub.lua — a headless fake `reaper` global for testing the ReaImGui panels and the
-- panel->engine->write path WITHOUT REAPER. The real `reaper` API has ~hundreds of functions; the
-- panels touch ~120 of them. Rather than stub each, a catch-all metatable turns every UNKNOWN
-- reaper.* into a no-op returning nil, and a curated override table (R) supplies TYPED returns for the
-- calls whose RESULTS are actually consumed: ImGui geometry (numbers the layout math divides by),
-- Begin*/tab gating (return true so the bodies run -> max coverage), ExtState (""), and the
-- envelope/automation-item read+write point APIs (recorded into M.rec so the Generate/Reduce sweeps
-- can assert on what WOULD be written, and fed from M.envPoints so the overlay/reduce read paths work).
--
-- Coverage philosophy:
--   * Begin*/BeginTabItem/BeginCombo => true  : enter every conditional body (this is what catches the
--     nil-global / missing-function / arity crashes that loadfile + the pure suite cannot, e.g. the
--     overlay `bounds` forward-reference regression).
--   * edit widgets (SliderInt/Checkbox/Combo/Button/...) keep the catch-all => (nil, nil) i.e.
--     changed=false : the panels do `if changed then state.x = v end`, so they never read a junk value.
--   * feature gates `if reaper.ImGui_Foo then` are ALWAYS truthy (catch-all returns a function), so the
--     modern-ReaImGui code path is taken — same as a real up-to-date install.
--
-- Value range: GetEnvelopeName => "Pan" => target.envValueRange yields a symmetric [-1,1] at scaling
-- mode 0 (no ScaleToEnvelopeMode), so written values are deterministic and easy to assert.
--
-- Usage:
--   local stub = require("reaper_stub")
--   stub.install()                         -- installs at _G.reaper; MUST run BEFORE require("ui.*")
--   stub.reset()                           -- clear M.rec + reseed read fixtures between tests
--   ... drive panels / M.run ...
--   assert(#stub.rec.ins > 0)
local M = { rec = nil, envPoints = nil, aiPoints = nil, ccEvents = nil }

local function noop() return nil end

-- Reset the recording tables + the read fixtures. A few selected envelope points so the overlay's
-- readScope finds a "Selected points" region and reaches bounds()/the transform math.
M.CC_LANE = 1   -- the active CC lane the read fixtures live on (matches MIDIEditor_GetSetting_int)
M.PPQ = 100     -- ppq per second (MIDI_GetPPQPosFromProjTime scale below)
-- Content-region width ImGui_GetContentRegionAvail reports (the panels pick one vs two columns from it).
-- reset() deliberately does NOT touch it: a test that changes it sets it and restores it (360) itself.
M.AVAIL_W = 360
-- The REAPER theme GetThemeColor reads (key -> native colour int, 0x00BBGGRR) and the clock time_precise
-- reports. reset() deliberately does NOT touch either: a test that changes them sets and restores them.
M.themeColors = {}
M.now = 0

function M.reset()
  M.rec = {
    ins = {}, insEx = {}, delRange = {}, delRangeEx = {},
    sort = 0, sortEx = 0, ccIns = 0, setAllEvts = 0, extState = {}, undoBlocks = 0, msgs = {},
    -- Begin/End pairing counters: every BeginChild needs an EndChild whatever it returns; EndTable only
    -- follows a BeginTable that returned true (the stub always does). Tests assert begin == end.
    childBegin = 0, childEnd = 0, tableBegin = 0, tableEnd = 0,
    -- Same for popups: EndPopup only follows a BeginPopup that returned true (the stub always does).
    popupBegin = 0, popupEnd = 0,
    -- And tab bars: EndTabBar only follows a BeginTabBar that returned true (the stub always does).
    tabBarBegin = 0, tabBarEnd = 0,
    -- And combos: EndCombo only follows a BeginCombo that returned true (the stub always does).
    comboBegin = 0, comboEnd = 0,
    -- SetCursorContext(mode, env) calls, in order: each entry { mode, env, mode = mode, env = env }.
    cursorCtx = {},
  }
  -- Razor-area fixtures: tracks in project order, each { handle, name, razor, envs = { {handle, guid, name} } },
  -- plus the master track. razor is the raw P_RAZOREDITS string; mouseState is JS_Mouse_GetState(1)
  -- (bit 1 = left button down). A fresh stub has no tracks, so context.detect() finds no razor areas.
  M.tracks = {}
  M.master = { handle = "MASTER", razor = "", envs = {} }
  M.mouseState = 0
  M.envPoints = {
    { time = 0.0, value = -0.5, shape = 0, tension = 0, sel = true },
    { time = 2.0, value =  0.6, shape = 0, tension = 0, sel = true },
    { time = 4.0, value = -0.2, shape = 0, tension = 0, sel = true },
  }
  M.aiPoints = {
    { time = 1.0, value = 0.3,  shape = 0, tension = 0, sel = true },
    { time = 3.0, value = -0.3, shape = 0, tension = 0, sel = true },
  }
  -- Stateful MIDI CC buffer for the active take: seeded with a couple of SELECTED events on CC_LANE so
  -- the overlay/reduce READ paths find a region; CC:write mutates it (recorded via rec.ccIns) so the
  -- Generate CC write path is assertable. ppq = time * PPQ.
  M.ccList = {
    { ppq = 1.0 * M.PPQ, chan = 0, lane = M.CC_LANE, val = 64, shape = 1, tension = 0, sel = true },
    { ppq = 3.0 * M.PPQ, chan = 0, lane = M.CC_LANE, val = 90, shape = 1, tension = 0, sel = true },
  }
  M.DEFAULT_CHAN = 0   -- the editor's default insert channel (MIDIEditor_GetSetting_int "default_note_chan")
  M.TAKE_NUM = 0       -- the active take's IP_TAKENUMBER (multi-take chunk-slicing tests override)
  M.LOOP_SRC = 0       -- TITEM's B_LOOPSRC flag (loop-extended MIDI item tests set 1)
  M.SRC_LEN_QN = 0     -- MIDI source length in QN (0 = unset; tick 0 sits at project 0, QN = sec*2)
  -- The MIDI item chunk ccSetup parses. Default: ONE visible CC lane (the active one) + a CFGEDITVIEW
  -- (leftTick 0, pxPerTick 1.0). Multi-lane tests overwrite this with a stacked-VELLANE chunk.
  M.itemChunk = ("CFGEDITVIEW 0 1.0 0 0 0\nVELLANE %d 90 0\n"):format(M.CC_LANE)
  -- TAKE-envelope fixture: env handle "TENV" on take "TAKE", whose item "TITEM" sits at 3s, length 5s,
  -- playrate 2.0. Point times are TAKE-RELATIVE seconds (range 0..10 maps to project 3..8), so any
  -- consumer that forgets the conversion shows up immediately in the tests.
  M.takeEnvPoints = {
    { time = 0.0,  value = -0.5, shape = 0, tension = 0, sel = true },
    { time = 4.0,  value =  0.6, shape = 0, tension = 0, sel = true },
    { time = 10.0, value = -0.2, shape = 0, tension = 0, sel = true },
  }
end
M.reset()

-- Read every CC event currently on `lane` (sorted by tick) — for tests asserting what a write produced.
function M.ccOnLane(lane)
  local out = {}
  for _, e in ipairs(M.ccList) do if e.lane == lane then out[#out + 1] = e end end
  table.sort(out, function(a, b) return a.ppq < b.ppq end)
  return out
end

-- Fixture lookups for the razor/track API: the track (or M.master) a handle names, and the envelope
-- fixture (plus its track) a handle names.
local function findTrack(handle)
  if handle == M.master.handle then return M.master end
  for _, t in ipairs(M.tracks) do if t.handle == handle then return t end end
end
local function findEnv(handle)
  local function scan(t)
    for _, e in ipairs(t.envs or {}) do if e.handle == handle then return t, e end end
  end
  local t, e = scan(M.master)
  if t then return t, e end
  for _, tr in ipairs(M.tracks) do
    t, e = scan(tr)
    if t then return t, e end
  end
end

local R = {}

-- ---- ImGui geometry: layout math divides by / offsets from these, so they MUST be numbers ----------
R.ImGui_GetMousePos           = function() return 100, 100 end
R.ImGui_GetCursorScreenPos    = function() return 10, 10 end
R.ImGui_GetContentRegionAvail = function() return M.AVAIL_W, 240 end
R.ImGui_GetCursorPosX         = function() return 14 end     -- window-space cursor (shell header / footer maths)
R.ImGui_GetCursorPosY         = function() return 100 end
R.ImGui_GetFrameHeight        = function() return 24 end
R.ImGui_GetFrameHeightWithSpacing = function() return 32 end
R.ImGui_GetTextLineHeightWithSpacing = function() return 22 end
R.ImGui_CalcTextSize          = function(_ctx, s) return #tostring(s) * 7, 14 end
R.ImGui_GetItemRectMin        = function() return 10, 10 end
R.ImGui_GetItemRectMax        = function() return 350, 30 end
R.ImGui_CalcItemWidth         = function() return 300 end
R.ImGui_GetWindowDrawList     = function() return "DL" end   -- opaque handle; DrawList_* are no-ops
R.ImGui_GetMouseWheel         = function() return 0 end
R.ImGui_GetKeyMods            = function() return 0 end
R.ImGui_GetVersion            = function() return "0.9.3" end
-- native<->ImGui point conversion. Identity here = Windows-standard-DPI (native == ImGui). A
-- macOS/HiDPI test overrides this to flip/scale and assert the overlay still maps onto the lane.
R.ImGui_PointConvertNative    = function(_ctx, x, y) return x, y end

-- ---- Value-echo widgets: real ReaImGui returns (changed, currentValue) and the panels write it back
-- UNCONDITIONALLY (`changed, g.x = SliderInt(...)`), so the stub MUST echo the passed-in value (arg 3)
-- or it would null out g.x every frame. changed=false => the `if changed then ... end` branches skip.
local function echo(_ctx, _label, v) return false, v end
R.ImGui_SliderInt    = echo
R.ImGui_SliderDouble = echo
R.ImGui_DragInt      = echo
R.ImGui_DragDouble   = echo
R.ImGui_InputInt     = echo
R.ImGui_InputDouble  = echo
R.ImGui_InputText    = echo
R.ImGui_Checkbox     = echo
R.ImGui_Combo        = echo

-- ---- Begin*/tab gating: return true so the conditional bodies run (max coverage) ------------------
-- End*/EndTabItem are no-ops via the catch-all; EndChild/EndTable/EndPopup/EndTabBar/EndCombo are COUNTED
-- (rec.*End) so tests can assert pairing.
R.ImGui_Begin        = function() return true, true end   -- (visible, open)
R.ImGui_BeginCombo   = function() M.rec.comboBegin = M.rec.comboBegin + 1; return true end
R.ImGui_EndCombo     = function() M.rec.comboEnd = M.rec.comboEnd + 1 end
R.ImGui_BeginTabBar  = function() M.rec.tabBarBegin = M.rec.tabBarBegin + 1; return true end
R.ImGui_EndTabBar    = function() M.rec.tabBarEnd = M.rec.tabBarEnd + 1 end
R.ImGui_BeginTabItem = function() return true end
R.ImGui_BeginChild   = function() M.rec.childBegin = M.rec.childBegin + 1; return true end
R.ImGui_EndChild     = function() M.rec.childEnd = M.rec.childEnd + 1 end
R.ImGui_BeginTable   = function() M.rec.tableBegin = M.rec.tableBegin + 1; return true end
R.ImGui_EndTable     = function() M.rec.tableEnd = M.rec.tableEnd + 1 end
R.ImGui_BeginPopup   = function() M.rec.popupBegin = M.rec.popupBegin + 1; return true end
R.ImGui_EndPopup     = function() M.rec.popupEnd = M.rec.popupEnd + 1 end
R.ImGui_BeginPopupModal = function() return true end
-- Pressed-style widgets: nothing is clicked unless a test overrides them.
R.ImGui_TabItemButton = function() return false end
R.ImGui_MenuItem      = function() return false end

-- ---- REAPER theme + clock (ui/theme Auto palette and its once-a-second refresh) ---------------------
-- GetThemeColor reads M.themeColors and reports a missing key as -1, like REAPER. ColorFromNative is the
-- Windows order: native = 0x00BBGGRR.
R.GetThemeColor   = function(key) local v = M.themeColors[key]; if v == nil then return -1 end return v end
R.ColorFromNative = function(n) return n & 0xFF, (n >> 8) & 0xFF, (n >> 16) & 0xFF end
R.time_precise    = function() return M.now end

-- ---- Tracks, track envelopes, razor areas (core/context.lua) ---------------------------------------------
-- Driven by M.tracks / M.master (see reset()). An unknown handle reads as (false, ""), like a failed
-- REAPER call. Writes (set == true) land in the fixture so a test can read them back.
R.GetMasterTrack = function() return M.master.handle end
R.CountTracks    = function() return #M.tracks end
R.GetTrack       = function(_proj, i) local t = M.tracks[i + 1]; return t and t.handle or nil end
R.GetSetMediaTrackInfo_String = function(tr, key, val, set)
  local t = findTrack(tr)
  if not t then return false, "" end
  if key == "P_RAZOREDITS" then
    if set then t.razor = val end
    return true, t.razor or ""
  elseif key == "P_NAME" then
    if set then t.name = val end
    return true, t.name or ""
  end
  return false, ""
end
R.CountTrackEnvelopes = function(tr) local t = findTrack(tr); return t and #(t.envs or {}) or 0 end
R.GetTrackEnvelope    = function(tr, i)
  local t = findTrack(tr)
  local e = t and t.envs and t.envs[i + 1]
  return e and e.handle or nil
end
R.GetSetEnvelopeInfo_String = function(env, key, _val, _set)
  local _, e = findEnv(env)
  if e and key == "GUID" then return true, e.guid end
  return false, ""
end
-- SetCursorContext(2, env) selects an envelope in REAPER; the stub only records the call.
R.SetCursorContext = function(mode, env)
  M.rec.cursorCtx[#M.rec.cursorCtx + 1] = { mode, env, mode = mode, env = env }
end
-- js_ReaScriptAPI: bit 1 of JS_Mouse_GetState(1) is the left button.
R.JS_Mouse_GetState = function() return M.mouseState end

-- ---- ExtState: return "" so preset/store decoders see "nothing saved" cleanly --------------------
R.GetExtState = function(_sec, key) return M.rec.extState[key] or "" end
R.SetExtState = function(_sec, key, val) M.rec.extState[key] = val end
R.DeleteExtState = function(_sec, key) M.rec.extState[key] = nil end
R.HasExtState = function(_sec, key) return M.rec.extState[key] ~= nil end

-- ---- Console / dialogs ---------------------------------------------------------------------------
R.ShowConsoleMsg = function(s) M.rec.msgs[#M.rec.msgs + 1] = tostring(s) end
R.ShowMessageBox = function() return 0 end

-- ---- Value range (envelope): "Pan", scaling mode 0 => target gives [-1,1] -------------------------
R.GetEnvelopeScalingMode = function() return 0 end
R.GetEnvelopeName        = function(env)
  local _, e = findEnv(env)
  return true, (e and e.name) or "Pan"   -- a fixture envelope reports its own name
end
R.ScaleToEnvelopeMode    = function(_m, v) return v end
R.ScaleFromEnvelopeMode  = function(_m, v) return v end

-- ---- Automation-item geometry: item at 0s, length 10s => bounds [0,10] ----------------------------
R.GetSetAutomationItemInfo = function(_e, _i, key)
  if key == "D_POSITION" then return 0.0 end
  if key == "D_LENGTH"   then return 10.0 end
  if key == "D_UISEL"    then return 1 end
  return 0.0
end
R.CountAutomationItems = function() return 1 end

-- ---- Envelope READ (track + take envelope + automation item) --------------------------------------
-- "TENV" (the take envelope) reads the take-relative fixture; any other env handle reads envPoints.
R.CountEnvelopePoints = function(env) return (env == "TENV") and #M.takeEnvPoints or #M.envPoints end
R.GetEnvelopePoint = function(env, i)
  local list = (env == "TENV") and M.takeEnvPoints or M.envPoints
  local p = list[i + 1]; if not p then return false end
  return true, p.time, p.value, p.shape, p.tension or 0, p.sel and true or false
end
-- take-envelope plumbing: parent take, its item, and the item/take geometry the time conversion uses
R.Envelope_GetParentTake = function(env) if env == "TENV" or env == "TENV0" then return "TAKE" end return nil end
R.GetMediaItemTakeInfo_Value = function(take, key)
  if take == "TAKE" and key == "D_PLAYRATE" then return 2.0 end
  if key == "IP_TAKENUMBER" then return M.TAKE_NUM or 0 end
  return 1.0
end
R.CountEnvelopePointsEx = function() return #M.aiPoints end
R.GetEnvelopePointEx = function(_e, _idx, i)
  local p = M.aiPoints[i + 1]; if not p then return false end
  return true, p.time, p.value, p.shape, p.tension or 0, p.sel and true or false
end

-- ---- Envelope WRITE — recorded (track non-Ex + automation-item Ex) --------------------------------
R.DeleteEnvelopePointRange = function(_e, t0, t1) M.rec.delRange[#M.rec.delRange + 1] = { t0, t1 } end
R.InsertEnvelopePoint = function(_e, t, v, shape, tension, sel)
  M.rec.ins[#M.rec.ins + 1] = { t = t, v = v, shape = shape, tension = tension, sel = sel }
  return true
end
R.Envelope_SortPoints = function() M.rec.sort = M.rec.sort + 1 end
R.DeleteEnvelopePointRangeEx = function(_e, idx, t0, t1) M.rec.delRangeEx[#M.rec.delRangeEx + 1] = { idx, t0, t1 } end
R.InsertEnvelopePointEx = function(_e, idx, t, v, shape, tension, sel)
  M.rec.insEx[#M.rec.insEx + 1] = { idx = idx, t = t, v = v, shape = shape, tension = tension, sel = sel }
  return true
end
R.Envelope_SortPointsEx = function() M.rec.sortEx = M.rec.sortEx + 1 end

-- ---- Envelope geometry (overlay laneRect) --------------------------------------------------------
R.GetEnvelopeInfo_Value = function(env, key)
  if key == "P_TRACK" then                           -- truthy pointer (passed to GetMediaTrackInfo_Value)
    local t = findEnv(env)
    return t and t.handle or "TRACK"
  end
  if env == "TENV" then                              -- take envelope: its OWN strip within the item
    if key == "I_TCPY_USED" then return 25 end
    if key == "I_TCPH_USED" then return 30 end
    return 0
  end
  if env == "TENV0" then return 0 end                -- take envelope whose strip fields come back empty
  if key == "I_TCPY_USED"  then return 10 end
  if key == "I_TCPH_USED"  then return 80 end
  return 0
end
R.GetMediaTrackInfo_Value = function(_t, key)
  if key == "I_TCPSCREENY" then return 100 end
  if key == "I_TCPY"       then return 120 end   -- track Y relative to arrange top (overlay laneRect)
  return 0
end

-- ---- Arrange / window geometry (overlay trackviewRect + viewNow) ----------------------------------
R.GetMainHwnd            = function() return "MAIN" end
R.JS_Window_FindChildByID = function() return "CHILD" end
R.JS_Window_GetClientRect = function() return true, 0, 0, 800, 600 end   -- (ok, l, t, r, b)
R.JS_Window_GetFocus     = function() return "CONTOUR" end
R.GetSet_ArrangeView2    = function() return 0.0, 10.0 end               -- (startTime, endTime)

-- ---- Time / tempo --------------------------------------------------------------------------------
R.Master_GetTempo     = function() return 120 end
R.TimeMap2_timeToQN   = function(_p, t) return t * 2 end                 -- 120bpm: 2 QN/sec
R.TimeMap2_QNToTime   = function(_p, q) return q / 2 end
R.GetProjectLength    = function() return 60 end
R.GetSet_LoopTimeRange = function() return 0.0, 4.0 end

-- ---- MIDI editor read (CC value mapping in panels) -----------------------------------------------
R.MIDIEditor_GetActive    = function() return "ME" end
R.MIDIEditor_GetTake      = function() return "TAKE" end
R.MIDIEditor_GetSetting_int = function(_me, setting)
  if setting == "default_note_chan" then return M.DEFAULT_CHAN end
  return M.CC_LANE   -- last_clicked_cc_lane
end
R.MIDI_GetPPQPosFromProjTime = function(_t, sec) return sec * M.PPQ end
R.MIDI_GetProjTimeFromPPQPos = function(_t, ppq) return ppq / M.PPQ end
R.ValidatePtr2 = function() return true end
-- The MIDI item chunk the overlay's ccSetup parses — configurable via M.itemChunk (reset() restores
-- the single-lane default) so multi-lane VELLANE stacks are testable.
R.GetItemStateChunk = function()
  return true, M.itemChunk
end

-- ---- MIDI CC: a minimal STATEFUL event engine so CC:write round-trips like real REAPER -----------
-- CC:write uses deleteCCInRange (CountEvts/GetCC + DeleteCC) -> MIDI_InsertCC -> MIDI_Sort ->
-- applyPointShapes (GetCC scan + SetCCShape). Modelling those over M.ccList makes a written lane
-- readable back (and counts inserts in rec.ccIns). writeBulk's MIDI_SetAllEvts path stays a no-op
-- (Generate's self-contained write uses the InsertCC path, not SetAllEvts).
R.MIDI_GetAllEvts = function() return true, "" end
R.MIDI_SetAllEvts = function() M.rec.setAllEvts = M.rec.setAllEvts + 1; return true end   -- atomic writeBulk path
R.MIDI_Sort       = function() table.sort(M.ccList, function(a, b) return a.ppq < b.ppq end) end
R.MIDI_CountEvts  = function() return true, 0, #M.ccList end
R.MIDI_GetCC = function(_t, i)
  local e = M.ccList[i + 1]; if not e then return false end
  return true, e.sel and true or false, false, e.ppq, 0xB0, e.chan or 0, e.lane, e.val
end
R.MIDI_GetCCShape = function(_t, i)
  local e = M.ccList[i + 1]; if not e then return false end
  return true, e.shape or 1, e.tension or 0
end
R.MIDI_InsertCC = function(_t, sel, _muted, ppq, _status, chan, lane, val)
  M.ccList[#M.ccList + 1] = { ppq = ppq, chan = chan, lane = lane, val = val, shape = 0, tension = 0, sel = sel }
  M.rec.ccIns = M.rec.ccIns + 1
  return true
end
R.MIDI_SetCCShape = function(_t, i, shape, tension) local e = M.ccList[i + 1]; if e then e.shape = shape; e.tension = tension end end
R.MIDI_DeleteCC = function(_t, i) table.remove(M.ccList, i + 1) end
R.MIDI_EnumSelCC      = function(_t, idx) return (idx < 0) and 0 or -1 end
R.GetMediaItemTake_Item  = function(take) return (take == "TAKE") and "TITEM" or "ITEM" end
R.GetMediaItem_Track     = function() return "TRACK" end
-- "TITEM" (the take-envelope item) has real geometry; the CC item ("ITEM") keeps the old zeros.
R.GetMediaItemInfo_Value = function(item, key)
  if item == "TITEM" then
    if key == "D_POSITION" then return 3.0 end
    if key == "D_LENGTH"   then return 5.0 end
    if key == "I_LASTY"    then return 20 end   -- item Y within the track (px)
    if key == "I_LASTH"    then return 60 end   -- item height (px)
    if key == "B_LOOPSRC"  then return M.LOOP_SRC end
  end
  return 0
end
R.GetMediaItemTake_Source = function() return "SRC" end
R.GetMediaSourceLength    = function() return M.SRC_LEN_QN, true end            -- MIDI sources report QN
R.MIDI_GetProjQNFromPPQPos = function(_t, ppq) return (ppq / M.PPQ) * 2 end     -- via time, 2 QN/sec
R.MarkTrackItemsDirty    = function() end
R.PreventUIRefresh       = function() end
R.UpdateArrange          = function() end

-- ---- Undo blocks ---------------------------------------------------------------------------------
R.Undo_BeginBlock2 = function() M.rec.undoBlocks = M.rec.undoBlocks + 1 end
R.Undo_EndBlock2   = function() end

-- The long tail. ImGui ENUM/FLAG getters (Mod_*, Key_*, *Flags*, Col_*, Cond*, StyleVar_*,
-- MouseCursor_*, Dir_*) are combined with bitwise/arithmetic operators (`C | S`, `mods & Mod_Alt()`,
-- flag1 | flag2), so they MUST return a NUMBER — nil would throw. Everything else (actions, end-calls,
-- pressed-style widgets) is a no-op returning nil (falsy => "not pressed / not changed"). Returning 0
-- for every enum is fine for smoke testing: we assert the code RUNS, not which chord/flag fired.
local function zero() return 0 end
local function isEnum(name)
  return name:find("_Mod_") or name:find("_Key_") or name:find("Flags")
      or name:find("_Col_") or name:find("_Cond") or name:find("_StyleVar_")
      or name:find("_MouseCursor_") or name:find("_Dir_") or name:find("_ConfigVar_")
end

-- Install at _G.reaper with the smart catch-all behind the curated overrides. MUST be called BEFORE any
-- require("ui.*") so the modules' module-level `reaper.*` reads (e.g. shell's FLAG_SETSEL) resolve here.
function M.install()
  _G.reaper = setmetatable(R, {
    __index = function(_, name)
      if type(name) == "string" and isEnum(name) then return zero end
      return noop
    end,
  })
  return _G.reaper
end

return M
