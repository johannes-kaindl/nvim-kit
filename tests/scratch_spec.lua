local T = require('nvim_kit.test')
local S = require('nvim_kit.scratch')

T.case('open creates a named, read-only buffer with lines and filetype', function()
  local buf = S.open('kitprobe://view', { 'a', 'b' }, { filetype = 'markdown' })
  T.eq(vim.api.nvim_get_current_buf(), buf)
  T.eq(vim.api.nvim_buf_get_name(buf), 'kitprobe://view')
  T.eq(vim.api.nvim_buf_get_lines(buf, 0, -1, false), { 'a', 'b' })
  T.eq(vim.bo[buf].modifiable, false)
  T.eq(vim.bo[buf].buftype, 'nofile')
  T.eq(vim.bo[buf].filetype, 'markdown')
end)

T.case('opening the same name again replaces the buffer', function()
  local a = S.open('kitprobe://again', { 'old' })
  local b = S.open('kitprobe://again', { 'new' })
  T.ok(a ~= b)
  T.eq(vim.api.nvim_buf_is_valid(a), false)
  T.eq(S.find('kitprobe://again'), b)
  T.eq(vim.api.nvim_buf_get_lines(b, 0, -1, false), { 'new' })
end)

T.case('keys are buffer-local and never global', function()
  local hit = 0
  local before = #vim.api.nvim_get_keymap('n')
  S.open('kitprobe://keys', { 'x' }, { keys = {
    ['<CR>'] = function()
      hit = hit + 1
    end,
  } })
  -- no 'n' flag: it would bypass mappings
  vim.api.nvim_feedkeys(vim.api.nvim_replace_termcodes('<CR>', true, false, true), 'tx', false)
  T.eq(hit, 1)
  T.eq(#vim.api.nvim_get_keymap('n'), before)
  vim.cmd('enew')
  T.eq(vim.fn.maparg('<CR>', 'n'), '')
end)

T.case('modifiable buffers stay editable; set_lines keeps the setting', function()
  local buf = S.open('kitprobe://edit', { 'a' }, { modifiable = true, bufhidden = 'hide', listed = true })
  T.eq(vim.bo[buf].modifiable, true)
  T.eq(vim.bo[buf].buflisted, true)
  local ro = S.open('kitprobe://ro', { 'a' })
  S.set_lines(ro, { 'b', 'c' })
  T.eq(vim.api.nvim_buf_get_lines(ro, 0, -1, false), { 'b', 'c' })
  T.eq(vim.bo[ro].modifiable, false)
end)

T.case('replacing a buffer keeps every window that showed it', function()
  vim.cmd('silent! only')
  local a = S.open('kitprobe://split', { 'old' })
  vim.cmd('vsplit')
  T.eq(#vim.fn.win_findbuf(a), 2)
  local b = S.open('kitprobe://split', { 'new' })
  T.eq(#vim.api.nvim_tabpage_list_wins(0), 2)
  T.eq(#vim.fn.win_findbuf(b), 2)
  vim.cmd('silent! only')
end)

T.case('the initial text is not undoable', function()
  local buf = S.open('kitprobe://undo', { 'abc', 'def' }, { modifiable = true })
  vim.cmd('silent! normal! xuuuu')
  T.eq(vim.api.nvim_buf_get_lines(buf, 0, -1, false), { 'abc', 'def' })
end)

T.case('set_lines paints line highlights and replaces the old ones', function()
  local buf = S.open('kitprobe://marks', { 'a' })
  S.set_lines(buf, { 'title', 'body' }, { { 1, 'Title' } })
  local marks = vim.api.nvim_buf_get_extmarks(buf, -1, 0, -1, { details = true })
  T.eq(#marks, 1)
  T.eq(marks[1][2], 0)
  T.eq(marks[1][4].line_hl_group, 'Title')
  S.set_lines(buf, { 'x' }, {})
  T.eq(#vim.api.nvim_buf_get_extmarks(buf, -1, 0, -1, {}), 0)
end)

-- close: a fresh single-window state; `keep` is a normal buffer to fall back to
local function lone_window()
  vim.cmd('silent! tabonly | silent! only')
  pcall(function()
    vim.wo.winfixbuf = false -- a failed winfixbuf case must not leak into later specs
  end)
  vim.cmd('enew')
  return vim.api.nvim_get_current_win()
end

T.case('close: the last window shows the fallback and the buffer is wiped', function()
  local win = lone_window()
  local keep = vim.api.nvim_create_buf(false, true)
  local buf = S.open('kitprobe://close1', { 'x' }, { bufhidden = 'hide' })
  T.eq(vim.api.nvim_win_get_buf(win), buf)
  S.close(buf, keep)
  T.eq(vim.api.nvim_buf_is_valid(buf), false)
  T.eq(vim.api.nvim_win_get_buf(win), keep)
end)

T.case('close: closes every window that shows the buffer and leaves the others', function()
  local other = lone_window()
  local shown = vim.api.nvim_win_get_buf(other)
  vim.cmd('vsplit')
  local buf = S.open('kitprobe://close2', { 'x' }, { bufhidden = 'hide' })
  vim.cmd('vsplit')
  T.eq(#vim.fn.win_findbuf(buf), 2)
  T.eq(#vim.api.nvim_tabpage_list_wins(0), 3)
  S.close(buf, vim.api.nvim_create_buf(false, true))
  T.eq(vim.api.nvim_buf_is_valid(buf), false)
  T.eq(vim.api.nvim_tabpage_list_wins(0), { other })
  T.eq(vim.api.nvim_win_get_buf(other), shown)
end)

T.case('close: an invalid fallback gives the last window an empty buffer', function()
  local win = lone_window()
  local gone = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_buf_delete(gone, { force = true })
  local buf = S.open('kitprobe://close3', { 'x' }, { bufhidden = 'hide' })
  S.close(buf, gone)
  T.eq(vim.api.nvim_buf_is_valid(buf), false)
  local shown = vim.api.nvim_win_get_buf(win)
  T.ok(shown ~= buf)
  T.eq(vim.api.nvim_buf_get_lines(shown, 0, -1, false), { '' })
  -- Neovim itself puts a listed buffer into a window whose buffer it deletes; close is explicit
  T.eq(vim.bo[shown].buflisted, false)
  T.eq(vim.bo[shown].buftype, 'nofile')
  -- no fallback at all: the same
  local buf2 = S.open('kitprobe://close3b', { 'x' }, { bufhidden = 'hide' })
  S.close(buf2)
  T.eq(vim.api.nvim_buf_is_valid(buf2), false)
  T.eq(vim.api.nvim_buf_is_valid(vim.api.nvim_win_get_buf(win)), true)
end)

T.case('close: a buffer that is already wiped is a no-op', function()
  lone_window()
  local buf = S.open('kitprobe://close4', { 'x' })
  vim.api.nvim_buf_delete(buf, { force = true })
  S.close(buf, nil)
  S.close(buf, buf)
  T.eq(vim.api.nvim_buf_is_valid(buf), false)
end)

T.case('close: also closes a floating window and a window in another tab page', function()
  lone_window()
  local buf = S.open('kitprobe://close5', { 'x' }, { bufhidden = 'hide' })
  local float =
    vim.api.nvim_open_win(buf, false, { relative = 'editor', row = 1, col = 1, width = 5, height = 1 })
  vim.cmd('tabnew')
  vim.api.nvim_win_set_buf(0, buf)
  vim.cmd('tabfirst')
  S.close(buf)
  T.eq(vim.api.nvim_buf_is_valid(buf), false)
  T.eq(vim.api.nvim_win_is_valid(float), false)
  T.eq(#vim.api.nvim_list_tabpages(), 1)
end)

T.case('close: invalid arguments raise', function()
  T.raises(function()
    S.close('x')
  end, 'buf must be a number')
  T.raises(function()
    S.close(nil)
  end, 'buf must be a number')
  local buf = vim.api.nvim_create_buf(false, true)
  T.raises(function()
    S.close(buf, 'x')
  end, 'fallback must be')
  T.eq(vim.api.nvim_buf_is_valid(buf), true)
end)

T.case('close: a bufhidden=wipe buffer wiped by its last window closing is not deleted twice', function()
  lone_window()
  local buf = S.open('kitprobe://close7', { 'x' }) -- bufhidden=wipe
  vim.cmd('vsplit')
  T.eq(#vim.fn.win_findbuf(buf), 2)
  S.close(buf, vim.api.nvim_create_buf(false, true))
  T.eq(vim.api.nvim_buf_is_valid(buf), false)
  T.eq(#vim.api.nvim_tabpage_list_wins(0), 1)
end)

T.case('close: a modified buffer in the last window does not raise and is gone', function()
  local win = lone_window()
  local buf = S.open('kitprobe://close8', { 'x' }) -- bufhidden=wipe
  vim.bo[buf].buftype = 'acwrite'
  S.set_lines(buf, { 'changed' })
  vim.bo[buf].modified = true
  S.close(buf, vim.api.nvim_create_buf(false, true))
  T.eq(vim.api.nvim_buf_is_valid(buf), false)
  T.ok(vim.api.nvim_win_get_buf(win) ~= buf)
end)

T.case('close: the placeholder buffer is wiped when left, nothing piles up', function()
  local win = lone_window()
  local before = #vim.api.nvim_list_bufs()
  for i = 1, 2 do
    local buf = S.open('kitprobe://close9' .. i, { 'x' }, { bufhidden = 'hide' })
    S.close(buf)
  end
  local placeholder = vim.api.nvim_win_get_buf(win)
  T.eq(vim.bo[placeholder].bufhidden, 'wipe')
  local elsewhere = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_win_set_buf(win, elsewhere)
  T.eq(vim.api.nvim_buf_is_valid(placeholder), false)
  T.eq(#vim.api.nvim_list_bufs(), before + 1) -- `elsewhere`, no leftovers
end)

T.case('close: a failing WinClosed autocmd does not stop the deletion', function()
  lone_window()
  vim.cmd('vsplit')
  local buf = S.open('kitprobe://close10', { 'x' }, { bufhidden = 'hide' })
  local id = vim.api.nvim_create_autocmd('WinClosed', {
    callback = function()
      error('third-party failure')
    end,
  })
  local ok, err = pcall(S.close, buf, vim.api.nvim_create_buf(false, true))
  vim.api.nvim_del_autocmd(id)
  T.ok(ok, tostring(err))
  T.eq(vim.api.nvim_buf_is_valid(buf), false)
end)

T.case('close: a winfixbuf last window still gets the fallback', function()
  local win = lone_window()
  local buf = S.open('kitprobe://close11', { 'x' }, { bufhidden = 'hide' })
  vim.wo[win].winfixbuf = true
  local keep = vim.api.nvim_create_buf(false, true)
  S.close(buf, keep)
  T.eq(vim.api.nvim_buf_is_valid(buf), false)
  T.eq(vim.api.nvim_win_get_buf(win), keep)
  vim.wo[win].winfixbuf = false
end)

T.case('close: calling close again from its own BufUnload/BufWipeout is a no-op', function()
  lone_window()
  local buf = S.open('kitprobe://close12', { 'x' }) -- bufhidden=wipe, in the last window
  local inner
  local id = vim.api.nvim_create_autocmd({ 'BufDelete', 'BufUnload', 'BufWipeout' }, {
    buffer = buf,
    callback = function()
      local r = { pcall(S.close, buf) }
      if inner == nil or inner[1] then
        inner = r
      end
    end,
  })
  local ok, err = pcall(S.close, buf, vim.api.nvim_create_buf(false, true))
  pcall(vim.api.nvim_del_autocmd, id)
  T.ok(ok, tostring(err))
  T.ok(inner and inner[1], inner and tostring(inner[2]))
  T.eq(vim.api.nvim_buf_is_valid(buf), false)
end)

local function lines_buf(n)
  local buf = vim.api.nvim_create_buf(false, true)
  local lines = {}
  for i = 1, n do
    lines[i] = 'line number ' .. i
  end
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
  return buf
end

T.case('reveal: focuses the window of this tab page that shows the buffer, opens no window', function()
  lone_window()
  local buf = lines_buf(5)
  local win = vim.api.nvim_get_current_win()
  vim.api.nvim_win_set_buf(win, buf)
  vim.cmd('botright new')
  local other = vim.api.nvim_get_current_win()
  local before = #vim.api.nvim_tabpage_list_wins(0)
  local got = S.reveal(buf, 3, 5)
  T.eq(got, win)
  T.eq(vim.api.nvim_get_current_win(), win)
  T.eq(#vim.api.nvim_tabpage_list_wins(0), before)
  T.eq(vim.api.nvim_win_get_cursor(win), { 3, 5 })
  T.ok(other ~= win)
end)

T.case('reveal: no window shows the buffer, so a split opens above and shows it', function()
  local win0 = lone_window()
  local buf = lines_buf(4)
  T.eq(#vim.fn.win_findbuf(buf), 0)
  local got = S.reveal(buf, 2, 0)
  T.ok(got ~= win0)
  T.eq(#vim.api.nvim_tabpage_list_wins(0), 2)
  T.eq(vim.api.nvim_win_get_buf(got), buf)
  T.eq(vim.api.nvim_get_current_win(), got)
  T.eq(vim.api.nvim_win_get_cursor(got), { 2, 0 })
  -- aboveleft split: the new window is above the old one
  T.ok(vim.api.nvim_win_get_position(got)[1] < vim.api.nvim_win_get_position(win0)[1])
end)

T.case('reveal: a window of another tab page does not count', function()
  lone_window()
  local buf = lines_buf(3)
  vim.cmd('tabnew')
  vim.api.nvim_win_set_buf(0, buf)
  local elsewhere = vim.api.nvim_get_current_win()
  vim.cmd('tabprevious')
  local got = S.reveal(buf, 1, 0)
  T.ok(got ~= elsewhere)
  T.eq(vim.api.nvim_win_get_tabpage(got), vim.api.nvim_get_current_tabpage())
  vim.cmd('tabonly')
end)

T.case('reveal: row and col are clamped to a buffer that shrank', function()
  lone_window()
  local buf = lines_buf(2)
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, { 'abc', 'de' })
  local win = S.reveal(buf, 40, 99)
  T.eq(vim.api.nvim_win_get_cursor(win), { 2, 1 }) -- last line, last byte
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, { '' })
  win = S.reveal(buf, 7, 3)
  T.eq(vim.api.nvim_win_get_cursor(win), { 1, 0 })
  win = S.reveal(buf, 0, -4)
  T.eq(vim.api.nvim_win_get_cursor(win), { 1, 0 })
end)

T.case('reveal: invalid arguments raise', function()
  local buf = lines_buf(2)
  T.raises(function()
    S.reveal('x', 1, 0)
  end, 'buf')
  T.raises(function()
    S.reveal(buf, '1', 0)
  end, 'row')
  T.raises(function()
    S.reveal(buf, 1.5, 0)
  end, 'row')
  T.raises(function()
    S.reveal(buf, 1, nil)
  end, 'col')
  local gone = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_buf_delete(gone, { force = true })
  T.raises(function()
    S.reveal(gone, 1, 0)
  end, 'not valid')
end)

T.case('reveal: a column past a multibyte line lands on a character start', function()
  lone_window()
  local buf = lines_buf(1)
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, { 'äö' })
  local win = S.reveal(buf, 1, 99)
  T.eq(vim.api.nvim_win_get_cursor(win), { 1, 2 }) -- the start of ö, not its second byte
end)

T.case('reveal: a window that cannot be focused does not count', function()
  lone_window()
  local buf = lines_buf(3)
  local float = vim.api.nvim_open_win(buf, false, {
    relative = 'editor',
    row = 1,
    col = 1,
    width = 10,
    height = 2,
    focusable = false,
  })
  local win = S.reveal(buf, 2, 0)
  T.ok(win ~= float)
  T.eq(vim.api.nvim_get_current_win(), win)
  T.eq(vim.api.nvim_win_get_buf(win), buf)
  pcall(vim.api.nvim_win_close, float, true)
end)
