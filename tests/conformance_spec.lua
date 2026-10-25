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

-- Review findings 2026-10-09 (C2, I4, M2).
local function tmpdir()
  local d = vim.fn.tempname()
  vim.fn.mkdir(d, 'p')
  return d
end

local function write_json(dir, name, text)
  vim.fn.writefile(vim.split(text, '\n'), dir .. '/' .. name)
end

T.case('works when vendored under another namespace, without nvim_kit on the runtimepath', function()
  local root = vim.fn.fnamemodify(debug.getinfo(1, 'S').source:sub(2), ':p:h:h')
  local plug = tmpdir()
  vim.fn.mkdir(plug .. '/lua/plug/kit', 'p')
  for _, m in ipairs({ 'test', 'conformance', 'data' }) do
    vim.fn.writefile(
      vim.fn.readfile(root .. '/lua/nvim_kit/' .. m .. '.lua'),
      plug .. '/lua/plug/kit/' .. m .. '.lua'
    )
  end
  local script = plug .. '/probe.lua'
  vim.fn.writefile({
    ('vim.opt.rtp = { %q, vim.env.VIMRUNTIME }'):format(plug),
    "local ok = pcall(require, 'nvim_kit.test')",
    'if ok then os.exit(3) end',
    "local C = require('plug.kit.conformance')",
    ('local r = C.run_dir(%q, { add = function(a, b) return a + b end, pick = function(a, b, c) return { first = a, second = b, third = c } end })'):format(
      DIR
    ),
    'os.exit(#r.failures == 0 and 0 or 2)',
  }, script)
  T.eq(vim.system({ vim.v.progpath, '--headless', '-u', 'NONE', '-l', script }):wait().code, 0)
end)

T.case('a vector file with no cases is an error, not a pass', function()
  local d = tmpdir()
  write_json(d, 'x.json', '{ "schema": 1, "function": "x", "cases": [] }')
  T.raises(function()
    C.load_dir(d)
  end, 'has no cases')
end)

T.case('two vector files for one function are an error', function()
  local d = tmpdir()
  write_json(
    d,
    'a.json',
    '{ "schema": 1, "function": "x", "cases": [ { "name": "a", "args": [], "expected": 1 } ] }'
  )
  write_json(
    d,
    'b.json',
    '{ "schema": 1, "function": "x", "cases": [ { "name": "b", "args": [], "expected": 2 } ] }'
  )
  T.raises(function()
    C.load_dir(d)
  end, 'twice')
end)

T.case('a case without an expected key is an error (a nil-returning stub must not pass)', function()
  local d = tmpdir()
  write_json(
    d,
    'x.json',
    '{ "schema": 1, "function": "x", "cases": [ { "name": "no expected", "args": [1] } ] }'
  )
  T.raises(function()
    C.load_dir(d)
  end, 'no expected')
end)

T.case('a case whose args are not a list is an error', function()
  local d = tmpdir()
  write_json(
    d,
    'x.json',
    '{ "schema": 1, "function": "x", "cases": [ { "name": "obj", "args": { "a": 1 }, "expected": 1 } ] }'
  )
  T.raises(function()
    C.load_dir(d)
  end, 'args')
end)

T.case('expected null stays a real expectation', function()
  local d = tmpdir()
  write_json(
    d,
    'x.json',
    '{ "schema": 1, "function": "x", "cases": [ { "name": "null", "args": [], "expected": null } ] }'
  )
  T.eq(
    C.run(C.load_dir(d).x, function()
      return nil
    end),
    {}
  )
  T.ok(#C.run(C.load_dir(d).x, function()
    return 1
  end) > 0)
end)

-- Review finding M2b (neurovim.nvim phase 2): a null inside an array argument can only arrive as
-- vim.NIL, which is truthy; nil would leave a hole. Such a vector is refused when it is loaded.
T.case('a null inside an array argument is an error, naming file, case and position', function()
  local d = tmpdir()
  write_json(
    d,
    'x.json',
    '{ "schema": 1, "function": "x", "cases": [ { "name": "holey", "args": [0, { "l": [1, null] }], "expected": 1 } ] }'
  )
  T.raises(function()
    C.load_dir(d)
  end, 'x.json case 1 (holey): null inside an array at args[2].l[2]')
  write_json(
    d,
    'x.json',
    '{ "schema": 1, "function": "x", "cases": [ { "name": "flat", "args": [[null]], "expected": 1 } ] }'
  )
  T.raises(function()
    C.load_dir(d)
  end, 'args[1][1]')
end)

T.case('nulls the runner can pass stay allowed: top-level, inside objects, in expected', function()
  local d = tmpdir()
  write_json(
    d,
    'x.json',
    '{ "schema": 1, "function": "x", "cases": [ { "name": "ok", "args": [null, [{ "k": null }]], "expected": [null, 1] } ] }'
  )
  local seen
  T.eq(
    C.run(C.load_dir(d).x, function(a, b)
      seen = { a = a, b = b }
      return { nil, 1 }
    end),
    {}
  )
  T.ok(seen.a == nil)
  T.eq(seen.b, { {} })
end)

T.case('a tolerance lets a float result pass; without one it fails', function()
  local vector = { cases = { { name = 'sum', args = {}, expected = 0.3 } } }
  local impl = function()
    return 0.1 + 0.2
  end
  T.eq(#C.run(vector, impl), 1)
  T.eq(C.run(vector, impl, { tolerance = 1e-9 }), {})
  T.eq(#C.run(vector, function()
    return 0.31
  end, { tolerance = 1e-9 }), 1)
end)

T.case('run_dir hands the tolerance to every vector', function()
  local r = C.run_dir(DIR, {
    add = function(a, b)
      return a + b + 1e-12
    end,
    pick = impls.pick,
  }, { tolerance = 1e-9 })
  T.eq(r.failures, {})
  T.ok(#C.run_dir(DIR, {
    add = function(a, b)
      return a + b + 1e-12
    end,
    pick = impls.pick,
  }).failures > 0)
end)
