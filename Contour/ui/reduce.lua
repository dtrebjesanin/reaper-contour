-- ui/reduce.lua — Reduce panel: thin existing automation/CC points with vertical-distance RDP
-- (core/reduce). NON-DESTRUCTIVE: a baseline of the pristine points is captured and every reduction
-- re-derives from it, so 0%/Reset restores the original and dialing up never compounds.
--
-- Three scopes:
--   * Time selection  — thin all points inside the time selection.
--   * Entire item     — thin the whole CC item / automation item (not for track envelopes).
--   * Selected points — thin ONLY the points the user has selected, leaving the rest untouched.
--
-- Baseline lifetime:
--   * Range scopes (Time selection / Entire item): baseline is PERSISTENT, keyed by target+lane+span,
--     so Reset restores the original across separate drags. It is re-captured when that key changes,
--     when the project changes underneath it (GetProjectStateChangeCount fingerprint — catches Generate
--     or manual edits to the same lane), and it is invalidated on op-switch (M.cleanup).
--   * Selected scope: baseline is LATCHED per drag gesture (the write clears the selection, so it can't
--     persist across gestures); scrubbing within the drag still restores.
local M = {}

local reduce = require("core.reduce")
local target = require("core.target")
local common = require("ui.common")

local COLOR_ERR  = 0xE05050FF
local COLOR_OK   = 0x60C080FF
local COLOR_HINT = 0xC0A040FF

local SCOPE_TIMESEL, SCOPE_ENTIRE, SCOPE_SELECTED = 0, 1, 2

-- Reduction slider (0..100 %) -> RDP tolerance as a fraction of the value range (span-invariant; see
-- core/reduce). Quadratic for fine control at the low end: 100% -> 0.5, 50% -> 0.125, 10% -> ~0.005.
local MAX_AMOUNT = 0.5
local function amountFor(pct) local f = (pct or 0) / 100; return f * f * MAX_AMOUNT end

local function ui(state)
  if not state.red then
    state.red = { amount = 0, scope = SCOPE_TIMESEL, live = true, status = "", statusErr = false }
  end
  return state.red
end

-- Scope choices per target (track envelopes have no "item", so no Entire-item option).
local function scopeChoices(t)
  if t == "envelope" then
    return { { label = "Time selection", v = SCOPE_TIMESEL }, { label = "Selected points", v = SCOPE_SELECTED } }
  end
  return { { label = "Time selection", v = SCOPE_TIMESEL },
           { label = "Entire item", v = SCOPE_ENTIRE },
           { label = "Selected points", v = SCOPE_SELECTED } }
end

-- Target-aware undo metadata: CC edits are items (flag 4); envelope/AI point edits use ALL (-1).
local function undoMetaFor(t)
  if t == "cc" then return 4, "Contour: Reduce CC" end
  if t == "ai" then return -1, "Contour: Reduce automation item" end
  return -1, "Contour: Reduce envelope"
end

-- base: the captured pristine points. base.selectedMode marks the latched-per-gesture selected scope.
-- The baseline persists across drags (so Reset restores the original) but is INVALIDATED on op-switch
-- (M.cleanup) — that closes the Generate->Reduce-same-lane staleness path without a per-frame fingerprint
-- (a fingerprint risked re-capturing from already-reduced data and breaking the Reset-restore promise).
local base = { key = nil, tgt = nil, snapshot = nil, orig = nil, origCount = 0,
               t0 = nil, t1 = nil, selectedMode = false }
local gesture = { open = false, undoFlag = 4, undoLabel = "Contour: Reduce" }

local function invalidateBase()
  base.key, base.tgt, base.snapshot, base.orig = nil, nil, nil, nil
  base.selectedMode, base.origCount = false, 0
end

local function baselineKey(detected, st0, st1)
  local d = detected.details or {}
  local id
  if detected.target == "cc" then
    local lane = (d.midiEditor and reaper.MIDIEditor_GetSetting_int
      and reaper.MIDIEditor_GetSetting_int(d.midiEditor, "last_clicked_cc_lane")) or -1
    id = "cc:" .. tostring(d.take) .. ":" .. tostring(lane)
  elseif detected.target == "ai" then
    id = "ai:" .. tostring(d.env) .. ":" .. tostring(d.aiIndex)
  else
    id = "env:" .. tostring(d.env)
  end
  return ("%s@%.4f,%.4f"):format(id, st0 or 0, st1 or 0)
end

-- Ensure `base` holds the pristine points to reduce. `gestureOpen` lets the selected scope latch its
-- selection for the duration of a drag. Returns true or (false, errString).
local function ensureBaseline(detected, g, gestureOpen)
  local tgt, tErr = target.fromContext(detected)
  if not tgt then return false, tErr or "No target" end

  if g.scope == SCOPE_SELECTED then
    -- Latch the selection per gesture: the write clears point selection, so re-resolving mid-drag would
    -- lose it. Reuse the captured base while this gesture stays open; re-read on a fresh interaction.
    if gestureOpen and base.selectedMode and base.orig and base.tgt then return true end
    local all = tgt:read(nil, nil)
    local tmin, tmax, n = nil, nil, 0
    for _, p in ipairs(all) do
      if p.sel then
        n = n + 1
        if not tmin or p.time < tmin then tmin = p.time end
        if not tmax or p.time > tmax then tmax = p.time end
      end
    end
    if n == 0 then return false, "Select some points first" end
    local snap, sErr = tgt:snapshot()
    if not snap then return false, sErr or "Snapshot failed" end
    local orig = {}
    for _, p in ipairs(all) do if p.time >= tmin and p.time <= tmax then orig[#orig + 1] = p end end
    base.key, base.tgt, base.snapshot = "selected", tgt, snap
    base.t0, base.t1, base.selectedMode = tmin, tmax, true
    base.orig, base.origCount = orig, #orig
    return true
  end

  -- Range scopes: persistent baseline keyed by target identity + span.
  local st0, st1 = common.spanFor(tgt, detected, g)
  if not (st0 and st1 and st1 > st0) then return false, "Empty range" end
  local key = baselineKey(detected, st0, st1)
  if base.key == key and base.orig and not base.selectedMode then return true end
  local snap, sErr = tgt:snapshot()
  if not snap then return false, sErr or "Snapshot failed" end
  base.key, base.tgt, base.snapshot = key, tgt, snap
  base.t0, base.t1, base.selectedMode = st0, st1, false
  base.orig = tgt:read(st0, st1)
  base.origCount = #base.orig
  return true
end

-- The points to write at the current amount. 0% restores the exact baseline. In selected scope only the
-- selected points are thinned; the unselected ones are kept verbatim and merged back.
local function reducedAt(g)
  local pts = base.orig
  if (g.amount or 0) <= 0 then return pts end
  local vmin, vmax = base.tgt:valueRange()
  local eps = amountFor(g.amount)
  if not base.selectedMode then
    return reduce.thin(pts, eps, { vmin = vmin, vmax = vmax })
  end
  local sel, unsel = {}, {}
  for _, p in ipairs(pts) do if p.sel then sel[#sel + 1] = p else unsel[#unsel + 1] = p end end
  local keptSel = reduce.thin(sel, eps, { vmin = vmin, vmax = vmax })
  local merged = {}
  for _, p in ipairs(unsel) do merged[#merged + 1] = p end
  for _, p in ipairs(keptSel) do merged[#merged + 1] = p end
  table.sort(merged, function(a, b) return a.time < b.time end)
  return merged
end

local function markCCDirty(tgt)
  if not (tgt and tgt.kind and tgt:kind() == "cc") then return end
  local take = tgt._take
  if not (take and reaper.GetMediaItemTake_Item and reaper.GetMediaItem_Track and reaper.MarkTrackItemsDirty) then
    return
  end
  local item = reaper.GetMediaItemTake_Item(take)
  if not item then return end
  reaper.MarkTrackItemsDirty(reaper.GetMediaItem_Track(item), item)
end

local function endGesture(committed)
  if not gesture.open then return end
  if committed then
    markCCDirty(base.tgt)
    reaper.Undo_EndBlock2(0, gesture.undoLabel, gesture.undoFlag)
  else
    reaper.Undo_EndBlock2(0, "", 0)
  end
  gesture.open = false
end

-- Called from contour.lua atexit / window-close and on op switch. Closes a dangling block AND clears
-- the baseline so returning to Reduce (e.g. after Generate edited the same lane) re-reads fresh.
function M.cleanup()
  if gesture.open then
    markCCDirty(base.tgt)
    reaper.Undo_EndBlock2(0, gesture.undoLabel, gesture.undoFlag)
    gesture.open = false
  end
  invalidateBase()
end

-- Can a write run for this scope right now (selection check is deferred to ensureBaseline)?
local function readyFor(detected, g)
  if not (detected and detected.details) then return false end
  local t = detected.target
  if t ~= "cc" and t ~= "envelope" and t ~= "ai" then return false end
  if g.scope == SCOPE_SELECTED then
    if t == "cc" then return detected.details.take ~= nil
    elseif t == "envelope" then return detected.details.env ~= nil
    else return detected.details.env ~= nil and detected.details.aiIndex ~= nil end
  end
  local needTimeSel = (g.scope == SCOPE_TIMESEL) or (t == "envelope")
  if needTimeSel and not detected.hasTimeSel then return false end
  if t == "cc" then return detected.details.take ~= nil
  elseif t == "envelope" then return detected.details.env ~= nil
  else return detected.details.env ~= nil and detected.details.aiIndex ~= nil end
end

function M.draw(ctx, state, detected)
  local g = ui(state)

  if gesture.open and state.op ~= "reduce" then endGesture(true) end

  reaper.ImGui_Text(ctx, "Reduce points")

  do
    local rv, v = reaper.ImGui_Checkbox(ctx, "Live##red_live", g.live)
    if rv then g.live = v; if not g.live then endGesture(true) end end
  end
  reaper.ImGui_SameLine(ctx)
  reaper.ImGui_TextColored(ctx, COLOR_HINT, g.live and "on (auto-apply)" or "off (click Reduce)")
  reaper.ImGui_Separator(ctx)

  local editedThisFrame = false
  local function acc(c) if c then editedThisFrame = true end end

  -- Scope selector (target-appropriate options; maps the combo index to a scope constant).
  local t = detected and detected.target
  do
    local choices = scopeChoices(t)
    local cur, items = 0, ""
    for i, c in ipairs(choices) do
      items = items .. c.label .. "\0"
      if c.v == g.scope then cur = i - 1 end
    end
    if choices[cur + 1].v ~= g.scope then g.scope = choices[cur + 1].v end  -- snap if prev scope invalid here
    local changed, idx = reaper.ImGui_Combo(ctx, "Scope##red_scope", cur, items, #items)
    if changed and choices[idx + 1] and choices[idx + 1].v ~= g.scope then g.scope = choices[idx + 1].v; acc(true) end
  end

  -- Reduction amount (0 = restore original; raise to thin). Notch + label double-click reset.
  do
    local changed
    changed, g.amount = reaper.ImGui_SliderInt(ctx, "Reduction##red_amt", g.amount, 0, 100, "%d%%")
    acc(changed); acc(common.tickReset(ctx, g, "amount", 0, 100, 0))
  end

  reaper.ImGui_Separator(ctx)
  if reaper.ImGui_Button(ctx, "Reset##red_reset") then g.amount = 0; acc(true) end  -- restores original (0%)
  reaper.ImGui_Separator(ctx)

  -- Status hints.
  if t ~= "cc" and t ~= "envelope" and t ~= "ai" then
    reaper.ImGui_TextColored(ctx, COLOR_HINT, "Select a MIDI CC lane, a track envelope, or an automation item.")
  elseif g.scope == SCOPE_SELECTED then
    reaper.ImGui_TextColored(ctx, COLOR_HINT, "Select points in the editor, then raise Reduction.")
  elseif (g.scope == SCOPE_TIMESEL or t == "envelope") and not detected.hasTimeSel then
    reaper.ImGui_TextColored(ctx, COLOR_HINT, "Make a time selection (or switch Scope to Entire item).")
  elseif g.amount == 0 then
    reaper.ImGui_TextColored(ctx, COLOR_HINT, "Raise Reduction to thin points")
  end

  local ready = readyFor(detected, g)

  if g.live then
    local anyActive = reaper.ImGui_IsAnyItemActive and reaper.ImGui_IsAnyItemActive(ctx) or false

    if ready and editedThisFrame then
      local okB, bErr = ensureBaseline(detected, g, gesture.open)
      if not okB then
        g.status = bErr or "Reduce setup failed"; g.statusErr = true
      elseif base.origCount == 0 then
        g.status = "No points to reduce"; g.statusErr = false   -- no-op: don't open a ghost undo block
      else
        if not gesture.open then
          reaper.Undo_BeginBlock2(0)
          gesture.open = true
          gesture.undoFlag, gesture.undoLabel = undoMetaFor(detected.target)
        end
        local ok, cnt, err, rc = pcall(function()
          local pts = reducedAt(g)
          local c, e = base.tgt:writeBulk(base.snapshot, pts, base.t0, base.t1, { noUndo = true, rawShape = true })
          return c, e, #pts
        end)
        if not ok then
          g.status = "Reduce error: " .. tostring(cnt); g.statusErr = true
          endGesture(true)
        elseif not cnt then
          g.status = err or "Reduce write failed"; g.statusErr = true
          endGesture(true)
        else
          g.status = ("%d -> %d points"):format(base.origCount, rc); g.statusErr = false
        end
      end
    end

    if gesture.open and not anyActive then endGesture(true) end
  else
    if reaper.ImGui_BeginDisabled then
      reaper.ImGui_BeginDisabled(ctx, not ready)
      if reaper.ImGui_Button(ctx, "Reduce##red_run") then M.run(state, detected, g) end
      reaper.ImGui_EndDisabled(ctx)
    elseif ready then
      if reaper.ImGui_Button(ctx, "Reduce##red_run") then M.run(state, detected, g) end
    end
  end

  if g.status ~= "" then
    reaper.ImGui_TextColored(ctx, g.statusErr and COLOR_ERR or COLOR_OK, g.status)
  end
end

-- Non-live commit (Reduce button). Self-contained single undo. Sets g.status; never throws.
function M.run(state, detected, g)
  local function fail(m) g.status = m; g.statusErr = true end
  local function ok(m)   g.status = m; g.statusErr = false end

  if not readyFor(detected, g) then
    fail("Select a CC lane / envelope / automation item (and a time selection)") return
  end
  local okB, bErr = ensureBaseline(detected, g, false)
  if not okB then fail(bErr or "No target") return end
  if base.origCount == 0 then fail("No points to reduce") return end
  local reduced = reducedAt(g)
  local _, label = undoMetaFor(detected.target)
  local n, wErr = base.tgt:write(reduced, base.t0, base.t1, { rawShape = true, undoLabel = label })
  if not n then fail(wErr or "Write failed") return end
  ok(("Reduced %d -> %d points"):format(base.origCount, #reduced))
end

return M
