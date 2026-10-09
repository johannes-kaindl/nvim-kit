local T = require('nvim_kit.test')
local S = require('nvim_kit.store')

local function tmp()
  local dir = vim.fn.tempname()
  vim.fn.mkdir(dir, 'p')
  return dir .. '/state.json'
end

local function raw(path)
  return table.concat(vim.fn.readfile(path), '\n')
end

T.case('a missing file reads as nil', function()
  local v, info = S.read(tmp())
  T.eq(v, nil)
  T.eq(info, {})
end)

T.case('write then read keeps null and empty objects', function()
  local p = tmp()
  S.write(p, vim.json.decode('{"a": null, "o": {}, "l": [], "n": {"x": null}}'))
  T.json_eq(S.read(p), '{"a": null, "o": {}, "l": [], "n": {"x": null}}')
end)

T.case('a file without valid JSON is moved aside, never dropped', function()
  local p = tmp()
  vim.fn.writefile({ '{ not json' }, p)
  local v, info = S.read(p)
  T.eq(v, nil)
  T.ok(info.broken and info.broken:find(p .. '.broken-', 1, true), vim.inspect(info))
  T.eq(vim.fn.filereadable(p), 0)
  T.eq(raw(info.broken), '{ not json')
end)

T.case('two broken files in the same second do not overwrite each other', function()
  local p = tmp()
  vim.fn.writefile({ 'one' }, p)
  local _, a = S.read(p)
  vim.fn.writefile({ 'two' }, p)
  local _, b = S.read(p)
  T.ok(a.broken ~= b.broken)
  T.eq(raw(a.broken), 'one')
  T.eq(raw(b.broken), 'two')
end)

T.case('update re-reads the file and sees a change made by another editor', function()
  local p = tmp()
  S.update(p, function()
    return { mine = 1 }
  end)
  S.write(p, { mine = 1, theirs = 2 }) -- the other Neovim instance
  S.update(p, function(v)
    v.mine = 3
    return v
  end)
  T.json_eq(S.read(p), '{"mine": 3, "theirs": 2}')
end)

T.case('update returns everything fn returned, and leaves no temp files', function()
  local p = tmp()
  local a, b, c = S.update(p, function()
    return { x = 1 }, 'second', nil
  end)
  T.eq(a, { x = 1 })
  T.eq(b, 'second')
  T.eq(c, nil)
  T.eq(vim.fn.glob(p .. '.tmp-*', false, true), {})
end)

T.case('set_aside moves a file that is valid JSON but not usable', function()
  local p = tmp()
  vim.fn.writefile({ '[1, 2]' }, p)
  local aside = S.set_aside(p)
  T.eq(vim.fn.filereadable(p), 0)
  T.eq(raw(aside), '[1, 2]')
end)
