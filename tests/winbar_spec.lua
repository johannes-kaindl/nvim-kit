local T = require('nvim_kit.test')
local W = require('nvim_kit.winbar')

local function shown(win)
  return vim.api.nvim_eval_statusline(vim.wo[win].winbar, { winid = win, use_winbar = true }).str
end

-- Named and not empty: :enew reuses an unnamed empty buffer instead of switching (measured), which
-- would make every "another buffer in this window" check meaningless.
local count = 0
local function buffer()
  count = count + 1
  local buf = vim.api.nvim_create_buf(true, true)
  vim.bo[buf].bufhidden = 'hide'
  vim.api.nvim_buf_set_name(buf, 'kitprobe://winbar-' .. count)
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, { 'text' })
  vim.api.nvim_set_current_buf(buf)
  return buf
end

T.case('the winbar shows the provider text literally, only while the buffer is in the window', function()
  vim.cmd('silent! only')
  local buf = buffer()
  local n = 0
  W.attach(buf, function()
    n = n + 1
    return ('M-01 · %d keys · 50%%'):format(n)
  end)
  local win = vim.api.nvim_get_current_win()
  T.ok(shown(win):find('keys · 50%', 1, true), shown(win))
  vim.cmd('enew')
  T.eq(vim.wo[win].winbar, '')
  vim.api.nvim_set_current_buf(buf)
  T.ok(shown(win):find('M-01', 1, true), shown(win))
end)

T.case('another window that later shows the buffer gets the winbar too', function()
  vim.cmd('silent! only')
  local buf = buffer()
  W.attach(buf, function()
    return 'probe'
  end)
  vim.cmd('vsplit')
  vim.cmd('enew')
  local other = vim.api.nvim_get_current_win()
  T.eq(vim.wo[other].winbar, '')
  vim.api.nvim_win_set_buf(other, buf)
  T.eq(shown(other), 'probe')
  vim.cmd('silent! only')
end)

T.case('unloading the buffer ends the provider', function()
  local buf = buffer()
  W.attach(buf, function()
    return 'gone soon'
  end)
  vim.cmd('enew')
  vim.cmd('bdelete! ' .. buf)
  T.eq(W.render(buf), '')
end)

T.case('attached while hidden, the buffer brings its winbar when it is shown', function()
  vim.cmd('silent! only')
  local buf = buffer()
  vim.cmd('enew')
  W.attach(buf, function()
    return 'later'
  end)
  vim.api.nvim_set_current_buf(buf)
  T.eq(shown(vim.api.nvim_get_current_win()), 'later')
end)
