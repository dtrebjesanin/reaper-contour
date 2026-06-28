-- tests/test_reduce_panel.lua — drives the Reduce PANEL end-to-end (reduce.run -> target.read -> RDP /
-- curve-fit -> target.write) through the recording stub, on a populated read fixture. The pure RDP/curve
-- math is covered by test_reduce; this guards the panel wiring: scope -> baseline -> reducedAt -> write,
-- the non-destructive 0%-restore, and that curve-fit actually beats straight RDP on a curve.
package.path = package.path .. ";./Contour/?.lua;./?.lua;./tests/?.lua"

local stub   = require("reaper_stub")
stub.install()
local h      = require("harness")
local reduce = require("ui.reduce")

local function detEnv() return { target = "envelope", label = "Pan", hasTimeSel = true, t0 = 0, t1 = 4, details = { env = {} } } end

-- Seed N points sampling f(t) over [0,4] into the stub's envelope read fixture (all selected).
local function seedEnv(n, f)
  local pts = {}
  for i = 0, n - 1 do
    local t = (i / (n - 1)) * 4
    pts[#pts + 1] = { time = t, value = f(t), shape = 0, tension = 0, sel = true }
  end
  stub.envPoints = pts
end

h.test("reduce thins a dense collinear ramp to a handful (straight RDP)", function()
  reduce.cleanup(); stub.reset()                  -- clear the module-level baseline between cases
  seedEnv(21, function(t) return -1 + (t / 4) * 2 end)   -- perfectly linear ramp -1..1
  local g = { amount = 80, scope = 0, curveFit = false }  -- scope 0 = time selection
  reduce.run({}, detEnv(), g)
  h.truthy(not g.statusErr, "reduce errored: " .. tostring(g.status))
  h.truthy(#stub.rec.ins > 0, "reduce wrote points")
  h.truthy(#stub.rec.ins < 21, "should thin the collinear ramp, wrote " .. #stub.rec.ins)
  h.truthy(#stub.rec.ins <= 5, "a straight ramp should reduce to a handful, got " .. #stub.rec.ins)
end)

h.test("curve fit keeps a sine with no more points than straight RDP", function()
  local function run(curveFit)
    reduce.cleanup(); stub.reset()
    seedEnv(41, function(t) return math.sin(t / 4 * 2 * math.pi) * 0.9 end)
    local g = { amount = 50, scope = 0, curveFit = curveFit }
    reduce.run({}, detEnv(), g)
    return #stub.rec.ins, g
  end
  local straight = run(false)
  local curved   = run(true)
  h.truthy(curved < 41, "curve fit should thin the sine, got " .. curved)
  h.truthy(curved <= straight, ("curve fit (%d) should be <= straight RDP (%d) on a sine"):format(curved, straight))
  -- curve-fit must emit at least one CURVED segment shape (>=2) — otherwise it isn't fitting curves
  local curvedShapes = 0
  for _, ins in ipairs(stub.rec.ins) do if (ins.shape or 0) >= 2 then curvedShapes = curvedShapes + 1 end end
  h.truthy(curvedShapes > 0, "curve fit should write at least one curved-segment shape (2..5)")
end)

h.test("reduce at 0% restores every original point (non-destructive)", function()
  reduce.cleanup(); stub.reset()
  seedEnv(15, function(t) return math.sin(t) * 0.5 end)
  local g = { amount = 0, scope = 0, curveFit = false }
  reduce.run({}, detEnv(), g)
  h.truthy(not g.statusErr, "reduce errored: " .. tostring(g.status))
  h.eq(#stub.rec.ins, 15)   -- 0% writes the baseline back verbatim
end)

h.run()
