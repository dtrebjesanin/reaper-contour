-- tests/test_gen_tempomap.lua — Musical-rate LFOs must follow the TEMPO MAP, not the tempo sampled
-- once at the span start. The old single seconds-per-cycle kept 120-BPM cycles running after a
-- mid-selection tempo change to 60 BPM: the "1/4-note" LFO pumped in eighths and every cycle after
-- the marker drifted off the grid. Musical mode now generates on the QN AXIS (cycle boundaries an
-- exact number of quarter notes apart by construction) and converts each point through the map.
-- Hz mode stays on the seconds axis: 2 Hz means 2 per second at any tempo.
-- Piecewise map here: 120 BPM until t=4s (QN 8), then 60 BPM (1 QN per second).
package.path = package.path .. ";./Contour/?.lua;./?.lua;./tests/?.lua"

local stub = require("reaper_stub")
stub.install()

reaper.TimeMap2_timeToQN = function(_p, t) if t <= 4 then return t * 2 end return 8 + (t - 4) end
reaper.TimeMap2_QNToTime = function(_p, q) if q <= 8 then return q / 2 end return 4 + (q - 8) end
reaper.GetSet_LoopTimeRange = function() return 0.0, 8.0 end

local h = require("harness")
local generate = require("ui.generate")

local function detEnv()
  return { target = "envelope", label = "Envelope", hasTimeSel = true, t0 = 0, t1 = 8,
           details = { env = "ENV" } }
end

-- Panel state: SAW (sparse corner emitter — its corners sit exactly on cycle boundaries) at
-- Musical rate, 1 QN per cycle (1/4 note, Straight, freq 2: 8 * 1/4 * 1 / 2 = 1).
local function musicalG()
  return {
    shapeIdx = 3, rateMode = 0, cycles = 4, hz = 2,
    lengthIdx = 6, feelIdx = 0, freqIdx = 9,
    baseline = 0, amplitude = 100, tilt = 0, tiltR = 0, phase = 0,
    ampSkew = 0, pulseWidth = 0.5, freqSkew = 0, swing = 0, seed = 1,
    smooth = 0, steps = 0, curve = 0, attack = 50, edge = 50,
  }
end

h.test("musical cycles land on the beat grid across a tempo change", function()
  stub.reset()
  generate.run({}, detEnv(), musicalG())
  local ts = {}
  for _, p in ipairs(stub.rec.ins) do ts[#ts + 1] = p.t end
  table.sort(ts)
  h.truthy(#ts > 4, "points written, got " .. tostring(#ts))
  h.truthy(ts[#ts] > 7.9, "span end reached, last point at " .. tostring(ts[#ts]))
  for _, t in ipairs(ts) do
    local qn = reaper.TimeMap2_timeToQN(0, t)
    local dist = math.abs(qn - math.floor(qn + 0.5))
    h.truthy(dist < 0.01, ("point at t=%.4f sits at QN %.4f - off the 1-QN cycle grid"):format(t, qn))
  end
end)

h.test("Hz rate ignores the tempo map (2 Hz stays 0.5s cycles after the change)", function()
  stub.reset()
  local g = musicalG()
  g.rateMode = 2; g.hz = 2
  generate.run({}, detEnv(), g)
  local found = false
  for _, p in ipairs(stub.rec.ins) do if p.t > 4.4 and p.t < 4.6 then found = true end end
  h.truthy(found, "a 0.5s-grid corner must exist after the tempo change (t ~ 4.5)")
end)

h.run()
