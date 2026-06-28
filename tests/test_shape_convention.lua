-- tests/test_shape_convention.lua — regression guard that the CC<->envelope linear/step
-- convention stays consistent between core/target.lua and core/reduce.lua.
--
-- Convention recap:
--   CC        : linear = 1,  square/step = 0
--   Envelope  : linear = 0,  square/step = 1
--   Shapes 2-5: identical in both conventions (slow start/end, fast start, fast end, bezier)
--
-- target.CC_TO_ENV_SHAPE is the single-source table; reduce.thinCurve must emit the same
-- mapping (envConvention=false -> 1; envConvention=true -> 0).

package.path = package.path .. ";./Contour/?.lua;./?.lua;./tests/?.lua"

-- Minimal reaper stub so core/target.lua loads headlessly (its require('core.midistream')
-- still needs the stub before the module file is loaded).
_G.reaper = {
  GetEnvelopeScalingMode          = function() return 0 end,
  GetEnvelopeName                  = function() return true, "Pan" end,
  GetSetAutomationItemInfo         = function() return 0.0 end,
  DeleteEnvelopePointRange         = function() end,
  InsertEnvelopePoint              = function() return true end,
  Envelope_SortPoints              = function() end,
  DeleteEnvelopePointRangeEx       = function() end,
  InsertEnvelopePointEx            = function() return true end,
  Envelope_SortPointsEx            = function() end,
  Undo_BeginBlock2                 = function() end,
  Undo_EndBlock2                   = function() end,
  UpdateArrange                    = function() end,
  MIDI_GetPPQPosFromProjTime       = function(_, s) return s * 100 end,
  MIDI_GetProjTimeFromPPQPos       = function(_, p) return p / 100 end,
  MIDI_CountEvts                   = function() return true, 0, 0 end,
  MIDI_GetCC                       = function() return false end,
  CountEnvelopePoints              = function() return 0 end,
  GetEnvelopePoint                 = function() return false end,
  CountEnvelopePointsEx            = function() return 0 end,
  GetEnvelopePointEx               = function() return false end,
}

local h      = require("harness")
local target = require("core.target")
local reduce = require("core.reduce")

-- ── target.CC_TO_ENV_SHAPE invariants ────────────────────────────────────────

h.test("target.CC_TO_ENV_SHAPE is exported", function()
  h.truthy(target.CC_TO_ENV_SHAPE ~= nil, "CC_TO_ENV_SHAPE should be a table on the module")
end)

h.test("target.CC_TO_ENV_SHAPE: CC linear(1) maps to ENV linear(0)", function()
  h.eq(target.CC_TO_ENV_SHAPE[1], 0, "CC linear 1 -> ENV linear 0")
end)

h.test("target.CC_TO_ENV_SHAPE: CC square(0) maps to ENV square(1)", function()
  h.eq(target.CC_TO_ENV_SHAPE[0], 1, "CC square 0 -> ENV square 1")
end)

h.test("target.CC_TO_ENV_SHAPE: shapes 2-5 are absent (pass-through, unchanged)", function()
  -- The table only overrides 0 and 1; callers fall back to the original value for 2..5.
  h.eq(target.CC_TO_ENV_SHAPE[2], nil, "shape 2 not in swap table (pass-through)")
  h.eq(target.CC_TO_ENV_SHAPE[3], nil, "shape 3 not in swap table (pass-through)")
  h.eq(target.CC_TO_ENV_SHAPE[4], nil, "shape 4 not in swap table (pass-through)")
  h.eq(target.CC_TO_ENV_SHAPE[5], nil, "shape 5 not in swap table (pass-through)")
end)

-- ── reduce.thinCurve linear-shape agreement ──────────────────────────────────

-- Helper: run thinCurve on a two-point linear stretch and return the first point's shape.
local function linearShapeFrom(envConvention)
  local pts = {
    { time = 0.0, value = 0.0 },
    { time = 1.0, value = 1.0 },
  }
  local out = reduce.thinCurve(pts, 0, { vmin = 0, vmax = 1 }, { envConvention = envConvention })
  return out[1].shape
end

h.test("reduce.thinCurve emits linear=1 for CC convention (envConvention=false)", function()
  h.eq(linearShapeFrom(false), 1, "CC path: linear shape must be 1")
end)

h.test("reduce.thinCurve emits linear=0 for envelope convention (envConvention=true)", function()
  h.eq(linearShapeFrom(true), 0, "envelope path: linear shape must be 0")
end)

-- ── Cross-agreement: reduce linear int == CC_TO_ENV_SHAPE image of CC-linear ─

h.test("reduce env-linear(0) == CC_TO_ENV_SHAPE[CC-linear(1)]", function()
  -- reduce says CC-linear = 1 (envConvention=false).
  local ccLinear = linearShapeFrom(false)   -- must be 1
  -- CC_TO_ENV_SHAPE maps that 1 -> 0 (ENV linear).
  local envLinearViaTable = target.CC_TO_ENV_SHAPE[ccLinear]
  -- reduce says ENV-linear = 0 (envConvention=true).
  local envLinearViaBranch = linearShapeFrom(true)
  h.eq(envLinearViaTable, envLinearViaBranch,
    "reduce env-linear must equal CC_TO_ENV_SHAPE[reduce cc-linear]")
end)

h.test("reduce cc-linear(1) == CC_TO_ENV_SHAPE image inverted back from env-linear", function()
  -- Both should be consistent: applying CC_TO_ENV_SHAPE twice is identity.
  local ccLinear  = linearShapeFrom(false)   -- 1
  local envLinear = linearShapeFrom(true)    -- 0
  -- The table is its own inverse for 0 and 1 ({[0]=1,[1]=0}).
  h.eq(target.CC_TO_ENV_SHAPE[envLinear], ccLinear,
    "CC_TO_ENV_SHAPE must be self-inverse on 0 and 1")
end)

h.run()
