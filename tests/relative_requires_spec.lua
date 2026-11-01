local T = require('nvim_kit.test')

-- A plugin vendors the kit under its own namespace (lua/<plugin>/kit/), where `nvim_kit.<name>` does
-- not exist. A module that requires a sibling by its absolute name works here and fails in every copy.
-- Siblings are required relative to the module's own name: `require(base .. 'store')`.

local root = vim.fn.fnamemodify(debug.getinfo(1, 'S').source:sub(2), ':p:h:h')

--- The `require('nvim_kit.…')` calls in a Lua source, as written.
local function absolute_requires(source)
  local found = {}
  for call in source:gmatch('require%s*%(?%s*[\'"]nvim_kit[%w_.]*[\'"]%)?') do
    found[#found + 1] = call
  end
  return found
end

T.case('relative requires: the scan finds an absolute require (control)', function()
  T.eq(absolute_requires("local store = require('nvim_kit.store')\n"), { "require('nvim_kit.store')" })
  T.eq(absolute_requires('local s = require "nvim_kit.store"\n'), { 'require "nvim_kit.store"' })
  T.eq(absolute_requires("local s = require(base .. 'store')\nlocal b = require('bit')\n"), {})
end)

T.case('relative requires: no kit module requires a sibling by its absolute name', function()
  local files = vim.fn.globpath(root .. '/lua/nvim_kit', '**/*.lua', false, true)
  T.ok(#files > 20, 'found the kit modules, got ' .. #files)
  local offenders = {}
  for _, path in ipairs(files) do
    local f = assert(io.open(path, 'rb'))
    local source = f:read('*a')
    f:close()
    for _, call in ipairs(absolute_requires(source)) do
      offenders[#offenders + 1] = path:sub(#root + 2) .. ': ' .. call
    end
  end
  T.eq(offenders, {})
end)
