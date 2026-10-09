local T = require('nvim_kit.test')
local K = require('nvim_kit.keytrack')

-- Keep mode messages and the search count out of the test report.
vim.o.showmode = false
vim.opt.shortmess:append('Sq')

local function keys(k)
  vim.api.nvim_feedkeys(vim.api.nvim_replace_termcodes(k, true, false, true), 'ntx', false)
end

local function buffer(lines)
  local buf = vim.api.nvim_create_buf(true, true)
  vim.api.nvim_set_current_buf(buf)
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines or { 'aaaa', 'bbbb', 'cccc', 'dddd' })
  return buf
end

T.case('counts typed keys in its buffer only', function()
  local buf = buffer()
  local t = K.start(buf)
  keys('xx')
  T.eq(t.keys(), 2)
  vim.cmd('enew')
  keys('ix<Esc>')
  T.eq(t.keys(), 2)
  vim.api.nvim_set_current_buf(buf)
  keys('j')
  T.eq(t.keys(), 3)
  t.stop()
end)

T.case('a macro replay counts the keys that started it, not the replayed ones', function()
  local buf = buffer()
  local t = K.start(buf)
  keys('qaxjq2@a')
  T.eq(t.keys(), 8)
  t.stop()
end)

T.case('time runs from the first key and freezes on stop', function()
  local clock = 1000
  local buf = buffer()
  local t = K.start(buf, {
    now = function()
      return clock
    end,
  })
  clock = 5000
  T.eq(t.started(), false)
  T.eq(t.elapsed_ms(), 0)
  keys('x')
  clock = 8500
  T.eq(t.elapsed_ms(), 3500)
  t.stop()
  clock = 20000
  T.eq(t.elapsed_ms(), 3500)
  keys('x')
  T.eq(t.keys(), 1)
end)

T.case('keys of an excluded command line do not count; other command lines do', function()
  vim.api.nvim_create_user_command('KitProbe', function() end, {})
  local buf = buffer()
  local t = K.start(buf, { exclude_cmdline = '^%s*KitProbe' })
  keys('x:KitProbe<CR>')
  T.eq(t.keys(), 1)
  keys(':s/a/b/<CR>')
  T.eq(t.keys(), 1 + #':s/a/b/' + 1)
  keys('/b<CR>')
  T.eq(t.keys(), 1 + 8 + 3)
  t.stop()
end)

T.case('on_tick fires every second after the first key until stop', function()
  local ticks = 0
  local buf = buffer()
  local t = K.start(buf, {
    on_tick = function()
      ticks = ticks + 1
    end,
  })
  vim.wait(1200)
  T.eq(ticks, 0)
  keys('x')
  vim.wait(1500, function()
    return ticks >= 1
  end)
  T.ok(ticks >= 1)
  t.stop()
  local seen = ticks
  vim.wait(1200)
  T.eq(ticks, seen)
end)

T.case('wiping the buffer stops the tracker', function()
  local buf = buffer()
  local t = K.start(buf)
  keys('x')
  vim.api.nvim_buf_delete(buf, { force = true })
  buffer()
  keys('xx')
  T.eq(t.keys(), 1)
end)

T.case('format_clock', function()
  T.eq(K.format_clock(0), '00:00')
  T.eq(K.format_clock(61999), '01:01')
  T.eq(K.format_clock(3600000), '60:00')
end)
