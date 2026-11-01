-- ui/reduce.lua — Reduce panel: thin existing automation/CC points with vertical-distance RDP
-- (core/reduce). NON-DESTRUCTIVE: a baseline of the pristine points is captured and every reduction
-- re-derives from it, so 0%/Reset restores the original and dialing up never compounds.
--
-- Three scopes:
--   * Time selection  — thin all points inside the time selection, or inside each razor area on the
--                       target lane (a lane can carry several separate areas: each is thinned on its own,
--                       the gaps between them are never touched, and the write is ONE Undo step).
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
local theme  = require("ui.theme")

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
-- do have one — their item — so they get the full list like CC/AI). The range option is named after the
-- lane's range (common.rangeLabel): "Time selection", or "Razor area(s)" when the lane has razor areas.
local function scopeChoices(detected)
  local t = detected and detected.target
  local isTake = detected and detected.details and detected.details.take ~= nil
  local range = { label = common.rangeLabel(detected), v = SCOPE_TIMESEL }
  if t == "envelope" and not isTake then
    return { range, { label = "Selected points", v = SCOPE_SELECTED } }
  end
  return { range,
           { label = "Entire item", v = SCOPE_ENTIRE },
           { label = "Selected points", v = SCOPE_SELECTED } }
end

-- Target-aware undo metadata: CC edits are items (flag 4); envelope/AI point edits use ALL (-1).
local function undoMetaFor(t)
  if t == "cc" then return 4, "Contour: Reduce CC" end
  if t == "ai" then return -1, "Contour: Reduce automation item" end
  return -1, "Contour: Reduce envelope"
end

-- The active working set for the current interaction: base.regions = one entry per working span,
--   { t0, t1, orig, origCount }, where orig is the PRE-REDUCE original points within [t0,t1] (a slice of
-- the whole-lane original). reducedAt thins each region on its own; Reset (0%) writes it back verbatim.
-- The range scopes get one region per span (several razor areas = several regions); Selected points is
-- always one region. base.origCount is the sum over the regions. tgt/snapshot are volatile and refreshed on
-- every fresh interaction.
local base = { key = nil, tgt = nil, snapshot = nil, regions = nil, origCount = 0, selectedMode = false }
local function newRegion(t0, t1, orig) return { t0 = t0, t1 = t1, orig = orig, origCount = #orig } end
local function setRegions(list)
  base.regions, base.origCount = list, 0
  for _, r in ipairs(list) do base.origCount = base.origCount + r.origCount end
end
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
-- scope so a region's orig carries the ORIGINAL selection (the points the user picked), independent of whatever
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

-- Resolve the pristine whole-lane original for `key`, given the working spans `spans` ({ {a,b}, ... }) and
-- the current lane read `all`. PRESERVE the stored original (bumping its LRU slot) when EVERY span still
-- holds our last reduce output — this is scope-INDEPENDENT, so it survives op-switch, span/scope changes,
-- AND a Time->Selected scope switch. One span edited from outside is enough to re-baseline, because the
-- stored original would otherwise overwrite that edit. Otherwise capture `all` as the new original.
-- Returns (whole, storedEntry).
local function resolveWhole(key, all, spans)
  local e = store[key]
  if e and e.whole and e.written then
    local ours = true
    for _, s in ipairs(spans) do
      if not pointsMatch(regionOf(all, s[1], s[2]), regionOf(e.written, s[1], s[2])) then ours = false; break end
    end
    if ours then
      bumpLRU(key)
      return e.whole, e
    end
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
    if gestureOpen and base.selectedMode and base.regions and base.tgt and base.key == key then return true end
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
      local t0, t1 = e.selSpan[1], e.selSpan[2]
      setRegions({ newRegion(t0, t1, tagSelected(regionOf(e.whole, t0, t1), e.selTimes)) })
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
      local whole, prev = resolveWhole(key, all, { { tmin, tmax } })
      setRegions({ newRegion(tmin, tmax, tagSelected(regionOf(whole, tmin, tmax), selTimes)) })
      setStore(key, { whole = whole, written = prev and prev.written or nil, selSpan = { tmin, tmax }, selTimes = selTimes })
    end
    base.key, base.tgt, base.snapshot, base.selectedMode = key, tgt, snap, true
    return true
  end

  -- RANGE scopes (Time selection / Entire item). A live drag keeps the latched regions (the span list is
  -- frozen when the gesture opens, so a razor change in the middle of a drag cannot move the write).
  if gestureOpen and not base.selectedMode and base.regions and base.key == key then return true end

  -- One span per razor area (or the single time-selection / entire-item span); an empty one holds nothing.
  local spans = {}
  for _, s in ipairs(common.spansFor(tgt, detected, g)) do
    if s[1] and s[2] and s[2] > s[1] then spans[#spans + 1] = s end
  end
  if #spans == 0 then return false, "Empty range" end

  local snap, sErr = tgt:snapshot()
  if not snap then return false, sErr or "Snapshot failed" end

  -- Reuse the stored pristine original if every working region still holds our last reduce output (preserved
  -- scope-independently by resolveWhole); otherwise capture the current lane as the new original.
  local whole = resolveWhole(key, tgt:read(nil, nil), spans)
  local regions = {}
  for i, s in ipairs(spans) do
    regions[i] = newRegion(s[1], s[2], regionOf(whole, s[1], s[2]))   -- the original points within that span
  end
  setRegions(regions)
  base.key, base.tgt, base.snapshot, base.selectedMode = key, tgt, snap, false
  return true
end

-- The points to write at the current amount, one job per region that holds points: { t0, t1, pts }. Each
-- region is thinned on its own (a razor area never sees the points of another), and a region with no points
-- has nothing to write. 0% restores the exact baseline. In selected scope only the selected points are
-- thinned; the unselected ones are kept verbatim and merged back.
local function reducedAt(g)
  local thin
  if (g.amount or 0) > 0 then
    local vmin, vmax = base.tgt:valueRange()
    local eps = amountFor(g.amount)
    local vr = { vmin = vmin, vmax = vmax }
    thin = function(p)
      if g.curveFit then
        return reduce.thinCurve(p, eps, vr, { envConvention = base.tgt:kind() ~= "cc" })
      end
      return reduce.thin(p, eps, vr)
    end
  end
  local jobs = {}
  for _, r in ipairs(base.regions) do
    if r.origCount > 0 then
      local out
      if not thin then
        out = r.orig
      elseif not base.selectedMode then
        out = thin(r.orig)
      else
        local sel, unsel = {}, {}
        for _, p in ipairs(r.orig) do if p.sel then sel[#sel + 1] = p else unsel[#unsel + 1] = p end end
        local keptSel = thin(sel)
        out = {}
        for _, p in ipairs(unsel) do out[#out + 1] = p end
        for _, p in ipairs(keptSel) do out[#out + 1] = p end
        table.sort(out, function(a, b) return a.time < b.time end)
      end
      jobs[#jobs + 1] = { t0 = r.t0, t1 = r.t1, pts = out }
    end
  end
  return jobs
end

-- Write every job over its own [t0,t1] (each write deletes and rewrites only that range, so writing the
-- regions one after the other never compounds and never touches the gaps). The caller owns the Undo block,
-- so every write is noUndo. `bulk` takes the live path (cached snapshot). Returns the number of points
-- written over all regions, or (nil, errString) at the first failing region.
local function writeJobs(jobs, bulk)
  local total = 0
  for _, j in ipairs(jobs) do
    local opts = { noUndo = true, rawShape = true }
    local n, e
    if bulk then n, e = base.tgt:writeBulk(base.snapshot, j.pts, j.t0, j.t1, opts)
    else         n, e = base.tgt:write(j.pts, j.t0, j.t1, opts) end
    if not n then return nil, e end
    total = total + #j.pts
  end
  return total
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

-- Does this scope need a range (razor areas or the time selection)? Time selection always does, and a TRACK
-- envelope always does (it has no item, so no Entire item); Selected points never does.
local function needsRange(detected, g)
  if g.scope == SCOPE_SELECTED then return false end
  if g.scope == SCOPE_TIMESEL then return true end
  return detected ~= nil and detected.target == "envelope" and not (detected.details and detected.details.take)
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
  if needsRange(detected, g) and not common.hasRange(detected) then return false end   -- razor area(s) or time selection
  if t == "cc" then return detected.details.take ~= nil
  elseif t == "envelope" then return detected.details.env ~= nil
  else return detected.details.env ~= nil and detected.details.aiIndex ~= nil end
end

function M.draw(ctx, state, detected)
  local g = ui(state)

  if gesture.open and state.op ~= "reduce" then endGesture(true) end
  -- REAPER selected another envelope / item / CC lane in the middle of a drag: the open gesture belongs to
  -- the lane it started on. End it NOW, while base still points at that lane (endGesture records the lane's
  -- output), before ensureBaseline re-reads a baseline for the new one.
  if gesture.open and detected and detected.details and base.key ~= targetKey(detected) then endGesture(true) end

  do
    local rv, v = reaper.ImGui_Checkbox(ctx, "Live##red_live", g.live)
    if rv then g.live = v; if not g.live then endGesture(true) end end
  end
  reaper.ImGui_SameLine(ctx)
  reaper.ImGui_TextColored(ctx, theme.C.hint, g.live and "on (auto-apply)" or "off (click Reduce)")
  reaper.ImGui_Separator(ctx)

  local editedThisFrame = false
  local function acc(c) if c then editedThisFrame = true end end

  -- Scope selector (target-appropriate options; maps the combo index to a scope constant).
  local t = detected and detected.target
  do
    local choices = scopeChoices(detected)
    local cur, items = 0, ""
    for i, c in ipairs(choices) do
      items = items .. c.label .. "\0"
      if c.v == g.scope then cur = i - 1 end
    end
    if choices[cur + 1].v ~= g.scope then g.scope = choices[cur + 1].v end  -- snap if prev scope invalid here
    reaper.ImGui_SetNextItemWidth(ctx, common.SCOPE_W)
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
    acc(changed); acc(common.tickReset(ctx, g, "amount", 0, 100, 0, g.amount .. "%"))
  end

  reaper.ImGui_Separator(ctx)
  if reaper.ImGui_Button(ctx, "Reset##red_reset") then g.amount = 0; acc(true) end  -- restores original (0%)
  reaper.ImGui_Separator(ctx)

  -- Status hints.
  if t ~= "cc" and t ~= "envelope" and t ~= "ai" then
    reaper.ImGui_TextColored(ctx, theme.C.hint, "Select a MIDI CC lane, a track envelope, or an automation item.")
  elseif g.scope == SCOPE_SELECTED then
    reaper.ImGui_TextColored(ctx, theme.C.hint, "Select points in the editor, then raise Reduction.")
  elseif needsRange(detected, g) and detected.razorOutside then
    -- The razor area on this lane lies outside the item: no range, and never a fallback to the time selection.
    reaper.ImGui_TextColored(ctx, theme.C.hint, common.razorOutsideText(detected))
  elseif needsRange(detected, g) and not common.hasRange(detected) then
    -- The other scope that needs no range: a track envelope has no Entire item, so it offers Selected points.
    local isTrackEnv = t == "envelope" and not (detected.details and detected.details.take)
    reaper.ImGui_TextColored(ctx, theme.C.hint, common.rangeHint(detected, isTrackEnv and "Selected points" or "Entire item"))
  elseif g.amount == 0 then
    reaper.ImGui_TextColored(ctx, theme.C.hint, "Raise Reduction to thin points")
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
        -- Every region is written inside the gesture's ONE Undo block (writeJobs passes noUndo).
        local ok, total, err = pcall(function() return writeJobs(reducedAt(g), true) end)
        if not ok then
          g.status = "Reduce error: " .. tostring(total); g.statusErr = true
          endGesture(true)
        elseif not total then
          g.status = err or "Reduce write failed"; g.statusErr = true
          endGesture(true)
        else
          g.status = ("%d -> %d points"):format(base.origCount, total); g.statusErr = false
        end
      end
    end

    if gesture.open and not anyActive then endGesture(true) end
  else
    if reaper.ImGui_BeginDisabled then
      reaper.ImGui_BeginDisabled(ctx, not ready)
      if theme.accentButton(ctx, "Reduce##red_run") then M.run(state, detected, g) end
      reaper.ImGui_EndDisabled(ctx)
    elseif ready then
      if theme.accentButton(ctx, "Reduce##red_run") then M.run(state, detected, g) end
    end
  end

  if g.status ~= "" then
    reaper.ImGui_TextColored(ctx, g.statusErr and theme.C.err or theme.C.ok, g.status)
  end
end

-- Non-live commit (Reduce button). Self-contained single undo. Sets g.status; never throws.
function M.run(state, detected, g)
  local function fail(m) g.status = m; g.statusErr = true end
  local function ok(m)   g.status = m; g.statusErr = false end

  if not readyFor(detected, g) then
    if detected and detected.razorOutside then fail(common.razorOutsideText(detected)) return end
    local t = detected and detected.target
    if (t == "cc" or t == "envelope" or t == "ai") and needsRange(detected, g) and not common.hasRange(detected) then
      fail("Make " .. common.rangeWhat(detected)) return
    end
    fail("Select a CC lane / envelope / automation item (and a time selection or a razor area)") return
  end
  local okB, bErr = ensureBaseline(detected, g, false)
  if not okB then fail(bErr or "No target") return end
  if base.origCount == 0 then fail("No points to reduce") return end
  local jobs = reducedAt(g)
  local flag, label = undoMetaFor(detected.target)

  local total = 0
  if #jobs == 1 then
    -- ONE region: the write layer opens its own Undo block, exactly as it always did.
    local job = jobs[1]
    local n, wErr = base.tgt:write(job.pts, job.t0, job.t1, { rawShape = true, undoLabel = label })
    if not n then fail(wErr or "Write failed") return end
    recordWritten()   -- remember our output so a later Reset keeps the true original
    total = #job.pts
  else
    -- SEVERAL regions (razor areas), ONE Undo step. The block is closed even if a write throws, and a
    -- failure part-way still closes it with the label (and records what the lane now holds), so the
    -- regions already written can be undone and Reset still finds the true original.
    reaper.Undo_BeginBlock2(0)
    local okW, res, wErr = pcall(writeJobs, jobs, false)
    markCCDirty(base.tgt)
    reaper.Undo_EndBlock2(0, label, flag)
    recordWritten()
    if not okW then fail("Write error: " .. tostring(res)) return end
    if not res then fail(wErr or "Write failed") return end
    total = res
  end
  ok(("Reduced %d -> %d points"):format(base.origCount, total))
end

return M
