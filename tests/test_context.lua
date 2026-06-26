-- tests/test_context.lua — exercises the detection priority in core/context.lua via a mock `reaper`
-- global. Focus: window-focus RECENCY decides between a lingering arrange envelope/AI selection and a CC
-- selection in the MIDI editor (both persist at once), so switching surfaces switches the target BOTH
-- ways. Also covers the hold-when-Contour-is-focused case and the no-js_ReaScriptAPI fallback. Install the
-- mock BEFORE requiring core.context so its global resolves to ours.
package.path = package.path .. ";./Contour/?.lua;./?.lua;./tests/?.lua"

-- Window handles the mock hands back. focusedSide() compares JS_Window_GetFocus() against these.
local ME, MIDIVIEW, MAIN, TRACKVIEW = "ME", "MIDIVIEW", "MAIN", "TRACKVIEW"

local S
local function reset()
  S = {
    timeSel = { 0, 0 },
    me = nil, take = nil, takeOK = true, selCC = false, takeName = "Lead",
    env = nil, envName = "Volume", aiCount = 0, aiSel = {},
    focus = nil,        -- current OS-focused window handle (nil = unknown)
    hasJS = true,       -- js_ReaScriptAPI present?
  }
end
reset()

local function jsGetFocus() return S.hasJS and S.focus or nil end

_G.reaper = {
  GetSet_LoopTimeRange = function() return S.timeSel[1], S.timeSel[2] end,
  MIDIEditor_GetActive = function() return S.me end,
  MIDIEditor_GetTake   = function() return S.take end,
  ValidatePtr2         = function() return S.takeOK end,
  MIDI_EnumSelCC       = function(_t, ccidx) return (S.selCC and ccidx < 0) and 0 or -1 end,
  GetSelectedEnvelope  = function() return S.env end,
  GetEnvelopeName      = function() return true, S.envName end,
  CountAutomationItems = function() return S.aiCount end,
  GetSetAutomationItemInfo = function(_e, i, key) if key == "D_UISEL" then return S.aiSel[i] and 1 or 0 end return 0 end,
  GetSetMediaItemTakeInfo_String = function() return true, S.takeName end,
  GetMainHwnd          = function() return MAIN end,
  JS_Window_FindChildByID = function(parent, id)
    if parent == MAIN and id == 0x3E8 then return TRACKVIEW end
    if parent == ME   and id == 0x3E9 then return MIDIVIEW end
    return nil
  end,
}
-- JS_Window_GetFocus is set per-test below so the no-JS case can drop it.
local function installJS() _G.reaper.JS_Window_GetFocus = jsGetFocus end
installJS()

local h   = require("harness")
local ctx = require("core.context")

-- Stateful module: clear focus-recency memory before each scenario.
local function fresh() ctx._resetRecency(); reset(); installJS() end
local function det() return ctx.detect().target end

-- An "everything open" baseline: MIDI editor with a valid take AND an arrange envelope selected.
local function bothOpen() S.me, S.take = ME, "TAKE"; S.env = "ENV_A" end

h.test("focus on the arrange picks the envelope even when a CC selection lingers", function()
  fresh(); bothOpen(); S.selCC = true; S.focus = TRACKVIEW
  h.eq(det(), "envelope")
end)

h.test("focusing the MIDI editor switches to CC (direction 1)", function()
  fresh(); bothOpen()
  S.focus = TRACKVIEW; h.eq(det(), "envelope", "start on the envelope")
  S.selCC = true; S.focus = MIDIVIEW; h.eq(det(), "cc", "selecting CC in the editor switches to CC")
end)

h.test("clicking back on the SAME still-selected envelope switches back (direction 2, the reported bug)", function()
  fresh(); bothOpen()
  S.focus = TRACKVIEW; h.eq(det(), "envelope")
  S.selCC = true; S.focus = MIDIVIEW; h.eq(det(), "cc")
  -- env never changed (still ENV_A) and the CC stays selected; only focus returns to the arrange.
  S.focus = TRACKVIEW; h.eq(det(), "envelope", "re-focusing the arrange returns to the envelope")
end)

h.test("focus on the MIDI editor window itself (not the CC view) counts as midi", function()
  fresh(); bothOpen(); S.selCC = true; S.focus = ME
  h.eq(det(), "cc")
end)

h.test("Contour-panel focus holds the last surface (no spurious flip)", function()
  fresh(); bothOpen()
  S.focus = MIDIVIEW; S.selCC = true; h.eq(det(), "cc")
  S.focus = "CONTOUR"; h.eq(det(), "cc", "clicking the Contour panel must not flip the target")
  -- and the other way: settle on the envelope, then click Contour
  S.focus = TRACKVIEW; h.eq(det(), "envelope")
  S.focus = "CONTOUR"; h.eq(det(), "envelope", "still held on the arrange side")
end)

h.test("selecting a DIFFERENT envelope switches to the arrange even without a recognized focus", function()
  fresh(); bothOpen()
  S.focus = MIDIVIEW; S.selCC = true; h.eq(det(), "cc")
  -- user selects another envelope from the TCP: focus is unknown to us, but the handle changed.
  S.focus = "CONTOUR"; S.env = "ENV_B"; h.eq(det(), "envelope", "changed-envelope backstop switches to arrange")
end)

h.test("automation item is detected when its envelope is the focused arrange surface", function()
  fresh(); bothOpen(); S.aiCount = 2; S.aiSel[1] = true; S.focus = TRACKVIEW
  local d = ctx.detect()
  h.eq(d.target, "ai"); h.eq(d.details.aiIndex, 1)
end)

h.test("a closed editor with the midi side remembered falls back to the envelope", function()
  fresh(); bothOpen()
  S.focus = MIDIVIEW; S.selCC = true; h.eq(det(), "cc")
  S.me, S.take = nil, nil  -- editor closed; lastSide is still "midi" but cc candidate is gone
  S.focus = "CONTOUR"; h.eq(det(), "envelope", "no CC candidate => fall back to the selected envelope")
end)

h.test("no js_ReaScriptAPI: falls back to selected-CC-beats-envelope, else envelope", function()
  fresh(); bothOpen(); S.hasJS = false; _G.reaper.JS_Window_GetFocus = nil
  S.selCC = true;  h.eq(det(), "cc", "selected CC beats a stale envelope when focus is unknowable")
  ctx._resetRecency()
  S.selCC = false; h.eq(det(), "envelope", "no CC selected => the selected envelope wins")
end)

h.test("plain open editor, no envelope, no CC selection => CC fallback", function()
  fresh(); S.me, S.take = ME, "TAKE"; S.focus = "CONTOUR"
  h.eq(det(), "cc")
end)

h.test("an invalid editor take is ignored", function()
  fresh(); bothOpen(); S.takeOK = false; S.selCC = true; S.focus = MIDIVIEW
  h.eq(det(), "envelope", "invalid take => no CC candidate, envelope wins")
end)

h.test("nothing selected yields a nil target", function()
  fresh()
  local d = ctx.detect()
  h.eq(d.target, nil); h.eq(d.label, "(nothing selected)")
end)

h.test("time selection passes through to t0/t1/hasTimeSel", function()
  fresh(); S.timeSel = { 1.5, 3.25 }
  local d = ctx.detect()
  h.almost(d.t0, 1.5); h.almost(d.t1, 3.25); h.truthy(d.hasTimeSel)
end)

h.run()
