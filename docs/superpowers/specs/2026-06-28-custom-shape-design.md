# Custom Shape — Design (Phase 1: freehand draw pad + presets)

**Status:** Direction approved in discussion. This spec covers **Phase 1**. Phases 2–3 are noted at the
end; the Phase-1 data model is built to support them with no rework.
**Build constraint:** LOCAL ONLY (no push). Native-CC-LFO match (`tests/test_native_match.lua`, 35)
must stay green — Custom is a NEW shape and must not touch the existing shapes' code paths.

## Goal

A **Custom** LFO shape the user draws in an in-panel pad: place points, drag them, and bow the segments
between them (bezier). The drawn curve is ONE cycle that Generate repeats at the Rate, just like the
built-in shapes. Multiple named custom shapes are saved as **presets** and persist across sessions.

## Phasing

- **Phase 1 (this spec):** freehand draw pad (add/move/delete points, bendable segments) + preset
  library + the `generateCustom` engine. Controls: Rate, Amplitude, Baseline, Phase, Amp skew, Tilt,
  Fade, Freq skew. (No Swing/Steps/Smooth.)
- **Phase 2 (future):** add Swing / Steps / Smooth to Custom (needs a value-sampling path so the
  generic sampler can quantize/round/swing a custom curve).
- **Phase 3 (future):** stamp palette — pick a primitive (sine/triangle/saw/square/…) and drop its
  points into a region of the cycle. Freehand stays; stamping just inserts points into the same shape.

## Data model

A **point**: `{ x, y, shape, tension }`
- `x` in [0,1] — intra-cycle position; points kept x-ascending; first point x=0, last point x=1.
- `y` in [-1,1] — normalized waveform value.
- `shape` — CC interpolation for the segment LEAVING this point (engine ints: 1=linear, 2=slow s/e,
  3=fast start, 4=fast end, 5=bezier). **Phase 1 freehand uses only 1 (straight) and 5 (bent).**
  Phase 3's stamp palette will populate 2/3/4 too — the field exists from day one.
- `tension` in [-1,1] — bezier tension for `shape == 5`; 0 otherwise.

A **preset**: `{ name = <string>, points = { <point>, ... } }`. A **store** is an ordered list of
presets. The cycle is the curve over x∈[0,1]; the value at x=1 is the cycle end. When repeated, a
boundary where the next cycle's x=0 value differs from this cycle's x=1 value is an instant jump
(e.g. a saw) — handled by the writer's existing tick de-collision (`assignTicks`).

## Components / files

- **`Contour/core/customshape.lua`** (NEW, pure, headless): point/preset helpers + `encode(store)` /
  `decode(string)` serialization (round-trippable). No REAPER.
- **`Contour/core/lfo.lua`**: add `generateCustom` emitter + a `custom` dispatch branch.
- **`Contour/ui/drawpad.lua`** (NEW, ReaImGui-bound): the draw-pad widget — render + mouse editing.
- **`Contour/ui/generate.lua`**: `SHAPES` gains `custom`; `buildParams` passes the active preset's
  points; preset controls (dropdown + Save/New/Rename/Delete) + ExtState load/save; control
  visibility for Custom; the draw pad is shown when Custom is selected.
- **`tests/test_customshape.lua`** (NEW): serialization round-trip + `generateCustom` behavior.

## Engine — `generateCustom`

`generateCustom(t0, t1, spanLen, totalCycles, p, amp, baseV, ampSkew, freqSkew, tiltOffset)` — a SPARSE
emitter modeled on `generateTrapezoid`/`emitAnchored`:
- Per cycle `c` in 0..ceil(N): place each preset point at shape-phase `c + x` → `prog = (c + x +
  phase)/N` → `rel = freqWarpInverse(prog, freqSkew)` (kept when in the open (0,1)); `value = baseV +
  ampHalf(amp, ampSkew, rel)*y*fadeDepth(rel) + tiltOffset*rel`; carry `shape` and `tension`.
- **Cycle boundary:** the preset's x=1 (cycle end) and the next cycle's x=0 (cycle start) land on the
  same boundary tick. If their values differ it's an instant JUMP (e.g. a saw); if equal it's seamless.
  Coincident boundary points are separated onto distinct ticks by the writer — CC via the existing
  `assignTicks` de-collision; the envelope/AI path nudges the second by a tiny epsilon (like the saw's
  reset). The plan works out the exact emit loop + dedup so a seamless loop doesn't leave a redundant
  pair while a jump is preserved.
- Span-edge anchors at rel 0 and rel 1 use the custom curve's value at the wrapped phase (`-phase`,
  `N-phase`), so coverage runs t0..t1.
- PHASE shifts the cycle start; FREQ SKEW warps timing; AMP SKEW / TILT / FADE apply — same value model
  and `shape-phase = N*rel - phase` convention as the other emitters. (Swing is Phase 2.)
- Empty/degenerate preset (0–1 points) → falls back to a flat line at the points' value (or baseline),
  never errors.

Dispatch: `if p.shape == "custom" and (p.smooth or 0) == 0 and not p.quantizeSteps then return
generateCustom(...) end` (the smooth/quantize guard is inert in Phase 1 since those are hidden; it
leaves the door open for Phase 2 to route Custom to the generic sampler).

## Draw pad — `ui/drawpad.lua`

Rendered in the Generate panel when Shape = Custom. A fixed-size canvas (e.g. ~full panel width ×
~140 px) via ImGui DrawList, with an `InvisibleButton` over it to capture the mouse.
- **Axes:** x∈[0,1] left→right; y∈[-1,1] with the center line at the middle (top=+1, bottom=-1).
- **Add point:** click empty space (not near an existing point/segment) → insert a point at the mouse
  (x kept in order). **Move point:** drag a point (x clamped strictly between its neighbors; y clamped
  [-1,1]). **Endpoints** (x=0, x=1) move in y only (x fixed). **Delete point:** right-click or
  double-click a non-endpoint point.
- **Bend segment:** drag the middle of a segment (mouse down on the line, away from points) → vertical
  drag sets that segment's bezier `tension` (and `shape` = 5; tension back to ~0 → `shape` = 1).
- **Render:** grid + center line; the curve (straight or bezier per segment) via DrawList; points as
  draggable handles; the bezier preview should visually match REAPER's bezier (calibrate against the
  written output, like the Reduce bezier note).
- Edits mutate the active preset's points and mark the store dirty (saved to ExtState).
- Returns whether anything changed (so Generate's Live can re-apply).

## Presets — storage & UI

- Stored in REAPER **ExtState** (persist=true), section `Contour`, key `customPresets` = `encode(store)`.
  A separate key holds the active preset index/name. Loaded once on panel open, saved on edit.
- UI: a preset **dropdown** + **New** (blank or default shape), **Save** (overwrite current), **Rename**,
  **Delete**. A ship-with **default preset** (e.g. a simple two-hump curve) so the pad isn't empty on
  first use.
- `core.customshape.encode/decode` is the single serialization point (pure, tested); the UI only does
  ExtState get/set.

## Control visibility (Custom)

Shown: the draw pad + preset controls, then **Rate, Amplitude, Baseline, Phase, Amp skew, Tilt, Fade,
Freq skew**. Hidden: Swing, Steps, Smooth, Pulse width, Edge, Attack, Curve. (Custom is not in the
`special` set; it's a normal periodic shape minus Swing/Steps/Smooth for Phase 1.)

## Error handling

- `generateCustom` is pure/total: guards empty/short point lists, zero spans, non-finite; never throws.
- `decode` tolerates malformed/empty ExtState (returns an empty or default store), so a corrupt entry
  can't brick the panel.
- All REAPER/ExtState calls in the UI are guarded; the pad degrades to "no custom shape" rather than
  erroring.

## Testing (headless where possible)

- **`core.customshape`:** `encode`→`decode` round-trips a multi-preset store (names with delimiters
  escaped; points with shapes/tensions preserved); `decode` of malformed/empty input is safe.
- **`generateCustom`:** a known preset repeats `Rate` times (point count scales with cycles, no
  densify under amp/freq skew); endpoints cover t0..t1, strictly increasing times, finite values;
  per-point `shape`/`tension` carried through; Phase shifts the start value; a boundary jump produces
  distinct ticks via the writer (covered by the existing CC writer tests).
- **Native match unaffected:** `test_native_match.lua` stays 35/35 (Custom is a new, isolated path).
- The **draw pad and preset store** (ReaImGui/ExtState) are verified in REAPER with the user — no UI
  unit-test harness exists in this codebase (consistent with Transform/overlay).

## Out of scope (Phase 1)

- Swing / Steps / Smooth on Custom (Phase 2).
- The stamp-a-primitive palette (Phase 3) — but `point.shape` already supports the primitives' eases.
- Per-project (vs global) preset scoping; import/export of preset files. (Global ExtState only for now.)
- Changes to any existing shape, Reduce, or Transform.
