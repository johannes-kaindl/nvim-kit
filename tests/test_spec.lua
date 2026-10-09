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
  return vim.system({ 'nvim', '--headless', '-u', 'NONE', '-l', runner }):wait().code
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
