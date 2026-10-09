local T = require('nvim_kit.test')
local P = require('nvim_kit.panel')

local function long_buffer()
  local buf = vim.api.nvim_create_buf(true, true)
  vim.api.nvim_set_current_buf(buf)
  local lines = {}
  for i = 1, 200 do
    lines[i] = 'line ' .. i
  end
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
  return buf
end

local function keys(k)
  vim.api.nvim_feedkeys(vim.api.nvim_replace_termcodes(k, true, false, true), 'ntx', false)
end

-- Headless `nvim -l` never fires CursorMoved (Neovim fires it only while waiting for input;
-- measured 2026-10-09), so the tests raise the event the editor would raise.
local function moved(buf)
  vim.api.nvim_exec_autocmds('CursorMoved', { buffer = buf })
end

local TWO = { { { 'objective', 'Title' } }, { { '  step', 'Comment' } } }

T.case('set shows the panel above line 1', function()
  local buf = long_buffer()
  P.set(buf, TWO)
  T.eq(vim.fn.winsaveview().topfill, 2)
  local marks = vim.api.nvim_buf_get_extmarks(buf, -1, 0, -1, { details = true })
  T.eq(#marks, 1)
  T.eq(#marks[1][4].virt_lines, 2)
end)

T.case('the panel comes back when the cursor returns to line 1 (gg)', function()
  local buf = long_buffer()
  P.set(buf, TWO)
  keys('G')
  moved(buf)
  keys('gg')
  moved(buf)
  T.eq(vim.fn.winsaveview().topfill, 2)
end)

T.case('scrolling down from the top with <C-e> is not undone', function()
  local buf = long_buffer()
  P.set(buf, TWO)
  keys('<C-e>')
  moved(buf)
  T.eq(vim.fn.winsaveview().topfill, 1)
end)

T.case('an empty list removes the panel', function()
  local buf = long_buffer()
  P.set(buf, TWO)
  P.set(buf, {})
  T.eq(#vim.api.nvim_buf_get_extmarks(buf, -1, 0, -1, {}), 0)
end)

T.case('wrap breaks at word boundaries and splits overlong words', function()
  T.eq(P.wrap('alpha beta gamma', 11), { 'alpha beta', 'gamma' })
  T.eq(P.wrap('abcdefghij', 4), { 'abcd', 'efgh', 'ij' })
  T.eq(P.wrap('', 10), { '' })
  T.eq(P.wrap('a  b', 10), { 'a b' })
end)
