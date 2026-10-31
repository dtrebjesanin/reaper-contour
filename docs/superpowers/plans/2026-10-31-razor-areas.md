# Razor Areas Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** A razor area on the lane that Contour targets becomes the range for Generate, Reduce and Transform. A drag on one envelope lane switches Contour to it. A drag over several lanes shows a chooser on the context line.

**Architecture:**
- A new pure module `core/razor.lua` parses `P_RAZOREDITS`, merges and clamps spans, diffs snapshots and settles drags.
- `core/context.lua` reads the razor state, at most every 100 ms, and adds `ranges` to the detected descriptor.
- `ui/common.spansFor` is the ONE place that turns a descriptor into a list of spans.
- The razor-versus-time-selection decision is made in `context.addRanges`. The later "Razor ⇄ Time selection" toggle belongs there. It has to reach the overlay script through ExtState.
- Generate and Reduce loop over that list inside one Undo block.
- The shell draws the range text and the chooser.

**Tech Stack:** Lua 5.4 (headless tests), REAPER ReaScript API, ReaImGui, optional js_ReaScriptAPI.

**Spec:** `docs/superpowers/specs/2026-10-31-razor-areas-design.md` (approved by Danilo 2026-10-31).

## Global Constraints

- Branch `panel-layout`. Commit after each task, and never push. Each message ends with `Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>`.
- Run every test file from the repo root: `for f in tests/test_*.lua; do lua "$f" || echo "FAIL: $f"; done`. All 38 existing files must stay green. Two kinds of change are allowed: hint-text assertions that this plan changes, and new tests.
- Nothing changes for a user who draws no razor area: same spans, same hints, same Undo labels.
- A razor area on the target lane wins over the time selection, however old it is (Danilo). "Entire item" ignores razor areas.
- Contour writes only to the target lane. It never writes to a lane that you did not target or pick.
- Exact texts:
  - Range text: `Razor %.3f .. %.3f s`. For several areas: `Razor ×%d, %.3f .. %.3f s`.
  - `Razor on 1 other lane`. Chooser label: `Razor on %d lanes:`. Chooser placeholder: `choose a lane`.
  - Range hint: `Make a time selection or a razor area (or switch Scope to Entire item).`
  - Outside hints: `The razor area is outside this automation item` and `The razor area is outside this item`.
  - Transform: `Transform needs one razor area on this lane`.
- Timing constants in `core/context.lua`: `RAZOR_READ_SEC = 0.1` and `RAZOR_SETTLE_SEC = 0.25`. A change counts only when it has been stable for 0.25 s and the left mouse button is up (`JS_Mouse_GetState(1) & 1 == 0`). Without js_ReaScriptAPI, stability alone decides.
- Guard every optional `reaper.*` call. Under the test stubs, unknown functions return nil (`reaper_stub`) or do not exist (`test_context` mock). Then razor support is simply off.
- ImGui stack: `EndCombo` only after a `BeginCombo` that returned true. Run the combo body in `pcall`, end it, then re-raise with `error(err, 0)`, as `shell.paletteMenu` does.
- The new nomain module must be listed in `contour.lua`'s `@provides` as `[nomain] core/razor.lua`, or ReaPack does not install it.
- New files (Danilo approves them with this plan): `Contour/core/razor.lua`, `tests/test_razor.lua` and `dev/dump_razor.lua`.

## Review Focus

1. **A click without a drag, or an area of zero length** (`t1 - t0 <= 1e-9`): ignore it. It never becomes a span, never counts as a change, and never switches the lane.
2. **Two areas on one lane that touch or overlap** (1–2 s and 2–3 s): merge them into ONE span. Otherwise the second write's range delete removes the point that the first write put at 2 s.
3. **One drag over two lanes of the SAME track** (Synth Volume and Synth Pan): this is two lanes. It shows the chooser and never switches.
4. **An area that only touches an automation item's edge** (it ends exactly where the item starts): the clamp leaves zero length, so it is skipped. If it was the only area, the target gets `razorOutside`.
5. **A razor GUID with no matching envelope** (a deleted envelope, or a stale string): leave that lane out of `razorLanes` and of the switch. Never error.

Each line has its test in the owning task (marked **[RF n]**).

---

### Task 0: Spike in REAPER (throwaway)

**Files:**
- Create: `dev/dump_razor.lua` (dev only, outside the `Contour/` folder, never packaged)

The answers decide the parser fixtures and whether Task 8 runs. Danilo runs the script in REAPER. A subagent cannot.

- [ ] **Step 1:** Write `dev/dump_razor.lua`, a `reaper.defer` loop that runs every 0.1 s.
  - For the master track and every track, it prints any change of `P_RAZOREDITS` and `P_RAZOREDITS_EXT`, with `time_precise()` and `JS_Mouse_GetState(1)` when present.
  - It does NOT print every frame.
  - A second mode (`MODE = "select"` at the top) takes the first envelope GUID in any razor string, finds the envelope by walking `GetTrackEnvelope`, and calls `SetCursorContext(2, env)`. It then prints `GetSelectedEnvelope(0) == env`.
- [ ] **Step 2: Danilo runs it** and records the answers in the spec's "Known facts" section:
  - (a) The raw string for one area on an envelope lane, one on an item lane, and one drag over three tracks.
  - (b) Does the string change during the drag, or only on mouse-up?
  - (c) Does a razor drag on an envelope lane select that envelope?
  - (d) Does `SetCursorContext(2, env)` select `env`? Does it take the keyboard focus or the window order away from a floating Contour window?
- [ ] **Step 3: Decide the route.**
  - If (d) is "selects, and Contour stays usable", skip Task 8.
  - If not, run Task 8 after Task 5.
- [ ] **Step 4:** Commit the script and the spec update (`dev: razor spike script and findings`).

### Task 1: `core/razor.lua`, the pure razor logic

**Files:**
- Create: `Contour/core/razor.lua`, `tests/test_razor.lua`

**Interfaces (Produces):**
- `razor.parse(s: string|nil) -> { {t0=number, t1=number, guid=string}, ... }`
  - `guid` is `""` for the item lane.
  - Accept the GUID quoted (`""`, `"{...}"`) and unquoted (`{...}`).
  - Skip a triple whose times do not parse or where `t1 - t0 <= 1e-9`.
- `razor.mergeSpans(spans) -> spans`: sorted by `t0`, merging spans that overlap or touch (gap ≤ 1e-9). Spans are `{t0, t1}` arrays.
- `razor.clamp(spans, a, b) -> spans`: drop spans outside `[a, b]`, trim partial ones, and drop spans with zero length after the trim.
- `razor.snapshot(tracks: { {track=any, raw=string|nil}, ... }) -> Snap`, where:
  - `Snap = { env = { [guid] = { track = any, spans = {...} } }, item = { [track] = spans }, order = { guid, ... } }`
  - Spans are merged.
  - `order` is the order of first appearance, with tracks in the given order.
- `razor.envSpans(snap, guid) -> spans` and `razor.itemSpans(snap, track) -> spans`. Both return `{}` when nothing is there.
- `razor.sigOf(snap) -> string`: stable for equal snapshots, and different for any span change.
- `razor.changedLanes(prev: Snap|nil, cur: Snap) -> { guid, ... }`
  - Returns the envelope lanes in `cur` that have at least one span not in `prev` (|Δ| ≤ 1e-6 on both ends).
  - A lane whose spans only disappeared is excluded.
  - Result order = `cur.order`.
- `razor.newSettler(settleSec: number) -> settler`, with `settler:feed(sig: string, now: number, mouseDown: boolean) -> boolean`.
  - The first call sets the baseline and returns false.
  - It returns true exactly once per new state: when `sig` differs from the last settled sig, has stayed equal for ≥ `settleSec`, and `mouseDown` is false.

- [ ] **Step 1: Write the failing tests in `tests/test_razor.lua`** (harness as in other test files). Exact cases:
  - `parse('1.0 2.0 "" 3.5 4.0 "{A}"')` → two entries, the second with `guid == "{A}"`.
  - `parse('1 2 {A}')` → one entry with guid `{A}`.
  - `parse('')` and `parse(nil)` → `{}`.
  - `parse('1 2')`, an incomplete triple → `{}`.
  - **[RF 1]** `parse('2 2 "{A}"')` → `{}`.
  - **[RF 2]** `mergeSpans({{2,3},{1,2}})` → `{{1,3}}`; `mergeSpans({{1,2.5},{2,3}})` → `{{1,3}}`; `mergeSpans({{1,2},{4,5}})` stays two spans.
  - `clamp({{0,5}}, 1, 4)` → `{{1,4}}`; `clamp({{5,6}}, 1, 4)` → `{}`.
  - **[RF 4]** `clamp({{0,1}}, 1, 4)` → `{}`.
  - `snapshot` over two tracks:
    - Track T1 has `'1 3 "{A}" 0 2 ""'`, and track T2 has `'1 3 "{B}"'`.
    - Expect `order == {"{A}","{B}"}`, `envSpans(s,"{A}") == {{1,3}}` and `itemSpans(s,"T1") == {{0,2}}`.
  - **[RF 3]** One track with `'1 3 "{A}" 1 3 "{P}"'` → `order == {"{A}","{P}"}`.
  - `changedLanes(nil, s)` → all lanes in order.
  - `changedLanes(s, s)` → `{}`.
  - After the `{A}` span moves to `{2,4}` → `{"{A}"}`.
  - After `{B}` is removed → `{}`.
  - Settler with `settleSec = 0.25`:
    - The first `feed("x", 0, false)` → false.
    - `feed("y", 0.1, false)` → false.
    - `feed("y", 0.3, false)` → false (0.2 s stable).
    - `feed("y", 0.36, false)` → true.
    - `feed("y", 0.5, false)` → false (already reported).
    - With the mouse down: `feed("z", 1, false)`, then `feed("z", 2, true)` → false, then `feed("z", 2.1, false)` → true.
- [ ] **Step 2:** Run `lua tests/test_razor.lua`. Expected: FAIL with "module 'core.razor' not found".
- [ ] **Step 3:** Implement `Contour/core/razor.lua` with no `reaper.*` references, in the style of `core/reduce.lua` (header comment, local helpers, `return M`).
- [ ] **Step 4:** Run `lua tests/test_razor.lua` → all PASS. Then run the full suite → green.
- [ ] **Step 5:** Commit (`core: razor area parsing, merging, diff and settle`).

### Task 2: Read razor areas in `core/context.lua`

**Files:**
- Modify: `Contour/core/context.lua` (`M.detect`, plus new locals)
- Modify: `tests/reaper_stub.lua` (track and envelope fixtures)
- Test: `tests/test_context.lua` (new cases with the mock extended)

**Interfaces:**
- **Consumes:** all of Task 1.
- **Produces:** `detect()` gains these fields. It keeps `hasTimeSel`, `t0` and `t1` unchanged.
  - `rangeSource`: `"razor"` when the target lane has razor spans (even if all of them are clamped away), else `"timesel"`.
  - `ranges`: the clamped razor spans, or `{ {t0, t1} }` when `hasTimeSel`, else `{}`.
  - `razorOutside`: true when `rangeSource == "razor"` and `#ranges == 0`.
  - `razorLanes`: `{ {guid=string, env=handle, label="Track: Envelope"}, ... }` for the covered envelope lanes whose GUID resolves to an envelope, in snapshot order.
  - `razorSwitchTo`: an envelope handle on the ONE frame where the settler reports a change and `changedLanes` holds exactly one resolvable envelope lane, else nil.
  - `hasRange`: `#ranges > 0`.
- **Also produces:** `M.engageArrange()`, which sets the recency to `"arrange"`, and `M._resetRazor()` for tests.

Which spans belong to the target (spec section 1):
- A track envelope or an automation item uses `envSpans` of the envelope's GUID (`GetSetEnvelopeInfo_String(env, "GUID", "", false)`).
- An automation item then applies `clamp` to `D_POSITION .. D_POSITION + D_LENGTH`.
- A take envelope uses `itemSpans` of `GetMediaItem_Track(item)`, clamped to the item's `D_POSITION .. + D_LENGTH`.
- MIDI CC always uses `"timesel"`.

The reading itself:
- Tracks come from `GetMasterTrack(0)` first, then `CountTracks(0)`/`GetTrack(0, i)`.
- Each track's string comes from `GetSetMediaTrackInfo_String(tr, "P_RAZOREDITS", "", false)`.
- To resolve a GUID, walk `CountTrackEnvelopes`/`GetTrackEnvelope` on its track.
- Lane labels are `"<track name>: <envelope name>"`: the name comes from `P_NAME`, or `"Track N"` (1-based) when it is empty, or `"Master"` for the master track. The envelope name comes from `GetEnvelopeName`.
- Reuse the last snapshot when less than `RAZOR_READ_SEC` has passed (`time_precise`).
- Feed the settler with `razor.sigOf(snap)` on every read.

- [ ] **Step 1:** Extend `tests/reaper_stub.lua`:
  - `M.tracks` (cleared by `M.reset`): a list of `{ handle, name, razor, envs = { {handle, guid, name} } }`.
  - `M.master`: `{ handle = "MASTER", razor = "", envs = {} }`.
  - `CountTracks`, `GetTrack`, `GetMasterTrack`.
  - `GetSetMediaTrackInfo_String` for `P_RAZOREDITS` and `P_NAME`.
  - `CountTrackEnvelopes` and `GetTrackEnvelope`.
  - `GetSetEnvelopeInfo_String` for `GUID`.
  - `GetEnvelopeInfo_Value(env, "P_TRACK")`: the fixture's track when the env is in `M.tracks`, else today's `"TRACK"`.
  - `SetCursorContext`, recorded in `M.rec.cursorCtx`.
  - `JS_Mouse_GetState`, which returns `M.mouseState` (default 0).
  
  Add the same functions to the `test_context.lua` mock, driven by `S.tracks`, `S.now` and `S.mouse`.
- [ ] **Step 2: Write the failing tests in `tests/test_context.lua`:**
  - `razor on the selected envelope's lane becomes the range`:
    - `ENV_A` has GUID `{A}` and the razor `'2 4 "{A}"'`. The time selection is 0..10.
    - Expect `rangeSource == "razor"`, `ranges == {{2,4}}`, `hasTimeSel == true` (unchanged) and `t0 == 0`.
  - `no razor keeps the time selection`: `rangeSource == "timesel"` and `ranges == {{0,10}}`.
  - `razor on another lane only`: `rangeSource == "timesel"`. `razorLanes` holds that lane with label `"Pad: Volume"`.
  - `automation item clamp`: the AI is at 3..5 and the razor is `'0 4 "{A}"'` → `ranges == {{3,4}}`.
    - **[RF 4]** With the razor `'0 3 "{A}"'` → `razorOutside == true` and `hasRange == false`.
  - **[RF 5]** `GUID with no envelope`: the razor `'1 2 "{GONE}"'` → `razorLanes == {}`, `razorSwitchTo == nil`, no error.
  - `switch fires once after settle`:
    - The baseline read is at `now = 0` with no razor.
    - At 0.2 s, add `'1 2 "{B}"'` (`ENV_B`). `detect()` gives `razorSwitchTo == nil`.
    - At 0.5 s → `razorSwitchTo == ENV_B`.
    - At 0.7 s → nil again.
  - `switch waits for mouse-up`: the same, with `S.mouse = 1` at 0.5 s → nil. With the mouse up at 0.6 s → `ENV_B`.
  - **[RF 3]** `two lanes never switch`: add `'1 2 "{A}" 1 2 "{P}"'` on one track → `razorSwitchTo == nil` after the settle, and `#razorLanes == 2`.
  - `areas present at start do not switch`: the razor exists before the first `detect()` → `razorSwitchTo` stays nil.
  - `no razor API`: the existing mock without the new functions → `rangeSource == "timesel"` and no error. This is today's behaviour, so the existing tests must stay green unchanged.
- [ ] **Step 3:** Run `lua tests/test_context.lua`. Expected: the new cases FAIL.
- [ ] **Step 4:** Implement in `core/context.lua`. Use the throttle and the settler from the constants above. `M._resetRazor()` clears the snapshot, the settler and the read time. `M.engageArrange()` sets `lastSide = "arrange"`.
- [ ] **Step 5:** Run the full suite → green. Commit (`context: razor areas become the target lane's range`).

### Task 3: One span list, used by Generate

**Files:**
- Modify: `Contour/ui/common.lua` (`spanFor` becomes `spansFor`, and a wrapper is kept)
- Modify: `Contour/ui/generate.lua` (`generateAndWrite`, `liveBulkWrite`, `canGenerate`, `drawFooter` hints and orchestration, `M.run`)
- Test: `tests/test_render_smoke.lua` and `tests/test_generate_sweep.lua` (if it calls `spanFor`)

**Interfaces:**
- **Consumes:** `detected.rangeSource`, `ranges`, `razorOutside` and `hasRange` from Task 2.
- **Produces:**
  - `common.spansFor(tgt, detected, g) -> { {t0, t1}, ... }`. This is the ONE place that resolves the range (the spec asks for this, so that the later toggle has one home). It works in this order:
    1. "Entire item" with a non-track-envelope target → `{ fullSpan }`, as today.
    2. `detected.rangeSource == "razor"` → `detected.ranges`.
    3. Otherwise → today's time-selection span with today's clamp, as a one-element list.
  - `common.spanFor` stays as a wrapper that returns the first span's `t0, t1`.

Generate changes:
- `generateAndWrite` and `liveBulkWrite` take a `spans` list and write each span. Spans are `{t0, t1}` arrays, as in Task 1. Each span calls `buildParams(g, span[1], …)` and `generateSpan(g, span[1], span[2], params)`, so each area's LFO starts at its own start. They return the summed count.
- `M.run` opens ONE `Undo_BeginBlock2`, writes all spans with `noUndo = true`, and closes with today's target-aware label.
- When the live gesture opens, it stores `liveGesture.spans = common.spansFor(...)` and `liveGesture.laneKey = tostring(d.env) .. ":" .. tostring(d.aiIndex) .. ":" .. tostring(d.take)`. Every live write uses `liveGesture.spans`.
- If `laneKey` changes while the gesture is open → `endLiveGesture(true)` before anything else, next to the existing take-change guard.
- `canGenerate` uses `detected.hasRange` where it checked `hasTimeSel`, except for "Entire item", as today.
- Hints, in this order:
  1. `razorOutside` → `The razor area is outside this automation item` for an AI target, `The razor area is outside this item` for a take envelope.
  2. Otherwise, no range → the new range hint (Global Constraints).

- [ ] **Step 1: Write the failing tests** (render smoke; use the stub's `M.rec.ins` and `undoBlocks`):
  - `Generate writes one LFO per razor area in one Undo step`:
    - `detEnv()` with `rangeSource="razor"` and `ranges={{0,1},{2,3}}`, Sine, Live off, `generate.run`.
    - Expect `undoBlocks == 1`.
    - Every inserted point has `t` in `[0,1]` or `[2,3]`.
    - The first point of each area is at its `t0` (±1e-6).
  - `razor beats the time selection`: `ranges={{2,3}}` while `t0=0, t1=4` → no point below 2.
  - `entire item ignores razor`: an AI target, scope `SCOPE_ENTIRE` → one span equal to `fullSpan`.
  - `frozen spans during a live drag`:
    - Open a live gesture with `ranges={{0,1}}`.
    - Change `detected.ranges` to `{{2,3}}` on the next edited frame.
    - All writes stay in `[0,1]`.
  - `lane change ends the live gesture`: open the gesture on `details.env = "ENV_A"`, then draw a frame with `"ENV_B"` → `undoBlocks` closed (the `EndBlock2` count is up by 1) before any write to `ENV_B`.
  - `outside hint`: an AI target with `razorOutside = true` → the footer shows the AI outside text, and nothing is written.
  - Update the existing assertion on the old hint text to the new text.
- [ ] **Step 2:** Run → the new tests FAIL.
- [ ] **Step 3:** Implement as described above. Keep CC on a single span (`ranges` is never razor for CC).
- [ ] **Step 4:** Full suite → green. Commit (`generate: write one LFO per razor area, freeze spans per live drag`).

### Task 4: Reduce over several spans

**Files:**
- Modify: `Contour/ui/reduce.lua` (`base`, `ensureBaseline` range branch, `reducedAt`, live write, `M.run`, hints)
- Test: `tests/test_render_smoke.lua` and `tests/test_reduce_reset.lua`

**Interfaces:**
- **Consumes:** `common.spansFor` (Task 3).
- **Produces:** nothing new for later tasks.

Changes to Reduce:
- The range scopes store `base.regions = { { t0 = number, t1 = number, orig = points, origCount = number }, ... }`, one entry per span from `spansFor`. `base.origCount` is the sum.
- `resolveWhole` keeps the stored original only when EVERY region still matches our last output (`pointsMatch` per region).
- `reducedAt` thins each region on its own. The live write and `M.run` write each region in one Undo step: the live gesture's block, or one `Undo_BeginBlock2` in `M.run` with `noUndo = true` writes.
- The "Selected points" scope stays one region, as today.
- A change of `targetKey` while `gesture.open` → `endGesture(true)` before the baseline is re-read.
- The hints use the new range text and the outside texts, as in Task 3.

- [ ] **Step 1: Write the failing tests:**
  - `Reduce thins each razor area and leaves the gap untouched`:
    - Use a dense zigzag of `stub.envPoints` over 0..6, `ranges={{0,2},{4,6}}`, amount 80, `reduce.run`.
    - Points in (2,4) are written back unchanged, or not touched at all.
    - Each area has fewer points than before. `undoBlocks == 1`.
  - `Reset after a two-area reduce restores both areas`: amount 80, then 0 → the points equal the original in both areas.
- [ ] **Step 2:** Run → FAIL.
- [ ] **Step 3:** Implement.
- [ ] **Step 4:** Full suite → green. This includes `test_reduce_reset.lua`, which must stay unchanged in its single-span cases. Commit (`reduce: thin each razor area, one Undo step`).

### Task 5: Context line, chooser and lane switch

**Files:**
- Modify: `Contour/ui/shell.lua` (`contextLine`, `M.draw`)
- Test: `tests/test_render_smoke.lua`

**Interfaces:**
- **Consumes:**
  - `detected.rangeSource`, `ranges`, `razorLanes` and `razorSwitchTo` (Task 2)
  - `context.engageArrange()` (Task 2)
- **Produces:** `local function selectLane(env)` in `shell.lua`, which calls `reaper.SetCursorContext(2, env)` (guarded) and then `context.engageArrange()`. Task 8 replaces its body.

What the context line shows, after `detected.label`:
- When `rangeSource == "razor"` and `#ranges ≥ 1`: the range text in `theme.C.textDim`.
- When `razorOutside` is true: the outside text in `theme.C.hint`.
- Otherwise: today's time-selection text or "No time selection".

Then, on the same line:
- If `#razorLanes ≥ 2`: the label `Razor on %d lanes:` and a combo (`BeginCombo`, width 170).
  - The preview is the current target's lane label when its GUID is in `razorLanes`, else `choose a lane`.
  - Each entry is a `Selectable(label)`. A click calls `selectLane(entry.env)`.
- Else, if `#razorLanes == 1` and that lane is not the target: `Razor on 1 other lane`.
- Follow keeps its right-aligned place.

The switch: at the top of `M.draw`, `if state.follow and detected.razorSwitchTo then selectLane(detected.razorSwitchTo) end`. Detection picks up the new lane on the next frame.

- [ ] **Step 1: Write the failing tests:**
  - `context line shows the razor range`: `ranges={{1.2,1.95}}`, `rangeSource="razor"` → a text call contains `Razor 1.200 .. 1.950 s`.
  - With two spans `{{1,2},{5,6}}` → `Razor ×2, 1.000 .. 6.000 s`.
  - `chooser lists covered lanes`:
    - Three `razorLanes` → `BeginCombo` is called with the preview `choose a lane`.
    - When the target's GUID is in the list → the preview is its label.
    - With `Selectable` overridden to return true for `"Drums: Volume"` → `stub.rec.cursorCtx` records `(2, "ENV_D")`.
    - The `BeginCombo`/`EndCombo` counts are balanced at 360 and 700 px.
  - `throw inside the chooser`: `Selectable` throws → `EndCombo` and `EndTabBar` still run, and the error is re-raised.
  - `switch only with Follow on`: `razorSwitchTo="ENV_B"` with `follow=true` → `cursorCtx` recorded. With `follow=false` → nothing.
  - `one other lane`: one `razorLanes` entry that is not the target → the text `Razor on 1 other lane`.
- [ ] **Step 2:** Run → FAIL.
- [ ] **Step 3:** Implement. Add the stub counters `comboBegin` and `comboEnd` to `balanced()`.
- [ ] **Step 4:** Full suite → green. Commit (`shell: razor range text, lane chooser, switch on a settled drag`).

### Task 6: Transform uses the razor area

**Files:**
- Modify: `Contour/ui/overlay.lua` (`readScope`, `M.start`)
- Modify: `Contour/ui/transform_panel.lua` (message, disabled Launch)
- Test: `tests/test_render_smoke.lua`

**Interfaces:**
- **Consumes:** `detected.rangeSource`, `ranges` and `hasRange` (Task 2). The overlay script calls `context.detect()` itself, so it gets these fields with no hand-off.
- **Produces:** nothing new.

The changes:
- In `readScope(detected, "timesel")`:
  - If `rangeSource == "razor"`: exactly one span → `t0, t1` = that span. More than one → `return nil, "Transform needs one razor area on this lane"`. None → the outside text.
  - Otherwise, today's time-selection path.
- `M.start` uses `detected.hasRange` where it tests `detected.hasTimeSel`.
- `transform_panel.draw` takes `detected` as a new third argument; `shell` passes it.
  - When `rangeSource == "razor"` and `#ranges > 1`, it shows the message in `theme.C.warn`.
  - In that case Launch is disabled (`BeginDisabled`), and nothing is written to ExtState.

- [ ] **Step 1: Write the failing tests:**
  - `overlay uses the single razor area`: `ranges={{2,4}}`, `rangeSource="razor"`, the time selection 0..4 → `overlay.start` succeeds, and the region holds only points with t in [2,4] (fixture points at 0, 2 and 4 → the points at 2 and 4).
  - `two areas refuse`: `ranges={{0,1},{2,3}}` → `start` returns false with the exact message.
  - `panel message and disabled launch`: the same descriptor → `transform_panel.draw` shows the message, and `stub.rec.extState.tr_scope` stays nil, even with `Button` overridden to return true.
- [ ] **Step 2:** Run → FAIL.
- [ ] **Step 3:** Implement.
- [ ] **Step 4:** Full suite → green. Commit (`transform: use the lane's razor area, refuse several`).

### Task 7: Packaging and the in-REAPER self-test

**Files:**
- Modify: `Contour/contour.lua` (`@provides`: add `[nomain] core/razor.lua` after `core/midistream.lua`)
- Modify: `tests/reaper/contour_selftest.lua` (a razor round trip)

- [ ] **Step 1:** Add the `@provides` line. Run `lua -e "assert(io.open('Contour/core/razor.lua'))"` and `grep -n "core/razor.lua" Contour/contour.lua` → both succeed.
- [ ] **Step 2:** In `contour_selftest.lua`, add a case after the envelope round trip:
  1. Make the scratch track's Volume envelope visible.
  2. Read its GUID.
  3. Set the track's `P_RAZOREDITS` to `"1.0 2.0 \"<guid>\""`.
  4. Select the envelope, call `context.detect()`, and assert `rangeSource == "razor"`.
  5. Run `generate.run` with Sine. Assert that every point lies in [1, 2].
  6. Clear `P_RAZOREDITS`.
  
  Print PASS/FAIL like the other cases.
- [ ] **Step 3:** Full headless suite → green. Commit (`selftest: razor round trip; package core/razor.lua`).
- [ ] **Step 4: Danilo's REAPER check.** Run the self-test from the Action list, then try the spec's worked examples 1–10. Report what differs.

### Task 8 (conditional, only if Task 0 (d) failed): a lane pinned inside Contour

**Files:**
- Modify: `Contour/core/context.lua`, `Contour/ui/shell.lua` (`selectLane`), `tests/test_context.lua`

**Interfaces:**
- **Produces:** `context.pin(env)` and `context.unpin()`.
  - `detect()` prefers a pinned, still-valid envelope (`ValidatePtr2(0, env, "TrackEnvelope*")`) over `GetSelectedEnvelope(0)`.
  - The pin clears when `GetSelectedEnvelope(0)` changes to a different envelope than at pin time, and when the MIDI side becomes the recent side.
  - The pin is shared with the Transform script through ExtState `Contour/pin_env` (the GUID, not persisted), which `detect()` reads.
- `selectLane(env)` calls `context.pin(env)` and does NOT call `SetCursorContext`.

- [ ] **Step 1: Failing tests:**
  - A pin wins over the selected envelope.
  - Selecting another envelope clears the pin.
  - An invalid pinned envelope is ignored.
  - The ExtState GUID resolves in a fresh `detect()` (simulating the overlay script).
- [ ] **Step 2:** Run → FAIL.
- [ ] **Step 3:** Implement.
- [ ] **Step 4:** Run → PASS.
- [ ] **Step 5:** Full suite → green. Commit (`context: pinned lane when SetCursorContext cannot select`).
