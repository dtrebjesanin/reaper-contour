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
    state.red = { amount = 0, scope = SCOPE_TIMESEL, live = true, status = "", statusErr = false, curveFit = false }
  end
  return state.red
end

-- Scope choices per target (TRACK envelopes have no "item", so no Entire-item option; TAKE envelopes
-- do have one — their item — so they get the full list like CC/AI).
local function scopeChoices(t, isTake)
  if t == "envelope" and not isTake then
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

-- The active working set for the current interaction: base.orig = the PRE-REDUCE original points within
-- the working span [t0,t1] (a slice of the whole-lane original). reducedAt thins it; Reset (0%) writes it
-- back verbatim. tgt/snapshot are volatile and refreshed on every fresh interaction.
local base = { key = nil, tgt = nil, snapshot = nil, orig = nil, origCount = 0,
               t0 = nil, t1 = nil, selectedMode = false }
local gesture = { open = false, undoFlag = 4, undoLabel = "Contour: Reduce" }

-- Per-TARGET baseline store (NOT per-span): keyed by lane identity, each entry keeps the WHOLE-lane
-- original (`whole`) and a read-back of the whole lane after our last reduce (`written`). Keying by target
-- means changing the time selection / scope still finds the original; one entry per lane means reducing
-- another lane doesn't clobber this one; `written` lets us tell our own untouched output (keep the
-- original -> Reset restores it) from an external edit (re-baseline). A small FIFO cap bounds the map.
local store, order, STORE_CAP = {}, {}, 64
local function bumpLRU(key)   -- move key to newest; evict the oldest entry past the cap
  for i, k in ipairs(order) do if k == key then table.remove(order, i); break end end
  order[#order + 1] = key
  if #order > STORE_CAP then local old = table.remove(order, 1); store[old] = nil end
end
local function setStore(key, entry) bumpLRU(key); store[key] = entry end

-- points of `all` whose time is within [a,b]
local function regionOf(all, a, b)
  local out = {}
  for _, p in ipairs(all) do if p.time >= a - 1e-9 and p.time <= b + 1e-9 then out[#out + 1] = p end end
  return out
end

-- Clone `region` points, tagging each `sel` from a selected-time set keyed by "%.6f". Used by selected
-- scope so base.orig carries the ORIGINAL selection (the points the user picked), independent of whatever
-- is selected on the lane right now (a prior reduce leaves only the survivors selected).
local function tagSelected(region, selSet)
  local out = {}
  for _, p in ipairs(region) do
    out[#out + 1] = { time = p.time, value = p.value, shape = p.shape, tension = p.tension,
      sel = selSet[string.format("%.6f", p.time)] or false }
  end
  return out
end

-- Do point lists `cur` and `ref` match? Both are reads of REAPER's stored points, so an exact-ish compare
-- on EVERY stored field (time, value, shape, tension) distinguishes our own untouched output from any
-- external edit — including a shape/tension-only edit (which earlier slipped through and let Reset revert it).
local function pointsMatch(cur, ref)
  if not ref or #cur ~= #ref then return false end
  for i = 1, #cur do
    local a, b = cur[i], ref[i]
    if math.abs(a.time - b.time) > 1e-6 or math.abs(a.value - b.value) > 1e-9 then return false end
    if (a.shape or 1) ~= (b.shape or 1) then return false end
    if math.abs((a.tension or 0) - (b.tension or 0)) > 1e-6 then return false end
  end
  return true
end

-- Resolve the pristine whole-lane original for `key`, given the working span [a,b] and the current lane
-- read `all`. PRESERVE the stored original (bumping its LRU slot) when the lane region [a,b] still holds
-- our last reduce output — this is scope-INDEPENDENT, so it survives op-switch, span/scope changes, AND a
-- Time->Selected scope switch. Otherwise capture `all` as the new original. Returns (whole, storedEntry).
local function resolveWhole(key, all, a, b)
  local e = store[key]
  if e and e.whole and e.written and pointsMatch(regionOf(all, a, b), regionOf(e.written, a, b)) then
    bumpLRU(key)
    return e.whole, e
  end
  e = { whole = all, written = nil }
  setStore(key, e)
  return all, e
end

-- Per-target key — lane identity only (span deliberately excluded; the whole-lane original in `store`
-- covers any span, so changing the time selection / scope no longer loses the original).
local function targetKey(detected)
  local d = detected.details or {}
  if detected.target == "cc" then
    local lane = (d.midiEditor and reaper.MIDIEditor_GetSetting_int
      and reaper.MIDIEditor_GetSetting_int(d.midiEditor, "last_clicked_cc_lane")) or -1
    return "cc:" .. tostring(d.take) .. ":" .. tostring(lane)
  elseif detected.target == "ai" then
    return "ai:" .. tostring(d.env) .. ":" .. tostring(d.aiIndex)
  end
  return "env:" .. tostring(d.env)
end

-- Record (read back) the WHOLE lane after a committed write, so a later interaction recognises our own
-- output and keeps the stored original. Called after every committed reduce write (gesture end / M.run).
local function recordWritten()
  if base.tgt and base.key and store[base.key] then store[base.key].written = base.tgt:read(nil, nil) end
end

-- Ensure `base` holds the pristine points to reduce. `gestureOpen` lets a drag keep the latched working set
-- without re-reading. Returns true or (false, errString).
local function ensureBaseline(detected, g, gestureOpen)
  local tgt, tErr = target.fromContext(detected)
  if not tgt then return false, tErr or "No target" end
  local key = targetKey(detected)

  -- SELECTED scope. The trap: reducing leaves only the SURVIVORS selected, so re-reading the live
  -- selection after a reduce would mistake the survivors for "the selection" and bring the thinned-away
  -- points back / collapse the selection. Instead we LATCH the original selection (span + selected times)
  -- in the store and keep re-deriving from it for as long as the lane still holds our own output — so
  -- Reset / Curve-fit / amount changes re-reduce the ORIGINAL selection, exactly like Time-selection scope.
  if g.scope == SCOPE_SELECTED then
    if gestureOpen and base.selectedMode and base.orig and base.tgt and base.key == key then return true end
    local snap, sErr = tgt:snapshot()
    if not snap then return false, sErr or "Snapshot failed" end
    local all = tgt:read(nil, nil)
    local cur = {}
    for _, p in ipairs(all) do if p.sel then cur[#cur + 1] = p.time end end

    local e = store[key]
    -- Is the lane (over the STORED selection span) still our own last reduce output? Then the live
    -- selection only shrank to survivors because WE reduced it — reuse the latched original selection.
    local ours = e and e.whole and e.written and e.selTimes and e.selSpan
      and pointsMatch(regionOf(all, e.selSpan[1], e.selSpan[2]), regionOf(e.written, e.selSpan[1], e.selSpan[2]))
    -- A genuinely NEW selection (a point picked outside the latched set, beyond a tick of tolerance)
    -- re-baselines so the user can reduce a different selection.
    local newSel = false
    if ours and #cur > 0 then
      for _, t in ipairs(cur) do
        local hit = false
        for st in pairs(e.selTimes) do if math.abs(t - tonumber(st)) <= 1e-3 then hit = true; break end end
        if not hit then newSel = true; break end
      end
    end

    if ours and not newSel then
      bumpLRU(key)
      base.t0, base.t1 = e.selSpan[1], e.selSpan[2]
      base.orig = tagSelected(regionOf(e.whole, base.t0, base.t1), e.selTimes)
    else
      if #cur == 0 then return false, "Select some points first" end
      local selTimes, tmin, tmax = {}, nil, nil
      for _, t in ipairs(cur) do
        selTimes[string.format("%.6f", t)] = true
        if not tmin or t < tmin then tmin = t end
        if not tmax or t > tmax then tmax = t end
      end
      -- Preserve the pristine original if the lane over this span is still our last output (covers a
      -- Time->Selected scope switch on an already-reduced lane); else capture the current lane. Then latch
      -- the new selection onto it.
      local whole, prev = resolveWhole(key, all, tmin, tmax)
      base.t0, base.t1 = tmin, tmax
      base.orig = tagSelected(regionOf(whole, tmin, tmax), selTimes)
      setStore(key, { whole = whole, written = prev and prev.written or nil, selSpan = { tmin, tmax }, selTimes = selTimes })
    end
    base.key, base.tgt, base.snapshot, base.selectedMode = key, tgt, snap, true
    base.origCount = #base.orig
    return true
  end

  -- RANGE scopes (Time selection / Entire item).
  local st0, st1 = common.spanFor(tgt, detected, g)
  if not (st0 and st1 and st1 > st0) then return false, "Empty range" end
  if gestureOpen and not base.selectedMode and base.orig and base.key == key then return true end

  local snap, sErr = tgt:snapshot()
  if not snap then return false, sErr or "Snapshot failed" end

  -- Reuse the stored pristine original if the working region still holds our last reduce output (preserved
  -- scope-independently by resolveWhole); otherwise capture the current lane as the new original.
  local whole = resolveWhole(key, tgt:read(nil, nil), st0, st1)
  base.key, base.tgt, base.snapshot = key, tgt, snap
  base.t0, base.t1, base.selectedMode = st0, st1, false
  base.orig = regionOf(whole, st0, st1)   -- the original points within the working span
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
  local vr = { vmin = vmin, vmax = vmax }
  local function thin(p)
    if g.curveFit then
      return reduce.thinCurve(p, eps, vr, { envConvention = base.tgt:kind() ~= "cc" })
    end
    return reduce.thin(p, eps, vr)
  end
  if not base.selectedMode then
    return thin(pts)
  end
  local sel, unsel = {}, {}
  for _, p in ipairs(pts) do if p.sel then sel[#sel + 1] = p else unsel[#unsel + 1] = p end end
  local keptSel = thin(sel)
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
  recordWritten()   -- remember our output so a later Reset/op-switch return keeps the true original
end

-- Called from contour.lua atexit / window-close and on op switch. Closes a dangling block AND clears
-- the baseline so returning to Reduce (e.g. after Generate edited the same lane) re-reads fresh.
function M.cleanup()
  if gesture.open then
    markCCDirty(base.tgt)
    reaper.Undo_EndBlock2(0, gesture.undoLabel, gesture.undoFlag)
    gesture.open = false
    recordWritten()
  end
  -- Keep the baseline across op-switch / window-close: returning to Reduce re-validates it against the
  -- lane (ensureBaseline), so Reset still restores the true pre-reduce original unless the lane was edited
  -- externally. (Previously this hard-invalidated, which made Reset restore the already-reduced data.)
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
  local isTrackEnv = (t == "envelope") and not (detected.details and detected.details.take)
  local needTimeSel = (g.scope == SCOPE_TIMESEL) or isTrackEnv
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
    local choices = scopeChoices(t, detected and detected.details and detected.details.take ~= nil)
    local cur, items = 0, ""
    for i, c in ipairs(choices) do
      items = items .. c.label .. "\0"
      if c.v == g.scope then cur = i - 1 end
    end
    if choices[cur + 1].v ~= g.scope then g.scope = choices[cur + 1].v end  -- snap if prev scope invalid here
    local changed, idx = reaper.ImGui_Combo(ctx, "Scope##red_scope", cur, items, #items)
    if changed and choices[idx + 1] and choices[idx + 1].v ~= g.scope then g.scope = choices[idx + 1].v; acc(true) end
  end

  -- Curve fit: thin using curved segments (REAPER per-point shapes) instead of straight lines, so a
  -- curve keeps its shape with far fewer points. Off = exact straight-line reduction.
  do
    local rv, v = reaper.ImGui_Checkbox(ctx, "Curve fit##red_curve", g.curveFit)
    if rv then g.curveFit = v; acc(true) end
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
  recordWritten()   -- remember our output so a later Reset keeps the true original
  ok(("Reduced %d -> %d points"):format(base.origCount, #reduced))
end

return M
