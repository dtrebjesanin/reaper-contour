-- tests/test_env_range.lua — envelope value ranges must reflect REAPER's CONFIG VARS (the same source
-- SWS LaneMin/LaneMaxValue uses): "pitchenvrange" (semitones in the LOW byte; snap lives higher) and
-- "volenvrange" (bit1 = fader scaling; the rest selects 0dB/+6/+12/+24 dB -> linear 1/2/4/16), with
-- fader-scaled volume converted to the STORAGE domain. NOTE: SWS BR_EnvGetProperties is NOT usable for
-- named envelopes — it returns hardcoded chunk-type values (volume 0..2, pitch ±255), which is exactly
-- what broke the first attempt (phantom ±255 pitch range; vanished volume overlay under fader scaling).
package.path = package.path .. ";./Contour/?.lua;./?.lua;./tests/?.lua"

local stub = require("reaper_stub")
stub.install()

local h = require("harness")
local target = require("core.target")

local function detEnv()
  return { target = "envelope", label = "Envelope", hasTimeSel = true, t0 = 0, t1 = 4, details = { env = "ENV" } }
end
local function detTake()
  return { target = "envelope", label = "Take envelope", hasTimeSel = true, t0 = 3, t1 = 8,
           details = { env = "TENV", take = "TAKE" } }
end

local CFG = {}
reaper.get_config_var_string = function(name)
  if CFG[name] ~= nil then return true, tostring(CFG[name]) end
  return false
end

h.test("pitch range follows pitchenvrange (24 semitones, snap bits in the high byte masked off)", function()
  reaper.GetEnvelopeName = function() return true, "Pitch" end
  CFG.pitchenvrange = 24 | (1 << 8)              -- range 24 + a snap setting in the high bits
  local lo, hi = target.fromContext(detEnv()):valueRange()
  h.almost(lo, -24); h.almost(hi, 24)
end)

h.test("take pitch envelopes get the same range (the reported case)", function()
  reaper.GetEnvelopeName = function() return true, "Pitch" end
  CFG.pitchenvrange = 24
  local tgt = target.fromContext(detTake())
  h.eq(tgt:kind(), "takeenv")
  local lo, hi = tgt:valueRange()
  h.almost(lo, -24); h.almost(hi, 24)
end)

h.test("volume ceiling follows volenvrange: +12 dB -> 4, +24 dB -> 16, 0 dB -> 1", function()
  reaper.GetEnvelopeName = function() return true, "Volume" end
  CFG.volenvrange = 4
  local _, hi = target.fromContext(detEnv()):valueRange()
  h.almost(hi, 4)
  CFG.volenvrange = 5
  _, hi = target.fromContext(detEnv()):valueRange()
  h.almost(hi, 16)
  CFG.volenvrange = 1
  _, hi = target.fromContext(detEnv()):valueRange()
  h.almost(hi, 1)
end)

h.test("fader-scaled volume converts the range to the STORAGE domain (the vanished-overlay bug)", function()
  reaper.GetEnvelopeName = function() return true, "Volume" end
  CFG.volenvrange = 7                            -- +24 dB with the fader-scaling bit set
  local savedMode, savedScale = reaper.GetEnvelopeScalingMode, reaper.ScaleToEnvelopeMode
  reaper.GetEnvelopeScalingMode = function() return 1 end
  reaper.ScaleToEnvelopeMode = function(_m, v) return v * 100 end   -- stand-in storage conversion
  local lo, hi = target.fromContext(detEnv()):valueRange()
  reaper.GetEnvelopeScalingMode, reaper.ScaleToEnvelopeMode = savedMode, savedScale
  h.almost(lo, 0)
  h.almost(hi, 1600, 1e-6, "linear 16 -> storage via ScaleToEnvelopeMode")
end)

h.test("no config API: defaults hold (volume 0..2, pitch ±3, pan -1..1)", function()
  reaper.get_config_var_string = function() return false end
  reaper.GetEnvelopeName = function() return true, "Volume" end
  local lo, hi = target.fromContext(detEnv()):valueRange()
  h.almost(lo, 0); h.almost(hi, 2)
  reaper.GetEnvelopeName = function() return true, "Pitch" end
  lo, hi = target.fromContext(detEnv()):valueRange()
  h.almost(lo, -3); h.almost(hi, 3)
  reaper.GetEnvelopeName = function() return true, "Pan" end
  lo, hi = target.fromContext(detEnv()):valueRange()
  h.almost(lo, -1); h.almost(hi, 1)
  reaper.get_config_var_string = function(name)
    if CFG[name] ~= nil then return true, tostring(CFG[name]) end
    return false
  end
end)

h.test("unknown envelope names still use SWS BR properties (FX parameter envelopes)", function()
  reaper.GetEnvelopeName = function() return true, "Wet / Dry" end
  reaper.BR_EnvAlloc = function() return "BR" end
  reaper.BR_EnvGetProperties = function() return true, true, true, false, 0, 0, 0.25, 0.75, 0.5, 0, false end
  reaper.BR_EnvFree = function() end
  local lo, hi = target.fromContext(detEnv()):valueRange()
  h.almost(lo, 0.25); h.almost(hi, 0.75)
end)

h.run()
