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

-- names in the directory of path that are not path itself (temp files are dot files there)
local function leftovers(path)
  local dir, name = vim.fn.fnamemodify(path, ':h'), vim.fn.fnamemodify(path, ':t')
  local out = {}
  for entry in vim.fs.dir(dir) do
    if entry ~= name then
      table.insert(out, entry)
    end
  end
  table.sort(out)
  return out
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
  T.eq(leftovers(p), {})
end)

T.case('set_aside moves a file that is valid JSON but not usable', function()
  local p = tmp()
  vim.fn.writefile({ '[1, 2]' }, p)
  local aside = S.set_aside(p)
  T.eq(vim.fn.filereadable(p), 0)
  T.eq(raw(aside), '[1, 2]')
end)

T.case('read with expect = object moves aside a file that is JSON but not an object', function()
  local p = tmp()
  vim.fn.writefile({ '[1, 2]' }, p)
  local v, info = S.read(p, { expect = 'object' })
  T.eq(v, nil)
  T.ok(info.broken, 'moved aside')
  T.eq(raw(info.broken), '[1, 2]')
  vim.fn.writefile({ '{}' }, p)
  T.json_eq(S.read(p, { expect = 'object' }), '{}')
end)

T.case('update passes expect on to the read', function()
  local p = tmp()
  vim.fn.writefile({ '"just a string"' }, p)
  local seen
  S.update(p, function(v, info)
    seen = info
    return v or {}
  end, { expect = 'object' })
  T.ok(seen.broken, 'moved aside before fn ran')
end)

T.case('a file that exists but cannot be read is an error, never "no file"', function()
  local p = tmp()
  vim.fn.mkdir(vim.fn.fnamemodify(p, ':h'), 'p')
  vim.fn.writefile({ '{"total_xp": 500}' }, p)
  vim.fn.setfperm(p, '---------')
  local ok, err = pcall(S.read, p)
  local ok2 = pcall(S.update, p, function(v)
    return v or { fresh = true }
  end)
  vim.fn.setfperm(p, 'rw-r--r--')
  T.eq(ok, false)
  T.ok(tostring(err):find('cannot read', 1, true), tostring(err))
  T.eq(ok2, false)
  T.eq(vim.fn.readfile(p), { '{"total_xp": 500}' })
end)

T.case('write_bytes keeps NUL and 0xFF bytes and leaves no temp file', function()
  local p = tmp()
  local bytes = 'a\0b\255c\r\n\0'
  S.write_bytes(p, bytes)
  local f = assert(io.open(p, 'rb'))
  local back = f:read('*a')
  f:close()
  T.eq(back, bytes)
  T.eq(leftovers(p), {})
  S.write_bytes(p, '')
  T.eq(vim.uv.fs_stat(p).size, 0)
  T.eq(leftovers(p), {})
end)

T.case('write_bytes creates the target directory', function()
  local p = vim.fn.tempname() .. '/a/b/c.bin'
  S.write_bytes(p, 'x')
  T.eq(vim.uv.fs_stat(p).size, 1)
  T.eq(leftovers(p), {})
end)

T.case('write_bytes replaces an existing file whole', function()
  local p = tmp()
  S.write_bytes(p, ('long'):rep(1000))
  S.write_bytes(p, 'short')
  T.eq(vim.uv.fs_stat(p).size, 5)
end)

T.case('write_bytes raises loudly and leaves no temp file when a directory is in the way', function()
  local p = tmp()
  vim.fn.mkdir(p, 'p') -- the target is a non-empty directory: rename over it fails
  vim.fn.writefile({ 'x' }, p .. '/inner')
  local ok, err = pcall(S.write_bytes, p, 'data')
  T.eq(ok, false)
  T.ok(tostring(err):find('cannot replace', 1, true), tostring(err))
  T.eq(leftovers(p), {})
  T.eq(vim.fn.isdirectory(p), 1)
end)

T.case('write_bytes raises loudly when the target directory cannot be created', function()
  local blocker = tmp() -- a file where a directory should be
  vim.fn.writefile({ 'x' }, blocker)
  local ok = pcall(S.write_bytes, blocker .. '/sub/file.bin', 'data')
  T.eq(ok, false)
  T.eq(vim.fn.readfile(blocker), { 'x' })
end)

T.case('write_bytes refuses arguments that are not strings', function()
  T.raises(function()
    S.write_bytes(tmp(), 12)
  end)
end)

T.case('write goes through write_bytes: JSON bytes, no temp file', function()
  local p = tmp()
  S.write(p, { a = 1 })
  T.eq(raw(p), '{"a":1}')
  T.eq(leftovers(p), {})
end)

T.case('mkdir_p creates nested directories, accepts existing ones and a trailing slash', function()
  local base = vim.fn.tempname()
  S.mkdir_p(base .. '/a/b/c')
  T.eq(vim.fn.isdirectory(base .. '/a/b/c'), 1)
  S.mkdir_p(base .. '/a/b/c') -- already there
  S.mkdir_p(base .. '/a/b/d/')
  T.eq(vim.fn.isdirectory(base .. '/a/b/d'), 1)
  S.mkdir_p('') -- nothing to create
  S.mkdir_p('/')
  vim.fn.delete(base, 'rf')
end)

T.case('mkdir_p raises when a file is in the way, at the end or on the way', function()
  local base = vim.fn.tempname()
  vim.fn.mkdir(base, 'p')
  vim.fn.writefile({ 'x' }, base .. '/file')
  local ok, err = pcall(S.mkdir_p, base .. '/file')
  T.eq(ok, false)
  T.ok(tostring(err):find('in the way', 1, true), tostring(err))
  ok, err = pcall(S.mkdir_p, base .. '/file/sub')
  T.eq(ok, false)
  T.ok(tostring(err):find('in the way', 1, true), tostring(err))
  T.raises(function()
    S.mkdir_p(nil)
  end, 'string')
  vim.fn.delete(base, 'rf')
end)

T.case('mkdir_p and write_bytes work in a fast callback, where vim.fn.mkdir raises E5560', function()
  local base = vim.fn.tempname()
  local res
  local timer = vim.uv.new_timer()
  timer:start(0, 0, function()
    res = {
      fast = vim.in_fast_event(),
      fn = { pcall(vim.fn.mkdir, base .. '/via-fn', 'p') },
      ours = { pcall(S.write_bytes, base .. '/deep/er/f.bin', 'abc') },
    }
  end)
  vim.wait(2000, function()
    return res ~= nil
  end, 5)
  timer:close()
  T.ok(res, 'the timer did not fire')
  T.eq(res.fast, true)
  T.eq(
    res.fn[1],
    false,
    'vim.fn.mkdir is expected to refuse here; if it does not, this test no longer proves anything'
  )
  T.eq(res.ours[1], true, tostring(res.ours[2]))
  T.eq(vim.fn.readfile(base .. '/deep/er/f.bin'), { 'abc' })
  vim.fn.delete(base, 'rf')
end)

T.case(
  'write_bytes: a write that fails half way (EFBIG under ulimit, as ENOSPC on a full disk) raises and keeps the old file',
  function()
    local dir = vim.fn.tempname()
    vim.fn.mkdir(dir, 'p')
    local root = vim.fn.fnamemodify(debug.getinfo(1, 'S').source:sub(2), ':p:h:h')
    local script = ('ulimit -f 4; trap "" XFSZ; exec %s --headless -u NONE -l %s %s'):format(
      vim.fn.shellescape(vim.v.progpath),
      vim.fn.shellescape(root .. '/tests/store_efbig_child.lua'),
      vim.fn.shellescape(dir)
    )
    local res = vim.system({ 'sh', '-c', script }, { text = true, timeout = 20000 }):wait()
    local out = (res.stdout or '') .. (res.stderr or '')
    local raised, intact, names, err = out:match('RESULT (%a+) (%a+) ([^|]*)| ([^\n]*)')
    T.ok(raised, 'the child printed no RESULT: ' .. out:sub(-500))
    T.eq(raised, 'true', 'write_bytes must raise: ' .. out)
    T.ok(err:find('EFBIG', 1, true), 'expected a file-too-large error: ' .. err)
    T.eq(intact, 'true', 'the old file changed')
    T.eq(vim.trim(names), 'f.bin', 'a temp file was left behind')
    vim.fn.delete(dir, 'rf')
  end
)
