local T = require('nvim_kit.test')
local H = require('nvim_kit.health')

-- Health helpers report into a :checkhealth run, so each case runs a probe plugin through the real
-- command and reads the report buffer.
local probe_root = vim.fn.tempname()
vim.fn.mkdir(probe_root .. '/lua/kitprobe', 'p')
-- The file only makes the check discoverable; its module is replaced before every run.
vim.fn.writefile({ 'return { check = function() end }' }, probe_root .. '/lua/kitprobe/health.lua')
vim.opt.rtp:append(probe_root)

local function report(fn)
  package.loaded['kitprobe.health'] = {
    check = function()
      vim.health.start('probe')
      fn()
    end,
  }
  vim.cmd('checkhealth kitprobe')
  local lines = vim.api.nvim_buf_get_lines(0, 0, -1, false)
  vim.cmd('bwipeout!')
  return table.concat(lines, '\n')
end

local function file(text)
  local p = vim.fn.tempname() .. '.json'
  vim.fn.writefile(vim.split(text, '\n'), p)
  return p
end

T.case('neovim: OK for a version we run, ERROR for one from the future', function()
  local out = report(function()
    H.neovim('0.10')
    H.neovim('99.0')
  end)
  T.ok(out:find('OK Neovim', 1, true), out)
  T.ok(out:find('ERROR', 1, true) and out:find('99.0', 1, true), out)
end)

T.case('json: OK with schema, ERROR on another schema, configurable missing and invalid', function()
  local good = file('{"schema": 1, "x": 1}')
  local out = report(function()
    T.eq(H.json(good, { label = 'data', schema = 1 }).x, 1)
    T.eq(H.json(good, { label = 'data2', schema = 2 }), nil)
    T.eq(H.json('/nonexistent/x.json', { label = 'save', missing = 'ok', missing_text = 'no save yet' }), nil)
    T.eq(H.json(file('{ broken'), { label = 'broken', invalid = 'warn' }), nil)
    T.eq(H.json(file('[1, 2]'), { label = 'list', expect = 'object' }), nil)
  end)
  T.ok(out:find('OK data:', 1, true), out)
  T.ok(out:find('ERROR data2', 1, true), out)
  T.ok(out:find('OK save: no save yet', 1, true), out)
  T.ok(out:find('WARNING broken', 1, true), out)
  T.ok(out:find('ERROR list', 1, true), out)
end)

T.case('json never moves or changes the file it checks', function()
  local p = file('{ broken')
  report(function()
    H.json(p, { label = 'broken', invalid = 'warn' })
  end)
  T.eq(vim.fn.readfile(p), { '{ broken' })
  T.eq(vim.fn.glob(p .. '.broken-*', false, true), {})
end)

T.case(
  'writable: OK for a writable dir and a missing one below it, ERROR when read-only; creates nothing',
  function()
    local dir = vim.fn.tempname()
    vim.fn.mkdir(dir, 'p')
    local ro = dir .. '/ro'
    vim.fn.mkdir(ro, 'p')
    vim.fn.setfperm(ro, 'r-xr-xr-x')
    local out = report(function()
      T.eq(H.writable(dir, 'here'), true)
      T.eq(H.writable(dir .. '/not/yet', 'later'), true)
      T.eq(H.writable(ro .. '/sub', 'locked'), false)
    end)
    vim.fn.setfperm(ro, 'rwxr-xr-x')
    T.ok(out:find('OK here', 1, true), out)
    T.ok(out:find('OK later', 1, true), out)
    T.ok(out:find('ERROR locked', 1, true), out)
    T.eq(vim.fn.isdirectory(dir .. '/not'), 0)
  end
)

T.case('vendored: names source, tag and short sha', function()
  local m = file('{"source": "nvim-kit", "tag": "0.5.0", "commit": "abcdef1234567"}')
  local out = report(function()
    H.vendored(m, 'kit')
    H.vendored('/nonexistent/VENDOR.json', 'gone')
  end)
  T.ok(out:find('kit: nvim-kit@0.5.0 (abcdef1)', 1, true), out)
  T.ok(out:find('ERROR gone', 1, true), out)
end)
