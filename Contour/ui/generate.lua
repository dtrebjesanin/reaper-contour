-- ui/generate.lua — Generate v2 panel (stock ReaImGui widgets only).
-- CC target end-to-end with LIVE preview, full native-CC-LFO control parity + extras,
-- and shape-aware point output (fewer events; crisp squares; smooth sines).
--
-- This is the ONLY Reaper-bound part of the Generate feature beyond core/target.lua:
--   - tempo -> cycleSec for Sync rate is computed here (core/lfo stays pure).
--   - the live-preview single-undo gesture is orchestrated here.
--   - per-LFO-shape density + MIDI CC shape selection is decided here.
-- core/lfo.lua + core/shapes.lua remain pure (zero reaper.*).
--
-- The drawn preview-curve UI, presets, fades/quantize/randomness/smooth controls are a
-- LATER slice and deliberately NOT built here.
local M = {}

local lfo    = require("core.lfo")
local target = require("core.target")

-- Shape ids MUST match what core/shapes.lua / core/lfo.lua expect. "None" is FIRST and the
-- DEFAULT (v2.1 U1): a NO-OP — picking it generates and writes NOTHING (canGenerate=false),
-- so the panel doesn't auto-write on first open until a real shape is chosen. Shapes are
-- ordered by family: tonal (sine/triangle/saw/sawdown/square/trapezoid/parametric), harmonic
-- (rectsine/sine²), dynamic (pump/ad), stochastic (random/drift).
local SHAPES = {
  { id = "none",       label = "None" },
  { id = "sine",       label = "Sine" },
  { id = "triangle",   label = "Triangle" },
  { id = "saw",        label = "Saw Up" },
  { id = "sawdown",    label = "Saw Down" },
  { id = "square",     label = "Square" },
  { id = "trapezoid",  label = "Trapezoid" },
  { id = "parametric", label = "Parametric" },
  { id = "rectsine",   label = "Rectified sine" },
  { id = "sine2",      label = "Sine\xc2\xb2" },     -- "Sine²" (UTF-8 superscript two)
  { id = "random",     label = "Random (S&H)" },
  { id = "drift",      label = "Drift" },
}

-- Build the null-separated combo string for the shape selector.
local SHAPE_ITEMS = ""
for _, s in ipairs(SHAPES) do SHAPE_ITEMS = SHAPE_ITEMS .. s.label .. "\0" end

-- Rate modes. Musical (native Length x Frequency) is the DEFAULT and mirrors REAPER's CC LFO.
local RATE_MODES = { "Musical (Length x Freq)", "Free (cycles)", "Hz (absolute)" }
local RATE_ITEMS = ""
for _, s in ipairs(RATE_MODES) do RATE_ITEMS = RATE_ITEMS .. s .. "\0" end
local RATE_MUSICAL, RATE_FREE, RATE_HZ = 0, 1, 2

-- Native musical rate: a Length note value x a rhythm Feel, plus a Frequency multiplier
-- (period in quarter notes = lfo.musicalBeatsPerCycle). Full native value range — Length
-- 1/256..4 and Frequency 1/256..16 — not the tiny old Division list the user flagged.
local NOTE_VALUES = { 1/256, 1/128, 1/64, 1/32, 1/16, 1/8, 1/4, 1/2, 1, 2, 4 }
local NOTE_LABELS = { "1/256", "1/128", "1/64", "1/32", "1/16", "1/8", "1/4", "1/2", "1", "2", "4" }
local FREQ_VALUES = { 1/256, 1/128, 1/64, 1/32, 1/16, 1/8, 1/4, 1/2, 1, 2, 4, 8, 16 }
local FREQ_LABELS = { "1/256", "1/128", "1/64", "1/32", "1/16", "1/8", "1/4", "1/2", "1", "2", "4", "8", "16" }
local FEELS = {
  { label = "Straight", mult = 1.0 },
  { label = "Triplet",  mult = 2.0 / 3.0 },
  { label = "Dotted",   mult = 1.5 },
}
local function nullJoin(labels)
  local s = ""
  for _, l in ipairs(labels) do s = s .. l .. "\0" end
  return s
end
local LENGTH_ITEMS = nullJoin(NOTE_LABELS)
local FREQ_ITEMS   = nullJoin(FREQ_LABELS)
local FEEL_ITEMS   = ""
for _, f in ipairs(FEELS) do FEEL_ITEMS = FEEL_ITEMS .. f.label .. "\0" end

-- Scope: write across the Time selection, or the target's Entire item/envelope (native parity).
local SCOPE_MODES = { "Time selection", "Entire item" }
local SCOPE_ITEMS = ""
for _, s in ipairs(SCOPE_MODES) do SCOPE_ITEMS = SCOPE_ITEMS .. s .. "\0" end
local SCOPE_TIMESEL, SCOPE_ENTIRE = 0, 1

-- Resolve the write span (project seconds) from the scope: the time selection, or the target's
-- fullSpan(). ENVELOPES are time-selection ONLY (a track envelope has no item; "entire" = the whole
-- project is rarely wanted), so Entire-item applies only to CC and AI. Falls back to the time
-- selection if Entire-item has no valid span.
local function spanFor(tgt, detected, g)
  local kind = tgt and tgt.kind and tgt:kind()
  -- Entire-item scope uses fullSpan() (CC item bounds, or the AI's own bounds). Envelopes have no
  -- item, so they stay time-selection only (the kind ~= "envelope" guard).
  if g.scope == SCOPE_ENTIRE and kind and kind ~= "envelope" and tgt.fullSpan then
    local a, b = tgt:fullSpan()
    if a and b and b > a then return a, b end
  end
  local t0, t1 = detected.t0, detected.t1
  -- Automation items: REAPER drops points outside [pos, pos+len], so intersect the time-selection
  -- span with the AI's bounds (Entire-item already returned the AI bounds above).
  if kind == "ai" and tgt.fullSpan then
    local a, b = tgt:fullSpan()
    if a and b then
      if t0 < a then t0 = a end
      if t1 > b then t1 = b end
    end
  end
  return t0, t1
end

-- ---------------------------------------------------------------------------
-- Shape-aware output: points-per-cycle + a FALLBACK MIDI CC shape per LFO shape.
-- The engine (lfo.generate) now tags EACH point with its native CC shape (sine=slow start/end,
-- parametric=fast-end/fast-start alternating, triangle/saw=linear, square=step), and the writer
-- applies those per-point. ccShape here is only a fallback for points without a shape. MIDI CC
-- shape ints: 0=step, 1=linear, 2=slow start/end, 3=fast start, 4=fast end, 5=bezier.
-- ---------------------------------------------------------------------------
local SHAPE_OUTPUT = {
  none       = { ppc = 1,  ccShape = 0 },
  sine       = { ppc = 8,  ccShape = 2 },
  triangle   = { ppc = 2,  ccShape = 1 },
  saw        = { ppc = 2,  ccShape = 1 },
  square     = { ppc = 2,  ccShape = 0 },
  parametric = { ppc = 4,  ccShape = 4 },
  -- Saw Down / Trapezoid / Rectified sine / Sine² have dedicated SPARSE emitters that tag their own
  -- per-point shapes; ppc/ccShape here are only the fallback for the smooth/quantize generic path:
  sawdown    = { ppc = 2,  ccShape = 1 },   -- descending ramp (sparse emitter)
  trapezoid  = { ppc = 8,  ccShape = 1 },   -- 4-corner sparse emitter
  rectsine   = { ppc = 8,  ccShape = 1 },   -- |sin| humps: 4-anchor emitter (fast-start/fast-end)
  sine2      = { ppc = 4,  ccShape = 2 },   -- peakier sine: 4-anchor emitter (slow start/end)
  random     = { ppc = 1,  ccShape = 0 },
  drift      = { ppc = 1,  ccShape = 2 },
}
local DEFAULT_OUTPUT = { ppc = 16, ccShape = 1 }

-- Pick points-per-cycle + fallback CC shape. All UI shapes now have their own crisp/sparse
-- emitter that handles phase/swing/freqSkew/ampSkew/tilt directly (sine/triangle/parametric =
-- anchored; square = explicit edges; saw = warped ramp), so none fall to the dense sampler and
-- none need densifying here. (g is unused but kept for call-site compatibility.)
local function outputFor(shape, g)
  local base = SHAPE_OUTPUT[shape] or DEFAULT_OUTPUT
  return base.ppc, base.ccShape
end

-- ---------------------------------------------------------------------------
-- Sync: tempo -> cycleSec. Reaper-bound; uses the QN method (tempo-envelope-correct)
-- with a constant-tempo fallback if the TimeMap2 calls are unavailable.
-- ---------------------------------------------------------------------------
-- Native musical Length x Frequency -> seconds per cycle, via the tempo map (tempo-envelope-
-- correct, with a constant-tempo fallback). qnPerCycle (quarter notes) comes from the pure
-- lfo.musicalBeatsPerCycle so the rate math is headless-tested.
local function musicalCycleSec(t0, lengthFrac, feelMult, freq)
  t0 = t0 or 0
  local qnPerCycle = lfo.musicalBeatsPerCycle(lengthFrac, feelMult, freq)
  if reaper.TimeMap2_timeToQN and reaper.TimeMap2_QNToTime then
    local qn0 = reaper.TimeMap2_timeToQN(0, t0)
    local sec = reaper.TimeMap2_QNToTime(0, qn0 + qnPerCycle) - t0
    if sec and sec > 0 then return sec end
  end
  local bpm = (reaper.Master_GetTempo and reaper.Master_GetTempo()) or 120
  if not bpm or bpm <= 0 then bpm = 120 end
  return qnPerCycle * 60.0 / bpm
end

-- ---------------------------------------------------------------------------
-- Documented control DEFAULTS (single source of truth for the global Reset and the
-- per-row RESET buttons). shapeIdx=0 => "None" (no-op, v2.1 U1). These are the values
-- the global Reset (U3) restores and the values each per-row RESET button snaps its
-- field back to. ccNum/lastLane are intentionally NOT here — Reset must keep the lane
-- as-is (the CC# per-row reset uses an explicit CC1 default instead).
-- ---------------------------------------------------------------------------
-- Generate v2.4: sliders are now in NATIVE-CC-LFO % units (matching REAPER's own LFO panel),
-- converted to value units in buildParams before calling lfo.generate:
--   baseline  -100..100  (0 = center; -100 = vmin, +100 = vmax)
--   amplitude -200..200  (50 = half-swing of 31.75 on a 0..127 lane; negative inverts; >100 clips)
--   ampSkew   -100..100  (global amplitude ramp; +100 = 0->full L->R)
--   freqSkew  -100..100  (global phase time-warp; +100 bunches cycles to the right)
--   tilt      -100..100  (global full-range drift; +100 = +full range at the right edge)
--   phase        0..100  (slider units; phase = phaseSlider/100 cycles, so 100 = one full cycle)
-- pulseWidth/swing keep their prior 0..1 / -1..1 ranges.
local DEFAULTS = {
  shapeIdx   = 0,        -- None
  cycles     = 4,
  amplitude  = 50,       -- % of HALF range (50 => baseHalf 31.75 on a 0..127 lane)
  baseline   = 0,        -- % offset from center (0 => CC 63.5)
  rateMode   = RATE_MUSICAL,
  lengthIdx  = 6,        -- 1/4 (into NOTE_VALUES)
  feelIdx    = 0,        -- Straight (into FEELS)
  freqIdx    = 8,        -- 1 (into FREQ_VALUES); with Length 1/4 => 2 QN/cycle (4 cycles / 2 bars)
  hz         = 1.0,
  phase      = 0,        -- slider units 0..100 (phase = phaseSlider/100 cycles)
  ampSkew    = 0,        -- -100..100 % (SliderInt)
  pulseWidth = 0.5,
  freqSkew   = 0,        -- -100..100 % (SliderInt)
  tilt       = 0,        -- -100..100 % (SliderInt)
  swing      = 0.0,
  steps      = 0,        -- 0 = off; >=2 quantizes any shape to N levels
  smooth     = 0,        -- 0..100 % blend toward sine
  curve      = 0,        -- 0..100 (Pump/AD recovery/ease steepness)
  attack     = 50,       -- 1..99 % of cycle (AD peak position)
  edge       = 50,       -- 0..100 % (Trapezoid edge width; /200 => [0,0.5])
  scope      = SCOPE_TIMESEL,  -- Time selection (0) vs Entire item/envelope (1)
}

-- ---------------------------------------------------------------------------
-- Panel state (persists across frames under state.gen).
-- ---------------------------------------------------------------------------
local function ui(state)
  if not state.gen then
    state.gen = {
      shapeIdx  = DEFAULTS.shapeIdx,  -- 0-based combo index into SHAPES (None = default)
      cycles    = DEFAULTS.cycles,    -- Free rate: integer cycles over the selection
      amplitude = DEFAULTS.amplitude, -- -200..200 % of HALF range (native amplitude; neg inverts, >100 clips)
      ampDirty  = false,  -- true once the user moves Amplitude -> stops following the per-target default
      lastAmpTarget = nil,-- last detected target the amplitude default was synced to (edge-triggered)
      baseline  = DEFAULTS.baseline,  -- -100..100 % offset from center (native baseline)
      ccNum     = -1,     -- 0..127; -1 = not yet initialised from detection
      lastLane  = -1,     -- last-seen clicked CC lane, for edge-triggered follow

      scope     = DEFAULTS.scope,     -- Time selection vs Entire item/envelope

      -- Rate
      rateMode  = DEFAULTS.rateMode,
      lengthIdx = DEFAULTS.lengthIdx, -- 0-based into NOTE_VALUES (default 1/4)
      feelIdx   = DEFAULTS.feelIdx,   -- 0-based into FEELS (default Straight)
      freqIdx   = DEFAULTS.freqIdx,   -- 0-based into FREQ_VALUES (default 1)
      hz        = DEFAULTS.hz,        -- Hz mode

      -- Waveform shaping (native-CC-LFO parity + extras)
      phase     = DEFAULTS.phase,     -- 0..100 slider units (phase/100 cycles; 100 = one full cycle)
      ampSkew   = DEFAULTS.ampSkew,   -- -100..100 % (global amplitude ramp)
      pulseWidth= DEFAULTS.pulseWidth,-- 0..1 (square only)
      freqSkew  = DEFAULTS.freqSkew,  -- -100..100 % (global phase time-warp)
      tilt      = DEFAULTS.tilt,      -- -100..100 % (global full-range drift)
      swing     = DEFAULTS.swing,     -- -1..1
      steps     = DEFAULTS.steps,
      smooth    = DEFAULTS.smooth,
      curve     = DEFAULTS.curve,
      attack    = DEFAULTS.attack,
      edge      = DEFAULTS.edge,

      -- Random seed (v2.1 U2): stable while dragging other sliders; only Re-roll
      -- changes it, so a random pattern doesn't jump around as you tweak amplitude.
      -- Seeded per session so the FIRST Random pattern varies between sessions (Lua 5.4
      -- auto-seeds its PRNG at startup, so no math.randomseed is needed). Stays stable
      -- within the session until Re-roll.
      seed      = math.random(1, 2147483647),  -- 2^31-1

      live      = true,   -- LIVE preview ON by default

      status    = "",
      statusErr = false,
    }
  end
  return state.gen
end

-- Reset (U3): restore every documented control to its default, in place (keep the
-- table reference — liveGesture / state hold no ref to it but other fields like
-- ccNum/seed/live must survive). Lane is intentionally preserved.
local function resetDefaults(g)
  for k, v in pairs(DEFAULTS) do g[k] = v end
end

-- Live-gesture bookkeeping (script-level; one panel instance).
-- v2.1: tgt + snapshot are CACHED for the lifetime of the gesture so we do NOT call
-- target.fromContext or MIDI_GetAllEvts every frame — only once at gesture start, and
-- again only if the take changes mid-gesture (re-snapshot).
local liveGesture = {
  open      = false,   -- an Undo block is currently open for a live drag
  take      = nil,     -- the take the open block is editing (for clean re-target)
  tgt       = nil,     -- cached CC target for the gesture's take
  snapshot  = nil,     -- cached decoded midistream snapshot of the take at gesture start
  errored   = false,   -- a snapshot/fromContext failure occurred; suppress re-opening a
                       -- new undo block every drag frame on a broken take until the gesture
                       -- truly ends (reset in endLiveGesture / M.cleanup).
}

local COLOR_ERR  = 0xE05050FF
local COLOR_OK   = 0x60C080FF
local COLOR_HINT = 0xC0A040FF

-- Build the lfo.generate params + per-shape output (ppc / ccShape) from panel state.
--
-- Generate v2.4: the panel sliders are in NATIVE % units; lfo.generate consumes VALUE units
-- (range-agnostic). Convert here using the target's value range (vmin/vmax). Let
-- MID = (vmin+vmax)/2 and HALF = (vmax-vmin)/2 (e.g. 63.5 / 63.5 on a 0..127 CC lane):
--   baseline(center) = MID + (baselinePct/100)*HALF      -- 0% => center, +/-100% => vmax/vmin
--   amplitude(baseHalf) = (amplitudePct/100)*HALF        -- 50% => 31.75
--   tiltOffset       = (tiltPct/100)*(vmax-vmin)          -- full-range; +100% => +127 at right
--   ampSkew/freqSkew = pct/100  (mapped into [-1,1])
local function buildParams(g, spanT0, vmin, vmax)
  -- Out-of-range shapeIdx falls back to "none" (a no-op) rather than a surprise Sine write.
  local shape = SHAPES[g.shapeIdx + 1] and SHAPES[g.shapeIdx + 1].id or "none"
  local ppc, ccShape = outputFor(shape, g)

  local rate
  if g.rateMode == RATE_HZ then
    rate = { mode = "hz", hz = g.hz }
  elseif g.rateMode == RATE_MUSICAL then
    local L    = NOTE_VALUES[g.lengthIdx + 1] or 0.25
    local mult = (FEELS[g.feelIdx + 1] or FEELS[1]).mult
    local F    = FREQ_VALUES[g.freqIdx + 1] or 1
    rate = { mode = "sync", cycleSec = musicalCycleSec(spanT0, L, mult, F) }
  else
    rate = { mode = "free", cycles = g.cycles }
  end

  -- Value-unit conversion from native % sliders.
  local mid  = (vmin + vmax) / 2
  local half = (vmax - vmin) / 2
  local center     = mid + (g.baseline / 100) * half
  local baseHalf   = (g.amplitude / 100) * half
  local tiltOffset = (g.tilt / 100) * (vmax - vmin)

  local params = {
    shape      = shape,
    rate       = rate,
    amplitude  = baseHalf,             -- VALUE-UNIT half-swing (baseHalf)
    baseline   = center,               -- VALUE-UNIT center
    tiltOffset = tiltOffset,           -- VALUE-UNIT full-range offset (applied *rel)
    density    = ppc,
    phase      = g.phase / 100,        -- slider 0..100 -> cycles 0..1 (100 = one full cycle)
    ampSkew    = g.ampSkew / 100,      -- [-1,1]
    pulseWidth = g.pulseWidth,
    freqSkew   = g.freqSkew / 100,     -- [-1,1]
    swing      = g.swing,
    -- Random seed (v2.1 U2): forwarded so Re-roll yields a fresh pattern and the
    -- pattern stays stable while other sliders are dragged (seed only changes on Re-roll).
    seed          = g.seed or 0,
    smooth        = (g.smooth or 0) / 100,                                  -- 0..1 blend toward sine
    quantizeSteps = (g.steps and g.steps >= 2) and g.steps or nil,         -- nil = off
    curve         = g.curve or 0,                                          -- Pump/AD ease (0..100)
    attack        = g.attack or 50,                                        -- AD peak position (%)
    edge          = (g.edge or 50) / 200,                                  -- Trapezoid edge -> [0,0.5]
  }
  return params, ccShape
end

-- Core generate+write. Returns (count|nil, errString|nil). `noUndo` true => the caller
-- owns the undo block (live drag); false => self-contained single-undo write.
local function generateAndWrite(state, detected, g, noUndo)
  local tgt, tErr = target.fromContext(detected)
  if not tgt then return nil, tErr or "No target" end
  -- Pin the panel's CC# as the write target (CC only; retarget without re-clicking a lane).
  if tgt.kind and tgt:kind() == "cc" then tgt._lane = g.ccNum end

  local vmin, vmax = tgt:valueRange()
  local st0, st1 = spanFor(tgt, detected, g)   -- time selection or entire item/envelope
  local params, ccShape = buildParams(g, st0, vmin, vmax)

  local okGen, pts = pcall(lfo.generate, { t0 = st0, t1 = st1 }, params)
  if not okGen then return nil, "Generate failed: " .. tostring(pts) end
  if not pts or #pts == 0 then return nil, "No points generated (empty selection?)" end

  -- Pre-clamp to the target range (the write layer also clamps).
  for _, pt in ipairs(pts) do
    pt.value = math.max(vmin, math.min(vmax, pt.value))
  end

  return tgt:write(pts, st0, st1, { ccShape = ccShape, noUndo = noUndo })
end

-- BULK live write (v2.1 P): generate points, then write via the cached target +
-- decoded snapshot using the atomic MIDI_SetAllEvts path (no per-event Insert/Delete,
-- no MIDI_Sort, no full scan per frame). The caller owns the coalesced undo block,
-- so noUndo=true. Returns (count|nil, errString|nil). `tgt` and `snapshot` are the
-- CACHED gesture objects — never re-fetched here.
local function liveBulkWrite(tgt, snapshot, detected, g)
  -- Pin the panel's CC# as the write target (CC only; retarget without re-clicking a lane).
  if tgt.kind and tgt:kind() == "cc" then tgt._lane = g.ccNum end

  local vmin, vmax = tgt:valueRange()
  local st0, st1 = spanFor(tgt, detected, g)   -- time selection or entire item/envelope
  local params, ccShape = buildParams(g, st0, vmin, vmax)

  local okGen, pts = pcall(lfo.generate, { t0 = st0, t1 = st1 }, params)
  if not okGen then return nil, "Generate failed: " .. tostring(pts) end
  if not pts or #pts == 0 then return nil, "No points generated (empty selection?)" end

  -- No pre-clamp loop here: writeBulk clamps+floors every value via clampCC internally
  -- (single clamp site). Keeping a redundant clamp here would be a no-op on the final
  -- written values.
  return tgt:writeBulk(snapshot, pts, st0, st1, { ccShape = ccShape, noUndo = true })
end

-- The currently-selected shape id (defaults to "none").
local function currentShapeId(g)
  return SHAPES[g.shapeIdx + 1] and SHAPES[g.shapeIdx + 1].id or "none"
end

-- Whether a live write can run right now (CC target + a time selection + valid CC#
-- + a REAL shape selected). When shape == "none" (the default, v2.1 U1) we generate
-- and write NOTHING — this is the explicit no-op gate that stops auto-generation on
-- first open until the user picks a shape.
local function canGenerate(detected, g)
  if not (detected and currentShapeId(g) ~= "none" and detected.details) then return false end
  -- A time selection is required in Time-selection scope AND always for envelopes (time-sel only);
  -- Entire-item scope (CC/AI) uses fullSpan() and needs no time selection.
  local needTimeSel = g.scope == SCOPE_TIMESEL or detected.target == "envelope"
  if needTimeSel and not detected.hasTimeSel then return false end
  if detected.target == "cc" then
    return g.ccNum >= 0 and g.ccNum <= 127 and detected.details.take ~= nil
  elseif detected.target == "envelope" then
    return detected.details.env ~= nil
  elseif detected.target == "ai" then
    return detected.details.env ~= nil and detected.details.aiIndex ~= nil
  end
  return false
end

-- Mark the live gesture take's item dirty so a flags=4 (UNDO_STATE_ITEMS) EndBlock2 produces
-- an entry that is actually visible in the Undo History window. Two-step (item -> track) lookup
-- to avoid the ambiguous take->track call. Guarded against a nil/stale take.
local function markLiveTakeDirty()
  local take = liveGesture.take
  if not take then return end
  if not (reaper.GetMediaItemTake_Item and reaper.GetMediaItem_Track and reaper.MarkTrackItemsDirty) then
    return
  end
  local item = reaper.GetMediaItemTake_Item(take)
  if not item then return end
  local track = reaper.GetMediaItem_Track(item)
  reaper.MarkTrackItemsDirty(track, item)
end

-- Close any open live-undo block. Safe to call when none is open (no-op).
-- `committed` true => the gesture made edits (label it); false => suppress the entry.
local function endLiveGesture(committed, label)
  if not liveGesture.open then return end
  if committed then
    -- Mark dirty BEFORE EndBlock2 so the flags=4 entry is visible in the Undo History.
    -- Fallback if single-item MIDI undo ever fails to register on a REAPER build: the
    -- documented alternative is reaper.Undo_OnStateChange_Item(0, label, item) at gesture end.
    -- (Keep this working markLiveTakeDirty + EndBlock2(...,4) pattern; do NOT switch mechanisms.)
    markLiveTakeDirty()  -- no-op for envelope gestures (no take/item)
    -- Undo flag is target-aware: CC edits are items (4); envelope edits use ALL (-1) since point
    -- changes aren't captured by the items flag. Set when the gesture opened (default CC).
    reaper.Undo_EndBlock2(0, label or liveGesture.undoLabel or "Contour: Generate CC LFO",
      liveGesture.undoFlag or 4)
  else
    reaper.Undo_EndBlock2(0, "", 0)  -- flags=0 => no undo entry for a no-op gesture
  end
  liveGesture.open = false
  liveGesture.take = nil
  liveGesture.tgt = nil
  liveGesture.snapshot = nil
  liveGesture.errored = false
end

-- Called from contour.lua's reaper.atexit and on window close to guard a dangling block.
function M.cleanup()
  if liveGesture.open then
    -- Mark dirty BEFORE EndBlock2 so the defensive flags=4 entry is visible in the History
    -- window and the user can undo any partial live edit.
    markLiveTakeDirty()
    reaper.Undo_EndBlock2(0, liveGesture.undoLabel or "Contour: Generate CC LFO", liveGesture.undoFlag or 4)
    liveGesture.open = false
    liveGesture.take = nil
    liveGesture.tgt = nil
    liveGesture.snapshot = nil
  end
  liveGesture.errored = false
end

-- Per-row reset is now DOUBLE-CLICK on the fader (snap to the default notch) — see tickReset
-- below. The old small "R" SmallButton per row was removed (the user preferred the double-click).
-- CC# (an InputInt, not a fader) keeps its own inline R button.

-- Per-target default amplitude: envelopes/automation items default to FULL range (100); MIDI CC to
-- the native 50. Single source of truth for the edge-triggered default AND both Reset paths.
local function defaultAmp(detected)
  local t = detected and detected.target
  return ((t == "envelope" or t == "ai") and 100) or 50
end

-- Draw a small "notch" on the just-drawn slider at its default value, so the neutral/default
-- position is visible like a fader detent. Call IMMEDIATELY after the slider (before any SameLine
-- button). The slider frame is [itemMin.x, itemMin.x + CalcItemWidth]; the default value maps into
-- it. Guarded for missing DrawList APIs (older ReaImGui).
local function drawDefaultTick(ctx, vmin, vmax, vdef)
  if not (reaper.ImGui_GetItemRectMin and reaper.ImGui_GetItemRectMax and reaper.ImGui_GetWindowDrawList
      and reaper.ImGui_DrawList_AddLine and reaper.ImGui_CalcItemWidth) then return end
  if vmax <= vmin then return end
  local x0, y0 = reaper.ImGui_GetItemRectMin(ctx)
  local _, y1 = reaper.ImGui_GetItemRectMax(ctx)
  local frameW = reaper.ImGui_CalcItemWidth(ctx)
  if not frameW or frameW <= 0 then return end
  local inset = math.min(7, frameW * 0.04)
  local frac = (vdef - vmin) / (vmax - vmin)
  if frac < 0 then frac = 0 elseif frac > 1 then frac = 1 end
  local x = x0 + inset + frac * (frameW - 2 * inset)
  local dl = reaper.ImGui_GetWindowDrawList(ctx)
  reaper.ImGui_DrawList_AddLine(dl, x, y0 + 2, x, y1 - 2, 0xFFFFFFA0, 1.0)
end

-- Draw the default notch on the just-drawn slider AND snap it to that default on DOUBLE-CLICK
-- (replaces the per-row reset button). Must be called IMMEDIATELY after the slider. The value is
-- overridden AFTER the widget returned, so the single frame-end live write lands on the default
-- with no flicker. Returns true if a reset happened (so the caller marks the frame edited).
local function tickReset(ctx, g, key, vmin, vmax, vdef)
  drawDefaultTick(ctx, vmin, vmax, vdef)
  -- Double-click the slider's LABEL to reset to the default notch. (Double-clicking the fader head
  -- itself doesn't work: the slider widget consumes the click before IsItemHovered/IsMouseDoubleClicked
  -- can see it — IsItemHovered is false while the slider is active. Label double-click is reliable.)
  -- The value is overridden after the widget returns, so the frame-end live write lands on the default.
  if reaper.ImGui_IsItemHovered and reaper.ImGui_IsMouseDoubleClicked
     and reaper.ImGui_IsItemHovered(ctx) and reaper.ImGui_IsMouseDoubleClicked(ctx, 0) then
    g[key] = vdef
    return true
  end
  return false
end

function M.draw(ctx, state, detected)
  local g = ui(state)

  -- CC# follows the last-clicked CC lane (edge-triggered). Manual edits survive until the
  -- editor's clicked lane actually changes.
  if detected and detected.target == "cc" and detected.details and detected.details.midiEditor then
    local lane = reaper.MIDIEditor_GetSetting_int(detected.details.midiEditor, "last_clicked_cc_lane")
    if lane and lane >= 0 and lane <= 127 then
      if g.ccNum < 0 then
        g.ccNum = lane
      elseif state.follow and lane ~= g.lastLane then
        g.ccNum = lane
      end
      g.lastLane = lane
    end
  end

  -- Amplitude follows the per-target default (envelope/AI 100, CC 50) until you change it. Edge-
  -- triggered on the detected target so a manually-set amplitude survives, but first run AND target
  -- switches land on the right default — matching what Reset / double-click give.
  if detected and detected.target and detected.target ~= g.lastAmpTarget then
    if not g.ampDirty then g.amplitude = defaultAmp(detected) end
    g.lastAmpTarget = detected.target
  end
  if g.ccNum < 0 then g.ccNum = 1 end

  -- NOTE: amplitude is NOT auto-changed on context switch (that reset the value when hopping
  -- between envelopes/takes). The per-target default (envelope/AI = full range 100, CC = 50) is
  -- applied ONLY by the Reset button / per-row R, so your settings stay put across selections.

  -- If the user navigated away from the Generate op mid-drag, the live block would otherwise
  -- dangle. Commit it cleanly here before any further orchestration. (Defensive in-panel
  -- guard; shell also calls M.cleanup on op change.)
  if liveGesture.open and state.op ~= "generate" then
    endLiveGesture(true)  -- nil label => use the target-aware liveGesture.undoLabel
  end

  -- A live-drag is keyed to a specific take; if the target take changed mid-gesture
  -- (lane/clip re-target), close the old block cleanly before anything else writes.
  local curTake = detected and detected.details and detected.details.take or nil
  if liveGesture.open and liveGesture.take and curTake ~= liveGesture.take then
    endLiveGesture(true)  -- nil label => use the target-aware liveGesture.undoLabel
  end

  reaper.ImGui_Text(ctx, "Generate LFO")

  -- == Live toggle ==
  do
    local rv, v = reaper.ImGui_Checkbox(ctx, "Live##gen_live", g.live)
    if rv then
      g.live = v
      -- Turning Live OFF mid-drag: cleanly close any open block.
      if not g.live then endLiveGesture(true) end  -- nil label => target-aware liveGesture.undoLabel
    end
  end
  reaper.ImGui_SameLine(ctx)
  reaper.ImGui_TextColored(ctx, COLOR_HINT, g.live and "on (auto-apply)" or "off (click Generate)")

  reaper.ImGui_Separator(ctx)

  -- editedThisFrame is OR-accumulated from every interactive widget below; it is the
  -- "a value actually changed this frame" gate that prevents idle-frame writes.
  local editedThisFrame = false
  local function acc(changed) if changed then editedThisFrame = true end end

  -- == Shape ==
  do
    -- Combo reports `changed` even when the user re-picks the current item; only treat it as
    -- a real edit (and trigger a live write) when the index actually moved.
    local changed, idx = reaper.ImGui_Combo(ctx, "Shape##gen_shape", g.shapeIdx, SHAPE_ITEMS, #SHAPE_ITEMS)
    if changed and idx ~= g.shapeIdx then g.shapeIdx = idx; acc(true) end

    -- Re-roll (v2.1 U2): only meaningful for the Random / S&H shape. Assigns a NEW
    -- seed so a fresh pattern generates. The seed stays STABLE while dragging other
    -- sliders, so random doesn't jump around as you tweak amplitude etc.
    if currentShapeId(g) == "random" then
      reaper.ImGui_SameLine(ctx)
      if reaper.ImGui_Button(ctx, "Re-roll##gen_reroll") then
        g.seed = math.random(1, 2147483647)  -- 2^31-1
        acc(true)
      end
    end
  end

  -- == Scope == (CC + Automation Item: write across the Time selection OR the Entire item.
  -- Envelopes are TIME-SELECTION ONLY — a track envelope has no item — so the selector is hidden
  -- for them and the span is always the time selection.)
  if not (detected and detected.target == "envelope") then
    local changed, idx = reaper.ImGui_Combo(ctx, "Scope##gen_scope", g.scope, SCOPE_ITEMS, #SCOPE_ITEMS)
    if changed and idx ~= g.scope then g.scope = idx; acc(true) end
  end

  -- == Rate ==
  reaper.ImGui_Text(ctx, "Rate")
  do
    local changed, idx = reaper.ImGui_Combo(ctx, "Mode##gen_ratemode", g.rateMode, RATE_ITEMS, #RATE_ITEMS)
    if changed and idx ~= g.rateMode then g.rateMode = idx; acc(true) end
  end
  if g.rateMode == RATE_MUSICAL then
    -- Native parity: Length (note value) x Feel (straight/triplet/dotted) x Frequency multiplier.
    -- Length & Frequency are SLIDERS (per request) over the note-value list; the format string is
    -- the current note label (e.g. "1/4"), so the slider reads like native's value field. Feel
    -- stays a small 3-option dropdown.
    local cL, iL = reaper.ImGui_SliderInt(ctx, "Length##gen_len", g.lengthIdx, 0, #NOTE_VALUES - 1, NOTE_LABELS[g.lengthIdx + 1] or "")
    if cL and iL ~= g.lengthIdx then g.lengthIdx = math.max(0, math.min(#NOTE_VALUES - 1, iL)); acc(true) end
    acc(tickReset(ctx, g, "lengthIdx", 0, #NOTE_VALUES - 1, DEFAULTS.lengthIdx))
    local cM, iM = reaper.ImGui_Combo(ctx, "Feel##gen_feel", g.feelIdx, FEEL_ITEMS, #FEEL_ITEMS)
    if cM and iM ~= g.feelIdx then g.feelIdx = iM; acc(true) end
    local cF, iF = reaper.ImGui_SliderInt(ctx, "Frequency##gen_freq", g.freqIdx, 0, #FREQ_VALUES - 1, FREQ_LABELS[g.freqIdx + 1] or "")
    if cF and iF ~= g.freqIdx then g.freqIdx = math.max(0, math.min(#FREQ_VALUES - 1, iF)); acc(true) end
    acc(tickReset(ctx, g, "freqIdx", 0, #FREQ_VALUES - 1, DEFAULTS.freqIdx))
  elseif g.rateMode == RATE_FREE then
    local changed
    changed, g.cycles = reaper.ImGui_SliderInt(ctx, "Cycles##gen_cycles", g.cycles, 1, 64, "%d")
    acc(changed)
    acc(tickReset(ctx, g, "cycles", 1, 64, DEFAULTS.cycles))
  else -- RATE_HZ
    local changed
    changed, g.hz = reaper.ImGui_SliderDouble(ctx, "Hz##gen_hz", g.hz, 0.01, 50.0, "%.2f")
    acc(changed)
    acc(tickReset(ctx, g, "hz", 0.01, 50.0, DEFAULTS.hz))
  end

  reaper.ImGui_Separator(ctx)

  -- == Level ==
  reaper.ImGui_Text(ctx, "Level")
  do
    local changed
    -- Baseline -100..100 (0 = center). Double-click the fader to snap to the notch (default).
    changed, g.baseline = reaper.ImGui_SliderInt(ctx, "Baseline##gen_base", g.baseline, -100, 100, "%d")
    acc(changed)
    acc(tickReset(ctx, g, "baseline", -100, 100, 0))
    -- Amplitude: linear -200..200 (% of half range; negative inverts the wave, >100 clips). Plain
    -- SliderInt so Ctrl+click type-entry works. Notch + double-click snap to the per-target default
    -- (envelope/AI 100, CC 50).
    changed, g.amplitude = reaper.ImGui_SliderInt(ctx, "Amplitude##gen_amp", g.amplitude, -200, 200, "%d")
    if changed then g.ampDirty = true end   -- user moved it: stop following the per-target default
    acc(changed)
    -- Double-click reset to the per-target default also resumes following it.
    if tickReset(ctx, g, "amplitude", -200, 200, defaultAmp(detected)) then g.ampDirty = false; acc(true) end
  end

  reaper.ImGui_Separator(ctx)

  -- == Shaping (native CC LFO parity + extras) ==
  reaper.ImGui_Text(ctx, "Shaping")
  do
    local changed
    local sid = currentShapeId(g)
    -- Random / Drift use dedicated emitters that ignore Phase, Freq skew, Swing and the
    -- Steps / Smooth modifiers — hide those controls for them so the panel shows only what has effect.
    local special = (sid == "random" or sid == "drift")
    -- Phase 0..100 slider units (phase/100 cycles; 100 = one full cycle), converted in buildParams.
    -- All shaping faders: double-click snaps to the notch (default).
    if not special then
      changed, g.phase = reaper.ImGui_SliderInt(ctx, "Phase##gen_phase", g.phase, 0, 100, "%d")
      acc(changed); acc(tickReset(ctx, g, "phase", 0, 100, 0))
    end
    -- Amp skew / Tilt apply to every shape (the dedicated emitters use them too). Freq skew is gated
    -- below with the other periodic-only modulators.
    changed, g.ampSkew = reaper.ImGui_SliderInt(ctx, "Amp skew##gen_ampskew", g.ampSkew, -100, 100, "%d")
    acc(changed); acc(tickReset(ctx, g, "ampSkew", -100, 100, 0))
    -- Pulse width only for Square.
    if currentShapeId(g) == "square" then
      changed, g.pulseWidth = reaper.ImGui_SliderDouble(ctx, "Pulse width##gen_pw", g.pulseWidth, 0.01, 0.99, "%.2f")
      acc(changed); acc(tickReset(ctx, g, "pulseWidth", 0.01, 0.99, 0.5))
    end
    -- Edge only for Trapezoid (0 = square, 100 = triangle).
    if currentShapeId(g) == "trapezoid" then
      changed, g.edge = reaper.ImGui_SliderInt(ctx, "Edge##gen_edge", g.edge, 0, 100, "%d")
      acc(changed); acc(tickReset(ctx, g, "edge", 0, 100, 50))
    end
    -- Attack for Triangle (peak position, % of cycle).
    if currentShapeId(g) == "triangle" then
      changed, g.attack = reaper.ImGui_SliderInt(ctx, "Attack##gen_attack", g.attack, 1, 99, "%d")
      acc(changed); acc(tickReset(ctx, g, "attack", 1, 99, 50))
    end
    -- Curve for Saw Up/Down + Triangle (ease steepness). Bipolar: 0 = linear, + one way, - the other.
    if currentShapeId(g) == "saw" or currentShapeId(g) == "sawdown" or currentShapeId(g) == "triangle" then
      changed, g.curve = reaper.ImGui_SliderInt(ctx, "Curve##gen_curve", g.curve, -100, 100, "%d")
      acc(changed); acc(tickReset(ctx, g, "curve", -100, 100, 0))
    end
    if not special then
      changed, g.freqSkew = reaper.ImGui_SliderInt(ctx, "Freq skew##gen_freqskew", g.freqSkew, -100, 100, "%d")
      acc(changed); acc(tickReset(ctx, g, "freqSkew", -100, 100, 0))
    end
    changed, g.tilt = reaper.ImGui_SliderInt(ctx, "Tilt##gen_tilt", g.tilt, -100, 100, "%d")
    acc(changed); acc(tickReset(ctx, g, "tilt", -100, 100, 0))
    if not special then
      changed, g.swing = reaper.ImGui_SliderDouble(ctx, "Swing##gen_swing", g.swing, -1.0, 1.0, "%.2f")
      acc(changed); acc(tickReset(ctx, g, "swing", -1.0, 1.0, 0.0))
    end
    -- Steps quantizes the wave into N flat levels (a staircase). Meaningless on Square (already 2
    -- levels) and on the special generators.
    if not special and sid ~= "square" then
      changed, g.steps = reaper.ImGui_SliderInt(ctx, "Steps##gen_steps", g.steps, 0, 32, g.steps < 2 and "off" or "%d")
      acc(changed); acc(tickReset(ctx, g, "steps", 0, 32, 0))
    end
    -- Smooth rounds the shape toward a sine. Meaningless on Sine (already a sine) and the specials.
    if not special and sid ~= "sine" then
      changed, g.smooth = reaper.ImGui_SliderInt(ctx, "Smooth##gen_smooth", g.smooth, 0, 100, "%d")
      acc(changed); acc(tickReset(ctx, g, "smooth", 0, 100, 0))
    end
  end

  reaper.ImGui_Separator(ctx)

  -- == CC number (MIDI CC target only; envelopes have no lane) ==
  if detected and detected.target == "cc" then
    -- "CC###gen_cc" renders blank because ImGui eats everything after the first "##" as the
    -- ID. Draw a visible "CC#" label, then an InputInt with an ID-only ("##") label.
    reaper.ImGui_Text(ctx, "CC#")
    reaper.ImGui_SameLine(ctx)
    local changed
    changed, g.ccNum = reaper.ImGui_InputInt(ctx, "##gen_cc", g.ccNum)
    if g.ccNum < 0 then g.ccNum = 0 elseif g.ccNum > 127 then g.ccNum = 127 end
    acc(changed)
    -- CC# is intentionally NOT in DEFAULTS (the global Reset preserves the lane), so its
    -- per-row reset uses an explicit default of CC1 (same fallback as the first-open default).
    reaper.ImGui_SameLine(ctx)
    if reaper.ImGui_SmallButton(ctx, "R##reset_ccnum") then g.ccNum = 1; acc(true) end
    if reaper.ImGui_SetItemTooltip then
      reaper.ImGui_SetItemTooltip(ctx, "Reset to default")
    elseif reaper.ImGui_IsItemHovered and reaper.ImGui_IsItemHovered(ctx)
       and reaper.ImGui_SetTooltip then
      reaper.ImGui_SetTooltip(ctx, "Reset to default")
    end
  end

  -- == Reset (v2.1 U3) ==
  -- Restores ALL Generate controls to their documented defaults (shape -> None, so
  -- the panel returns to the no-op state). Lane (ccNum/lastLane), seed, and Live are
  -- intentionally preserved. Because shape becomes None, this does NOT trigger a write.
  if reaper.ImGui_Button(ctx, "Reset##gen_reset") then
    resetDefaults(g)
    g.amplitude = defaultAmp(detected)   -- target-aware (envelope/AI = 100, CC = 50)
    g.ampDirty = false                   -- resume following the per-target default
    acc(true)
  end

  reaper.ImGui_Separator(ctx)

  -- == Status / hints ==
  local ready = canGenerate(detected, g)
  local tgtKind = detected and detected.target
  if tgtKind ~= "cc" and tgtKind ~= "envelope" and tgtKind ~= "ai" then
    reaper.ImGui_TextColored(ctx, COLOR_HINT, "Select a MIDI CC lane, a track envelope, or an automation item.")
  elseif g.scope == SCOPE_TIMESEL and not detected.hasTimeSel then
    reaper.ImGui_TextColored(ctx, COLOR_HINT, "Make a time selection (or switch Scope to Entire item).")
  elseif currentShapeId(g) == "none" then
    -- v2.1 U1: the default None shape is a no-op; prompt the user to choose a shape.
    reaper.ImGui_TextColored(ctx, COLOR_HINT, "Pick a shape to generate")
  end

  -- Clip hint: convert the native % sliders to value units (CC lane MID=63.5, HALF=63.5)
  -- and check whether the waveform plus the full tilt drift exceeds 0..127. center +/- baseHalf
  -- is the un-tilted swing; +tiltOffset (full at the right edge) is the worst-case drift.
  if detected and detected.target == "cc" then
    local MID, HALF, RANGE = 63.5, 63.5, 127
    local center     = MID + (g.baseline / 100) * HALF
    local baseHalf   = (g.amplitude / 100) * HALF
    local tiltOffset = (g.tilt / 100) * RANGE
    local lo = center - baseHalf + math.min(0, tiltOffset)
    local hi = center + baseHalf + math.max(0, tiltOffset)
    if lo < 0 or hi > 127 then
      reaper.ImGui_TextColored(ctx, COLOR_HINT, "Values will clip to 0-127")
    end
  end

  -- ==========================================================================
  -- LIVE PREVIEW gesture orchestration.
  --   * One undo block per drag gesture (coalesced across all widgets + frames).
  --   * IsAnyItemActive keeps the gesture open while any widget is held.
  --   * Writes only fire on frames where a value actually changed (editedThisFrame).
  --   * pcall safety: a failed write closes the block and reports — never dangles.
  -- ==========================================================================
  if g.live then
    local anyActive = reaper.ImGui_IsAnyItemActive and reaper.ImGui_IsAnyItemActive(ctx) or false

    if ready and editedThisFrame then
      -- Open the gesture's single undo block on the first edited frame, AND cache the
      -- target + a one-time decoded snapshot of the take's whole event buffer. The
      -- snapshot is the pristine, pre-edit CC data; every live frame re-derives from it
      -- (replace-in-range never mutates it), so edits never compound. We do NOT call
      -- target.fromContext or MIDI_GetAllEvts again until the take changes.
      -- Do NOT re-open a block while errored: a broken take (snapshot/fromContext failure)
      -- would otherwise flood the undo stack with a begin/end pair every drag frame. The
      -- errored latch clears only when the gesture truly ends (endLiveGesture / cleanup).
      if not liveGesture.open and not liveGesture.errored then
        reaper.Undo_BeginBlock2(0)
        liveGesture.open = true
        liveGesture.take = curTake
        -- Target-aware undo metadata for endLiveGesture/cleanup: CC -> items flag (4); envelope AND
        -- automation item -> ALL (-1) so envelope point edits are captured.
        if detected.target == "envelope" then
          liveGesture.undoFlag, liveGesture.undoLabel = -1, "Contour: Generate envelope LFO"
        elseif detected.target == "ai" then
          liveGesture.undoFlag, liveGesture.undoLabel = -1, "Contour: Generate automation-item LFO"
        else
          liveGesture.undoFlag, liveGesture.undoLabel = 4, "Contour: Generate CC LFO"
        end

        local tgt, tErr = target.fromContext(detected)
        if not tgt then
          g.status = tErr or "No target"; g.statusErr = true
          endLiveGesture(false, "")
          liveGesture.errored = true  -- set AFTER endLiveGesture (which clears the latch)
        else
          local snap, sErr = tgt:snapshot()
          if not snap then
            g.status = sErr or "Snapshot failed"; g.statusErr = true
            endLiveGesture(false, "")
            liveGesture.errored = true  -- set AFTER endLiveGesture (which clears the latch)
          else
            liveGesture.tgt = tgt
            liveGesture.snapshot = snap
          end
        end
      end

      -- Only write if the gesture is still open and the cache is valid.
      if liveGesture.open and liveGesture.tgt and liveGesture.snapshot then
        -- No per-frame PreventUIRefresh here: research shows it does NOT improve live MIDI
        -- smoothness (the MIDI_SetAllEvts path is already a single atomic call) and only adds
        -- overhead. pcall keeps a thrown write from dangling the open undo block.
        local okWrite, count, wErr = pcall(liveBulkWrite, liveGesture.tgt, liveGesture.snapshot, detected, g)
        if not okWrite then
          count, wErr = nil, "Live write error: " .. tostring(count)
        end
        if not count then
          -- Surface the error and close the block so nothing dangles.
          g.status = wErr or "Live write failed"; g.statusErr = true
          endLiveGesture(true, liveGesture.undoLabel)
        else
          if detected.target == "envelope" then
            g.status = ("Live: %d envelope points"):format(count)
          elseif detected.target == "ai" then
            g.status = ("Live: %d automation-item points"):format(count)
          else
            g.status = ("Live: %d CC events on CC%d"):format(count, g.ccNum)
          end
          g.statusErr = false
        end
      end
    end

    -- Gesture end: nothing is active anymore (mouse released / focus lost). Close the
    -- single coalesced undo block. Only happens after the block was opened by an edit.
    if liveGesture.open and not anyActive then
      endLiveGesture(true)  -- nil label => use the target-aware liveGesture.undoLabel
    elseif liveGesture.errored and not anyActive then
      -- An errored gesture already closed its block; clear the latch on release so the
      -- NEXT drag can re-attempt cleanly (endLiveGesture is a no-op when nothing is open).
      liveGesture.errored = false
    end
  else
    -- Non-live: the Generate button commits on click (slice-3 behavior).
    if reaper.ImGui_BeginDisabled then
      reaper.ImGui_BeginDisabled(ctx, not ready)
      if reaper.ImGui_Button(ctx, "Generate##gen_run") then M.run(state, detected, g) end
      reaper.ImGui_EndDisabled(ctx)
    elseif ready then
      if reaper.ImGui_Button(ctx, "Generate##gen_run") then M.run(state, detected, g) end
    end
  end

  if g.status ~= "" then
    reaper.ImGui_TextColored(ctx, g.statusErr and COLOR_ERR or COLOR_OK, g.status)
  end
end

-- Non-live commit (Generate button). Self-contained single undo. Sets g.status; never throws.
function M.run(state, detected, g)
  local function fail(msg) g.status = msg; g.statusErr = true end
  local function ok(msg)   g.status = msg; g.statusErr = false end

  local tk = detected and detected.target
  if tk ~= "cc" and tk ~= "envelope" and tk ~= "ai" then
    fail("Select a MIDI CC lane, a track envelope, or an automation item")
    return
  end
  if (g.scope == SCOPE_TIMESEL or tk == "envelope") and not detected.hasTimeSel then
    fail("Make a time selection") return
  end
  if tk == "cc" and (g.ccNum < 0 or g.ccNum > 127) then fail("Set a valid CC# (0-127)") return end
  -- Defense-in-depth (v2.1 U1): the UI button is gated by canGenerate, but M.run is public
  -- and must never overwrite with a flat line when None is selected.
  if currentShapeId(g) == "none" then fail("Pick a shape to generate") return end

  local count, wErr = generateAndWrite(state, detected, g, false)  -- self-contained undo
  if not count then fail(wErr or "Write failed") return end
  if tk == "cc" then ok(("Wrote %d CC events to CC%d"):format(count, g.ccNum))
  elseif tk == "ai" then ok(("Wrote %d automation-item points"):format(count))
  else ok(("Wrote %d envelope points"):format(count)) end
end

return M
