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

-- which-key lays its triggers into the buffer on BufEnter, before apply sets the filetype, and
-- checks its filetype list only when it adds them (measured in LazyVim 2026-10-14, neurovim.nvim:
-- 6 triggers, <Space>p swallowed). Clearing them once the filetype is listed keeps them out.
local function with_which_key_buf(fn)
  local saved = package.loaded['which-key.buf']
  local cleared = {}
  package.loaded['which-key.buf'] = {
    clear = function(o)
      cleared[#cleared + 1] = o.buf
    end,
  }
  local ok, err = pcall(fn, cleared)
  package.loaded['which-key.buf'] = saved
  if not ok then
    error(err, 0)
  end
end

T.case('isolated: which-key triggers already in the buffer are cleared, and again on BufEnter', function()
  with_which_key(function()
    with_which_key_buf(function(cleared)
      with_setup(function()
        local buf = open(true)
        T.eq(cleared, { buf })
        vim.cmd('enew')
        vim.api.nvim_set_current_buf(buf)
        T.eq(cleared, { buf, buf })
      end)
    end)
  end)
end)

T.case('counter-check: not isolated clears no which-key trigger', function()
  with_which_key(function()
    with_which_key_buf(function(cleared)
      with_setup(function()
        open(false)
      end)
      T.eq(cleared, {})
    end)
  end)
end)

T.case('isolated: without which-key loaded nothing is cleared and nothing fails', function()
  local saved_buf, saved_cfg = package.loaded['which-key.buf'], package.loaded['which-key.config']
  package.loaded['which-key.buf'], package.loaded['which-key.config'] = nil, nil
  local ok, err = pcall(with_setup, function()
    open(true)
  end)
  package.loaded['which-key.buf'], package.loaded['which-key.config'] = saved_buf, saved_cfg
  assert(ok, err)
end)

-- mini.clue adds its triggers one tick after BufWinEnter, and its buffer switch only stops new
-- ones: unmapping returns early once miniclue_disable is set (measured with mini.clue 149236a: an
-- apply one tick late kept the <Space> trigger). So apply unmaps them before setting the switch.
T.case('isolated: mini.clue triggers already in the buffer are removed before its switch is set', function()
  local saved = package.loaded['mini.clue']
  local calls = {}
  package.loaded['mini.clue'] = {
    disable_buf_triggers = function(b)
      calls[#calls + 1] = { b, vim.b[b].miniclue_disable }
    end,
  }
  local ok, err = pcall(with_setup, function()
    local buf = open(true)
    T.eq(calls, { { buf, nil } })
  end)
  package.loaded['mini.clue'] = saved
  assert(ok, err)
end)

T.case('counter-check: not isolated leaves mini.clue triggers alone', function()
  local saved = package.loaded['mini.clue']
  local calls = 0
  package.loaded['mini.clue'] = {
    disable_buf_triggers = function()
      calls = calls + 1
    end,
  }
  local ok, err = pcall(with_setup, function()
    open(false)
  end)
  package.loaded['mini.clue'] = saved
  assert(ok, err)
  T.eq(calls, 0)
end)

-- which-key does not map its triggers on BufEnter itself: the mode it builds there schedules them
-- (a 0 ms timer). Applied in the same tick, as a plugin does right after opening its buffer,
-- `clear` finds nothing mapped and drops the mode, and the timer maps them afterwards (measured
-- with which-key 3aab214: 5 triggers left, <Space> among them). This double keeps that order: its
-- BufEnter leaves a mode with triggers, and a 0 ms timer maps that mode's triggers later.
local function with_scheduled_which_key(fn)
  local saved = package.loaded['which-key.buf']
  local wb = { bufs = {}, fired = 0 }
  function wb.clear(o)
    local b = wb.bufs[o.buf]
    if b then
      b.modes = {}
    end
  end
  local group = vim.api.nvim_create_augroup('kit_test_which_key', { clear = true })
  vim.api.nvim_create_autocmd('BufEnter', {
    group = group,
    callback = function(ev)
      local buf = ev.buf
      local cfg = package.loaded['which-key.config']
      if vim.tbl_contains(cfg.options.disable.ft, vim.bo[buf].filetype) then
        return
      end
      local mode = { triggers = { { keys = ' ' }, { keys = 'g`' } } }
      wb.bufs[buf] = { modes = { n = mode } }
      vim.defer_fn(function()
        if not vim.api.nvim_buf_is_valid(buf) then
          return
        end
        for _, node in ipairs(mode.triggers) do
          vim.keymap.set('n', node.keys, function()
            wb.fired = wb.fired + 1
          end, { buffer = buf, nowait = true, desc = 'which-key-trigger' })
        end
      end, 0)
    end,
  })
  package.loaded['which-key.buf'] = wb
  local ok, err = pcall(fn, wb)
  vim.api.nvim_del_augroup_by_id(group)
  package.loaded['which-key.buf'] = saved
  if not ok then
    error(err, 0)
  end
end

local function wk_triggers(buf)
  local n = 0
  for _, m in ipairs(vim.api.nvim_buf_get_keymap(buf, 'n')) do
    if (m.desc or ''):find('which-key-trigger', 1, true) then
      n = n + 1
    end
  end
  return n
end

local scratch = require('nvim_kit.scratch')

-- The way neurovim.nvim opens its mission buffer: scratch.open, then apply right away.
T.case('isolated in the same tick as BufEnter: which-key maps no trigger afterwards', function()
  with_which_key(function()
    with_scheduled_which_key(function()
      with_setup(function()
        local buf = scratch.open(
          'kitprobe://same-tick',
          { 'text' },
          { modifiable = true, bufhidden = 'hide', listed = false }
        )
        I.apply(buf, { filetype = FILETYPE })
        vim.wait(30)
        T.eq(wk_triggers(buf), 0)
        vim.cmd('enew')
        vim.api.nvim_set_current_buf(buf)
        vim.wait(30)
        T.eq(wk_triggers(buf), 0)
      end)
    end)
  end)
end)

T.case('counter-check: not isolated, the scheduled which-key triggers arrive', function()
  with_which_key(function()
    with_scheduled_which_key(function()
      with_setup(function()
        local buf = scratch.open(
          'kitprobe://not-isolated',
          { 'text' },
          { modifiable = true, bufhidden = 'hide', listed = false }
        )
        vim.wait(30)
        T.eq(wk_triggers(buf), 2)
      end)
    end)
  end)
end)

-- which-key's config module runs setup() when a missing field is read (its __index), so reading
-- `options` before the user's setup would set which-key up with defaults (measured with 3aab214).
T.case('isolated: which-key loaded but not set up is not set up by apply', function()
  local saved = package.loaded['which-key.config']
  local setup_ran = false
  package.loaded['which-key.config'] = setmetatable({}, {
    __index = function()
      setup_ran = true
      return { disable = { ft = {} } }
    end,
  })
  local ok, err = pcall(with_setup, function()
    open(true)
  end)
  package.loaded['which-key.config'] = saved
  assert(ok, err)
  T.eq(setup_ran, false)
end)

-- The three cases measured in LazyVim (neurovim.nvim, which-key 3aab214, 2026-10-14), each opened
-- with scratch.open and isolated right away: <Space>p on a <Plug> mapping, <Space>c on a :Cmd<CR>
-- mapping, and <Space>p after :enew and back. A which-key trigger on <Space> left in the buffer
-- takes <Space> at once (nowait) when a person types it, and p pastes. Headless, that shows only
-- with one key at a time; but then a lone <Space> resolves as a motion (the typeahead ends), so
-- whether <Space>p reaches its target is checked with both keys at once, where the longest match
-- wins. Together: the trigger never fires, and the mapping does its job.
local function neurovim_like(isolated)
  local hits = { reveal = 0, cmd = 0 }
  vim.keymap.set('n', '<Plug>(kit-reveal)', function()
    hits.reveal = hits.reveal + 1
  end)
  vim.api.nvim_create_user_command('KitHit', function()
    hits.cmd = hits.cmd + 1
  end, {})
  local buf = scratch.open('kitprobe://keys-' .. tostring(isolated), { 'text' }, {
    modifiable = true,
    bufhidden = 'hide',
    listed = false,
  })
  vim.keymap.set('n', '<Leader>p', '<Plug>(kit-reveal)', { buffer = buf })
  vim.keymap.set('n', '<Leader>c', ':KitHit<CR>', { buffer = buf })
  if isolated then
    I.apply(buf, { filetype = FILETYPE })
  end
  vim.wait(30)
  vim.fn.setreg('"', 'PASTED')
  return buf, hits
end

local function with_leader(fn)
  local leader, reg = vim.g.mapleader, vim.fn.getreginfo('"')
  vim.g.mapleader = ' '
  local ok, err = pcall(fn)
  vim.g.mapleader = leader
  vim.fn.setreg('"', reg)
  pcall(vim.keymap.del, 'n', '<Plug>(kit-reveal)')
  pcall(vim.api.nvim_del_user_command, 'KitHit')
  if not ok then
    error(err, 0)
  end
end

-- Runs k on a fresh neurovim-like buffer; one_by_one feeds each key on its own.
local function keys_case(isolated, k, opts)
  opts = opts or {}
  local buf, hits, fired
  with_which_key(function()
    with_scheduled_which_key(function(wb)
      with_setup(function()
        with_leader(function()
          buf, hits = neurovim_like(isolated)
          if opts.reenter then
            vim.cmd('enew')
            vim.api.nvim_set_current_buf(buf)
            vim.wait(30)
          end
          if opts.one_by_one then
            for _, key in ipairs(vim.split(k, '')) do
              typed(key)
            end
          else
            typed(k)
          end
          fired = wb.fired
        end)
      end)
    end)
  end)
  return table.concat(vim.api.nvim_buf_get_lines(buf, 0, -1, false), '|'), hits, fired
end

for _, c in ipairs({
  { name = '<Space>p', keys = ' p', hit = 'reveal' },
  { name = '<Space>c', keys = ' c', hit = 'cmd' },
  { name = '<Space>p after :enew and back', keys = ' p', hit = 'reveal', reenter = true },
}) do
  T.case(
    'isolated in the same tick: ' .. c.name .. ' — the which-key trigger never takes <Space>',
    function()
      local _, _, fired = keys_case(true, c.keys, { one_by_one = true, reenter = c.reenter })
      T.eq(fired, 0)
    end
  )
  T.case('isolated in the same tick: ' .. c.name .. ' reaches its mapping, the text stays', function()
    local text, hits = keys_case(true, c.keys, { reenter = c.reenter })
    T.eq({ text, hits[c.hit] }, { 'text', 1 })
  end)
end

T.case('counter-check: not isolated, the which-key trigger takes <Space> and p pastes', function()
  local text, hits, fired = keys_case(false, ' p', { one_by_one = true })
  T.eq({ fired, hits.reveal }, { 1, 0 })
  T.ok(text ~= 'text', text)
end)

-- On re-entry which-key builds the buffer's modes again when the filetype is not on its list,
-- e.g. after the user's own setup() replaced the options apply had added it to. The trigger
-- queued then must not survive either.
T.case('isolated: triggers which-key queues again on re-entry are kept out', function()
  local n
  with_which_key(function(wk)
    with_scheduled_which_key(function()
      with_setup(function()
        local buf = scratch.open(
          'kitprobe://reenter',
          { 'text' },
          { modifiable = true, bufhidden = 'hide', listed = false }
        )
        I.apply(buf, { filetype = FILETYPE })
        vim.wait(30)
        wk.options = { disable = { ft = { 'help' } } } -- the user's setup() runs after apply
        vim.cmd('enew')
        vim.api.nvim_set_current_buf(buf)
        vim.wait(30)
        n = wk_triggers(buf)
      end)
    end)
  end)
  T.eq(n, 0)
end)

T.case('counter-check: not isolated, re-entry queues the triggers again', function()
  local n
  with_which_key(function(wk)
    with_scheduled_which_key(function(wb)
      with_setup(function()
        local buf = scratch.open(
          'kitprobe://reenter-plain',
          { 'text' },
          { modifiable = true, bufhidden = 'hide', listed = false }
        )
        vim.wait(30)
        for _, m in ipairs(vim.api.nvim_buf_get_keymap(buf, 'n')) do
          pcall(vim.keymap.del, 'n', m.lhs, { buffer = buf })
        end
        wb.bufs = {}
        wk.options = { disable = { ft = { 'help' } } }
        vim.cmd('enew')
        vim.api.nvim_set_current_buf(buf)
        vim.wait(30)
        n = wk_triggers(buf)
      end)
    end)
  end)
  T.eq(n, 2)
end)
