-- The index code has two paths: a LuaJIT `float[]` with `ffi` and a Lua list without it. The main
-- suite runs the first; this spec runs the indexer, vector and container specs again in a second
-- Neovim where `require('ffi')` fails, and compares the container bytes of both paths. The byte
-- comparison needs inputs where float32 rounding decides an int8 value (`no_ffi_bytes.lua`); the
-- golden sha256 inside the child's `live_indexer_dim_spec` is the proof against vault-rag's bytes,
-- this case is the proof that both paths agree.
local T = require('nvim_kit.test')

local root = vim.fn.fnamemodify(debug.getinfo(1, 'S').source:sub(2), ':p:h:h')
local SPECS =
  { 'live_indexer_spec', 'live_indexer_dim_spec', 'live_indexer_stamps_spec', 'vectors_spec', 'vrix_spec' }

-- A lower bound for the cases the child must run: the `T.case(` lines of its specs (a case made in a
-- loop only adds to the count). A child that loaded half of them cannot pass.
local function case_count()
  local n = 0
  for _, name in ipairs(SPECS) do
    for line in io.lines(root .. '/tests/' .. name .. '.lua') do
      if line:match('^T%.case%(') then
        n = n + 1
      end
    end
  end
  return n
end

local function run_child()
  local cmd = { vim.v.progpath, '--headless', '-u', 'NONE', '-l', root .. '/tests/no_ffi_child.lua' }
  vim.list_extend(cmd, SPECS)
  return vim.system(cmd, { text = true, timeout = 280000 }):wait()
end

local result

T.case('without ffi: the indexer, vector and container specs pass on the list path', function()
  result = run_child()
  local out = (result.stdout or '') .. (result.stderr or '')
  T.eq(result.code, 0, out:sub(-3000))
  local passed, failed = out:match('(%d+) passed, (%d+) failed')
  T.eq(failed, '0', out:sub(-3000))
  local wanted = case_count()
  T.ok(tonumber(passed) >= wanted, ('only %s of at least %d cases ran'):format(tostring(passed), wanted))
end)

T.case('without ffi: the container has the same bytes as with ffi', function()
  result = result or run_child()
  local len, crc = (result.stdout or ''):match('BYTES (%d+) (%d+)')
  T.ok(len, 'the child printed no BYTES line: ' .. tostring(result.stdout):sub(-500))
  local has_ffi = pcall(require, 'ffi')
  T.ok(has_ffi, 'this run is meant to have ffi')
  local own_len, own_crc = dofile(root .. '/tests/no_ffi_bytes.lua')()
  T.eq({ own_len, own_crc }, { tonumber(len), tonumber(crc) })
end)
