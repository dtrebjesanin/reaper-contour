# Reduce — Curve Fit Design

**Status:** Approved direction (Approach 1: curve-aware simplification; UI: "Curve fit" checkbox).
**Build constraint:** LOCAL ONLY — do not push to GitHub/ReaPack until the user says so. All
existing tests must stay green (especially `test_native_match.lua` and `test_reduce.lua`); the current
straight-line Reduce behavior must be unchanged when Curve fit is off.

## Goal

Let Reduce keep the *shape* of a curved automation/CC contour with far fewer points by choosing a
curved interpolation between the kept points, instead of always assuming straight lines.

## Background — how Reduce works today

- `core/reduce.lua` is a pure, headless RDP thinner. `M.rdp(points, eps)` keeps a point only when the
  straight chord between its neighbors deviates by more than `eps` (measured **vertically**, in value
  units). `M.thin(points, amount, valueRange)` maps the amount to `eps = amount * (vmax - vmin)`.
- `ui/reduce.lua` captures a non-destructive baseline of the pristine points, calls
  `reducedAt(g)` → `reduce.thin(...)`, and writes via `tgt:writeBulk(..., { rawShape = true })` /
  `tgt:write(..., { rawShape = true })`. `rawShape = true` re-inserts each kept point verbatim,
  preserving its existing `.shape`/`.tension`.
- The writer **already** applies per-point shape + bezier tension for all three targets:
  CC via `MIDI_SetCCShape(take, idx, shape, tension)`, envelope/AI via
  `InsertEnvelopePointEx(env, ai, t, v, shape, tension, ...)`. Reading (`tgt:read`) returns each
  point's `{time, value, shape, tension, sel}` in the target's **native** shape convention.
- Because RDP assumes straight chords, on a curve it must keep many points: no straight segment can
  follow the bend. That is exactly what this upgrade fixes.

## Approach — curve-aware simplification (fit-and-split)

Replace RDP's "can a straight line approximate this stretch within `eps`?" test with "can one of
REAPER's per-point interpolations approximate it within `eps`?" Where a curve fits, keep only the two
endpoints, tagging the first with the chosen shape (a point's shape governs its **outgoing** segment).

Recursive, mirroring `M.rdp`:

```
fitSegment(points, i, j, eps):
    best = nil  -- {shape, tension, maxErr}
    for each candidate (shape, tension) for the chord points[i]..points[j]:
        maxErr = max over k in (i, j) of | points[k].value - reconstruct(points[i], points[j], shape, tension, points[k].time) |
        track the (shape, tension) with the smallest maxErr
    if best.maxErr <= eps:
        keep points[i] (shape=best.shape, tension=best.tension) and points[j]; done
    else:
        split at the k with the largest error; recurse fitSegment(i..k) and fitSegment(k..j)
```

`reconstruct(p0, p1, shape, tension, t)` evaluates REAPER's interpolation at time `t`:
`x = (t - p0.time) / (p1.time - p0.time)`, `value = p0.value + (p1.value - p0.value) * ease(shape, x, tension)`.

### Candidate shapes and their easing models

`ease(shape, x, tension)` for `x` in [0,1] (CC-convention shape ints):

- **1 linear:** `e = x`.
- **2 slow start/end:** `e = (1 - cos(pi*x)) / 2`. EXACT — this is the sine arc REAPER's native sine
  LFO draws between trough and peak (proven by `test_native_match.lua`).
- **3 fast start:** `e = sin(pi*x/2)` (steep at start, flat at end).
- **4 fast end:** `e = 1 - cos(pi*x/2)` (flat at start, steep at end).
- **5 bezier:** a tension-parameterized curve `e = bez(x, tension)`, `tension` in [-1, 1]; the fit
  searches `tension` (coarse-to-fine 1-D scan, e.g. 9 samples then refine ±) for the minimum error.

The easing models live in **one small table** so they are the single point of calibration. Models 1
and 2 are known exactly. Models 3, 4, and the bezier curve are derived from REAPER's interpolation and
**validated visually in REAPER**; if a model is off, only that table entry changes — the fit framework
is unaffected. (Confidence note: 3/4 are the quarter-sine eases that compose REAPER's parametric sine,
so they are expected to match; bezier tension is the least certain and is the primary calibration item.)

Linear segments (already straight) and bezier with `tension≈0` both collapse the bulge, so the fit
naturally prefers the cheapest accurate shape.

## Shape convention

`thinCurve` emits shapes in the **target's native convention** directly (so the existing
`rawShape = true` write path stays verbatim). Curves 2–5 are identical across CC and envelope; only
**linear** and **step** differ (CC 1=linear/0=step; envelope 0=linear/1=step). `thinCurve` takes an
`opts.envConvention` flag and emits `linear = 0` (envelope) or `1` (CC) accordingly. AI uses the
envelope convention. The caller (`reducedAt`) knows the target and passes the flag.

## Tolerance

Curve fit reuses the existing Reduction slider and `eps = amountFor(pct) * (vmax - vmin)` unchanged.
The same setting simply keeps fewer points in curve mode (a curve covers more of the contour within
`eps` than a straight line). Error is measured **vertically**, identical to the RDP metric, so the
slider feel is consistent between modes.

## Components and files

- **`core/reduce.lua`** (pure, headless): add `M.thinCurve(points, eps, valueRange, opts)` plus the
  private easing table and the `fitSegment` recursion. `M.rdp`/`M.thin` are untouched.
- **`ui/reduce.lua`**:
  - State: add `curveFit = false` to `state.red`.
  - Draw: a `"Curve fit"` checkbox above the Reduction slider; toggling it counts as an edit (`acc`),
    so Live re-applies. Off = today's behavior exactly.
  - `reducedAt(g)`: when `g.curveFit` and `amount > 0`, call `reduce.thinCurve(pts, eps,
    {vmin, vmax}, { envConvention = <target is envelope/ai> })` instead of `reduce.thin`. Selected
    scope: thin only the selected points (same merge-back as today), via `thinCurve`.
  - Status line unchanged (`N -> M points`).
- **Writer:** no change — fitted points carry native-convention `.shape`/`.tension` and write through
  the existing `rawShape = true` path.

## Data flow

`baseline (pristine points, native shapes)` → `reducedAt`: if Curve fit → `reduce.thinCurve` (fits a
shape+tension per kept point) else `reduce.thin` → `tgt:writeBulk(snapshot, pts, t0, t1, { rawShape =
true })`. Non-destructive baseline, scopes (Time selection / Entire item / Selected points), Reset,
and Live are all unchanged — Curve fit only swaps the thinning function.

## Error handling

- `thinCurve` is pure and total: `n <= 2` returns the points as-is; a zero-length time span between two
  points falls back to linear; non-finite guards mirror existing code. It never throws.
- All target/baseline/undo error handling in `ui/reduce.lua` is unchanged.

## Testing (headless, `tests/test_reduce.lua`)

- Straight line → 2 points, linear shape (no spurious curve).
- A sampled smooth arc (e.g. a sine span) → few points, all tagged with curve shapes, and the
  **reconstructed** curve (re-evaluating `ease` at every original time) stays within `eps`.
- On the sampled smooth arc, curve mode keeps **fewer** points than straight mode at the same `eps`
  (linear is in the candidate set, so curve mode is never worse and is strictly better on real curves).
- `envConvention` maps linear to 0 (envelope) vs 1 (CC).
- Existing RDP tests and `test_native_match.lua` remain green (no engine changes).

## Out of scope (future)

- Per-shape "allow only these curve types" controls. (Start with the full candidate set.)
- Curvature-extrema pre-seeding of split points (the recursion already converges; revisit only if a
  pathological input is slow).
- Any change to Generate or Transform.
