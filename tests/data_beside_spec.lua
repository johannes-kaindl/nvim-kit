local T = require('nvim_kit.test')
local D = require('nvim_kit.data')

local SRC = "return require('nvim_kit.data').beside(debug.getinfo(1, 'S').source, 'd.json')"

T.case('beside resolves against the given file, not against data.lua or the cwd', function()
  local dir = vim.fn.tempname()
  vim.fn.mkdir(dir .. '/sub', 'p')
  vim.fn.writefile({ SRC }, dir .. '/sub/caller.lua')
  T.eq(dofile(dir .. '/sub/caller.lua'), vim.fn.fnamemodify(dir .. '/sub', ':p:h') .. '/d.json')
end)

T.case('beside works under vim.loader (the bytecode cache keeps the file name)', function()
  local dir = vim.fn.tempname()
  vim.fn.mkdir(dir .. '/lua/probe_beside', 'p')
  vim.fn.writefile({ SRC }, dir .. '/lua/probe_beside/init.lua')
  local root = vim.fn.fnamemodify(debug.getinfo(1, 'S').source:sub(2), ':p:h:h')
  local script = dir .. '/probe.lua'
  vim.fn.writefile({
    ('vim.opt.rtp:prepend(%q)'):format(root),
    ('vim.opt.rtp:prepend(%q)'):format(dir),
    'vim.loader.enable()',
    "io.write(require('probe_beside'))",
  }, script)
  for _ = 1, 2 do -- the second run reads the cached bytecode
    local r = vim.system({ vim.v.progpath, '--headless', '-u', 'NONE', '-l', script }):wait()
    T.eq(r.stdout, vim.fn.fnamemodify(dir, ':p:h') .. '/lua/probe_beside/d.json', r.stderr)
  end
end)

T.case('beside raises for a chunk loaded from a string and for a missing source', function()
  T.raises(loadstring(SRC), 'needs a file source')
  T.raises(function()
    D.beside(nil, 'd.json')
  end, 'needs a file source')
end)
