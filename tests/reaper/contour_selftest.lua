-- @noindex
--
-- tests/reaper/contour_selftest.lua — Contour IN-REAPER integration self-test (Tier 2).
--
-- Run this from REAPER's Action list (Actions > Show action list > "ReaScript: Load..." > pick this
-- file > Run), or bind it to a key. It validates Contour's REAL write->read round-trip against the
-- LIVE REAPER API — the layer the headless tests (tests/test_*.lua) can only approximate with stubs.
-- It creates its OWN scratch track + objects, asserts what REAPER actually stored matches what Contour
-- intended, prints a PASS/FAIL report to the ReaScript console (and a message box), then DELETES the
-- scratch track so your project is left untouched. Safe to run on any open project.
--
-- What it covers (the things stubs can lie about):
--   * Track ENVELOPE round-trip (Pan, non-scaled): InsertEnvelopePoint/CountEnvelopePoints/GetEnvelopePoint
--     contracts + the CC->ENV shape swap (0<->1) on a real envelope.
--   * MIDI CC round-trip: MIDI_InsertCC + MIDI_SetCCShape + MIDI_GetCC against a real take.
--   * AUTOMATION ITEM round-trip: the *Ex point family + item-bounds handling.
--   * RAZOR AREA round-trip: P_RAZOREDITS on a Volume lane -> context.detect() -> Generate writes only
--     inside the razor span.
--
-- This is NOT part of the shipped package (it lives under tests/, not in contour.lua's @provides).

local sep = package.config:sub(1, 1)
local src = debug.getinfo(1, "S").source:match("^@?(.*[/\\])") or ("." .. sep)
-- repo root = up two dirs from tests/reaper/ ; Contour modules live in <root>/Contour/
package.path = src .. ".." .. sep .. ".." .. sep .. "Contour" .. sep .. "?.lua;" .. package.path

local okReq, target = pcall(require, "core.target")
local okReq2, lfo   = pcall(require, "core.lfo")
if not (okReq and okReq2) then
  reaper.ShowMessageBox("Could not load Contour core modules from:\n" .. src ..
    "\n\nRun this script from inside the repo's tests/reaper/ folder so it can find ../../Contour/.",
    "Contour self-test", 0)
  return
end

-- ---- tiny console assertion harness --------------------------------------------------------------
local results = {}
local function check(cond, msg) if not cond then error(msg or "assertion failed", 2) end end
local function approx(a, b, tol) return math.abs(a - b) <= (tol or 1e-3) end
local function suite(name, fn)
  local ok, err = pcall(fn)
  results[#results + 1] = { name = name, ok = ok, msg = ok and "OK" or tostring(err) }
end

-- nearest-time match: every written point must reappear (within tol) on read-back, same count.
local function assertRoundTrip(label, written, readback, valTol, timeTol)
  check(#readback == #written, label .. (": count %d, expected %d"):format(#readback, #written))
  local function byTime(a, b) return a.time < b.time end
  table.sort(written, byTime); table.sort(readback, byTime)
  for i = 1, #written do
    local w, r = written[i], readback[i]
    check(approx(r.time, w.time, timeTol or 0.02), label .. (": point %d time %.4f != %.4f"):format(i, r.time, w.time))
    check(approx(r.value, w.value, valTol or 1e-3), label .. (": point %d value %.4f != %.4f"):format(i, r.value, w.value))
  end
end

-- ---- scratch project setup -----------------------------------------------------------------------
reaper.PreventUIRefresh(1)
reaper.Undo_BeginBlock()

local trackIdx = reaper.CountTracks(0)
reaper.InsertTrackAtIndex(trackIdx, true)
local track = reaper.GetTrack(0, trackIdx)

-- A non-scaled Pan envelope (storage domain == linear == [-1,1]) keeps the value round-trip exact.
local function ensurePanEnv()
  reaper.SetOnlyTrackSelected(track)
  local env = reaper.GetTrackEnvelopeByName(track, "Pan")
  if not env then
    reaper.Main_OnCommand(40407, 0)  -- Track: Toggle track pan envelope visible
    env = reaper.GetTrackEnvelopeByName(track, "Pan")
  end
  check(env, "could not create a Pan envelope (action 40407 may differ on this REAPER build)")
  local mode = reaper.GetEnvelopeScalingMode(env)
  check(mode == 0, "Pan envelope is unexpectedly scaled (mode " .. tostring(mode) .. ")")
  return env
end

-- ---- ENVELOPE round-trip -------------------------------------------------------------------------
suite("envelope: value round-trip (Pan, rawShape)", function()
  local env = ensurePanEnv()
  local tgt = assert(target.fromContext({ target = "envelope", details = { env = env } }))
  local vmin, vmax = tgt:valueRange()
  check(approx(vmin, -1) and approx(vmax, 1), ("Pan range %.2f..%.2f, expected -1..1"):format(vmin, vmax))
  -- interior points (no edge insets) at known values, native ENV linear shape (0)
  local written = {
    { time = 1.0, value = -0.8, shape = 0 }, { time = 1.5, value = -0.3, shape = 0 },
    { time = 2.0, value =  0.0, shape = 0 }, { time = 2.5, value =  0.4, shape = 0 },
    { time = 3.0, value =  0.8, shape = 0 },
  }
  local copy = {}; for i, p in ipairs(written) do copy[i] = { time = p.time, value = p.value, shape = p.shape } end
  local n = assert(tgt:write(copy, 0.5, 3.5, { rawShape = true }))
  check(n == 5, "wrote " .. tostring(n) .. " points, expected 5")
  local readback = tgt:read(0.4, 3.6)
  assertRoundTrip("envelope", written, readback)
end)

suite("envelope: CC->ENV shape swap (0<->1) on a real envelope", function()
  local env = ensurePanEnv()
  local tgt = assert(target.fromContext({ target = "envelope", details = { env = env } }))
  -- NON-raw (Generate path): CC square(0) -> ENV 1 ; CC linear(1) -> ENV 0.
  local n = assert(tgt:write({
    { time = 1.2, value = 0.1, shape = 0 },   -- CC square
    { time = 2.2, value = 0.2, shape = 1 },   -- CC linear
  }, 0.5, 3.5, {}))
  check(n == 2, "wrote " .. tostring(n))
  local rb = tgt:read(0.4, 3.6)
  table.sort(rb, function(a, b) return a.time < b.time end)
  check(rb[1].shape == 1, "CC square(0) should store as ENV 1, got " .. tostring(rb[1].shape))
  check(rb[2].shape == 0, "CC linear(1) should store as ENV 0, got " .. tostring(rb[2].shape))
end)

-- ---- RAZOR AREA round-trip -----------------------------------------------------------------------
-- A razor area on the target envelope's lane is the range for Generate (it beats the time selection).
-- Covers what stubs can lie about: the live P_RAZOREDITS string REAPER stores, the envelope GUID that
-- string must name, context.detect() resolving the selected envelope's lane to it, and Generate writing
-- only inside the razor span. Uses the track's Volume envelope; the lane's razor is always cleared after.
suite("razor area: detect + Generate write only inside the razor span (Volume lane)", function()
  local okCtx, context  = pcall(require, "core.context")
  local okGen, generate = pcall(require, "ui.generate")
  check(okCtx,  "could not load core.context: " .. tostring(context))
  check(okGen,  "could not load ui.generate: " .. tostring(generate))

  -- 1. the track's Volume envelope, visible
  reaper.SetOnlyTrackSelected(track)
  local env = reaper.GetTrackEnvelopeByName(track, "Volume")
  if not env then
    reaper.Main_OnCommand(40406, 0)  -- Track: Toggle track volume envelope visible
    env = reaper.GetTrackEnvelopeByName(track, "Volume")
  end
  check(env, "could not create a Volume envelope (action 40406 may differ on this REAPER build)")
  reaper.DeleteEnvelopePointRange(env, -1, 1e6)   -- start from an empty lane so every point is Generate's

  -- 2. its GUID
  local okGuid, guid = reaper.GetSetEnvelopeInfo_String(env, "GUID", "", false)
  check(okGuid and guid and guid ~= "", "GetSetEnvelopeInfo_String(GUID) returned nothing")

  local function clearRazor() reaper.GetSetMediaTrackInfo_String(track, "P_RAZOREDITS", "", true) end
  local okRun, err = pcall(function()
    -- 3. a razor area 1..2 s on that lane
    local razor = ('1.0 2.0 "%s"'):format(guid)
    reaper.GetSetMediaTrackInfo_String(track, "P_RAZOREDITS", razor, true)
    local _, stored = reaper.GetSetMediaTrackInfo_String(track, "P_RAZOREDITS", "", false)
    check(stored and stored:find(guid, 1, true), "REAPER did not store the razor area (read back: " .. tostring(stored) .. ")")

    -- 4. select the envelope; detect() must report the razor as the range source
    reaper.SetCursorContext(2, env)
    if context.engageArrange then context.engageArrange() end   -- a lingering MIDI editor selection must not win
    local det = context.detect()
    check(det.target == "envelope" and det.details and det.details.env == env,
      "detect() did not resolve the selected Volume envelope (target=" .. tostring(det.target) .. ")")
    check(det.rangeSource == "razor", "rangeSource is " .. tostring(det.rangeSource) .. ", expected razor")
    check(det.ranges and #det.ranges == 1, "expected exactly one razor range, got " .. tostring(det.ranges and #det.ranges))
    check(approx(det.ranges[1][1] or det.ranges[1].t0, 1.0) and approx(det.ranges[1][2] or det.ranges[1].t1, 2.0),
      "razor range is not 1..2")

    -- 5. Generate Sine; every point lies in [1, 2]
    local g = {
      shapeIdx = 1,   -- Sine
      rateMode = 1, cycles = 4, hz = 1,
      lengthIdx = 6, feelIdx = 0, freqIdx = 8, ccNum = 1,
      baseline = 0, amplitude = 50, tilt = 0, tiltR = 0, phase = 0,
      ampSkew = 0, pulseWidth = 0.5, freqSkew = 0, swing = 0, seed = 1,
      smooth = 0, steps = 0, curve = 0, attack = 50, edge = 50,
      scope = 0,
    }
    generate.run({}, det, g)
    check(not g.statusErr, "Generate failed: " .. tostring(g.status))
    local n = reaper.CountEnvelopePoints(env)
    check(n > 0, "Generate wrote no points on the razor lane (" .. tostring(g.status) .. ")")
    for i = 0, n - 1 do
      local _, tm = reaper.GetEnvelopePoint(env, i)
      check(tm >= 1.0 - 1e-6 and tm <= 2.0 + 1e-6, ("point %d at %.4f s lies outside the razor span 1..2"):format(i, tm))
    end
  end)
  clearRazor()   -- 6. never leave a razor behind, pass or fail
  if not okRun then error(err, 0) end
end)

-- ---- MIDI CC round-trip --------------------------------------------------------------------------
suite("MIDI CC: value + per-point shape round-trip", function()
  local item = reaper.CreateNewMIDIItemInProj(track, 0, 4)
  check(item, "CreateNewMIDIItemInProj returned nil")
  local take = reaper.GetActiveTake(item)
  check(take, "no active take on the MIDI item")
  local LANE = 11
  -- fromContext resolves the lane from a live MIDI editor; here we target a known lane directly.
  local tgt = target.CC.new(take, nil, LANE, 0)
  local written = {
    { time = 0.5, value = 20,  shape = 1 },   -- linear
    { time = 1.5, value = 64,  shape = 0 },   -- square
    { time = 2.5, value = 100, shape = 2 },   -- slow start/end
    { time = 3.5, value = 40,  shape = 1 },
  }
  local copy = {}; for i, p in ipairs(written) do copy[i] = { time = p.time, value = p.value, shape = p.shape } end
  local n = assert(tgt:write(copy, 0, 4, {}))
  check(n == 4, "wrote " .. tostring(n) .. " CC events, expected 4")
  local rb = tgt:read(-0.1, 4.1)
  assertRoundTrip("cc", written, rb, 0.5, 0.03)   -- CC values are integers; time tol a bit looser (tick rounding)
  table.sort(rb, function(a, b) return a.time < b.time end)
  for i = 1, #written do
    check(rb[i].shape == written[i].shape, ("cc: point %d shape %d != %d"):format(i, rb[i].shape, written[i].shape))
  end
end)

-- ---- AUTOMATION ITEM round-trip ------------------------------------------------------------------
suite("automation item: value round-trip (*Ex point family)", function()
  local env = ensurePanEnv()
  local aiIdx = reaper.InsertAutomationItem(env, -1, 5.0, 4.0)   -- new AI, bounds [5,9]
  check(aiIdx and aiIdx >= 0, "InsertAutomationItem failed (" .. tostring(aiIdx) .. ")")
  local tgt = assert(target.fromContext({ target = "ai", details = { env = env, aiIndex = aiIdx } }))
  local lo, hi = tgt:bounds()
  check(approx(lo, 5.0) and approx(hi, 9.0), ("AI bounds %.2f..%.2f, expected 5..9"):format(lo, hi))
  local written = {
    { time = 5.5, value = -0.6, shape = 0 },
    { time = 7.0, value =  0.2, shape = 0 },
    { time = 8.5, value =  0.7, shape = 0 },
  }
  local copy = {}; for i, p in ipairs(written) do copy[i] = { time = p.time, value = p.value, shape = p.shape } end
  local n = assert(tgt:write(copy, 5.2, 8.8, { rawShape = true }))
  check(n == 3, "wrote " .. tostring(n) .. " AI points, expected 3")
  local rb = tgt:read(5.1, 8.9)
  assertRoundTrip("ai", written, rb, 1e-3, 0.02)
end)

-- ---- teardown ------------------------------------------------------------------------------------
pcall(reaper.DeleteTrack, track)
reaper.Undo_EndBlock("Contour self-test (scratch track removed)", -1)
reaper.PreventUIRefresh(-1)
reaper.UpdateArrange()

-- ---- report --------------------------------------------------------------------------------------
local lines = { "", "Contour in-REAPER self-test", "===========================" }
local pass, fail = 0, 0
for _, r in ipairs(results) do
  if r.ok then pass = pass + 1; lines[#lines + 1] = "PASS  " .. r.name
  else fail = fail + 1; lines[#lines + 1] = "FAIL  " .. r.name .. "\n        " .. r.msg end
end
lines[#lines + 1] = ""
lines[#lines + 1] = ("%d passed, %d failed"):format(pass, fail)
lines[#lines + 1] = ""
local report = table.concat(lines, "\n")
reaper.ShowConsoleMsg(report .. "\n")
reaper.ShowMessageBox(report, "Contour self-test", 0)
