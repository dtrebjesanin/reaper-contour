-- tests/test_env_chunk.lua — envelope TYPE must come from the state chunk's header token
-- (<VOLENV2/<PANENV/<PITCHENV/<PARMENV...), which langpacks never translate, NOT from the localized
-- display name. Name-substring matching misclassified every built-in lane on non-English installs
-- (German Volume = "Lautstaerke" matched nothing -> wrong range) and hijacked FX parameters whose
-- names merely contain a keyword (ReaEQ "Bandwidth" contains "width" -> forced to -1..1 on a 0..1
-- lane). PARMENV headers carry the parameter's real min/max, so FX params no longer depend on SWS.
package.path = package.path .. ";./Contour/?.lua;./?.lua;./tests/?.lua"

local stub = require("reaper_stub")
stub.install()

local h = require("harness")
local target = require("core.target")

local function detEnv()
  return { target = "envelope", label = "Envelope", hasTimeSel = true, t0 = 0, t1 = 4, details = { env = "ENV" } }
end

local CFG = {}
reaper.get_config_var_string = function(name)
  if CFG[name] ~= nil then return true, tostring(CFG[name]) end
  return false
end
local function withChunk(chunk) reaper.GetEnvelopeStateChunk = function() return true, chunk end end

h.test("localized volume envelope: chunk token wins over the translated name", function()
  reaper.GetEnvelopeName = function() return true, "Lautst\228rke" end   -- German langpack
  withChunk("<VOLENV2\nEGUID {X}\nACT 1 -1\nPT 0 1 0\n>")
  CFG.volenvrange = 4                                                    -- +12 dB -> linear top 4
  local lo, hi = target.fromContext(detEnv()):valueRange()
  h.almost(lo, 0); h.almost(hi, 4, 1e-9, "volume range despite non-English name")
end)

h.test("localized pitch envelope: chunk token routes to pitchenvrange", function()
  reaper.GetEnvelopeName = function() return true, "Tonh\246he" end
  withChunk("<PITCHENV\nACT 1 -1\n>")
  CFG.pitchenvrange = 24
  local lo, hi = target.fromContext(detEnv()):valueRange()
  h.almost(lo, -24); h.almost(hi, 24)
end)

h.test("FX parameter containing 'width': PARMENV real range wins over the name keyword", function()
  reaper.GetEnvelopeName = function() return true, "Bandwidth-Band 1 (oct) / ReaEQ" end
  withChunk("<PARMENV 3 0.000000 1.000000 0.500000\nACT 1 -1\n>")
  local lo, hi = target.fromContext(detEnv()):valueRange()
  h.almost(lo, 0, 1e-9, "param floor, not -1"); h.almost(hi, 1)
end)

h.test("FX parameter named 'Pitch': PARMENV range, not semitones", function()
  reaper.GetEnvelopeName = function() return true, "Pitch / ReaSamplOmatic5000" end
  withChunk("<PARMENV 0:wet 0.250000 0.750000 0.500000\nACT 1 -1\n>")
  CFG.pitchenvrange = 24
  local lo, hi = target.fromContext(detEnv()):valueRange()
  h.almost(lo, 0.25); h.almost(hi, 0.75)
end)

h.test("no chunk API (old builds/stubs): English name fallback still classifies", function()
  reaper.GetEnvelopeStateChunk = nil
  reaper.GetEnvelopeName = function() return true, "Pan" end
  local lo, hi = target.fromContext(detEnv()):valueRange()
  h.almost(lo, -1); h.almost(hi, 1)
end)

h.test("range is cached per target: the live loop must not re-fetch the chunk every frame", function()
  reaper.GetEnvelopeName = function() return true, "Volume" end
  local fetches = 0
  reaper.GetEnvelopeStateChunk = function() fetches = fetches + 1; return true, "<VOLENV2\n>" end
  local tgt = target.fromContext(detEnv())
  for _ = 1, 5 do tgt:valueRange() end      -- liveBulkWrite calls this once per frame
  h.eq(fetches, 1, "one chunk fetch per target, not per frame")
end)

h.run()
