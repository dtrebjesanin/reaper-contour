-- tests/test_fader_reset.lua — double-click ON THE FADER resets to default. The trap: an ImGui slider
-- grabs on click and rewrites its value from the mouse EVERY frame while held, so a naive one-frame
-- reset is overwritten on the next frame (why only the label used to work). tickReset must LATCH the
-- reset and re-pin the value until the mouse is released. Frames are simulated by overriding the
-- stub's item/mouse state between calls.
package.path = package.path .. ";./Contour/?.lua;./?.lua;./tests/?.lua"

local stub = require("reaper_stub")
stub.install()

local h = require("harness")
local common = require("ui.common")

local CTX = "CTX"

-- per-frame ImGui state the test scripts explicitly
local S = { hovered = false, dblclick = false, mousedown = false }
reaper.ImGui_IsItemHovered        = function() return S.hovered end
reaper.ImGui_IsMouseDoubleClicked = function() return S.dblclick end
reaper.ImGui_IsMouseDown          = function() return S.mousedown end

h.test("double-click on the fader frame resets AND SURVIVES the held slider re-writing the value", function()
  local g = { x = 77 }
  -- frame A: second click of the double-click lands on the frame (slider active, mouse held)
  S.hovered, S.dblclick, S.mousedown = true, true, true
  h.eq(common.tickReset(CTX, g, "x", 0, 100, 50), true, "reset fires on the double-click frame")
  h.eq(g.x, 50, "value reset to default")
  -- frame B: mouse STILL HELD; the active slider has re-written the value from the mouse position
  -- (this is the frame that defeated the naive implementation)
  S.hovered, S.dblclick, S.mousedown = false, false, true
  g.x = 77                                     -- the slider's per-frame mouse-position write
  h.eq(common.tickReset(CTX, g, "x", 0, 100, 50), true, "latch keeps pinning while held")
  h.eq(g.x, 50, "value stays at the default, not the click position")
  -- frame C: mouse released; slider writes once more, latch pins one final time and clears
  S.mousedown = false
  g.x = 77
  h.eq(common.tickReset(CTX, g, "x", 0, 100, 50), true, "final pin on the release frame")
  h.eq(g.x, 50)
  -- frame D: latch cleared — normal slider use works again untouched
  g.x = 55
  h.eq(common.tickReset(CTX, g, "x", 0, 100, 50), false, "no reset without a double-click")
  h.eq(g.x, 55, "user's value untouched after the latch cleared")
end)

h.test("label double-click (item not active / mouse not held) still resets immediately", function()
  local g = { y = 80 }
  S.hovered, S.dblclick, S.mousedown = true, true, false   -- label: no grab, button already up
  h.eq(common.tickReset(CTX, g, "y", 0, 100, 0), true)
  h.eq(g.y, 0)
  S.hovered, S.dblclick = false, false
  g.y = 42
  h.eq(common.tickReset(CTX, g, "y", 0, 100, 0), false, "no lingering latch from a label reset")
  h.eq(g.y, 42)
end)

h.test("independent keys latch independently", function()
  local g = { a = 10, b = 20 }
  S.hovered, S.dblclick, S.mousedown = true, true, true
  common.tickReset(CTX, g, "a", 0, 100, 0)
  S.hovered, S.dblclick = false, false
  g.a, g.b = 99, 99
  common.tickReset(CTX, g, "a", 0, 100, 0)
  h.eq(g.a, 0, "latched key pinned")
  h.eq(common.tickReset(CTX, g, "b", 0, 100, 0), false, "other key unaffected")
  h.eq(g.b, 99)
  S.mousedown = false
  common.tickReset(CTX, g, "a", 0, 100, 0)   -- clears on release
end)

h.run()
