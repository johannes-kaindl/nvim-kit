local T = require('nvim_kit.test')
local R = require('nvim_kit.rg')

-- Runs a search and waits for its single answer; counts how often the callback fired.
local function search(text, opts)
  local result, calls = nil, 0
  R.search(text, opts, function(v)
    calls = calls + 1
    result = v
  end)
  vim.wait(5000, function()
    return result ~= nil
  end, 5)
  vim.wait(50) -- a second answer would arrive here
  return result, calls
end

-- An executable script standing in for rg; the version line comes from `--version`.
local function fake_rg(version_line, body)
  local path = vim.fn.tempname()
  local f = assert(io.open(path, 'w'))
  f:write(('#!/bin/sh\nif [ "$1" = --version ]; then echo "%s"; exit 0; fi\n%s\n'):format(version_line, body))
  f:close()
  vim.fn.setfperm(path, 'rwx------')
  return path
end

T.case('search: hits with byte offsets into the text, match and replaced text', function()
  local text = 'Deadline 13.10.2026\nÄrger 01.02.2003\nnone\n'
  local r = search(text, { pattern = [[(\d{2})\.(\d{2})\.(\d{4})]], replacement = '$3-$2-$1' })
  T.eq(r.ok, true)
  T.eq(r.truncated, false)
  T.eq(r.hits, {
    { start = 9, stop = 19, match = '13.10.2026', replacement = '2026-10-13', line = 1 },
    -- "Ä" is two bytes: offsets count bytes, as Neovim's columns do
    { start = 27, stop = 37, match = '01.02.2003', replacement = '2003-02-01', line = 2 },
  })
  T.eq(text:sub(28, 37), '01.02.2003')
end)

T.case('search: no match is ok with no hits; without a replacement none is reported', function()
  local r = search('abc\n', { pattern = 'zzz' })
  T.eq(r, { ok = true, hits = {}, truncated = false })
  r = search('abc\n', { pattern = 'b' })
  T.eq(r.hits, { { start = 1, stop = 2, match = 'b', line = 1 } })
end)

T.case('search: several hits on one line and lines of hits inside a multi-line block', function()
  local r = search('a1 a2\nb\na3\n', { pattern = [[a\d(\n\w)?]], multiline = true })
  T.eq(r.ok, true)
  local got = {}
  for _, h in ipairs(r.hits) do
    got[#got + 1] = { h.match, h.line }
  end
  T.eq(got, { { 'a1', 1 }, { 'a2\nb', 1 }, { 'a3', 3 } })
end)

T.case('search: a pattern with \\n needs multiline; rg says so as rg-error', function()
  local r = search('a\nb\n', { pattern = [[a\nb]] })
  T.eq(r.ok, false)
  T.eq(r.error, 'rg-error')
  T.ok(r.detail:find('\\n', 1, true), r.detail)
  r = search('a\nb\n', { pattern = [[a\nb]], multiline = true, replacement = 'X' })
  T.eq(r.hits, { { start = 0, stop = 3, match = 'a\nb', replacement = 'X', line = 1 } })
end)

T.case('search: a pattern rg refuses is rg-error with rg own message', function()
  local r = search('x\n', { pattern = '(?<=x)y' })
  T.eq({ r.ok, r.error }, { false, 'rg-error' })
  T.ok(r.detail:find('look-around', 1, true), r.detail)
end)

T.case('search: text that is not UTF-8 still gives hits (rg sends it as base64)', function()
  local r = search('a\255b x\n', { pattern = 'b.x', replacement = '[$0]' })
  T.eq(r.hits, { { start = 2, stop = 5, match = 'b x', replacement = '[b x]', line = 1 } })
  -- the hit itself is not UTF-8: match and replacement arrive as bytes
  r = search('a\255b\n', { pattern = [[(?-u:\xFF)]], replacement = '[$0]' })
  T.eq(r.hits, { { start = 1, stop = 2, match = '\255', replacement = '[\255]', line = 1 } })
end)

T.case('search: a NUL byte is text, not a line break (rg would convert it as binary)', function()
  local r = search('x\na\0b x\nx\n', { pattern = 'x' })
  local got = {}
  for _, h in ipairs(r.hits) do
    got[#got + 1] = { h.start, h.line }
  end
  T.eq(got, { { 0, 1 }, { 6, 2 }, { 8, 3 } })
end)

T.case('search: max_hits cuts the list and says so', function()
  local r = search('x x x\n', { pattern = 'x', max_hits = 2 })
  T.eq({ #r.hits, r.truncated }, { 2, true })
  r = search('x x\n', { pattern = 'x', max_hits = 2 })
  T.eq({ #r.hits, r.truncated }, { 2, false })
end)

T.case('search: a replacement that starts with - is a replacement, not an option', function()
  local r = search('ab\n', { pattern = 'a', replacement = '-x' })
  T.eq(r.hits[1].replacement, '-x')
end)

T.case('search: the user ripgrep config does not apply', function()
  local cfg = vim.fn.tempname()
  vim.fn.writefile({ '--max-count=1' }, cfg)
  local saved = vim.env.RIPGREP_CONFIG_PATH
  vim.env.RIPGREP_CONFIG_PATH = cfg
  local r = search('x\nx\n', { pattern = 'x' })
  vim.env.RIPGREP_CONFIG_PATH = saved
  T.eq(#r.hits, 2)
end)

T.case('search: rg missing or too old is rg-missing, without starting a search', function()
  R.reset()
  local r = search('x\n', { pattern = 'x', exe = vim.fn.tempname() })
  T.eq({ r.ok, r.error }, { false, 'rg-missing' })
  T.ok(r.detail:find('not found', 1, true), r.detail)
  local old = fake_rg('ripgrep 14.1.0', 'echo should-not-run >&2; exit 2')
  r = search('x\n', { pattern = 'x', exe = old })
  T.eq(r.error, 'rg-missing')
  T.ok(r.detail:find('14.1.0 is older than 15.0.0', 1, true), r.detail)
  T.eq(R.check(fake_rg('ripgrep 15.0.0 (rev x)', 'exit 1')), nil)
  R.reset()
end)

T.case('search: a search that runs too long is timeout', function()
  local slow = fake_rg('ripgrep 15.0.0', 'sleep 5')
  local r = search('x\n', { pattern = 'x', exe = slow, timeout_ms = 100 })
  T.eq({ r.ok, r.error }, { false, 'timeout' })
  R.reset()
end)

T.case('search: cancel answers cancelled once and stops rg', function()
  local slow = fake_rg('ripgrep 15.0.0', 'sleep 5')
  local result, calls = nil, 0
  local h = R.search('x\n', { pattern = 'x', exe = slow }, function(v)
    calls = calls + 1
    result = v
  end)
  h.cancel()
  vim.wait(300, function()
    return false
  end, 10)
  T.eq({ result and result.error, calls }, { 'cancelled', 1 })
  R.reset()
end)

T.case('search: the callback runs on the main loop, where buffers may change', function()
  local fast
  local r = search('x\n', { pattern = 'x' })
  R.search('x\n', { pattern = 'x' }, function()
    fast = vim.in_fast_event()
  end)
  vim.wait(2000, function()
    return fast ~= nil
  end, 5)
  T.eq({ r.ok, fast }, { true, false })
end)

T.case('search: invalid arguments raise', function()
  T.raises(function()
    R.search(nil, { pattern = 'x' }, function() end)
  end, 'needs text')
  T.raises(function()
    R.search('x', {}, function() end)
  end, 'opts.pattern')
  T.raises(function()
    R.search('x', { pattern = 'x', replacement = 1 }, function() end)
  end, 'replacement must be a string')
end)

T.case('version: reads the installed ripgrep', function()
  R.reset()
  local v = R.version()
  T.ok(v and v:match('^%d+%.%d+%.%d+$'), v)
end)
