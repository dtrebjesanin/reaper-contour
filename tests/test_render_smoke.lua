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
local common          = require("ui.common")
local theme           = require("ui.theme")

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

-- ---- generate: custom ghost-preview toggle (Preview checkbox) ----------------------------------
h.test("generate.draw custom renders with the ghost preview on AND off", function()
  local st = newState(); st.op = "generate"; st.target = "envelope"
  generate.draw(CTX, st, detEnv())
  local g = st.gen; seedCustom(g); g.shapeIdx = 12   -- Custom
  for _, ghost in ipairs({ true, false }) do
    g.custom.ghost = ghost
    stub.reset()
    noThrow("custom ghost=" .. tostring(ghost), function() generate.draw(CTX, st, detEnv()) end)
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
    -- with a ghost overlay (the "result after modifiers" preview) carrying its own segment shapes,
    -- so the shape-aware ghost renderer (ease + bezier branches) is exercised, not just straight lines
    { pts = { { x = 0, y = -1, shape = 1 }, { x = 0.5, y = 1, shape = 1 }, { x = 1, y = -1, shape = 1 } },
      opts = { overlay = { { x = 0, y = -0.8, shape = 2 }, { x = 0.4, y = 0.6, shape = 5, tension = -0.3 },
                           { x = 0.7, y = 0.2, shape = 0 }, { x = 1, y = -0.8, shape = 1 } } } },
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

-- Same overlay smoke, but with a NON-identity native<->ImGui conversion (simulates a macOS Y-flip plus a
-- HiDPI scale) so the coordinate-conversion path runs: the corner min/max ordering, the signed CC span,
-- and the derived x-scale. Correct on-screen POSITION still needs a real macOS/4K check; this only proves
-- the flip/scale math executes cleanly (no divide-by-zero, nil, or bad swap) across env/AI/CC.
local function overlayFlipSmoke(det, name)
  h.test("overlay: " .. name .. " under macOS-style flipped + scaled coords (no crash)", function()
    stub.reset()
    local saved = reaper.ImGui_PointConvertNative
    reaper.ImGui_PointConvertNative = function(_ctx, x, y) return x * 1.5, 1000 - y * 1.5 end  -- 1.5x scale + Y-flip
    local ok, err = pcall(function()
      overlay.params = { knob = 20, shape = "sine", symmetrical = true, flipMode = "relative" }
      local started = overlay.start(CTX, det)
      h.truthy(started, "start under flipped coords")
      overlay.frame(CTX); overlay.frame(CTX)
      overlay._pendingOneShot = "flip"; overlay.frame(CTX)
      overlay.finish()
    end)
    reaper.ImGui_PointConvertNative = saved     -- always restore, even if the body threw
    h.truthy(ok, "flipped-coords overlay threw: " .. tostring(err))
  end)
end
overlayFlipSmoke(detEnv(), "envelope")
overlayFlipSmoke(detAI(),  "automation item")
overlayFlipSmoke(detCC(),  "MIDI CC")

-- ---- layout: scrolling body child + pinned footer, one vs two columns --------------------------------
-- The shell wraps the active op's body in ONE BeginChild (EndChild must follow it whatever it returns) and
-- Generate's lower sections go in a 2-column BeginTable once the content region is >= TWO_COL_MIN_W px.
-- The stub counts Begin/End pairs in stub.rec; AVAIL_W is the content width ImGui reports.
local function atWidth(w, fn)
  stub.AVAIL_W = w
  local ok, err = pcall(fn)
  stub.AVAIL_W = 360                    -- always restore, even if fn threw
  if not ok then error(err, 0) end
end

local function balanced(label)
  h.eq(stub.rec.childBegin, stub.rec.childEnd, label .. ": BeginChild/EndChild")
  h.eq(stub.rec.tableBegin, stub.rec.tableEnd, label .. ": BeginTable/EndTable")
end

-- Swap reaper.<name> for the duration of fn, always restoring the original.
local function with(overrides, fn)
  local saved = {}
  for k, v in pairs(overrides) do saved[k] = reaper[k]; reaper[k] = v end
  local ok, err = pcall(fn)
  for k in pairs(overrides) do reaper[k] = saved[k] end
  if not ok then error(err, 0) end
end

h.test("common.useTwoColumns switches at TWO_COL_MIN_W", function()
  h.eq(common.TWO_COL_MIN_W, 600)
  h.eq(common.useTwoColumns(599), false)
  h.eq(common.useTwoColumns(600), true)
  h.eq(common.useTwoColumns(1200), true)
  h.eq(common.useTwoColumns(nil), false)
end)

h.test("shell.draw pairs BeginChild/EndChild and BeginTable/EndTable for every op x context at 360 and 700 px", function()
  for _, w in ipairs({ 360, 700 }) do
    for _, op in ipairs({ "generate", "reduce", "transform" }) do
      for _, det in ipairs({ detEnv(), detCC(), detAI(), detNone() }) do
        local label = ("shell op=%s target=%s width=%d"):format(op, tostring(det.target), w)
        stub.reset()
        local st = newState(); st.op = op
        atWidth(w, function() noThrow(label, function() shell.draw(CTX, st, det) end) end)
        balanced(label)
        h.eq(stub.rec.childBegin, 1, label .. ": exactly one body child")
        -- the 2-column table is Generate-only, and only at the wide width
        h.eq(stub.rec.tableBegin, (op == "generate" and w >= common.TWO_COL_MIN_W) and 1 or 0, label .. ": table count")
      end
    end
  end
end)

h.test("generate.draw runs for every shape on every target at 700 px (two columns)", function()
  for _, det in ipairs({ detEnv(), detAI(), detCC() }) do
    local st = newState(); st.op = "generate"; st.target = det.target
    generate.draw(CTX, st, det)          -- one draw to initialise state.gen
    local g = st.gen
    seedCustom(g)
    for shapeIdx = 0, 12 do
      g.shapeIdx = shapeIdx
      stub.reset()
      local label = ("generate 700px shape=%d target=%s"):format(shapeIdx, det.target)
      atWidth(700, function() noThrow(label, function() generate.draw(CTX, st, det) end) end)
      balanced(label)
      h.eq(stub.rec.tableBegin, 1, label .. ": two-column table")
    end
  end
end)

-- Custom shape with both inline rename rows open, at the narrow and the wide layout. The rows only show
-- while their flag is set; each requests keyboard focus ONCE (the frame it opens), not every frame.
h.test("generate.draw custom with both rename rows open (360 and 700 px)", function()
  for _, w in ipairs({ 360, 700 }) do
    local st = newState(); st.op = "generate"
    generate.draw(CTX, st, detEnv())
    local g = st.gen; seedCustom(g); g.shapeIdx = 12
    g.genPre = { store = { { name = "P1", params = {} } }, idx = 1 }   -- the preset row needs a selected preset
    local drawn, focus = {}, 0
    local function frame(label)
      stub.reset()
      atWidth(w, function() noThrow(label, function() generate.draw(CTX, st, detEnv()) end) end)
      balanced(label)
    end
    with({
      ImGui_InputText = function(_c, label, v) drawn[label] = (drawn[label] or 0) + 1; return false, v end,
      ImGui_SetKeyboardFocusHere = function() focus = focus + 1 end,
    }, function()
      frame("rows closed")
      h.eq(drawn["Name##gen_prename"], nil, "preset Name row hidden by default")
      h.eq(drawn["Name##cust_name"], nil, "Custom Name row hidden by default")
      g.renamingPreset = true; g.custom.renaming = true
      frame("rows open #1")
      h.eq(drawn["Name##gen_prename"], 1, "preset Name row shown")
      h.eq(drawn["Name##cust_name"], 1, "Custom Name row shown")
      h.eq(focus, 2, "one focus request per row on the frame it opens")
      frame("rows open #2")
      h.eq(drawn["Name##gen_prename"], 2); h.eq(drawn["Name##cust_name"], 2)
      h.eq(focus, 2, "no repeated focus request")
    end)
  end
end)

h.test("Rename buttons toggle their rows; a row with nothing to rename stays closed", function()
  local st = newState(); st.op = "generate"
  generate.draw(CTX, st, detEnv())
  local g = st.gen; seedCustom(g); g.shapeIdx = 12
  local click
  with({ ImGui_Button = function(_c, label) return label == click end }, function()
    -- Custom drawing row
    click = "Rename##cust_ren"
    generate.draw(CTX, st, detEnv()); h.eq(g.custom.renaming, true, "first click opens")
    generate.draw(CTX, st, detEnv()); h.eq(g.custom.renaming, false, "second click closes")
    -- Generate-preset row: no preset selected => nothing to rename
    click = "Rename##gen_preren"
    g.genPre = { store = {}, idx = 0 }
    generate.draw(CTX, st, detEnv()); h.truthy(not g.renamingPreset, "no selected preset: stays closed")
    g.genPre = { store = { { name = "P1", params = {} } }, idx = 1 }
    generate.draw(CTX, st, detEnv()); h.eq(g.renamingPreset, true, "selected preset: opens")
    generate.draw(CTX, st, detEnv()); h.eq(g.renamingPreset, false, "second click closes")
  end)
end)

-- Close rules: finishing an edit saves + closes; losing focus (after having had it) closes; while the
-- mouse is still down the row waits, so clicking the Rename button itself doesn't close-then-reopen.
h.test("rename row closes on edit-finished and on focus loss (not while the mouse is down)", function()
  local st = newState(); st.op = "generate"
  generate.draw(CTX, st, detEnv())
  local g = st.gen
  g.genPre = { store = { { name = "P1", params = {} } }, idx = 1 }
  local active, deact, down = false, false, false
  with({
    ImGui_IsItemActive = function() return active end,
    ImGui_IsItemDeactivatedAfterEdit = function() return deact end,
    ImGui_IsMouseDown = function() return down end,
  }, function()
    stub.reset()
    g.renamingPreset = true; active = true
    generate.draw(CTX, st, detEnv()); h.eq(g.renamingPreset, true, "focused field stays open")
    active, down = false, true
    generate.draw(CTX, st, detEnv()); h.eq(g.renamingPreset, true, "focus lost with mouse down: waits")
    down = false
    generate.draw(CTX, st, detEnv()); h.eq(g.renamingPreset, false, "focus lost, mouse up: closes")
    -- edit finished (Enter): saves the presets and closes
    g.renamingPreset = true; active, deact = true, false
    generate.draw(CTX, st, detEnv())
    active, deact = false, true
    stub.rec.extState.genPresets = nil
    generate.draw(CTX, st, detEnv())
    h.eq(g.renamingPreset, false, "edit finished: closes")
    h.truthy(stub.rec.extState.genPresets ~= nil, "edit finished: preset store saved")
  end)
end)

-- A throw inside the child body must not unbalance the ImGui stack: EndChild always runs, and the error
-- is re-raised (contour.lua's pcall then reports it).
h.test("shell.draw: a throwing Generate body still EndChilds and re-raises", function()
  stub.reset()
  local real = generate.drawBody
  generate.drawBody = function() error("body boom") end
  local ok, err = pcall(shell.draw, CTX, newState(), detEnv())
  generate.drawBody = real
  h.truthy(not ok, "shell.draw must re-raise the body error")
  h.truthy(tostring(err):find("body boom", 1, true), "original message kept: " .. tostring(err))
  h.eq(stub.rec.childBegin, 1); h.eq(stub.rec.childEnd, 1, "EndChild ran")
end)

h.test("generate.draw: a throwing section inside the two-column table still EndTables", function()
  stub.reset()
  local st = newState(); st.op = "generate"
  local ok, err
  with({ ImGui_SliderInt = function(_c, label, v)
           if label:find("gen_base", 1, true) then error("table boom") end
           return false, v
         end }, function()
    atWidth(700, function() ok, err = pcall(generate.draw, CTX, st, detEnv()) end)
  end)
  h.truthy(not ok, "the section error must be re-raised")
  h.truthy(tostring(err):find("table boom", 1, true), "original message kept: " .. tostring(err))
  h.eq(stub.rec.tableBegin, 1); h.eq(stub.rec.tableEnd, 1, "EndTable ran")
end)

-- Shell: BeginChild gets nil for the border/child_flags slot (arg 5), a footer-sized negative height for
-- Generate (estimate first, then the MEASURED footer), and 0 (fill) for Reduce / Transform.
h.test("shell body child: arg 5 nil, height from the footer estimate then the measured footer", function()
  local calls = {}
  local posY = 0
  with({
    ImGui_BeginChild = function(_c, id, w, hh, a5, flags)
      calls[#calls + 1] = { id = id, w = w, h = hh, a5 = a5, flags = flags }
      stub.rec.childBegin = stub.rec.childBegin + 1
      return true
    end,
  }, function()
    stub.reset()
    local st = newState()
    shell.draw(CTX, st, detEnv())
    h.eq(calls[1].id, "##contour_body"); h.eq(calls[1].w, 0)
    h.eq(calls[1].a5, nil, "arg 5 (border / child_flags) must be nil")
    h.truthy(calls[1].flags ~= nil, "window flags passed as arg 6")
    h.eq(calls[1].h, -(2 * 32 + 8), "first frame: 2 x GetFrameHeightWithSpacing + 8")
    h.eq(st.footerH, nil, "constant cursor Y in the stub => nothing measurable => estimate kept")
    -- now a cursor that advances: the footer measures positive and drives the next frame's height
    with({ ImGui_GetCursorPosY = function() posY = posY + 40; return posY end }, function()
      shell.draw(CTX, st, detEnv())
      h.truthy(st.footerH and st.footerH > 0, "footer height measured: " .. tostring(st.footerH))
      shell.draw(CTX, st, detEnv())
      h.eq(calls[3].h, -st.footerH, "later frames use the measured footer height")
    end)
    -- Reduce / Transform have no footer: the child just fills the window
    for _, op in ipairs({ "reduce", "transform" }) do
      local st2 = newState(); st2.op = op
      shell.draw(CTX, st2, detEnv())
      h.eq(calls[#calls].h, 0, op .. ": child fills the rest of the window")
    end
  end)
end)

h.test("shell calls opts.scroll inside the child and passes noWheel into the child's window flags", function()
  local order = {}
  local flagsSeen
  with({
    ImGui_BeginChild = function(_c, _id, _w, _h, _a5, flags)
      order[#order + 1] = "begin"; flagsSeen = flags
      stub.rec.childBegin = stub.rec.childBegin + 1
      return true
    end,
    ImGui_EndChild = function() order[#order + 1] = "end"; stub.rec.childEnd = stub.rec.childEnd + 1 end,
    ImGui_WindowFlags_NoScrollWithMouse = function() return 4 end,
    ImGui_WindowFlags_AlwaysVerticalScrollbar = function() return 16 end,
  }, function()
    stub.reset()
    local scrolled = 0
    local opts = { scroll = function() order[#order + 1] = "scroll"; scrolled = scrolled + 1 end, noWheel = true }
    shell.draw(CTX, newState(), detEnv(), opts)
    h.eq(scrolled, 1)
    h.eq(order[1], "begin"); h.eq(order[2], "scroll"); h.eq(order[3], "end")
    h.eq(flagsSeen & 16, 16, "AlwaysVerticalScrollbar")
    h.eq(flagsSeen & 4, 4, "NoScrollWithMouse when opts.noWheel")
    shell.draw(CTX, newState(), detEnv(), { scroll = function() end, noWheel = false })
    h.eq(flagsSeen & 4, 0, "no NoScrollWithMouse without opts.noWheel")
    shell.draw(CTX, newState(), detEnv(), nil)          -- opts may be nil
  end)
end)

-- Header: one context line (label, time selection, right-aligned Follow); the old rows are gone.
h.test("shell header: single context line, Follow right-aligned, old rows removed", function()
  local texts, checks, cursorX = {}, {}, {}
  local over = {
    ImGui_Text = function(_c, s) texts[#texts + 1] = s end,
    ImGui_TextColored = function(_c, _col, s) texts[#texts + 1] = s end,
    ImGui_Checkbox = function(_c, label, v) checks[#checks + 1] = label; return false, v end,
    ImGui_SetCursorPosX = function(_c, x) cursorX[#cursorX + 1] = x end,
  }
  local xAt = {}
  for _, w in ipairs({ 360, 700 }) do
    texts, checks, cursorX = {}, {}, {}
    with(over, function()
      stub.reset()
      atWidth(w, function() shell.draw(CTX, newState(), detEnv()) end)
    end)
    local joined = table.concat(texts, "|")
    h.truthy(not joined:find("Detected:", 1, true), "no 'Detected:' row")
    h.truthy(not joined:find("Time selection:", 1, true), "no 'Time selection:' row")
    h.truthy(not joined:find("Operation:", 1, true), "no debug row")
    h.truthy(joined:find("Pan", 1, true), "detected label shown")
    h.truthy(joined:find("0.000 .. 4.000 s", 1, true), "time selection shown")
    local follows = 0
    for _, l in ipairs(checks) do if l == "Follow##follow" then follows = follows + 1 end end
    h.eq(follows, 1, "one Follow##follow checkbox")
    h.truthy(cursorX[1] ~= nil, "SetCursorPosX used to right-align")
    xAt[w] = cursorX[1]
  end
  h.almost(xAt[700] - xAt[360], 340, 1e-6, "Follow tracks the content width")
  -- no time selection: the existing hint text instead
  texts = {}
  with(over, function() shell.draw(CTX, newState(), detNone()) end)
  h.truthy(table.concat(texts, "|"):find("No time selection", 1, true), "hint when no time selection")
end)

-- Edits from the body AND the footer widgets share ONE per-frame gate, so either drives the live write.
h.test("generate: an edit in the body OR the footer triggers the live write that frame", function()
  local function liveFrame(editLabel)
    stub.reset()
    local st = newState()
    generate.draw(CTX, st, detEnv())
    local g = st.gen; g.shapeIdx = 1; g.live = true      -- Sine, Live on, envelope + time selection => ready
    with({
      ImGui_SliderInt = function(_c, label, v) return label:find(editLabel, 1, true) ~= nil, v end,
      ImGui_Button = function(_c, label) return label == editLabel end,
    }, function()
      generate.drawBody(CTX, st, detEnv())
      generate.drawFooter(CTX, st, detEnv())
    end)
    return #stub.rec.ins
  end
  h.truthy(liveFrame("gen_base") > 0, "body edit (Baseline) wrote")
  h.truthy(liveFrame("Reset##gen_reset") > 0, "footer edit (Reset) wrote")
  h.eq(liveFrame("no-such-widget"), 0, "idle frame writes nothing")
end)

-- Reset restores scope to Time selection, so readiness must be judged AFTER Reset: Entire-item scope with no
-- time selection is ready before the click and not after it, and that frame must not open a live write.
h.test("generate: Reset into Time-selection scope with no time selection writes nothing", function()
  stub.reset()
  local det = detCC(); det.hasTimeSel = false
  local st = newState(); st.target = "cc"
  generate.draw(CTX, st, det)
  local g = st.gen; g.shapeIdx = 1; g.live = true; g.scope = common.SCOPE_ENTIRE
  with({ ImGui_Button = function(_c, label) return label == "Reset##gen_reset" end }, function()
    generate.drawBody(CTX, st, det)
    generate.drawFooter(CTX, st, det)
  end)
  h.eq(g.scope, common.SCOPE_TIMESEL, "Reset restored the default scope")
  h.eq(stub.rec.undoBlocks, 0, "no live undo block opened")
  h.eq(stub.rec.setAllEvts + stub.rec.ccIns, 0, "no CC written")
end)

h.test("theme.sectionHeader hairline ends at the column edge, falling back to the window edge", function()
  local x2s = {}
  local rec = { ImGui_DrawList_AddLine = function(_dl, _x1, _y1, x2) x2s[#x2s + 1] = x2 end }
  with(rec, function()
    atWidth(360, function() theme.sectionHeader(CTX, "X") end)
    atWidth(200, function() theme.sectionHeader(CTX, "X") end)
  end)
  h.almost(x2s[1], 10 + 360, 1e-6, "cursor x (10) + avail width (360)")
  h.almost(x2s[2], 10 + 200, 1e-6, "narrower column => shorter line")
  -- fallback: cursor/avail unavailable => the old window-edge calculation
  x2s = {}
  rec.ImGui_GetCursorScreenPos = function() return nil end
  rec.ImGui_GetWindowPos  = function() return 5, 5 end
  rec.ImGui_GetWindowSize = function() return 400, 600 end
  with(rec, function() theme.sectionHeader(CTX, "X") end)
  h.almost(x2s[1], 5 + 400 - 26, 1e-6, "fallback: wx + ww - 26")
end)

h.run()
