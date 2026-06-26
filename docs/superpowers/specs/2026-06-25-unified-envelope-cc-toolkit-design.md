# Contour — Unified Envelope & CC Toolkit for Reaper

**Status:** Design (approved in brainstorming, pending spec review)
**Date:** 2026-06-25
**Provisional name:** "Contour" (TBD)

---

## 1. Problem

Reaper's modulation/shaping tooling is scattered across at least six separate tools, each with its own UI, its own quirks, and gaps where it simply doesn't apply:

| Tool | What it does | Limitation |
|---|---|---|
| SWS/Padre **LFO Generator** | LFO points on envelopes / take env / MIDI CC | Compiled C++, fixed dialog, can't be themed/extended |
| Native **Automation Item LFO** | Looping LFO inside automation items | Core dialog, not editable |
| Native **CC LFO** (MIDI editor) | LFO on a CC lane | Core dialog, not editable |
| **js_ Envelope LFO generator and shaper** | LFO + draw-parameter-over-time on envelopes/AIs | Old `gfx` UI; does **not** write CC |
| **js_ Mouse editing – Multi Tool** | In-place warp/stretch/tilt/etc. of notes/CC/points | Powerful but crude `gfx` UI ("shitty UI") |
| Native **Reduce points** + sockmonkey72 **Thin CCs** | Point reduction | Native ignores **MIDI CC**; CC thinning has no live slider |

The cost: four different LFO dialogs, two different point-reducers, and a transform tool with poor visual feedback — none of which share a look, behavior, or live preview, and several of which don't cover all three data types (track/take **envelopes**, **automation items**, **MIDI CC**).

## 2. Vision

**One window. One consistent, modern UI. Three operations, each working identically across envelopes, automation items, and MIDI CC, with live preview throughout.**

The toolkit is organized as:

- **Operation switcher** (top): **Generate / Reduce / Transform**
- **Shared target tabs** (below): **Envelope / Automation Item / MIDI CC** — auto-selected from what the user is pointed at, manually overridable
- **A body** that swaps to the active operation's panel

Built as a **ReaScript (Lua) + ReaImGui** application — the modern Dear ImGui binding — replacing every `gfx`-based and compiled dialog above with one themed, extensible, live-previewing tool.

## 3. Goals / Non-Goals

**Goals**
- Collapse the four LFO generators into **one Generate panel** that targets envelopes, automation items, or CC, with feature parity to all four (verified by source audit — see §7).
- Provide **Reduce** (point thinning) that works on **CC too**, with the live slider the native dialog lacks.
- Re-skin the **Multi-Tool** ("Transform") with proper visual feedback while keeping its gesture-driven editing.
- A genuinely **nice UI**: preview-first, live, consistent dark theme, icon-based shape selection.
- Clean module boundaries so the modulation math and reduction algorithm are **unit-testable outside Reaper**.

**Non-Goals (for now)**
- Replacing Reaper's modulation routing / parameter modulation system.
- A full custom **bezier/draw-your-own shape editor** (Phase 2).
- The **"shape over time"** parameter-drawing sub-editor (Phase 2).
- Audio-rate / real-time modulation (this writes envelope points / CC events, not a live modulator).

## 4. Phasing

The full toolkit is too large for one implementation pass. It decomposes into:

- **Phase 1 (this spec's implementation scope): Generate + Reduce.** The shared core, the unified window shell, and the two panel-driven tools across all three targets. This replaces five of the six tools above.
- **Phase 2 (described here, separate spec/plan later): Transform + Shaper.** The gesture-driven Multi-Tool re-skin, plus the "shape parameter over time" sub-editor for Generate.

Each phase gets its own implementation plan.

## 5. Tech Stack & Dependencies

- **Language:** Lua (ReaScript).
- **UI:** **ReaImGui** (`reaper_imgui`) — installed via ReaPack. Hard dependency; the tool checks for it on launch and shows an install hint if missing.
- **Phase 2 only:** **js_ReaScriptAPI** for low-level mouse/window interaction (the Multi-Tool's gesture handling). Not needed for Phase 1.
- **Not required:** SWS. (We replace Padre's functionality; we don't call it.)
- **Distribution:** developed as a ReaPack-compatible package layout; primary goal is personal use, but structured so a public ReaPack release is a packaging step, not a rewrite.
- **Reaper API:** standard envelope (`*EnvelopePoint*`), automation item (`CountAutomationItems`, `GetSetAutomationItemInfo`), and MIDI (`MIDI_*CC*`) functions.

## 6. Architecture

### 6.1 Module map (UI-free core + UI layer)

The core has **no ReaImGui dependency** and is pure-data, so it runs headless under a plain Lua interpreter for tests.

```
contour/
  core/
    context.lua    -- detect active surface (arrange vs MIDI editor) + current target
    target.lua     -- abstraction over the 3 target types (read/write/range/timebase)
    shapes.lua     -- pure shape math: (shape, phase, skew, pulseW, tilt, smooth, t) -> value
    lfo.lua        -- compose shapes + rate + amplitude/baseline + fades + quantize/random -> point list
    reduce.lua     -- Ramer–Douglas–Peucker thinning of a point list
    presets.lua    -- named preset save/load via ExtState
  ui/
    theme.lua      -- the dark/teal theme, ImGui style push/pop
    shell.lua      -- window, operation switcher, target tabs, defer loop
    preview.lua    -- the live curve/points widget (shared by Generate & Reduce)
    generate.lua   -- Generate panel
    reduce_ui.lua  -- Reduce panel
  contour.lua      -- entry point / app state
```

### 6.2 Key interfaces

**`Target`** — the abstraction that makes "works the same on Env / AI / CC" real. Every operation talks only to this:

```
Target:kind()                  -> "env" | "ai" | "cc"
Target:timeRange(scope)        -> t0, t1     (scope = "all" | "timesel" | "selected" | "item" | "loop")
Target:valueRange()            -> vmin, vmax (e.g. envelope min/max, CC 0..127)
Target:timeBasis()             -> "time" | "beats"
Target:readPoints(t0, t1)      -> { {time, value, shape?}... }
Target:writePoints(points, opts) -> writes/replaces in range, sets one undo point
Target:selection()             -> selected point/event indices
```

`context.lua` inspects focus and selection and returns the appropriate concrete `Target` (EnvelopeTarget / AutomationItemTarget / MidiCCTarget). The active operation panel + target tab are seeded from it; the user can override the tab.

**`shapes.lua`** (pure): `value(shape, t, params)` where `t ∈ [0,1)` within one cycle and `params = {phase, ampSkew, pulseWidth, freqSkew, tilt, smooth}` → returns `[-1, 1]`. `smooth` interpolates the hard-edged shapes toward their rounded ("bezier") variants. Random uses a seeded PRNG so results are reproducible (Seed control).

**`lfo.lua`** (pure): `generate(span, params) -> points`. Walks the target span according to the **rate model**, samples `shapes.value`, scales by `amplitude` around `baseline`, applies `freqSkew`, edge `fadeIn`/`fadeOut`, optional `quantize` to N steps, and emits points at `density` resolution.

**`reduce.lua`** (pure): `thin(points, tolerance) -> points` via RDP. `tolerance` is normalized against `valueRange` so the single slider behaves consistently across env/AI/CC.

## 7. Phase 1A — Generate

A single panel, **Preview-First** layout: a large live curve as the hero, controls beneath.

### 7.1 Shape selection
Icon buttons (no dropdown): **Sine, Square, Triangle, Saw up, Saw down, Random/S&H, None**. Hover shows the name. (Custom/bezier editor → Phase 2.) A **Smooth** slider rounds any shape (e.g. triangle→sineish), covering SWS's bezier-smoothed variants without a separate editor.

### 7.2 Rate model — three modes
- **Sync** — musical division `1/1 … 1/128` × `straight / dotted / triplet`. Period is independent of selection length.
- **Free** — *N cycles fit exactly across the selection* (`period = selection ÷ N`). The common envelope case.
- **Hz** — absolute real-time frequency.
- **Source** selector (the span the LFO is laid over): **Time selection / Loop / Item / Project** (from SWS's `TimeSegment`).

### 7.3 Controls (full set, audited against all four LFO tools)
- **Depth:** Amplitude, Baseline (center), Phase, Tilt
- **Character:** Amp skew, Pulse width, Freq skew, Swing
- **Variation:** Randomness, Seed (+ re-roll), Quantize steps (off / 3–128), Density (points-per-cycle / precision)
- **Edges:** Fade in, Fade out (taper LFO depth at the selection edges)
- **Output:** **Replace only.** (Blending onto existing data — Add/Multiply — is intentionally the Transform tool's job, per the create-vs-transform split.)
- **Presets:** save / load / delete named presets (replaces the native CC "Preset" button and the js_ saved-curves library).
- **Footer:** **Live** (on by default — writes to the real target continuously while dragging, one undo point on release), **Reset**, **Apply** (commits when Live is off).

### 7.4 Per-target specifics
- **Envelope tab:** writes points into the chosen Source span of the active track/take envelope. Supports take Volume/Pan/Mute/Pitch envelopes as targets (SWS `TakeEnvType` parity).
- **Automation Item tab:** in addition to the LFO controls, exposes the native AI properties so the panel replaces that dialog too: Position, Length, Start offset, Transition time, Play rate, Loop, Name, pooled-copy handling, and "baseline/amplitude affects pooled copies."
- **MIDI CC tab:** writes CC events in the active MIDI take's lane; honors the CC value range (0–127, or 14-bit where applicable).

## 8. Phase 1B — Reduce

Point thinning that works identically on **Envelope / Automation Item / MIDI CC** — closing the gap where Reaper's native reducer ignores CC.

- **Scope radios:** All points / In time selection / Selected (maps to the native dialog and to sockmonkey72's two scripts).
- **Algorithm:** Ramer–Douglas–Peucker (clean-room, MIT-friendly; no dependency on `ThinCCUtils`). Tolerance normalized to the target's value range so one slider behaves the same everywhere.
- **Live preview:** faint original points vs. bold reduced curve with kept-point dots; **live point count** ("1,240 → 86 · −93%") updates as the slider moves.
- **Controls:** single **Reduction** slider, **Live / Reset / Apply**.

## 9. Phase 2 (outline — separate spec later)

- **Transform (Multi-Tool re-skin):** keep the gesture-driven, zone-under-cursor editing — Tilt/Arch, Scale (top/bottom), Compress (top/bottom), Stretch (left/right), Move, Warp, plus wheel edits (Chase L/R, Reverse, Space evenly, Flip relative/absolute) and Undo/Redo — but replace the `gfx` rendering with clear ReaImGui-quality visual feedback (zone highlighting, value/curve HUD). Add/Multiply-style blending of an LFO onto existing data lives here naturally. Requires js_ReaScriptAPI.
- **Shape over time (Generate sub-editor):** draw how **Rate, Swing, Amplitude, and Center** evolve across the selection (the js_ "shaper" feature — note: all four parameters, not just amplitude/baseline).

## 10. UX / Visual Design

- **Preview-First** everywhere: the live curve leads, controls support it.
- **Theme:** a fixed, tasteful dark theme with a teal accent (mocked during brainstorming). Following the user's Reaper theme accent is a possible later option, not Phase 1.
- **Consistency:** Generate and Reduce share the `preview.lua` widget and `theme.lua`; the shell, operation switcher, and target tabs are identical across tools.
- **Density management:** the most advanced controls (Density/precision, Seed) may collapse under an "Advanced" disclosure to keep the default view clean while honoring Preview-First.

## 11. Data Flow & Undo

1. `context` resolves the `Target`. 2. Panel reads current params (+ existing points for preview reference). 3. On any change, `lfo.generate` / `reduce.thin` produces a candidate point list. 4. `preview` draws it. 5. If **Live**, `Target:writePoints` applies immediately and coalesces into a **single undo point** per drag (begin on first edit, end on mouse-up). 6. **Apply** commits; **Reset** restores the pre-edit state. All writes go through `Undo_BeginBlock2`/`EndBlock2` with descriptive labels.

## 12. Error Handling & Edge Cases

- **No ReaImGui:** detect on launch, show install instructions, exit cleanly.
- **No valid target / no time selection** when a scope requires one: disable Apply, show an inline hint rather than failing silently.
- **Empty or single-point** reduction input: no-op, report it.
- **Value clamping:** all generated/written values clamp to `Target:valueRange()`.
- **Tempo/beat vs time bases:** Sync/Free respect the target's `timeBasis`; "Free = N cycles" is defined as equal time division of the span (well-defined across tempo changes).
- **14-bit / multi-byte CC:** handle or explicitly scope out per lane type.

## 13. Testing Strategy

- **Headless unit tests** (plain Lua) for the pure core: `shapes.lua` (shape values, smoothing, seeded randomness reproducibility), `lfo.lua` (point counts, fades, quantize, rate models), `reduce.lua` (RDP correctness, tolerance monotonicity, endpoint preservation).
- **Manual verification in Reaper** for each target type × operation, following a written checklist (the UI/integration layer can't be unit-tested).

## 14. Open Decisions / Assumptions (confirm at spec review)

1. **Name:** provisional "Contour."
2. **Distribution:** personal-use first, ReaPack-ready layout. (assumption)
3. **Theme:** fixed dark/teal for Phase 1; Reaper-accent-following deferred. (assumption)
4. **ReaImGui** as a hard dependency the user installs once via ReaPack. (assumption)
5. **Build order within Phase 1:** shared core → shell → Generate → Reduce. (proposal)

## 15. Milestones (Phase 1)

1. **Core + tests:** `context`, `target` (all three implementations), `shapes`, `lfo`, `reduce`, `presets` — with headless tests green.
2. **Shell:** window, operation switcher, target tabs, theme, defer loop, ReaImGui dependency check.
3. **Generate:** preview widget + full control set + per-target specifics + live/apply/undo.
4. **Reduce:** scope radios + RDP slider + live count, reusing the preview widget.
5. **Polish pass:** Advanced disclosure, presets UI, manual-test checklist across all targets.
