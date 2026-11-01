local T = require('nvim_kit.test')
local E = require('nvim_kit.endpoint_model')

-- A store over a fresh state file; `put` writes raw text into it.
local function fresh(opts)
  local dir = vim.fn.tempname()
  local path = dir .. '/sub/state.json'
  local em = E.new(path, opts)
  local function put(text)
    vim.fn.mkdir(dir .. '/sub', 'p')
    local f = assert(io.open(path, 'wb'))
    f:write(text)
    f:close()
  end
  local function saved()
    local f = assert(io.open(path, 'rb'))
    local text = f:read('*a')
    f:close()
    return vim.json.decode(text)
  end
  return em, put, saved, path
end

-- Run fn with vim.ui.select answering `pick` (an index, or nil to dismiss); fn gets a getter for
-- the prompt and the items the picker was shown.
local function with_select(pick, fn)
  local original = vim.ui.select
  local prompt, shown
  vim.ui.select = function(items, o, cb)
    prompt, shown = o.prompt, items
    cb(pick and items[pick] or nil)
  end
  local ok, err = pcall(fn, function()
    return prompt, shown
  end)
  vim.ui.select = original
  assert(ok, err)
end

T.case('new: a path that is neither a string nor a function raises', function()
  T.raises(function()
    E.new(nil)
  end, 'takes a string or a function')
  T.raises(function()
    E.new({})
  end, 'takes a string or a function')
  E.new('/x') -- counter-check: both accepted forms do not raise
  E.new(function()
    return '/x'
  end)
end)

T.case('path: a string is returned as is, a function is called on every use', function()
  local n = 0
  local em = E.new(function()
    n = n + 1
    return '/p/' .. n
  end)
  T.eq({ em.path(), em.path() }, { '/p/1', '/p/2' })
  T.eq(E.new('/fixed/state.json').path(), '/fixed/state.json')
end)

T.case('model: a model is remembered per endpoint URL and read back', function()
  local em, _, saved = fresh()
  T.eq(em.model('http://a'), nil)
  em.set_model('http://a', 'm1')
  em.set_model('http://b', 'm2')
  em.set_model('http://a', 'm3')
  T.eq(em.model('http://a'), 'm3')
  T.eq(em.model('http://b'), 'm2')
  T.eq(em.model('http://c'), nil) -- an unknown URL
  T.eq(saved(), { models = { ['http://a'] = 'm3', ['http://b'] = 'm2' } })
end)

T.case('model: no file at all reads as nil without raising', function()
  local em = fresh()
  T.eq(em.model('http://a'), nil)
end)

T.case('model: an empty file reads as nil and does not stop a write', function()
  local em, put = fresh()
  put('')
  T.eq(em.model('http://a'), nil)
  em.set_model('http://a', 'm1')
  T.eq(em.model('http://a'), 'm1')
end)

T.case('model: a broken file reads as nil, is set aside and the next write succeeds', function()
  local em, put, _, path = fresh()
  put('{ not json')
  T.eq(em.model('http://a'), nil)
  T.eq(#vim.fn.glob(path .. '.broken-*', false, true), 1)
  em.set_model('http://a', 'm1')
  T.eq(em.model('http://a'), 'm1')
end)

T.case('model: valid JSON that is not an object reads as nil', function()
  local em, put = fresh()
  put('["models"]')
  T.eq(em.model('http://a'), nil)
  em.set_model('http://a', 'm1')
  T.eq(em.model('http://a'), 'm1')
end)

T.case('model: "models" as a list is not read and is replaced by an object on write', function()
  local em, put, saved = fresh()
  put('{"models":["x"]}')
  T.eq(em.model('http://a'), nil)
  em.set_model('http://a', 'm1')
  T.eq(em.model('http://a'), 'm1')
  T.eq(saved(), { models = { ['http://a'] = 'm1' } })
end)

T.case('model: other keys of the file survive a write', function()
  local em, put, saved = fresh()
  put('{"other":{"keep":1},"models":{"http://b":"m2"}}')
  em.set_model('http://a', 'm1')
  T.eq(saved(), { other = { keep = 1 }, models = { ['http://a'] = 'm1', ['http://b'] = 'm2' } })
end)

T.case('model: an entry that is no string is not a model', function()
  local em, put = fresh()
  put('{"models":{"http://a":5,"http://b":"m"}}')
  T.eq(em.model('http://a'), nil)
  T.eq(em.model('http://b'), 'm')
end)

T.case('choose: a pick is remembered for the endpoint and answered', function()
  local em = fresh()
  with_select(2, function(shown)
    local got = 'unset'
    em.choose({ url = 'http://x' }, { 'a', 'b' }, function(id)
      got = id
    end)
    local _, items = shown()
    T.eq({ got, em.model('http://x'), items }, { 'b', 'b', { 'a', 'b' } })
  end)
end)

T.case('choose: dismissing answers nil and stores nothing, not even a file', function()
  local em, _, _, path = fresh()
  with_select(nil, function()
    local got = 'unset'
    em.choose({ url = 'http://x' }, { 'a', 'b' }, function(id)
      got = id
    end)
    T.eq({ got, em.model('http://x'), (vim.uv.fs_stat(path)) }, { nil, nil, nil })
  end)
end)

T.case('choose: the prompt carries the prefix from new, a prefix in opts wins, none is allowed', function()
  local function prompt_of(em, opts)
    local out
    with_select(1, function(shown)
      em.choose({ url = 'http://x' }, { 'a' }, function() end, opts)
      out = shown()
    end)
    return out
  end
  T.eq(prompt_of((fresh({ prompt_prefix = 'transmute' }))), 'transmute: model on http://x')
  T.eq(
    prompt_of((fresh({ prompt_prefix = 'transmute' })), { prompt_prefix = 'other' }),
    'other: model on http://x'
  )
  T.eq(prompt_of((fresh())), 'model on http://x')
end)

T.case('two stores over two files do not see each other', function()
  local a, b = fresh(), fresh()
  a.set_model('http://x', 'ma')
  T.eq({ a.model('http://x'), b.model('http://x') }, { 'ma', nil })
end)

T.case('set_model: valid JSON that is not an object is set aside, not overwritten', function()
  local em, put, saved, path = fresh()
  put('"x"')
  em.set_model('http://a', 'm')
  T.eq(#vim.fn.glob(path .. '.broken-*', false, true), 1)
  T.eq(saved().models['http://a'], 'm')
end)

T.case('model: an unreadable state file reads as nil instead of raising', function()
  local em, put, _, path = fresh()
  put('{"models":{"http://a":"m"}}')
  vim.uv.fs_chmod(path, 0)
  T.eq(io.open(path, 'rb'), nil, 'precondition: file must be unreadable')
  local ok, err = pcall(function()
    T.eq(em.model('http://a'), nil)
  end)
  vim.uv.fs_chmod(path, tonumber('644', 8))
  assert(ok, err)
end)
