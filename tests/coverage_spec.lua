local T = require('nvim_kit.test')
local C = require('nvim_kit.conformance')
local here = vim.fn.fnamemodify(debug.getinfo(1, 'S').source:sub(2), ':p:h')

-- Every code-kit vector file has an adapter, and every adapter belongs to a vector file: a vector
-- nobody runs (or an adapter nobody feeds) is a silent hole in the port's conformance.
local function adapter_keys()
  local keys, owner = {}, {}
  local files = vim.fn.globpath(here .. '/adapters', '*.lua', false, true)
  table.sort(files)
  for _, file in ipairs(files) do
    for name, impl in pairs(dofile(file)) do
      -- an adapter file may share helpers with its spec under a `_`-prefixed key
      if name:sub(1, 1) ~= '_' then
        T.eq(type(impl), 'function', file .. ': ' .. tostring(name))
        T.ok(not owner[name], ('%s is adapted twice (%s, %s)'):format(name, owner[name] or '', file))
        owner[name] = file
        keys[#keys + 1] = name
      end
    end
  end
  table.sort(keys)
  return keys, #files
end

local function vector_names()
  local names = vim.tbl_keys(C.load_dir(here .. '/conformance/code-kit'))
  table.sort(names)
  return names
end

T.case('the adapters under tests/adapters cover exactly the code-kit vector functions', function()
  local keys, n_files = adapter_keys()
  T.ok(n_files >= 9, 'adapter files found: ' .. n_files)
  T.eq(keys, vector_names())
end)

T.case('counter-check: a missing adapter entry, or one without a vector, is a difference', function()
  local keys = adapter_keys()
  local names = vector_names()
  local without = vim.list_slice(keys, 2)
  T.ok(not vim.deep_equal(without, names), 'dropping one adapter must turn the comparison red')
  local extra = vim.list_extend(vim.deepcopy(keys), { 'noSuchVector' })
  table.sort(extra)
  T.ok(not vim.deep_equal(extra, names), 'an adapter without a vector must turn it red')
end)
