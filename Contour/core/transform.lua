-- core/transform.lua — PURE geometric transforms for the Transform overlay. Zero reaper.*, headless.
-- Points are arrays of { t=<sec>, v=<value, in the caller's domain>, shape, tension, sel }; transforms
-- PRESERVE the non-coordinate fields and change only t (time ops) or v (value ops). The overlay passes
-- raw envelope STORAGE values; the engine is domain-agnostic.
local M = {}

-- Shared bend curve. x,f in [0,1]; f(0)=0, f(1)=1; monotonic. knob -100..100 (0=linear); shape:
-- "power" => x^w ; "sine" => ((1-cos(pi x))/2)^w. w = 2^(knob/100 * 2.2) so knob 0 => w 1 (straight).
function M.curve(x, knob, shape)
  if x <= 0 then return 0 elseif x >= 1 then return 1 end
  local w = 2 ^ ((knob or 0) / 100 * 2.2)
  if shape == "sine" then
    local s = (1 - math.cos(math.pi * x)) / 2
    return s ^ w
  end
  return x ^ w
end

-- Shallow-copy a point, overriding t and/or v. Pass nil for the axis you are NOT changing. Must use an
-- explicit nil check (not `t or p.t`): a legitimately computed 0 — a point reversed to project start, or a
-- value flipped/scaled to exactly 0 on a pan/pitch/mute lane — is falsy in Lua and would otherwise revert.
local function copy(p, t, v)
  local nt = t; if nt == nil then nt = p.t end
  local nv = v; if nv == nil then nv = p.v end
  return { t = nt, v = nv, shape = p.shape, tension = p.tension, sel = p.sel }
end

-- Stretch positions in time about anchorT by factor: t' = anchorT + factor*(t-anchorT).
function M.stretch(points, anchorT, factor)
  local out = {}
  for i = 1, #points do
    local p = points[i]
    out[i] = copy(p, anchorT + factor * (p.t - anchorT), nil)
  end
  return out
end

-- Scale/Compress values. The dragged boundary edge (boundaryV) moves to targetV; the anchor edge
-- (anchorV, the opposite edge — or the box centre when symmetrical) stays fixed. knob=0 ⇒ affine Scale;
-- knob≠0 ⇒ Compress (the curve weights interior motion toward the boundary). For symmetrical the caller
-- passes anchorV = centre, so the far side (u<0) mirrors via sign(u).
function M.vscale(points, anchorV, boundaryV, targetV, opts)
  opts = opts or {}
  local span = boundaryV - anchorV
  local move = targetV - boundaryV
  local out = {}
  for i = 1, #points do
    local p = points[i]
    local u = (span ~= 0) and (p.v - anchorV) / span or 0
    local s = (u < 0) and -1 or 1
    local a = math.abs(u); if a > 1 then a = 1 end
    local g = M.curve(a, opts.knob, opts.shape)
    out[i] = copy(p, nil, p.v + move * s * g)
  end
  return out
end

-- Tilt values: pivot one end (or dome if symmetrical), distributed across the span by the curve.
function M.tilt(points, tmin, tmax, delta, opts)
  opts = opts or {}
  local span = (tmax - tmin)
  local out = {}
  for i = 1, #points do
    local p = points[i]
    local relT = span > 0 and (p.t - tmin) / span or 0
    if relT < 0 then relT = 0 elseif relT > 1 then relT = 1 end
    local g
    if opts.symmetrical then
      g = M.curve(1 - math.abs(2 * relT - 1), opts.knob, opts.shape)
    elseif opts.side == "left" then
      g = M.curve(1 - relT, opts.knob, opts.shape)
    else
      g = M.curve(relT, opts.knob, opts.shape)
    end
    out[i] = copy(p, nil, p.v + delta * g)
  end
  return out
end

-- Tent weight: 1 at relT==c, 0 at relT 0 and 1, curve-shaped on each side. A cursor at an edge
-- (c<=0 or c>=1) is handled explicitly so that edge becomes the peak (not a pinned, zero-weight point).
local function tent(relT, c, knob, shape)
  local x
  if c <= 0 then
    -- Peak at left edge
    x = 1 - relT
  elseif c >= 1 then
    -- Peak at right edge
    x = relT
  else
    -- Peak in the middle
    x = (relT <= c) and (relT / c) or ((1 - relT) / (1 - c))
  end
  if x < 0 then x = 0 elseif x > 1 then x = 1 end
  return M.curve(x, knob, shape)
end

-- Warp: bend along `axis` ("time"|"value") toward the cursor. The bend peaks at cursorRelT and pins the
-- box's time-edges. Each point moves by delta*weight on the chosen axis. Input is time-ascending; on the
-- time axis the output is kept STRICTLY INCREASING (WARP_EPS) so a hard warp bunches points up against each
-- other instead of folding them past a neighbour (which would leave reversed/coincident points).
local WARP_EPS = 1e-9
function M.warp(points, axis, tmin, tmax, cursorRelT, delta, opts)
  opts = opts or {}
  local span = tmax - tmin
  local out, lastT = {}, nil
  for i = 1, #points do
    local p = points[i]
    local relT = (span > 0) and (p.t - tmin) / span or 0
    if relT < 0 then relT = 0 elseif relT > 1 then relT = 1 end
    local w = tent(relT, cursorRelT, opts.knob, opts.shape)
    if axis == "time" then
      local nt = p.t + delta * w
      if lastT and nt <= lastT then nt = lastT + WARP_EPS end
      lastT = nt
      out[i] = copy(p, nt, nil)
    else
      out[i] = copy(p, nil, p.v + delta * w)
    end
  end
  return out
end

-- Warp BOTH axes at once: the same tent weight (peaking at cursorRelT, edges pinned) drives t by deltaT and
-- v by deltaV, so the point under the cursor follows it in 2D. Times stay strictly increasing (no folding).
-- The overlay uses warp2d; single-axis M.warp above is the constrained variant (currently test-only).
function M.warp2d(points, tmin, tmax, cursorRelT, deltaT, deltaV, opts)
  opts = opts or {}
  local span = tmax - tmin
  local out, lastT = {}, nil
  for i = 1, #points do
    local p = points[i]
    local relT = (span > 0) and (p.t - tmin) / span or 0
    if relT < 0 then relT = 0 elseif relT > 1 then relT = 1 end
    local w = tent(relT, cursorRelT, opts.knob, opts.shape)
    local nt = p.t + deltaT * w
    if lastT and nt <= lastT then nt = lastT + WARP_EPS end
    lastT = nt
    out[i] = copy(p, nt, p.v + deltaV * w)
  end
  return out
end

-- Mirror positions in time about the box: t' = tmin+tmax-t. One-shot.
function M.reverse(points, tmin, tmax)
  local out = {}
  for i = 1, #points do out[i] = copy(points[i], tmin + tmax - points[i].t, nil) end
  return out
end

-- Mirror values about (lo+hi)/2: v' = lo+hi-v. lo/hi = lane range (absolute) or selection range (relative).
function M.flip(points, lo, hi)
  local out = {}
  for i = 1, #points do out[i] = copy(points[i], nil, lo + hi - points[i].v) end
  return out
end

-- Shallow-clone a point, optionally overriding any fields via the `overrides` table.
-- Copies every field present on `p` (including idx, sel, etc.) so callers never silently
-- drop fields they didn't know about. overrides is merged in after the copy; pass nil to
-- get a plain clone.
function M.clonePoint(p, overrides)
  local out = {}
  for k, v in pairs(p) do out[k] = v end
  if overrides then for k, v in pairs(overrides) do out[k] = v end end
  return out
end

return M
