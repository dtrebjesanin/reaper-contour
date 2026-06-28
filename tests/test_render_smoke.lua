-- tests/test_render_smoke.lua — headless RENDER-SMOKE for the ReaImGui panels. Installs the fake
-- `reaper` (tests/reaper_stub) and calls every panel's draw()/frame() across a parameter MATRIX,
-- failing on any throw. This exercises the UI layer that loadfile + the pure suite cannot: nil-global
-- calls, missing/renamed reaper.* functions, arity mismatches, and render-path math — the exact class
-- of bug behind the overlay `bounds` forward-reference crash (overlay start->frame->one-shots below
-- reach BOTH former crash sites). It does NOT assert pixels; "draw ran without throwing across the
-- option space" is the contract.
package.path = package.path .. ";./Contour/?.lua;./?.lua;./tests/?.lua"

local stub = require("reaper_stub")
stub.install()                          -- MUST precede the ui.* requires (module-level reaper.* reads)

local h = require("harness")
local shell           = require("ui.shell")
local generate        = require("ui.generate")
local reduce          = require("ui.reduce")
local transform_panel = require("ui.transform_panel")
local drawpad         = require("ui.drawpad")
local overlay         = require("ui.overlay")

local CTX = "CTX"  -- opaque; the stub ignores it

-- ---- detected-context factories ------------------------------------------------------------------
local function detEnv() return { target = "envelope", label = "Pan", hasTimeSel = true, t0 = 0, t1 = 4, details = { env = {} } } end
local function detAI()  return { target = "ai",       label = "AI",  hasTimeSel = true, t0 = 0, t1 = 4, details = { env = {}, aiIndex = 0 } } end
local function detCC()  return { target = "cc",       label = "CC1", hasTimeSel = true, t0 = 0, t1 = 4, details = { take = "TAKE", midiEditor = "ME" } } end
local function detNone() return { target = nil, label = "(nothing selected)", hasTimeSel = false, t0 = 0, t1 = 0, details = {} } end

local function newState()
  return { op = "generate", target = "envelope", follow = true }
end

-- A valid custom-shape store so shapeIdx=custom has points to draw + generate.
local function seedCustom(g)
  g.custom = { store = { { name = "T", points = {
    { x = 0, y = -1, shape = 1, tension = 0 },
    { x = 0.5, y = 1, shape = 5, tension = -0.4 },
    { x = 1, y = -1, shape = 1, tension = 0 },
  } } }, idx = 1 }
end

-- Run fn in pcall; fail the enclosing test (with the error) if it throws.
local function noThrow(label, fn)
  local ok, err = pcall(fn)
  h.truthy(ok, label .. " threw: " .. tostring(err))
end

-- ---- shell: every operation x a couple of contexts --------------------------------------------
h.test("shell.draw runs for every operation and context", function()
  for _, op in ipairs({ "generate", "reduce", "transform" }) do
    for _, det in ipairs({ detEnv(), detCC(), detAI(), detNone() }) do
      stub.reset()
      local st = newState(); st.op = op
      noThrow("shell." .. op, function() shell.draw(CTX, st, det) end)
    end
  end
end)

-- ---- generate: ALL shapes x each target (the bulk of the manual option matrix) -----------------
h.test("generate.draw runs for every shape on every target", function()
  for _, det in ipairs({ detEnv(), detAI(), detCC() }) do
    local st = newState(); st.op = "generate"; st.target = det.target
    generate.draw(CTX, st, det)          -- one draw to initialise state.gen
    local g = st.gen
    seedCustom(g)
    for shapeIdx = 0, 12 do              -- 0=None .. 12=Custom (the full SHAPES list)
      g.shapeIdx = shapeIdx
      stub.reset()
      noThrow(("generate shape=%d target=%s"):format(shapeIdx, det.target),
        function() generate.draw(CTX, st, det) end)
    end
  end
end)

-- ---- generate: modifier sweep on representative shapes -----------------------------------------
h.test("generate.draw runs across the modifier sweep", function()
  local st = newState(); st.op = "generate"
  generate.draw(CTX, st, detEnv())
  local g = st.gen; seedCustom(g)
  local variants = {
    function() g.steps = 8 end,                         function() g.steps = 0 end,
    function() g.smooth = 60 end,                       function() g.smooth = 0 end,
    function() g.swing = 0.6 end,                       function() g.swing = -0.6 end,
    function() g.tilt = 80 end,                         function() g.tiltR = -80 end,
    function() g.tilt = 50; g.tiltR = 50 end,           function() g.ampSkew = 90 end,
    function() g.freqSkew = -90 end,                    function() g.phase = 75 end,
    function() g.pulseWidth = 0.2 end,                  function() g.amplitude = -150 end,
    function() g.amplitude = 200 end,                   function() g.baseline = 80 end,
    function() g.curve = 70 end,                        function() g.attack = 25 end,
    function() g.edge = 30 end,                         function() g.rateMode = 1 end,
    function() g.rateMode = 2 end,                      function() g.rateMode = 0 end,
  }
  for _, shapeIdx in ipairs({ 1, 5, 6, 2, 12 }) do      -- sine, square, trapezoid, triangle, custom
    g.shapeIdx = shapeIdx
    for i, apply in ipairs(variants) do
      apply()
      stub.reset()
      noThrow(("generate shape=%d variant=%d"):format(shapeIdx, i),
        function() generate.draw(CTX, st, detEnv()) end)
    end
  end
end)

-- ---- reduce + transform panels -----------------------------------------------------------------
h.test("reduce.draw runs across amounts and contexts", function()
  local st = newState(); st.op = "reduce"
  reduce.draw(CTX, st, detEnv())
  for _, det in ipairs({ detEnv(), detAI(), detCC(), detNone() }) do
    for _, amt in ipairs({ 0, 25, 50, 100 }) do
      st.red.amount = amt
      stub.reset()
      noThrow("reduce amount=" .. amt, function() reduce.draw(CTX, st, det) end)
    end
    st.red.curveFit = true
    stub.reset()
    noThrow("reduce curveFit", function() reduce.draw(CTX, st, det) end)
    st.red.curveFit = false
  end
end)

h.test("transform_panel.draw runs for both scopes", function()
  for _, scope in ipairs({ "points", "timesel" }) do
    transform_panel.scope = scope
    stub.reset()
    noThrow("transform_panel scope=" .. scope, function() transform_panel.draw(CTX, newState()) end)
  end
end)

-- ---- drawpad: point/segment/grid variants ------------------------------------------------------
h.test("drawpad.draw runs across point/segment/grid configurations", function()
  local configs = {
    { pts = { { x = 0, y = 0, shape = 1 }, { x = 1, y = 0, shape = 1 } }, opts = {} },
    { pts = { { x = 0, y = -1, shape = 1 }, { x = 0.5, y = 1, shape = 1 }, { x = 1, y = -1, shape = 1 } }, opts = { snap = true } },
    { pts = { { x = 0, y = -1, shape = 5, tension = -0.5 }, { x = 1, y = 1, shape = 5, tension = 0.5 } }, opts = { gridX = 8, gridY = 4 } },
    { pts = { { x = 0, y = 0, shape = 0 }, { x = 0.5, y = 1, shape = 2 }, { x = 1, y = -1, shape = 3 } }, opts = { gridX = 1, gridY = 1 } },
    { pts = { { x = 0, y = 0, shape = 4, tension = 0.3 }, { x = 1, y = 0.5, shape = 1 } }, opts = { width = 500, height = 200, snap = true } },
    -- with a ghost overlay (the "result after modifiers" preview) supplied by the caller
    { pts = { { x = 0, y = -1, shape = 1 }, { x = 0.5, y = 1, shape = 1 }, { x = 1, y = -1, shape = 1 } },
      opts = { overlay = { { x = 0, y = -0.8 }, { x = 0.3, y = 0.6 }, { x = 0.6, y = 0.6 }, { x = 1, y = -0.8 } } } },
  }
  for i, c in ipairs(configs) do
    stub.reset()
    noThrow("drawpad config=" .. i, function() drawpad.draw(CTX, c.pts, c.opts) end)
  end
end)

-- ---- overlay (Transform engine): the bounds-regression guard -----------------------------------
-- start() must SUCCEED (selected points present) so frame() reaches `bounds(g.orig)` (the former crash
-- line) and the one-shots reach the second bounds() call site + the full writeTransformed path.
-- NOT covered here: live DRAG transforms (stretch/scale/tilt/warp) and live undo/redo — those need a
-- scripted mouse (zone hit -> IsMouseDown -> moving GetMousePos across frames). The transform MATH they
-- drive is unit-tested in tests/test_transform.lua; only the overlay's mouse glue is unexercised.
-- env/AI write via InsertEnvelopePoint(Ex); CC writes via the atomic writeBulk -> MIDI_SetAllEvts path.
local function wrote() return #stub.rec.ins > 0 or #stub.rec.insEx > 0 or stub.rec.ccIns > 0 or stub.rec.setAllEvts > 0 end
local function overlaySmoke(det, name)
  h.test("overlay: " .. name .. " start->frames->one-shots (bounds regression guard)", function()
    stub.reset()
    overlay.params = { knob = 30, shape = "power", symmetrical = false, flipMode = "absolute" }
    local started, serr
    noThrow("overlay.start " .. name, function() started, serr = overlay.start(CTX, det) end)
    h.truthy(started, "overlay.start should succeed on selected points: " .. tostring(serr))
    noThrow("overlay.frame#1", function() overlay.frame(CTX) end)   -- CC branch runs the ppq<->x / lane math here
    noThrow("overlay.frame#2", function() overlay.frame(CTX) end)
    for _, op in ipairs({ "reverse", "flip", "reset" }) do
      overlay._pendingOneShot = op
      noThrow("overlay one-shot " .. op, function() overlay.frame(CTX) end)
    end
    h.truthy(wrote(), "a one-shot should have written points back")
    noThrow("overlay.finish", function() overlay.finish() end)
  end)
end
overlaySmoke(detEnv(), "envelope")
overlaySmoke(detAI(),  "automation item")
overlaySmoke(detCC(),  "MIDI CC")   -- reaches the CC coordinate frame (ppq<->x, lane height) + CC writeback

h.run()
