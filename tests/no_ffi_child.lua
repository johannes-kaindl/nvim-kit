-- Run by tests/no_ffi_spec.lua in a second Neovim: `require('ffi')` fails here, the way it does on
-- a Lua without LuaJIT's FFI, so vectors and the indexer take their list path. Runs the specs that
-- touch the matrix and the container and prints "<n> passed, <m> failed"; exit 1 on a failure.
local root = vim.fn.fnamemodify(debug.getinfo(1, 'S').source:sub(2), ':p:h:h')
vim.opt.rtp:prepend(root)

package.loaded['ffi'] = nil
package.preload['ffi'] = function()
  error("module 'ffi' not found (switched off by tests/no_ffi_child.lua)")
end

local T = require('nvim_kit.test')
local V = require('nvim_kit.vectors')

local cases, current = {}, nil
T.case = function(name, fn)
  cases[#cases + 1] = { file = current, name = name, fn = fn }
end

local failed, passed = 0, 0
local function fail(msg)
  failed = failed + 1
  io.write('FAIL ' .. msg .. '\n')
end

if pcall(require, 'ffi') then
  fail('ffi is still loadable: the child does not test the list path')
end
local probe = V.parse({
  schema_version = 1,
  embedding_model = 'm',
  index_dim = 2,
  scale = 127,
  count = 1,
  granularity = 'note',
  quant = 'int8',
}, { 'a.md' }, string.char(127, 0))
if probe.ffi ~= false or type(probe.data) ~= 'table' then
  fail('vectors.parse did not take the list path')
end

for _, name in ipairs(arg) do
  current = name
  local ok, err = pcall(dofile, root .. '/tests/' .. name .. '.lua')
  if not ok then
    fail(name .. ' (load): ' .. tostring(err))
  end
end
for _, c in ipairs(cases) do
  local ok, err = pcall(c.fn)
  if ok then
    passed = passed + 1
  else
    fail(('%s :: %s\n     %s'):format(c.file, c.name, tostring(err)))
  end
end
local len, crc = dofile(root .. '/tests/no_ffi_bytes.lua')()
io.write(('BYTES %d %d\n'):format(len, crc))
io.write(('%d passed, %d failed\n'):format(passed, failed))
os.exit((failed > 0 or passed == 0) and 1 or 0)
