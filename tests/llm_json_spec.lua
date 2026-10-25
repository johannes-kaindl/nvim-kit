local T = require('nvim_kit.test')
local C = require('nvim_kit.conformance')
local J = require('nvim_kit.llm_json')
local here = vim.fn.fnamemodify(debug.getinfo(1, 'S').source:sub(2), ':p:h')
local VECTORS = here .. '/conformance/code-kit'

-- The vectors use code-kit's names and shapes; the adapters are the only translation.
local IMPLS = dofile(here .. '/adapters/llm_json.lua')

local function run(name, impl)
  local v = C.load_dir(VECTORS)[name]
  T.ok(v, 'no vector file for ' .. name)
  return #v.cases, C.run(v, impl or IMPLS[name])
end

T.case('passes every code-kit stripThinkBlocks vector', function()
  local n, failures = run('stripThinkBlocks')
  T.eq(n, 500)
  T.eq(failures, {})
end)

T.case('passes every code-kit firstJsonObject vector', function()
  local n, failures = run('firstJsonObject')
  T.eq(n, 40)
  T.eq(failures, {})
end)

T.case('counter-check: a lenient decoder (vim.json alone) fails the NaN/hex/leading-zero vectors', function()
  local _, failures = run('firstJsonObject', function(raw)
    for span in raw:gmatch('%b{}') do
      local ok, v = pcall(vim.json.decode, span, { luanil = { object = true } })
      if ok then
        return v
      end
    end
    return nil
  end)
  local names = {}
  for _, f in ipairs(failures) do
    names[f.name] = true
  end
  T.ok(names['NaN is no json'] and names['hex number is no json'] and names['leading zero is no json'])
end)

T.case('counter-check: dropping only the first stray close fails stripThinkBlocks', function()
  local _, failures = run('stripThinkBlocks', function(text, o)
    if o and o.dropStrayClose then
      local i = text:find('</think>', 1, true)
      if i then
        text = text:sub(i + 8)
      end
      return J.strip_think(text, { drop_unclosed = o.dropUnclosed })
    end
    return IMPLS.stripThinkBlocks(text, o)
  end)
  T.ok(#failures > 0)
end)

-- Lua-only inputs (review of building block 1).
T.case('repair drops a trailing comma after U+00A0 and other JS whitespace (finding M9)', function()
  T.eq(J.first_json_object('{"a":1,\194\160}', { repair = true }), { a = 1 })
  T.eq(J.first_json_object('{"a":[1,\226\128\168]}', { repair = true }), { a = { 1 } })
  T.eq(J.first_json_object('{"a":1,\239\187\191 }', { repair = true }), { a = 1 })
  T.eq(J.first_json_object('{"a":1,\194\160}', {}), nil, 'without repair it stays broken')
end)

T.case('counter-check: with Lua %s the U+00A0 comma is not repaired', function()
  local span = '{"a":1,\194\160}'
  local lua_s = span:gsub(',%s*([}%]])', '%1')
  T.eq(lua_s, span)
end)

T.case('strict JSON: what JSON.parse refuses is refused, what it takes is taken', function()
  for _, bad in ipairs({
    '{"a":NaN}',
    '{"a":Infinity}',
    '{"a":-Infinity}',
    '{"a":0x10}',
    '{"a":01}',
    '{"a":+1}',
    '{"a":1.}',
    '{"a":.5}',
    '{"a":"x\ty"}',
    '{"a":1,}',
    '{a:1}',
    '{"a":tru}',
    '{"a":1}x',
    '{"a" 1}',
    '[1 2]',
    '',
    '{"a":"\\x41"}',
    '{"a":"\\u12G4"}',
  }) do
    T.eq(J.is_strict_json(bad), false, bad)
  end
  for _, good in ipairs({
    '{}',
    '[]',
    ' {"a" : [ 1 , -0.5e+3 , true , false , null , "\\u00e4\\n" ] } ',
    '{"a":{"b":{"c":[[]]}}}',
    '0',
    '"x"',
  }) do
    T.eq(J.is_strict_json(good), true, good)
  end
end)

T.case('deep nesting costs no Lua stack in the strict check', function()
  local deep = ('['):rep(100000) .. (']'):rep(100000)
  T.eq(J.is_strict_json(deep), true)
end)

T.case('a null inside the object becomes an absent field, a null in a list stays vim.NIL', function()
  local o = J.first_json_object('{"a":null,"b":[null,1]}')
  T.eq(rawget(o, 'a'), nil)
  T.ok(o.b[1] == vim.NIL)
end)

T.case('linear on hostile input: 50 000 openers in a few hundred ms at most', function()
  for _, s in ipairs({ ('<think>'):rep(50000), ('[1,'):rep(50000), ('\\"['):rep(50000), ('{'):rep(50000) }) do
    local t0 = vim.uv.hrtime()
    J.first_json_object(s)
    local ms = (vim.uv.hrtime() - t0) / 1e6
    T.ok(ms < 1000, ('%d ms for %q…'):format(ms, s:sub(1, 6)))
  end
end)
