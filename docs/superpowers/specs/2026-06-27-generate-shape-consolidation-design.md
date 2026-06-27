# Generate Shape Consolidation — Saw Curve + Triangle Attack/Curve; retire Pump & AD

**Status:** Design approved in discussion (saws + Curve, retire Pump; triangle + Attack + Curve,
retire AD). This doc captures it for review before planning.
**Build constraint:** LOCAL ONLY — no push. `tests/test_native_match.lua` (35) MUST stay green: the
DEFAULT saw/triangle (Curve 0, Attack 50) must remain byte-identical to today's native emitters.

## Goal

Collapse redundant Generate shapes by adding the two missing degrees of freedom:
- **Saw Up / Saw Down** gain a bipolar **Curve** knob (bent ramp) — which makes **Pump** redundant
  (Pump == a curved Saw Up). Retire Pump.
- **Triangle** gains **Attack** (peak position) + **Curve** (bent segments) — which makes **AD**
  redundant (AD == a triangle with a movable, curved peak). Retire AD.

Net shape list afterward: None, Sine, Triangle, Saw Up, Saw Down, Square, Parametric, Trapezoid,
Rectified sine, Sine², Random, Drift. (Pump and AD removed.)

## Why this is safe to consolidate

- **Pump = curved Saw Up.** Same topology (instant transition + ramp to a peak at the cycle end);
  Pump's only extra was the bezier ramp, which Saw+Curve now provides. The *new* capability is curved
  Saw **Down**.
- **AD = Triangle + Attack + Curve.** AD is "a triangle whose peak you can move, with bent segments."
  Triangle with those two knobs reproduces it exactly, and (because Triangle is a normal periodic
  shape) also composes with Phase/Swing/Freq-skew/Steps/Smooth — a superset of AD.

## Design

### 1. Saw Curve (`saw`, `sawdown`)

- New param **`curve`** (UI SliderInt **-100..100**, default **0**; engine `curve/100` in [-1,1]).
  Maps to bezier tension `curve/100 * 0.9` (same mapping Pump/AD use today).
- In `generateSaw`, a point's CC shape governs its OUTGOING segment. The ramp runs from each
  ramp-START point (rel 0, and each `relB+eps` reset-trough) up/down to the next ramp-END (peak).
  So the **ramp-start points** carry the ramp shape; the **ramp-end (peak) points** keep linear so
  the reset stays an instant drop:
  - `curve == 0`: every point shape = 1 (linear) → **byte-identical to today** (native match holds).
  - `curve != 0`: ramp-start points get shape = 5 (bezier) + `tension`; peak points stay shape = 1.
- Works for both `saw` and `sawdown` (the shared emitter; `desc` only flips lo/hi).
- Composes with existing Phase/Swing/Freq-skew/Amp-skew/Tilt/Fade (already in `generateSaw`).

### 2. Triangle Attack + Curve (`triangle`)

- New params **`attack`** (UI SliderInt **1..99** %, default **50**) and **`curve`** (bipolar, default
  **0**), mirroring AD.
- Implement by GENERALIZING `emitAnchored` for the triangle (it already does
  Phase/Swing/Freq-skew/Amp-skew/Tilt/Fade — reusing it gives the full modifier set the user wanted):
  - Triangle anchors become **{0 (trough), attack/100 (peak)}** instead of {0, 0.5}.
  - **Value override for triangle:** trough = -1, peak = +1, and an explicit triangle value function
    `triVal(x, a)` (rise -1→+1 over [0,a], fall +1→-1 over [a,1]) for the span-edge anchors — the
    `-cos` model only yields the right peak value at attack=50, so triangle must not use `-cos` for a
    moved peak. Sine/Parametric/Sine² keep `-cos` unchanged.
  - **Curve:** `curve == 0` → linear (shape 1, today's triangle). `curve != 0` → bezier (shape 5) +
    `tension` on the rise and fall segments.
- **Native match:** at **attack = 50, curve = 0**, anchors are {0, 0.5}, `triVal` gives {-1, +1}
  (identical to `-cos` there), shape = linear → **byte-identical to today's triangle** for the tested
  configs (integer cycles, phase 0). The override and bezier paths only diverge when the user moves
  Attack or Curve.
- **Accepted minor change:** for the *plain* triangle at FRACTIONAL cycle counts or non-zero Phase,
  the span-edge value moves from the old `-cos`-based value to the true linear-triangle value
  (`triVal`). This is *more* correct (a triangle should be linear, not cosine, between its corners)
  and is invisible at the native-match configs. The reviewer should treat this as intended, not a
  regression.

### 3. Retire Pump & AD

- Remove `pump` and `ad` from the Shape dropdown (`SHAPES` in `ui/generate.lua`).
- Remove `generatePump`, `generateAD`, their dispatch branches, and their `SHAPE_OUTPUT` entries.
  (The bezier-tension approach they used carries over to the Saw/Triangle Curve.)
- `core/shapes.lua`: no base.pump/ad exist (they were emitter-only), so nothing to remove there;
  leave `randomAt` etc. untouched.

### 4. Param visibility (`ui/generate.lua`)

- **Curve**: now shown for `saw`, `sawdown`, `triangle` (was pump/ad).
- **Attack**: now shown for `triangle` (was ad).
- Remove pump/ad from the `special` set. Recompute `special` = `random`/`drift` only (Phase/Swing/
  Freq-skew/Steps/Smooth keep hiding for those, as today).
- Curve/Attack are normal modifiers on saw/triangle, so Phase/Swing/etc. stay visible and all compose.
- Pulse width (square) and Edge (trapezoid) unchanged.

### 5. Defaults / state

- Add `curve = 0` and `attack = 50` to the Generate state defaults if not already present (they exist
  for the old pump/ad; keep them, now reused by saw/triangle). Reset restores curve→0, attack→50.

## Components / files

- `Contour/core/lfo.lua` — `generateSaw` (+curve on ramp-start points); `emitAnchored` (triangle
  attack peak + `triVal` override + bezier curve); remove `generatePump`/`generateAD` + their dispatch.
- `Contour/ui/generate.lua` — `SHAPES` (drop pump/ad); `SHAPE_OUTPUT` (drop pump/ad); `special` set;
  Curve/Attack visibility; `buildParams` (curve/attack already plumbed for pump/ad — repoint to
  saw/triangle).
- `tests/test_lfo.lua` — remove pump/AD tests; add saw-curve (bezier on ramp, linear reset, native at
  curve 0) and triangle attack+curve (moved peak, bezier, native at attack 50/curve 0) tests.
- `tests/test_lfo_shapes_regression.lua` — drop the `pump`/`ad` CASES; keep saw/triangle guards.
- `tests/test_native_match.lua` — UNCHANGED and green (the gate).

## Testing strategy (headless)

- **Native match preserved**: full `test_native_match.lua` green (default saw/triangle byte-identical).
- **Saw curve**: curve 0 → all shape 1; curve != 0 → ramp-start points shape 5 with sign(tension) ==
  sign(curve), peak points still shape 1 (instant reset); count unchanged vs curve 0 (no densify).
- **Triangle attack**: peak time shifts with attack (point at rel ≈ attack/100 holds the +1 peak);
  attack 50 + curve 0 == today's triangle points/shapes.
- **Triangle curve**: curve != 0 → rise/fall segments shape 5 + tension; curve 0 → linear.
- **Pump/AD gone**: `SHAPES`/dispatch no longer accept them (or are removed); suite green after the
  pump/ad tests are removed.

## Out of scope

- No change to Square/Parametric/Sine/Sine²/Trapezoid/Rectified-sine/Random/Drift behavior.
- No migration of existing saved panel state from "pump"/"ad" (local-only tool; acceptable). If a
  stale shapeIdx points past the shortened list, the dropdown clamps to None.
- Reduce, Transform unchanged.
