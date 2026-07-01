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

function M.reset()
  M.rec = {
    ins = {}, insEx = {}, delRange = {}, delRangeEx = {},
    sort = 0, sortEx = 0, ccIns = 0, setAllEvts = 0, extState = {}, undoBlocks = 0, msgs = {},
  }
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
  -- The MIDI item chunk ccSetup parses. Default: ONE visible CC lane (the active one) + a CFGEDITVIEW
  -- (leftTick 0, pxPerTick 1.0). Multi-lane tests overwrite this with a stacked-VELLANE chunk.
  M.itemChunk = ("CFGEDITVIEW 0 1.0 0 0 0\nVELLANE %d 90 0\n"):format(M.CC_LANE)
end
M.reset()

-- Read every CC event currently on `lane` (sorted by tick) — for tests asserting what a write produced.
function M.ccOnLane(lane)
  local out = {}
  for _, e in ipairs(M.ccList) do if e.lane == lane then out[#out + 1] = e end end
  table.sort(out, function(a, b) return a.ppq < b.ppq end)
  return out
end

local R = {}

-- ---- ImGui geometry: layout math divides by / offsets from these, so they MUST be numbers ----------
R.ImGui_GetMousePos           = function() return 100, 100 end
R.ImGui_GetCursorScreenPos    = function() return 10, 10 end
R.ImGui_GetContentRegionAvail = function() return 360, 240 end
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
-- End*/EndTabItem/EndCombo are no-ops via the catch-all; the stub does not enforce ImGui stack pairing.
R.ImGui_Begin        = function() return true, true end   -- (visible, open)
R.ImGui_BeginCombo   = function() return true end
R.ImGui_BeginTabBar  = function() return true end
R.ImGui_BeginTabItem = function() return true end
R.ImGui_BeginChild   = function() return true end
R.ImGui_BeginPopup   = function() return true end
R.ImGui_BeginPopupModal = function() return true end

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
R.GetEnvelopeName        = function() return true, "Pan" end
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

-- ---- Envelope READ (track + automation item) -----------------------------------------------------
R.CountEnvelopePoints = function() return #M.envPoints end
R.GetEnvelopePoint = function(_e, i)
  local p = M.envPoints[i + 1]; if not p then return false end
  return true, p.time, p.value, p.shape, p.tension or 0, p.sel and true or false
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
R.GetEnvelopeInfo_Value = function(_e, key)
  if key == "P_TRACK"      then return "TRACK" end   -- truthy pointer (passed to GetMediaTrackInfo_Value)
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
R.MIDIEditor_GetSetting_int = function() return M.CC_LANE end   -- last_clicked_cc_lane
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
R.GetMediaItemTake_Item  = function() return "ITEM" end
R.GetMediaItem_Track     = function() return "TRACK" end
R.GetMediaItemInfo_Value = function() return 0 end
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
