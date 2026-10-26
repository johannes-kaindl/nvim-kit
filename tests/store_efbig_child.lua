-- Run by tests/store_spec.lua under `ulimit -f` (a file cannot grow past a few KB, the write fails
-- with EFBIG the way it fails with ENOSPC on a full disk): writes a small file, then tries a big
-- one over it. Prints "RESULT <raised> <old file intact> <leftover names>".
local root = vim.fn.fnamemodify(debug.getinfo(1, 'S').source:sub(2), ':p:h:h')
vim.opt.rtp:prepend(root)
local S = require('nvim_kit.store')
local dir = arg[1]
local path = dir .. '/f.bin'
local small = ('a'):rep(1000)
S.write_bytes(path, small)
local ok, err = pcall(S.write_bytes, path, ('b'):rep(20000))
local f = assert(io.open(path, 'rb'))
local now = f:read('*a')
f:close()
local names = {}
for name in vim.fs.dir(dir) do
  names[#names + 1] = name
end
table.sort(names)
io.write(
  ('RESULT %s %s %s | %s\n'):format(
    tostring(not ok),
    tostring(now == small),
    table.concat(names, ','),
    tostring(err)
  )
)
