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
local target          = require("core.target")

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
  h.eq(stub.rec.popupBegin, stub.rec.popupEnd, label .. ": BeginPopup/EndPopup")
  h.eq(stub.rec.tabBarBegin, stub.rec.tabBarEnd, label .. ": BeginTabBar/EndTabBar")
  h.eq(stub.rec.comboBegin, stub.rec.comboEnd, label .. ": BeginCombo/EndCombo")
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

-- ---- palettes ------------------------------------------------------------------------------------------
-- Today's Contour look, value for value: the OLD palette keys plus the panel colours that used to be
-- hardcoded in the panels and the overlay. Selecting "contour" must reproduce every one of them.
local CONTOUR_NOW = {
  text = 0xE3E8ECFF, textDim = 0x8B97A2FF,
  winBg = 0x1B1E23FF, childBg = 0x20242AFF, popupBg = 0x22262CFF,
  frame = 0x262D34FF, frameH = 0x303842FF, frameA = 0x3A424DFF,
  accent = 0x2E8B9BFF, accentH = 0x3FB6C4FF, accentA = 0x53C9D6FF, accentDim = 0x2A6A75FF,
  tab = 0x262B31FF, tabH = 0x3FB6C4FF, tabSel = 0x2E8B9BFF,
  sep = 0x323A44FF,
  scrollBg = 0x1B1E23FF, scrollGrab = 0x3C444EFF, scrollGrabH = 0x4A535EFF,
  header = 0x2E8B9B33, headerH = 0x2E8B9B55, headerA = 0x2E8B9B77,
  button = 0x262D34FF, buttonH = 0x303842FF, buttonA = 0x2E8B9BFF,
  onAccent = 0xF3FBFCFF,
  -- the stock slider grab and check mark, which COLORS used to take from frameA / 0x4A535EFF / accentH
  sliderGrab = 0x3A424DFF, sliderGrabA = 0x4A535EFF, check = 0x3FB6C4FF,
  -- hardcoded in the panels
  mute = 0x3A3A3AFF, muteH = 0x4A4A4AFF, sectionHdr = 0x3FB6C4FF,
  hint = 0xC0A040FF, ok = 0x60C080FF, err = 0xE05050FF, warn = 0xE0A060FF,
  grip = 0x6A737BFF,
  padBg = 0x10151AFF, padGrid = 0x3A434BFF, padAxis = 0x55636EFF, padCurve = 0x48C6D4FF, padPoint = 0x9FE9F1FF,
  faderFill = 0x2E8B9B4D, faderCap = 0x359DADFF, faderShadow = 0x0E1317D9, faderText = 0xE9EEF2FF,
  -- the cap's hover / press colours, which common.lua used to take from accentH / accentA
  faderCapH = 0x3FB6C4FF, faderCapA = 0x53C9D6FF,
  hudBg = 0x12242BF7,
}

-- WCAG relative luminance / contrast ratio of two 0xRRGGBBAA palette colours (alpha ignored), written here
-- on purpose so the check does not share code with ui/theme.
local function lumOf(col)
  local function lin(v) v = v / 255; return v <= 0.04045 and v / 12.92 or ((v + 0.055) / 1.055) ^ 2.4 end
  local r, g, b = (col >> 24) & 0xFF, (col >> 16) & 0xFF, (col >> 8) & 0xFF
  return 0.2126 * lin(r) + 0.7152 * lin(g) + 0.0722 * lin(b)
end
local function contrastOf(a, b)
  local la, lb = lumOf(a), lumOf(b)
  if la < lb then la, lb = lb, la end
  return (la + 0.05) / (lb + 0.05)
end

local function nat(rgb) return ((rgb & 0xFF) << 16) | (rgb & 0xFF00) | (rgb >> 16) end   -- 0xRRGGBB -> native 0x00BBGGRR
local function sortedKeys(t) local ks = {} for k in pairs(t) do ks[#ks + 1] = k end table.sort(ks) return ks end

-- Run fn, then ALWAYS restore the palette, the stub's theme colours and clock, and the content width.
local function withTheme(fn)
  local id, colors, now = theme.paletteId(), stub.themeColors, stub.now
  local ok, err = pcall(fn)
  stub.themeColors, stub.now, stub.AVAIL_W = colors, now, 360
  theme.setPalette(id)
  if not ok then error(err, 0) end
end

local DARK  = { col_main_bg2 = 0x1E1F24, col_main_editbk = 0x2A2C33, genlist_fg = 0xD0D4DA, col_toolbar_text_on = 0x46BAFE }
local LIGHT = { col_main_bg2 = 0xFFFFFF, col_main_editbk = 0xF0F0F0, genlist_fg = 0x202020, col_toolbar_text_on = 0x0066CC }
local function readFrom(t) return function(k) return t[k] end end
local function nativeTheme(t) local o = {} for k, v in pairs(t) do o[k] = nat(v) end return o end

h.test("theme.C is one table; Contour reproduces today's colours exactly", function()
  withTheme(function()
    local c = theme.C
    theme.setPalette("contour")
    h.truthy(theme.C == c, "theme.C must stay the same table object")
    for _, k in ipairs(sortedKeys(CONTOUR_NOW)) do h.eq(theme.C[k], CONTOUR_NOW[k], "contour." .. k) end
    for k in pairs(theme.C) do h.truthy(CONTOUR_NOW[k] ~= nil, "unexpected key in theme.C: " .. k) end
    h.eq(theme.withAlpha(0x2E8B9BFF, 0xCC), 0x2E8B9BCC, "BOXCOL: accent at alpha 0xCC")
    h.eq(theme.withAlpha(theme.C.accentA, 0xE6), 0x53C9D6E6, "hovered fader notch")
    h.eq(theme.withAlpha(theme.C.textDim, 0x96), 0x8B97A296, "idle fader notch")
    h.eq(theme.withAlpha(theme.C.sep, 0x80), 0x323A4480, "section header hairline")
  end)
end)

h.test("theme.derive: pure, one key set for every palette", function()
  local saved = _G.reaper
  _G.reaper = nil                               -- derive / autoSpec must not touch the API
  local ok, err = pcall(function()
    for _, p in ipairs(theme.PALETTES) do
      if p.spec then
        local d = theme.derive(p.spec)
        h.eq(table.concat(sortedKeys(d), ","), table.concat(sortedKeys(CONTOUR_NOW), ","), p.id .. ": key set")
        for k, v in pairs(d) do h.truthy(math.type(v) == "integer" and v >= 0 and v <= 0xFFFFFFFF, p.id .. "." .. k) end
      end
    end
    local light = theme.derive(theme.autoSpec(readFrom(LIGHT)))
    h.eq(table.concat(sortedKeys(light), ","), table.concat(sortedKeys(CONTOUR_NOW), ","), "light auto: key set")
  end)
  _G.reaper = saved
  h.truthy(ok, tostring(err))
end)

h.test("palette order and ids", function()
  local ids = {}
  for _, p in ipairs(theme.PALETTES) do ids[#ids + 1] = p.id end
  h.eq(table.concat(ids, ","), "auto,contour,cassatt,kandinsky,tam,paquin,klimt")
  h.eq(theme.PALETTES[1].name, "Auto (REAPER theme)")
end)

h.test("contrast floors hold for every fixed palette and for Auto on a dark and a light REAPER theme", function()
  local function check(label, c, skipOnAccent)
    h.truthy(contrastOf(c.text, c.winBg)   >= 4.5, label .. ": text/bg "     .. contrastOf(c.text, c.winBg))
    h.truthy(contrastOf(c.text, c.frame)   >= 4.5, label .. ": text/field "  .. contrastOf(c.text, c.frame))
    h.truthy(contrastOf(c.textDim, c.winBg) >= 4.5, label .. ": dim/bg "     .. contrastOf(c.textDim, c.winBg))
    if not skipOnAccent then
      h.truthy(contrastOf(c.onAccent, c.accent) >= 4.5, label .. ": onAccent/accent " .. contrastOf(c.onAccent, c.accent))
    end
    for _, k in ipairs({ "hint", "ok", "err" }) do
      h.truthy(contrastOf(c[k], c.winBg) >= 3, label .. ": " .. k .. "/bg " .. contrastOf(c[k], c.winBg))
    end
  end
  for _, p in ipairs(theme.PALETTES) do
    if p.spec then check(p.id, theme.derive(p.spec))
    -- Contour keeps today's exact values, and its onAccent is 3.8:1 on the teal (not floored, by design)
    elseif p.full then check(p.id, CONTOUR_NOW, true) end
  end
  check("auto dark",  theme.derive(theme.autoSpec(readFrom(DARK))))
  check("auto light", theme.derive(theme.autoSpec(readFrom(LIGHT))))
  -- status colours keep their hue on dark backgrounds and turn darker on light ones
  h.eq(theme.derive(theme.PALETTES[5].spec).hint, 0xC0A040FF, "dark palette: hint unchanged")
  local lt = theme.derive(theme.autoSpec(readFrom(LIGHT)))
  for _, k in ipairs({ "hint", "ok", "err", "warn" }) do
    h.truthy(lumOf(lt[k]) < lumOf(CONTOUR_NOW[k]), "light background: " .. k .. " darker than the dark variant")
  end
end)

h.test("Auto reads the real Reapertips theme", function()
  withTheme(function()
    -- natives are 0x00BBGGRR. NB: 16693574 is 0xFEB946 -> rgb 0x46B9FE (one green step off 0x46BAFE).
    stub.themeColors = { col_main_bg2 = 4079166, col_main_editbk = 2763306, genlist_fg = 13158600,
                         col_toolbar_text_on = 16693574, genlist_selbg = 14569774 }
    theme.setPalette("auto")
    h.eq(theme.C.winBg, 0x3E3E3EFF); h.eq(theme.C.frame, 0x2A2A2AFF)
    h.eq(theme.C.text, 0xC8C8C8FF);  h.eq(theme.C.accent, 0x46B9FEFF)
    -- the same mapping seen through the pure helper
    local spec = theme.autoSpec(readFrom({ col_main_bg2 = 0x3E3E3E, col_main_editbk = 0x2A2A2A, genlist_fg = 0xC8C8C8,
                                           col_toolbar_text_on = 0x46B9FE }))
    h.eq(spec.bg, 0x3E3E3E); h.eq(spec.field, 0x2A2A2A); h.eq(spec.text, 0xC8C8C8); h.eq(spec.accent, 0x46B9FE)
    -- a negative native (flag bits in the high byte, as col_main_bg is on Reapertips) is masked, not rejected
    stub.themeColors = { col_main_bg = (0xFF000000 | 0x3E3E3E) - 0x100000000, genlist_fg = 13158600,
                         col_toolbar_text_on = 16693574 }
    theme.setPalette("auto")
    h.eq(theme.C.winBg, 0x3E3E3EFF, "flag bits masked off, bg read from col_main_bg")
    h.eq(theme.C.accent, 0x46B9FEFF)
  end)
end)

h.test("Auto falls back: nothing found -> Contour; accent == bg -> genlist_selbg", function()
  withTheme(function()
    stub.themeColors = {}
    theme.setPalette("auto")
    for _, k in ipairs(sortedKeys(CONTOUR_NOW)) do h.eq(theme.C[k], CONTOUR_NOW[k], "no theme: " .. k) end
    -- bg, text or accent missing => no spec
    h.eq(theme.autoSpec(readFrom({ col_main_bg2 = 0x202020, genlist_fg = 0xFFFFFF })), nil, "no accent")
    h.eq(theme.autoSpec(readFrom({ col_main_bg2 = 0x202020, col_toolbar_text_on = 0x46BAFE })), nil, "no text")
    h.eq(theme.autoSpec(readFrom({ genlist_fg = 0xFFFFFF, col_toolbar_text_on = 0x46BAFE })), nil, "no bg")
    -- GetThemeColor / ColorFromNative unknown to the API (the stub's catch-all then returns nil)
    local gt, cn = reaper.GetThemeColor, reaper.ColorFromNative
    reaper.GetThemeColor, reaper.ColorFromNative = nil, nil
    local ok, err = pcall(theme.setPalette, "auto")
    reaper.GetThemeColor, reaper.ColorFromNative = gt, cn
    h.truthy(ok, tostring(err))
    h.eq(theme.C.accent, CONTOUR_NOW.accent, "no GetThemeColor: Contour")
    -- the accent equals the bg (or is under 2:1 against it): the next candidate is used
    local t = { col_main_bg2 = 0x1E1F24, genlist_fg = 0xD0D4DA, col_toolbar_text_on = 0x1E1F24, genlist_selbg = 0x46BAFE }
    h.eq(theme.autoSpec(readFrom(t)).accent, 0x46BAFE, "accent == bg -> genlist_selbg")
    stub.themeColors = nativeTheme(t)
    theme.setPalette("auto")
    h.eq(theme.C.accent, 0x46BAFEFF, "accent == bg -> genlist_selbg, through GetThemeColor")
    t.genlist_selbg = 0x202228                 -- also too close to the bg: nothing usable, so Contour
    h.eq(theme.autoSpec(readFrom(t)), nil, "no accent clears 2:1")
  end)
end)

h.test("palette persistence: Auto by default, setPalette saves and applies in place", function()
  withTheme(function()
    stub.themeColors = {}
    local c = theme.C
    -- empty or unknown ExtState => auto (seen by the once-a-second re-read)
    theme.setPalette("klimt")
    stub.rec.extState.palette = nil
    stub.now = stub.now + 2; theme.push(CTX); theme.pop(CTX)
    h.eq(theme.paletteId(), "auto", "empty ExtState -> auto")
    theme.setPalette("klimt")
    stub.rec.extState.palette = "no-such-palette"
    stub.now = stub.now + 2; theme.push(CTX); theme.pop(CTX)
    h.eq(theme.paletteId(), "auto", "unknown ExtState -> auto")
    -- setPalette: saved + applied at once, same table object
    local before = theme.C.accent
    theme.setPalette("tam")
    h.eq(stub.rec.extState.palette, "tam")
    h.eq(theme.paletteId(), "tam")
    h.eq(theme.C.accent, 0xEF8737FF); h.truthy(theme.C.accent ~= before)
    h.truthy(theme.C == c, "same table object after setPalette")
    -- a change saved elsewhere (the panel, seen from the overlay's Lua state) is followed on the next re-read
    stub.rec.extState.palette = "cassatt"
    stub.now = stub.now + 2; theme.push(CTX); theme.pop(CTX)
    h.eq(theme.paletteId(), "cassatt", "ExtState change followed")
    h.eq(theme.C.accent, 0x7FA074FF)
    theme.setPalette("not-a-palette")          -- unknown id degrades to auto
    h.eq(theme.paletteId(), "auto")
  end)
end)

h.test("Auto palette follows a REAPER theme change at most once a second", function()
  withTheme(function()
    stub.themeColors = nativeTheme(DARK); stub.now = 500
    theme.setPalette("auto")
    local bgBefore = theme.C.winBg
    h.eq(bgBefore & 0xFFFFFF00, 0x1E1F2400, "dark theme applied")
    stub.themeColors = nativeTheme(LIGHT)
    stub.now = 500.5
    theme.push(CTX); theme.pop(CTX)
    h.eq(theme.C.winBg, bgBefore, "under 1 s: nothing re-read")
    stub.now = 501.5
    theme.push(CTX); theme.pop(CTX)
    h.eq(theme.C.winBg, 0xFFFFFFFF, "past 1 s: the new theme applies")
    -- no further change => nothing is re-applied (the table's values stay put)
    local snap = {}
    for k, v in pairs(theme.C) do snap[k] = v end
    stub.now = 503; theme.push(CTX); theme.pop(CTX)
    for k, v in pairs(snap) do h.eq(theme.C[k], v, "stable " .. k) end
    -- fixed palettes ignore the REAPER theme
    theme.setPalette("klimt")
    stub.themeColors = nativeTheme(DARK); stub.now = 510
    theme.push(CTX); theme.pop(CTX)
    h.eq(theme.C.accent, 0x924099FF)
  end)
end)

-- The fader cap must brighten on hover and again on press (darken on a light theme), in every palette:
-- deriving hover / press from the accent instead of the cap colour made Klimt's pink cap go dark purple.
h.test("fader cap: hover and press move away from the idle cap in the 'lighter' direction", function()
  local function check(label, c)
    local light = lumOf(c.winBg) > 0.5
    local idle, hov, act = lumOf(c.faderCap), lumOf(c.faderCapH), lumOf(c.faderCapA)
    if light then
      h.truthy(hov <= idle and act <= hov, label .. ": darker on hover, darker still on press")
    else
      h.truthy(hov >= idle and act >= hov, label .. ": lighter on hover, lighter still on press")
    end
  end
  for _, p in ipairs(theme.PALETTES) do
    if p.spec then check(p.id, theme.derive(p.spec)) end
  end
  check("contour", CONTOUR_NOW)
  check("auto dark", theme.derive(theme.autoSpec(readFrom(DARK))))
  check("auto light", theme.derive(theme.autoSpec(readFrom(LIGHT))))
  -- and common.lua draws the hovered cap in faderCapH
  withTheme(function()
    theme.setPalette("klimt")
    local got = {}
    with({ ImGui_DrawList_AddRectFilled = function(_dl, _a, _b, _c, _d, col) got[col] = true end,
           ImGui_IsItemHovered = function() return true end },
      function() stub.reset(); common.tickReset(CTX, { v = 10 }, "v", 0, 100, 50, "10") end)
    h.truthy(got[theme.C.faderCapH], "hovered cap uses faderCapH")
  end)
end)

-- ---- the palette menu in the shell ---------------------------------------------------------------------
h.test("shell palette menu: popups balance at 360 and 700 px, button + popup sit inside the tab bar", function()
  withTheme(function()
    for _, w in ipairs({ 360, 700 }) do
      local label = "shell palette menu width=" .. w
      stub.reset()
      atWidth(w, function() noThrow(label, function() shell.draw(CTX, newState(), detEnv()) end) end)
      balanced(label)
      h.eq(stub.rec.popupBegin, 1, label .. ": one popup per frame")
    end
    -- order: tab button, then BeginPopup, THEN EndTabBar; a click on the button opens the popup
    local order, opened = {}, nil
    with({
      ImGui_TabItemButton = function(_c, lbl) order[#order + 1] = "button:" .. lbl; return true end,
      ImGui_OpenPopup = function(_c, id) opened = id end,
      ImGui_BeginPopup = function(_c, id) order[#order + 1] = "popup:" .. id; stub.rec.popupBegin = stub.rec.popupBegin + 1; return true end,
      ImGui_EndTabBar = function() order[#order + 1] = "endbar" end,
    }, function() stub.reset(); shell.draw(CTX, newState(), detEnv()) end)
    h.eq(table.concat(order, " "), "button:...##palette popup:##palette_menu endbar")
    h.eq(opened, "##palette_menu", "a click opens the popup")
    -- one MenuItem per palette in menu order; only the active one is ticked; clicking Tam selects it
    theme.setPalette("klimt")
    local names, ticked = {}, {}
    with({ ImGui_MenuItem = function(_c, lbl, _sc, sel) names[#names + 1] = lbl; if sel then ticked[#ticked + 1] = lbl end
                                    return lbl == "Tam" end },
      function() stub.reset(); shell.draw(CTX, newState(), detEnv()) end)
    h.eq(table.concat(names, "|"), "Auto (REAPER theme)|Contour|Cassatt|Kandinsky|Tam|Paquin|Klimt")
    h.eq(table.concat(ticked, "|"), "Klimt", "the active palette is ticked")
    h.eq(theme.paletteId(), "tam", "clicking Tam selects it")
    h.eq(stub.rec.extState.palette, "tam")
    balanced("menu click")
    -- a throw inside the popup body still EndPopups and re-raises
    stub.reset()
    local ok, err
    with({ ImGui_MenuItem = function() error("menu boom") end }, function() ok, err = pcall(shell.draw, CTX, newState(), detEnv()) end)
    h.truthy(not ok and tostring(err):find("menu boom", 1, true), "the popup error is re-raised: " .. tostring(err))
    h.eq(stub.rec.popupBegin, 1); h.eq(stub.rec.popupEnd, 1, "EndPopup ran")
    h.eq(stub.rec.tabBarEnd, stub.rec.tabBarBegin, "EndTabBar ran although the popup threw")
  end)
end)

-- ---- panels read theme.C when they draw ----------------------------------------------------------------
h.test("panels follow a palette change (no colour is cached at load)", function()
  withTheme(function()
    local function capture(fnNames, run)
      local got, over = {}, {}
      for _, n in ipairs(fnNames) do
        over[n] = function(_a, ...) local a = { ... }; for _, v in ipairs(a) do if math.type(v) == "integer" and v > 0xFFFF then got[v] = true end end end
      end
      with(over, function() stub.reset(); run() end)
      return got
    end
    local pts = { { x = 0, y = -1, shape = 1 }, { x = 1, y = 1, shape = 1 } }
    for _, id in ipairs({ "contour", "tam", "klimt" }) do
      theme.setPalette(id)
      local c = theme.C
      local pad = capture({ "ImGui_DrawList_AddRectFilled", "ImGui_DrawList_AddLine", "ImGui_DrawList_AddCircleFilled" },
        function() drawpad.draw(CTX, pts, {}) end)
      for _, k in ipairs({ "padBg", "padGrid", "padAxis", "padCurve", "padPoint" }) do h.truthy(pad[c[k]], id .. " drawpad " .. k) end
      local fader = capture({ "ImGui_DrawList_AddRectFilled", "ImGui_DrawList_AddTriangleFilled" },
        function() common.tickReset(CTX, { v = 10 }, "v", 0, 100, 50, "10") end)
      for _, k in ipairs({ "faderFill", "faderShadow", "faderCap" }) do h.truthy(fader[c[k]], id .. " fader " .. k) end
      local btns = capture({ "ImGui_PushStyleColor" }, function() shell.draw(CTX, newState(), detEnv()) end)
      for _, k in ipairs({ "accent", "accentH", "mute", "muteH", "onAccent", "textDim" }) do h.truthy(btns[c[k]], id .. " op switcher " .. k) end
      local hint = capture({ "ImGui_TextColored" }, function() shell.draw(CTX, newState(), detNone()) end)
      h.truthy(hint[c.hint], id .. ": 'No time selection' uses theme.C.hint")
    end
    -- hint/ok/err really change with the background (light REAPER theme => darker variants)
    stub.themeColors = nativeTheme(LIGHT); theme.setPalette("auto")
    local seen = {}
    with({ ImGui_TextColored = function(_c, col, s) seen[s] = col end }, function()
      stub.reset(); shell.draw(CTX, newState(), detNone())
    end)
    h.eq(seen["No time selection"], theme.C.hint)
    h.truthy(seen["No time selection"] ~= 0xC0A040FF, "light theme: the hint colour is the darker variant")
  end)
end)

-- ---- the old render matrix, once more under a different palette -----------------------------------------
h.test("render matrix runs under the Klimt palette", function()
  withTheme(function()
    theme.setPalette("klimt")
    noThrow("theme.push/pop", function() theme.push(CTX); theme.pop(CTX); theme.push(CTX, true); theme.pop(CTX) end)
    for _, w in ipairs({ 360, 700 }) do
      for _, op in ipairs({ "generate", "reduce", "transform" }) do
        for _, det in ipairs({ detEnv(), detCC(), detAI(), detNone() }) do
          local label = ("klimt shell op=%s target=%s width=%d"):format(op, tostring(det.target), w)
          stub.reset()
          local st = newState(); st.op = op
          atWidth(w, function() noThrow(label, function() shell.draw(CTX, st, det) end) end)
          balanced(label)
        end
      end
    end
    for _, det in ipairs({ detEnv(), detAI(), detCC() }) do
      local st = newState(); st.op = "generate"; st.target = det.target
      generate.draw(CTX, st, det)
      local g = st.gen; seedCustom(g)
      for shapeIdx = 0, 12 do
        g.shapeIdx = shapeIdx
        stub.reset()
        noThrow(("klimt generate shape=%d target=%s"):format(shapeIdx, det.target), function() generate.draw(CTX, st, det) end)
      end
    end
    local st = newState(); st.op = "reduce"
    reduce.draw(CTX, st, detEnv())             -- one draw to initialise state.red
    for _, amt in ipairs({ 0, 50, 100 }) do
      st.red.amount = amt
      stub.reset(); noThrow("klimt reduce amount=" .. amt, function() reduce.draw(CTX, st, detEnv()) end)
    end
    for _, scope in ipairs({ "points", "timesel" }) do
      transform_panel.scope = scope
      stub.reset(); noThrow("klimt transform_panel", function() transform_panel.draw(CTX, newState()) end)
    end
    overlay.params = { knob = 30, shape = "power", symmetrical = false, flipMode = "absolute" }
    stub.reset()
    noThrow("klimt overlay", function()
      h.truthy(overlay.start(CTX, detEnv())); overlay.frame(CTX); overlay.frame(CTX); overlay.finish()
    end)
  end)
end)

-- ---- razor areas: ONE span list drives Generate ------------------------------------------------------------
-- The descriptor fields below (rangeSource, ranges, razorOutside, hasRange) are what core/context.detect
-- produces; these tests build them by hand. A descriptor WITHOUT them must behave exactly as before.
local HINT_RANGE      = "Make a time selection or a razor area (or switch Scope to Entire item)."
local HINT_OUTSIDE_AI = "The razor area is outside this automation item"
local HINT_OUTSIDE_IT = "The razor area is outside this item"

h.test("[M5] the razor texts live in ui.common and are byte-identical to what the panels pin", function()
  h.eq(common.RANGE_HINT, HINT_RANGE)
  h.eq(common.MSG_ONE_AREA, "Transform needs one razor area on this lane")
  h.eq(common.razorOutsideText({ target = "ai" }), HINT_OUTSIDE_AI)
  h.eq(common.razorOutsideText({ target = "envelope" }), HINT_OUTSIDE_IT)
  h.eq(common.razorOutsideText({}), HINT_OUTSIDE_IT)
  h.eq(common.razorOutsideText(nil), HINT_OUTSIDE_IT, "nil-safe")
end)

local function razor(det, ranges)
  det.rangeSource, det.ranges, det.hasRange, det.razorOutside = "razor", ranges, #ranges > 0, false
  return det
end
local function detTake()
  return { target = "envelope", label = "Take envelope", hasTimeSel = true, t0 = 3, t1 = 8,
           details = { env = "TENV", take = "TAKE" } }
end
-- A Sine panel state (Live as asked) that has been drawn once, so state.gen exists.
local function sineState(live)
  stub.reset()
  local st = newState()
  generate.draw(CTX, st, detEnv())
  local g = st.gen; g.shapeIdx = 1; g.live = live and true or false
  stub.reset()
  return st, g
end
-- Texts the footer draws for `det` (both Text and TextColored).
local function footerTexts(st, det)
  local texts = {}
  with({
    ImGui_Text = function(_c, s) texts[#texts + 1] = s end,
    ImGui_TextColored = function(_c, _col, s) texts[#texts + 1] = s end,
  }, function() generate.drawFooter(CTX, st, det) end)
  return table.concat(texts, "|")
end
-- Every point the stub recorded, as a list of times (track/take non-Ex inserts, then automation-item Ex).
local function insertedTimes()
  local ts = {}
  for _, p in ipairs(stub.rec.ins) do ts[#ts + 1] = p.t end
  for _, p in ipairs(stub.rec.insEx) do ts[#ts + 1] = p.t end
  return ts
end
local function inAny(t, spans)
  for _, s in ipairs(spans) do if t >= s[1] - 1e-6 and t <= s[2] + 1e-6 then return true end end
  return false
end

h.test("common.spansFor: razor wins, Entire item ignores it, no razor fields = today's span", function()
  stub.reset()
  local gT, gE = { scope = common.SCOPE_TIMESEL }, { scope = common.SCOPE_ENTIRE }
  -- no razor fields at all: today's single time-selection span (clamped to an automation item's bounds)
  local det = detAI(); det.t0, det.t1 = -2, 14
  local spans = common.spansFor(target.fromContext(det), det, gT)
  h.eq(#spans, 1); h.almost(spans[1][1], 0); h.almost(spans[1][2], 10)
  -- razor source: the ranges, verbatim and as a COPY (later changes to detected.ranges must not leak in)
  det = razor(detAI(), { { 1, 2 }, { 4, 5 } })
  spans = common.spansFor(target.fromContext(det), det, gT)
  h.eq(#spans, 2); h.almost(spans[1][1], 1); h.almost(spans[1][2], 2); h.almost(spans[2][1], 4); h.almost(spans[2][2], 5)
  det.ranges[1][1] = 99
  h.almost(spans[1][1], 1, 1e-9, "spansFor returns a copy")
  -- the razor area beats the time selection (det carries t0=0, t1=4)
  det = razor(detEnv(), { { 2, 3 } })
  spans = common.spansFor(target.fromContext(det), det, gT)
  h.eq(#spans, 1); h.almost(spans[1][1], 2); h.almost(spans[1][2], 3)
  -- "Entire item" ignores razor areas: one span equal to fullSpan
  det = razor(detAI(), { { 2, 3 } })
  local tgt = target.fromContext(det)
  local a, b = tgt:fullSpan()
  spans = common.spansFor(tgt, det, gE)
  h.eq(#spans, 1); h.almost(spans[1][1], a); h.almost(spans[1][2], b)
  -- an area that falls outside the item: NO span (never the time selection)
  det = detAI(); det.rangeSource, det.ranges, det.hasRange, det.razorOutside = "razor", {}, false, true
  h.eq(#common.spansFor(target.fromContext(det), det, gT), 0)
  -- MIDI CC never takes razor ranges: one span, the time selection
  det = razor(detCC(), { { 1, 2 }, { 3, 4 } })
  spans = common.spansFor(target.fromContext(det), det, gT)
  h.eq(#spans, 1, "CC stays on one span")
  -- spanFor stays: the first span's t0, t1
  local s0, s1 = common.spanFor(target.fromContext(detAI()), razor(detAI(), { { 1, 2 }, { 4, 5 } }), gT)
  h.almost(s0, 1); h.almost(s1, 2)
  -- [M7] ...and with no span at all (a razor area outside the item) it is nil, never the time selection
  det = detAI(); det.rangeSource, det.ranges, det.hasRange, det.razorOutside = "razor", {}, false, true
  local n0, n1 = common.spanFor(target.fromContext(det), det, gT)
  h.eq(n0, nil, "no span: nil, not the time selection"); h.eq(n1, nil)
end)

h.test("Generate writes one LFO per razor area in one Undo step", function()
  local st, g = sineState(false)
  local det = razor(detEnv(), { { 0, 1 }, { 2, 3 } })
  generate.run(st, det, g)
  h.truthy(not g.statusErr, "run errored: " .. tostring(g.status))
  h.eq(stub.rec.undoBlocks, 1, "ONE Undo block for both areas")
  local spans = { { 0, 1 }, { 2, 3 } }
  local first, firstV = {}, {}
  for _, p in ipairs(stub.rec.ins) do
    h.truthy(inAny(p.t, spans), "point outside every area: " .. p.t)
    local k = p.t <= 1 + 1e-6 and 1 or 2
    if first[k] == nil or p.t < first[k] then first[k] = p.t; firstV[k] = p.v end
  end
  h.truthy(first[1] and first[2], "both areas received points")
  h.almost(first[1], 0, 1e-6, "area 1 starts at its t0")
  h.almost(first[2], 2, 1e-6, "area 2 starts at its t0")
  h.almost(firstV[1], firstV[2], 1e-9, "each area's LFO starts at its own start (same phase)")
  h.eq(#stub.rec.delRange, 2, "one range delete per area")
  h.eq(g.status, ("Wrote %d envelope points"):format(#stub.rec.ins), "status carries the summed count")
end)

h.test("a razor area beats the time selection", function()
  local st, g = sineState(false)
  local det = razor(detEnv(), { { 2, 3 } })      -- detEnv() still carries t0=0, t1=4, hasTimeSel=true
  generate.run(st, det, g)
  h.truthy(not g.statusErr, tostring(g.status))
  h.truthy(#stub.rec.ins > 0, "wrote")
  for _, p in ipairs(stub.rec.ins) do h.truthy(p.t >= 2 - 1e-6 and p.t <= 3 + 1e-6, "point outside the razor area: " .. p.t) end
end)

h.test("a razor area is a range even without a time selection", function()
  local st, g = sineState(false)
  local det = razor(detEnv(), { { 1, 2 } }); det.hasTimeSel = false
  generate.run(st, det, g)
  h.truthy(not g.statusErr, tostring(g.status))
  h.truthy(#stub.rec.ins > 0, "wrote")
  for _, p in ipairs(stub.rec.ins) do h.truthy(p.t >= 1 - 1e-6 and p.t <= 2 + 1e-6, "outside: " .. p.t) end
end)

h.test("Entire item ignores razor areas when generating", function()
  local st, g = sineState(false)
  g.scope = common.SCOPE_ENTIRE
  local det = razor(detAI(), { { 2, 3 } })
  generate.run(st, det, g)
  h.truthy(not g.statusErr, tostring(g.status))
  h.eq(#stub.rec.delRangeEx, 1, "one span")
  h.almost(stub.rec.delRangeEx[1][2], 0); h.almost(stub.rec.delRangeEx[1][3], 10)   -- the AI's own bounds
end)

h.test("the Undo label of a multi-area write is target-aware and the flag is ALL", function()
  local cases = {
    { det = function() return razor(detEnv(),  { { 0, 1 }, { 2, 3 } }) end, label = "Contour: Generate envelope LFO" },
    { det = function() return razor(detAI(),   { { 0, 1 }, { 2, 3 } }) end, label = "Contour: Generate automation-item LFO" },
    { det = function() return razor(detTake(), { { 3, 4 }, { 5, 6 } }) end, label = "Contour: Generate take-envelope LFO" },
  }
  for _, c in ipairs(cases) do
    local st, g = sineState(false)
    local ends = {}
    with({ Undo_EndBlock2 = function(_p, label, flag) ends[#ends + 1] = { label, flag } end }, function()
      generate.run(st, c.det(), g)
    end)
    h.truthy(not g.statusErr, tostring(g.status))
    h.eq(#stub.rec.delRange + #stub.rec.delRangeEx, 2, c.label .. ": both areas written")
    h.eq(stub.rec.undoBlocks, 1, c.label .. ": one Begin")
    h.eq(#ends, 1, c.label .. ": one End")
    h.eq(ends[1][1], c.label); h.eq(ends[1][2], -1)
  end
end)

h.test("a single area keeps today's self-contained write (one Undo block, same label)", function()
  local st, g = sineState(false)
  local ends = {}
  with({ Undo_EndBlock2 = function(_p, label, flag) ends[#ends + 1] = { label, flag } end }, function()
    generate.run(st, razor(detEnv(), { { 1, 2 } }), g)
  end)
  h.eq(stub.rec.undoBlocks, 1); h.eq(#ends, 1)
  h.eq(ends[1][1], "Contour: Generate envelope LFO"); h.eq(ends[1][2], -1)
end)

-- Live drag: the span list is frozen when the gesture opens. A body edit (Baseline) drives each frame; the
-- stubbed IsAnyItemActive keeps the gesture open between frames.
local function liveFrame(st, det)
  with({
    ImGui_SliderInt = function(_c, label, v) return label:find("gen_base", 1, true) ~= nil, v end,
    ImGui_IsAnyItemActive = function() return true end,
  }, function()
    generate.drawBody(CTX, st, det)
    generate.drawFooter(CTX, st, det)
  end)
end

h.test("live preview writes every razor area each frame", function()
  local st, g = sineState(true)
  local det = razor(detEnv(), { { 0, 1 }, { 2, 3 } })
  local ok, err = pcall(liveFrame, st, det)
  generate.cleanup()
  h.truthy(ok, tostring(err))
  h.eq(#stub.rec.delRange, 2, "one range delete per area, in one frame")
  local seen = { false, false }
  for _, p in ipairs(stub.rec.ins) do
    h.truthy(inAny(p.t, { { 0, 1 }, { 2, 3 } }), "outside: " .. p.t)
    if p.t <= 1 + 1e-6 then seen[1] = true else seen[2] = true end
  end
  h.truthy(seen[1] and seen[2], "both areas written")
  h.eq(stub.rec.undoBlocks, 1, "one gesture block")
end)

h.test("frozen spans during a live drag", function()
  local st, g = sineState(true)
  local det = razor(detEnv(), { { 0, 1 } })
  local ok, err = pcall(function()
    liveFrame(st, det)
    local after1 = #stub.rec.ins
    h.truthy(after1 > 0, "first frame wrote")
    det.ranges = { { 2, 3 } }                      -- the razor area changes in the middle of the drag
    det.hasRange = true
    liveFrame(st, det)
    h.truthy(#stub.rec.ins > after1, "second frame wrote too")
    for _, p in ipairs(stub.rec.ins) do h.truthy(p.t >= -1e-6 and p.t <= 1 + 1e-6, "write left the frozen span: " .. p.t) end
    for _, d in ipairs(stub.rec.delRange) do h.almost(d[1], 0); h.almost(d[2], 1) end
    h.eq(stub.rec.undoBlocks, 1, "still ONE block")
  end)
  generate.cleanup()
  h.truthy(ok, tostring(err))
end)

h.test("a lane change ends the live gesture before anything writes to the new lane", function()
  local st, g = sineState(true)
  local log = {}
  local function detOn(env) local d = detEnv(); d.details = { env = env }; return d end
  local over = {
    Undo_BeginBlock2 = function() log[#log + 1] = "begin"; stub.rec.undoBlocks = stub.rec.undoBlocks + 1 end,
    Undo_EndBlock2 = function() log[#log + 1] = "end" end,
    InsertEnvelopePoint = function(e) log[#log + 1] = "ins:" .. tostring(e); return true end,
  }
  local ok, err = pcall(function()
    with(over, function()
      liveFrame(st, detOn("ENV_A"))
      h.eq(#log > 0 and log[1], "begin")
      local ends = 0
      for _, e in ipairs(log) do if e == "end" then ends = ends + 1 end end
      h.eq(ends, 0, "gesture open on ENV_A")
      liveFrame(st, detOn("ENV_B"))
    end)
  end)
  generate.cleanup()
  h.truthy(ok, tostring(err))
  local endAt, firstB, lastA
  for i, e in ipairs(log) do
    if e == "end" and not endAt then endAt = i end
    if e == "ins:ENV_B" and not firstB then firstB = i end
    if e == "ins:ENV_A" then lastA = i end
  end
  h.truthy(endAt, "the ENV_A gesture was closed (EndBlock2)")
  h.truthy(firstB, "the new lane was written")
  h.truthy(lastA < endAt and endAt < firstB, "end comes after the last ENV_A write and before the first ENV_B write")
  h.eq(stub.rec.undoBlocks, 2, "ENV_B opened its own block")
end)

h.test("hints: outside, range, and no hint change for a user without a razor area", function()
  -- the razor area is outside the automation item
  local st, g = sineState(false)
  local det = detAI(); det.rangeSource, det.ranges, det.hasRange, det.razorOutside = "razor", {}, false, true
  h.truthy(footerTexts(st, det):find(HINT_OUTSIDE_AI, 1, true), "AI outside hint")
  -- ... or outside the item (take envelope)
  det = detTake(); det.rangeSource, det.ranges, det.hasRange, det.razorOutside = "razor", {}, false, true
  local txt = footerTexts(st, det)
  h.truthy(txt:find(HINT_OUTSIDE_IT, 1, true), "take envelope outside hint")
  h.truthy(not txt:find(HINT_OUTSIDE_AI, 1, true), "...and not the AI text")
  -- no range at all (no razor fields): the new range hint (on a target with an item: a track envelope has no
  -- Entire item, see "hints and messages follow the target")
  det = detAI(); det.hasTimeSel = false
  h.truthy(footerTexts(st, det):find(HINT_RANGE, 1, true), "range hint")
  det = detAI(); det.hasTimeSel = false; det.rangeSource, det.ranges, det.hasRange, det.razorOutside = "timesel", {}, false, false
  h.truthy(footerTexts(st, det):find(HINT_RANGE, 1, true), "range hint (descriptor with the new fields)")
  -- "Entire item" does not need a range, so neither hint shows
  g.scope = common.SCOPE_ENTIRE
  det = detAI(); det.rangeSource, det.ranges, det.hasRange, det.razorOutside = "razor", {}, false, true
  txt = footerTexts(st, det)
  h.truthy(not txt:find("razor area", 1, true), "Entire item: no razor hint")
  -- a descriptor with a range shows neither
  g.scope = common.SCOPE_TIMESEL
  txt = footerTexts(st, detEnv())
  h.truthy(not txt:find("Make a time selection", 1, true) and not txt:find("razor area", 1, true), "ready: no hint")
end)

h.test("a razor area outside the item writes nothing, live or on Generate", function()
  local st, g = sineState(true)
  local det = detAI(); det.rangeSource, det.ranges, det.hasRange, det.razorOutside = "razor", {}, false, true
  local ok, err = pcall(liveFrame, st, det)
  generate.cleanup()
  h.truthy(ok, tostring(err))
  h.eq(#insertedTimes(), 0, "live: nothing written")
  h.eq(stub.rec.undoBlocks, 0, "live: no undo block opened")
  g.live = false
  generate.run(st, det, g)
  h.truthy(g.statusErr, "run reports an error")
  h.eq(g.status, HINT_OUTSIDE_AI)
  h.eq(#insertedTimes(), 0, "run: nothing written")
  h.eq(stub.rec.undoBlocks, 0)
  -- hasTimeSel stays true on this descriptor, so only hasRange can be what blocks it
  h.truthy(det.hasTimeSel)
end)

-- ---- razor areas in the shell: the context line, the lane chooser and the lane switch ---------------------------
local context = require("core.context")
local CHOOSER_ID = "##razor_lane"
local function lane(guid, env, label) return { guid = guid, env = env, label = label } end
local function lanes3()
  return { lane("{P}", "ENV_P", "Pad: Volume"), lane("{D}", "ENV_D", "Drums: Volume"), lane("{B}", "ENV_B", "Bass: Pan") }
end
-- A detected descriptor whose target lane has razor `ranges`, with `lanes` covered by razor areas in the project.
local function razorDet(det, ranges, covered)
  det.rangeSource, det.ranges, det.hasRange, det.razorOutside = "razor", ranges, #ranges > 0, false
  det.razorLanes = covered or {}
  return det
end
-- One shell frame with the header calls recorded in order. Returns the log joined by "|" (entries "text:<s>",
-- "same", "check:<label>", "width:<n>", "combo:<id>=<preview>", "sel:<label>", "endcombo"), the colour each
-- text was drawn in, and the ok/error of the frame. opts.pick: the lane (as it reads, without the "##lane<i>"
-- ID suffix) whose Selectable reports a click; opts.boom: the lane whose Selectable throws.
local function plain(label) return (label:gsub("##.*$", "")) end
local function headerFrame(st, det, opts)
  opts = opts or {}
  local log, cols = {}, {}
  local function add(s) log[#log + 1] = s end
  local origBegin, origEnd = reaper.ImGui_BeginCombo, reaper.ImGui_EndCombo
  local ok, err
  stub.reset()
  with({
    ImGui_Text = function(_c, s) add("text:" .. s); cols[s] = false end,
    ImGui_TextColored = function(_c, col, s) add("text:" .. s); cols[s] = col end,
    ImGui_SameLine = function() add("same") end,
    ImGui_Checkbox = function(_c, label, v) add("check:" .. label); return false, v end,
    ImGui_SetNextItemWidth = function(_c, w) add("width:" .. tostring(w)) end,
    ImGui_BeginCombo = function(c, id, preview, ...) add("combo:" .. id .. "=" .. tostring(preview)); return origBegin(c, id, preview, ...) end,
    ImGui_EndCombo = function(...) add("endcombo"); return origEnd(...) end,
    ImGui_Selectable = function(_c, label)
      add("sel:" .. label)
      if opts.boom == plain(label) then error("chooser boom") end
      return opts.pick == plain(label)
    end,
  }, function() ok, err = pcall(shell.draw, CTX, st, det) end)
  return table.concat(log, "|"), cols, ok, err
end

h.test("context line shows the razor range, dim, in place of the time selection", function()
  local det = razorDet(detEnv(), { { 1.2, 1.95 } })
  local log, cols = headerFrame(newState(), det)
  h.truthy(log:find("text:Razor 1.200 .. 1.950 s", 1, true), "one area: " .. log)
  h.eq(cols["Razor 1.200 .. 1.950 s"], theme.C.textDim, "the range text is dim")
  h.truthy(not log:find("0.000 .. 4.000 s", 1, true), "the time selection text is replaced")
  -- the label comes first, then the range, on the same line
  h.truthy(log:find("text:Pan|same|text:Razor 1.200", 1, true), "label, SameLine, range")
  -- several areas: the count, then first start .. last end
  det = razorDet(detEnv(), { { 1, 2 }, { 5, 6 } })
  log = headerFrame(newState(), det)
  h.truthy(log:find("text:Razor ×2, 1.000 .. 6.000 s", 1, true), "two areas: " .. log)
  -- a time-selection range keeps today's text
  det = detEnv(); det.rangeSource, det.ranges, det.hasRange, det.razorOutside, det.razorLanes = "timesel", { { 0, 4 } }, true, false, {}
  log = headerFrame(newState(), det)
  h.truthy(log:find("text:0.000 .. 4.000 s", 1, true), "time selection text: " .. log)
  h.truthy(not log:find("Razor", 1, true), "no razor text without a razor range")
  det = detNone(); det.rangeSource, det.ranges, det.hasRange, det.razorOutside, det.razorLanes = "timesel", {}, false, false, {}
  log = headerFrame(newState(), det)
  h.truthy(log:find("text:No time selection", 1, true), "no range, no selection: the hint stays")
end)

h.test("context line: a razor area outside the item or automation item shows the hint", function()
  h.truthy(theme.C.hint ~= theme.C.textDim, "the two colours differ, so the assertions below mean something")
  local det = detAI(); det.rangeSource, det.ranges, det.hasRange, det.razorOutside, det.razorLanes = "razor", {}, false, true, {}
  local log, cols = headerFrame(newState(), det)
  h.truthy(log:find("text:" .. HINT_OUTSIDE_AI, 1, true), "automation item: " .. log)
  h.eq(cols[HINT_OUTSIDE_AI], theme.C.hint, "the outside text uses the hint colour")
  h.truthy(not log:find("No time selection", 1, true) and not log:find("0.000 .. 4.000 s", 1, true), "it replaces the time selection text")
  det = detTake(); det.rangeSource, det.ranges, det.hasRange, det.razorOutside, det.razorLanes = "razor", {}, false, true, {}
  log, cols = headerFrame(newState(), det)
  h.truthy(log:find("text:" .. HINT_OUTSIDE_IT, 1, true), "take envelope: " .. log)
  h.truthy(not log:find(HINT_OUTSIDE_AI, 1, true), "...and not the automation item text")
  h.eq(cols[HINT_OUTSIDE_IT], theme.C.hint)
end)

h.test("chooser lists covered lanes, preview names the target or says choose a lane", function()
  -- the target is not one of the covered lanes
  local det = razorDet(detEnv(), { { 1, 2 } }, lanes3())
  local log = headerFrame(newState(), det)
  h.truthy(log:find("text:Razor on 3 lanes:", 1, true), "label: " .. log)
  h.truthy(log:find("width:170|combo:" .. CHOOSER_ID .. "=choose a lane", 1, true), "width 170, placeholder preview: " .. log)
  h.truthy(log:find("sel:Pad: Volume##lane1|sel:Drums: Volume##lane2|sel:Bass: Pan##lane3|endcombo", 1, true),
    "entries in order with their own IDs, then EndCombo: " .. log)
  -- the target is a covered lane: its label is the preview
  det = razorDet(detEnv(), { { 1, 2 } }, lanes3()); det.details.env = "ENV_D"
  log = headerFrame(newState(), det)
  h.truthy(log:find("combo:" .. CHOOSER_ID .. "=Drums: Volume", 1, true), "target label as preview: " .. log)
  -- two lanes already make a chooser; none and one do not
  for n, covered in pairs({ [0] = {}, [1] = { lane("{P}", "ENV_P", "Pad: Volume") } }) do
    log = headerFrame(newState(), razorDet(detEnv(), { { 1, 2 } }, covered))
    h.truthy(not log:find(CHOOSER_ID, 1, true), n .. " covered lanes: no chooser")
  end
  log = headerFrame(newState(), razorDet(detEnv(), { { 1, 2 } }, { lane("{P}", "ENV_P", "Pad: Volume"), lane("{D}", "ENV_D", "Drums: Volume") }))
  h.truthy(log:find("text:Razor on 2 lanes:", 1, true), "two lanes: " .. log)
  -- a descriptor without razor fields draws no chooser and no razor text
  log = headerFrame(newState(), detEnv())
  h.truthy(not log:find(CHOOSER_ID, 1, true) and not log:find("Razor", 1, true), "no razor fields: nothing new")
end)

h.test("two lanes with the same name get distinct entry labels, and no ID scope is pushed", function()
  -- Two tracks named "Pad" both list "Pad: Volume"; the same label would give both the same ImGui ID, so a click
  -- on one would hit the other. The ID is part of the label (after "##"), so there is no PushID to balance.
  local same = { lane("{1}", "ENV_1", "Pad: Volume"), lane("{2}", "ENV_2", "Pad: Volume") }
  local labels, pushes = {}, 0
  stub.reset()
  with({
    ImGui_PushID = function() pushes = pushes + 1 end,
    ImGui_Selectable = function(_c, label)
      if label:find("^Pad: Volume##") then labels[#labels + 1] = label end
      return label == "Pad: Volume##lane2"   -- click the second one
    end,
  }, function() shell.draw(CTX, newState(), razorDet(detEnv(), { { 1, 2 } }, same)) end)
  h.eq(#labels, 2, "both entries read 'Pad: Volume'")
  h.truthy(labels[1] ~= labels[2], "...with different IDs: " .. table.concat(labels, ","))
  h.eq(pushes, 0, "no PushID/PopID around the entries")
  h.eq(#stub.rec.cursorCtx, 1, "the click selected a lane")
  h.eq(stub.rec.cursorCtx[1].env, "ENV_2", "the second Pad, not the first")
end)

h.test("chooser sits on its own line under the context line, Follow stays on the first", function()
  for _, w in ipairs({ 360, 700 }) do
    local log
    atWidth(w, function() log = headerFrame(newState(), razorDet(detEnv(), { { 1, 2 } }, lanes3())) end)
    -- Follow closes line one; the chooser's label starts line two (no SameLine before it); the combo follows it
    h.truthy(log:find("check:Follow##follow|text:Razor on 3 lanes:|same|width:170|combo:", 1, true),
      "width " .. w .. ": " .. log)
  end
end)

h.test("a range text too long for the first line takes a line of its own, Follow stays on the first", function()
  -- At 360 px the outside hint alone is wider than the panel, and a long label pushes even a razor range off the line.
  local function longLabel() local d = detAI(); d.label = "Automation item #0 on Volume"; return d end
  local log
  atWidth(360, function() log = headerFrame(newState(), razorDet(longLabel(), { { 1.2, 1.95 } }, {})) end)
  h.truthy(log:find("text:Automation item #0 on Volume|same|check:Follow##follow|text:Razor 1.200 .. 1.950 s", 1, true),
    "360 px, long label: " .. log)
  atWidth(700, function() log = headerFrame(newState(), razorDet(longLabel(), { { 1.2, 1.95 } }, {})) end)
  h.truthy(log:find("text:Automation item #0 on Volume|same|text:Razor 1.200 .. 1.950 s|same|check:Follow##follow", 1, true),
    "700 px: all on one line: " .. log)
  -- the outside hint at 360 px (a short label)
  local det = detAI(); det.rangeSource, det.ranges, det.hasRange, det.razorOutside, det.razorLanes = "razor", {}, false, true, {}
  atWidth(360, function() log = headerFrame(newState(), det) end)
  h.truthy(log:find("text:AI|same|check:Follow##follow|text:" .. HINT_OUTSIDE_AI, 1, true), "outside hint under the line: " .. log)
  -- with the chooser: the range text, then the chooser, both under the first line
  atWidth(360, function() log = headerFrame(newState(), razorDet(longLabel(), { { 1.2, 1.95 } }, lanes3())) end)
  h.truthy(log:find("check:Follow##follow|text:Razor 1.200 .. 1.950 s|text:Razor on 3 lanes:|same|width:170|combo:", 1, true),
    "range text, then chooser: " .. log)
end)

h.test("the time selection text and the no-selection hint never wrap: no razor area, no layout change", function()
  -- A user who draws no razor area sees exactly today's line even with a label too long for it: one line, Follow
  -- clamped to just after the text.
  local function longLabel() local d = detAI(); d.label = "Automation item #0 on Volume"; return d end
  local function followX(det)
    local calls, xs, log = 0, {}, nil
    atWidth(360, function()
      with({
        -- the first read is the row's left edge; later reads are the cursor after the text, far to the right
        ImGui_GetCursorPosX = function() calls = calls + 1; return calls == 1 and 14 or 400 end,
        ImGui_SetCursorPosX = function(_c, x) xs[#xs + 1] = x end,
      }, function() log = headerFrame(newState(), det) end)
    end)
    return log, xs[1]
  end
  -- (a) the time selection (old fields only, and with the new fields as core/context.detect fills them)
  local det = longLabel(); det.hasTimeSel = true
  local log, x = followX(det)
  h.truthy(log:find("text:Automation item #0 on Volume|same|text:0.000 .. 4.000 s|same|check:Follow##follow", 1, true),
    "time selection stays on the first line: " .. log)
  h.eq(x, 400, "Follow clamped to just after the text, not right-aligned (302)")
  det = longLabel(); det.hasTimeSel = true
  det.rangeSource, det.ranges, det.hasRange, det.razorOutside, det.razorLanes = "timesel", { { 0, 4 } }, true, false, {}
  log = followX(det)
  h.truthy(log:find("text:Automation item #0 on Volume|same|text:0.000 .. 4.000 s|same|check:Follow##follow", 1, true),
    "time selection with the razor fields: " .. log)
  -- (b) no time selection at all
  det = longLabel(); det.hasTimeSel = false
  log, x = followX(det)
  h.truthy(log:find("text:Automation item #0 on Volume|same|text:No time selection|same|check:Follow##follow", 1, true),
    "the no-selection hint stays on the first line: " .. log)
  h.eq(x, 400, "Follow clamped to just after the hint")
  -- (c) a razor text of the same label DOES wrap, and Follow is then right-aligned (302 = 14 + 360 - 72)
  det = razorDet(longLabel(), { { 1.2, 1.95 } }, {})
  local calls, xs = 0, {}
  atWidth(360, function()
    with({
      ImGui_GetCursorPosX = function() calls = calls + 1; return calls == 1 and 14 or 100 end,
      ImGui_SetCursorPosX = function(_c, xx) xs[#xs + 1] = xx end,
    }, function() log = headerFrame(newState(), det) end)
  end)
  h.truthy(log:find("check:Follow##follow|text:Razor 1.200 .. 1.950 s", 1, true), "razor text wrapped: " .. log)
  h.eq(xs[1], 302, "Follow right-aligned on the first line")
end)

h.test("clicking a lane selects its envelope, then marks the arrange as engaged", function()
  local order = {}
  local savedEngage = context.engageArrange
  context.engageArrange = function() order[#order + 1] = "engage" end
  local det = razorDet(detEnv(), { { 1, 2 } }, lanes3())
  local ok, err = pcall(function()
    local log, _, fok, ferr = headerFrame(newState(), det, { pick = "Drums: Volume" })
    h.truthy(fok, tostring(ferr))
    h.truthy(log:find("sel:Drums: Volume", 1, true))
  end)
  context.engageArrange = savedEngage
  h.truthy(ok, tostring(err))
  -- headerFrame resets the stub first, so the recorded click is what this frame did
  h.eq(#stub.rec.cursorCtx, 1, "one SetCursorContext call")
  h.eq(stub.rec.cursorCtx[1].mode, 2, "mode 2: select an envelope")
  h.eq(stub.rec.cursorCtx[1].env, "ENV_D", "the clicked lane's envelope")
  h.eq(table.concat(order, ","), "engage", "engageArrange ran once")
  -- no click, no call
  headerFrame(newState(), det)
  h.eq(#stub.rec.cursorCtx, 0, "no click: no SetCursorContext")
end)

h.test("a click is applied after the combo closes (EndCombo first, then the switch)", function()
  local seq = {}
  local det = razorDet(detEnv(), { { 1, 2 } }, lanes3())
  local ok, err
  stub.reset()
  with({
    ImGui_EndCombo = function() seq[#seq + 1] = "endcombo"; stub.rec.comboEnd = stub.rec.comboEnd + 1 end,
    ImGui_Selectable = function(_c, label) return label:find("^Pad: Volume##") ~= nil end,
    SetCursorContext = function(m, e) seq[#seq + 1] = "set:" .. tostring(e) end,
  }, function() ok, err = pcall(shell.draw, CTX, newState(), det) end)
  h.truthy(ok, tostring(err))
  -- the chooser's EndCombo precedes the switch (Generate's own Shape combo may add its own endcombo after)
  h.eq(seq[1], "endcombo", "the combo closes first")
  h.eq(seq[2], "set:ENV_P", "then the pick is applied")
end)

h.test("chooser: BeginCombo/EndCombo balance at 360 and 700 px", function()
  for _, w in ipairs({ 360, 700 }) do
    for _, covered in ipairs({ lanes3(), { lane("{P}", "ENV_P", "Pad: Volume"), lane("{D}", "ENV_D", "Drums: Volume") } }) do
      local label = ("razor chooser width=%d lanes=%d"):format(w, #covered)
      local log, _, ok, err
      atWidth(w, function()
        log, _, ok, err = headerFrame(newState(), razorDet(detEnv(), { { 1, 2 } }, covered))
      end)
      h.truthy(ok, label .. " threw: " .. tostring(err))
      h.truthy(log:find("combo:" .. CHOOSER_ID, 1, true), label .. ": the chooser opened a combo")
      balanced(label)
    end
  end
end)

h.test("a throw inside the chooser still EndCombos and re-raises", function()
  local det = razorDet(detEnv(), { { 1, 2 } }, lanes3())
  local log, _, ok, err = headerFrame(newState(), det, { boom = "Drums: Volume" })
  h.truthy(not ok and tostring(err):find("chooser boom", 1, true), "the error is re-raised: " .. tostring(err))
  h.truthy(log:find("sel:Drums: Volume##lane2|endcombo", 1, true), "EndCombo ran right after the throw: " .. log)
  balanced("chooser throw")
  h.eq(#stub.rec.cursorCtx, 0, "nothing was selected")
end)

h.test("one covered lane that is not the target: 'Razor on 1 other lane', no chooser", function()
  local det = razorDet(detEnv(), { { 1, 2 } }, { lane("{P}", "ENV_P", "Pad: Volume") })
  det.rangeSource, det.ranges, det.hasRange = "timesel", { { 0, 4 } }, true   -- the razor is on another lane
  local log, cols = headerFrame(newState(), det)
  h.truthy(log:find("text:Razor on 1 other lane", 1, true), log)
  h.eq(cols["Razor on 1 other lane"], theme.C.textDim)
  h.truthy(not log:find(CHOOSER_ID, 1, true), "no chooser for one lane")
  -- the one lane IS the target: its range text says it all
  det = razorDet(detEnv(), { { 1, 2 } }, { lane("{P}", "ENV_P", "Pad: Volume") }); det.details.env = "ENV_P"
  log = headerFrame(newState(), det)
  h.truthy(not log:find("other lane", 1, true), "the target's own lane is not 'other': " .. log)
  h.truthy(log:find("text:Razor 1.000 .. 2.000 s", 1, true))
  -- a MIDI CC target has no envelope: the one lane is another lane
  det = razorDet(detCC(), {}, { lane("{P}", "ENV_P", "Pad: Volume") })
  det.rangeSource, det.ranges, det.hasRange = "timesel", { { 0, 4 } }, true
  log = headerFrame(newState(), det)
  h.truthy(log:find("text:Razor on 1 other lane", 1, true), "CC target: " .. log)
end)

h.test("the lane switch happens only with Follow on", function()
  local det = detEnv(); det.razorSwitchTo = "ENV_B"
  stub.reset()
  local st = newState(); st.follow = true
  shell.draw(CTX, st, det)
  h.eq(#stub.rec.cursorCtx, 1, "Follow on: one SetCursorContext")
  h.eq(stub.rec.cursorCtx[1].mode, 2)
  h.eq(stub.rec.cursorCtx[1].env, "ENV_B")
  stub.reset()
  st = newState(); st.follow = false
  shell.draw(CTX, st, det)
  h.eq(#stub.rec.cursorCtx, 0, "Follow off: nothing")
  stub.reset()
  shell.draw(CTX, newState(), detEnv())
  h.eq(#stub.rec.cursorCtx, 0, "no razorSwitchTo: nothing")
end)

h.test("the lane switch marks the arrange as engaged, like a chooser pick", function()
  local engaged = 0
  local saved = context.engageArrange
  context.engageArrange = function() engaged = engaged + 1 end
  local det = detEnv(); det.razorSwitchTo = "ENV_B"
  stub.reset()
  local ok, err = pcall(shell.draw, CTX, newState(), det)
  context.engageArrange = saved
  h.truthy(ok, tostring(err))
  h.eq(engaged, 1, "engageArrange ran once")
end)

-- [F2] The target lane is already the selected envelope: SetCursorContext(2, env) would only risk dropping an
-- automation-item selection on it, so it is skipped. engageArrange still runs (a MIDI CC selection may be active).
local function countEngage(fn)
  local engaged, saved = 0, context.engageArrange
  context.engageArrange = function() engaged = engaged + 1 end
  local ok, err = pcall(fn)
  context.engageArrange = saved
  h.truthy(ok, tostring(err))
  return engaged
end

h.test("[F2] the settled-drag switch to the lane that is already the target does not re-select it", function()
  local det = detEnv(); det.details.env = "ENV_B"; det.razorSwitchTo = "ENV_B"
  local engaged = countEngage(function() stub.reset(); shell.draw(CTX, newState(), det) end)
  h.eq(#stub.rec.cursorCtx, 0, "no SetCursorContext when the target already is that envelope")
  h.eq(engaged, 1, "engageArrange still ran once")
  -- an automation item selected on that envelope: the same, which is the point
  det = detAI(); det.details.env = "ENV_B"; det.razorSwitchTo = "ENV_B"
  engaged = countEngage(function() stub.reset(); shell.draw(CTX, newState(), det) end)
  h.eq(#stub.rec.cursorCtx, 0, "automation item target: its envelope is not re-selected")
  h.eq(engaged, 1)
  -- another lane is still selected
  det = detEnv(); det.details.env = "ENV_A"; det.razorSwitchTo = "ENV_B"
  engaged = countEngage(function() stub.reset(); shell.draw(CTX, newState(), det) end)
  h.eq(#stub.rec.cursorCtx, 1, "a different lane is selected"); h.eq(stub.rec.cursorCtx[1].env, "ENV_B")
  h.eq(engaged, 1)
end)

h.test("[F2] a chooser pick of the lane that is already the target does not re-select it", function()
  local det = razorDet(detEnv(), { { 1, 2 } }, lanes3()); det.details.env = "ENV_D"
  local engaged = countEngage(function() headerFrame(newState(), det, { pick = "Drums: Volume" }) end)
  h.eq(#stub.rec.cursorCtx, 0, "no SetCursorContext for the current target lane")
  h.eq(engaged, 1, "engageArrange still ran once")
  -- picking another lane still selects it
  det = razorDet(detEnv(), { { 1, 2 } }, lanes3()); det.details.env = "ENV_D"
  engaged = countEngage(function() headerFrame(newState(), det, { pick = "Pad: Volume" }) end)
  h.eq(#stub.rec.cursorCtx, 1); h.eq(stub.rec.cursorCtx[1].env, "ENV_P")
  h.eq(engaged, 1)
end)

-- ---- razor areas: Transform's "Time selection" scope takes the lane's one razor area ----------------------
-- The stub's fixture points sit at t = 0, 2, 4 and are all selected, so these tests either hand the overlay
-- the panel's "timesel" scope (ExtState tr_scope, consumed by start) or deselect the points first.
local MSG_ONE_AREA = "Transform needs one razor area on this lane"
local function trParams()
  overlay.params = { knob = 30, shape = "power", symmetrical = false, flipMode = "absolute" }
end
local function deselectPoints()
  for _, list in ipairs({ stub.envPoints, stub.aiPoints }) do   -- track envelope, automation item
    for _, p in ipairs(list) do p.sel = false end
  end
end

h.test("overlay uses the single razor area", function()
  stub.reset(); trParams()
  stub.rec.extState.tr_scope = "timesel"
  -- the time selection is 0..4; the one razor area is 2..4, so the point at t = 0 stays outside the region
  local started, serr = overlay.start(CTX, razor(detEnv(), { { 2, 4 } }))
  h.truthy(started, "start: " .. tostring(serr))
  local b = overlay._boundsNow()
  h.almost(b.tmin, 2, 1e-9, "region starts at the razor area")
  h.almost(b.tmax, 4, 1e-9, "region ends at the razor area")
  overlay.finish()
  -- with no handoff and no selected points, a razor area alone is a range to work on
  stub.reset(); trParams(); deselectPoints()
  local det = razor(detEnv(), { { 2, 4 } }); det.hasTimeSel = false
  started, serr = overlay.start(CTX, det)
  h.truthy(started, "a razor area is a range even without a time selection: " .. tostring(serr))
  b = overlay._boundsNow()
  h.almost(b.tmin, 2); h.almost(b.tmax, 4)
  overlay.finish()
end)

h.test("two areas refuse", function()
  stub.reset(); trParams()
  stub.rec.extState.tr_scope = "timesel"
  local started, msg = overlay.start(CTX, razor(detEnv(), { { 0, 1 }, { 2, 3 } }))
  h.eq(started, false)
  h.eq(msg, MSG_ONE_AREA)
  -- no selected points and no handoff: the time-selection scope is all that is left, so it refuses too
  stub.reset(); trParams(); deselectPoints()
  started, msg = overlay.start(CTX, razor(detAI(), { { 0, 1 }, { 2, 3 } }))
  h.eq(started, false)
  h.eq(msg, MSG_ONE_AREA)
  -- selected points still work with several areas: the points scope never asks for a razor area
  stub.reset(); trParams()
  stub.rec.extState.tr_scope = "points"
  started = overlay.start(CTX, razor(detEnv(), { { 0, 1 }, { 2, 3 } }))
  h.truthy(started, "Selected points ignore the razor areas")
  overlay.finish()
end)

h.test("a razor area outside the item says so, never the time selection", function()
  stub.reset(); trParams(); deselectPoints()
  local det = detAI(); det.rangeSource, det.ranges, det.hasRange, det.razorOutside = "razor", {}, false, true
  local started, msg = overlay.start(CTX, det)
  h.eq(started, false)
  h.eq(msg, "The razor area is outside this automation item")
  stub.reset(); trParams(); deselectPoints()
  det = detEnv(); det.rangeSource, det.ranges, det.hasRange, det.razorOutside = "razor", {}, false, true
  started, msg = overlay.start(CTX, det)
  h.eq(started, false)
  h.eq(msg, "The razor area is outside this item")
  -- the time selection (0..4 on detEnv) is never the fallback: even with the time-selection handoff
  stub.reset(); trParams(); deselectPoints()
  stub.rec.extState.tr_scope = "timesel"
  started, msg = overlay.start(CTX, det)
  h.eq(started, false)
  h.eq(msg, "The razor area is outside this item")
end)

h.test("overlay: the time selection path is unchanged for descriptors without a razor", function()
  -- the old fields only
  stub.reset(); trParams()
  stub.rec.extState.tr_scope = "timesel"
  local started, serr = overlay.start(CTX, detEnv())
  h.truthy(started, tostring(serr))
  local b = overlay._boundsNow()
  h.almost(b.tmin, 0); h.almost(b.tmax, 4)
  overlay.finish()
  -- with the fields core/context.detect fills for a time selection
  stub.reset(); trParams()
  stub.rec.extState.tr_scope = "timesel"
  local det = detEnv()
  det.rangeSource, det.ranges, det.hasRange, det.razorOutside = "timesel", { { 0, 4 } }, true, false
  started, serr = overlay.start(CTX, det)
  h.truthy(started, tostring(serr))
  b = overlay._boundsNow()
  h.almost(b.tmin, 0); h.almost(b.tmax, 4)
  overlay.finish()
  -- no time selection and no selected points: today's message
  stub.reset(); trParams(); deselectPoints()
  det = detEnv(); det.hasTimeSel = false
  local msg
  started, msg = overlay.start(CTX, det)
  h.eq(started, false)
  h.eq(msg, "Select some points, or make a time selection or a razor area, then launch Transform")
end)

-- ---- razor areas: a direct run (the Transform action or its hotkey, no scope handed over) ------------------
-- A razor area that gives the target a range beats selected points (Danilo, 2026-11-01). The panel's
-- explicit "Selected points" scope still wins (covered in "two areas refuse").
h.test("direct run: a razor area beats selected points", function()
  stub.reset(); trParams()   -- the fixture points at t = 0, 2, 4 are all selected
  local started, serr = overlay.start(CTX, razor(detEnv(), { { 2, 4 } }))
  h.truthy(started, "start: " .. tostring(serr))
  local b = overlay._boundsNow()
  h.almost(b.tmin, 2, 1e-9, "the region is the razor area, not the selected points (0 .. 4)")
  h.almost(b.tmax, 4, 1e-9)
  overlay.finish()
end)

h.test("direct run: several razor areas refuse, also with selected points", function()
  stub.reset(); trParams()
  local started, msg = overlay.start(CTX, razor(detEnv(), { { 0, 1 }, { 2, 3 } }))
  h.eq(started, false)
  h.eq(msg, MSG_ONE_AREA)
end)

h.test("direct run: a razor area outside the target leaves selected points working", function()
  stub.reset(); trParams()
  local det = detAI(); det.rangeSource, det.ranges, det.hasRange, det.razorOutside = "razor", {}, false, true
  local started, serr = overlay.start(CTX, det)
  h.truthy(started, "selected points work when the razor area misses this automation item: " .. tostring(serr))
  local b = overlay._boundsNow()
  h.almost(b.tmin, 1); h.almost(b.tmax, 3)   -- the selected automation-item points at t = 1 and 3
  overlay.finish()
end)

h.test("direct run end to end: context.detect reads the razor area, Transform uses it over selected points", function()
  stub.reset(); trParams()
  -- a lower-case GUID, as a hand-edited project may store it; the area 1.5 .. 4.5 s holds the points at 2 and 4
  stub.tracks = { { handle = "TR1", name = "Synth", razor = '1.5 4.5 "{e1}"',
                    envs = { { handle = "ENV1", guid = "{E1}", name = "Pan" } } } }
  context._resetRazor(); context._resetRecency()   -- a direct run is a fresh script: fresh context state
  local det
  with({
    MIDIEditor_GetActive = function() return nil end,
    GetSelectedEnvelope = function() return "ENV1" end,
    CountAutomationItems = function() return 0 end,   -- a plain track envelope, no automation item
  }, function() det = context.detect() end)
  h.eq(det.target, "envelope")
  h.eq(det.rangeSource, "razor", "the razor area beats the 0 .. 4 s time selection")
  h.eq(#det.ranges, 1)
  local started, serr = overlay.start(CTX, det)
  h.truthy(started, "start: " .. tostring(serr))
  local b = overlay._boundsNow()
  -- _boundsNow spans the region's points: 2 .. 4 inside the razor area (the selected points alone give 0 .. 4)
  h.almost(b.tmin, 2, 1e-9, "the region is the points inside the razor area")
  h.almost(b.tmax, 4, 1e-9)
  overlay.finish()
  stub.tracks = {}
  context._resetRazor(); context._resetRecency()
end)

-- Draw the Transform panel for `det` with every Button clicked. Returns the warn-coloured and the other
-- texts, plus the BeginDisabled / EndDisabled calls (the stub's own BeginDisabled disables nothing, so the
-- panel must not trust it alone: the click is ignored in code too).
local function trPanelFrame(det, scope)
  stub.reset()
  transform_panel.scope = scope or "timesel"
  transform_panel.status = nil
  local warns, begins, ends = {}, {}, 0
  with({
    ImGui_TextColored = function(_c, col, s) if col == theme.C.warn then warns[#warns + 1] = s end end,
    ImGui_Button = function() return true end,
    ImGui_BeginDisabled = function(_c, d) begins[#begins + 1] = d end,
    ImGui_EndDisabled = function() ends = ends + 1 end,
  }, function() transform_panel.draw(CTX, newState(), det) end)
  return warns, begins, ends
end

h.test("panel message and disabled launch", function()
  local warns, begins, ends = trPanelFrame(razor(detEnv(), { { 0, 1 }, { 2, 3 } }))
  h.eq(#warns, 1, "one warning: " .. table.concat(warns, "|"))
  h.eq(warns[1], MSG_ONE_AREA)
  h.eq(#begins, 1); h.eq(begins[1], true, "Launch is disabled")
  h.eq(ends, 1, "BeginDisabled is closed")
  h.eq(stub.rec.extState.tr_scope, nil, "a click on the disabled Launch writes nothing")
  -- [R1] the Selected points scope never asks for a razor area: no message, Launch works. (The overlay itself
  -- refuses safely when it falls back to the time-selection scope.)
  warns, begins, ends = trPanelFrame(razor(detAI(), { { 0, 1 }, { 2, 3 }, { 5, 6 } }), "points")
  h.eq(#warns, 0, "Selected points: no warning (" .. table.concat(warns, "|") .. ")")
  h.eq(#begins, 1); h.eq(begins[1], false, "Selected points: Launch is enabled")
  h.eq(ends, 1, "BeginDisabled is closed")
  h.eq(stub.rec.extState.tr_scope, "points", "the click hands the points scope to the tool")
end)

h.test("[M6] a throw while Launch is drawn still closes BeginDisabled, then re-raises", function()
  stub.reset()
  transform_panel.scope, transform_panel.status = "timesel", nil
  local begins, ends = 0, 0
  local ok, err
  with({
    ImGui_Button = function() error("launch boom") end,
    ImGui_BeginDisabled = function() begins = begins + 1 end,
    ImGui_EndDisabled = function() ends = ends + 1 end,
  }, function() ok, err = pcall(transform_panel.draw, CTX, newState(), detEnv()) end)
  h.truthy(not ok and tostring(err):find("launch boom", 1, true), "the error is re-raised: " .. tostring(err))
  h.eq(begins, 1); h.eq(ends, 1, "EndDisabled ran although Launch threw")
end)

h.test("panel: one razor area, a time selection, or no descriptor keeps Launch enabled", function()
  local cases = {
    { "one razor area",   razor(detEnv(), { { 2, 4 } }) },
    { "time selection",   detEnv() },
    { "timesel fields",   (function() local d = detEnv(); d.rangeSource, d.ranges = "timesel", { { 0, 4 } }; return d end)() },
    { "razor, outside",   (function() local d = detAI(); d.rangeSource, d.ranges, d.razorOutside = "razor", {}, true; return d end)() },
    { "no descriptor",    nil },
  }
  for _, c in ipairs(cases) do
    local warns, begins, ends = trPanelFrame(c[2])
    h.eq(#warns, 0, c[1] .. ": no warning (" .. table.concat(warns, "|") .. ")")
    h.eq(#begins, 1, c[1] .. ": one BeginDisabled"); h.eq(begins[1], false, c[1] .. ": Launch is enabled")
    h.eq(ends, 1, c[1] .. ": balanced")
    h.eq(stub.rec.extState.tr_scope, "timesel", c[1] .. ": the click hands the scope to the tool")
  end
  -- shell hands its descriptor on to the panel (the body is the Transform panel on the Transform tab)
  stub.reset()
  transform_panel.scope = "timesel"
  local st = newState(); st.op = "transform"
  local shown = {}
  with({ ImGui_TextColored = function(_c, col, s) if col == theme.C.warn then shown[#shown + 1] = s end end },
    function() shell.draw(CTX, st, razor(detEnv(), { { 0, 1 }, { 2, 3 } })) end)
  h.truthy(table.concat(shown, "|"):find(MSG_ONE_AREA, 1, true), "shell.draw reaches the panel's message: " .. table.concat(shown, "|"))
end)

-- ---- Scope: one dropdown in every panel, the range option named after the lane's range ----------------------
-- Danilo, 2026-11-01: Scope is a dropdown in Generate, Reduce and Transform alike, and its range option says
-- what the range is right now: "Time selection", or "Razor area" / "Razor areas" when the target lane has
-- razor areas (they beat the time selection). MIDI CC has no razor areas, so it always says "Time selection".
-- The hints follow the target the same way: MIDI CC never asks for a razor area, and a track envelope (no
-- item) never offers Entire item.
h.test("common.rangeLabel names the range the lane has", function()
  h.eq(common.rangeLabel(nil), "Time selection", "nil-safe")
  h.eq(common.rangeLabel(detEnv()), "Time selection", "no razor fields")
  h.eq(common.rangeLabel(razor(detEnv(), { { 1, 2 } })), "Razor area")
  h.eq(common.rangeLabel(razor(detAI(), { { 1, 2 }, { 3, 4 } })), "Razor areas")
  local out = detAI(); out.rangeSource, out.ranges, out.hasRange, out.razorOutside = "razor", {}, false, true
  h.eq(common.rangeLabel(out), "Razor area", "an area outside the item still beats the time selection")
  h.eq(common.rangeLabel(razor(detCC(), { { 1, 2 } })), "Time selection", "MIDI CC never uses a razor area")
end)

h.test("common.rangeHint: what to make, then the scope that needs no range", function()
  h.eq(common.rangeHint(detEnv(), "Entire item"), HINT_RANGE)
  h.eq(common.rangeHint(nil, "Entire item"), HINT_RANGE, "nil-safe")
  h.eq(common.rangeHint(detCC(), "Entire item"), "Make a time selection (or switch Scope to Entire item).")
  h.eq(common.rangeHint(detEnv(), "Selected points"), "Make a time selection or a razor area (or switch Scope to Selected points).")
  h.eq(common.rangeHint(detEnv()), "Make a time selection or a razor area.")
  h.eq(common.noRangeText(detCC()), "No time selection")
  h.eq(common.noRangeText(detAI()), "No time selection or razor area")
end)

-- Every Scope dropdown that drawFn(det) draws: { label, items, cur } per ImGui_Combo call, and the number of
-- radio buttons. With `pick`, each Scope dropdown reports a click on that index.
local function scopeCombos(drawFn, det, pick)
  local combos, radios = {}, 0
  with({
    ImGui_Combo = function(_c, label, cur, items)
      if not label:find("^Scope##") then return false, cur end
      combos[#combos + 1] = { label = label, items = items, cur = cur }
      if pick then return true, pick end
      return false, cur
    end,
    ImGui_RadioButton = function() radios = radios + 1; return false end,
  }, function() drawFn(det) end)
  return combos, radios
end

h.test("Scope dropdowns: the range option follows the lane in Generate, Reduce and Transform", function()
  -- Generate (a track envelope has no Scope dropdown at all)
  stub.reset()
  local st = newState()
  local gen = function(d) generate.draw(CTX, st, d) end
  local combos = scopeCombos(gen, razor(detAI(), { { 0, 1 }, { 2, 3 } }))
  h.eq(#combos, 1, "Generate: one Scope dropdown")
  h.eq(combos[1].items, "Razor areas\0Entire item\0")
  h.eq(scopeCombos(gen, detCC())[1].items, "Time selection\0Entire item\0")
  h.eq(#scopeCombos(gen, razor(detEnv(), { { 1, 2 } })), 0, "Generate: no Scope for a track envelope")
  -- Reduce: a track envelope has no Entire item
  stub.reset()
  st = newState(); st.op = "reduce"
  local red = function(d) reduce.draw(CTX, st, d) end
  combos = scopeCombos(red, razor(detEnv(), { { 1, 2 } }))
  h.eq(#combos, 1, "Reduce: one Scope dropdown")
  h.eq(combos[1].items, "Razor area\0Selected points\0")
  h.eq(scopeCombos(red, detAI())[1].items, "Time selection\0Entire item\0Selected points\0")
  -- Transform: a dropdown, not radio buttons, with the range option first like the other panels
  stub.reset()
  transform_panel.scope = "points"
  local tr = function(d) transform_panel.draw(CTX, newState(), d) end
  local radios
  combos, radios = scopeCombos(tr, razor(detEnv(), { { 1, 2 } }))
  h.eq(radios, 0, "Transform: no radio buttons")
  h.eq(#combos, 1, "Transform: one Scope dropdown")
  h.eq(combos[1].label, "Scope##tr_scope")
  h.eq(combos[1].items, "Razor area\0Selected points\0")
  h.eq(combos[1].cur, 1, "Selected points is the second option")
  scopeCombos(tr, detEnv(), 0)
  h.eq(transform_panel.scope, "timesel", "the range option hands the time-selection scope to the tool")
  scopeCombos(tr, detEnv(), 1)
  h.eq(transform_panel.scope, "points")
  h.eq(scopeCombos(tr, razor(detCC(), { { 1, 2 } }))[1].items, "Time selection\0Selected points\0", "Transform on MIDI CC")
end)

h.test("hints and messages follow the target: MIDI CC asks for a time selection only, a track envelope never offers Entire item", function()
  -- Generate footer
  local st, g = sineState(false)
  local det = detCC(); det.hasTimeSel = false
  local txt = footerTexts(st, det)
  h.truthy(txt:find("Make a time selection (or switch Scope to Entire item).", 1, true), "Generate CC: " .. txt)
  h.truthy(not txt:find("razor", 1, true), "Generate CC: no razor area in the hint")
  -- a track envelope has no Scope dropdown, so the hint must not depend on the scope the state still holds
  for _, scope in ipairs({ common.SCOPE_TIMESEL, common.SCOPE_ENTIRE }) do
    g.scope = scope
    det = detEnv(); det.hasTimeSel = false
    txt = footerTexts(st, det)
    h.truthy(txt:find("Make a time selection or a razor area.", 1, true), "Generate track envelope, scope " .. scope .. ": " .. txt)
    h.truthy(not txt:find("Entire item", 1, true), "Generate track envelope: no Entire item")
  end
  g.scope = common.SCOPE_TIMESEL
  -- Generate status on a MIDI CC without a time selection
  det = detCC(); det.hasTimeSel = false
  generate.run(st, det, g)
  h.eq(g.status, "Make a time selection")
  -- Reduce hints
  stub.reset()
  local rst = newState(); rst.op = "reduce"
  local function redHints(d)
    local seen = {}
    with({ ImGui_TextColored = function(_c, _col, s) seen[#seen + 1] = s end }, function() reduce.draw(CTX, rst, d) end)
    return table.concat(seen, "|")
  end
  det = detEnv(); det.hasTimeSel = false
  txt = redHints(det)
  h.truthy(txt:find("Make a time selection or a razor area (or switch Scope to Selected points).", 1, true), "Reduce track envelope: " .. txt)
  det = detCC(); det.hasTimeSel = false
  txt = redHints(det)
  h.truthy(txt:find("Make a time selection (or switch Scope to Entire item).", 1, true), "Reduce CC: " .. txt)
  det = detAI(); det.hasTimeSel = false
  h.truthy(redHints(det):find(HINT_RANGE, 1, true), "Reduce automation item: the full range hint")
  -- Reduce status: a missing range names the range, a missing target keeps the general text
  local rg = { amount = 50, scope = common.SCOPE_TIMESEL, curveFit = false }
  det = detCC(); det.hasTimeSel = false
  reduce.run(rst, det, rg)
  h.eq(rg.status, "Make a time selection")
  det = detEnv(); det.hasTimeSel = false
  reduce.run(rst, det, rg)
  h.eq(rg.status, "Make a time selection or a razor area")
  reduce.run(rst, detNone(), rg)
  h.eq(rg.status, "Select a CC lane / envelope / automation item (and a time selection or a razor area)")
  -- Transform: a MIDI CC lane with no selected events and no time selection
  stub.reset(); trParams()
  for _, e in ipairs(stub.ccList) do e.sel = false end
  det = detCC(); det.hasTimeSel = false
  local started, msg = overlay.start(CTX, det)
  h.eq(started, false)
  h.eq(msg, "Select some points, or make a time selection, then launch Transform")
end)

h.run()
