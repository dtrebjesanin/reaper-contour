-- ui/overlay.lua — Transform mouse-overlay engine (Reaper-bound). A transparent, input-capturing ReaImGui
-- window floats over the arrange (track envelopes / automation items) or the MIDI editor (CC); it draws the
-- selection box + handles and performs LIVE drag transforms (Stretch / Tilt / Scale / Compress / Warp) plus
-- the Reverse / Flip / Reset one-shots, committing one undo point per gesture.
local M = {}
local target = require("core.target")
local ac     = require("core.arrangecoords")
local tr     = require("core.transform")
-- Shaping params live HERE (the overlay is its own script instance — no cross-process sync needed). The
-- HUD edits them; the drag branches read them via g.knob/g.shape/g.symmetrical each frame.
M.params = { knob = 0, shape = "power", symmetrical = false, flipMode = "absolute" }

local ACCENT   = 0x2E8B9BFF
local ACCENT_H = 0x53C9D6FF
local BOXCOL   = 0x2E8B9BCC

-- Per-operation colour code for the handles (base, brightened-when-grabbed). The arrow shape shows the drag
-- axis; the colour shows the operation (and tells Tilt from Scale, which share a vertical arrow).
local OPCOL = {
  stretch = { 0x53C9D6FF, 0xC9F4FAFF },  -- cyan   · time, horizontal
  scale   = { 0xE3B153FF, 0xF6DDA0FF },  -- amber  · value, vertical
  tilt    = { 0x6FD79AFF, 0xCDEFDBFF },  -- green  · lift an end, vertical
  warp    = { 0xC78BF0FF, 0xE7CCFAFF },  -- violet · 2D
}

-- Handle arrow glyphs drawn on the DrawList. Values dialled in via the icon lab.
local AT, L, A, HL, BOW, ROT = 1.05, 7.9, 2.1, 3.7, 3.7, 45  -- thickness, half-len, head half-w, head len, tilt bow, hug°
local SH = L - HL*0.5  -- shaft half-length: overlaps ~halfway into each head so the join shows no AA gap in REAPER
local function head(dl, tx, ty, dx, dy, col)  -- filled triangle: tip (tx,ty) pointing unit (dx,dy)
  local bx, by, px, py = tx - dx*HL, ty - dy*HL, -dy, dx
  reaper.ImGui_DrawList_AddTriangleFilled(dl, tx, ty, bx + px*A, by + py*A, bx - px*A, by - py*A, col)
end
-- NB: shafts are FILLED RECTS, not AddLine. ImGui's AddLine nudges lines by +0.5px to pixel-centre them,
-- but AddTriangleFilled isn't nudged — so a line shaft sits ~0.5px off the heads. A filled rect rasterises
-- exactly like the heads, so the shaft stays centred on them.
local function arrowH(dl, cx, cy, col)  -- horizontal double arrow (Stretch); shaft overlaps the heads
  reaper.ImGui_DrawList_AddRectFilled(dl, cx-SH, cy-AT*0.5, cx+SH, cy+AT*0.5, col)
  head(dl, cx-L, cy, -1, 0, col); head(dl, cx+L, cy, 1, 0, col)
end
local function arrowV(dl, cx, cy, col)  -- vertical double arrow (Scale); shaft overlaps the heads
  reaper.ImGui_DrawList_AddRectFilled(dl, cx-AT*0.5, cy-SH, cx+AT*0.5, cy+SH, col)
  head(dl, cx, cy-L, 0, -1, col); head(dl, cx, cy+L, 0, 1, col)
end
local function arrow4(dl, cx, cy, col)  -- Warp: four diagonal chevrons + a centre dot
  local d = 0.70710678
  head(dl, cx-L*d, cy-L*d, -d, -d, col); head(dl, cx+L*d, cy-L*d, d, -d, col)
  head(dl, cx-L*d, cy+L*d, -d,  d, col); head(dl, cx+L*d, cy+L*d, d,  d, col)
  reaper.ImGui_DrawList_AddCircleFilled(dl, cx, cy, 1.68, col)
end
local function arrowCurved(dl, cx, cy, col, m)  -- curved double arrow (Tilt): tangent heads, rotated to hug the corner
  m = m or 1
  local bt, th = L - HL, m * ROT * math.pi/180
  local cs, sn = math.cos(th), math.sin(th)
  local function rot(lx, ly) return lx*cs - ly*sn, lx*sn + ly*cs end  -- rotate a local vector by th
  local ctrlx = -BOW*m
  local b0x, b0y = rot(0, -bt); b0x, b0y = cx+b0x, cy+b0y           -- top base (rotated, translated)
  local b1x, b1y = rot(0,  bt); b1x, b1y = cx+b1x, cy+b1y           -- bottom base
  local ccx, ccy = rot(ctrlx, 0); ccx, ccy = cx+ccx, cy+ccy        -- control
  reaper.ImGui_DrawList_AddBezierQuadratic(dl, b0x, b0y, ccx, ccy, b1x, b1y, col, AT, 0)
  local d0x, d0y = rot(-ctrlx, -bt); local n0 = math.sqrt(d0x*d0x+d0y*d0y); d0x, d0y = d0x/n0, d0y/n0
  local d1x, d1y = rot(-ctrlx,  bt); local n1 = math.sqrt(d1x*d1x+d1y*d1y); d1x, d1y = d1x/n1, d1y/n1
  head(dl, b0x + d0x*HL, b0y + d0y*HL, d0x, d0y, col)               -- heads follow the curve tangent
  head(dl, b1x + d1x*HL, b1y + d1y*HL, d1x, d1y, col)
end

local g = nil  -- gesture state table while armed

-- arrange trackview client rect (screen coords) + width.
local function trackviewRect()
  local main = reaper.GetMainHwnd()
  local tv = reaper.JS_Window_FindChildByID(main, 0x3E8)  -- 1000 = arrange trackview
  if not tv then return nil end
  local ok, l, t, r, b = reaper.JS_Window_GetClientRect(tv)
  if not ok then return nil end
  return { l = l, t = t, r = r, b = b, w = r - l, h = b - t }
end

-- envelope lane screen rect (yTop/yBot) for a TRACK envelope.
local function laneRect(env)
  local track = reaper.GetEnvelopeInfo_Value(env, "P_TRACK")
  if not track then return nil end
  local sy = reaper.GetMediaTrackInfo_Value(track, "I_TCPSCREENY")
  local ly = reaper.GetEnvelopeInfo_Value(env, "I_TCPY_USED")
  local lh = reaper.GetEnvelopeInfo_Value(env, "I_TCPH_USED")
  if not lh or lh <= 0 then return nil end
  return { yTop = sy + ly, yBot = sy + ly + lh }
end

-- MIDI CC coordinate setup (juliansader's CFGEDITVIEW/VELLANE approach, decoded from a live editor):
--   CFGEDITVIEW field 1 = leftmost tick at the midiview's left edge; field 2 = pixels per tick.
--   VELLANE <lane> <height> = the active CC lane's pixel height.
-- Read ONCE at launch (the overlay then locks the view by capturing input); the midiview RECT is re-read
-- live each frame in M.frame, so moving/resizing the editor still tracks. midiview = child id 1001 (0x3E9).
local function ccSetup(detected, lane)
  local me   = detected.details and detected.details.midiEditor
  local take = detected.details and detected.details.take
  if not (me and take) then return nil, "no editor/take" end
  if not reaper.JS_Window_FindChildByID then return nil, "js_ReaScriptAPI missing" end
  local mv = reaper.JS_Window_FindChildByID(me, 0x3E9)  -- 1001 = midiview
  if not mv then return nil, "midiview not found (0x3E9)" end
  local item = reaper.GetMediaItemTake_Item(take)
  if not item then return nil, "no media item" end
  local okc, chunk = reaper.GetItemStateChunk(item, "", false)  -- NB: keep on its own line — `item and f()` truncates f's 2 returns to 1
  if not (okc and chunk) then return nil, "no item chunk" end
  -- Single visible CC lane only for now: with stacked lanes the active lane is not bottom-anchored, so the
  -- value<->Y mapping (which assumes laneBottom = midiview bottom) would be miscalibrated. Refuse cleanly
  -- rather than silently mis-edit. (Proper multi-lane stacking is a known TODO.)
  local laneCount = 0
  for _ in chunk:gmatch("VELLANE%s+%-?%d+%s+%d+") do laneCount = laneCount + 1 end
  if laneCount > 1 then return nil, "show only ONE CC lane (hide the others), then relaunch" end
  local leftTick, pxPerTick = chunk:match("CFGEDITVIEW%s+(%-?[%d%.]+)%s+(%-?[%d%.]+)")
  if not (leftTick and pxPerTick) then return nil, "no CFGEDITVIEW" end
  -- Active lane height from its VELLANE line; fall back to the FIRST VELLANE (the only lane, single-lane case).
  local laneHeight = chunk:match("VELLANE%s+" .. tostring(lane) .. "%s+(%d+)")
                     or chunk:match("VELLANE%s+%-?%d+%s+(%d+)")
  if not laneHeight then return nil, "no VELLANE" end
  leftTick, pxPerTick, laneHeight = tonumber(leftTick), tonumber(pxPerTick), tonumber(laneHeight)
  if not (pxPerTick and pxPerTick ~= 0 and laneHeight and laneHeight > 0) then return nil, "bad view numbers" end
  return { midiview = mv, leftTick = leftTick, pxPerTick = pxPerTick, laneHeight = laneHeight }
end

-- Read in-scope points (raw STORAGE values), tagged with their envelope index, for the explicit scope:
-- "points" = the selected points (error if none); "timesel" = points inside the time selection (error if
-- none). Returns region[], t0, t1, all[]  — or nil, message.
local function readScope(detected, scope)
  local sel, all = {}, {}
  if detected.target == "cc" then
    -- CC: read the active lane's events via the target (project seconds, value 0-127, CC shape).
    local tgt = target.fromContext(detected)
    if not tgt then return nil, "No MIDI lane" end
    for _, p in ipairs(tgt:read(nil, nil)) do
      local pt = { t = p.time, v = p.value, shape = p.shape, tension = p.tension, sel = p.sel and true or false }
      all[#all+1] = pt
      if pt.sel then sel[#sel+1] = pt end
    end
  else
    local d = detected.details
    local env = d and d.env
    if not env then return nil, "No envelope" end
    -- An automation item reads via the *Ex point functions with its index; a plain track envelope uses the
    -- non-Ex ones. Both report points in absolute PROJECT seconds on the same lane.
    local ai = d.aiIndex
    local cnt = (ai ~= nil) and reaper.CountEnvelopePointsEx(env, ai) or reaper.CountEnvelopePoints(env)
    for i = 0, (cnt or 0) - 1 do
      local ok, t, v, shape, tension, selected
      if ai ~= nil then ok, t, v, shape, tension, selected = reaper.GetEnvelopePointEx(env, ai, i)
      else              ok, t, v, shape, tension, selected = reaper.GetEnvelopePoint(env, i) end
      if ok then
        local pt = { idx = i, t = t, v = v,   -- raw STORAGE-domain value (lane draws it linearly)
                     shape = shape, tension = tension, sel = selected and true or false }
        all[#all+1] = pt
        if selected then sel[#sel+1] = pt end
      end
    end
  end
  local t0, t1
  if scope == "timesel" then
    if not detected.hasTimeSel then return nil, "No time selection — make one, or use Selected points" end
    t0, t1 = detected.t0, detected.t1
  else
    if #sel == 0 then return nil, "No points selected — select some, or use Time selection" end
    t0, t1 = sel[1].t, sel[1].t
    for _, p in ipairs(sel) do if p.t < t0 then t0 = p.t end; if p.t > t1 then t1 = p.t end end
  end
  local region = {}
  for _, p in ipairs(all) do if p.t >= t0 and p.t <= t1 then region[#region+1] = p end end
  return region, t0, t1, all
end

function M.start(ctx, detected)
  if not detected or not (detected.target == "envelope" or detected.target == "ai" or detected.target == "cc") then
    return false, "Select a track envelope, automation item, or a MIDI CC lane"
  end
  -- Scope: a SATISFIABLE explicit handoff from the Contour panel wins; otherwise PRECEDENCE — selected
  -- points, else the time selection. An explicit choice that can't be met (e.g. "points" with nothing
  -- selected) falls back to precedence rather than erroring, so a direct run with only a time selection just
  -- works and a stale/leftover handoff can never strand the tool. Consume the handoff so it's a true
  -- one-shot. Only error when NEITHER selected points nor a time selection exist.
  local handoff = reaper.GetExtState("Contour", "tr_scope")
  reaper.DeleteExtState("Contour", "tr_scope", false)
  local pts, pt0, pt1, ptAll = readScope(detected, "points")  -- non-nil region iff points are selected
  local scope
  if handoff == "timesel" and detected.hasTimeSel then scope = "timesel"
  elseif handoff == "points" and pts then scope = "points"
  elseif pts then scope = "points"
  elseif detected.hasTimeSel then scope = "timesel"
  else return false, "Select some points, or make a time selection, then launch Transform" end
  local region, t0, t1, all
  if scope == "points" then region, t0, t1, all = pts, pt0, pt1, ptAll
  else region, t0, t1, all = readScope(detected, "timesel") end
  if not region then return false, t0 or "Nothing to transform" end
  if #region == 0 then return false, "No points in the region" end
  local tgt = target.fromContext(detected)
  if not tgt then return false, "No target" end
  -- MIDI CC: read the editor view (tick<->x + lane height) once, now, while the lane is the active one.
  local cc
  if detected.target == "cc" then
    local ccErr
    cc, ccErr = ccSetup(detected, tgt:lane())
    if not cc then return false, "MIDI view read failed: " .. tostring(ccErr) end
  end
  -- Lane value range in the STORAGE domain GetEnvelopePoint returns (volume etc. are fader-scaled; the
  -- lane draws that domain linearly). ENV:valueRange already converts to storage via ScaleToEnvelopeMode,
  -- so it matches the raw point values directly — same domain Reduce/Generate use. No ScaleFrom/To.
  local vlo, vhi = tgt:valueRange()
  if vhi < vlo then vlo, vhi = vhi, vlo end
  -- Points OUTSIDE the transformed region — re-written unchanged each frame so they're preserved when a
  -- stretch's widened delete-range sweeps over them.
  local keep = {}
  for _, p in ipairs(all or {}) do if p.t < t0 or p.t > t1 then keep[#keep + 1] = p end end
  -- Deep copy a point list so the pristine "first state" can never be mutated by later edits.
  local function dcopy(arr)
    local out = {}
    for i = 1, #arr do local p = arr[i]
      out[i] = { idx = p.idx, t = p.t, v = p.v, shape = p.shape, tension = p.tension, sel = p.sel } end
    return out
  end
  g = { detected = detected, scope = scope, tgt = tgt, env = detected.details.env,
        orig = region, keep = keep, t0 = t0, t1 = t1, vlo = vlo, vhi = vhi,
        snap = tgt:snapshot(), zone = nil,
        -- CC coordinate frame (env/AI leave these nil and use the arrange-lane path):
        isCC = (detected.target == "cc"), take = detected.details.take,
        midiview = cc and cc.midiview, ccLeftTick = cc and cc.leftTick,
        ccPxPerTick = cc and cc.pxPerTick, ccLaneHeight = cc and cc.laneHeight,
        ccTopInset = 11, ccBottomInset = 1.5,  -- CC lane top-header / bottom-border px padding (values 127/0 sit inside the lane)
        -- Undo: CC needs UNDO_STATE_ITEMS(4) + a MarkTrackItemsDirty per edit (point changes aren't captured
        -- by flag -1 alone); env/AI use UNDO_STATE_ALL(-1). Mirrors ui/generate.lua's live-gesture undo.
        undoFlag = (detected.target == "cc") and 4 or -1,
        undoLabel = (detected.target == "cc") and "Contour: Transform MIDI CC"
                    or (detected.target == "ai") and "Contour: Transform automation item"
                    or "Contour: Transform envelope",
        -- Reset restores these: the region + outside points as captured at launch, plus the widest time
        -- extent ever written this session (so widening stretches/warps leave no stray points behind).
        pristine = dcopy(region), pristineKeep = dcopy(keep), everMin = t0, everMax = t1 }
  g.knob = M.params.knob; g.shape = M.params.shape; g.symmetrical = M.params.symmetrical
  -- Undo is per-DRAG (opened on grab, closed on release), not per session — so each stretch/tilt is its
  -- own clean undo point rather than the whole session collapsing into one coarse undo.
  return true
end

-- screen->canvas helpers using the live view each frame
local function viewNow()
  local tvr = trackviewRect(); if not tvr then return nil end
  -- GetSet_ArrangeView2's screen_x args are OS-SCREEN pixels, so anchor them to the trackview's screen
  -- left/right (NOT 0..width) — otherwise the returned times correspond to the wrong x and the box is
  -- offset by tvr.l. Then timeToX maps with the same (tvr.l, tvr.r). Returns (start_time, end_time).
  local t0, t1 = reaper.GetSet_ArrangeView2(0, false, tvr.l, tvr.r, 0, 0)
  return tvr, t0, t1
end

-- left mouse + position via ImGui. The overlay now CAPTURES input (no NoInputs flag), so it blocks
-- clicks/scroll to the arrange while active, and we read the mouse from ImGui (same screen space as
-- our draw coordinates, so hit-testing against the handles lines up).
local function mouseNow(ctx)
  local x, y = reaper.ImGui_GetMousePos(ctx)
  return reaper.ImGui_IsMouseDown(ctx, 0), x, y
end

local HR = 10  -- handle hit radius (screen px)
local function hit(mx, my, hx, hy) return math.abs(mx-hx) <= HR and math.abs(my-hy) <= HR end

-- Write the transformed points back, under PreventUIRefresh. FULL RE-WRITE each frame: the transformed
-- region points PLUS the preserved (outside) points = every point. The delete-range spans them all, so
-- stretch can push points beyond the original span without being clamped, pulling a stretch back never
-- leaves stragglers, and the untouched automation outside the selection is re-inserted unchanged.
-- Values stay in the storage domain (rawShape; no ScaleTo) — same as Reduce/Generate.
local function writeTransformed(newPts)
  local cMin, cMax
  for _, p in ipairs(newPts) do
    if not cMin or p.t < cMin then cMin = p.t end
    if not cMax or p.t > cMax then cMax = p.t end
  end
  if not cMin then return end
  -- Grow the gesture's cleared range to the WIDEST extent written so far this drag. Compressing shrinks
  -- the current extent, but earlier frames wrote wider points — deleting only the current extent would
  -- leave that trail. Deleting the grown range clears it. (g.wMin/g.wMax are seeded at the region's
  -- extent when the drag begins.)
  g.wMin = math.min(g.wMin or cMin, cMin)
  g.wMax = math.max(g.wMax or cMax, cMax)
  g.everMin = math.min(g.everMin or cMin, cMin)  -- widest extent across the WHOLE session (for Reset)
  g.everMax = math.max(g.everMax or cMax, cMax)
  local out = {}
  for _, p in ipairs(newPts) do
    out[#out + 1] = { time = p.t, value = p.v, shape = p.shape, tension = p.tension, sel = p.sel }
  end
  -- Re-insert ONLY the preserved points the cleared range will delete (others stay untouched -> no dup).
  for _, p in ipairs(g.keep or {}) do
    if p.t >= g.wMin and p.t <= g.wMax then
      out[#out + 1] = { time = p.t, value = p.v, shape = p.shape, tension = p.tension, sel = p.sel }
    end
  end
  reaper.PreventUIRefresh(1)
  local ok, res = pcall(function() return g.tgt:writeBulk(g.snap, out, g.wMin, g.wMax, { noUndo = true, rawShape = true }) end)
  reaper.PreventUIRefresh(-1)
  -- Surface a failed write (thrown error, or writeBulk returning nil) instead of silently leaving a no-op
  -- undo point with no feedback.
  if not ok or res == nil then g.status = "write failed" end
end

-- CC edits only register in the undo history if the take's item is marked dirty before EndBlock2 (a flag-4
-- UNDO_STATE_ITEMS entry records nothing otherwise). env/AI need neither. Call right before every EndBlock2.
local function markEditDirty()
  if not (g and g.isCC and reaper.MarkTrackItemsDirty and g.take) then return end
  local item = reaper.GetMediaItemTake_Item(g.take)
  if not item then return end
  local track = reaper.GetMediaItem_Track(item)
  if track then reaper.MarkTrackItemsDirty(track, item) end
end

-- CC writeBulk rebuilds the WHOLE take from g.snap (it keeps the snapshot's events OUTSIDE the edited range
-- verbatim). So g.snap must track the CURRENT take, not the launch state — otherwise after a committed edit
-- (e.g. a shrink that removed points) the next write resurrects those removed points outside the box. Call
-- after EVERY committed op (drag release / one-shot / live-undo). env/AI snapshots are inert markers (their
-- writeBulk re-reads the live take), so this is CC-only. Returns false if the snapshot fails.
local function resyncSnap()
  if not g.isCC then return true end
  local snap = g.tgt:snapshot()
  if not snap then return false end
  g.snap = snap
  return true
end

-- Undo/redo WHILE the tool is active: the overlay holds keyboard focus, so REAPER's own Ctrl+Z never
-- fires. Detect the chord here, drive REAPER's undo/redo, then RE-SYNC the baseline from the project so
-- continuing to transform works off the reverted state.
local function recapture()
  local region, t0, t1, all = readScope(g.detected, g.scope)
  if not region or #region == 0 then return false end  -- points/selection gone post-undo -> end the tool
  local keep = {}
  for _, p in ipairs(all or {}) do if p.t < t0 or p.t > t1 then keep[#keep + 1] = p end end
  g.orig, g.keep, g.t0, g.t1 = region, keep, t0, t1
  if not resyncSnap() then return false end  -- CC: refresh off the reverted take
  return true
end

local function chord(ctx, mods, key)
  return reaper.ImGui_IsKeyChordPressed and reaper.ImGui_IsKeyChordPressed(ctx, mods | key)
end

function M.frame(ctx)
  if not g then return false end
  if g then g.knob = M.params.knob; g.shape = M.params.shape; g.symmetrical = M.params.symmetrical end
  if reaper.ImGui_IsKeyPressed and reaper.ImGui_IsKeyPressed(ctx, reaper.ImGui_Key_Escape()) then return false end
  -- Live undo/redo (only when not mid-drag). Check redo (Ctrl+Shift+Z / Ctrl+Y) before undo (Ctrl+Z).
  if not g.zone and reaper.ImGui_Mod_Ctrl and reaper.ImGui_Key_Z then
    local C, S, Z, Y = reaper.ImGui_Mod_Ctrl(), reaper.ImGui_Mod_Shift(), reaper.ImGui_Key_Z(), reaper.ImGui_Key_Y()
    if chord(ctx, C | S, Z) or chord(ctx, C, Y) then
      reaper.Undo_DoRedo2(0); if not recapture() then return false end
    elseif chord(ctx, C, Z) then
      reaper.Undo_DoUndo2(0); if not recapture() then return false end
    end
  end
  -- One-shot transforms from the HUD (Reverse / Flip / Reset): apply once as their own undo point, then
  -- bake into g.orig so subsequent drags chain off the result. Only when not mid-drag.
  if g and not g.zone and M._pendingOneShot then
    local op = M._pendingOneShot; M._pendingOneShot = nil
    local b = M._bounds(g.orig)
    local newPts, clrMin, clrMax
    if op == "reverse" then
      newPts = tr.reverse(g.orig, b.tmin, b.tmax)
    elseif op == "flip" then
      local lo, hi
      if M.params.flipMode == "absolute" then lo, hi = g.vlo, g.vhi else lo, hi = b.vmin, b.vmax end
      newPts = tr.flip(g.orig, lo, hi)
    elseif op == "reset" then
      -- Restore the shape captured at launch (its first state): re-instate the pristine region AND the
      -- original outside points, and clear the widest extent ever written this session so any stray points
      -- left by widening stretches/warps are removed.
      newPts = {}
      for i = 1, #(g.pristine or {}) do local p = g.pristine[i]
        newPts[i] = { idx = p.idx, t = p.t, v = p.v, shape = p.shape, tension = p.tension, sel = p.sel } end
      g.keep = {}
      for i = 1, #(g.pristineKeep or {}) do local p = g.pristineKeep[i]
        g.keep[i] = { idx = p.idx, t = p.t, v = p.v, shape = p.shape, tension = p.tension, sel = p.sel } end
      clrMin = math.min(g.everMin or b.tmin, b.tmin)
      clrMax = math.max(g.everMax or b.tmax, b.tmax)
    end
    if newPts then
      g.wMin = clrMin or b.tmin
      g.wMax = clrMax or b.tmax
      reaper.Undo_BeginBlock2(0)
      writeTransformed(newPts)
      markEditDirty()
      reaper.Undo_EndBlock2(0, "Contour: Transform " .. op, g.undoFlag)
      g.orig = newPts
      resyncSnap()  -- CC: refresh off the just-written take so a later edit can't resurrect removed points
      g.status = (op == "reverse") and "Reversed"
        or (op == "flip") and ("Flipped (" .. (M.params.flipMode or "absolute") .. ")")
        or "Reset to first state"
    end
  end
  -- Target-aware coordinate frame, rebuilt live each frame (so scroll/zoom/resize track). env/AI map via
  -- the arrange view + lane rect; CC maps via the MIDI editor (ppq<->x from the launch-time CFGEDITVIEW;
  -- value<->y from the LIVE midiview rect + lane height, so editor moves/resizes still track).
  local tvr, X, Y, xToT, yToV
  if g.isCC then
    local okr, l, t, r, b = reaper.JS_Window_GetClientRect(g.midiview)
    if not okr then return true end
    tvr = { l = l, t = t, r = r, b = b, w = r - l, h = b - t }
    local valBot = b - g.ccBottomInset                  -- screen Y of CC value 0
    local valTop = b - g.ccLaneHeight + g.ccTopInset    -- screen Y of CC value 127
    local span = valBot - valTop
    if span <= 0 then return true end  -- degenerate (lane too short to map); skip this frame, don't invert
    X    = function(tt) return l + (reaper.MIDI_GetPPQPosFromProjTime(g.take, tt) - g.ccLeftTick) * g.ccPxPerTick end
    xToT = function(x)  return reaper.MIDI_GetProjTimeFromPPQPos(g.take, g.ccLeftTick + (x - l) / g.ccPxPerTick) end
    Y    = function(v)  return (g.vhi == g.vlo) and valBot or (valBot - (v - g.vlo) / (g.vhi - g.vlo) * span) end
    yToV = function(y)  return g.vlo + (valBot - y) / span * (g.vhi - g.vlo) end
  else
    local vt0, vt1
    tvr, vt0, vt1 = viewNow()
    local lr = laneRect(g.env)
    if not tvr or not lr or vt1 <= vt0 then return true end
    X    = function(tt) return ac.timeToX(tt, vt0, vt1, tvr.l, tvr.r) end
    xToT = function(x)  return ac.xToTime(x, vt0, vt1, tvr.l, tvr.r) end
    Y    = function(v)  return ac.valueToY(v, g.vlo, g.vhi, lr.yTop, lr.yBot) end
    yToV = function(y)  return ac.yToValue(y, g.vlo, g.vhi, lr.yTop, lr.yBot) end
  end
  local b = M._bounds(g.orig)
  local x0,x1 = X(b.tmin), X(b.tmax)
  local yt,yb = Y(b.vmax), Y(b.vmin)
  local cy = (yt+yb)/2
  local cx = (x0+x1)/2

  -- HUD panel geometry (drawn later, INSIDE the overlay window). Anchored just off the selection box's
  -- TOP-RIGHT corner — its bottom-left sits a touch up-and-right of that corner, so it rides next to the
  -- shape (above the lane content). Clamped so it never spills past the view edges.
  local HUDW, HUDH = 250, 236
  local hudX = x1 + 14
  if hudX + HUDW > tvr.r - 4 then hudX = tvr.r - 4 - HUDW end
  if hudX < tvr.l + 4 then hudX = tvr.l + 4 end
  local hudY = yt - HUDH - 16
  if hudY < tvr.t + 4 then hudY = tvr.t + 4 end
  g.hudRect = { x = hudX, y = hudY, w = HUDW, h = HUDH }

  local handles = {
    { id="stretchL", x=x0, y=cy, op="stretch", arrow="h" }, { id="stretchR", x=x1, y=cy, op="stretch", arrow="h" },
    { id="tiltL", x=x0, y=yt, op="tilt", arrow="c", dir=1 },  { id="tiltR", x=x1, y=yt, op="tilt", arrow="c", dir=-1 },
    { id="scaleT", x=cx, y=yt, op="scale", arrow="v" },     { id="scaleB", x=cx, y=yb, op="scale", arrow="v" },
    { id="warp",   x=cx, y=cy, op="warp", arrow="4" },
  }

  local down, mx, my = mouseNow(ctx)
  local overHud = g.hudRect and mx >= g.hudRect.x and mx <= g.hudRect.x + g.hudRect.w
                            and my >= g.hudRect.y and my <= g.hudRect.y + g.hudRect.h
  -- A HUD widget being dragged (e.g. the Curve fader) keeps IsAnyItemActive true even if the cursor leaves
  -- the panel — so gate on that too, or dragging a fader off the panel would trip the click-away and end
  -- the tool.
  local hudBusy = overHud or reaper.ImGui_IsAnyItemActive(ctx)
  -- begin drag — skipped while interacting with the HUD, so adjusting it never grabs a handle nor ends the
  -- tool (the HUD widgets live in THIS same window and handle their own clicks).
  if down and not g.zone and not hudBusy then
    for _, hnd in ipairs(handles) do
      if hit(mx, my, hnd.x, hnd.y) then
        g.zone = hnd.id
        g.box = b  -- snapshot box at grab
        g.wMin, g.wMax = b.tmin, b.tmax  -- seed the cleared range at the region's current extent
        g.warpGrabT = xToT(mx)  -- warp anchors: cursor time/value at grab (the warp peak)
        g.warpGrabV = yToV(my)
        reaper.Undo_BeginBlock2(0); g.dragUndo = true  -- one undo point per drag
        break
      end
    end
    -- click outside any handle AND outside the box => commit + end
    if not g.zone and (mx < x0-HR or mx > x1+HR or my < yt-HR or my > yb+HR) then
      return false
    end
  end

  -- during drag: compute params and write
  if g.zone and down then
    if g.zone == "stretchL" or g.zone == "stretchR" then
      local edgeT   = (g.zone == "stretchL") and g.box.tmin or g.box.tmax
      local anchorT
      if g.symmetrical then anchorT = (g.box.tmin + g.box.tmax) / 2
      else anchorT = (g.zone == "stretchL") and g.box.tmax or g.box.tmin end
      local mouseT  = xToT(mx)
      local denom   = (edgeT - anchorT)
      local factor  = (denom ~= 0) and ((mouseT - anchorT) / denom) or 1
      local newPts = tr.stretch(g.orig, anchorT, factor)
      g.pending = newPts
      writeTransformed(newPts)
      g.status = ("Stretch %d%%"):format(math.floor(factor*100+0.5))
    elseif g.zone == "scaleT" or g.zone == "scaleB" then
      local boundaryV = (g.zone == "scaleT") and g.box.vmax or g.box.vmin
      local anchorV
      if g.symmetrical then anchorV = (g.box.vmin + g.box.vmax) / 2
      else anchorV = (g.zone == "scaleT") and g.box.vmin or g.box.vmax end
      local mouseV = yToV(my)
      local newPts = tr.vscale(g.orig, anchorV, boundaryV, mouseV, { knob = g.knob or 0, shape = g.shape or "power" })
      g.pending = newPts
      writeTransformed(newPts)
      local denom  = (boundaryV - anchorV)
      local factor = (denom ~= 0) and ((mouseV - anchorV) / denom) or 1
      g.status = ((g.knob or 0) ~= 0 and "Compress %d%%" or "Scale %d%%"):format(math.floor(factor*100+0.5))
    elseif g.zone == "warp" then
      -- Free 2D warp: the peak (at the grab time) follows the cursor in BOTH time and value at once.
      local mouseT = xToT(mx)
      local mouseV = yToV(my)
      local span = g.box.tmax - g.box.tmin
      local cursorRelT = (span > 0) and ((g.warpGrabT - g.box.tmin) / span) or 0.5
      local newPts = tr.warp2d(g.orig, g.box.tmin, g.box.tmax, cursorRelT,
        mouseT - g.warpGrabT, mouseV - g.warpGrabV, { knob = g.knob or 0, shape = g.shape or "power" })
      g.pending = newPts
      writeTransformed(newPts)
      g.status = "Warp X+Y"
    else -- tilt
      local side = (g.zone == "tiltL") and "left" or "right"
      local mouseV = yToV(my)
      local endV   = g.box.vmax  -- both tilt handles sit at the top of the bounding box
      local delta  = mouseV - endV
      local newPts = tr.tilt(g.orig, g.box.tmin, g.box.tmax, delta,
        { knob = g.knob or 0, shape = g.shape or "power", side = side, symmetrical = g.symmetrical or false })
      g.pending = newPts
      writeTransformed(newPts)
      -- readout as a % of the lane's value range (storage units are arbitrary/huge — show something human)
      local pct = (g.vhi ~= g.vlo) and (delta / (g.vhi - g.vlo) * 100) or 0
      g.status = ("Tilt %+d%%"):format(math.floor(pct + 0.5))
    end
  end

  -- end drag (button released): bake the result into orig (so a re-grab chains), close this drag's undo
  -- point, and keep the tool open for another grab.
  if g.zone and not down then
    g.orig = g.pending or g.orig; g.pending = nil; g.zone = nil
    if g.dragUndo then
      markEditDirty()  -- CC: register the edit before closing (flag-4 entry is empty without it)
      reaper.Undo_EndBlock2(0, g.undoLabel, g.undoFlag); g.dragUndo = false
    end
    resyncSnap()  -- CC: take changed; the next write must rebuild from this committed state, not launch
  end

  -- Live param gestures over the arrange (not while over the HUD or dragging a widget): wheel = Curve,
  -- middle-click = Power/Sine, right-click = Symmetrical. The HUD reflects them since it reads M.params.
  if not hudBusy then
    local wv = reaper.ImGui_GetMouseWheel(ctx)
    if wv and wv ~= 0 then
      local k = (M.params.knob or 0) + (wv > 0 and 5 or -5)
      M.params.knob = (k < -100) and -100 or (k > 100) and 100 or k
    end
    if reaper.ImGui_IsMouseClicked(ctx, 2) then
      M.params.shape = (M.params.shape == "sine") and "power" or "sine"
    end
    if reaper.ImGui_IsMouseClicked(ctx, 1) then
      M.params.symmetrical = not M.params.symmetrical
    end
  end

  -- Draw EVERYTHING in ONE window: the box + handles (DrawList) AND the HUD panel (DrawList background +
  -- widgets placed by explicit per-row cursor). A single window means no inter-window focus competition —
  -- the HUD keeps responding even after a handle drag focuses the overlay (the earlier two-window version
  -- stopped registering HUD clicks after the first drag). The window CAPTURES input (no NoInputs) so the
  -- arrange can't be clicked/zoomed while the tool is active.
  reaper.ImGui_SetNextWindowPos(ctx, tvr.l, tvr.t)
  reaper.ImGui_SetNextWindowSize(ctx, tvr.w, tvr.h)
  local flags = reaper.ImGui_WindowFlags_NoDecoration() | reaper.ImGui_WindowFlags_NoMove()
    | reaper.ImGui_WindowFlags_NoBackground()
    | reaper.ImGui_WindowFlags_NoNav() | reaper.ImGui_WindowFlags_NoSavedSettings()
  if reaper.ImGui_Begin(ctx, "##contour_overlay", true, flags) then
    local dl = reaper.ImGui_GetWindowDrawList(ctx)
    -- bounding box + handles
    reaper.ImGui_DrawList_AddRect(dl, x0, yt, x1, yb, BOXCOL, 0, 0, 1.5)
    for _, hnd in ipairs(handles) do
      local c = OPCOL[hnd.op] or { ACCENT, ACCENT_H }
      local col = (g.zone == hnd.id) and c[2] or c[1]
      reaper.ImGui_DrawList_AddCircleFilled(dl, hnd.x, hnd.y, 11.55, 0x0A1A1FE6)  -- dark disc for contrast
      reaper.ImGui_DrawList_AddCircle(dl, hnd.x, hnd.y, 11.55, col, 0, 0.95)       -- op-coloured ring
      if     hnd.arrow == "h" then arrowH(dl, hnd.x, hnd.y, col)
      elseif hnd.arrow == "v" then arrowV(dl, hnd.x, hnd.y, col)
      elseif hnd.arrow == "c" then arrowCurved(dl, hnd.x, hnd.y, col, hnd.dir)
      else arrow4(dl, hnd.x, hnd.y, col) end
    end
    -- HUD panel background (drawn before the widgets, which append to the same draw list on top)
    reaper.ImGui_DrawList_AddRectFilled(dl, hudX, hudY, hudX+HUDW, hudY+HUDH, 0x12242BF7, 6)
    reaper.ImGui_DrawList_AddRect(dl, hudX, hudY, hudX+HUDW, hudY+HUDH, ACCENT, 6, 0, 1.5)
    local p = M.params
    local PAD, RH = 11, 27
    local function rowY(i) reaper.ImGui_SetCursorScreenPos(ctx, hudX + PAD, hudY + PAD + i * RH) end
    reaper.ImGui_PushItemWidth(ctx, HUDW - 2 * PAD)
    rowY(0)
    _, p.knob = reaper.ImGui_SliderInt(ctx, "##hud_curve", p.knob, -100, 100,
      p.knob == 0 and "Curve: linear" or "Curve: %d")
    rowY(1)
    if reaper.ImGui_RadioButton(ctx, "Power##hud_pow", p.shape == "power") then p.shape = "power" end
    reaper.ImGui_SameLine(ctx)
    if reaper.ImGui_RadioButton(ctx, "Sine##hud_sine", p.shape == "sine") then p.shape = "sine" end
    rowY(2)
    local cSym, sym = reaper.ImGui_Checkbox(ctx, "Symmetrical##hud_sym", p.symmetrical)
    if cSym then p.symmetrical = sym end
    rowY(3)
    reaper.ImGui_Text(ctx, (g and g.status) or "Grab a handle to transform")
    rowY(4)
    if reaper.ImGui_Button(ctx, "Reverse##hud_rev") then M._pendingOneShot = "reverse" end
    reaper.ImGui_SameLine(ctx)
    if reaper.ImGui_Button(ctx, "Flip##hud_flip") then M._pendingOneShot = "flip" end
    reaper.ImGui_SameLine(ctx)
    if reaper.ImGui_Button(ctx, "Reset##hud_reset") then M._pendingOneShot = "reset" end
    rowY(5)
    if reaper.ImGui_RadioButton(ctx, "Absolute##hud_fa", p.flipMode == "absolute") then p.flipMode = "absolute" end
    reaper.ImGui_SameLine(ctx)
    if reaper.ImGui_RadioButton(ctx, "Relative##hud_fr", p.flipMode == "relative") then p.flipMode = "relative" end
    -- Gesture hints, one per short line (pre-broken; the full single line won't fit, and ImGui wrap takes
    -- window-local coords our screen-pos layout doesn't use). Each line sits 17px below the previous.
    local hy = hudY + PAD + 6 * RH
    reaper.ImGui_SetCursorScreenPos(ctx, hudX + PAD, hy);      reaper.ImGui_TextColored(ctx, 0xC0A040FF, "Mouse Scroll: Curve")
    reaper.ImGui_SetCursorScreenPos(ctx, hudX + PAD, hy + 17); reaper.ImGui_TextColored(ctx, 0xC0A040FF, "Middle-click: Power/Sine")
    reaper.ImGui_SetCursorScreenPos(ctx, hudX + PAD, hy + 34); reaper.ImGui_TextColored(ctx, 0xC0A040FF, "Right-click: Symmetrical")
    reaper.ImGui_PopItemWidth(ctx)
  end
  reaper.ImGui_End(ctx)
  return true
end

function M._bounds(pts)
  local b = { tmin=1e18, tmax=-1e18, vmin=1e18, vmax=-1e18 }
  for _, p in ipairs(pts) do
    if p.t<b.tmin then b.tmin=p.t end; if p.t>b.tmax then b.tmax=p.t end
    if p.v<b.vmin then b.vmin=p.v end; if p.v>b.vmax then b.vmax=p.v end
  end
  if b.tmax<=b.tmin then b.tmax=b.tmin+1e-6 end
  if b.vmax<=b.vmin then b.vmin=b.vmin-0.01; b.vmax=b.vmax+0.01 end
  return b
end

function M.finish()
  -- Defensive: close a drag's undo block if the tool exits mid-drag (e.g. Esc while held).
  if g and g.dragUndo then
    markEditDirty()
    reaper.Undo_EndBlock2(0, g.undoLabel or "Contour: Transform", g.undoFlag or -1)
    g.dragUndo = false
  end
  M._pendingOneShot = nil  -- don't let a queued one-shot survive into the next session
  g = nil
end

return M
