-- tests/test_cc_channel.lua — the CC target must operate on the MIDI channel the lane's data actually
-- lives on (hardware controllers and imported MIDI routinely use channels other than 1), falling back
-- to the editor's default insert channel when the lane is empty or mixed. Hardcoding channel 1 made
-- Reduce report "No points to reduce" on a visibly full lane, gave Transform an empty scope, and made
-- Generate write a second interleaved channel-1 stream the user's synth never receives.
package.path = package.path .. ";./Contour/?.lua;./?.lua;./tests/?.lua"

local stub = require("reaper_stub")
stub.install()

local h = require("harness")
local target = require("core.target")

local function detCC()
  return { target = "cc", label = "CC1", hasTimeSel = true, t0 = 0, t1 = 4,
           details = { take = "TAKE", midiEditor = "ME" } }
end

h.test("lane data on channel 2: target adopts channel 2 and reads the points", function()
  stub.reset()
  stub.ccList = {
    { ppq = 100, chan = 2, lane = 1, val = 64, shape = 1, tension = 0, sel = true },
    { ppq = 300, chan = 2, lane = 1, val = 90, shape = 1, tension = 0, sel = true },
  }
  local tgt, err = target.fromContext(detCC())
  h.truthy(tgt, "fromContext: " .. tostring(err))
  h.eq(tgt:channel(), 2, "channel follows the lane's data")
  h.eq(#tgt:read(0, 4), 2, "read sees the channel-2 events")
end)

h.test("default channel-1 lane still resolves to channel 0 (regression)", function()
  stub.reset()   -- stock fixture: two events on chan 0
  local tgt = target.fromContext(detCC())
  h.eq(tgt:channel(), 0)
  h.eq(#tgt:read(0, 4), 2)
end)

h.test("empty lane: falls back to the editor's default insert channel, and write stamps it", function()
  stub.reset()
  stub.ccList = {}
  stub.DEFAULT_CHAN = 3
  local tgt = target.fromContext(detCC())
  h.eq(tgt:channel(), 3, "empty lane uses default_note_chan")
  local n, werr = tgt:write({ { time = 1.0, value = 64 } }, 0, 4)
  h.truthy(n == 1, "write ok: " .. tostring(werr))
  h.eq(stub.ccList[1].chan, 3, "written event carries the resolved channel")
end)

h.test("mixed-channel lane: no silent single-channel guess - editor default wins", function()
  stub.reset()
  stub.ccList = {
    { ppq = 100, chan = 0, lane = 1, val = 64, shape = 1, tension = 0, sel = true },
    { ppq = 300, chan = 2, lane = 1, val = 90, shape = 1, tension = 0, sel = true },
  }
  stub.DEFAULT_CHAN = 0
  local tgt = target.fromContext(detCC())
  h.eq(tgt:channel(), 0)
end)

h.test("mixed lane where the editor default has NO data: the dominant channel wins", function()
  stub.reset()
  stub.ccList = {
    { ppq = 100, chan = 5, lane = 1, val = 64, shape = 1, tension = 0, sel = true },
    { ppq = 200, chan = 2, lane = 1, val = 70, shape = 1, tension = 0, sel = true },
    { ppq = 300, chan = 2, lane = 1, val = 90, shape = 1, tension = 0, sel = true },
  }
  stub.DEFAULT_CHAN = 0                     -- default channel holds nothing on this lane
  h.eq(target.fromContext(detCC()):channel(), 2, "majority channel, not an empty default")
end)

h.test("panel retarget: the channel follows the PINNED write lane, not the clicked lane", function()
  stub.reset()
  stub.ccList = {
    { ppq = 100, chan = 2, lane = 1,  val = 64, shape = 1, tension = 0, sel = true },  -- clicked lane
    { ppq = 300, chan = 5, lane = 11, val = 90, shape = 1, tension = 0, sel = true },  -- panel target
  }
  local tgt = target.fromContext(detCC())   -- clicked lane 1 -> channel 2
  h.eq(tgt:channel(), 2)
  tgt._lane = 11                            -- the panel pins its CC# (ui/generate.lua does this)
  h.eq(tgt:channel(), 5, "re-resolved for the write lane")
  local n, werr = tgt:write({ { time = 1.0, value = 64 } }, 0, 4)
  h.truthy(n == 1, "write ok: " .. tostring(werr))
  local last = stub.ccList[#stub.ccList]
  h.eq(last.chan, 5, "written on the write lane's channel, not the clicked lane's")
end)

h.run()
