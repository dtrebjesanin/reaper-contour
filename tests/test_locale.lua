-- tests/test_locale.lua — preset serialization must survive a flipped C numeric locale (the classic
-- REAPER bug where a plugin calls setlocale and every script in the process starts formatting 0.5 as
-- "0,5"). The stores are comma-DELIMITED, so a comma decimal separator corrupts them on the next
-- save; and tonumber("0.5") returns nil under a comma locale, so even dot-decimal data stops parsing.
-- Encoders must emit dot-decimal regardless of locale; decoders must parse regardless of locale.
package.path = package.path .. ";./Contour/?.lua;./?.lua;./tests/?.lua"

local h = require("harness")
local cs = require("core.customshape")
local gp = require("core.genpreset")

local LOCALES = { "de_DE.UTF-8", "de_DE", "German_Germany.1252", "de-DE", "fr_FR" }
local function commaLocale()
  for _, l in ipairs(LOCALES) do
    if os.setlocale(l, "numeric") and string.format("%.1f", 0.5):find(",") then return true end
  end
  os.setlocale("C", "numeric")
  return false
end

local STORE = { { name = "T", points = {
  { x = 0,    y = -0.5,  shape = 5, tension = -0.3 },
  { x = 0.25, y =  0.75, shape = 1, tension = 0 },
  { x = 1,    y = -1,    shape = 1, tension = 0 },
} } }

h.test("custom shapes encode+decode under a comma-decimal locale", function()
  os.setlocale("C", "numeric")
  if not commaLocale() then h.truthy(true); return end   -- no comma locale on this machine
  local dec = cs.decode(cs.encode(STORE))
  os.setlocale("C", "numeric")
  h.eq(#dec, 1, "one preset survives")
  h.eq(#dec[1].points, 3, "all three points survive")
  h.almost(dec[1].points[1].y, -0.5)
  h.almost(dec[1].points[1].tension, -0.3)
  h.almost(dec[1].points[2].x, 0.25)
end)

h.test("data SAVED under the C locale still decodes under a comma locale", function()
  os.setlocale("C", "numeric")
  local enc = cs.encode(STORE)                            -- dot-decimal on disk (the normal case)
  if not commaLocale() then h.truthy(true); return end
  local dec = cs.decode(enc)
  os.setlocale("C", "numeric")
  h.eq(#dec[1].points, 3)
  h.almost(dec[1].points[2].x, 0.25, 1e-9, "dot-decimal field parses under the comma locale")
end)

h.test("generate presets round-trip under a comma-decimal locale", function()
  os.setlocale("C", "numeric")
  local store = { { name = "P", params = { hz = 2.5, swing = -0.6, amplitude = 50 } } }
  if not commaLocale() then h.truthy(true); return end
  local dec = gp.decode(gp.encode(store))
  os.setlocale("C", "numeric")
  h.eq(#dec, 1)
  h.almost(dec[1].params.hz, 2.5)
  h.almost(dec[1].params.swing, -0.6)
end)

h.run()
