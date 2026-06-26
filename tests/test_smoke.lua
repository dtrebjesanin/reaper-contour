package.path = package.path .. ";./Contour/?.lua;./?.lua;./tests/?.lua"
local h = require("harness")

h.test("harness eq works", function() h.eq(1 + 1, 2) end)
h.test("harness almost works", function() h.almost(0.1 + 0.2, 0.3, 1e-9) end)

h.run()
