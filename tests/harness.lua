-- tests/harness.lua — minimal dependency-free test runner
local M = { tests = {} }

function M.test(name, fn) M.tests[#M.tests + 1] = { name = name, fn = fn } end

local function fmt(x) return tostring(x) end

function M.eq(a, b, msg)
  if a ~= b then error((msg or "") .. " expected " .. fmt(b) .. " got " .. fmt(a), 2) end
end

function M.almost(a, b, tol, msg)
  tol = tol or 1e-9
  if type(a) ~= "number" then error((msg or "") .. " expected number got " .. fmt(a), 2) end
  if math.abs(a - b) > tol then
    error((msg or "") .. " expected ~" .. fmt(b) .. " got " .. fmt(a), 2)
  end
end

function M.truthy(v, msg)
  if not v then error((msg or "") .. " expected truthy value", 2) end
end

function M.run()
  local pass, fail = 0, 0
  for _, t in ipairs(M.tests) do
    local ok, err = pcall(t.fn)
    if ok then
      pass = pass + 1
      print("PASS " .. t.name)
    else
      fail = fail + 1
      print("FAIL " .. t.name .. "\n   " .. tostring(err))
    end
  end
  print(string.format("\n%d passed, %d failed", pass, fail))
  os.exit(fail == 0 and 0 or 1)
end

return M
