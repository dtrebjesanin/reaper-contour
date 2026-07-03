-- tests/test_lfo_cap.lua — lfo.generate must refuse absurd point counts instead of freezing REAPER.
-- Nothing bounded cycles x points: Length 1/256 at Frequency 16 is a ~2 ms cycle at 120 BPM, Hz mode
-- allows 50 Hz, and Entire-item scope can span minutes - the emitters then build hundreds of
-- thousands of points PER FRAME with Live on. Dense-beyond-reason requests now raise a clear error
-- (pcall-caught by the panels and shown as status) rather than hanging the session.
package.path = package.path .. ";./Contour/?.lua;./?.lua;./tests/?.lua"

local h = require("harness")
local lfo = require("core.lfo")

local function gen(shape, rate, span, extra)
  local p = { shape = shape, rate = rate, amplitude = 1, baseline = 0 }
  for k, v in pairs(extra or {}) do p[k] = v end
  return pcall(lfo.generate, { t0 = 0, t1 = span }, p)
end

h.test("absurdly dense sparse emitter refuses with a clear error", function()
  local ok, err = gen("sine", { mode = "hz", hz = 50 }, 3600)   -- 180k cycles over an hour
  h.truthy(not ok, "must refuse")
  h.truthy(tostring(err):find("dense") ~= nil, "error says why: " .. tostring(err))
end)

h.test("absurdly dense generic sampler (steps bump the density) refuses too", function()
  local ok, err = gen("sine", { mode = "hz", hz = 40 }, 1200, { quantizeSteps = 32 })
  h.truthy(not ok, "must refuse")
  h.truthy(tostring(err):find("dense") ~= nil, tostring(err))
end)

h.test("random/drift cycle loops are capped as well", function()
  local ok, err = gen("random", { mode = "hz", hz = 100 }, 3600)
  h.truthy(not ok, "must refuse")
  h.truthy(tostring(err):find("dense") ~= nil, tostring(err))
end)

h.test("ordinary settings still generate", function()
  local ok, pts = gen("sine", { mode = "hz", hz = 2 }, 60)      -- 120 cycles: plenty but sane
  h.truthy(ok and #pts > 100, "normal generation unaffected, got " .. tostring(ok and #pts))
  ok, pts = gen("saw", { mode = "free", cycles = 64 }, 8)
  h.truthy(ok and #pts > 64, "free-rate generation unaffected")
end)

h.run()
