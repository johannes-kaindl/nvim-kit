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
