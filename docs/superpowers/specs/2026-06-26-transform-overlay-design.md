# Contour — Transform (mouse-overlay) design

Date: 2026-06-26
Status: approved for planning
Branch: `native-cc-lfo-match` (Contour toolkit)

## Overview

Transform is Contour's third and final operation (after Generate and Reduce). It is a **mouse-overlay
tool**, in the spirit of juliansader's "js_Mouse editing - Multi Tool": when armed, interactive
**zones** are drawn over the user's selected automation/CC points in the editor, and dragging a zone
**reshapes the actual points in real time** (stretch, tilt, scale, compress, warp, …). It is launched
from the Contour panel (or a hotkey) and commits as a single undo point.

Unlike Generate/Reduce (which live inside the ReaImGui window), Transform's manipulation happens
**directly over the events in the arrange/editor**. Contour's window remains open beside it as the
control surface (curve/shape/symmetrical) and launcher.

### Why this, and why now

The native Multi-Tool is excellent on MIDI CC but has two problems the user wants solved:
1. **It lags/freezes on envelopes and automation items.** Root cause (confirmed by research): per-frame
   rewriting that re-inserts/re-sorts every point (~O(n²)).
2. **Dated GUI.**

Decision (with the user): build **our own** overlay tool, **lean and phased** — prove the hard engine
(zones + mouse over the events + fast env/AI writes) on the smallest op set first, then grow. We do NOT
fork juliansader's code and do NOT embed Transform as an in-window graph (an in-window-graph concept was
prototyped and set aside; the user wants direct manipulation over the real events).

## Dependencies

- **ReaImGui** — already required; draws the overlay and Contour's Transform controls.
- **SWS** — already used (`BR_EnvGetProperties`); used here for mouse hit-testing (`BR_GetMouseCursorContext*`).
- **js_ReaScriptAPI** — NEW (already installed by the user). Needed to (a) find/position the overlay
  window over the arrange and (b) read the drag without stealing focus. One-time ReaPack install; the
  entry script must detect it and show a friendly message if missing (mirrors the existing ReaImGui guard).

## Architecture

Pure core stays Reaper-free and headless-tested; Reaper-bound code is isolated.

| Module | Role | Reaper-bound? |
|---|---|---|
| `core/transform.lua` | Pure transform math: stretch / tilt / scale / compress / warp / reverse / flip + the shared curve function `f(x, steepness, shape)`. Operates on `{ {t, v}, … }` normalized point lists. | No (headless-tested) |
| `core/arrangecoords.lua` | Pure mapping helpers: given a view window (time range + pixel extents) and a lane rect (+ value range + scaling), convert time↔x and value↔y both ways. The Reaper calls that *fetch* those inputs live in the overlay module; the math is pure and tested. | No (pure math; thin Reaper fetchers live in overlay) |
| `ui/overlay.lua` | The overlay engine: transparent ReaImGui window positioned over the arrange via js_ReaScriptAPI; draws the bounding box + zone handles; reads the drag (js mouse/message peek); maps pixels↔data via `arrangecoords`; calls `transform`; writes via the target's fast path. Owns the defer loop while armed. | Yes |
| `core/target.lua` (extend) | Add a **fast in-place write** for envelopes/AI: snapshot points at grab, then per-frame `SetEnvelopePointEx(…, noSort)` + one `Envelope_SortPointsEx`, wrapped in `PreventUIRefresh`. Existing `:read` provides the points. | Yes |
| `contour_transform.lua` (new entry) | Standalone action that runs the overlay (so it can be hotkey-bound and launched via `Main_OnCommand`). Reuses `core/context.lua` for target detection. | Yes |
| `ui/shell.lua` / Transform panel | The Transform op in the Contour window: **Scope** toggle (Selected points / Time selection) + **Launch** only. All shaping controls live in the overlay's own HUD, not here. | Yes |

## Launch & scope model

Launch is **explicit** (button or hotkey), never automatic. On launch:

1. **Target** = Contour's detected target (`core/context.lua`): selected envelope, selected automation
   item, or clicked MIDI CC lane.
2. **Region** (precedence, matching Reduce's scope model):
   - **Selected points** if any exist → transform only those (unselected points within the span stay put).
   - else **Time selection** → transform all points inside it on the target lane.
   - else → do not arm; status: "Select points or make a time selection."
3. Compute the region's **bounding box** (time min/max × value min/max of the in-scope points) and map it
   to screen pixels. The overlay zones are laid out on that box.
4. Drag a zone → transform → live write. **Esc / click-away / op-change** ends the gesture and commits a
   single undo point.

The box is computed from the selection at launch (re-launch with a new selection for a new box). Chained
multi-step editing within one arming session is a later nicety, not slice 1.

## Coordinate mapping (per target)

- **Time → X (arrange):** `GetSet_ArrangeView2(0, false, 0, arrangeClientW, &t0, &t1)` gives the visible
  time range across the arrange client width (width from `JS_Window_GetClientRect` of "trackview");
  linear-interpolate time→x. Reconcile arrange-client x with ImGui screen coords via the window rect.
- **Value ↔ Y (track envelope lane):** lane rect from `GetEnvelopeInfo_Value(env, "I_TCPY_USED"/"I_TCPH_USED")`
  + parent track `I_TCPSCREENY`. Map [valueMin, valueMax] (display domain) onto [bottomPx, topPx].
  Envelopes can be non-linear: convert with `GetEnvelopeScalingMode` + `ScaleFromEnvelopeMode` (read) /
  `ScaleToEnvelopeMode` (write). Value range from the known built-in ranges (volume/pan/width/mute/pitch,
  already in `ENV:valueRange`) or SWS `BR_EnvGetProperties` fallback.
- **Automation item:** same lane rect as its parent envelope; time bounds from `GetSetAutomationItemInfo`
  `D_POSITION`/`D_LENGTH`. Points via the `*Ex` functions (slice 3).
- **MIDI CC (slice 4):** MIDI editor "midiview" rect (js) + chunk-parsed `CFGEDITVIEW` (leftmost tick,
  horiz zoom, lane top/bottom px). Most fragile — last.

Hit-testing what's under the cursor: `BR_GetMouseCursorContext` then `_EnvelopeEx` (envelope + AI index +
point index) and `_Position` (project time at mouse).

## The overlay engine

- A ReaImGui window with `WindowFlags_NoDecoration | NoMove | NoBackground | NoInputs`, positioned each
  frame over the arrange via `JS_Window_FindChildByID`("trackview") + `JS_Window_GetClientRect` +
  `SetNextWindowPos/Size`. `NoInputs` makes it fully click-through so the arrange stays interactive and
  focus is never stolen; precedent: amagalma's "flickerless ReaImGui arrange overlay."
- Because the window is click-through, the **drag is read via js_ReaScriptAPI** (`JS_Mouse_GetState`,
  `JS_WindowMessage_Peek` for button-down / wheel), not ImGui input. The defer loop:
  1. read mouse pos + buttons + wheel;
  2. if a zone is grabbed, compute pixel delta → time/value delta → `core/transform` → fast write;
  3. redraw zones + a live overlay of the transformed shape;
  4. mousewheel adjusts the curve steepness live (native parity); middle-click toggles Power/Sine;
     right-click toggles symmetrical (these also reflect in the Contour panel).
- ~32 Hz defer ceiling → ~30 ms cursor trail. Accepted (same as native). Skip idle frames.

## Operations & math (full set; slice phasing below)

All operate on the in-scope points captured at grab (`p0[]`), writing transformed points each frame.
Bounding box from `p0`: `tmin,tmax,vmin,vmax`. `relT = (t-tmin)/(tmax-tmin)`.

Shared curve `f(x, s, shape)`, `x,f ∈ [0,1]`, monotonic, `f(0)=0, f(1)=1`. The curve knob is `-100..100`
(0 = linear, centre detent), mapped to a steepness `w = 2^(knob/100 · K)` so the centre gives `w=1`
(straight line) and the ends give a strong-but-bounded bend (`K ≈ 2.2`, tuned in REAPER):
- `shape=power`: `f = x^w`.
- `shape=sine`: `f = ((1-cos(πx))/2)^w`.

- **Stretch L/R (time):** scale `t` about the far edge (or box center if symmetrical). Drag past anchor → reverse.
- **Scale top/bottom (value):** affine remap of the value range about the opposite edge (or center if symmetrical), preserving each point's relative position.
- **Tilt L/R (value):** hold one end, lift the other: `v' = v + Δ·f(end-relative)`. Symmetrical ⇒ arch (lift center).
- **Compress top/bottom (value):** pull a boundary in along the curve; near-boundary points move most (Scale's curved sibling).
- **Warp (time or value):** axis chosen by dominant first move; bend positions/values toward the cursor along the curve.
- **Reverse** (one-shot): mirror positions in time about the box.
- **Flip values** (one-shot): absolute (about the lane center) or relative (about the selection's range).

## Live preview, write path & undo

- **Fast write** (the lag fix): at grab, snapshot the in-scope points (already available via `target:read`).
  Each frame, write transformed values **in place** with `SetEnvelopePointEx(env, ai, idx, t, v, shape,
  tension, sel, /*noSort*/ true)`; call `Envelope_SortPointsEx` **once** at the end of the frame, and only
  if a transform can reorder points in time (stretch/warp can; pure value ops can skip the sort). Wrap the
  per-frame writes in `PreventUIRefresh(1)/(-1)` and one `UpdateArrange()`. This is the path every fast
  envelope script uses; it replaces Contour's current delete+reinsert envelope write for the live case.
- **Undo:** one `Undo_BeginBlock2`/`Undo_EndBlock2` spanning the whole arming session (flag -1 for
  envelopes/AI, 4 for CC), so the entire transform is a single undo entry. Guard against a dangling block
  on abnormal exit (atexit), like the existing live gestures.
- **Selection preserved:** kept points keep their selected flag (already threaded through the write paths).

## Contour panel integration

The Transform op in `ui/shell.lua` is intentionally minimal — only what's needed to *launch* the tool:
- A **Scope** toggle: **Selected points** / **Time selection** (the region the tool operates on).
- A **Launch Transform** button (a hotkey can also be bound to `contour_transform.lua`). On launch it
  writes the chosen scope to ExtState and fires the action.

All shaping controls (**Curve**, **Power/Sine**, **Symmetrical**, **Reverse**, **Flip**) and the live
**readout** live in the **overlay's own compact HUD**, which rides alongside the box/handles. Because the
overlay is a single script instance (its own Lua state), these params need no cross-process syncing; the
only thing handed from Contour to the tool is the one-time scope choice (via ExtState `Contour/tr_scope`)
at launch. The HUD controls are also adjustable mid-drag via mouse wheel (Curve) / middle-click
(Power/Sine) / right-click (Symmetrical).

The HUD is drawn **inside the single full-trackview overlay window** (NOT a second ImGui window): the box and
handles are DrawList primitives and the HUD is a DrawList background panel plus widgets positioned by explicit
per-row cursor placement, at the **top-right of the selected shape** (above the box, right-aligned, clamped to
the trackview) so it stays clear of the item's automation. One window is essential: two overlapping windows
where one captures all input proved unreliable — after a handle drag focused the capture window the separate
HUD stopped registering clicks, and `NoBringToFrontOnFocus` did not fix it. With one window there is no
inter-window focus competition. The manual begin-drag/click-away and the wheel/middle/right gestures are gated
on `hudBusy = (cursor over the HUD rect) or ImGui_IsAnyItemActive`, so interacting with the HUD — including
dragging the Curve fader past the panel edge — never grabs a handle or ends the tool. Only Esc or a click on
the bare arrange commits and closes.

## Phasing (lean)

1. **Slice 1 — Track envelopes · Stretch + Tilt.** Build the full spine: launch from Contour, overlay
   window + positioning + mouse capture, coordinate mapping (time↔x, value↔y with scaling), the fast
   in-place write, single-undo gesture, Esc/click-away end. Only two operations, to prove the engine.
2. **Slice 2 — Scale · Compress · Warp · curve knob · Power/Sine · Symmetrical** (still track envelopes).
3. **Slice 3 — Automation items** (lane rect + AI time bounds + `*Ex` points; pooled-edit note).
4. **Slice 4 — MIDI CC** in the editor (chunk-parsed coords). Most fragile; last.

Reverse/Flip one-shots can land in slice 2 (cheap, pure math).

## Testing

- **`core/transform.lua`** — headless unit tests for every operation: known input point lists → expected
  transformed lists (stretch factor about anchor, tilt ramp with curve, scale remap, compress curvature,
  warp, reverse, flip absolute/relative, symmetrical variants, curve `f` monotonicity + endpoints).
- **`core/arrangecoords.lua`** — headless tests: time↔x and value↔y round-trip for linear and
  fader-scaled lanes; box→pixel layout.
- **Reaper-bound** (overlay, coords fetch, fast write) — verified in REAPER by the user per slice (the
  established loop), with a `dump_*` diagnostic if a coordinate/scaling mismatch appears.
- Target the fast write with a mock-`reaper` test (point count constant, `SetEnvelopePointEx` used with
  `noSort`, one sort, no delete/reinsert) mirroring the existing `test_target.lua` style.

## Risks / open questions

- **Coordinate fragility across REAPER UI states** (scroll, zoom, lane resize, theme): recompute the lane
  rect + arrange view every frame; verify in-REAPER. Highest risk in slice 1 — that's why it's slice 1.
- **MIDI CC chunk parsing** (`CFGEDITVIEW`) is undocumented; isolate it and keep CC last.
- **Pooled automation items**: edits propagate to siblings (documented behavior; note it, don't fight it).
- **defer ~30 ms lag**: accepted.

## Out of scope (for now)

- Chained multi-step editing within one arming session (native has it; revisit after slice 2).
- Take envelopes (deferred across all of Contour).
- Notes/velocity/pitch/sysex transforms (Contour targets envelopes/AI/CC only).
- Snap-to-chased values (a later nicety).
