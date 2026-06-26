package.path = package.path .. ";./Contour/?.lua;./?.lua;./tests/?.lua"
local h = require("harness")
local ms = require("core.midistream")

local spack = string.pack
local FMT = "<i4Bs4"

-- Helpers to build a real REAPER-format buffer with string.pack ------------------

-- Build one packed event from an ABSOLUTE ppq list (we compute deltas here).
local function buildBlob(events, eot)
  -- events: array of { ppq=abs, flags=int, msg=bytestring } (assumed pre-sorted)
  local out = {}
  local last = 0
  for _, ev in ipairs(events) do
    out[#out + 1] = spack(FMT, ev.ppq - last, ev.flags, ev.msg)
    last = ev.ppq
  end
  out[#out + 1] = eot
  return table.concat(out)
end

-- Standard end-of-take sentinel bytes (offset 0, flags 0, All-Notes-Off on ch0).
local EOT = spack(FMT, 0, 0x00, string.char(0xB0, 0x7B, 0x00))

-- Message constructors.
local function noteOn(ch, pitch, vel)  return string.char(0x90 | ch, pitch, vel) end
local function noteOff(ch, pitch, vel) return string.char(0x80 | ch, pitch, vel) end
local function cc(ch, lane, val)       return string.char(0xB0 | ch, lane, val) end

-- PERF FAST PATH: encodeMerged(splitForRange(...)) MUST be byte-identical to the old
-- encode(replaceCCInRange(...)). This guards the live-path optimization against drift.
h.test("splitForRange+encodeMerged == replaceCCInRange+encode (byte-identical)", function()
  local lane, chan = 1, 0
  local events = {
    { ppq = 0,    flags = 0x00,               msg = noteOn(0, 60, 100) },
    { ppq = 0,    flags = ms.CCSHAPE_BITS[1],  msg = cc(0, lane, 64) },   -- our lane, in range
    { ppq = 120,  flags = ms.CCSHAPE_BITS[0],  msg = cc(0, 11, 30) },     -- other lane, in range
    { ppq = 240,  flags = ms.CCSHAPE_BITS[5],  msg = cc(0, lane, 100) },  -- our lane, in range (+ CCBZ)
    { ppq = 240,  flags = 0x00,                msg = string.char(0xFF) .. "CCBZ \0\0\0\0" }, -- bezier meta
    { ppq = 480,  flags = ms.CCSHAPE_BITS[1],  msg = cc(0, lane, 20) },   -- our lane, OUT of range
    { ppq = 600,  flags = 0x00,                msg = noteOff(0, 60, 0) },
  }
  local snap = { events = events, eot = EOT }
  local ppq0, ppq1 = 0, 300
  local newCCs = {
    { ppq = 50,  value = 10,  shape = 2 },
    { ppq = 200, value = 90,  shape = 4 },
    { ppq = 130, value = 55,  shape = 3 },   -- intentionally out of ppq order
  }
  -- Old path:
  local oldBlob = ms.encode(ms.replaceCCInRange(snap, chan, lane, ppq0, ppq1, newCCs))
  -- New fast path:
  local split = ms.splitForRange(snap, chan, lane, ppq0, ppq1)
  local newBlob = ms.encodeMerged(split.kept, chan, lane, newCCs, split.eot)
  h.eq(newBlob, oldBlob, "merged fast path must be byte-identical to replace+encode")
end)

-- (1) ROUND TRIP: notes + CC lane A + CC lane B + end marker survives decode->encode.
h.test("round-trip preserves note-pair + two-lane CC + end marker", function()
  local lane = 1   -- mod wheel
  local laneB = 11 -- expression
  local events = {
    { ppq = 0,    flags = 0x00,         msg = noteOn(0, 60, 100) },
    { ppq = 0,    flags = ms.CCSHAPE_BITS[1], msg = cc(0, lane, 64) },  -- linear shape
    { ppq = 120,  flags = ms.CCSHAPE_BITS[0], msg = cc(0, laneB, 30) }, -- step shape, other lane
    { ppq = 240,  flags = ms.CCSHAPE_BITS[5], msg = cc(0, lane, 100) }, -- bezier shape
    { ppq = 480,  flags = 0x00,         msg = noteOff(0, 60, 0) },
  }
  local blob = buildBlob(events, EOT)

  local dec = ms.decode(blob)
  h.eq(#dec.events, 5, "event count")
  h.eq(dec.eot, EOT, "eot captured verbatim")

  -- byte-identical re-encode (events are already sorted by ppq & stable)
  local re = ms.encode(dec)
  h.eq(re, blob, "encode(decode(blob)) is byte-identical")
end)

-- absolute<->delta conversion correctness.
h.test("decode converts deltas to absolute ppq", function()
  local events = {
    { ppq = 0,   flags = 0, msg = cc(0, 1, 10) },
    { ppq = 100, flags = 0, msg = cc(0, 1, 20) },
    { ppq = 350, flags = 0, msg = cc(0, 1, 30) },  -- delta 250
  }
  local blob = buildBlob(events, EOT)
  local dec = ms.decode(blob)
  h.eq(dec.events[1].ppq, 0)
  h.eq(dec.events[2].ppq, 100)
  h.eq(dec.events[3].ppq, 350)

  -- And the flags/shape nibble survives intact for a shaped CC.
  local shaped = { { ppq = 0, flags = ms.CCSHAPE_BITS[5], msg = cc(2, 7, 64) } }
  local d2 = ms.decode(buildBlob(shaped, EOT))
  h.eq(d2.events[1].flags, 0x50, "bezier nibble preserved")
end)

-- (2) replaceCCInRange removes only target lane+chan in range; keeps everything else.
h.test("replaceCCInRange drops only target lane+chan in range", function()
  local lane = 1
  local laneB = 11
  local events = {
    { ppq = 0,   flags = 0, msg = noteOn(0, 60, 100) },          -- KEEP note
    { ppq = 50,  flags = 0, msg = cc(0, lane, 10) },             -- DROP (lane, in range)
    { ppq = 100, flags = 0, msg = cc(0, laneB, 11) },            -- KEEP (other lane)
    { ppq = 150, flags = 0, msg = cc(1, lane, 12) },             -- KEEP (other chan)
    { ppq = 200, flags = 0, msg = cc(0, lane, 13) },             -- DROP (lane, in range)
    { ppq = 900, flags = 0, msg = cc(0, lane, 14) },             -- KEEP (lane, OUT of range)
    { ppq = 480, flags = 0, msg = noteOff(0, 60, 0) },           -- KEEP note
  }
  local dec = ms.decode(buildBlob(events, EOT))

  local newCCs = {
    { ppq = 60,  value = 70, shape = 1 },
    { ppq = 160, value = 80, shape = 1 },
  }
  local res = ms.replaceCCInRange(dec, 0, lane, 0, 500, newCCs)

  -- Count surviving originals: 2 notes + otherLane + otherChan + outOfRange = 5; + 2 new = 7
  h.eq(#res.events, 7, "kept everything except 2 dropped + 2 new")
  h.eq(res.eot, EOT, "end marker preserved through replace")

  -- No remaining ch0/lane CC inside [0,500].
  local insideCount = 0
  for _, ev in ipairs(res.events) do
    if ms._isCCOnLaneChan(ev.msg, 0, lane) and ev.ppq >= 0 and ev.ppq <= 500 then
      -- must be one of the NEW ones (value 70/80), never the old 10/13
      h.truthy(ev.msg:byte(3) == 70 or ev.msg:byte(3) == 80, "only new CCs remain in range")
      insideCount = insideCount + 1
    end
  end
  h.eq(insideCount, 2, "exactly the two new CCs sit in range")

  -- The out-of-range lane CC (value 14 at ppq 900) survived untouched.
  local found900 = false
  for _, ev in ipairs(res.events) do
    if ev.ppq == 900 and ms._isCCOnLaneChan(ev.msg, 0, lane) then
      h.eq(ev.msg:byte(3), 14); found900 = true
    end
  end
  h.truthy(found900, "out-of-range lane CC kept")

  -- result is sorted by ppq
  local prev = -1
  for _, ev in ipairs(res.events) do
    h.truthy(ev.ppq >= prev, "sorted ascending"); prev = ev.ppq
  end

  -- new CCs carry the requested linear shape nibble (0x10).
  for _, ev in ipairs(res.events) do
    if ev.ppq == 60 or ev.ppq == 160 then h.eq(ev.flags, 0x10, "shape nibble on new CC") end
  end
end)

-- replaceCCInRange also drops the CCBZ meta following a removed bezier CC, and keeps
-- the CCBZ of a CC that is NOT removed.
h.test("replaceCCInRange handles CCBZ bezier meta correctly", function()
  local lane = 1
  local ccbz = string.char(0xFF) .. "CCBZ " .. string.char(0x00) .. spack("<f", 0.5)
  local events = {
    { ppq = 50,  flags = 0x50, msg = cc(0, lane, 64) },   -- DROP (in range bezier CC)
    { ppq = 50,  flags = 0x00, msg = ccbz },              -- DROP (its meta, follows it)
    { ppq = 900, flags = 0x50, msg = cc(0, lane, 64) },   -- KEEP (out of range)
    { ppq = 900, flags = 0x00, msg = ccbz },              -- KEEP (its meta)
  }
  local dec = ms.decode(buildBlob(events, EOT))
  local res = ms.replaceCCInRange(dec, 0, lane, 0, 500, {})
  h.eq(#res.events, 2, "dropped the in-range CC + its CCBZ, kept the out-of-range pair")
  -- the surviving pair are both at 900
  for _, ev in ipairs(res.events) do h.eq(ev.ppq, 900) end
end)

-- (3) full edit cycle: decode -> replace -> encode -> decode reproduces the edit.
h.test("decode->replace->encode->decode is consistent", function()
  local lane = 7
  local events = {
    { ppq = 0,   flags = 0, msg = noteOn(0, 64, 90) },
    { ppq = 100, flags = 0, msg = cc(0, lane, 20) },
    { ppq = 200, flags = 0, msg = cc(0, lane, 40) },
    { ppq = 300, flags = 0, msg = noteOff(0, 64, 0) },
  }
  local dec = ms.decode(buildBlob(events, EOT))
  local res = ms.replaceCCInRange(dec, 0, lane, 50, 250, {
    { ppq = 80,  value = 1, shape = 0 },
    { ppq = 220, value = 2, shape = 0 },
  })
  local blob2 = ms.encode(res)
  local dec2 = ms.decode(blob2)
  h.eq(dec2.eot, EOT, "eot round-tripped through encode")
  -- 2 notes + 2 new CCs = 4
  h.eq(#dec2.events, 4)
  -- ppq order preserved and first event still at 0
  h.eq(dec2.events[1].ppq, 0)
end)

-- (4) EDGE CASES: empty buffer and no-matching-CC are safe.
h.test("empty / eot-only buffer is safe", function()
  -- A buffer that is just the sentinel.
  local dec = ms.decode(EOT)
  h.eq(#dec.events, 0, "no real events")
  h.eq(dec.eot, EOT, "eot preserved")
  local re = ms.encode(dec)
  h.eq(re, EOT, "re-encode of eot-only is byte-identical")

  -- Truly empty string.
  local d0 = ms.decode("")
  h.eq(#d0.events, 0)
  h.eq(d0.eot, "")
  -- encode with no eot synthesizes a standard sentinel.
  local synth = ms.encode(d0)
  local sd = ms.decode(synth)
  h.eq(#sd.events, 0, "synthesized sentinel decodes to zero events")
  h.eq(sd.eot, EOT, "synthesized sentinel equals standard All-Notes-Off")

  -- decode(nil) is safe.
  local dn = ms.decode(nil)
  h.eq(#dn.events, 0)
end)

h.test("replaceCCInRange with no matching CC keeps all events", function()
  local events = {
    { ppq = 0,   flags = 0, msg = noteOn(0, 60, 100) },
    { ppq = 100, flags = 0, msg = cc(0, 11, 50) },   -- lane 11
    { ppq = 480, flags = 0, msg = noteOff(0, 60, 0) },
  }
  local dec = ms.decode(buildBlob(events, EOT))
  -- target lane 1 (nothing matches); empty newCCs.
  local res = ms.replaceCCInRange(dec, 0, 1, 0, 1000, {})
  h.eq(#res.events, 3, "nothing dropped")
  h.eq(res.eot, EOT)

  -- plain-array form (no .events / .eot) returns a plain sorted array.
  local arr = res.events
  local res2 = ms.replaceCCInRange(arr, 0, 1, 0, 1000, {})
  h.truthy(res2.events == nil, "plain array in -> plain array out")
  h.eq(#res2, 3)
end)

-- swapped ppq0/ppq1 range is normalized.
h.test("replaceCCInRange normalizes reversed range", function()
  local lane = 1
  local events = {
    { ppq = 100, flags = 0, msg = cc(0, lane, 10) },
  }
  local dec = ms.decode(buildBlob(events, EOT))
  local res = ms.replaceCCInRange(dec, 0, lane, 500, 0, {})  -- reversed
  h.eq(#res.events, 0, "CC at 100 dropped despite reversed range args")
end)

-- (5) COVERAGE: a sysex event (msg starts with 0xF0) survives a full round trip through
-- decode -> replaceCCInRange (on an UNRELATED lane) -> encode -> decode byte/event-identically.
-- Sysex is not a CC, so isCCOnLaneChan never matches it and it must pass through untouched.
h.test("sysex event survives decode->replace->encode->decode identically", function()
  local lane = 1
  -- A small sysex: F0 7E 7F 09 01 F7 (a GM-on universal message).
  local sysex = string.char(0xF0, 0x7E, 0x7F, 0x09, 0x01, 0xF7)
  local events = {
    { ppq = 0,   flags = 0x00,                msg = noteOn(0, 60, 100) },
    { ppq = 120, flags = 0x00,                msg = sysex },              -- the sysex, mid-stream
    { ppq = 240, flags = ms.CCSHAPE_BITS[0],  msg = cc(0, 5, 77) },       -- CC on lane 5 (unrelated)
    { ppq = 480, flags = 0x00,                msg = noteOff(0, 60, 0) },
  }
  local blob = buildBlob(events, EOT)

  -- Replace lane 1 in range (nothing matches; no new CCs) -> event set is unchanged.
  local dec = ms.decode(blob)
  local res = ms.replaceCCInRange(dec, 0, lane, 0, 1000, {})
  local re = ms.encode(res)
  h.eq(re, blob, "sysex round-trips byte-identically through replace/encode")

  -- And decoding the re-encoded blob reproduces the sysex event verbatim.
  local dec2 = ms.decode(re)
  h.eq(#dec2.events, 4, "all four events survive")
  local foundSysex = false
  for _, ev in ipairs(dec2.events) do
    if ev.ppq == 120 then
      h.eq(ev.msg, sysex, "sysex msg bytes preserved verbatim")
      h.eq(ev.msg:byte(1), 0xF0, "sysex status byte intact")
      foundSysex = true
    end
  end
  h.truthy(foundSysex, "sysex event present after round trip")
end)

-- (6) COVERAGE: a KEPT CC carrying the muted bit (0x02) in its flags retains flags==0x02
-- after replaceCCInRange (we must not clobber the low-nibble flags of pass-through CCs).
h.test("replaceCCInRange preserves muted-bit flags on kept CC", function()
  local lane = 1
  local MUTED = 0x02
  local events = {
    { ppq = 100, flags = MUTED, msg = cc(0, lane, 50) },  -- in target lane but OUT of range -> KEEP
    { ppq = 900, flags = MUTED, msg = cc(0, lane, 60) },  -- OUT of range -> KEEP
  }
  local dec = ms.decode(buildBlob(events, EOT))
  -- Replace range [300,800] only: neither CC is in range, both kept untouched.
  local res = ms.replaceCCInRange(dec, 0, lane, 300, 800, {})
  h.eq(#res.events, 2, "both out-of-range CCs kept")
  for _, ev in ipairs(res.events) do
    h.eq(ev.flags, MUTED, "kept CC retains muted-bit flags (0x02)")
  end
end)

-- (7) REGRESSION: generated CCs arrive with FLOAT ppq (MIDI_GetPPQPosFromProjTime returns a
-- float). encode must NOT crash on a non-integer int32 delta — ppq is floored to ticks.
h.test("encode tolerates float ppq from generated CCs", function()
  local lane = 11
  local dec = ms.decode(buildBlob({}, EOT))  -- eot-only (empty take)
  local newCCs = {
    { ppq = 10.4,    value = 64, shape = 1 },
    { ppq = 20.6,    value = 70, shape = 1 },
    { ppq = 100.999, value = 80, shape = 1 },
  }
  local res = ms.replaceCCInRange(dec, 0, lane, 0, 200, newCCs)
  local blob
  local ok, err = pcall(function() blob = ms.encode(res) end)
  h.truthy(ok, "encode did not error on float ppq: " .. tostring(err))
  local back = ms.decode(blob)
  h.eq(#back.events, 3, "all three generated CCs present")
  h.eq(back.events[1].ppq, 10,  "ppq floored to integer tick")
  h.eq(back.events[3].ppq, 101, "ppq rounded to nearest integer tick")
end)

-- SELECTION PRESERVED: a newCC with sel=true sets flags bit0 (0x01); sel falsy leaves it clear.
-- (Reduce re-inserts kept points selected; Generate points carry no sel and stay unselected.)
h.test("encodeMerged sets the selected bit (0x01) from cc.sel", function()
  local lane, chan = 1, 0
  local split = ms.splitForRange({ events = {}, eot = EOT }, chan, lane, 0, 1000)
  local newCCs = {
    { ppq = 100, value = 64, shape = 1, sel = true },
    { ppq = 200, value = 20, shape = 1, sel = false },
  }
  local back = ms.decode(ms.encodeMerged(split.kept, chan, lane, newCCs, split.eot))
  h.eq(#back.events, 2)
  h.eq(back.events[1].flags & 0x01, 0x01, "selected CC has bit0 set")
  h.eq(back.events[2].flags & 0x01, 0x00, "unselected CC has bit0 clear")
  -- shape nibble still intact alongside the selected bit
  h.eq(back.events[1].flags & 0xF0, ms.CCSHAPE_BITS[1])
end)

h.run()
