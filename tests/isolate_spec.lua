-- Ported from neurovim.nvim 1e4c619 tests/isolate_spec.lua (15 cases). There a mission buffer
-- (mission.start, config.isolate) was the subject; here it is a plain buffer with or without
-- isolate.apply, and keytrack stands in for the mission's key count.
local T = require('nvim_kit.test')
local I = require('nvim_kit.isolate')
local K = require('nvim_kit.keytrack')

vim.o.showmode = false
vim.opt.shortmess:append('Sq')

-- The user's setup, simulated: global mappings and options the way plugins and distributions set
-- them (flash on f, a surround on sa, mini.ai's text objects, LazyVim's H, dial on <C-a>).
local USER_MAPS = {
  { { 'n', 'x', 'o' }, 'f', 'F' },
  { { 'n', 'x', 'o' }, 's', 'x' },
  { 'n', 'sa', 'x' },
  { { 'x', 'o' }, 'iw', 'aw' },
  { 'n', 'gs', 'x' },
  { 'n', 'H', 'x' },
  { 'n', '<C-a>', '<C-x>' },
}

local USER_OPTIONS = {
  textwidth = 10,
  shiftwidth = 2,
  expandtab = true,
  nrformats = 'bin,hex,unsigned',
  iskeyword = '@,48-57,_,192-255,-',
  conceallevel = 3,
  virtualedit = 'block',
  scrolloff = 4,
}

local FILETYPE = 'kitprobe'

-- Runs fn with the user's setup in place and puts everything back afterwards, also on failure.
local function with_setup(fn)
  local saved_opts = {}
  for name, value in pairs(USER_OPTIONS) do
    saved_opts[name] = vim.o[name]
    vim.o[name] = value
  end
  for _, m in ipairs(USER_MAPS) do
    vim.keymap.set(m[1], m[2], m[3])
  end
  local ok, err = pcall(fn)
  for _, m in ipairs(USER_MAPS) do
    pcall(vim.keymap.del, m[1], m[2])
  end
  for name, value in pairs(saved_opts) do
    vim.o[name] = value
  end
  if not ok then
    error(err, 0)
  end
end

-- A buffer the way a plugin opens one: named, shown, Markdown, then isolated or not. The name
-- matters: :enew reuses an unnamed empty buffer instead of leaving it (AGENTS.md, Gotchas).
local function open(isolated)
  local buf = vim.api.nvim_create_buf(true, true)
  vim.api.nvim_buf_set_name(buf, 'kitprobe://' .. buf)
  vim.api.nvim_set_current_buf(buf)
  vim.bo[buf].filetype = 'markdown'
  if isolated then
    I.apply(buf, { filetype = FILETYPE, desc = 'kit probe key' })
  end
  return buf
end

-- Keys go in through mappings (no n flag), all at once: a full typeahead is the hard case, where
-- the longest mapping wins. :silent keeps the echo of typed commands out of the test report.
local function typed(k)
  vim.g.kit_test_keys = vim.api.nvim_replace_termcodes(k, true, false, true)
  vim.cmd('silent call feedkeys(g:kit_test_keys, "tx")')
  vim.g.kit_test_keys = nil
end

vim.api.nvim_create_user_command('KitIso', function() end, {})

-- Plays keys on lines in a fresh buffer; returns the text afterwards and the keys counted.
local function play(isolated, k, lines)
  local buf = open(isolated)
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
  vim.api.nvim_win_set_cursor(0, { 1, 0 })
  local t = K.start(buf, { exclude_cmdline = '^%s*KitIso' })
  typed(k)
  t.stop()
  return table.concat(vim.api.nvim_buf_get_lines(buf, 0, -1, false), '|'), t.keys()
end

-- Each key sequence with the text it works on and what nvim --clean leaves behind.
local CLEAN = {
  { '0fcx', { 'abcabc' }, 'ababc' },
  { 'sX<Esc>', { 'abc' }, 'Xbc' },
  { 'saZ<Esc>', { 'abc' }, 'aZbc' },
  { 'wciwNEW<Esc>', { 'old mid end' }, 'old NEW end' },
  { 'gsx', { 'abc' }, 'bc' },
  { 'Hx', { 'abc' }, 'bc' },
  { '3<C-a>', { 'v 7' }, 'v 10' },
}

T.case('isolated: the keys do what they do in nvim --clean', function()
  with_setup(function()
    for _, c in ipairs(CLEAN) do
      T.eq((play(true, c[1], c[2])), c[3], c[1])
    end
  end)
end)

T.case('counter-check: not isolated, the same keys run into the user mappings', function()
  with_setup(function()
    for _, c in ipairs(CLEAN) do
      local out = play(false, c[1], c[2])
      T.ok(out ~= c[3], c[1] .. ' gave the clean result without isolation: ' .. out)
    end
  end)
end)

T.case('isolated: the plain-Vim mappings cost no extra keys', function()
  with_setup(function()
    local _, n = play(true, '0fcx', { 'abcabc' })
    T.eq(n, 4)
    _, n = play(true, 'sX<Esc>', { 'abc' })
    T.eq(n, 3)
  end)
end)

T.case('isolated: a typed excluded command still costs nothing', function()
  with_setup(function()
    local _, n = play(true, ':KitIso<CR>', { 'x' })
    T.eq(n, 0)
  end)
end)

T.case("isolated: Neovim's own default mappings stay (Y is y$, not yy)", function()
  with_setup(function()
    T.eq((play(true, 'wYP', { 'one two' })), 'one twotwo')
  end)
end)

T.case('isolated: mappings under <Leader> stay the user’s', function()
  local leader = vim.g.mapleader
  vim.g.mapleader = ' '
  local hit = false
  vim.keymap.set('n', '<leader>z', function()
    hit = true
  end)
  local ok, err = pcall(with_setup, function()
    play(true, ' z', { 'abc' })
  end)
  pcall(vim.keymap.del, 'n', '<leader>z')
  vim.g.mapleader = leader
  assert(ok, err)
  T.eq(hit, true)
end)

-- A single key is covered from the start; a longer mapping added later needs the next BufEnter.
T.case('isolated: a mapping a plugin adds after apply is covered on the next BufEnter', function()
  with_setup(function()
    local buf = open(true)
    vim.keymap.set('o', 'aw', 'iw')
    local ok, err = pcall(function()
      vim.cmd('enew')
      vim.api.nvim_set_current_buf(buf)
      vim.api.nvim_buf_set_lines(buf, 0, -1, false, { 'one two three' })
      vim.api.nvim_win_set_cursor(0, { 1, 0 })
      typed('wdaw')
      T.eq(vim.api.nvim_buf_get_lines(buf, 0, -1, false), { 'one three' })
    end)
    pcall(vim.keymap.del, 'o', 'aw')
    assert(ok, err)
  end)
end)

T.case('isolated: own filetype, Neovim defaults for options that change the text', function()
  with_setup(function()
    local buf = open(true)
    T.eq(vim.bo[buf].filetype, FILETYPE)
    T.eq(vim.bo[buf].textwidth, 0)
    T.eq(vim.bo[buf].shiftwidth, 8)
    T.eq(vim.bo[buf].expandtab, false)
    T.eq(vim.bo[buf].nrformats, 'bin,hex')
    T.eq(vim.bo[buf].iskeyword, '@,48-57,_,192-255')
    T.eq(vim.wo.conceallevel, 0)
    T.eq(vim.wo.scrolloff, 0)
    T.eq(vim.api.nvim_get_option_value('virtualedit', { scope = 'local' }), 'NONE')
  end)
end)

T.case('counter-check: not isolated keeps markdown and the user options', function()
  with_setup(function()
    local buf = open(false)
    T.eq(vim.bo[buf].filetype, 'markdown')
    T.eq(vim.bo[buf].textwidth, 10)
    T.eq(vim.bo[buf].nrformats, 'bin,hex,unsigned')
  end)
end)

T.case('isolated: textwidth of the user does not break a typed line', function()
  with_setup(function()
    T.eq((play(true, 'Aone two three four<Esc>', { 'x' })), 'xone two three four')
  end)
end)

T.case('isolated: editor helpers are switched off by their buffer switches, diagnostics too', function()
  with_setup(function()
    local buf = open(true)
    T.eq(vim.b[buf].completion, false)
    T.eq(vim.b[buf].minipairs_disable, true)
    T.eq(vim.b[buf].miniai_disable, true)
    T.eq(vim.diagnostic.is_enabled({ bufnr = buf }), false)
  end)
end)

T.case('counter-check: not isolated sets no buffer switch', function()
  with_setup(function()
    local buf = open(false)
    T.eq(vim.b[buf].completion, nil)
    T.eq(vim.b[buf].minipairs_disable, nil)
    T.eq(vim.diagnostic.is_enabled({ bufnr = buf }), true)
  end)
end)

-- The test runner starts with -u NONE -l, where Neovim's defaults carry other script ids than in a
-- real start. So ask a real `nvim --clean` (the same binary) what it calls an override: nothing.
T.case('nvim --clean has no mapping that counts as an override, Y and matchit included', function()
  local root = vim.fn.fnamemodify(debug.getinfo(1, 'S').source:sub(2), ':p:h:h')
  local lua = ([[vim.opt.rtp:prepend(%q)
local out = {}
for _, o in ipairs(require('nvim_kit.isolate').overrides()) do out[#out + 1] = o.mode .. ' ' .. o.lhs end
local n = 0
for _, mode in ipairs({ 'n', 'x', 'o' }) do n = n + #vim.api.nvim_get_keymap(mode) end
io.write(n .. ' mappings; overrides: ' .. table.concat(out, ', '))
vim.cmd('qa!')]]):format(root)
  local file = vim.fn.tempname() .. '.lua'
  vim.fn.writefile(vim.split(lua, '\n'), file)
  local r = vim.system({ vim.v.progpath, '--clean', '--headless', '-c', 'luafile ' .. file }):wait()
  T.eq(r.code, 0, r.stderr)
  T.ok(r.stdout:find('overrides: $') ~= nil, r.stdout)
  -- Without this the check could pass on an empty keymap.
  T.ok(tonumber(r.stdout:match('^(%d+) mappings')) > 20, r.stdout)
end)

-- which-key starts on its own when Operator-pending or Visual mode begins (ModeChanged), without a
-- mapping to cover; its only switch per buffer is its filetype list. Measured in LazyVim
-- 2026-10-14 (neurovim.nvim): `dw` typed at human pace counted 3.
local function with_which_key(fn)
  local saved = package.loaded['which-key.config']
  local wk = { options = { disable = { ft = { 'help' }, bt = {} } } }
  package.loaded['which-key.config'] = wk
  local ok, err = pcall(fn, wk)
  package.loaded['which-key.config'] = saved
  if not ok then
    error(err, 0)
  end
end

T.case('isolated: which-key is told to leave the filetype alone, once', function()
  with_which_key(function(wk)
    with_setup(function()
      open(true)
      open(true)
    end)
    T.eq(wk.options.disable.ft, { 'help', FILETYPE })
  end)
end)

T.case('counter-check: not isolated leaves which-key as it is', function()
  with_which_key(function(wk)
    with_setup(function()
      open(false)
    end)
    T.eq(wk.options.disable.ft, { 'help' })
  end)
end)
