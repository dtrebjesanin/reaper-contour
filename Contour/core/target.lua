-- core/target.lua — a target abstraction wrapping a concrete REAPER write surface.
-- This is the ONE Reaper-bound module in core/ (lfo/shapes/reduce stay pure & headless).
-- Implements three write surfaces: MIDI CC, track envelope, and automation item (pooled, via the
-- *Ex point functions). All share the range-agnostic %-based value model the Generate UI drives.
--
-- target.fromContext(detected) -> (targetObj, errString)
--   On success returns (targetObj, nil); on failure returns (nil, "message").
--
-- CC target methods:
--   :kind()                  -> "cc"
--   :valueRange()            -> 0, 127        (standard 7-bit lanes)
--   :write(points, t0, t1, opts) -> (count, errString)
--        REPLACE this lane+channel's CC events within project-time [t0,t1] with `points`
--        ({ {time=,value=}, ... }), wrapped in a single undo block. Values are clamped to
--        0..127 then FLOORED to integer (native truncates: 31.75 -> 31). Returns
--        (#written, nil) or (nil, "message").
--        opts (optional) = {
--          ccShape       = integer 0..5 MIDI CC shape applied to inserted events
--                          (0=square/step, 1=linear, 2=slow start/end, 3=fast start,
--                           4=fast end, 5=bezier). Default 1 (linear) — backward compatible.
--          bezierTension = number passed to MIDI_SetCCShape (default 0.0).
--          noUndo        = boolean; when true, DO NOT open/close an undo block here. The
--                          CALLER owns one outer Undo_BeginBlock2/EndBlock2 pair that spans
--                          many writes (live-preview drag => one undo point). NOTE (v2.2 T4):
--                          MarkTrackItemsDirty is NOT called per-frame when noUndo=true — it
--                          forces a synchronous arrange-view overview rebuild every frame
--                          (the navigation-bar FLASH). MIDI_SetAllEvts refreshes the open
--                          MIDI editor on its own, so the live display still updates. The
--                          caller (endLiveGesture) calls MarkTrackItemsDirty ONCE at gesture
--                          end so the coalesced flags=4 (UNDO_STATE_ITEMS) block snapshots the
--                          change and the entry is visible in the Undo History. When
--                          noUndo=false (self-contained write, slice-3 / Generate-button
--                          behavior) MarkTrackItemsDirty IS called here (the only dirty call).
--                          Default false.
--        }
local M = {}

local midistream = require("core.midistream")

local floor, min, max = math.floor, math.min, math.max

-- last_clicked_cc_lane encoding (see MIDIEditor_GetSetting_int):
--   -1            = no CC lane clicked
--   0..127        = standard 7-bit CC lane (value IS the CC number)
--   0x100..0x11F  = 14-bit CC (256-287) — not supported this slice
--   >= 0x200      = velocity/pitch/program/etc. special lanes — not supported this slice
local CC_STATUS = 0xB0   -- control-change status byte (channel bits zeroed)

-- Native CC LFO TRUNCATES (floors) values, not rounds: 31.75 -> 31, NOT 32.
-- We clamp to [0,127] first, then math.floor, to match REAPER's native output to the
-- integer (Generate v2.4). (Was floor(v+0.5) = round in slice 3; changed to floor.)
local function clampCC(v)
  if v < 0 then v = 0 elseif v > 127 then v = 127 end
  return floor(v)
end

-- Resolve the active CC lane number from the MIDI editor. Returns (laneNum, errString):
--   laneNum is a 0..127 CC number on success; nil + message otherwise.
local function activeCCLane(midiEditor)
  if not midiEditor then return nil, "No active MIDI editor" end
  local lane = reaper.MIDIEditor_GetSetting_int(midiEditor, "last_clicked_cc_lane")
  if lane == nil or lane < 0 then
    return nil, "Select a MIDI CC lane"
  end
  if lane >= 0x100 then
    return nil, "Standard CC lanes (0-127) only for now"
  end
  return lane, nil
end

------------------------------------------------------------------------------
-- MIDI CC target
------------------------------------------------------------------------------
local CC = {}
CC.__index = CC

function CC.new(take, midiEditor, lane, chan)
  return setmetatable({
    _take    = take,
    _editor  = midiEditor,
    _lane    = lane,            -- CC number 0..127
    _chan    = chan or 0,       -- 0-based MIDI channel
  }, CC)
end

function CC:kind() return "cc" end

function CC:valueRange() return 0, 127 end

-- CC number resolved from the editor at construction (panel may override the write target).
function CC:lane() return self._lane end

function CC:channel() return self._chan end

-- fullSpan() -> t0, t1 (project seconds): the target's "entire" extent for the Entire-item scope.
-- For CC that is the MIDI item's project bounds.
function CC:fullSpan()
  local take = self._take
  if not take then return nil end
  local item = reaper.GetMediaItemTake_Item(take)
  if not item then return nil end
  local pos = reaper.GetMediaItemInfo_Value(item, "D_POSITION")
  local len = reaper.GetMediaItemInfo_Value(item, "D_LENGTH")
  if not pos or not len or len <= 0 then return nil end
  return pos, pos + len
end

-- Read this lane+channel's CC events as { {time, value, shape, tension, sel}, ... } (time-ascending;
-- shapes in CC convention; tension = bezier tension for curve shapes; sel = the event's selected flag).
-- Used by Reduce. A nil t0 means no lower bound and a
-- nil t1 no upper bound, so read(nil, nil) returns the WHOLE lane (used by the "Selected points" scope
-- to locate selected events anywhere).
function CC:read(t0, t1)
  local take = self._take
  if not take then return {} end
  if not (reaper.MIDI_GetCC and reaper.MIDI_CountEvts) then return {} end
  local lane, chan = self._lane, self._chan or 0
  local ppq0 = (t0 ~= nil and reaper.MIDI_GetPPQPosFromProjTime) and reaper.MIDI_GetPPQPosFromProjTime(take, t0) or nil
  local ppq1 = (t1 ~= nil and reaper.MIDI_GetPPQPosFromProjTime) and reaper.MIDI_GetPPQPosFromProjTime(take, t1) or nil
  local _, _, ccCount = reaper.MIDI_CountEvts(take)
  local out = {}
  for i = 0, (ccCount or 0) - 1 do
    local ok, sel, _, ppqpos, chanmsg, ch, msg2, msg3 = reaper.MIDI_GetCC(take, i)
    if ok and chanmsg == CC_STATUS and ch == chan and msg2 == lane
       and (not ppq0 or ppqpos >= ppq0) and (not ppq1 or ppqpos <= ppq1) then
      local shape, tension = 1, 0
      if reaper.MIDI_GetCCShape then
        local okS, shp, tens = reaper.MIDI_GetCCShape(take, i)  -- (ok, shape, beztension)
        if okS and shp then shape = shp; tension = tens or 0 end
      end
      out[#out + 1] = { time = reaper.MIDI_GetProjTimeFromPPQPos(take, ppqpos),
                        value = msg3, shape = shape, tension = tension, sel = sel and true or false, _ppq = ppqpos }
    end
  end
  table.sort(out, function(a, b) return a._ppq < b._ppq end)
  return out
end

-- Delete this lane+channel's CC events whose ppq is within [ppq0, ppq1].
-- Collect-then-delete-descending avoids the index-shift bug of forward ascending deletes.
local function deleteCCInRange(take, lane, chan, ppq0, ppq1)
  local _, _, ccCount = reaper.MIDI_CountEvts(take)
  local toDelete = {}
  for i = 0, (ccCount or 0) - 1 do
    local ok, _, _, ppqpos, chanmsg, ch, msg2 = reaper.MIDI_GetCC(take, i)
    if ok and chanmsg == CC_STATUS and ch == chan and msg2 == lane
       and ppqpos >= ppq0 and ppqpos <= ppq1 then
      toDelete[#toDelete + 1] = i
    end
  end
  for j = #toDelete, 1, -1 do
    reaper.MIDI_DeleteCC(take, toDelete[j])
  end
end

-- Assign each point a STRICTLY-INCREASING integer ppq tick: clamp to [ppq0, ppq1-1], round
-- (floor(ppq+0.5) — matching encodeMerged), then bump any tick that ties the previous one to prev+1.
-- This stops two near-coincident points — e.g. a saw's reset (peak + instant drop) at short spans —
-- from landing on the SAME tick, which REAPER drew as a STACKED DUPLICATE CC ("square" block) with a
-- scrambled within-tick order (the user-reported "saw/pump look like squares"). Points are processed
-- in TIME order (CC events are tick-positioned, so insertion order is irrelevant); the result is
-- stored on pt._tick for both the writer and applyPointShapes. Mutates the point tables.
local function assignTicks(take, points, ppq0, ppq1)
  local floor = math.floor
  local ordered = {}
  for i = 1, #points do ordered[i] = points[i] end
  table.sort(ordered, function(a, b) return (a.time or 0) < (b.time or 0) end)
  local lastTick
  for _, pt in ipairs(ordered) do
    local ppq = reaper.MIDI_GetPPQPosFromProjTime(take, pt.time)
    if ppq > ppq1 - 1 then ppq = ppq1 - 1 elseif ppq < ppq0 then ppq = ppq0 end
    local tick = floor(ppq + 0.5)
    if lastTick and tick <= lastTick then tick = lastTick + 1 end
    lastTick = tick
    pt._tick = tick
  end
end

-- Apply each written point's CC interpolation shape (Sine: slow start/end; Parametric: fast eases;
-- Saw/Triangle: linear; Square: step). REAPER only RENDERS a CC's shape once MIDI_SetCCShape is called,
-- so we set it explicitly. Match each event to its shape by its PPQ TICK (assignTicks made them unique
-- on pt._tick), so it is position- and count-independent. Guarded: skips if the API is absent.
local function applyPointShapes(take, chan, lane, ppq0, ppq1, points)
  if not reaper.MIDI_SetCCShape then return end
  local floor = math.floor
  local byTick = {}
  for _, pt in ipairs(points) do
    local tick = pt._tick
    if not tick then
      local ppq = reaper.MIDI_GetPPQPosFromProjTime(take, pt.time)
      if ppq > ppq1 - 1 then ppq = ppq1 - 1 elseif ppq < ppq0 then ppq = ppq0 end
      tick = floor(ppq + 0.5)
    end
    byTick[tick] = { shape = pt.shape or 1, tension = pt.tension or 0.0 }
  end
  local _, _, ccCount = reaper.MIDI_CountEvts(take)
  for i = 0, (ccCount or 0) - 1 do
    local ok, _, _, ppqpos, chanmsg, ch, msg2 = reaper.MIDI_GetCC(take, i)
    if ok and chanmsg == CC_STATUS and ch == chan and msg2 == lane
       and ppqpos >= ppq0 and ppqpos <= ppq1 then
      local s = byTick[floor(ppqpos + 0.5)]
      if s then reaper.MIDI_SetCCShape(take, i, s.shape, s.tension, true) end
    end
  end
  reaper.MIDI_Sort(take)
end

-- REPLACE-in-range write. points = { {time=<sec>, value=<num>}, ... } in project time.
-- opts (optional): { ccShape=int 0..5, bezierTension=num, noUndo=bool } — see header.
function CC:write(points, t0, t1, opts)
  opts = opts or {}
  local take = self._take
  if not take then return nil, "No MIDI take" end

  -- The panel's CC# (self._lane) is the authoritative write target; validate it directly.
  local writeLane = self._lane
  if writeLane == nil or writeLane < 0 or writeLane > 127 then
    return nil, "Standard CC lanes (0-127) only for now"
  end

  local chan    = self._chan or 0
  local ccShape = opts.ccShape or 1        -- default linear = backward compatible
  local tension = opts.bezierTension or 0.0
  if not points or #points == 0 then return 0, nil end

  local ppq0 = reaper.MIDI_GetPPQPosFromProjTime(take, t0)
  local ppq1 = reaper.MIDI_GetPPQPosFromProjTime(take, t1)

  -- The actual replace-in-range body. Runs inside pcall so a thrown Reaper call can never
  -- leave an undo block open (the undo block, when used, is always closed below).
  local function body()
    -- Clear the existing lane+channel CCs across the full range first (Replace mode).
    deleteCCInRange(take, writeLane, chan, ppq0, ppq1)

    -- Strictly-increasing ticks (clamped 1 tick inside the selection so the last point's trailing
    -- segment isn't clipped). De-colliding here keeps a saw's reset (peak + drop) on two ticks
    -- instead of stacking a duplicate CC on one tick.
    assignTicks(take, points, ppq0, ppq1)
    local written = 0
    for _, pt in ipairs(points) do
      local val = clampCC(pt.value)
      if reaper.MIDI_InsertCC(take, pt.sel and true or false, false, pt._tick, CC_STATUS, chan, writeLane, val) then
        written = written + 1
      end
    end

    reaper.MIDI_Sort(take)

    -- Apply each point's native CC interpolation shape (per-point: see applyPointShapes).
    applyPointShapes(take, chan, writeLane, ppq0, ppq1, points)

    -- Mark the item dirty so undo (flag 4) records the change. In the SELF-CONTAINED path
    -- (noUndo=false, the Generate button) this is the only dirty call, so it must run here.
    -- In the LIVE path (noUndo=true) we deliberately SKIP this per-frame call (v2.2 T4):
    -- MarkTrackItemsDirty forces a synchronous arrange-view overview rebuild every frame,
    -- which is the cause of the per-frame navigation-bar FLASH. NOTE: this per-event :write
    -- path calls MIDI_Sort (above) to refresh the editor; that is DISTINCT from the live bulk
    -- path (CC:writeBulk), which uses MIDI_SetAllEvts (NO MIDI_Sort) and relies on the editor
    -- polling the take each defer cycle to repaint. The caller (endLiveGesture in
    -- ui/generate.lua) calls MarkTrackItemsDirty ONCE at gesture end so the coalesced flags=4
    -- undo block still snapshots the change.
    if not opts.noUndo then
      local item = reaper.GetMediaItemTake_Item(take)
      local track = reaper.GetMediaItem_Track(item)
      reaper.MarkTrackItemsDirty(track, item)
    end

    return written
  end

  local ok, errOrWritten
  if opts.noUndo then
    -- Caller owns one outer undo block spanning many writes (live drag => single undo).
    ok, errOrWritten = pcall(body)
  else
    reaper.Undo_BeginBlock2(0)
    ok, errOrWritten = pcall(body)
    reaper.Undo_EndBlock2(0, opts.undoLabel or "Contour: Generate CC LFO", 4)  -- 4 = UNDO_STATE_ITEMS
  end

  if not ok then
    return nil, "write failed: " .. tostring(errOrWritten)
  end

  local written = errOrWritten
  -- Silent-destructive guard: if we had points to write but inserted none, the delete
  -- already happened, so surface the failure instead of reporting success.
  if #points > 0 and written == 0 then
    return nil, "no CC events written (insert failed)"
  end

  return written, nil
end

------------------------------------------------------------------------------
-- BULK live-write path (v2.1): atomic MIDI_GetAllEvts/SetAllEvts.
--
-- The per-event MIDI_DeleteCC/InsertCC + MIDI_Sort + repaint loop lags badly on
-- dense takes during a live drag. Instead:
--   * at gesture START, snapshot the take's whole event buffer ONCE
--       (MIDI_GetAllEvts -> midistream.decode), and cache the decoded table;
--   * each live frame, midistream.replaceCCInRange(snapshot, ...) -> encode ->
--       MIDI_SetAllEvts ONCE — no per-event Reaper calls, no MIDI_Sort, no scan.
-- The decoded snapshot is IMMUTABLE across the gesture (replaceCCInRange returns
-- a fresh table and never mutates its input's events array members), so every
-- frame re-derives from the original, pristine CC data — never compounding edits.
------------------------------------------------------------------------------

-- Snapshot the take's full event stream as a decoded midistream table, or
-- (nil, err) on failure. Call ONCE at gesture start; reuse across frames.
function CC:snapshot()
  local take = self._take
  if not take then return nil, "No MIDI take" end
  if not (reaper.MIDI_GetAllEvts and midistream and midistream.decode) then
    return nil, "MIDI_GetAllEvts unavailable"
  end
  local ok, blob = reaper.MIDI_GetAllEvts(take, "")
  if not ok then return nil, "MIDI_GetAllEvts failed" end
  local okDec, dec = pcall(midistream.decode, blob)
  if not okDec then return nil, "decode failed: " .. tostring(dec) end
  return dec, nil
end

-- Bulk replace-in-range write driven from a pre-decoded snapshot. Replaces this
-- lane+channel's CC in project-time [t0,t1] with `points`, atomically via
-- MIDI_SetAllEvts. The CC shape is baked into the encoded flags nibble (no
-- post-write MIDI_SetCCShape scan needed). Returns (count, nil) or (nil, err).
--
-- `snapshot` MUST be a midistream.decode() table captured for THIS take. opts =
-- { ccShape=int 0..5, noUndo=bool } — semantics identical to :write (the live
-- caller passes noUndo=true and owns the coalesced undo block). MarkTrackItemsDirty
-- (v2.2 T4) is SKIPPED per-call when noUndo=true — the caller (endLiveGesture) marks
-- the item dirty ONCE at gesture end so the coalesced flags=4 block records the edit
-- without a per-frame arrange-overview rebuild. When noUndo=false this is the only
-- dirty call, so it runs here.
function CC:writeBulk(snapshot, points, t0, t1, opts)
  opts = opts or {}
  local take = self._take
  if not take then return nil, "No MIDI take" end
  if not snapshot then return nil, "No snapshot" end
  if not (reaper.MIDI_SetAllEvts and midistream) then
    return nil, "MIDI_SetAllEvts unavailable"
  end

  local writeLane = self._lane
  if writeLane == nil or writeLane < 0 or writeLane > 127 then
    return nil, "Standard CC lanes (0-127) only for now"
  end
  local chan    = self._chan or 0
  local ccShape = opts.ccShape or 1
  points = points or {}

  local ppq0 = reaper.MIDI_GetPPQPosFromProjTime(take, t0)
  local ppq1 = reaper.MIDI_GetPPQPosFromProjTime(take, t1)

  -- PERF: the immutable events (notes + other lanes + our lane outside [ppq0,ppq1]) don't change
  -- during a gesture, so split them out ONCE and reuse. Memoised on the target, keyed by
  -- (snapshot, chan, lane, ppq0, ppq1); rebuilt only when one of those changes (re-snapshot,
  -- CC# change, or time-selection change mid-drag). This removes the per-frame whole-take filter
  -- + double sort that scaled with note count and caused the fps dips.
  if not (self._split and self._splitSnap == snapshot and self._splitChan == chan
          and self._splitLane == writeLane and self._splitP0 == ppq0 and self._splitP1 == ppq1) then
    self._split = midistream.splitForRange(snapshot, chan, writeLane, ppq0, ppq1)
    self._splitSnap, self._splitChan, self._splitLane = snapshot, chan, writeLane
    self._splitP0, self._splitP1 = ppq0, ppq1
  end

  -- Build the new-CC list in ABSOLUTE ppq on STRICTLY-INCREASING ticks (assignTicks: clamped 1 tick
  -- inside the selection, with any tie bumped to the next tick). This keeps a saw's reset (peak +
  -- instant drop) on two adjacent ticks rather than stacking a duplicate CC on one tick (the "square"
  -- block). pt._tick is reused by applyPointShapes so the shapes line up.
  assignTicks(take, points, ppq0, ppq1)
  local newCCs = {}
  for _, pt in ipairs(points) do
    newCCs[#newCCs + 1] = { ppq = pt._tick, value = clampCC(pt.value), shape = pt.shape or ccShape, sel = pt.sel }
  end

  -- The atomic body: merge the new CCs into the cached immutable list, encode, set once.
  local function body()
    local blob = midistream.encodeMerged(self._split.kept, chan, writeLane, newCCs, self._split.eot)
    -- Mirror the :write insert guard: a false return means REAPER silently rejected the
    -- buffer. Raise so the outer pcall turns it into a "write failed" status instead of
    -- reporting a false-positive "Live: N CC events" + leaving a ghost undo entry.
    if not reaper.MIDI_SetAllEvts(take, blob) then
      error("MIDI_SetAllEvts rejected the event buffer")
    end

    -- The flags nibble alone renders only STEP (0) correctly in the live MIDI_SetAllEvts path;
    -- LINEAR (1) and the CURVE shapes (>= 2) draw as STEPS until MIDI_SetCCShape is applied (the
    -- user-reported "saw / pump look like squares in live"). So run the shape pass whenever ANY point
    -- is non-step (>= 1); an all-step shape (Square) still skips it. The commit path (:write) already
    -- applies shapes unconditionally, so this just makes Live match the committed result. No
    -- MarkTrackItemsDirty here, so still no per-frame arrange-overview FLASH.
    local needShapes = false
    for _, pt in ipairs(points) do
      if (pt.shape or 1) >= 1 then needShapes = true; break end
    end
    if needShapes then
      applyPointShapes(take, chan, writeLane, ppq0, ppq1, points)
    end

    -- v2.2 T4: SKIP MarkTrackItemsDirty on the per-frame LIVE path (noUndo=true). It forces
    -- a synchronous arrange-view overview/navigation rebuild every frame -> the FLASH the
    -- user saw. MIDI_SetAllEvts updates the open MIDI editor on its own next defer cycle
    -- WITHOUT this call (confirmed by research: the editor polls the take independently).
    -- The single gesture-end MarkTrackItemsDirty in ui/generate.lua's endLiveGesture keeps
    -- the coalesced flags=4 undo entry correct. In a self-contained bulk write (noUndo=false)
    -- this is the only dirty call, so it must run.
    if not opts.noUndo then
      local item = reaper.GetMediaItemTake_Item(take)
      if item then
        local track = reaper.GetMediaItem_Track(item)
        reaper.MarkTrackItemsDirty(track, item)
      end
    end
    return #newCCs
  end

  local ok, errOrCount
  if opts.noUndo then
    ok, errOrCount = pcall(body)
  else
    reaper.Undo_BeginBlock2(0)
    ok, errOrCount = pcall(body)
    reaper.Undo_EndBlock2(0, opts.undoLabel or "Contour: Generate CC LFO", 4)
  end

  if not ok then
    return nil, "bulk write failed: " .. tostring(errOrCount)
  end
  return errOrCount, nil
end

------------------------------------------------------------------------------
-- ENVELOPE target (track envelopes). Generate writes LFO points; the value model is the SAME
-- range-agnostic %-based one as CC (the UI reads :valueRange()). Per-point CC shapes (0-5) map
-- 1:1 onto envelope point shapes, so sine/parametric curves carry over for free.
--
-- Value domain: native REAPER exposes no envelope min/max, so the range comes from SWS
-- BR_EnvGetProperties (whose bounds are in the STORAGE domain), converted to the LINEAR/display
-- domain via ScaleFromEnvelopeMode so the symmetric MID/HALF %-model holds (volume 0..2 center 1,
-- pan -1..1 center 0, ...). At write time each value is converted back with ScaleToEnvelopeMode
-- (identity for scaling mode 0). Falls back to per-type defaults by envelope name when SWS is absent.
------------------------------------------------------------------------------
local ENV = {}
ENV.__index = ENV

function ENV.new(env) return setmetatable({ _env = env }, ENV) end
function ENV:kind() return "envelope" end
function ENV:lane() return nil end
function ENV:channel() return 0 end

-- LINEAR value range for the % model. NAME-BASED for the built-in envelope types — these are the
-- REAL values InsertEnvelopePoint takes directly (Volume 0..2 with unity=1, Pan/Width -1..1,
-- Mute 0..1, Pitch -3..+3 semitones). SWS BR_EnvGetProperties is used only for UNKNOWN types
-- (FX parameters, tempo) when present, else 0..1 normalized.
-- NOTE: earlier this ran values through ScaleToEnvelopeMode, which produced ALL-ZERO points; native
-- envelopes take the real value directly for the common (non-fader-scaled) case, so we insert
-- directly. A fader-scaled volume envelope (GetEnvelopeScalingMode==1) may need ScaleToEnvelopeMode
-- — to be confirmed with dump_env.lua on a real device before re-adding.
-- Returns the range in the envelope's STORAGE domain (the values InsertEnvelopePoint takes and the
-- lane draws). Generating the waveform in this domain — rather than in linear units then converting
-- each point — keeps the shape clean and lets baseline TRANSLATE it (clipping at the edges) instead
-- of the nonlinear conversion SQUASHING it. Built-in types: name-based linear bounds converted ONCE
-- to storage for fader-scaled envelopes (mode ~= 0). Unknown types: SWS BR bounds (already storage).
-- Shared by ENV and AI: an automation item's value domain IS its parent envelope's.
local function envValueRange(env)
  local mode = (reaper.GetEnvelopeScalingMode and reaper.GetEnvelopeScalingMode(env)) or 0
  local _, name = reaper.GetEnvelopeName(env, "")
  name = (name or ""):lower()
  local lo, hi
  if name:find("pan") or name:find("width") then lo, hi = -1, 1
  elseif name:find("mute") then lo, hi = 0, 1
  elseif name:find("pitch") then lo, hi = -3, 3
  elseif name:find("volume") then lo, hi = 0, 2
  end
  if lo then
    if mode ~= 0 and reaper.ScaleToEnvelopeMode then          -- linear bounds -> storage domain
      lo, hi = reaper.ScaleToEnvelopeMode(mode, lo), reaper.ScaleToEnvelopeMode(mode, hi)
    end
  elseif reaper.BR_EnvAlloc and reaper.BR_EnvGetProperties and reaper.BR_EnvFree then
    local ok, a, b = pcall(function()
      local br = reaper.BR_EnvAlloc(env, false)
      if not br then return nil end
      local _, _, _, _, _, _, mn, mx = reaper.BR_EnvGetProperties(br)
      reaper.BR_EnvFree(br, false)
      return mn, mx
    end)
    if ok and a and b then lo, hi = a, b end
  end
  if not lo then lo, hi = 0, 1 end
  if hi < lo then lo, hi = hi, lo end
  if hi <= lo then hi = lo + 1 end
  return lo, hi
end

function ENV:valueRange() return envValueRange(self._env) end

-- CC shape ints differ from ENVELOPE shape ints for 0/1: CC 0=square, 1=linear; ENVELOPE
-- 0=linear, 1=square (2=slow start/end, 3=fast start, 4=fast end, 5=bezier are identical in both).
-- The engine emits CC-convention shapes, so swap 0<->1 for envelope points (this is why triangle/
-- saw/square rendered with the wrong curve on envelopes).
local CC_TO_ENV_SHAPE = { [0] = 1, [1] = 0 }

-- Replace this envelope's points within [t0,t1] with `points`. Values clamp to range; a FADER-
-- SCALED envelope (Volume; GetEnvelopeScalingMode ~= 0) stores SCALED values, so its linear value
-- is converted via ScaleToEnvelopeMode. Non-scaled envelopes (Pan/Width/Mute/Pitch, mode 0) insert
-- directly (calling ScaleToEnvelopeMode at mode 0 ZEROED the values — that was the all-0 bug).
-- envReplace handles BOTH a track envelope (aiIdx=nil -> the non-Ex point calls) and an automation
-- item (aiIdx>=0 -> the *Ex variants, which address that item's pooled points). Automation-item point
-- times are ABSOLUTE PROJECT seconds — the SAME domain as track-envelope points, with NO
-- D_POSITION/startoffs/playrate conversion (verified empirically against REAPER 7.75). So the only
-- difference is the Ex function family + the item index.
-- rawShape=true means each point's .shape is ALREADY in envelope convention (e.g. Reduce reading back
-- existing envelope points) — skip the CC->ENV 0<->1 swap. Default (Generate) swaps, since the engine
-- emits CC-convention shapes.
local DPAD = 1e-9   -- sub-sample pad so the widened delete clears a survivor exactly at t1
local function envReplace(env, aiIdx, points, t0, t1, vmin, vmax, rawShape)
  -- Values are ALREADY in the envelope's storage domain (see envValueRange), so insert them DIRECTLY.
  -- Boundary handling differs by caller:
  --  * GENERATE (rawShape false): points are freshly emitted. DeleteEnvelopePointRange(Ex)(t0,t1) won't
  --    remove a point at t1, so a generated point there would pile up each live frame; inset both ends
  --    by eps so the re-derivation stays clean (AI also drops a point on its boundary on INSERT).
  --  * REDUCE (rawShape true): points are EXISTING points re-inserted verbatim at their own times, so
  --    insetting would shift them. Instead WIDEN the delete past t1 to clear the at-t1 survivor (else a
  --    point exactly at t1 would be duplicated), and insert at the exact times (AI: a 1ns inset off each
  --    boundary, imperceptible, to dodge REAPER dropping points on the item edges).
  local eps    = math.min(1e-3, (t1 - t0) * 1e-3)
  local insetL = rawShape and (aiIdx and DPAD or 0) or (aiIdx and eps or 0)
  local insetR = rawShape and (aiIdx and DPAD or 0) or eps
  local delHi  = rawShape and (t1 + DPAD) or t1
  if aiIdx then reaper.DeleteEnvelopePointRangeEx(env, aiIdx, t0, delHi)
  else          reaper.DeleteEnvelopePointRange(env, t0, delHi) end
  local written = 0
  for _, pt in ipairs(points) do
    local v = pt.value
    if v < vmin then v = vmin elseif v > vmax then v = vmax end
    local tm = pt.time
    if tm > t1 - insetR then tm = t1 - insetR end
    if tm < t0 + insetL then tm = t0 + insetL end
    local es = pt.shape
    if es == nil then es = 0 elseif not rawShape then es = CC_TO_ENV_SHAPE[es] or es end
    local okIns
    local selFlag = pt.sel and true or false   -- preserve selection (Reduce); Generate points have none
    if aiIdx then
      okIns = reaper.InsertEnvelopePointEx(env, aiIdx, tm, v, es, pt.tension or 0.0, selFlag, true)
    else
      okIns = reaper.InsertEnvelopePoint(env, tm, v, es, pt.tension or 0.0, selFlag, true)
    end
    if okIns then written = written + 1 end
  end
  if aiIdx then reaper.Envelope_SortPointsEx(env, aiIdx) else reaper.Envelope_SortPoints(env) end
  return written
end

-- write(points, t0, t1, opts): self-contained (opts.noUndo=false) opens its own undo block;
-- live (noUndo=true) is wrapped by the caller's coalesced gesture block. UpdateArrange repaints
-- the envelope lane (no MarkTrackItemsDirty -> no per-frame flash).
function ENV:write(points, t0, t1, opts)
  opts = opts or {}
  local env = self._env
  if not env then return nil, "No envelope" end
  if not points or #points == 0 then return 0, nil end
  local vmin, vmax = self:valueRange()
  local function body() return envReplace(env, nil, points, t0, t1, vmin, vmax, opts.rawShape) end
  local ok, res
  if opts.noUndo then
    ok, res = pcall(body)
  else
    reaper.Undo_BeginBlock2(0)
    ok, res = pcall(body)
    reaper.Undo_EndBlock2(0, opts.undoLabel or "Contour: Generate envelope LFO", -1)  -- -1 = UNDO_STATE_ALL
  end
  if reaper.UpdateArrange then reaper.UpdateArrange() end
  if not ok then return nil, "envelope write failed: " .. tostring(res) end
  -- Silent-destructive guard (mirrors CC:write): the range delete already happened, so if we had points
  -- to write but inserted none, surface a failure instead of reporting a wiped range as success.
  if #points > 0 and res == 0 then return nil, "no envelope points written (insert failed)" end
  return res, nil
end

-- Read this envelope's points as { {time, value, shape, tension, sel}, ... } (time-ascending; shapes
-- in ENVELOPE convention; sel = the point's selected flag). nil t0/t1 means unbounded (read all).
-- Used by Reduce, incl. its "Selected points" scope which reads the whole envelope to locate selection.
function ENV:read(t0, t1)
  local env = self._env
  if not env or not (reaper.CountEnvelopePoints and reaper.GetEnvelopePoint) then return {} end
  local out = {}
  local cnt = reaper.CountEnvelopePoints(env)
  for i = 0, (cnt or 0) - 1 do
    local ok, tm, val, shape, tension, sel = reaper.GetEnvelopePoint(env, i)
    if ok and (t0 == nil or tm >= t0) and (t1 == nil or tm <= t1) then
      out[#out + 1] = { time = tm, value = val, shape = shape, tension = tension, sel = sel and true or false }
    end
  end
  return out
end

-- Live path: envelopes have no bulk SetAllEvts, so writeBulk just does the per-point replace
-- (sparse for typical LFOs). snapshot() returns a marker so the shared live orchestration proceeds;
-- DeleteEnvelopePointRange each frame clears the prior frame's points, so edits never compound.
function ENV:snapshot() return { env = self._env } end
function ENV:writeBulk(_snap, points, t0, t1, opts)
  return self:write(points, t0, t1, opts)
end

-- A track envelope has no "item", so its Entire-item extent is the whole project timeline.
function ENV:fullSpan()
  local len = (reaper.GetProjectLength and reaper.GetProjectLength(0)) or 0
  if len <= 0 then return nil end
  return 0, len
end

------------------------------------------------------------------------------
-- AUTOMATION ITEM target. An automation item is a pooled segment of points living ON a track
-- envelope. Its value domain == the parent envelope's (envValueRange), and its point times are
-- ABSOLUTE PROJECT seconds (verified empirically against REAPER 7.75 — same domain as track-envelope
-- points, NO playrate/startoffs conversion at default item settings). So the AI target is the ENV
-- target routed through the *Ex point functions with the item index, plus a write span clamped to the
-- item's [position, position+length] bounds (REAPER discards points outside the item).
--
-- POOLED EDITS: if this item shares a pool ID with others (D_POOL_ID), REAPER propagates the point
-- edits to every sibling — REAPER's own documented behaviour (the native AI LFO does the same). The
-- item's baseline/amplitude (D_BASELINE/D_AMPLITUDE) stay at their transparent defaults; we bake the
-- full shape into the point VALUES, exactly like the CC and envelope targets. An AI-properties panel
-- (baseline / amplitude / loop) is a later sub-step.
------------------------------------------------------------------------------
local AI = {}
AI.__index = AI

function AI.new(env, idx) return setmetatable({ _env = env, _idx = idx }, AI) end
function AI:kind() return "ai" end
function AI:lane() return nil end
function AI:channel() return 0 end
function AI:valueRange() return envValueRange(self._env) end

-- The item's project-time bounds [position, position+length], or nil if unavailable.
function AI:bounds()
  local env, idx = self._env, self._idx
  if not (env and idx ~= nil and reaper.GetSetAutomationItemInfo) then return nil end
  local pos = reaper.GetSetAutomationItemInfo(env, idx, "D_POSITION", 0, false)
  local len = reaper.GetSetAutomationItemInfo(env, idx, "D_LENGTH", 0, false)
  if not pos or not len or len <= 0 then return nil end
  return pos, pos + len
end

-- "Entire item" extent = the automation item's own bounds.
function AI:fullSpan() return self:bounds() end

function AI:write(points, t0, t1, opts)
  opts = opts or {}
  local env = self._env
  if not env then return nil, "No envelope" end
  if not points or #points == 0 then return 0, nil end
  -- Clamp the write span to the item bounds: REAPER drops points outside [pos, pos+len], and an
  -- un-clamped span would pile the out-of-item points onto the edges.
  local lo, hi = self:bounds()
  if lo then
    if t0 < lo then t0 = lo end
    if t1 > hi then t1 = hi end
  end
  if t1 <= t0 then return 0, nil end
  local vmin, vmax = self:valueRange()
  local function body() return envReplace(env, self._idx, points, t0, t1, vmin, vmax, opts.rawShape) end
  local ok, res
  if opts.noUndo then
    ok, res = pcall(body)
  else
    reaper.Undo_BeginBlock2(0)
    ok, res = pcall(body)
    reaper.Undo_EndBlock2(0, opts.undoLabel or "Contour: Generate automation-item LFO", -1)  -- -1 = ALL
  end
  if reaper.UpdateArrange then reaper.UpdateArrange() end
  if not ok then return nil, "automation-item write failed: " .. tostring(res) end
  -- Silent-destructive guard (mirrors CC:write): delete already happened; a zero-insert means failure.
  if #points > 0 and res == 0 then return nil, "no automation-item points written (insert failed)" end
  return res, nil
end

-- Read this item's points as { {time, value, shape, tension, sel}, ... } (time-ascending, shapes in
-- ENVELOPE convention, times in absolute PROJECT seconds; sel = selected flag). nil t0/t1 = unbounded.
-- When a bound is given it is clamped to the item bounds. Used by Reduce (incl. its Selected scope).
function AI:read(t0, t1)
  local env, idx = self._env, self._idx
  if not env or not (reaper.CountEnvelopePointsEx and reaper.GetEnvelopePointEx) then return {} end
  if t0 ~= nil or t1 ~= nil then
    local lo, hi = self:bounds()
    if lo then if t0 and t0 < lo then t0 = lo end; if t1 and t1 > hi then t1 = hi end end
  end
  local out = {}
  local cnt = reaper.CountEnvelopePointsEx(env, idx)
  for i = 0, (cnt or 0) - 1 do
    local ok, tm, val, shape, tension, sel = reaper.GetEnvelopePointEx(env, idx, i)
    if ok and (t0 == nil or tm >= t0) and (t1 == nil or tm <= t1) then
      out[#out + 1] = { time = tm, value = val, shape = shape, tension = tension, sel = sel and true or false }
    end
  end
  return out
end

-- Live path mirrors ENV: no bulk SetAllEvts for points, so writeBulk delegates to write (sparse for
-- typical LFOs). DeleteEnvelopePointRangeEx each frame clears the prior frame's points, so live edits
-- never compound. snapshot() returns a marker so the shared live orchestration proceeds.
function AI:snapshot() return { env = self._env, idx = self._idx } end
function AI:writeBulk(_snap, points, t0, t1, opts)
  return self:write(points, t0, t1, opts)
end

------------------------------------------------------------------------------
-- Factory
------------------------------------------------------------------------------
function M.fromContext(detected)
  if not detected or not detected.target then
    return nil, "Nothing selected"
  end

  local tgt = detected.target
  if tgt == "envelope" then
    local d = detected.details
    if not d or not d.env then return nil, "No envelope selected" end
    -- Track envelopes use PROJECT time (what we generate in). Take envelopes use item-relative
    -- time (playrate/offset) — support those next. Envelope_GetParentTake returns the take only
    -- for take envelopes (nil for track envelopes).
    if reaper.Envelope_GetParentTake then
      local take = reaper.Envelope_GetParentTake(d.env)
      if take and reaper.ValidatePtr2(0, take, "MediaItem_Take*") then
        return nil, "Take-envelope support is coming next — select a track envelope"
      end
    end
    return ENV.new(d.env), nil
  elseif tgt == "ai" then
    local d = detected.details
    if not d or not d.env or d.aiIndex == nil then return nil, "No automation item selected" end
    return AI.new(d.env, d.aiIndex), nil
  elseif tgt == "cc" then
    local d = detected.details
    if not d or not d.take then return nil, "No MIDI take" end
    local lane, laneErr = activeCCLane(d.midiEditor)
    if laneErr then return nil, laneErr end
    return CC.new(d.take, d.midiEditor, lane, 0), nil
  end

  return nil, "Unknown target"
end

M._clampCC = clampCC   -- exposed for tests
M.CC = CC
M.AI = AI
return M
