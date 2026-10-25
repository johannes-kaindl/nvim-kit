local T = require('nvim_kit.test')
local root = vim.fn.fnamemodify(debug.getinfo(1, 'S').source:sub(2), ':p:h:h')

-- Runs a throwaway spec dir through a fresh headless Neovim and returns its exit code.
local function run_specs(files)
  local dir = vim.fn.tempname()
  vim.fn.mkdir(dir, 'p')
  for name, body in pairs(files) do
    local path = dir .. '/' .. name
    vim.fn.mkdir(vim.fn.fnamemodify(path, ':h'), 'p')
    vim.fn.writefile(vim.split(body, '\n'), path)
  end
  local runner = dir .. '/run.lua'
  vim.fn.writefile({
    ('vim.opt.rtp:prepend(%q)'):format(root),
    ('require("nvim_kit.test").main(%q)'):format(dir),
  }, runner)
  return vim.system({ vim.v.progpath, '--headless', '-u', 'NONE', '-l', runner }):wait().code
end

T.case('deep_equal treats vim.NIL as nil and ignores metatables', function()
  T.ok(T.deep_equal({ a = vim.NIL }, {}))
  T.ok(T.deep_equal(setmetatable({}, { __index = {} }), {}))
  T.ok(not T.deep_equal({ 1, 2 }, { 1, 3 }))
  T.ok(not T.deep_equal({ a = 1 }, { a = 1, b = 2 }))
  T.ok(T.deep_equal({ x = { 1, { y = 'z' } } }, { x = { 1, { y = 'z' } } }))
end)

T.case('eq reports expected and actual', function()
  local ok, err = pcall(T.eq, 1, 2, 'sum')
  T.ok(not ok)
  T.ok(tostring(err):find('sum: expected 2, got 1', 1, true), tostring(err))
end)

T.case('deep_equal tells an empty object from an empty list, like JSON (review M1)', function()
  local obj, arr = vim.json.decode('{}'), vim.json.decode('[]')
  T.ok(not T.deep_equal(obj, arr))
  T.ok(not T.deep_equal(arr, obj))
  T.ok(not T.deep_equal({ s = {} }, vim.json.decode('{"s": {}}')))
  T.ok(T.deep_equal(obj, vim.empty_dict()))
  T.ok(T.deep_equal(vim.json.decode('{"s": {}, "l": []}'), { s = vim.empty_dict(), l = {} }))
  T.ok(not pcall(T.eq, obj, {}))
end)

T.case('ok treats vim.NIL as false, like nil (review M8)', function()
  T.ok(not pcall(T.ok, vim.NIL))
  T.ok(not pcall(T.ok, nil))
  T.ok(not pcall(T.ok, false))
  T.ok(pcall(T.ok, 0))
  T.ok(pcall(T.ok, ''))
  T.ok(pcall(T.ok, {}))
end)

T.case('raises checks that an error happened and what it says', function()
  T.raises(function()
    error('boom here')
  end, 'boom')
  T.ok(not pcall(T.raises, function() end))
  T.ok(not pcall(T.raises, function()
    error('other')
  end, 'boom'))
end)

T.case('counter-check: a failing case makes the runner exit 1', function()
  T.eq(
    run_specs({
      ['a_spec.lua'] = "local T = require('nvim_kit.test')\nT.case('x', function() T.eq(1, 2) end)",
    }),
    1
  )
end)

T.case('counter-check: a spec that fails to load makes the runner exit 1', function()
  T.eq(run_specs({ ['a_spec.lua'] = 'this is not lua' }), 1)
end)

T.case('counter-check: no spec at all is not a pass', function()
  T.eq(run_specs({}), 1)
end)

T.case('a passing spec makes the runner exit 0', function()
  T.eq(
    run_specs({
      ['a_spec.lua'] = "local T = require('nvim_kit.test')\nT.case('x', function() T.eq(1, 1) end)",
    }),
    0
  )
end)

T.case('counter-check: a failing spec in a subdirectory is found (review I5)', function()
  T.eq(
    run_specs({
      ['a_spec.lua'] = "local T = require('nvim_kit.test')\nT.case('x', function() T.eq(1, 1) end)",
      ['sub/b_spec.lua'] = "local T = require('nvim_kit.test')\nT.case('y', function() T.eq(1, 2) end)",
    }),
    1
  )
end)

T.case('json_eq tells [] from {} and null from absent', function()
  T.json_eq(vim.json.decode('{"a": null, "o": {}}'), '{"o": {}, "a": null}')
  T.raises(function()
    T.json_eq({}, '{}')
  end, 'expected')
  T.raises(function()
    T.json_eq({}, '{"a": null}')
  end, 'expected')
  T.raises(function()
    T.json_eq({ a = 1 }, '{"a": 2}')
  end, 'expected')
end)

T.case('deep_equal compares numbers exactly unless a tolerance is given', function()
  T.eq(T.deep_equal(0.1 + 0.2, 0.3), false)
  T.eq(T.deep_equal(0.1 + 0.2, 0.3, 1e-9), true)
  T.eq(T.deep_equal(1.00001, 1, 1e-6), false)
  T.eq(T.deep_equal('a', 'a', 1e-6), true)
  T.eq(T.deep_equal(math.huge, math.huge, 1e-6), true)
end)

T.case('deep_equal passes the tolerance down into nested tables', function()
  T.eq(T.deep_equal({ x = { 1.0000001 } }, { x = { 1 } }, 1e-6), true)
  T.eq(T.deep_equal({ x = { 1.0000001 } }, { x = { 1 } }), false)
  T.eq(T.deep_equal({ x = { 1.001 } }, { x = { 1 } }, 1e-6), false)
end)

T.case('deep_equal with a tolerance keeps {} apart from vim.empty_dict() and vim.NIL as nil', function()
  T.eq(T.deep_equal({}, vim.empty_dict(), 1e-6), false)
  T.eq(T.deep_equal({ a = vim.NIL }, {}, 1e-6), true)
  T.eq(T.deep_equal('a', 'b', 1e-6), false)
end)
