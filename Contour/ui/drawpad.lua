-- ui/drawpad.lua — in-panel custom-shape draw pad (ReaImGui DrawList). Edits a points list in place:
--   click empty -> add point; drag point -> move; right-click / double-click point -> delete
--   (endpoints x are pinned to 0/1, y movable); Alt+drag a segment (EW cursor) -> bend it.
-- The bend PREVIEW uses REAPER's exact shape-5 bezier (customshape.bezierFrac, from schwa's tension
-- model) so the pad matches the rendered envelope/CC. Pure-ish: no ExtState; caller owns persistence.
local M = {}
local cs = require("core.customshape")
local abs, min, max, floor = math.abs, math.min, math.max, math.floor

local GRID = 0x3A434BFF
local AXIS = 0x55636EFF
local CURVE = 0x48C6D4FF
local PT = 0x9FE9F1FF
local PTHOT = 0xFFFFFFFF
local BG = 0x10151AFF

local drag = { idx = nil, seg = nil }   -- which point or segment is being dragged (module-level, single pad)

-- map data (x in [0,1], y in [-1,1]) <-> screen
local function toScreen(px, py, x0, y0, w, hgt) return x0 + px * w, y0 + (1 - (py + 1) / 2) * hgt end
local function toData(sx, sy, x0, y0, w, hgt)
  local x = (w > 0) and (sx - x0) / w or 0
  local y = (hgt > 0) and (1 - (sy - y0) / hgt) * 2 - 1 or 0
  return max(0, min(1, x)), max(-1, min(1, y))
end
-- snap a value to the nearest of `divs` grid lines spanning [lo, hi]
local function snapTo(v, lo, hi, divs)
  if divs < 1 then return v end
  return lo + floor((v - lo) / (hi - lo) * divs + 0.5) / divs * (hi - lo)
end

-- value-fraction per CC segment shape (caller does value = a.y + (b.y-a.y)*ease). Shape 5 = REAPER's
-- exact bezier (customshape.bezierFrac); 2/3/4 are the slow/fast sine eases (Phase-3 stamp palette).
local function ease(shape, t, ten)
  return cs.segEase(shape, t, ten)
end

-- Index of the segment whose drawn CURVE is under the cursor, or nil. Curve-aware: the pad is a
-- function of x, so it evaluates the segment's ease at the cursor's x and compares y — this works for
-- already-bent segments (a plain chord test would miss them). Used for Alt-bend targeting + cursor.
local function segUnder(points, mx, my, x0, y0, w, hgt)
  for i = 1, #points - 1 do
    local a, b = points[i], points[i + 1]
    local ax, bx = x0 + a.x * w, x0 + b.x * w
    if mx >= min(ax, bx) - 2 and mx <= max(ax, bx) + 2 then
      local t = (bx - ax ~= 0) and (mx - ax) / (bx - ax) or 0
      if t < 0 then t = 0 elseif t > 1 then t = 1 end
      local yv = a.y + (b.y - a.y) * ease(a.shape or 1, t, a.tension or 0)
      local cy = y0 + (1 - (yv + 1) / 2) * hgt
      if abs(my - cy) <= 8 then return i end
    end
  end
  return nil
end

function M.draw(ctx, points, opts)
  opts = opts or {}
  if not (reaper.ImGui_GetWindowDrawList and reaper.ImGui_DrawList_AddLine and reaper.ImGui_InvisibleButton
      and reaper.ImGui_GetCursorScreenPos and reaper.ImGui_GetMousePos) then
    reaper.ImGui_Text(ctx, "(draw pad needs a newer ReaImGui)"); return false
  end
  local w = opts.width or 360
  local hgt = opts.height or 140
  local gridX = max(1, floor(opts.gridX or 4))   -- vertical divisions (time)
  local gridY = max(1, floor(opts.gridY or 2))   -- horizontal divisions (value)
  local snap = opts.snap and true or false       -- snap added/dragged points to grid intersections
  local x0, y0 = reaper.ImGui_GetCursorScreenPos(ctx)
  reaper.ImGui_InvisibleButton(ctx, opts.id or "##drawpad", w, hgt)
  local hovered = reaper.ImGui_IsItemHovered(ctx)
  local active = reaper.ImGui_IsItemActive(ctx)
  local mx, my = reaper.ImGui_GetMousePos(ctx)
  local dl = reaper.ImGui_GetWindowDrawList(ctx)
  local changed = false

  -- background + grid (gridX vertical / gridY horizontal divisions; y=0 center drawn last, emphasized)
  reaper.ImGui_DrawList_AddRectFilled(dl, x0, y0, x0 + w, y0 + hgt, BG, 4)
  for i = 0, gridX do local gx = x0 + i / gridX * w; reaper.ImGui_DrawList_AddLine(dl, gx, y0, gx, y0 + hgt, GRID, 1) end
  for j = 0, gridY do local gy = y0 + j / gridY * hgt; reaper.ImGui_DrawList_AddLine(dl, x0, gy, x0 + w, gy, GRID, 1) end
  reaper.ImGui_DrawList_AddLine(dl, x0, y0 + hgt / 2, x0 + w, y0 + hgt / 2, AXIS, 1)   -- center (y=0)

  -- pointer hit-test (nearest point)
  local HR = 9
  local hotPt = nil
  if hovered then
    for i, p in ipairs(points) do
      local sx, sy = toScreen(p.x, p.y, x0, y0, w, hgt)
      if abs(mx - sx) <= HR and abs(my - sy) <= HR then hotPt = i; break end
    end
  end

  -- BEND mode = hold Alt over a line (REAPER convention): show the EW (horizontal double-arrow) cursor
  -- on hover, and Alt+drag the segment to bow it. Without Alt, a click adds a point (anywhere, incl. on
  -- a line). Alt only needs to be held to START the bend; the drag continues if it's released.
  local alt = false
  if reaper.ImGui_GetKeyMods and reaper.ImGui_Mod_Alt then
    alt = (reaper.ImGui_GetKeyMods(ctx) & reaper.ImGui_Mod_Alt()) ~= 0
  end
  local hotSeg = (hovered and not hotPt) and segUnder(points, mx, my, x0, y0, w, hgt) or nil
  if ((alt and hotSeg) or drag.seg) and reaper.ImGui_SetMouseCursor and reaper.ImGui_MouseCursor_ResizeEW then
    reaper.ImGui_SetMouseCursor(ctx, reaper.ImGui_MouseCursor_ResizeEW())
  end

  -- begin gestures on mouse-down. Skip the SECOND click of a double-click so double-clicking empty
  -- space doesn't drop a stray extra point (the double-click is handled by the delete branch below).
  if active and reaper.ImGui_IsMouseClicked(ctx, 0) and not reaper.ImGui_IsMouseDoubleClicked(ctx, 0) then
    if hotPt then drag.idx, drag.seg = hotPt, nil
    elseif alt and hotSeg then drag.idx, drag.seg = nil, hotSeg      -- Alt+drag a segment -> bend it
    else
      local nx, ny = toData(mx, my, x0, y0, w, hgt)                  -- plain click -> add a point
      if snap then nx = snapTo(nx, 0, 1, gridX); ny = snapTo(ny, -1, 1, gridY) end
      points[#points + 1] = { x = nx, y = ny, shape = 1, tension = 0 }
      local clamped = cs.clampPoints(points)
      for k = #points, 1, -1 do points[k] = nil end
      for k = 1, #clamped do points[k] = clamped[k] end
      changed = true; drag.idx, drag.seg = nil, nil
    end
  end

  -- delete on right-click / double-click a point (not endpoints)
  if hotPt and hotPt > 1 and hotPt < #points
     and (reaper.ImGui_IsMouseClicked(ctx, 1) or reaper.ImGui_IsMouseDoubleClicked(ctx, 0)) then
    table.remove(points, hotPt); changed = true; drag.idx, drag.seg = nil, nil
  end

  -- continue drag
  if active and reaper.ImGui_IsMouseDown(ctx, 0) then
    if drag.idx then
      local p = points[drag.idx]
      if p then
        local nx, ny = toData(mx, my, x0, y0, w, hgt)
        if snap then nx = snapTo(nx, 0, 1, gridX); ny = snapTo(ny, -1, 1, gridY) end
        if drag.idx == 1 then nx = 0 elseif drag.idx == #points then nx = 1
        else nx = max(points[drag.idx - 1].x + 1e-3, min(points[drag.idx + 1].x - 1e-3, nx)) end
        p.x, p.y = nx, ny; changed = true
      end
    elseif drag.seg then
      local a, b = points[drag.seg], points[drag.seg + 1]
      if a and b then
        local _, ay = toScreen(a.x, a.y, x0, y0, w, hgt)
        local _, by = toScreen(b.x, b.y, x0, y0, w, hgt)
        local off = max(-1, min(1, ((ay + by) / 2 - my) / (hgt / 2)))   -- mouse above the chord -> off>0
        -- Make the curve TRACK the mouse (above the chord -> bulges up) for both rising and falling
        -- segments. In REAPER's bezier the value-fraction exceeds 0.5 for NEGATIVE tension, so the
        -- sign that lifts the curve on screen depends on the segment's direction.
        local ten = -off * ((b.y >= a.y) and 1 or -1)
        a.shape = (abs(ten) > 1e-3) and 5 or 1; a.tension = ten; changed = true
      end
    end
  end
  if not reaper.ImGui_IsMouseDown(ctx, 0) then drag.idx, drag.seg = nil, nil end

  -- draw the curve. Shape 1 = straight; shape 5 (bezier) is tessellated by the bezier PARAMETER u
  -- (cs.bezierXY) so the steep extremes stay smooth instead of notching; 2/3/4 are y=ease(x).
  for i = 1, #points - 1 do
    local a, b = points[i], points[i + 1]
    local ax, ay = toScreen(a.x, a.y, x0, y0, w, hgt)
    local bx, by = toScreen(b.x, b.y, x0, y0, w, hgt)
    local sh = a.shape or 1
    if sh == 1 then
      reaper.ImGui_DrawList_AddLine(dl, ax, ay, bx, by, CURVE, 2)
    elseif sh == 0 then                                          -- step: hold at a.y, then jump at b.x
      reaper.ImGui_DrawList_AddLine(dl, ax, ay, bx, ay, CURVE, 2)
      reaper.ImGui_DrawList_AddLine(dl, bx, ay, bx, by, CURVE, 2)
    else
      local px, py = ax, ay
      for s = 1, 32 do
        local qx, qy
        if sh == 5 then
          local xf, yf = cs.bezierXY(s / 32, a.tension or 0)
          qx, qy = toScreen(a.x + (b.x - a.x) * xf, a.y + (b.y - a.y) * yf, x0, y0, w, hgt)
        else
          local t = s / 32
          qx, qy = toScreen(a.x + (b.x - a.x) * t, a.y + (b.y - a.y) * ease(sh, t, a.tension or 0), x0, y0, w, hgt)
        end
        reaper.ImGui_DrawList_AddLine(dl, px, py, qx, qy, CURVE, 2)
        px, py = qx, qy
      end
    end
  end
  -- draw point handles
  for i, p in ipairs(points) do
    local sx, sy = toScreen(p.x, p.y, x0, y0, w, hgt)
    reaper.ImGui_DrawList_AddCircleFilled(dl, sx, sy, (i == hotPt) and 5 or 3.5, (i == hotPt) and PTHOT or PT)
  end

  return changed
end

-- Test seams (underscore = not public): the pure coordinate + snap helpers, callable without ImGui so
-- the data<->screen mapping and grid snapping can be unit-tested directly (tests/test_drawpad.lua).
M._toScreen = toScreen   -- (px,py,x0,y0,w,hgt) -> sx,sy
M._toData   = toData     -- (sx,sy,x0,y0,w,hgt) -> px,py  (clamped to [0,1]x[-1,1])
M._snapTo   = snapTo     -- (v,lo,hi,divs) -> nearest grid value

return M
