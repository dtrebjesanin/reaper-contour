-- ui/drawpad.lua — in-panel custom-shape draw pad (ReaImGui DrawList). Edits a points list in place:
--   click empty -> add point; drag point -> move; right-click / double-click point -> delete
--   (endpoints x are pinned to 0/1, y movable); drag a segment's middle -> bend it (bezier tension).
-- Pure-ish: no ExtState; the caller owns persistence. Guarded so it no-ops if DrawList APIs are absent.
local M = {}
local cs = require("core.customshape")
local floor, abs, min, max = math.floor, math.abs, math.min, math.max

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

-- bezier value-fraction model (matches the engine's freq-skew quadratic; calibrate vs REAPER bezier)
local function ease(shape, t, ten)
  if shape == 5 then return t + ten * t * (1 - t) end
  if shape == 2 then return (1 - math.cos(math.pi * t)) / 2 end
  if shape == 3 then return math.sin(math.pi * t / 2) end
  if shape == 4 then return 1 - math.cos(math.pi * t / 2) end
  return t
end

function M.draw(ctx, points, opts)
  opts = opts or {}
  if not (reaper.ImGui_GetWindowDrawList and reaper.ImGui_DrawList_AddLine and reaper.ImGui_InvisibleButton
      and reaper.ImGui_GetCursorScreenPos and reaper.ImGui_GetMousePos) then
    reaper.ImGui_Text(ctx, "(draw pad needs a newer ReaImGui)"); return false
  end
  local w = opts.width or 360
  local hgt = opts.height or 140
  local x0, y0 = reaper.ImGui_GetCursorScreenPos(ctx)
  reaper.ImGui_InvisibleButton(ctx, opts.id or "##drawpad", w, hgt)
  local hovered = reaper.ImGui_IsItemHovered(ctx)
  local active = reaper.ImGui_IsItemActive(ctx)
  local mx, my = reaper.ImGui_GetMousePos(ctx)
  local dl = reaper.ImGui_GetWindowDrawList(ctx)
  local changed = false

  -- background + grid
  reaper.ImGui_DrawList_AddRectFilled(dl, x0, y0, x0 + w, y0 + hgt, BG, 4)
  for i = 0, 4 do local gx = x0 + i / 4 * w; reaper.ImGui_DrawList_AddLine(dl, gx, y0, gx, y0 + hgt, GRID, 1) end
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

  -- begin gestures on mouse-down
  if active and reaper.ImGui_IsMouseClicked(ctx, 0) then
    if hotPt then drag.idx, drag.seg = hotPt, nil
    else
      -- segment under cursor? (between two points, away from a point) -> bend; else add a point
      local seg = nil
      for i = 1, #points - 1 do
        local ax, ay = toScreen(points[i].x, points[i].y, x0, y0, w, hgt)
        local bx, by = toScreen(points[i + 1].x, points[i + 1].y, x0, y0, w, hgt)
        if mx >= min(ax, bx) - 2 and mx <= max(ax, bx) + 2 then
          local t = (bx - ax ~= 0) and (mx - ax) / (bx - ax) or 0
          local ly = ay + (by - ay) * t
          if abs(my - ly) <= 8 then seg = i; break end
        end
      end
      if seg then drag.idx, drag.seg = nil, seg
      else
        local nx, ny = toData(mx, my, x0, y0, w, hgt)
        points[#points + 1] = { x = nx, y = ny, shape = 1, tension = 0 }
        local clamped = cs.clampPoints(points)
        for k = #points, 1, -1 do points[k] = nil end
        for k = 1, #clamped do points[k] = clamped[k] end
        changed = true; drag.idx, drag.seg = nil, nil
      end
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
        if drag.idx == 1 then nx = 0 elseif drag.idx == #points then nx = 1
        else nx = max(points[drag.idx - 1].x + 1e-3, min(points[drag.idx + 1].x - 1e-3, nx)) end
        p.x, p.y = nx, ny; changed = true
      end
    elseif drag.seg then
      local a, b = points[drag.seg], points[drag.seg + 1]
      if a and b then
        local ax, ay = toScreen(a.x, a.y, x0, y0, w, hgt)
        local bx, by = toScreen(b.x, b.y, x0, y0, w, hgt)
        local midY = (ay + by) / 2
        local ten = max(-1, min(1, (midY - my) / (hgt / 2)))   -- drag up -> +tension
        a.shape = (abs(ten) > 1e-3) and 5 or 1; a.tension = ten; changed = true
      end
    end
  end
  if not reaper.ImGui_IsMouseDown(ctx, 0) then drag.idx, drag.seg = nil, nil end

  -- draw the curve (sample each segment by its ease)
  for i = 1, #points - 1 do
    local a, b = points[i], points[i + 1]
    local ax, ay = toScreen(a.x, a.y, x0, y0, w, hgt)
    local bx, by = toScreen(b.x, b.y, x0, y0, w, hgt)
    local steps = (a.shape == 1) and 1 or 16
    local px, py = ax, ay
    for s = 1, steps do
      local t = s / steps
      local yv = a.y + (b.y - a.y) * ease(a.shape or 1, t, a.tension or 0)
      local qx, qy = toScreen(a.x + (b.x - a.x) * t, yv, x0, y0, w, hgt)
      reaper.ImGui_DrawList_AddLine(dl, px, py, qx, qy, CURVE, 2)
      px, py = qx, qy
    end
  end
  -- draw point handles
  for i, p in ipairs(points) do
    local sx, sy = toScreen(p.x, p.y, x0, y0, w, hgt)
    reaper.ImGui_DrawList_AddCircleFilled(dl, sx, sy, (i == hotPt) and 5 or 3.5, (i == hotPt) and PTHOT or PT)
  end

  return changed
end

return M
