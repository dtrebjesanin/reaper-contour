# Contour — LFO Shapes Expansion (Generate) — Design

**Goal:** Add 8 new LFO shapes + 2 global shape modifiers to the Generate operation, fix the Random
"staircase" bug, and rename Saw → Saw Up — without breaking the native-CC-LFO match.

**Architecture:** Pure engine (`core/shapes.lua` waveform math, `core/lfo.lua` point composition) +
`ui/generate.lua` panel. New simple periodic shapes are base functions that flow through the existing
generic ppc sampler (so they inherit skew/swing/steps/smooth/tilt for free). New *curve* shapes (Pump,
AD, Drift, and Random) get small dedicated point-emitters in the pattern of the existing Square/Saw
emitters, so their per-point interpolation comes out clean.

**Tech stack:** Lua 5.4, ReaImGui. Headless tests via `lua.exe` (`tests/test_*.lua`).

## Global constraints

- **Native match is sacred.** The 5 native ids (`sine`, `triangle`, `saw`, `square`, `parametric`) must
  keep using their exact native emitters at default settings. The integer-exact `tests/test_native_match.lua`
  must stay green. Smooth/Steps are modifiers that only divert a native shape to the generic sampler when
  set to a non-default value (`smooth>0` or `quantizeSteps` set) — exactly today's behavior.
- **Local only.** Nothing is pushed to GitHub / ReaPack until the user explicitly says so. Commits are
  local.
- **Internal shape ids never change.** Renames are display labels only.
- **Value domain:** all waveform functions return `[-1, 1]` for phase `t in [0,1)`; the engine scales by
  amplitude/baseline in value units, as today.

---

## 1. Dropdown: rename + reorder (family grouping)

`SHAPES` in `ui/generate.lua` becomes, in this order:

| # | label | id | kind |
|---|-------|----|------|
| 0 | Sine | `sine` | native |
| 1 | Triangle | `triangle` | native |
| 2 | Saw Up | `saw` | native (label renamed from "Saw") |
| 3 | Saw Down | `sawdown` | extra (engine already has `base.sawdown`) |
| 4 | Square | `square` | native |
| 5 | Trapezoid | `trapezoid` | extra (new) |
| 6 | Parametric | `parametric` | native |
| 7 | Rectified sine | `rectsine` | extra (new) |
| 8 | Sine² | `sine2` | extra (new) |
| 9 | Pump | `pump` | extra (new) |
| 10 | AD | `ad` | extra (new) |
| 11 | Random (S&H) | `random` | extra (engine has `random`; randomAt is fixed) |
| 12 | Drift | `drift` | extra (new) |

- `id "saw"` is unchanged → native emitter + native tests untouched; only the visible label changes.
- `DEFAULTS.shapeIdx` / the default-shape resolution must still resolve to **Sine** (index 0) after the
  reorder. Verify whatever index the panel defaults to maps to `sine`.
- `currentShapeId(g)` must map every new index to the right id.

---

## 2. New waveform functions (`core/shapes.lua`) — flow through the generic sampler

These are pure `base.*` functions; `dispatch` gains the new ids. They need no dedicated emitter — the
generic ppc sampler already applies skew/swing/steps/smooth/tilt to anything routed through `shapes.value`.

- **Trapezoid** `base.trapezoid(t, edge)` — square with linear ramps of width `edge ∈ [0, 0.5]`:
  rise −1→+1 over `[0,edge]`, hold +1 over `[edge, 0.5]`, fall +1→−1 over `[0.5, 0.5+edge]`, hold −1 over
  `[0.5+edge, 1)`. `edge=0` ⇒ square; `edge=0.5` ⇒ triangle. `p.edge` carries the control (default 0.25).
- **Rectified sine** `base.rectsine(t)` — full-wave rectified humps: `2*abs(sin(2π t)) − 1` (two positive
  humps per cycle; −1 at the zero points, +1 at the hump tops). One-directional "only-ducks-one-way"
  tremolo feel.
- **Sine²** `base.sine2(t)` — peakier sine that preserves sign: let `s = -cos(2π t)`; return `sign(s)*s*s`.
  Same period as sine but sharper peaks / flatter middle.

`M.value` already dispatches by id and applies `smooth`; add the three ids to `dispatch`. `trapezoid`
reads `p.edge` like `square` reads `p.pulseWidth`.

---

## 3. Random fix + Random/Drift emitter (`core/shapes.lua` + `core/lfo.lua`)

### 3a. Fix `shapes.randomAt` (the staircase bug)

**Bug (confirmed):** `randomAt(seed,index)` seeds a Park-Miller LCG with `seed + index*2789 + 1` — linear
in `index` — so the first output is also linear in `index`, producing a monotonic staircase (≈ constant
step, wrapping) instead of noise.

**Fix:** replace with a proper integer mixing hash (splitmix64-style finalizer), which decorrelates
consecutive indices:

```lua
local function mix64(x)
  x = (x ~ (x >> 30)) * 0xbf58476d1ce4e5b9
  x = (x ~ (x >> 27)) * 0x94d049bb133111eb
  return x ~ (x >> 31)
end
function M.randomAt(seed, index)
  local h = mix64((seed or 0) * 0x9E3779B97F4A7C15 + index)
  local u = (h & 0x1FFFFFFFFFFFFF) / 0x20000000000000  -- 53-bit mantissa -> [0,1)
  return u * 2 - 1                                       -- [-1,1)
end
```

Lua 5.4 integer ops wrap mod 2^64 (two's complement), which is what the hash wants. `M.prng` stays for
any other callers but `randomAt` no longer uses it.

### 3b. Random (S&H) and Drift share one emitter

Both pick **one random value per cycle** (`randomAt(seed, cycleIndex)`); they differ only in interpolation
between cycle values:

- **Random (S&H):** hold each value flat → emit one point per cycle boundary with **step** CC shape (0).
- **Drift (smooth random):** ease between values → emit one point per cycle boundary with **slow start/end**
  CC shape (2), so the lane curves smoothly through the random targets.

Add a `generateRandom(..., smoothInterp)` emitter (mirrors `generateSquare`/`generateSaw` structure):
one point at each cycle start at `value = baseV + ampHalf(...)*randomAt(seed,cyc) + tiltOffset*rel`, plus
the span-end point; CC shape = `smoothInterp and 2 or 0`. This keeps output sparse and crisp instead of
the dense generic path. Honors amp-skew/tilt/fade; freq-skew/swing on random are out of scope (no musical
meaning for S&H) — boundaries are plain cycle starts. `seed` comes from `p.seed`; **Re-roll** changes it.

(The generic-sampler `random` branch can remain as a fallback but the dedicated emitter is the primary
path, selected in `lfo.generate` like square/saw.)

---

## 4. Pump and AD emitters (`core/lfo.lua`) — dedicated, curved

Both are per-cycle envelope shapes built from sparse points with curved CC interpolation. A shared
**Curve** control sets the easing steepness, mapped to a bezier tension / fast-ease CC shape.

- **Pump (sidechain duck):** per cycle, a point at the cycle start at value **−1** (max duck) that
  **recovers to +1** by the cycle end, then re-ducks. = an exponential Saw Up. Emit: duck point (−1) at
  each cycle start + recovered point (+1) just before the next cycle start, with the recovery segment using
  a **fast-start ease** (CC shape 3) or bezier whose tension = the **Curve** control. Depth = Amplitude
  (so on a Volume envelope with baseline high + positive amplitude, −1 sits at the duck floor). One pump
  per cycle (Rate controls pumps/bar).
- **AD (attack-decay hump):** per cycle, rise −1→+1 over the **Attack** fraction `a ∈ (0,1)` of the cycle,
  then fall +1→−1 over the remaining `1−a`. Emit: trough (−1) at cycle start, peak (+1) at `t=a`, trough
  (−1) at cycle end; both segments eased by the **Curve** control (CC bezier/fast-ease). `Attack` sets the
  peak position; `Curve` sets the ease.

Both reset cleanly between cycles (a near-instant boundary like `generateSaw`'s reset where needed). Both
honor amplitude/baseline/tilt; phase optional (can be added later — not required for v1). Implemented as
their own emitter functions selected in `lfo.generate` (same dispatch spot as square/saw/random).

---

## 5. New UI controls (`ui/generate.lua`)

### Global modifiers (always visible, in the "Shaping" group)

- **Steps** — `SliderInt`, range `0..32` where `0` = off; `1` also = off (needs ≥2 levels). When ≥2,
  `buildParams` sets `p.quantizeSteps = steps` → `lfo.quantizeBipolar` quantizes ANY shape to N levels.
- **Smooth** — `SliderInt 0..100` (%); `buildParams` sets `p.smooth = pct/100` → rounds any shape toward a
  sine. At `0` the native shapes keep their exact emitters.

### Shape-specific controls (shown only for the relevant shape, like Pulse width is for Square)

- **Random / Drift** → existing **Re-roll** button (already wired) + the existing `seed`.
- **Pump** → **Curve** `SliderInt` (e.g. `0..100`; 0 = linear, higher = more exponential).
- **AD** → **Attack** `SliderInt 1..99` (% of cycle) + **Curve** (shared with Pump).
- **Trapezoid** → **Edge** `SliderInt 0..100` (% → `edge = pct/200`, so 0 = square, 100 = triangle).
- **Pulse width** → gate to Square only (currently shown always; minor cleanup).

`buildParams` must additionally pass `p.seed`, `p.smooth`, `p.quantizeSteps`, and the shape-specific
`p.curve` / `p.attack` / `p.edge` (only the ones relevant to the selected shape; harmless if extra).
All new sliders get the existing double-click-to-default (`tickReset`) behavior.

---

## 6. Testing

- **`tests/test_shapes.lua`** — value checks for `sawdown`, `trapezoid` (edge=0 ≡ square, edge=0.5 ≡
  triangle, mid-edge ramps), `rectsine` (humps, ≥ −1, peaks at quarter points), `sine2` (peakier than
  sine, same zeros). **Random regression:** assert `randomAt` is NOT a staircase — e.g. the set of
  consecutive deltas over 32 indices has clearly varying magnitude (not all ≈ equal), and values spread
  across `[-1,1]`.
- **`tests/test_lfo.lua`** — Random S&H: values constant within a cycle, differ non-monotonically across
  cycles. Drift: same per-cycle targets as Random but with the smooth-interp CC shape. Pump: per cycle
  monotonically recovers low→high. AD: peak lands at the Attack fraction. Steps: output takes exactly N
  distinct levels. Smooth: blends toward sine.
- **`tests/test_native_match.lua`** — unchanged; must stay green (defaults route natives to exact emitters).
- Run the full suite (`lua.exe tests/test_*.lua`) after each task.

## 7. Out of scope (this round)

- Exp/log ramp shapes (covered by existing Curve/skew).
- Phase support for Pump/AD/Random/Drift (can be added later).
- Freq-skew/swing for Random/Drift (no musical meaning for S&H).
- Any push to GitHub / ReaPack.
