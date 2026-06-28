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
-- The Custom draw pad + preset store, fades/quantize/randomness/smooth controls are all
-- implemented here alongside the core LFO controls.
local M = {}

local lfo         = require("core.lfo")
local target      = require("core.target")
local customshape = require("core.customshape")
local starters    = require("core.starters")
local genpreset   = require("core.genpreset")
local drawpad     = require("ui.drawpad")
local common      = require("ui.common")

-- Shape ids MUST match what core/shapes.lua / core/lfo.lua expect. "None" is FIRST and the
-- DEFAULT (v2.1 U1): a NO-OP — picking it generates and writes NOTHING (canGenerate=false),
-- so the panel doesn't auto-write on first open until a real shape is chosen. Shapes are
-- ordered by family: tonal (sine/triangle/saw/sawdown/square/trapezoid/parametric), harmonic
-- (rectsine/sine²), stochastic (random/drift).
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
  { id = "custom",     label = "Custom (draw)" },   -- last: a user-drawn shape, set apart from the presets
}


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
local FEEL_ITEMS   = ""
for _, f in ipairs(FEELS) do FEEL_ITEMS = FEEL_ITEMS .. f.label .. "\0" end

-- Scope + spanFor live in ui.common (shared with the other panels); use common.SCOPE_* and
-- common.spanFor instead of re-defining them here.

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
  custom     = { ppc = 8,  ccShape = 1 },   -- user-drawn; dedicated emitter tags per-point shapes
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
--   tilt      -100..100  Tilt L: anchored left  (0 at left, full at right -> moves the RIGHT end)
--   tiltR     -100..100  Tilt R: anchored right (0 at right, full at left -> moves the LEFT end)
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
  tilt       = 0,        -- -100..100 % Tilt L (anchored left; SliderInt)
  tiltR      = 0,        -- -100..100 % Tilt R (anchored right; SliderInt)
  swing      = 0.0,
  steps      = 0,        -- 0 = off; >=2 quantizes any shape to N levels
  smooth     = 0,        -- 0..100 % blend toward sine
  curve      = 0,        -- -100..100 (Saw/Triangle bezier ease steepness; bipolar, 0 = linear)
  attack     = 50,       -- 1..99 % of cycle (Triangle peak position)
  edge       = 50,       -- 0..100 % (Trapezoid edge width; /200 => [0,0.5])
  scope      = common.SCOPE_TIMESEL,  -- Time selection (0) vs Entire item/envelope (1)
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
      tilt      = DEFAULTS.tilt,      -- -100..100 % Tilt L (anchored left)
      tiltR     = DEFAULTS.tiltR,     -- -100..100 % Tilt R (anchored right)
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

      custom    = nil,   -- { store = { presets }, idx = <active 1-based> }; lazily loaded from ExtState

      live      = true,   -- LIVE preview ON by default

      status    = "",
      statusErr = false,
    }
  end
  return state.gen
end

-- Reset (U3): restore every documented control to its default, in place (keep the
-- table reference — liveGesture / state hold no ref to it but other fields like
-- ccNum/seed/live must survive). Lane is intentionally preserved. The SELECTED SHAPE is
-- preserved too: Reset clears the parameters for the current shape, not the shape choice.
local function resetDefaults(g)
  local keepShape = g.shapeIdx
  for k, v in pairs(DEFAULTS) do g[k] = v end
  g.shapeIdx = keepShape
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

local function loadCustom()
  local store = customshape.decode(reaper.GetExtState("Contour", "customPresets") or "")
  if #store == 0 then store = { customshape.defaultPreset() } end
  for _, pr in ipairs(store) do pr.points = customshape.clampPoints(pr.points) end
  local idx = tonumber(reaper.GetExtState("Contour", "customIdx") or "") or 1
  if idx < 1 or idx > #store then idx = 1 end
  local gx, gy, sn, ph = (reaper.GetExtState("Contour", "customGrid") or ""):match("^(%d+),(%d+),(%d),?(%d*)")
  local gridX = math.max(1, math.min(64, tonumber(gx) or 4))   -- pad grid divisions (time)
  local gridY = math.max(1, math.min(64, tonumber(gy) or 2))   -- pad grid divisions (value)
  local padH = math.max(90, math.min(600, tonumber(ph) or 200)) -- stretchable pad height (px)
  return { store = store, idx = idx, gridX = gridX, gridY = gridY, snap = sn == "1", padH = padH }
end
local function saveCustom(c)
  reaper.SetExtState("Contour", "customPresets", customshape.encode(c.store), true)
  reaper.SetExtState("Contour", "customIdx", tostring(c.idx), true)
  reaper.SetExtState("Contour", "customGrid",
    string.format("%d,%d,%d,%d", c.gridX or 4, c.gridY or 2, c.snap and 1 or 0, c.padH or 200), true)
end
-- drag-to-resize state for the pad's bottom grabber (script-level; one panel instance)
local padResize = { active = false, startY = 0, startH = 0 }
local function activePoints(g)
  if not g.custom then g.custom = loadCustom() end
  local pr = g.custom.store[g.custom.idx]
  return pr and pr.points or {}
end

-- Generate-panel presets: capture/recall the documented controls (exactly the DEFAULTS keys: shape +
-- rate + level + every modulator) as named presets. Target-specific fields (lane/ccNum) and the Live
-- toggle are NOT captured. The custom-shape store is separate; a preset with shapeIdx=custom recalls
-- whichever custom preset is currently active.
local function captureParams(g)
  local params = {}
  for k in pairs(DEFAULTS) do params[k] = g[k] end
  return params
end
local function applyParams(g, params)
  for k in pairs(DEFAULTS) do if params[k] ~= nil then g[k] = params[k] end end
end
local function loadGenPresets()
  local store = genpreset.decode(reaper.GetExtState("Contour", "genPresets") or "")
  local idx = tonumber(reaper.GetExtState("Contour", "genPresetIdx") or "") or 0
  if idx < 0 or idx > #store then idx = 0 end   -- 0 = "(none)"; 1..#store selects a preset
  return { store = store, idx = idx }
end
local function saveGenPresets(gp)
  reaper.SetExtState("Contour", "genPresets", genpreset.encode(gp.store), true)
  reaper.SetExtState("Contour", "genPresetIdx", tostring(gp.idx or 0), true)
end
-- The encoded custom drawing to embed in a Generate preset (nil unless the shape is Custom), so a
-- Custom-based preset is self-contained. (Uses SHAPES directly, not currentShapeId, to stay above it.)
local function genPresetPoints(g)
  local sid = SHAPES[(g.shapeIdx or 0) + 1] and SHAPES[(g.shapeIdx or 0) + 1].id
  if sid ~= "custom" then return nil end
  return customshape.encodePoints(activePoints(g))
end
-- Recall a Generate preset: apply its controls, and if it embeds a Custom drawing (and lands on the
-- Custom shape), materialize that drawing into the Shape library — upsert a Shape named after the
-- preset and select it — so the preset reproduces its exact curve without depending on external state.
local function recallGenPreset(g, pr)
  applyParams(g, pr.params)
  local sid = SHAPES[(g.shapeIdx or 0) + 1] and SHAPES[(g.shapeIdx or 0) + 1].id
  if pr.points and pr.points ~= "" and sid == "custom" then
    if not g.custom then g.custom = loadCustom() end
    local pts = customshape.clampPoints(customshape.decodePoints(pr.points))
    local slot
    for i, sh in ipairs(g.custom.store) do if sh.name == pr.name then slot = i; break end end
    if slot then g.custom.store[slot].points = pts
    else g.custom.store[#g.custom.store + 1] = { name = pr.name, points = pts }; slot = #g.custom.store end
    g.custom.idx = slot
    saveCustom(g.custom)
  end
end

-- Build the lfo.generate params + per-shape output (ppc / ccShape) from panel state.
--
-- Generate v2.4: the panel sliders are in NATIVE % units; lfo.generate consumes VALUE units
-- (range-agnostic). Convert here using the target's value range (vmin/vmax). Let
-- MID = (vmin+vmax)/2 and HALF = (vmax-vmin)/2 (e.g. 63.5 / 63.5 on a 0..127 CC lane):
--   baseline(center) = MID + (baselinePct/100)*HALF      -- 0% => center, +/-100% => vmax/vmin
--   amplitude(baseHalf) = (amplitudePct/100)*HALF        -- 50% => 31.75
--   tiltOffset/tiltOffsetR = (tiltPct/100)*(vmax-vmin)   -- Tilt L (*rel) / Tilt R (*(1-rel))
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
  local center       = mid + (g.baseline / 100) * half
  local baseHalf     = (g.amplitude / 100) * half
  -- Two independent tilt sliders (value units): Tilt L is LEFT-anchored (applied *rel; the RIGHT end
  -- moves) and is REAPER's native tilt; Tilt R is RIGHT-anchored (applied *(1-rel); the LEFT end moves).
  local tiltOffset  = (g.tilt  / 100) * (vmax - vmin)   -- Tilt L (anchored left)
  local tiltOffsetR = (g.tiltR / 100) * (vmax - vmin)   -- Tilt R (anchored right)

  local params = {
    shape       = shape,
    rate        = rate,
    amplitude   = baseHalf,             -- VALUE-UNIT half-swing (baseHalf)
    baseline    = center,               -- VALUE-UNIT center
    tiltOffset  = tiltOffset,           -- Tilt L: applied *rel (left-anchored)
    tiltOffsetR = tiltOffsetR,          -- Tilt R: applied *(1-rel) (right-anchored)
    density     = ppc,
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
    curve         = g.curve or 0,                                          -- bipolar curvature -100..100 (Saw/Triangle Curve)
    attack        = g.attack or 50,                                        -- Triangle peak position (%)
    edge          = (g.edge or 50) / 200,                                  -- Trapezoid edge -> [0,0.5]
    customPoints  = (shape == "custom") and activePoints(g) or nil,
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
  local st0, st1 = common.spanFor(tgt, detected, g)   -- time selection or entire item/envelope
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
  local st0, st1 = common.spanFor(tgt, detected, g)   -- time selection or entire item/envelope
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

-- The custom draw-pad GHOST: ONE normalized cycle of the drawn shape AS RESHAPED by the per-cycle
-- modifiers (Swing / Steps / Smooth / Phase), so the pad shows what the drawn curve actually becomes.
-- Span-wide level/ramp modifiers (Tilt L/R, amp-skew, freq-skew, amplitude, baseline) are zeroed:
-- a single cycle sees only a slice of them, so drawing them here would misrepresent the multi-cycle
-- output (they read correctly in the live lane preview). Reuses buildParams + lfo.generate (no
-- re-implementation), so the ghost is exactly the engine. Returns a { {x,y}, ... } polyline in pad
-- space (x in [0,1], y in [-1,1]), or nil when the shape isn't custom / nothing generates.
local function customOverlayPoints(g)
  if currentShapeId(g) ~= "custom" then return nil end
  local params = buildParams(g, 0, -1, 1)               -- value units over a symmetric [-1,1] range
  params.rate        = { mode = "free", cycles = 1 }    -- one cycle fills the pad's x-axis
  params.amplitude   = 1                                -- full normalized height (level is shown in the lane)
  params.baseline    = 0
  params.tiltOffset  = 0                                -- span-wide -> excluded from the per-cycle view
  params.tiltOffsetR = 0
  params.ampSkew     = 0
  params.freqSkew    = 0
  local okGen, pts = pcall(lfo.generate, { t0 = 0, t1 = 1 }, params)
  if not okGen or not pts or #pts == 0 then return nil end
  local out = {}
  for _, p in ipairs(pts) do
    local y = p.value
    if y < -1 then y = -1 elseif y > 1 then y = 1 end   -- clamp to the pad (Smooth/overshoot can nudge past)
    -- carry the per-segment shape/tension so the pad tessellates curves (a sparse eased/bezier shape
    -- must not render as straight segments — that's what made a loaded sine look like a triangle).
    out[#out + 1] = { x = p.time, y = y, shape = p.shape, tension = p.tension }
  end
  return out
end

-- Whether a live write can run right now (CC target + a time selection + valid CC#
-- + a REAL shape selected). When shape == "none" (the default, v2.1 U1) we generate
-- and write NOTHING — this is the explicit no-op gate that stops auto-generation on
-- first open until the user picks a shape.
local function canGenerate(detected, g)
  if not (detected and currentShapeId(g) ~= "none" and detected.details) then return false end
  -- A time selection is required in Time-selection scope AND always for envelopes (time-sel only);
  -- Entire-item scope (CC/AI) uses fullSpan() and needs no time selection.
  local needTimeSel = g.scope == common.SCOPE_TIMESEL or detected.target == "envelope"
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

-- Per-row reset is now DOUBLE-CLICK on the fader (snap to the default notch) — see common.tickReset.
-- The old small "R" SmallButton per row was removed (the user preferred the double-click).
-- CC# (an InputInt, not a fader) keeps its own inline R button.

-- Per-target default amplitude: envelopes/automation items default to FULL range (100); MIDI CC to
-- the native 50. Single source of truth for the edge-triggered default AND both Reset paths.
local function defaultAmp(detected)
  local t = detected and detected.target
  return ((t == "envelope" or t == "ai") and 100) or 50
end

-- The default-notch draw + double-click reset (drawDefaultTick / tickReset) live in ui.common;
-- this panel calls common.tickReset directly.

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

  -- == Generate presets == (recall/save the WHOLE config — shape + rate + every control)
  do
    if not g.genPre then g.genPre = loadGenPresets() end
    local gp = g.genPre
    local items = "(none)\0"
    for _, pr in ipairs(gp.store) do items = items .. pr.name .. "\0" end
    reaper.ImGui_SetNextItemWidth(ctx, 180)
    local chg, idx = reaper.ImGui_Combo(ctx, "Preset##gen_preset", gp.idx, items, #gp.store + 1)
    if chg then
      gp.idx = idx
      if idx >= 1 and gp.store[idx] then recallGenPreset(g, gp.store[idx]); acc(true) end  -- recall (+ embedded shape)
      saveGenPresets(gp)
    end
    reaper.ImGui_SameLine(ctx)
    if reaper.ImGui_Button(ctx, "Save##gen_presave") and gp.idx >= 1 and gp.store[gp.idx] then
      gp.store[gp.idx].params = captureParams(g)                            -- overwrite with live settings
      gp.store[gp.idx].points = genPresetPoints(g); saveGenPresets(gp)      -- embed the drawing if Custom
    end
    reaper.ImGui_SameLine(ctx)
    if reaper.ImGui_Button(ctx, "New##gen_prenew") then
      gp.store[#gp.store + 1] = { name = "Preset " .. (#gp.store + 1), params = captureParams(g), points = genPresetPoints(g) }
      gp.idx = #gp.store; saveGenPresets(gp)
    end
    reaper.ImGui_SameLine(ctx)
    if reaper.ImGui_Button(ctx, "Del##gen_predel") and gp.idx >= 1 and gp.store[gp.idx] then
      table.remove(gp.store, gp.idx); if gp.idx > #gp.store then gp.idx = #gp.store end; saveGenPresets(gp)
    end
    if gp.idx >= 1 and gp.store[gp.idx] then                                -- rename the selected preset
      local pr = gp.store[gp.idx]
      reaper.ImGui_SetNextItemWidth(ctx, 180)
      local rv, nm = reaper.ImGui_InputText(ctx, "Name##gen_prename", pr.name or "")
      if rv then pr.name = nm end
      if reaper.ImGui_IsItemDeactivatedAfterEdit and reaper.ImGui_IsItemDeactivatedAfterEdit(ctx) then saveGenPresets(gp) end
    end
  end
  reaper.ImGui_Separator(ctx)

  -- == Shape ==
  do
    -- Built from BeginCombo/Selectable (not ImGui_Combo) so that picking the CURRENT shape again
    -- still counts as a trigger: a plain Combo only fires when the index moves, but the user wants
    -- re-selecting the same shape to re-apply (e.g. to re-stamp after editing the target).
    local cur = SHAPES[g.shapeIdx + 1] and SHAPES[g.shapeIdx + 1].label or "None"
    if reaper.ImGui_BeginCombo(ctx, "Shape##gen_shape", cur) then
      for i, s in ipairs(SHAPES) do
        local sel = (g.shapeIdx == i - 1)
        if reaper.ImGui_Selectable(ctx, s.label, sel) then g.shapeIdx = i - 1; acc(true) end
        if sel and reaper.ImGui_SetItemDefaultFocus then reaper.ImGui_SetItemDefaultFocus(ctx) end
      end
      reaper.ImGui_EndCombo(ctx)
    end

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

  if currentShapeId(g) == "custom" then
    if not g.custom then g.custom = loadCustom() end
    local c = g.custom
    -- shape-library dropdown (named drawn shapes; distinct from the panel-wide Generate "Preset")
    local names = {}
    for _, pr in ipairs(c.store) do names[#names + 1] = pr.name end
    local items = table.concat(names, "\0") .. "\0"
    local chg, idx = reaper.ImGui_Combo(ctx, "Shape##cust_preset", c.idx - 1, items, #items)
    if chg then c.idx = idx + 1; saveCustom(c); acc(true) end
    reaper.ImGui_SameLine(ctx)
    if reaper.ImGui_Button(ctx, "New##cust_new") then
      c.store[#c.store + 1] = { name = "Custom " .. (#c.store + 1), points = customshape.clampPoints(customshape.defaultPreset().points) }
      c.idx = #c.store; saveCustom(c); acc(true)
    end
    reaper.ImGui_SameLine(ctx)
    if reaper.ImGui_Button(ctx, "Del##cust_del") and #c.store > 1 then
      table.remove(c.store, c.idx); if c.idx > #c.store then c.idx = #c.store end; saveCustom(c); acc(true)
    end
    -- rename (inline text)
    do
      local pr = c.store[c.idx]
      local rv, nm = reaper.ImGui_InputText(ctx, "Name##cust_name", pr.name or "")
      if rv then pr.name = nm end
      if reaper.ImGui_IsItemDeactivatedAfterEdit and reaper.ImGui_IsItemDeactivatedAfterEdit(ctx) then saveCustom(c) end
    end
    -- start from a built-in shape: load the toolkit's OWN shape (via core.starters) into the current
    -- preset to tweak. Replaces the current points (New first to keep the old one).
    do
      local names = {}
      for _, s in ipairs(starters.list) do names[#names + 1] = s.name end
      reaper.ImGui_Text(ctx, "Start from"); reaper.ImGui_SameLine(ctx)
      reaper.ImGui_SetNextItemWidth(ctx, 150)
      local chg, si = reaper.ImGui_Combo(ctx, "##cust_starter", c.starterIdx or 0, table.concat(names, "\0") .. "\0", #names)
      if chg then c.starterIdx = si end
      reaper.ImGui_SameLine(ctx)
      if reaper.ImGui_Button(ctx, "Load##cust_loadshape") then
        local s = starters.list[(c.starterIdx or 0) + 1]
        if s then c.store[c.idx].points = customshape.clampPoints(starters.points(s.id)); saveCustom(c); acc(true) end
      end
    end
    -- grid density + snap (pad editing aids; they don't change the generated curve, so no re-apply)
    do
      reaper.ImGui_SetNextItemWidth(ctx, 86)
      local cgx, gx = reaper.ImGui_SliderInt(ctx, "Grid X##cust_gx", c.gridX or 4, 1, 32)
      if cgx then c.gridX = gx; saveCustom(c) end
      reaper.ImGui_SameLine(ctx)
      reaper.ImGui_SetNextItemWidth(ctx, 86)
      local cgy, gy = reaper.ImGui_SliderInt(ctx, "Grid Y##cust_gy", c.gridY or 2, 1, 32)
      if cgy then c.gridY = gy; saveCustom(c) end
      reaper.ImGui_SameLine(ctx)
      local csn, sn = reaper.ImGui_Checkbox(ctx, "Snap##cust_snap", c.snap and true or false)
      if csn then c.snap = sn; saveCustom(c) end
    end
    -- the pad (height is user-stretchable via the grabber below; persisted). The ghost overlay shows
    -- what the drawn cycle becomes after the per-cycle modifiers (Swing/Steps/Smooth/Phase).
    local padW = reaper.ImGui_GetContentRegionAvail and select(1, reaper.ImGui_GetContentRegionAvail(ctx)) or 360
    local padChanged = drawpad.draw(ctx, c.store[c.idx].points,
      { width = padW, height = c.padH or 200, id = "##cust_pad", gridX = c.gridX, gridY = c.gridY, snap = c.snap,
        overlay = customOverlayPoints(g) })
    -- resize grabber: a thin strip under the pad; drag it to change the pad height
    reaper.ImGui_InvisibleButton(ctx, "##cust_pad_resize", padW, 7)
    if reaper.ImGui_IsItemHovered(ctx) or reaper.ImGui_IsItemActive(ctx) then
      if reaper.ImGui_SetMouseCursor and reaper.ImGui_MouseCursor_ResizeNS then
        reaper.ImGui_SetMouseCursor(ctx, reaper.ImGui_MouseCursor_ResizeNS())
      end
    end
    if reaper.ImGui_GetItemRectMin and reaper.ImGui_DrawList_AddLine then   -- draw a centered grab hint
      local gx0, gy0 = reaper.ImGui_GetItemRectMin(ctx)
      local gx1, gy1 = reaper.ImGui_GetItemRectMax(ctx)
      local gdl = reaper.ImGui_GetWindowDrawList(ctx)
      local cx, cyy = (gx0 + gx1) / 2, (gy0 + gy1) / 2
      reaper.ImGui_DrawList_AddLine(gdl, cx - 14, cyy, cx + 14, cyy, 0x6A737BFF, 2)
    end
    if reaper.ImGui_IsItemActive(ctx) then
      local _, my = reaper.ImGui_GetMousePos(ctx)
      if not padResize.active then padResize.active = true; padResize.startY = my; padResize.startH = c.padH or 200 end
      c.padH = math.max(90, math.min(600, padResize.startH + (my - padResize.startY)))
    elseif padResize.active then
      padResize.active = false; saveCustom(c)   -- persist once the drag ends
    end
    if padChanged then c._dirty = true; acc(true) end                    -- live re-apply each drag frame
    if c._dirty and not reaper.ImGui_IsMouseDown(ctx, 0) then            -- persist once the gesture ends
      c.store[c.idx].points = customshape.clampPoints(c.store[c.idx].points)
      saveCustom(c); c._dirty = false
    end
  end

  -- == Scope == (CC + Automation Item: write across the Time selection OR the Entire item.
  -- Envelopes are TIME-SELECTION ONLY — a track envelope has no item — so the selector is hidden
  -- for them and the span is always the time selection.)
  if not (detected and detected.target == "envelope") then
    local changed, idx = reaper.ImGui_Combo(ctx, "Scope##gen_scope", g.scope, common.SCOPE_ITEMS, #common.SCOPE_ITEMS)
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
    acc(common.tickReset(ctx, g, "lengthIdx", 0, #NOTE_VALUES - 1, DEFAULTS.lengthIdx))
    local cM, iM = reaper.ImGui_Combo(ctx, "Feel##gen_feel", g.feelIdx, FEEL_ITEMS, #FEEL_ITEMS)
    if cM and iM ~= g.feelIdx then g.feelIdx = iM; acc(true) end
    local cF, iF = reaper.ImGui_SliderInt(ctx, "Frequency##gen_freq", g.freqIdx, 0, #FREQ_VALUES - 1, FREQ_LABELS[g.freqIdx + 1] or "")
    if cF and iF ~= g.freqIdx then g.freqIdx = math.max(0, math.min(#FREQ_VALUES - 1, iF)); acc(true) end
    acc(common.tickReset(ctx, g, "freqIdx", 0, #FREQ_VALUES - 1, DEFAULTS.freqIdx))
  elseif g.rateMode == RATE_FREE then
    local changed
    changed, g.cycles = reaper.ImGui_SliderInt(ctx, "Cycles##gen_cycles", g.cycles, 1, 64, "%d")
    acc(changed)
    acc(common.tickReset(ctx, g, "cycles", 1, 64, DEFAULTS.cycles))
  else -- RATE_HZ
    local changed
    changed, g.hz = reaper.ImGui_SliderDouble(ctx, "Hz##gen_hz", g.hz, 0.01, 50.0, "%.2f")
    acc(changed)
    acc(common.tickReset(ctx, g, "hz", 0.01, 50.0, DEFAULTS.hz))
  end

  reaper.ImGui_Separator(ctx)

  -- == Level ==
  reaper.ImGui_Text(ctx, "Level")
  do
    local changed
    -- Baseline -100..100 (0 = center). Double-click the fader to snap to the notch (default).
    changed, g.baseline = reaper.ImGui_SliderInt(ctx, "Baseline##gen_base", g.baseline, -100, 100, "%d")
    acc(changed)
    acc(common.tickReset(ctx, g, "baseline", -100, 100, 0))
    -- Amplitude: linear -200..200 (% of half range; negative inverts the wave, >100 clips). Plain
    -- SliderInt so Ctrl+click type-entry works. Notch + double-click snap to the per-target default
    -- (envelope/AI 100, CC 50).
    changed, g.amplitude = reaper.ImGui_SliderInt(ctx, "Amplitude##gen_amp", g.amplitude, -200, 200, "%d")
    if changed then g.ampDirty = true end   -- user moved it: stop following the per-target default
    acc(changed)
    -- Double-click reset to the per-target default also resumes following it.
    if common.tickReset(ctx, g, "amplitude", -200, 200, defaultAmp(detected)) then g.ampDirty = false; acc(true) end
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
      acc(changed); acc(common.tickReset(ctx, g, "phase", 0, 100, 0))
    end
    -- Amp skew / Tilt apply to every shape (the dedicated emitters use them too). Freq skew is gated
    -- below with the other periodic-only modulators.
    changed, g.ampSkew = reaper.ImGui_SliderInt(ctx, "Amp skew##gen_ampskew", g.ampSkew, -100, 100, "%d")
    acc(changed); acc(common.tickReset(ctx, g, "ampSkew", -100, 100, 0))
    -- Pulse width only for Square.
    if currentShapeId(g) == "square" then
      changed, g.pulseWidth = reaper.ImGui_SliderDouble(ctx, "Pulse width##gen_pw", g.pulseWidth, 0.01, 0.99, "%.2f")
      acc(changed); acc(common.tickReset(ctx, g, "pulseWidth", 0.01, 0.99, 0.5))
    end
    -- Edge only for Trapezoid (0 = square, 100 = triangle).
    if currentShapeId(g) == "trapezoid" then
      changed, g.edge = reaper.ImGui_SliderInt(ctx, "Edge##gen_edge", g.edge, 0, 100, "%d")
      acc(changed); acc(common.tickReset(ctx, g, "edge", 0, 100, 50))
    end
    -- Attack for Triangle (peak position, % of cycle).
    if currentShapeId(g) == "triangle" then
      changed, g.attack = reaper.ImGui_SliderInt(ctx, "Attack##gen_attack", g.attack, 1, 99, "%d")
      acc(changed); acc(common.tickReset(ctx, g, "attack", 1, 99, 50))
    end
    -- Curve for Saw Up/Down + Triangle (ease steepness). Bipolar: 0 = linear, + one way, - the other.
    if currentShapeId(g) == "saw" or currentShapeId(g) == "sawdown" or currentShapeId(g) == "triangle" then
      changed, g.curve = reaper.ImGui_SliderInt(ctx, "Curve##gen_curve", g.curve, -100, 100, "%d")
      acc(changed); acc(common.tickReset(ctx, g, "curve", -100, 100, 0))
    end
    if not special then
      changed, g.freqSkew = reaper.ImGui_SliderInt(ctx, "Freq skew##gen_freqskew", g.freqSkew, -100, 100, "%d")
      acc(changed); acc(common.tickReset(ctx, g, "freqSkew", -100, 100, 0))
    end
    -- Two independent tilt sliders: Tilt L is anchored at the LEFT edge (raises/lowers the right end;
    -- REAPER's native tilt); Tilt R is anchored at the RIGHT edge (raises/lowers the left end).
    changed, g.tilt = reaper.ImGui_SliderInt(ctx, "Tilt L##gen_tilt", g.tilt, -100, 100, "%d")
    acc(changed); acc(common.tickReset(ctx, g, "tilt", -100, 100, 0))
    changed, g.tiltR = reaper.ImGui_SliderInt(ctx, "Tilt R##gen_tiltR", g.tiltR, -100, 100, "%d")
    acc(changed); acc(common.tickReset(ctx, g, "tiltR", -100, 100, 0))
    -- Swing for periodic shapes EXCEPT triangle, whose Attack already controls peak position (Swing
    -- there would just duplicate it). Custom honors Swing via the generic SSS path.
    if not special and sid ~= "triangle" then
      changed, g.swing = reaper.ImGui_SliderDouble(ctx, "Swing##gen_swing", g.swing, -1.0, 1.0, "%.2f")
      acc(changed); acc(common.tickReset(ctx, g, "swing", -1.0, 1.0, 0.0))
    end
    -- Steps quantizes the wave into N flat levels (a staircase). Meaningless on Square (already 2
    -- levels) and on the special generators. Custom is quantized via the generic SSS path.
    if not special and sid ~= "square" then
      changed, g.steps = reaper.ImGui_SliderInt(ctx, "Steps##gen_steps", g.steps, 0, 32, g.steps < 2 and "off" or "%d")
      acc(changed); acc(common.tickReset(ctx, g, "steps", 0, 32, 0))
    end
    -- Smooth rounds the shape toward a sine. Meaningless on Sine (already a sine) and the specials.
    -- Custom is smoothed (blended toward sine) via the generic SSS path.
    if not special and sid ~= "sine" then
      changed, g.smooth = reaper.ImGui_SliderInt(ctx, "Smooth##gen_smooth", g.smooth, 0, 100, "%d")
      acc(changed); acc(common.tickReset(ctx, g, "smooth", 0, 100, 0))
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
  elseif g.scope == common.SCOPE_TIMESEL and not detected.hasTimeSel then
    reaper.ImGui_TextColored(ctx, COLOR_HINT, "Make a time selection (or switch Scope to Entire item).")
  elseif currentShapeId(g) == "none" then
    -- v2.1 U1: the default None shape is a no-op; prompt the user to choose a shape.
    reaper.ImGui_TextColored(ctx, COLOR_HINT, "Pick a shape to generate")
  end

  -- Clip hint: convert the native % sliders to value units (CC lane MID=63.5, HALF=63.5) and check
  -- whether the waveform plus the two tilts exceeds 0..127. center +/- baseHalf is the un-tilted swing;
  -- Tilt L is full at the right edge, Tilt R full at the left, so the worst-case offset is the most
  -- extreme of {0, tiltL, tiltR}.
  if detected and detected.target == "cc" then
    local MID, HALF, RANGE = 63.5, 63.5, 127
    local center     = MID + (g.baseline / 100) * HALF
    local baseHalf   = (g.amplitude / 100) * HALF
    local tiltL = (g.tilt  / 100) * RANGE   -- left-anchored: full at the right edge
    local tiltR = (g.tiltR / 100) * RANGE   -- right-anchored: full at the left edge
    local lo = center - baseHalf + math.min(0, tiltL, tiltR)
    local hi = center + baseHalf + math.max(0, tiltL, tiltR)
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
  if (g.scope == common.SCOPE_TIMESEL or tk == "envelope") and not detected.hasTimeSel then
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

-- Test seams (underscore = not part of the panel's public API; same convention as the former _bounds).
-- These let the headless tests exercise pure panel logic without ImGui: the NATIVE-%-slider -> VALUE-unit
-- param assembly, and the Generate-preset capture/recall (incl. embedding/materializing a Custom drawing).
M._buildParams     = buildParams        -- (g, spanT0, vmin, vmax) -> params, ccShape
M._captureParams   = captureParams      -- (g) -> { DEFAULTS key -> value }
M._applyParams     = applyParams        -- (g, params)
M._genPresetPoints = genPresetPoints    -- (g) -> encoded custom-drawing string | nil
M._recallGenPreset = recallGenPreset    -- (g, preset) — applies params + materializes embedded drawing
M._customOverlayPoints = customOverlayPoints  -- (g) -> { {x,y}, ... } pad-space ghost | nil

return M
