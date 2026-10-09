local T = require('nvim_kit.test')
local C = require('nvim_kit.conformance')
local here = vim.fn.fnamemodify(debug.getinfo(1, 'S').source:sub(2), ':p:h')
local DIR = here .. '/fixtures/vectors'

local impls = {
  add = function(a, b)
    return a + b
  end,
  pick = function(a, b, c)
    return { first = a, second = b, third = c }
  end,
}

T.case('loads vectors keyed by function', function()
  local v = C.load_dir(DIR)
  T.eq(#v.add.cases, 3)
  T.eq(#v.pick.cases, 4)
end)

T.case('a correct port passes every vector', function()
  local r = C.run_dir(DIR, impls)
  T.eq(r.cases, 7)
  T.eq(r.failures, {})
end)

T.case('arguments keep their position; false stays false; null arrives as nil', function()
  local seen
  C.run(C.load_dir(DIR).pick, function(a, b, c)
    seen = seen or { a = a, b = b, c = c }
    return { first = a, second = b, third = c }
  end)
  T.eq(seen.a, 'a')
  T.eq(seen.b, nil)
  T.eq(seen.c, 'c')
  local f = C.run(C.load_dir(DIR).pick, impls.pick)
  T.eq(f, {})
end)

T.case('counter-check: a wrong port fails', function()
  local r = C.run_dir(DIR, {
    add = function(a, b)
      return a - b
    end,
    pick = impls.pick,
  })
  T.ok(#r.failures > 0)
  T.eq(r.failures[1]['function'], 'add')
end)

T.case('counter-check: a port that treats false like nil fails', function()
  local f = C.run(C.load_dir(DIR).pick, function(a, b, c)
    return { first = a or nil, second = b, third = c }
  end)
  T.ok(#f > 0)
end)

T.case('a missing implementation is a failure, not a skip', function()
  local r = C.run_dir(DIR, { add = impls.add })
  T.eq(r.failures[#r.failures].name, '(no implementation)')
end)

T.case('an impl that raises is reported with its error', function()
  local f = C.run(C.load_dir(DIR).add, function()
    error('nope')
  end)
  T.eq(#f, 3)
  T.ok(tostring(f[1].error):find('nope', 1, true))
end)

T.case('an empty vector dir is an error', function()
  local d = vim.fn.tempname()
  vim.fn.mkdir(d, 'p')
  T.raises(function()
    C.load_dir(d)
  end, 'no vector files')
end)
