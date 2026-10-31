# Razor areas as Contour's range — design

Date: 2026-10-31. Status: draft for Danilo's approval. Branch: build on `panel-layout` (or a branch from it).

## Intent

A time selection covers every track, so it feels global. A razor area belongs to the track where you drag it. That matches what Contour edits: one lane at a time. Danilo finds the razor area the more intuitive way to say "work here, from here to there".

So for Contour, a razor area works as a time selection that belongs to one lane.

## Goals

1. A razor area on the lane that Contour targets becomes the range for Generate, Reduce and Transform. It replaces the time selection for that lane.
2. A razor drag on one envelope lane makes Contour switch to that lane, without an extra click.
3. A razor drag over several lanes never makes Contour guess. A chooser on the context line lets you pick the lane.
4. You can always see which range Contour uses.

## Non-goals (this version)

- Writing to several lanes at once ("option 2"). The chooser is designed so that "All covered lanes" or a multi-pick can come later.
- The MIDI editor. It has no razor areas. MIDI CC keeps the time selection and the "Entire item" scope as today.
- Transform over several areas on one lane.
- Fixed item lanes. Razor areas carry a vertical position there (`P_RAZOREDITS_EXT`). This version ignores that position.
- A switch between razor area and time selection (Danilo, 2026-10-31: none for now). Possible later step if old razor areas get in the way: when the target lane has a razor area AND there is a time selection, the range text on the context line becomes a toggle "Razor ⇄ Time selection" for that lane, and a new razor area resets it. Keep the range resolution in one place so that this toggle can be added there.

## Anti-goals

- Contour must never write to a lane that you did not pick or target. A guess that writes to the wrong lane is a failure, even if the feature works otherwise.
- Nothing may change for a user who never draws a razor area.

## Definitions

- **Target lane**: the envelope that Contour targets now (its context descriptor: track envelope, automation item, or take envelope).
- **Razor area**: one entry of a track's `P_RAZOREDITS`: start time, end time, envelope GUID. The GUID is empty for an area on the track's item lane.
- **Covered envelope lanes**: the distinct envelope GUIDs over all tracks' razor areas. Item-lane areas are not envelope lanes.

## Behaviour

### 1. Which razor areas belong to the target lane

| Target | Areas that count |
|---|---|
| Track envelope | Areas on the envelope's track whose GUID equals the envelope's GUID |
| Automation item | Same as the track envelope that holds the item, then limited to the item's bounds. An area outside the item is skipped. |
| Take envelope | Areas on the item lane (empty GUID) of the take's track that overlap the take's item, limited to the item's bounds |
| MIDI CC | None (unchanged) |

Danilo confirmed: for a track envelope he drags on the envelope lane itself. The take-envelope rule is Claude's call: take envelopes have no lane of their own, so the item lane under the item is the natural place.

**All of the lane's areas fall outside the item (Claude's call).** A typical case: a razor area over automation item #1 while #2 is selected. Contour then has NO range for this target. It does not fall back to the time selection, because that could write where you were not looking (anti-goal). The hint says "The razor area is outside this automation item" (or "outside this item" for a take envelope). The context line always shows the clamped range, which is what Contour writes.

**The master track counts (Claude's call).** Read it with `GetMasterTrack` as well as `CountTracks`/`GetTrack`, so razor areas on master Volume/Pan lanes are found and listed.

### 2. Precedence

- The Scope choice "Time selection" now means "the range". The range is the target lane's razor areas when there are any, else the time selection, as today.
- **Razor always wins (Danilo, 2026-10-31):** "if Razor is active, it takes priority." A razor area on the target lane beats the time selection, even when the time selection is newer. Contour does not track time-selection changes. To go back to the time selection, you clear the razor area. The context line shows "Razor", so you can see which range is active.
- "Entire item" ignores razor areas, as it ignores the time selection today.
- Track envelopes have no Scope combo and always use "the range".
- The Scope combo keeps its label ("Time selection"). The context line shows which range is active (section 6).

### 3. Several areas on the target lane

- Each area is its own span.
- **Generate** writes one LFO per area. Each LFO starts at the start of its area, exactly as a time selection starting there would. Phase, rate and all controls apply per area.
- **Reduce** thins each area on its own.
- One Apply, or one live drag of a control, writes all areas in ONE Undo step.
- Live preview updates every area in each frame, with one write per area. Each write deletes and rewrites its own range, as today, so edits never compound.
- **The span list is frozen when a live gesture starts (Claude's call).** Today `liveBulkWrite` reads the span again from `detected` in every frame. A frozen list stops a razor change in the middle of a drag from moving the write. Without razor areas nothing visible changes, because you cannot change the time selection while you drag a Contour control.
- **A change of target lane ends an open live gesture (Claude's call),** with `endLiveGesture(true)`, as a take change does today. Today a change of track envelope in the middle of a gesture is not guarded. This closes that gap.
- Boundary handling at each area's edges is the same as at today's time-selection edges.

### 4. Switching to a lane (Follow on)

Contour keeps the razor state of the last read, as one snapshot of all tracks.

**When a change counts (Claude's call):** only after the drag is finished. REAPER may update `P_RAZOREDITS` while you drag. A drag that starts on Pad and continues down to Drums must not switch to Pad halfway. So a change counts only when both are true:
- the razor state has not changed for 250 ms
- the left mouse button is up, when `js_ReaScriptAPI` is installed (`JS_Mouse_GetState`)

Without `js_ReaScriptAPI`, the 250 ms rule alone decides. Contour compares the settled state with the last settled state, never with the frames in between.

- **New or changed areas on exactly one envelope lane:** Contour selects that envelope with `reaper.SetCursorContext(2, env)`. Detection then picks it up as today. Item-lane areas do not count here.
- **New or changed areas on several envelope lanes:** no switch. The chooser takes over (section 5).
- **Razor areas that already exist when Contour opens:** they are not "new". No switch. If the selected lane has areas, Contour uses them.
- **A removed area:** no switch.
- **Follow off:** never switch. The context line still reports areas on other lanes.

### 5. The chooser

- **When it shows:** the razor areas in the project cover two or more envelope lanes. It sits on the context line, for example "Razor on 3 lanes: [Pad: Volume ▾]".
- **What it lists:** each covered envelope lane as "Track name: Envelope name", in track order and then lane order.
- **Its starting value:** the current target when it is one of the covered lanes. Otherwise it shows "choose a lane", and Contour writes nothing to any covered lane until you pick one.
- **What a pick does:** it selects that envelope with `SetCursorContext(2, env)`. The rest of Contour then works as today. A pick also marks the arrange view as the surface you engaged, through a small hook in `core/context.lua` that sets its recency to "arrange". Without the hook, a pick of the envelope that is already selected does nothing while a MIDI CC target is active (`env ~= prevEnv` never fires).
- **Later:** the list is the place where "All covered lanes" or several picks can come. Build it so that adding entries is easy.

### 6. Context line and hints

- **Razor areas on the target lane:** "Razor 1.200 .. 1.950 s" for one area. For several areas: "Razor ×2, 1.000 .. 6.000 s", from the first start to the last end.
- **No areas on the target lane, but areas elsewhere:** the time selection as today, plus "Razor on N other lanes", or the chooser when N ≥ 2.
- **The hint for a missing range:** "Make a time selection or a razor area".

### 7. Transform

- The overlay's "Time selection" scope uses the target lane's razor area when the lane has exactly one.
- When the lane has several areas, the Transform panel says "Transform needs one razor area on this lane", and Launch does nothing.
- The overlay runs as its own script. It reads the razor areas itself, with the same core code.

## Architecture

- **A pure module, `core/razor.lua`** (a new file, so it needs Danilo's OK at plan time). It has no `reaper.*` calls and does these jobs:
  - parse a `P_RAZOREDITS` string into `{ t0, t1, guid }` entries
  - pick the areas for a target (section 1), including the clamp to an item
  - diff two snapshots and return the envelope lanes with new or changed areas
  - build the chooser list from a snapshot
- **The REAPER-bound reading** lives next to the time-selection read in `core/context.lua`. The descriptor gains a field such as `ranges = { {t0, t1}, ... }` and `rangeSource = "razor" | "timesel"`. It keeps `hasTimeSel`, `t0` and `t1` for existing callers.
- **Envelope GUIDs:** `GetSetEnvelopeInfo_String(env, "GUID", "", false)`. To map a GUID to an envelope, walk the track's envelopes with `CountTrackEnvelopes` and `GetTrackEnvelope`. The API has no envelope-by-GUID lookup.
- **Range users:** `ui/common.spanFor` and the Generate/Reduce write paths change from one span to a list of spans. `ui/overlay.readScope` gains the razor case.
- **Reading cost:** reading `P_RAZOREDITS` for every track in every frame may be too much in large projects. The builder chooses the rate, for example every 3 frames or on project state change (`GetProjectStateChangeCount`). Budget: a new razor area shows within 200 ms, with no visible slowdown in a 200-track project.

## Known facts and facts to verify in REAPER

- **Confirmed from the API doc (2026-10-31):**
  - `P_RAZOREDITS` is "space-separated triples of start time, end time, and envelope GUID string".
  - `SetCursorContext(2, env)` focuses the arrange view and selects `env`.
  - An envelope has a `GUID` string and the `P_TRACK` and `P_ITEM` parents.
- **Verify with a dev dump** (`dev/dump_razor.lua`, new) before the parser is final:
  - the exact quoting of the GUID field (quoted `""` for the item lane?)
  - the number format
  - what a drag across several tracks stores: which tracks and which lanes
- **Verify in REAPER:**
  - Does a razor drag on an envelope lane already select that envelope? If yes, section 4's single-lane switch is partly free. The diff must still handle the case where it does not.
  - Does `P_RAZOREDITS` change during a drag, or only on mouse-up? Section 4's settle rule handles both, but the test fixtures must match reality.
  - **The doc only says "select".** Does `SetCursorContext(2, env)` really make `GetSelectedEnvelope(0)` return `env`? Does it take the focus away from a floating Contour window?

**The plan starts with a spike (Claude's call):** a throwaway dev script checks the three points above in REAPER before anything else is built.
- If `SetCursorContext` selects the envelope and leaves the Contour window usable, the design stands.
- If it fails or steals focus, the switch and the chooser use a fallback instead: a lane pinned inside Contour (`context.pin(env)`, cleared when you select another envelope in REAPER). `detect()` prefers the pinned lane over `GetSelectedEnvelope`. Nothing else in this design changes.

## Edge cases (worked examples)

Setup: the tracks "Synth" (Volume and Pan lanes), "Pad" (Volume) and "Drums" (Volume). The target is Synth: Volume, and Follow is on.

1. **Drag on Pad: Volume only, 2 to 4 s:** Contour switches to Pad: Volume and uses 2 to 4 s.
2. **Drag 1 to 3 s across Synth: Volume and Pad: Volume:** the chooser shows and starts on Synth: Volume. Contour uses 1 to 3 s on Synth: Volume. Pad does not change.
3. **Drag across Pad: Volume and Drums: Volume:** the chooser shows "choose a lane". Synth: Volume uses the time selection. You pick Drums: Volume, and Contour switches to it.
4. **Two areas on Synth: Volume (1 to 2 s and 5 to 6 s):** Generate writes two LFOs in one Undo step. The context line shows "Razor ×2, 1.000 .. 6.000 s".
5. **Follow off, drag on Pad: Volume:** no switch. The context line shows "Razor on 1 other lane".
6. **Drag on Synth's item lane:** it does not count for Synth: Volume. It counts for a take envelope of an item under it.
7. **Areas already exist when Contour opens:** no switch. The selected lane uses its own areas.
8. **Nothing selected, drag across three tracks:** the chooser shows "choose a lane", and nothing is written until you pick one.
9. **An area partly over an automation item:** only the part inside the item counts. An area fully outside is skipped.
10. **A live drag while you change a razor area:** the open gesture keeps the span list it froze at its start. The new areas apply from the next gesture. If the change switches the target lane, the gesture ends first (section 3).

## Left to the builder

- The polling rate (within the budget above).
- The exact widths and text of the chooser, and how it shortens long names.
- Whether `ranges` replaces `t0`/`t1` inside the code, or sits next to them.
- How to name the setting, if a razor option is later needed in the UI.

## Tests

- **Pure tests for `core/razor.lua`:** parsing (quoted and unquoted GUIDs, empty string, odd token counts), area selection per target type, the clamp to an item, the snapshot diff, and the chooser list order.
- **Stub support:** `GetSetMediaTrackInfo_String(track, "P_RAZOREDITS")`, envelope GUIDs, `SetCursorContext` (recorded).
- **Render smoke:** the context line with razor text, the chooser at 360 and 700 px, and balanced stacks.
- **Generate and Reduce over two areas:** two spans written, one Undo block, nothing written outside the areas.
- **`tests/reaper/contour_selftest.lua`:** add a razor round trip in REAPER: set `P_RAZOREDITS` on a scratch track envelope, run Generate, check the points.
