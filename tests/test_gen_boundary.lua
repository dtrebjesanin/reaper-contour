-- tests/test_gen_boundary.lua — a generated region's LAST point owns the segment LEAVING the time
-- selection, which runs into untouched material (the next kept event). Leaving the LFO's curved ease
-- on it bent that foreign segment: a sine written over bar 3 curved the first triangle ramp of bar 4
-- (user report). The tail point's outgoing shape must be neutralized to LINEAR after generating -
-- but step tails (Square / S&H) keep holding, since a ramp out of a square is its own surprise.
-- Stub geometry: CC item TITEM spans 3..8s (ppq = sec * 100).
package.path = package.path .. ";./Contour/?.lua;./?.lua;./tests/?.lua"

local stub = require("reaper_stub")
stub.install()

local h = require("harness")
local generate = require("ui.generate")

local function detCC(t0, t1)
  return { target = "cc", label = "CC1", hasTimeSel = true, t0 = t0, t1 = t1,
           details = { take = "TAKE", midiEditor = "ME" } }
end
local function detEnv()
  return { target = "envelope", label = "Envelope", hasTimeSel = true, t0 = 0, t1 = 4,
           details = { env = "ENV" } }
end

local function baseG(shapeIdx)
  return {
    shapeIdx = shapeIdx, rateMode = 2, cycles = 4, hz = 1,
    lengthIdx = 6, feelIdx = 0, freqIdx = 8, ccNum = 1,
    baseline = 0, amplitude = 100, tilt = 0, tiltR = 0, phase = 0,
    ampSkew = 0, pulseWidth = 0.5, freqSkew = 0, swing = 0, seed = 1,
    smooth = 0, steps = 0, curve = 0, attack = 50, edge = 50,
    scope = 0,
  }
end

-- The written CC tail: the max-ppq event at or below the span end tick.
local function ccTail(maxTick)
  local tail
  for _, e in ipairs(stub.ccList) do
    if e.ppq <= maxTick and (not tail or e.ppq > tail.ppq) then tail = e end
  end
  return tail
end

h.test("CC: sine over a time selection leaves a LINEAR tail into the kept region", function()
  stub.reset()
  stub.ccList = {
    { ppq = 650, chan = 0, lane = 1, val = 127, shape = 1, tension = 0, sel = false },  -- "bar 4 peak" (kept)
    { ppq = 700, chan = 0, lane = 1, val = 0,   shape = 1, tension = 0, sel = false },
  }
  generate.run({}, detCC(4, 6), baseG(1))          -- sine over [4,6] (inside the 3..8 item)
  local tail = ccTail(600)
  h.truthy(tail ~= nil, "a tail event was written")
  h.eq(tail.shape, 1, "tail outgoing segment is linear, not the sine's curved ease")
  -- the kept region is untouched
  local kept
  for _, e in ipairs(stub.ccList) do if e.ppq == 650 then kept = e end end
  h.truthy(kept and kept.shape == 1 and kept.val == 127, "kept event unchanged")
end)

h.test("CC: square keeps its STEP tail (holds; no ramp into the kept region)", function()
  stub.reset()
  stub.ccList = {
    { ppq = 650, chan = 0, lane = 1, val = 127, shape = 1, tension = 0, sel = false },
  }
  generate.run({}, detCC(4, 6), baseG(5))          -- square
  local tail = ccTail(600)
  h.truthy(tail ~= nil, "a tail event was written")
  h.eq(tail.shape, 0, "square tail keeps the step hold")
end)

h.test("envelope: sine tail converts to the envelope convention's linear (0)", function()
  stub.reset()
  generate.run({}, detEnv(), baseG(1))
  local tail
  for _, p in ipairs(stub.rec.ins) do if not tail or p.t > tail.t then tail = p end end
  h.truthy(tail ~= nil, "envelope points written")
  h.eq(tail.shape, 0, "tail is envelope-linear, not the sine ease")
end)

h.run()
