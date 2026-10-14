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

T.case('mouse and scroll wheel events are not keystrokes', function()
  local old = vim.o.mouse
  vim.o.mouse = 'nvi'
  local buf = buffer()
  local t = K.start(buf)
  keys('<ScrollWheelDown><ScrollWheelDown><ScrollWheelUp><LeftMouse><LeftRelease>')
  T.eq(t.keys(), 0)
  keys('x')
  T.eq(t.keys(), 1)
  t.stop()
  vim.o.mouse = old
end)

T.case('unloading the buffer (:bdelete) stops the tracker', function()
  local buf = buffer()
  vim.bo[buf].bufhidden = 'hide'
  local t = K.start(buf)
  keys('x')
  vim.cmd('enew')
  vim.cmd('bdelete! ' .. buf)
  vim.api.nvim_set_current_buf(buf)
  keys('ix<Esc>')
  T.eq(t.keys(), 1)
end)

-- Terminals send a paste as one bracketed paste, which the TUI hands to nvim_paste (Neovim >= 0.10):
-- no on_key event at all, so a paste costs 0 keys, never its length (measured 2026-10-09).
T.case('a terminal paste (nvim_paste) is not a keystroke, however long', function()
  local buf = buffer({ '' })
  local t = K.start(buf)
  vim.api.nvim_paste('a long pasted text\nwith a second line', false, -1)
  T.eq(t.keys(), 0)
  T.eq(vim.api.nvim_buf_get_lines(buf, 0, -1, false)[2], 'with a second line')
  t.stop()
end)

-- 0.7.0: counting rules for neurovim.nvim (agent play test 2026-10-14, rules F1–F3 decided by
-- Johannes). Every case below is red with the 0.6.0 tracker.

-- Through mappings: without the n flag of keys(), so a mapping fires (with n it is bypassed and a
-- mapping test would pass for nothing).
local function mapped(k)
  vim.api.nvim_feedkeys(vim.api.nvim_replace_termcodes(k, true, false, true), 'tx', false)
end

vim.api.nvim_create_user_command('KitProbeLong', function() end, {})
local function parsed_as(name)
  return function(line)
    local ok, r = pcall(vim.api.nvim_parse_cmd, line, {})
    return ok and r.cmd == name
  end
end

T.case('B1: a mapping counts the keys of its lhs, not one', function()
  local buf = buffer({ 'old mid end' })
  vim.keymap.set('o', 'iw', 'iw', { buffer = buf })
  vim.keymap.set('n', '<Space>p', 'x', { buffer = buf })
  local t = K.start(buf)
  mapped('wciwN<Esc>')
  T.eq(t.keys(), 6)
  T.eq(vim.api.nvim_buf_get_lines(buf, 0, -1, false), { 'old N end' })
  mapped('<Space>p')
  T.eq(t.keys(), 8)
  T.eq(vim.api.nvim_buf_get_lines(buf, 0, -1, false), { 'old  end' }, 'the mapping ran')
  t.stop()
end)

T.case('F1a: a mapping that opens an excluded command keeps its keys; a typed : is free', function()
  local buf = buffer()
  vim.keymap.set('n', '<F5>', ':KitProbe<CR>', { buffer = buf })
  vim.keymap.set('n', '<Space>c', ':KitProbe<CR>', { buffer = buf })
  local t = K.start(buf, { exclude_cmdline = '^%s*KitProbe' })
  mapped('<F5>')
  T.eq(t.keys(), 1)
  mapped('<Space>c')
  T.eq(t.keys(), 3)
  mapped(':KitProbe<CR>')
  T.eq(t.keys(), 3)
  T.eq(vim.fn.histget(':', -1), 'KitProbe', 'the mappings ran the command')
  t.stop()
end)

T.case('B3: keys in a command-line window opened from the buffer count', function()
  local buf = buffer({ 'x x', 'x' })
  local t = K.start(buf)
  keys('q:i%s/x//g<CR>')
  T.eq(t.keys(), 11)
  T.eq(vim.api.nvim_buf_get_lines(buf, 0, -1, false), { ' ', '' })
  keys('q/i <CR>')
  T.eq(t.keys(), 16)
  t.stop()
end)

T.case('B3: an excluded command run from the command-line window is free like on the command line', function()
  local buf = buffer()
  local t = K.start(buf, { exclude_cmdline = '^%s*KitProbe' })
  keys('q:iKitProbe<CR>')
  T.eq(t.keys(), 1, 'q counts like a mapping key, the : and the line are free')
  t.stop()
end)

T.case('B3: a command-line window opened from another buffer does not count', function()
  local buf = buffer()
  local t = K.start(buf)
  keys('x')
  vim.cmd('enew')
  keys('q:iecho<CR>')
  T.eq(t.keys(), 1)
  t.stop()
end)

T.case('B4: exclude_cmdline as a function recognises an abbreviated command', function()
  local buf = buffer()
  local t = K.start(buf, { exclude_cmdline = parsed_as('KitProbeLong') })
  keys('x:KitProbeL<CR>')
  T.eq(t.keys(), 1)
  keys(':silent KitProbeLong<CR>')
  T.eq(t.keys(), 1)
  t.stop()
  -- counter-check: the pattern sees only the text
  local p = K.start(buffer(), { exclude_cmdline = '^%s*KitProbeLong' })
  keys('x:KitProbeL<CR>')
  T.eq(p.keys(), 1 + #':KitProbeL' + 1)
  p.stop()
end)

T.case('B5: an excluded command is free also when abandoned; another abandoned line counts', function()
  local buf = buffer()
  local t = K.start(buf, { exclude_cmdline = '^%s*KitProbe' })
  keys(':KitProbe ch<Esc>')
  T.eq(t.keys(), 0)
  keys(':s/x<Esc>')
  T.eq(t.keys(), 5)
  t.stop()
end)

T.case('a nested command line (:q in a command-line window) does not end the open command', function()
  local buf = buffer()
  local t = K.start(buf, { exclude_cmdline = '^%s*KitProbe' })
  keys('q:iKitProbe<Esc>:echo<CR><CR>')
  T.eq(t.keys(), 1)
  t.stop()
end)

-- With the x flag Neovim runs the keys before feedkeys returns; vim.schedule callbacks (free_if_left)
-- run on the next loop turn.
local function settle()
  vim.wait(0)
end

T.case('B6: free_if_left — a command that leaves the buffer unchanged and not current is free', function()
  local buf = buffer({ 'x x' })
  local t = K.start(buf, { free_if_left = true })
  keys(':enew<CR>')
  settle()
  T.eq(t.keys(), 0)
  vim.api.nvim_set_current_buf(buf)
  keys(':%s/x/y/g|enew<CR>')
  settle()
  T.eq(t.keys(), #':%s/x/y/g|enew' + 1, 'the buffer changed: every key counts')
  vim.api.nvim_set_current_buf(buf)
  keys(':help<CR>')
  settle()
  T.eq(t.keys(), 15, ':help is free')
  vim.cmd('helpclose')
  vim.api.nvim_set_current_buf(buf)
  keys(':s/y/z/<CR>')
  settle()
  T.eq(t.keys(), 15 + 8, 'a command that stays in the buffer counts')
  t.stop()
end)

T.case('counter-check B6: without free_if_left :enew counts', function()
  local buf = buffer()
  local t = K.start(buf)
  keys(':enew<CR>')
  settle()
  T.eq(t.keys(), 6)
  t.stop()
end)

T.case('B7: pause_outside — time stops while the buffer is not current', function()
  local clock = 0
  local buf = buffer()
  local opts = {
    pause_outside = true,
    now = function()
      return clock
    end,
  }
  local t = K.start(buf, opts)
  keys('x')
  clock = 1000
  vim.cmd('enew')
  clock = 5000
  vim.api.nvim_set_current_buf(buf)
  clock = 6000
  T.eq(t.elapsed_ms(), 2000)
  clock = 7000
  vim.cmd('enew')
  clock = 9000
  t.stop()
  T.eq(t.elapsed_ms(), 3000, 'stopped while away: the time away does not count')
end)

T.case('counter-check B7: without pause_outside the time away counts', function()
  local clock = 0
  local buf = buffer()
  local t = K.start(buf, {
    now = function()
      return clock
    end,
  })
  keys('x')
  clock = 1000
  vim.cmd('enew')
  clock = 5000
  vim.api.nvim_set_current_buf(buf)
  clock = 6000
  T.eq(t.elapsed_ms(), 6000)
  t.stop()
end)

T.case('B7: leaving and coming back before the first key changes nothing', function()
  local clock = 0
  local buf = buffer()
  local t = K.start(buf, {
    pause_outside = true,
    now = function()
      return clock
    end,
  })
  clock = 1000
  vim.cmd('enew')
  clock = 5000
  vim.api.nvim_set_current_buf(buf)
  clock = 6000
  keys('x')
  clock = 7000
  T.eq(t.elapsed_ms(), 1000)
  t.stop()
end)

T.case('B7: a command-line window opened from the buffer is not time away', function()
  local clock = 0
  local buf = buffer()
  local t = K.start(buf, {
    pause_outside = true,
    now = function()
      return clock
    end,
  })
  keys('x')
  clock = 1000
  -- after keytrack's own CmdwinEnter: five seconds pass in the window
  vim.api.nvim_create_autocmd('CmdwinEnter', {
    once = true,
    callback = function()
      clock = clock + 5000
    end,
  })
  keys('q:iecho<CR>')
  T.eq(t.elapsed_ms(), 6000)
  t.stop()
end)

T.case('B7: on_tick rests while the buffer is not current', function()
  local ticks = 0
  local buf = buffer()
  local t = K.start(buf, {
    pause_outside = true,
    on_tick = function()
      ticks = ticks + 1
    end,
  })
  keys('x')
  vim.cmd('enew')
  vim.wait(1300)
  T.eq(ticks, 0)
  vim.api.nvim_set_current_buf(buf)
  vim.wait(1500, function()
    return ticks >= 1
  end)
  T.ok(ticks >= 1, 'ticks again after coming back')
  t.stop()
end)
