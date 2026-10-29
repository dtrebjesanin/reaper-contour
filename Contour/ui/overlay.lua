-- ui/overlay.lua — Transform mouse-overlay engine (Reaper-bound). A transparent, input-capturing ReaImGui
-- window floats over the arrange (track envelopes / automation items) or the MIDI editor (CC); it draws the
-- selection box + handles and performs LIVE drag transforms (Stretch / Tilt / Scale / Compress / Warp, and
-- Move = Shift + the centre handle) plus the Reverse / Flip / Reset one-shots, committing one undo point
-- per gesture.
local M = {}
local target = require("core.target")
local ac     = require("core.arrangecoords")
local tr     = require("core.transform")
local common = require("ui.common")
local theme  = require("ui.theme")
-- Shaping params live HERE (the overlay is its own script instance — no cross-process sync needed). The
-- HUD edits them; the drag branches read them via g.knob/g.shape/g.symmetrical each frame.
M.params = { knob = 0, shape = "power", symmetrical = false, flipMode = "absolute", smallHandles = false }

-- HUD settings saved between launches (ExtState Contour/<key>, persisted): { param, key, encode, decode }.
-- Curve is deliberately NOT saved — a forgotten curve would silently change the next result. decode
-- returns nil for an absent/unknown value, which leaves the default in place.
local SAVED = {
  { "symmetrical",  "tr_sym",      function(v) return v and "1" or "0" end,
    function(s) if s == "1" then return true elseif s == "0" then return false end end },
  { "shape",        "tr_shape",    tostring,
    function(s) if s == "power" or s == "sine" then return s end end },
  { "flipMode",     "tr_flipmode", tostring,
    function(s) if s == "absolute" or s == "relative" then return s end end },
  { "smallHandles", "tr_handles",  function(v) return v and "small" or "full" end,
    function(s) if s == "small" then return true elseif s == "full" then return false end end },
}

local ACCENT   = 0x2E8B9BFF
local ACCENT_H = 0x53C9D6FF
local BOXCOL   = 0x2E8B9BCC

-- Forward declaration: bounds() is defined lower in the file but called from the draw/drag handlers
-- ABOVE its definition. As a module-local it must be declared here first, else those earlier call
-- sites resolve to a nil global (regression from demoting M._bounds to a local).
local bounds

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

-- Load the saved HUD settings over the defaults (launch), and save any that changed (every frame — the
-- HUD widgets and the mouse gestures both edit M.params). g.saved holds the last saved encodings.
local function loadSaved()
  for _, s in ipairs(SAVED) do
    local v = s[4](reaper.GetExtState("Contour", s[2]) or "")
    if v ~= nil then M.params[s[1]] = v end
  end
end
local function saveChanged()
  for _, s in ipairs(SAVED) do
    local enc = s[3](M.params[s[1]])
    if enc ~= g.saved[s[2]] then
      reaper.SetExtState("Contour", s[2], enc, true)
      g.saved[s[2]] = enc
    end
  end
end

-- ReaImGui draws in a TOP-DOWN, DPI-scaled coordinate space on every platform, but REAPER's native APIs
-- (JS_Window_*, track I_TCPSCREENY, GetSet_ArrangeView2) hand back OS-NATIVE screen coords: bottom-up on
-- macOS, and unscaled on HiDPI/4K. Feeding native coords straight to ImGui put the box/handles/HUD in the
-- wrong place (vertically inverted on macOS, offset on 4K). ImGui_PointConvertNative maps native -> ImGui,
-- correcting the macOS Y-flip AND the Windows/Linux DPI scale in one call. Guarded: on an older ReaImGui
-- without it, fall back to identity (native == ImGui, the historical Windows-standard-DPI behavior).
local function toImGui(ctx, x, y)
  if reaper.ImGui_PointConvertNative then
    local cx, cy = reaper.ImGui_PointConvertNative(ctx, x, y)
    if cx and cy then return cx, cy end   -- nil-safe: never crash the overlay if the API returns nothing
  end
  return x, y
end

-- arrange trackview client rect (screen coords) + width.
local function trackviewRect()
  local main = reaper.GetMainHwnd()
  local tv = reaper.JS_Window_FindChildByID(main, 0x3E8)  -- 1000 = arrange trackview
  if not tv then return nil end
  local ok, l, t, r, b = reaper.JS_Window_GetClientRect(tv)
  if not ok then return nil end
  return { l = l, t = t, r = r, b = b, w = r - l, h = b - t }
end

-- envelope lane rect, as an ARRANGE-RELATIVE top offset + height (NOT screen coords).
-- On macOS I_TCPSCREENY is in a different coordinate system than the JS_Window trackview rect (top-down vs
-- bottom-up, different origin), so screen coords for the lane can't be reconciled with the (correctly
-- converted) trackview. I_TCPY + I_TCPY_USED is arrange-relative and platform-consistent; the caller adds
-- it to the converted trackview top (scaled by the trackview height ratio for HiDPI).
-- TRACK envelope: the envelope's own TCP lane. TAKE envelope (`take` given): with SEVERAL take
-- envelopes visible on one item REAPER stacks them in strips, and I_TCPY_USED/I_TCPH_USED report the
-- clicked envelope's OWN strip (track-relative, same fields as the TCP-lane path) — so prefer those.
-- Fall back to the ITEM BODY rect (track I_TCPY + item I_LASTY/I_LASTH) when the strip fields come
-- back empty, which is exact for the single-envelope case.
local function laneRect(env, take)
  if take then
    local item = reaper.GetMediaItemTake_Item(take)
    if not item then return nil end
    local track = reaper.GetMediaItem_Track(item)
    if not track then return nil end
    local ty = reaper.GetMediaTrackInfo_Value(track, "I_TCPY")
    local ey = reaper.GetEnvelopeInfo_Value(env, "I_TCPY_USED")    -- the envelope's strip within the item stack
    local eh = reaper.GetEnvelopeInfo_Value(env, "I_TCPH_USED")
    if eh and eh > 0 then
      return { topOff = (ty or 0) + (ey or 0), h = eh }
    end
    local iy = reaper.GetMediaItemInfo_Value(item, "I_LASTY")      -- item Y within the track (px)
    local ih = reaper.GetMediaItemInfo_Value(item, "I_LASTH")      -- item height (px)
    if not ih or ih <= 0 then return nil end
    return { topOff = (ty or 0) + (iy or 0), h = ih }
  end
  local track = reaper.GetEnvelopeInfo_Value(env, "P_TRACK")
  if not track then return nil end
  local ty = reaper.GetMediaTrackInfo_Value(track, "I_TCPY")        -- track TCP Y, relative to arrange top
  local ly = reaper.GetEnvelopeInfo_Value(env, "I_TCPY_USED")       -- envelope offset within the track TCP
  local lh = reaper.GetEnvelopeInfo_Value(env, "I_TCPH_USED")
  if not lh or lh <= 0 then return nil end
  return { topOff = (ty or 0) + (ly or 0), h = lh }
end

-- All visible CC-area lanes from the item chunk's VELLANE lines: { {lane=int, h=px}, ... } in chunk
-- order, which is the on-screen order TOP to BOTTOM (the lane stack sits at the BOTTOM of the midiview,
-- so the LAST entry's bottom edge is the midiview bottom). lane ids: 0..127 = CC#; -1 = velocity;
-- >= 128 = pitch/program/etc. special lanes — not editable targets here, but their heights still
-- position the lanes around them.
local function parseVellanes(chunk)
  local lanes = {}
  for ln, hh in chunk:gmatch("VELLANE%s+(%-?%d+)%s+(%d+)") do
    lanes[#lanes + 1] = { lane = tonumber(ln), h = tonumber(hh) }
  end
  return lanes
end

-- The active lane's slot in the stack: (height, bottomOffset), where bottomOffset = the summed heights
-- of the lanes BELOW it (listed after it) = how far its bottom edge sits above the midiview bottom.
-- A single visible lane (or the bottom lane of a stack) has offset 0. nil if the lane isn't in the stack.
local function laneSlot(lanes, lane)
  local idx
  for i, e in ipairs(lanes) do if e.lane == lane then idx = i; break end end
  if not idx then return nil end
  local off = 0
  for i = idx + 1, #lanes do off = off + lanes[i].h end
  return lanes[idx].h, off
end

-- One item chunk carries EVERY take's <SOURCE> block, each with its own CFGEDITVIEW/VELLANE lines —
-- matching the whole chunk read take 1's view state (and lane stack) while the editor showed take 2.
-- Slice to the ACTIVE take's section: take k's block starts at the k-th "\nTAKE...\nNAME" boundary
-- (take 0's data sits before the first boundary, straight after the item header) — the same walk
-- juliansader's Multi Tool does. Falls back to the whole chunk if the boundaries don't line up.
local function activeTakeSlice(chunk, take)
  local takeNum = reaper.GetMediaItemTakeInfo_Value
                  and reaper.GetMediaItemTakeInfo_Value(take, "IP_TAKENUMBER") or 0
  local startPos = 1
  for _ = 1, takeNum do
    local p = chunk:find("\nTAKE[^\n]-\nNAME", startPos + 1)
    if not p then return chunk end
    startPos = p
  end
  local endPos = chunk:find("\nTAKE[^\n]-\nNAME", startPos + 1)
  return chunk:sub(startPos, endPos)
end

-- MIDI CC coordinate setup (juliansader's CFGEDITVIEW/VELLANE approach, decoded from a live editor):
--   CFGEDITVIEW field 1 = leftmost tick at the midiview's left edge; field 2 = the horizontal zoom.
--   CFGEDIT field 19 = the editor's timebase: 0/4 = beats (zoom is px per TICK), 1/2 = project
--   synced/time (zoom is px per SECOND — tick math there put the box ~1000x off and wrote CC at
--   wrong times). VELLANE lines (one per visible lane, top-to-bottom) = each lane's pixel height.
-- Multiple visible lanes are supported: the tool maps the ACTIVE (last-clicked) lane's own strip via its
-- slot in the VELLANE stack (laneSlot). Read ONCE at launch (the overlay then locks the view by capturing
-- input); the midiview RECT is re-read live each frame in M.frame, so moving/resizing the editor still
-- tracks. midiview = child id 1001 (0x3E9).
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
  chunk = activeTakeSlice(chunk, take)
  -- (%S+) not [%d%.]: REAPER writes tiny floats in scientific notation ("6.5e-05" at extreme
  -- zoom-out), and the digit class silently truncated the exponent — a ~100000x zoom error.
  local leftTick, pxPerTick = chunk:match("CFGEDITVIEW%s+(%S+)%s+(%S+)")
  if not (leftTick and pxPerTick) then return nil, "no CFGEDITVIEW" end
  local lanes = parseVellanes(chunk)
  if #lanes == 0 then return nil, "no VELLANE" end
  local laneHeight, laneBottomOff = laneSlot(lanes, lane)
  if not laneHeight then
    -- The clicked lane isn't among the VISIBLE lanes (e.g. it was hidden after being clicked): refuse
    -- with guidance rather than silently mapping the box onto a different lane's strip. (This replaces
    -- the old fall-back-to-first-VELLANE, which could aim the box at a lane the data isn't on.)
    return nil, ("CC %d isn't a visible lane — click its lane in the editor, then relaunch"):format(lane)
  end
  leftTick, pxPerTick = tonumber(leftTick), tonumber(pxPerTick)
  if not (pxPerTick and pxPerTick ~= 0 and laneHeight > 0) then return nil, "bad view numbers" end
  -- Editor timebase: CFGEDIT field 19. "0"/"4" (or no CFGEDIT line) = beats; anything else = time.
  local timeMode = false
  local cfgedit = ("\n" .. chunk):match("\nCFGEDIT%s+([^\r\n]+)")
  if cfgedit then
    local fields = {}
    for w in cfgedit:gmatch("%S+") do fields[#fields + 1] = w end
    local tb = fields[19]
    timeMode = (tb ~= nil) and not (tb == "0" or tb == "4")
  end
  local leftTime
  if timeMode and reaper.MIDI_GetProjTimeFromPPQPos then
    leftTime = reaper.MIDI_GetProjTimeFromPPQPos(take, leftTick)  -- field 1 stays a TICK in time mode
  end
  return { midiview = mv, leftTick = leftTick, pxPerTick = pxPerTick,
           timeMode = timeMode, leftTime = leftTime,
           laneHeight = laneHeight, laneBottomOff = laneBottomOff }
end

-- Read in-scope points (raw STORAGE values), tagged with their envelope index, for the explicit scope:
-- "points" = the selected points (error if none); "timesel" = points inside the time selection (error if
-- none). Returns region[], t0, t1, all[]  — or nil, message.
local function readScope(detected, scope)
  local sel, all = {}, {}
  local isTakeEnv = detected.target == "envelope" and detected.details and detected.details.take
  if detected.target == "cc" or isTakeEnv then
    -- CC + TAKE envelopes read via the target abstraction: both need a time conversion the target owns
    -- (CC: ppq -> project seconds; take envelope: take-relative seconds -> project seconds).
    local tgt = target.fromContext(detected)
    if not tgt then return nil, "No target" end
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
  -- The pristine snapshot every write rebuilds from. Without it EVERY write would fail with only the
  -- tiny "write failed" HUD status, so refuse to start instead. (Only CC's MIDI_GetAllEvts can actually
  -- fail; env/AI snapshots are inert markers.)
  local snap, snapErr = tgt:snapshot()
  if not snap then return false, "Take snapshot failed: " .. tostring(snapErr) end
  -- Points OUTSIDE the transformed region — re-written unchanged each frame so they're preserved when a
  -- stretch's widened delete-range sweeps over them.
  local keep = {}
  for _, p in ipairs(all or {}) do if p.t < t0 or p.t > t1 then keep[#keep + 1] = p end end
  -- Deep copy a point list so the pristine "first state" can never be mutated by later edits.
  local function dcopy(arr)
    local out = {}
    for i = 1, #arr do out[i] = tr.clonePoint(arr[i]) end
    return out
  end
  g = { detected = detected, scope = scope, tgt = tgt, env = detected.details.env,
        orig = region, keep = keep, t0 = t0, t1 = t1, vlo = vlo, vhi = vhi,
        snap = snap, zone = nil,
        -- TAKE envelope: laneRect maps values over the ITEM body instead of a TCP envelope lane.
        envTake = (detected.target == "envelope") and detected.details.take or nil,
        -- CC coordinate frame (env/AI leave these nil and use the arrange-lane path):
        isCC = (detected.target == "cc"), take = detected.details.take,
        midiview = cc and cc.midiview, ccLeftTick = cc and cc.leftTick,
        ccPxPerTick = cc and cc.pxPerTick, ccLaneHeight = cc and cc.laneHeight,
        -- Editor timebase time/synced: the zoom is px per SECOND and x maps linearly in project time.
        ccTimeMode = cc and cc.timeMode or false, ccLeftTime = cc and cc.leftTime,
        ccLaneBottomOff = (cc and cc.laneBottomOff) or 0,  -- summed heights of the lanes BELOW the active one (0 = bottom/only lane)
        ccTopInset = 11, ccBottomInset = 1.5,  -- CC lane top-header / bottom-border px padding (values 127/0 sit inside the lane)
        -- Undo: CC needs UNDO_STATE_ITEMS(4) + a MarkTrackItemsDirty per edit (point changes aren't captured
        -- by flag -1 alone); env/AI use UNDO_STATE_ALL(-1). Mirrors ui/generate.lua's live-gesture undo.
        undoFlag = (detected.target == "cc") and 4 or -1,
        undoLabel = (detected.target == "cc") and "Contour: Transform MIDI CC"
                    or (detected.target == "ai") and "Contour: Transform automation item"
                    or (detected.target == "envelope" and detected.details.take) and "Contour: Transform take envelope"
                    or "Contour: Transform envelope",
        -- Reset restores these: the region + outside points as captured at launch, plus the widest time
        -- extent ever written this session (so widening stretches/warps leave no stray points behind).
        pristine = dcopy(region), pristineKeep = dcopy(keep), everMin = t0, everMax = t1 }
  loadSaved()
  g.saved = {}
  for _, s in ipairs(SAVED) do g.saved[s[2]] = s[3](M.params[s[1]]) end
  g.knob = M.params.knob; g.shape = M.params.shape; g.symmetrical = M.params.symmetrical
  -- HUD starts collapsed if the user left it that way last time (toggled in the draw block; persisted).
  -- The DRAGGED position stays session-only (g.hudUser dies with the tool) — but the PIN button can
  -- save a persistent HOME (tr_hudhome, view-relative ints): launches start there when set, at the
  -- classic spot off the box's top-right corner when not.
  g.hudCollapsed = reaper.GetExtState("Contour", "tr_hudcollapsed") == "1"
  local hx, hy = (reaper.GetExtState("Contour", "tr_hudhome") or ""):match("^(%-?%d+),(%-?%d+)$")
  if hx then g.hudHome = { x = tonumber(hx), y = tonumber(hy) } end
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

-- Handle grab radius (screen px, square test) and minimum on-screen box size, per handle style. The
-- minimum box keeps neighbouring grab areas apart (MINPX/2 > 2*HR), so two handles never overlap.
local HR_FULL, HR_SMALL = 10, 6
local MINPX_FULL, MINPX_SMALL = 44, 28
local function hit(mx, my, hx, hy, r) return math.abs(mx-hx) <= r and math.abs(my-hy) <= r end

-- The target's REAL time boundaries: item bounds for automation items, take envelopes AND MIDI CC
-- (the same rule juliansader's Multi Tool enforces — its mouse tick is clamped into the visible item
-- on every move), project start for track envelopes (right side unbounded — envelopes extend forever).
local function targetTimeBounds()
  local kind = g.tgt and g.tgt.kind and g.tgt:kind()
  if kind == "ai" or kind == "takeenv" or kind == "cc" then
    if g.tgt.fullSpan then return g.tgt:fullSpan() end
    return nil, nil
  elseif kind == "envelope" then
    return 0, nil
  end
  return nil, nil
end

-- Write the transformed points back, under PreventUIRefresh. FULL RE-WRITE each frame: the transformed
-- region points PLUS the preserved (outside) points = every point. The delete-range spans them all, so
-- stretch can push points beyond the original span without being clamped, pulling a stretch back never
-- leaves stragglers, and the untouched automation outside the selection is re-inserted unchanged.
-- Values stay in the storage domain (rawShape; no ScaleTo) — same as Reduce/Generate.
local function writeTransformed(newPts)
  -- Clamp to the target's REAL boundaries before writing — and therefore before these points become
  -- the next baseline (the SAME table is baked on release / one-shot): values to the lane range, and
  -- times to targetTimeBounds. Keeping the written data and the baseline identical is what keeps the
  -- re-rendered box inside the boundaries the actual points piled up against.
  local tlo, thi = targetTimeBounds()
  for _, p in ipairs(newPts) do
    if p.v < g.vlo then p.v = g.vlo elseif p.v > g.vhi then p.v = g.vhi end
    if tlo and p.t < tlo then p.t = tlo end
    if thi and p.t > thi then p.t = thi end
  end
  -- Time-ascending BEFORE the write (in place, so the baseline baked from this table matches): the
  -- write order of same-time points decides a step's direction, and a mirrored list must swap them.
  tr.orderByTime(newPts)
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

-- Baked baselines must be TIME-ASCENDING: transforms that reorder points (Reverse mirrors times in
-- place; a Stretch dragged across its anchor negates the factor) otherwise hand warp2d a descending
-- list, whose anti-fold guard then stacks the whole shape at the right edge on the next Warp drag.
-- tr.orderByTime, not a plain table.sort: it keeps same-time points (vertical steps) in order.
local function sortByTime(pts)
  return tr.orderByTime(pts)
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

-- HUD view margin (px): the panel never sits closer than this to the view edges.
local HUD_M = 4

-- Pin toggle: save the panel's CURRENT position as the persistent default home (view-relative
-- INTEGERS — locale-proof), or unpin back to the classic box-corner home. Clearing g.hudUser on pin
-- hands the spot over to the home path with no visual jump (the home IS this spot now).
local function hudPinToggle()
  if not (g and g.hudRect) then return end
  if g.hudHome then
    g.hudHome = nil
    if reaper.DeleteExtState then reaper.DeleteExtState("Contour", "tr_hudhome", true)
    else reaper.SetExtState("Contour", "tr_hudhome", "", true) end
  else
    local hx = math.floor(g.hudRect.x - (g.viewL or 0) + 0.5)
    local hy = math.floor(g.hudRect.y - (g.viewT or 0) + 0.5)
    g.hudHome = { x = hx, y = hy }
    reaper.SetExtState("Contour", "tr_hudhome", hx .. "," .. hy, true)
    g.hudUser = nil
  end
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
    local b = bounds(g.orig)
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
      for i = 1, #(g.pristine or {}) do newPts[i] = tr.clonePoint(g.pristine[i]) end
      g.keep = {}
      for i = 1, #(g.pristineKeep or {}) do g.keep[i] = tr.clonePoint(g.pristineKeep[i]) end
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
      g.orig = sortByTime(newPts)   -- boundary-clamped inside writeTransformed above; ascending for warp
      -- CC: refresh off the just-written take so a later edit can't resurrect removed points. If the
      -- re-snapshot fails (take gone/broken), end the tool cleanly — the edit is already committed.
      if not resyncSnap() then return false end
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
    -- Native -> ImGui (macOS Y-flip + HiDPI): convert the midiview corners, then derive x/y scales.
    local il, it = toImGui(ctx, l, t)
    local ir, ib = toImGui(ctx, r, b)
    if it > ib then it, ib = ib, it end
    local ilx, irx = math.min(il, ir), math.max(il, ir)
    local xScale = (r ~= l) and ((irx - ilx) / (r - l)) or 1
    local yScale = (b ~= t) and (math.abs(ib - it) / math.abs(b - t)) or 1
    -- CC value edges computed IN ImGui SPACE (top-down): the ACTIVE lane's strip sits ccLaneBottomOff
    -- native px above the midiview BOTTOM (the summed heights of the lanes below it in the VELLANE stack;
    -- 0 when it's the bottom/only lane — identical to the old single-lane mapping). Value 0 sits just
    -- above the strip's bottom, value 127 a lane-height above that. Working from the converted `ib` keeps
    -- the macOS bottom-up flip handled; native px offsets/insets scale to ImGui px via yScale.
    local ivalBot = ib - (g.ccLaneBottomOff + g.ccBottomInset) * yScale
    local ivalTop = ib - (g.ccLaneBottomOff + g.ccLaneHeight - g.ccTopInset) * yScale
    local ispan = ivalBot - ivalTop
    if ispan <= 0 then return true end
    tvr = { l = ilx, t = it, r = irx, b = ib, w = irx - ilx, h = ib - it }
    if g.ccTimeMode and g.ccLeftTime then
      -- Timebase time/synced: CFGEDITVIEW's zoom is px per SECOND — x is linear in project time.
      local pxPerSec = g.ccPxPerTick * xScale
      X    = function(tt) return ilx + (tt - g.ccLeftTime) * pxPerSec end
      xToT = function(x)  return g.ccLeftTime + (x - ilx) / pxPerSec end
    else
      local pxPerTick = g.ccPxPerTick * xScale
      X    = function(tt) return ilx + (reaper.MIDI_GetPPQPosFromProjTime(g.take, tt) - g.ccLeftTick) * pxPerTick end
      xToT = function(x)  return reaper.MIDI_GetProjTimeFromPPQPos(g.take, g.ccLeftTick + (x - ilx) / pxPerTick) end
    end
    Y    = function(v)  return (g.vhi == g.vlo) and ivalBot or (ivalBot - (v - g.vlo) / (g.vhi - g.vlo) * ispan) end
    yToV = function(y)  return g.vlo + (ivalBot - y) / ispan * (g.vhi - g.vlo) end
  else
    local vt0, vt1
    tvr, vt0, vt1 = viewNow()
    local lr = laneRect(g.env, g.envTake)   -- take envelopes map over the item body
    if not tvr or not lr or vt1 <= vt0 then return true end
    -- Native -> ImGui (macOS Y-flip + HiDPI): convert the trackview corners and the lane's yTop/yBot, then
    -- build the maps in ImGui space. viewNow already consumed the NATIVE l/r for GetSet_ArrangeView2, so
    -- converting here doesn't disturb the time lookup. min/max keeps top<bottom whichever way the platform
    -- orders the converted corners.
    local il, iTop = toImGui(ctx, tvr.l, tvr.t)
    local ir, iBot = toImGui(ctx, tvr.r, tvr.b)
    if il > ir then il, ir = ir, il end
    if iTop > iBot then iTop, iBot = iBot, iTop end
    -- Lane Y from the ARRANGE-RELATIVE offset (see laneRect), scaled into ImGui px by the trackview
    -- height ratio (=1 non-HiDPI) and added to the converted trackview top. Avoids the I_TCPSCREENY
    -- coordinate-system mismatch that pushed the box off-screen on macOS.
    local nativeH = math.abs(tvr.b - tvr.t)
    local scaleY  = (nativeH > 0) and (math.abs(iBot - iTop) / nativeH) or 1
    local iyTop = iTop + lr.topOff * scaleY
    local iyBot = iyTop + lr.h * scaleY
    tvr = { l = il, t = iTop, r = ir, b = iBot, w = ir - il, h = iBot - iTop }
    X    = function(tt) return ac.timeToX(tt, vt0, vt1, il, ir) end
    xToT = function(x)  return ac.xToTime(x, vt0, vt1, il, ir) end
    Y    = function(v)  return ac.valueToY(v, g.vlo, g.vhi, iyTop, iyBot) end
    yToV = function(y)  return ac.yToValue(y, g.vlo, g.vhi, iyTop, iyBot) end
  end
  -- LIVE box: during a drag the box tracks the IN-FLIGHT result (g.pending, one frame behind), not the
  -- pre-drag shape — so you see the boundary the whole time, including the moment the transform hits a
  -- clamp (item edge / lane rail) and stops growing. Anchoring math is unaffected: drags derive from
  -- g.box (snapshotted at grab) and re-transform g.orig every frame.
  local b = bounds(g.pending or g.orig)
  -- DISPLAY safety clamp: stored points can hold values/times beyond the target's CURRENT extent
  -- (range preference changed after writing, other tools, imports — REAPER draws such points clipped
  -- at the rail). The box hugs the real extent the same way, instead of scaling the overshoot into a
  -- box that shoots off-screen. Geometry only; the data is untouched until a transform writes it.
  local function cl(v, lo, hi)
    if lo and v < lo then return lo end
    if hi and v > hi then return hi end
    return v
  end
  b.vmin, b.vmax = cl(b.vmin, g.vlo, g.vhi), cl(b.vmax, g.vlo, g.vhi)
  local dtlo, dthi = targetTimeBounds()
  b.tmin, b.tmax = cl(b.tmin, dtlo, dthi), cl(b.tmax, dtlo, dthi)
  local x0,x1 = X(b.tmin), X(b.tmax)
  local yt,yb = Y(b.vmax), Y(b.vmin)
  -- Degenerate boxes stay usable: an extreme transform can flatten the shape to a single value (or
  -- compress it to a sliver of time), collapsing the box to a line — the handles then stack onto the
  -- same spots and the last-drawn one (Warp) hides the Scale pair. Enforce a minimum ON-SCREEN box
  -- size around the centre. Geometry only, purely a grab affordance: the value/time mapping and the
  -- drag anchors still come from the real data bounds, so recovery drags behave normally.
  local small = M.params.smallHandles
  local hr    = small and HR_SMALL or HR_FULL
  local MINPX = small and MINPX_SMALL or MINPX_FULL
  if (yb - yt) < MINPX then local c = (yt + yb) / 2; yt, yb = c - MINPX / 2, c + MINPX / 2 end
  if (x1 - x0) < MINPX then local c = (x0 + x1) / 2; x0, x1 = c - MINPX / 2, c + MINPX / 2 end
  local cy = (yt+yb)/2
  local cx = (x0+x1)/2
  g.boxPx = { x0 = x0, y0 = yt, x1 = x1, y1 = yb }   -- the on-screen rect (read by the test seam)

  -- HUD panel geometry (drawn later, INSIDE the overlay window). Its home is the ORIGINAL spot: just
  -- off the selection BOX's top-right corner (rides next to the shape), clamped into the view — so in
  -- a short editor / tall lane it can still land on the box. That's what DRAG (session-only) and the
  -- collapse strip are for (see the draw block). The rect is also what hudBusy protects.
  local HUDW, HUDH = 250, g.hudCollapsed and 28 or 253
  local hudX, hudY
  if g.hudUser then
    -- session-parked position (view-relative + clamped) beats the default spot
    hudX = math.max(tvr.l + HUD_M, math.min(tvr.r - HUD_M - HUDW, tvr.l + g.hudUser.x))
    hudY = math.max(tvr.t + HUD_M, math.min(tvr.b - HUD_M - HUDH, tvr.t + g.hudUser.y))
  elseif g.hudHome then
    -- pinned persistent home (view-relative + clamped) beats the box-corner default
    hudX = math.max(tvr.l + HUD_M, math.min(tvr.r - HUD_M - HUDW, tvr.l + g.hudHome.x))
    hudY = math.max(tvr.t + HUD_M, math.min(tvr.b - HUD_M - HUDH, tvr.t + g.hudHome.y))
  else
    hudX = x1 + 14
    if hudX + HUDW > tvr.r - HUD_M then hudX = tvr.r - HUD_M - HUDW end
    if hudX < tvr.l + HUD_M then hudX = tvr.l + HUD_M end
    hudY = yt - HUDH - 16
    if hudY < tvr.t + HUD_M then hudY = tvr.t + HUD_M end
  end
  g.hudRect = { x = hudX, y = hudY, w = HUDW, h = HUDH }
  g.viewL, g.viewT = tvr.l, tvr.t   -- view origin for the pin's view-relative save

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
  -- Drag the PANEL itself from any empty spot on it (not over a widget — widget hover is last frame's
  -- state, which is exactly right since our mouse handling runs before this frame's widgets). The parked
  -- position is view-relative, clamped, and SESSION-ONLY — every launch starts back at the default spot
  -- off the box's top-right corner. DOUBLE-CLICK an empty spot on the panel to send it back immediately.
  local anyItemHot = (reaper.ImGui_IsAnyItemActive and reaper.ImGui_IsAnyItemActive(ctx))
                  or (reaper.ImGui_IsAnyItemHovered and reaper.ImGui_IsAnyItemHovered(ctx))
  if g.hudDrag then
    local d = g.hudDrag
    if down then
      -- 3px threshold: a plain click on empty panel space must NOT silently park the panel in place
      if not d.moved and (math.abs(mx - d.sx) > 3 or math.abs(my - d.sy) > 3) then d.moved = true end
      if d.moved then
        hudX = math.max(tvr.l + HUD_M, math.min(tvr.r - HUD_M - HUDW, mx - d.dx))
        hudY = math.max(tvr.t + HUD_M, math.min(tvr.b - HUD_M - HUDH, my - d.dy))
        g.hudUser = { x = hudX - tvr.l, y = hudY - tvr.t }
        g.hudRect.x, g.hudRect.y = hudX, hudY
      end
    else
      g.hudDrag = nil   -- released: the parked spot holds for THIS session only (not persisted)
    end
  elseif overHud and not g.zone and not anyItemHot then
    if reaper.ImGui_IsMouseDoubleClicked and reaper.ImGui_IsMouseDoubleClicked(ctx, 0) then
      g.hudUser = nil   -- back to the default spot off the box's top-right corner (next frame)
    elseif down and reaper.ImGui_IsMouseClicked and reaper.ImGui_IsMouseClicked(ctx, 0) then
      g.hudDrag = { dx = mx - g.hudRect.x, dy = my - g.hudRect.y, sx = mx, sy = my, moved = false }
    end
  end
  -- begin drag — skipped while interacting with the HUD, so adjusting it never grabs a handle nor ends the
  -- tool (the HUD widgets live in THIS same window and handle their own clicks).
  if down and not g.zone and not hudBusy then
    for _, hnd in ipairs(handles) do
      if hit(mx, my, hnd.x, hnd.y, hr) then
        g.zone = hnd.id
        g.box = b  -- snapshot box at grab
        g.wMin, g.wMax = b.tmin, b.tmax  -- seed the cleared range at the region's current extent
        -- Cursor time/value at grab (also the warp peak). Every drag follows the mouse MOVEMENT from
        -- here, so a grab off the handle centre — or on a widened (MINPX) box's edge — never jumps.
        g.grabT = xToT(mx)
        g.grabV = yToV(my)
        g.lastSig = nil
        reaper.Undo_BeginBlock2(0); g.dragUndo = true  -- one undo point per drag
        break
      end
    end
    -- click outside any handle AND outside the box => commit + end
    if not g.zone and (mx < x0-hr or mx > x1+hr or my < yt-hr or my > yb+hr) then
      return false
    end
  end

  -- during drag: compute params and write. Skipped while nothing changed — the same mouse position,
  -- settings and Shift state give the same result, and each write deletes and re-inserts every point.
  local shiftHeld = reaper.ImGui_GetKeyMods and reaper.ImGui_Mod_Shift
                    and ((reaper.ImGui_GetKeyMods(ctx) or 0) & reaper.ImGui_Mod_Shift()) ~= 0
  local sig = g.zone and ("%s %.2f %.2f %s %s %s %s"):format(g.zone, mx, my, tostring(g.knob),
    tostring(g.shape), tostring(g.symmetrical), tostring(shiftHeld))
  if g.zone and down and sig ~= g.lastSig then
    g.lastSig = sig
    if g.zone == "stretchL" or g.zone == "stretchR" then
      local edgeT   = (g.zone == "stretchL") and g.box.tmin or g.box.tmax
      local anchorT
      if g.symmetrical then anchorT = (g.box.tmin + g.box.tmax) / 2
      else anchorT = (g.zone == "stretchL") and g.box.tmax or g.box.tmin end
      local mouseT  = edgeT + (xToT(mx) - g.grabT)   -- the edge follows the movement since the grab
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
      local mouseV = boundaryV + (yToV(my) - g.grabV)   -- the edge follows the movement since the grab
      local newPts = tr.vscale(g.orig, anchorV, boundaryV, mouseV, { knob = g.knob or 0, shape = g.shape or "power" })
      g.pending = newPts
      writeTransformed(newPts)
      local denom  = (boundaryV - anchorV)
      local factor = (denom ~= 0) and ((mouseV - anchorV) / denom) or 1
      g.status = ((g.knob or 0) ~= 0 and "Compress %d%%" or "Scale %d%%"):format(math.floor(factor*100+0.5))
    elseif g.zone == "warp" and shiftHeld then
      -- Shift + centre handle: a RIGID vertical move — every point by the same amount, times stay.
      -- A point that reaches a lane rail stops there (writeTransformed's clamp); the others keep moving.
      -- Releasing Shift mid-drag falls back to the warp below.
      local dv = yToV(my) - g.grabV
      local newPts = tr.move(g.orig, dv)
      g.pending = newPts
      writeTransformed(newPts)
      local pct = (g.vhi ~= g.vlo) and (dv / (g.vhi - g.vlo) * 100) or 0
      g.status = ("Move %+d%%"):format(math.floor(pct + 0.5))
    elseif g.zone == "warp" then
      -- Free 2D warp: the peak (at the grab time) follows the cursor in BOTH time and value at once.
      local mouseT = xToT(mx)
      local mouseV = yToV(my)
      local span = g.box.tmax - g.box.tmin
      local cursorRelT = (span > 0) and ((g.grabT - g.box.tmin) / span) or 0.5
      local newPts = tr.warp2d(g.orig, g.box.tmin, g.box.tmax, cursorRelT,
        mouseT - g.grabT, mouseV - g.grabV, { knob = g.knob or 0, shape = g.shape or "power" })
      g.pending = newPts
      writeTransformed(newPts)
      g.status = "Warp X+Y"
    else -- tilt
      local side = (g.zone == "tiltL") and "left" or "right"
      local delta  = yToV(my) - g.grabV   -- the lifted end follows the movement since the grab
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
    -- pending was boundary-clamped inside writeTransformed, so baking it keeps baseline == written data
    g.orig = sortByTime(g.pending or g.orig); g.pending = nil; g.zone = nil; g.lastSig = nil
    if g.dragUndo then
      markEditDirty()  -- CC: register the edit before closing (flag-4 entry is empty without it)
      reaper.Undo_EndBlock2(0, g.undoLabel, g.undoFlag); g.dragUndo = false
    end
    -- CC: the take changed; the next write must rebuild from this committed state, not the launch state.
    -- If the re-snapshot fails (take gone/broken), end the tool cleanly — the drag is already committed;
    -- continuing with the stale snapshot could resurrect points a later write should have removed.
    if not resyncSnap() then return false end
  end

  -- Live param gestures over the arrange (not while over the HUD or dragging a widget): wheel = Curve,
  -- middle-click = Power/Sine, right-click = Symmetrical. The HUD reflects them since it reads M.params,
  -- and each change ECHOES to the status line — the COLLAPSED strip shows only that line, so the
  -- gestures give feedback there too instead of changing parameters silently.
  if not hudBusy then
    local wv = reaper.ImGui_GetMouseWheel(ctx)
    if wv and wv ~= 0 then
      local k = (M.params.knob or 0) + (wv > 0 and 5 or -5)
      M.params.knob = (k < -100) and -100 or (k > 100) and 100 or k
      g.status = (M.params.knob == 0) and "Curve: linear" or ("Curve: %d"):format(M.params.knob)
    end
    if reaper.ImGui_IsMouseClicked(ctx, 2) then
      M.params.shape = (M.params.shape == "sine") and "power" or "sine"
      g.status = (M.params.shape == "sine") and "Shape: Sine" or "Shape: Power"
    end
    if reaper.ImGui_IsMouseClicked(ctx, 1) then
      M.params.symmetrical = not M.params.symmetrical
      g.status = M.params.symmetrical and "Symmetrical: on" or "Symmetrical: off"
    end
  end

  -- Draw EVERYTHING in ONE window: the box + handles (DrawList) AND the HUD panel (DrawList background +
  -- widgets placed by explicit per-row cursor). A single window means no inter-window focus competition —
  -- the HUD keeps responding even after a handle drag focuses the overlay (the earlier two-window version
  -- stopped registering HUD clicks after the first drag). The window CAPTURES input (no NoInputs) so the
  -- arrange can't be clicked/zoomed while the tool is active.
  -- The HUD widgets take the Contour panel's PALETTE (colors only — the HUD keeps its own fixed row
  -- metrics and the default font, so nothing crowds). DrawList visuals (box, handles, HUD background)
  -- keep their own colors. The window uses NoBackground, so the themed WindowBg is inert.
  theme.push(ctx, true)
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
      if small then
        -- Small handles: an op-coloured dot with a dark rim, about a third of the full disc, no arrow
        reaper.ImGui_DrawList_AddCircleFilled(dl, hnd.x, hnd.y, 4.5, 0x0A1A1FE6)
        reaper.ImGui_DrawList_AddCircleFilled(dl, hnd.x, hnd.y, 3.5, col)
      else
        reaper.ImGui_DrawList_AddCircleFilled(dl, hnd.x, hnd.y, 11.55, 0x0A1A1FE6)  -- dark disc for contrast
        reaper.ImGui_DrawList_AddCircle(dl, hnd.x, hnd.y, 11.55, col, 0, 0.95)       -- op-coloured ring
        if     hnd.arrow == "h" then arrowH(dl, hnd.x, hnd.y, col)
        elseif hnd.arrow == "v" then arrowV(dl, hnd.x, hnd.y, col)
        elseif hnd.arrow == "c" then arrowCurved(dl, hnd.x, hnd.y, col, hnd.dir)
        else arrow4(dl, hnd.x, hnd.y, col) end
      end
    end
    -- HUD panel background (drawn before the widgets, which append to the same draw list on top)
    reaper.ImGui_DrawList_AddRectFilled(dl, hudX, hudY, hudX+HUDW, hudY+HUDH, 0x12242BF7, 6)
    reaper.ImGui_DrawList_AddRect(dl, hudX, hudY, hudX+HUDW, hudY+HUDH, ACCENT, 6, 0, 1.5)
    local p = M.params
    local PAD, RH = 11, 27
    -- Collapse / expand toggle (top-right corner). Collapsed = a slim strip with just the live status:
    -- the shaping params keep their mouse gestures (wheel / middle / right click), so collapsing costs
    -- nothing while working — it's the escape hatch for cramped editors. Persisted across launches.
    -- A FIXED 18x18 button, right-aligned and vertically centred on its row (expanded: the Curve fader
    -- row; collapsed: the strip) — the old SmallButton floated a few px high and read as misaligned.
    reaper.ImGui_SetCursorScreenPos(ctx, hudX + HUDW - PAD - 18, hudY + (g.hudCollapsed and 5 or PAD + 1))
    if reaper.ImGui_Button(ctx, "##hud_tog", 18, 18) then
      g.hudCollapsed = not g.hudCollapsed
      reaper.SetExtState("Contour", "tr_hudcollapsed", g.hudCollapsed and "1" or "0", true)
    end
    -- The -/+ glyph is DRAWN, geometrically centred on the button rect: the font's own +/- characters
    -- sit off-centre inside their glyph cell, which is exactly what read as misaligned in a square.
    -- Drawn AFTER the click handling, so it shows the NEW state the moment it's toggled.
    if reaper.ImGui_GetItemRectMin and reaper.ImGui_GetItemRectMax and reaper.ImGui_DrawList_AddLine then
      local bx0, by0 = reaper.ImGui_GetItemRectMin(ctx)
      local bx1, by1 = reaper.ImGui_GetItemRectMax(ctx)
      local bcx, bcy = (bx0 + bx1) / 2, (by0 + by1) / 2
      local bdl = reaper.ImGui_GetWindowDrawList(ctx)
      reaper.ImGui_DrawList_AddLine(bdl, bcx - 4, bcy, bcx + 4, bcy, 0xE3E8ECFF, 1.5)     -- minus bar
      if g.hudCollapsed then
        reaper.ImGui_DrawList_AddLine(bdl, bcx, bcy - 4, bcx, bcy + 4, 0xE3E8ECFF, 1.5)   -- plus upright
      end
    end
    -- PIN toggle (save/unpin the position as the persistent default home), left of the collapse
    -- button — in BOTH states: the panel can be dragged while collapsed, so it must be pinnable
    -- there too. Glyph is DRAWN like the -/+ (map-pin dot + stem): filled = pinned, outline = not.
    reaper.ImGui_SetCursorScreenPos(ctx, hudX + HUDW - PAD - 18 - 22, hudY + (g.hudCollapsed and 5 or PAD + 1))
    if reaper.ImGui_Button(ctx, "##hud_pin", 18, 18) then hudPinToggle() end
    if reaper.ImGui_SetItemTooltip then
      reaper.ImGui_SetItemTooltip(ctx, g.hudHome and "Unpin: the default position returns to the box corner"
                                                  or "Pin this position as the default")
    end
    if reaper.ImGui_GetItemRectMin and reaper.ImGui_DrawList_AddCircle
       and reaper.ImGui_DrawList_AddCircleFilled and reaper.ImGui_DrawList_AddLine then
      local px0, py0 = reaper.ImGui_GetItemRectMin(ctx)
      local px1, py1 = reaper.ImGui_GetItemRectMax(ctx)
      local pcx, pcy = (px0 + px1) / 2, (py0 + py1) / 2
      local pdl = reaper.ImGui_GetWindowDrawList(ctx)
      if g.hudHome then reaper.ImGui_DrawList_AddCircleFilled(pdl, pcx, pcy - 2, 3.5, 0xE3E8ECFF)
      else              reaper.ImGui_DrawList_AddCircle(pdl, pcx, pcy - 2, 3.5, 0xE3E8ECFF, 0, 1.5) end
      reaper.ImGui_DrawList_AddLine(pdl, pcx, pcy + 1, pcx, pcy + 6, 0xE3E8ECFF, 1.5)
    end
    if g.hudCollapsed then
      reaper.ImGui_SetCursorScreenPos(ctx, hudX + PAD, hudY + 6)
      reaper.ImGui_Text(ctx, (g and g.status) or "Grab a handle to transform")
    else
      local function rowY(i) reaper.ImGui_SetCursorScreenPos(ctx, hudX + PAD, hudY + PAD + i * RH) end
      reaper.ImGui_PushItemWidth(ctx, HUDW - 2 * PAD - 46)   -- row 0 leaves room for pin + toggle buttons
      rowY(0)
      _, p.knob = reaper.ImGui_SliderInt(ctx, "##hud_curve", p.knob, -100, 100,
        p.knob == 0 and "Curve: linear" or "Curve: %d")
      -- Same fader treatment as the main panel: deviation fill + default notch + the dimensional cap
      -- (which fully covers the stock grab — no styling push needed) + double-click anywhere on the
      -- fader snaps Curve back to linear (0). g.knob re-syncs from M.params each frame.
      common.tickReset(ctx, p, "knob", -100, 100, 0,
        p.knob == 0 and "Curve: linear" or ("Curve: %d"):format(p.knob))
      rowY(1)
      if reaper.ImGui_RadioButton(ctx, "Power##hud_pow", p.shape == "power") then p.shape = "power" end
      reaper.ImGui_SameLine(ctx)
      if reaper.ImGui_RadioButton(ctx, "Sine##hud_sine", p.shape == "sine") then p.shape = "sine" end
      rowY(2)
      local cSym, sym = reaper.ImGui_Checkbox(ctx, "Symmetrical##hud_sym", p.symmetrical)
      if cSym then p.symmetrical = sym end
      -- Small handles: dots instead of the arrow discs, for small selections. Fixed x, same row.
      reaper.ImGui_SetCursorScreenPos(ctx, hudX + PAD + 108, hudY + PAD + 2 * RH)
      local cSm, sm = reaper.ImGui_Checkbox(ctx, "Small handles##hud_small", p.smallHandles or false)
      if cSm then p.smallHandles = sm end
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
      reaper.ImGui_SetCursorScreenPos(ctx, hudX + PAD, hy + 51); reaper.ImGui_TextColored(ctx, 0xC0A040FF, "Shift + centre: move up/down")
      reaper.ImGui_PopItemWidth(ctx)
    end
    reaper.ImGui_End(ctx)   -- only after a Begin that returned true (ReaImGui's rule, as in contour.lua)
  end
  theme.pop(ctx)
  saveChanged()
  return true
end

function bounds(pts)   -- assigns to the forward-declared local `bounds` (see top of file)
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

-- Test seams (underscore = not public): the pure VELLANE-stack helpers, callable without ImGui/REAPER so
-- the multi-lane geometry math is unit-testable headlessly (tests/test_cclane_stack.lua).
M._parseVellanes = parseVellanes   -- (chunk) -> { {lane, h}, ... } top-to-bottom
M._laneSlot      = laneSlot        -- (lanes, lane) -> height, bottomOffset | nil
M._ccSetup       = ccSetup         -- (detected, lane) -> cc table | nil, err
M._laneRect      = laneRect        -- (env, take?) -> { topOff, h } | nil  (arrange-relative)
M._hudRectNow    = function() return g and g.hudRect end   -- live HUD rect (read-only; nil when idle)
M._hudPinToggle  = hudPinToggle                             -- pin/unpin the persistent HUD home
M._statusNow     = function() return g and g.status end     -- live status line (read-only)
M._boundsNow     = function() return g and bounds(g.orig) end   -- baked-baseline bounds (read-only)
M._boxPxNow      = function() return g and g.boxPx end          -- on-screen box rect (read-only)

return M
