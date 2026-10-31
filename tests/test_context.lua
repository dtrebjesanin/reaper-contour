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
    -- razor fixtures: tracks = { { handle, name, razor, envs = { { handle, guid, name } } } }, in track order
    tracks = {}, master = { handle = "MASTER", name = "", razor = "", envs = {} },
    now = 0,            -- reaper.time_precise()
    mouse = 0,          -- JS_Mouse_GetState(1): bit 1 = left button down
    aiPos = 0, aiLen = 10,                -- bounds of every automation item
    takeOf = {}, takeItem = {},           -- take envelope handle -> take, take -> { handle, track, pos, len }
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
  GetEnvelopeName      = function(env)
    for _, t in ipairs(S.tracks) do
      for _, e in ipairs(t.envs) do if e.handle == env then return true, e.name end end
    end
    for _, e in ipairs(S.master.envs) do if e.handle == env then return true, e.name end end
    return true, S.envName
  end,
  Envelope_GetParentTake = function(env) return S.takeOf[env] end,
  GetMediaItemTake_Item  = function(take) local it = S.takeItem[take]; return it and it.handle or nil end,
  GetMediaItem_Track     = function(item)
    for _, it in pairs(S.takeItem) do if it.handle == item then return it.track end end
  end,
  GetMediaItemInfo_Value = function(item, key)
    for _, it in pairs(S.takeItem) do
      if it.handle == item then
        if key == "D_POSITION" then return it.pos end
        if key == "D_LENGTH" then return it.len end
      end
    end
    return 0
  end,
  CountAutomationItems = function() return S.aiCount end,
  GetSetAutomationItemInfo = function(_e, i, key)
    if key == "D_UISEL" then return S.aiSel[i] and 1 or 0 end
    if key == "D_POSITION" then return S.aiPos end
    if key == "D_LENGTH" then return S.aiLen end
    return 0
  end,
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

-- The razor-area API (tracks, track envelopes, envelope GUIDs, clock, mouse). A function so one test can
-- take it away again: without it context.detect must behave exactly as before razor support existed.
local RAZOR_API = {
  "GetMasterTrack", "CountTracks", "GetTrack", "GetSetMediaTrackInfo_String", "CountTrackEnvelopes",
  "GetTrackEnvelope", "GetSetEnvelopeInfo_String", "time_precise", "JS_Mouse_GetState",
}
local function trackByHandle(hnd)
  if hnd == S.master.handle then return S.master end
  for _, t in ipairs(S.tracks) do if t.handle == hnd then return t end end
end
local function installRazor()
  local r = _G.reaper
  r.GetMasterTrack = function() return S.master.handle end
  r.CountTracks = function() return #S.tracks end
  r.GetTrack = function(_p, i) local t = S.tracks[i + 1]; return t and t.handle or nil end
  r.GetSetMediaTrackInfo_String = function(tr, key, _val, _set)
    local t = trackByHandle(tr); if not t then return false, "" end
    if key == "P_RAZOREDITS" then return true, t.razor or "" end
    if key == "P_NAME" then return true, t.name or "" end
    return false, ""
  end
  r.CountTrackEnvelopes = function(tr) local t = trackByHandle(tr); return t and #t.envs or 0 end
  r.GetTrackEnvelope = function(tr, i) local t = trackByHandle(tr); local e = t and t.envs[i + 1]; return e and e.handle or nil end
  r.GetSetEnvelopeInfo_String = function(env, key, _val, _set)
    if key ~= "GUID" then return false, "" end
    for _, t in ipairs(S.tracks) do
      for _, e in ipairs(t.envs) do if e.handle == env then return true, e.guid end end
    end
    for _, e in ipairs(S.master.envs) do if e.handle == env then return true, e.guid end end
    return false, ""
  end
  r.time_precise = function() return S.now end
  r.JS_Mouse_GetState = function() return S.mouse end
end
local function removeRazor() for _, name in ipairs(RAZOR_API) do _G.reaper[name] = nil end end
installRazor()

local h   = require("harness")
local ctx = require("core.context")

-- Stateful module: clear focus-recency memory before each scenario.
local function fresh() ctx._resetRecency(); ctx._resetRazor(); reset(); installJS(); installRazor() end
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

-- ── razor areas ────────────────────────────────────────────────────────────────────────────────────
-- A razor area on the target lane is the range (it beats the time selection); a settled drag on one other
-- envelope lane reports razorSwitchTo exactly once. S.now drives reaper.time_precise (razor reads are
-- throttled to one per 0.1 s), S.mouse drives JS_Mouse_GetState.
local function lane(handle, guid, name) return { handle = handle, guid = guid, name = name or "Volume" } end
local function track(handle, name, razor, envs) return { handle = handle, name = name, razor = razor or "", envs = envs or {} } end
-- ENV_A {A} on "Lead", ENV_B {B} and ENV_P {P} on "Pad"; no razor areas yet.
local function project()
  S.tracks = {
    track("T1", "Lead", "", { lane("ENV_A", "{A}", "Volume") }),
    track("T2", "Pad",  "", { lane("ENV_B", "{B}", "Volume"), lane("ENV_P", "{P}", "Pan") }),
  }
end
local function spansEq(got, want, msg)
  h.eq(#got, #want, (msg or "") .. " span count")
  for i = 1, #want do
    h.almost(got[i][1], want[i][1], 1e-9, (msg or "") .. " t0 #" .. i)
    h.almost(got[i][2], want[i][2], 1e-9, (msg or "") .. " t1 #" .. i)
  end
end

-- detect() for the razor tests. The razor read runs inside a pcall: if it threw, detect() would degrade to
-- razor-off, which is exactly what the negative tests expect (razorLanes == {}, razorSwitchTo == nil,
-- rangeSource == "timesel"). Asserting there is no swallowed error keeps those tests honest.
local function rdet()
  local d = ctx.detect()
  h.eq(ctx._razorError, nil, "the razor read threw:")
  return d
end

h.test("razor on the selected envelope's lane becomes the range", function()
  fresh(); project(); S.env = "ENV_A"; S.timeSel = { 0, 10 }
  S.tracks[1].razor = '2 4 "{A}"'
  local d = rdet()
  h.eq(d.target, "envelope")
  h.eq(d.rangeSource, "razor")
  spansEq(d.ranges, { { 2, 4 } })
  h.eq(d.hasRange, true); h.eq(d.razorOutside, false)
  h.eq(d.hasTimeSel, true, "hasTimeSel is the time selection's, unchanged")
  h.almost(d.t0, 0); h.almost(d.t1, 10)
end)

h.test("[M8] GUIDs compare case-insensitively, whichever side is lower case", function()
  fresh(); project(); S.env = "ENV_A"; S.timeSel = { 0, 10 }
  S.tracks[1].razor = '2 4 "{a}"'                         -- razor string lower case, envelope GUID {A}
  local d = rdet()
  h.eq(d.rangeSource, "razor"); spansEq(d.ranges, { { 2, 4 } })
  h.eq(#d.razorLanes, 1); h.eq(d.razorLanes[1].env, "ENV_A")
  fresh(); project(); S.env = "ENV_A"; S.timeSel = { 0, 10 }
  S.tracks[1].envs[1].guid = "{a}"                        -- envelope GUID lower case, razor string {A}
  S.tracks[1].razor = '2 4 "{A}"'
  d = rdet()
  h.eq(d.rangeSource, "razor"); spansEq(d.ranges, { { 2, 4 } })
  h.eq(#d.razorLanes, 1); h.eq(d.razorLanes[1].env, "ENV_A")
  -- and a switch to a lane whose two spellings differ
  fresh(); project(); S.env = "ENV_A"
  S.tracks[2].envs[1].guid = "{b}"
  S.now = 0; rdet()
  S.now = 0.2; S.tracks[2].razor = '1 2 "{B}"'; rdet()
  S.now = 0.5; h.eq(rdet().razorSwitchTo, "ENV_B")
end)

h.test("no razor keeps the time selection as the range", function()
  fresh(); project(); S.env = "ENV_A"; S.timeSel = { 0, 10 }
  local d = rdet()
  h.eq(d.rangeSource, "timesel")
  spansEq(d.ranges, { { 0, 10 } })
  h.eq(d.hasRange, true); h.eq(d.razorOutside, false)
  h.eq(#d.razorLanes, 0); h.eq(d.razorSwitchTo, nil)
end)

h.test("no razor and no time selection: no ranges", function()
  fresh(); project(); S.env = "ENV_A"
  local d = rdet()
  h.eq(d.rangeSource, "timesel")
  h.eq(#d.ranges, 0); h.eq(d.hasRange, false); h.eq(d.razorOutside, false)
end)

h.test("a razor on another lane only keeps the time selection and lists that lane", function()
  fresh(); project(); S.env = "ENV_A"; S.timeSel = { 0, 10 }
  S.tracks[2].razor = '1 2 "{B}"'
  local d = rdet()
  h.eq(d.rangeSource, "timesel")
  spansEq(d.ranges, { { 0, 10 } })
  h.eq(#d.razorLanes, 1)
  h.eq(d.razorLanes[1].guid, "{B}"); h.eq(d.razorLanes[1].env, "ENV_B"); h.eq(d.razorLanes[1].label, "Pad: Volume")
end)

h.test("several areas on the target lane are merged and sorted into ranges", function()
  fresh(); project(); S.env = "ENV_A"; S.timeSel = { 0, 10 }
  S.tracks[1].razor = '6 8 "{A}" 1 2 "{A}" 2 3 "{A}"'
  local d = rdet()
  h.eq(d.rangeSource, "razor")
  spansEq(d.ranges, { { 1, 3 }, { 6, 8 } })
end)

h.test("ranges are copies: changing them never touches the next read", function()
  fresh(); project(); S.env = "ENV_A"
  S.tracks[1].razor = '2 4 "{A}"'
  local d1 = rdet(); d1.ranges[1][1] = 99
  local d2 = rdet()
  spansEq(d2.ranges, { { 2, 4 } })
end)

h.test("automation item: the razor is clamped to the item's bounds", function()
  fresh(); project(); S.env = "ENV_A"; S.aiCount = 1; S.aiSel[0] = true; S.aiPos = 3; S.aiLen = 2
  S.tracks[1].razor = '0 4 "{A}"'
  local d = rdet()
  h.eq(d.target, "ai")
  h.eq(d.rangeSource, "razor")
  spansEq(d.ranges, { { 3, 4 } })
  h.eq(d.razorOutside, false); h.eq(d.hasRange, true)
end)

h.test("[RF 4] an area that only touches the item's edge leaves no range: razorOutside", function()
  fresh(); project(); S.env = "ENV_A"; S.aiCount = 1; S.aiSel[0] = true; S.aiPos = 3; S.aiLen = 2
  S.timeSel = { 0, 10 }
  S.tracks[1].razor = '0 3 "{A}"'
  local d = rdet()
  h.eq(d.rangeSource, "razor", "the lane has a razor, even if all of it is clamped away")
  h.eq(#d.ranges, 0); h.eq(d.razorOutside, true); h.eq(d.hasRange, false)
  h.eq(d.hasTimeSel, true, "the time selection is still reported, just not used")
end)

h.test("[RF 5] a razor GUID with no envelope is left out of razorLanes and never switches", function()
  fresh(); project(); S.env = "ENV_A"
  rdet()                                  -- baseline read at now = 0
  S.now = 0.2; S.tracks[1].razor = '1 2 "{GONE}"'
  local d = rdet()
  h.eq(#d.razorLanes, 0); h.eq(d.razorSwitchTo, nil)
  S.now = 0.5; d = rdet()                 -- the change has settled; nothing resolves, so no switch
  h.eq(#d.razorLanes, 0); h.eq(d.razorSwitchTo, nil)
  h.eq(d.rangeSource, "timesel")
end)

h.test("a razor on the master track is a lane too: label Master", function()
  fresh(); project()
  S.master.envs = { lane("ENV_M", "{M}", "Volume") }
  S.master.razor = '1 2 "{M}"'
  local d = rdet()
  h.eq(#d.razorLanes, 1); h.eq(d.razorLanes[1].label, "Master: Volume"); h.eq(d.razorLanes[1].env, "ENV_M")
end)

h.test("an unnamed track is labelled Track N, 1-based", function()
  fresh(); project()
  S.tracks[2].name = ""
  S.tracks[2].razor = '1 2 "{P}"'
  local d = rdet()
  h.eq(d.razorLanes[1].label, "Track 2: Pan")
end)

h.test("razorLanes follow track order, then the order of the razor string", function()
  fresh(); project()
  S.tracks[1].razor = '1 2 "{A}"'
  S.tracks[2].razor = '1 2 "{P}" 1 2 "{B}"'
  local d = rdet()
  h.eq(#d.razorLanes, 3)
  h.eq(d.razorLanes[1].guid, "{A}"); h.eq(d.razorLanes[2].guid, "{P}"); h.eq(d.razorLanes[3].guid, "{B}")
end)

h.test("a take envelope uses the item lane of its track, clamped to the item", function()
  fresh(); project()
  S.env = "ENV_TAKE"; S.takeOf.ENV_TAKE = "TK"; S.takeItem.TK = { handle = "IT", track = "T1", pos = 2, len = 6 }
  S.tracks[1].razor = '0 4 ""'
  local d = rdet()
  h.eq(d.target, "envelope"); h.eq(d.details.take, "TK")
  h.eq(d.rangeSource, "razor")
  spansEq(d.ranges, { { 2, 4 } })
end)

h.test("a take envelope with the razor wholly outside its item: razorOutside", function()
  fresh(); project()
  S.env = "ENV_TAKE"; S.takeOf.ENV_TAKE = "TK"; S.takeItem.TK = { handle = "IT", track = "T1", pos = 2, len = 6 }
  S.timeSel = { 0, 10 }
  S.tracks[1].razor = '0 1 ""'
  local d = rdet()
  h.eq(d.rangeSource, "razor"); h.eq(#d.ranges, 0); h.eq(d.razorOutside, true); h.eq(d.hasRange, false)
end)

h.test("a take envelope ignores razors on envelope lanes and on other tracks", function()
  fresh(); project()
  S.env = "ENV_TAKE"; S.takeOf.ENV_TAKE = "TK"; S.takeItem.TK = { handle = "IT", track = "T1", pos = 2, len = 6 }
  S.timeSel = { 0, 10 }
  S.tracks[1].razor = '3 4 "{A}"'
  S.tracks[2].razor = '3 4 ""'
  local d = rdet()
  h.eq(d.rangeSource, "timesel"); spansEq(d.ranges, { { 0, 10 } })
end)

h.test("MIDI CC always uses the time selection, whatever the razor says", function()
  fresh(); project(); S.me, S.take = ME, "TAKE"; S.selCC = true; S.focus = MIDIVIEW; S.timeSel = { 1, 5 }
  S.tracks[1].razor = '2 4 "{A}" 2 4 ""'
  local d = rdet()
  h.eq(d.target, "cc")
  h.eq(d.rangeSource, "timesel"); spansEq(d.ranges, { { 1, 5 } })
end)

h.test("switch fires once, after the change has settled", function()
  fresh(); project(); S.env = "ENV_A"
  S.now = 0;   h.eq(rdet().razorSwitchTo, nil, "baseline read")
  S.now = 0.2; S.tracks[2].razor = '1 2 "{B}"'
  h.eq(rdet().razorSwitchTo, nil, "just changed")
  S.now = 0.5; h.eq(rdet().razorSwitchTo, "ENV_B", "stable for 0.3 s")
  S.now = 0.7; h.eq(rdet().razorSwitchTo, nil, "only once")
  S.now = 1.5; h.eq(rdet().razorSwitchTo, nil, "still only once")
end)

h.test("switch waits for the mouse button to come up", function()
  fresh(); project(); S.env = "ENV_A"
  S.now = 0;   rdet()
  S.now = 0.2; S.tracks[2].razor = '1 2 "{B}"'; rdet()
  S.now = 0.5; S.mouse = 1
  h.eq(rdet().razorSwitchTo, nil, "left button still down")
  S.now = 0.6; S.mouse = 0
  h.eq(rdet().razorSwitchTo, "ENV_B", "released and stable")
end)

h.test("without js_ReaScriptAPI stability alone decides", function()
  fresh(); project(); S.env = "ENV_A"
  _G.reaper.JS_Mouse_GetState = nil
  S.now = 0;   rdet()
  S.now = 0.2; S.tracks[2].razor = '1 2 "{B}"'; rdet()
  S.now = 0.5; h.eq(rdet().razorSwitchTo, "ENV_B")
end)

h.test("a change that keeps moving does not switch until it stops", function()
  fresh(); project(); S.env = "ENV_A"
  S.now = 0; rdet()
  S.now = 0.2; S.tracks[2].razor = '1 2 "{B}"'; rdet()
  S.now = 0.4; S.tracks[2].razor = '1 3 "{B}"'; h.eq(rdet().razorSwitchTo, nil, "still dragging")
  S.now = 0.6; S.tracks[2].razor = '1 4 "{B}"'; h.eq(rdet().razorSwitchTo, nil, "still dragging")
  S.now = 0.9; h.eq(rdet().razorSwitchTo, "ENV_B", "stopped for 0.3 s")
end)

h.test("[RF 3] two lanes of one drag never switch", function()
  fresh(); project(); S.env = "ENV_A"
  S.now = 0; rdet()
  S.now = 0.2; S.tracks[2].razor = '1 2 "{B}" 1 2 "{P}"'
  local d = rdet()
  h.eq(#d.razorLanes, 2)
  S.now = 0.5; d = rdet()
  h.eq(d.razorSwitchTo, nil); h.eq(#d.razorLanes, 2)
  S.now = 0.8; h.eq(rdet().razorSwitchTo, nil)
end)

h.test("[F1] a drag over two lanes never switches, even when one lane already had that span", function()
  fresh(); project(); S.env = "ENV_A"
  S.tracks[1].razor = '1 3 "{A}"'                      -- Lead: Volume already has 1..3 s
  S.now = 0; rdet()
  S.now = 0.2; S.tracks[2].razor = '1 3 "{B}"'         -- the drag 1..3 s over Lead + Pad changes only Pad
  h.eq(#rdet().razorLanes, 2)
  S.now = 0.5; h.eq(rdet().razorSwitchTo, nil, "one changed lane, but two lanes share the span")
  S.now = 1.0; h.eq(rdet().razorSwitchTo, nil)
end)

h.test("[F1] without js: a pause on one lane switches, the continuation to two lanes does not", function()
  fresh(); project(); S.env = "ENV_A"
  _G.reaper.JS_Mouse_GetState = nil
  S.now = 0; rdet()
  S.now = 0.2; S.tracks[2].razor = '1 3 "{B}"'; rdet()
  S.now = 0.5; h.eq(rdet().razorSwitchTo, "ENV_B", "a pause of 0.3 s on Pad alone switches to Pad")
  S.now = 0.7; S.tracks[2].razor = '1 3 "{B}" 1 3 "{P}"'; rdet()    -- the drag goes on to a second lane
  S.now = 1.0; h.eq(rdet().razorSwitchTo, nil, "the same span on a second lane: no second switch")
  S.now = 1.5; h.eq(rdet().razorSwitchTo, nil)
end)

h.test("a new area on one lane switches even when another lane already has areas", function()
  fresh(); project(); S.env = "ENV_A"
  S.tracks[1].razor = '1 2 "{A}"'
  S.now = 0; rdet()
  S.now = 0.2; S.tracks[2].razor = '5 6 "{P}"'; rdet()
  S.now = 0.5; h.eq(rdet().razorSwitchTo, "ENV_P")
end)

h.test("a removed area never switches", function()
  fresh(); project(); S.env = "ENV_A"
  S.tracks[2].razor = '1 2 "{B}"'
  S.now = 0; rdet()
  S.now = 0.2; S.tracks[2].razor = ""; rdet()
  S.now = 0.5; h.eq(rdet().razorSwitchTo, nil)
end)

h.test("item-lane areas never switch", function()
  fresh(); project(); S.env = "ENV_A"
  S.now = 0; rdet()
  S.now = 0.2; S.tracks[2].razor = '1 2 ""'; rdet()
  S.now = 0.5; h.eq(rdet().razorSwitchTo, nil)
end)

h.test("areas present at the start do not switch", function()
  fresh(); project(); S.env = "ENV_A"
  S.tracks[2].razor = '1 2 "{B}"'
  for _, t in ipairs({ 0, 0.2, 0.5, 1.0 }) do
    S.now = t; h.eq(rdet().razorSwitchTo, nil, "at " .. t)
  end
end)

h.test("razor reads are throttled to one per 0.1 s", function()
  fresh(); project(); S.env = "ENV_A"; S.timeSel = { 0, 10 }
  S.now = 1.0; h.eq(rdet().rangeSource, "timesel")
  S.tracks[1].razor = '2 4 "{A}"'
  S.now = 1.05; h.eq(rdet().rangeSource, "timesel", "inside the throttle window: last snapshot")
  S.now = 1.12; h.eq(rdet().rangeSource, "razor", "window over: fresh read")
end)

h.test("a clock that jumps back forces a fresh read", function()
  fresh(); project(); S.env = "ENV_A"
  S.now = 50; rdet()
  S.tracks[1].razor = '2 4 "{A}"'
  S.now = 1;  h.eq(rdet().rangeSource, "razor")
end)

h.test("without time_precise every call reads", function()
  fresh(); project(); S.env = "ENV_A"
  _G.reaper.time_precise = nil
  h.eq(rdet().rangeSource, "timesel")
  S.tracks[1].razor = '2 4 "{A}"'
  h.eq(rdet().rangeSource, "razor")
end)

h.test("_resetRazor forgets the baseline: areas present afterwards do not switch either", function()
  fresh(); project(); S.env = "ENV_A"
  S.now = 0; rdet()
  S.now = 0.2; S.tracks[2].razor = '1 2 "{B}"'; rdet()
  ctx._resetRazor()
  S.now = 0.5; h.eq(rdet().razorSwitchTo, nil, "first read after the reset is a baseline")
  S.now = 1.0; h.eq(rdet().razorSwitchTo, nil)
end)

h.test("engageArrange makes the arrange side win over a lingering CC selection", function()
  fresh(); bothOpen(); S.selCC = true
  S.focus = "CONTOUR"
  h.eq(det(), "cc", "no recency yet: a selected CC beats the envelope")
  ctx.engageArrange()
  h.eq(det(), "envelope", "engaged arrange: the selected envelope wins")
end)

h.test("no razor API: razor support is off, the time selection is the range", function()
  fresh(); project(); S.env = "ENV_A"; S.timeSel = { 0, 10 }
  S.tracks[1].razor = '2 4 "{A}"'
  removeRazor()
  local d = rdet()
  h.eq(d.rangeSource, "timesel"); spansEq(d.ranges, { { 0, 10 } })
  h.eq(d.hasRange, true); h.eq(d.razorOutside, false)
  h.eq(#d.razorLanes, 0); h.eq(d.razorSwitchTo, nil)
  S.timeSel = { 0, 0 }
  d = rdet()
  h.eq(#d.ranges, 0); h.eq(d.hasRange, false)
end)

h.test("a razor read that throws degrades to razor-off instead of breaking detect", function()
  fresh(); project(); S.env = "ENV_A"; S.timeSel = { 0, 10 }
  S.tracks[1].razor = '2 4 "{A}"'
  _G.reaper.GetSetMediaTrackInfo_String = function() error("boom") end
  local d = ctx.detect()
  h.eq(d.target, "envelope"); h.eq(d.rangeSource, "timesel"); spansEq(d.ranges, { { 0, 10 } })
  h.eq(#d.razorLanes, 0); h.eq(d.razorSwitchTo, nil)
  h.truthy(tostring(ctx._razorError):find("boom"), "the error is kept for inspection")
end)

h.run()
