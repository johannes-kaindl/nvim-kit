local T = require('nvim_kit.test')
local C = require('nvim_kit.conformance')
local V = require('nvim_kit.vectors')
local vrix = require('nvim_kit.vrix')
local here = vim.fn.fnamemodify(debug.getinfo(1, 'S').source:sub(2), ':p:h')
local VECTORS = here .. '/conformance/code-kit'
-- The vectors use code-kit's names and shapes; the adapters are the only translation.
local ADAPTERS = dofile(here .. '/adapters/vrix.lua')

local has_ffi = pcall(require, 'ffi')

-- Float scores and the renormalised rows agree to 1e-6 (the vector README); the rest is exact.
local NAMES = {
  crc32 = nil,
  decodeContainer = nil,
  encodeContainer = nil,
  containerRetrieve = { tolerance = 1e-6 },
}
local ORDER = { 'crc32', 'decodeContainer', 'encodeContainer', 'containerRetrieve' }

local function run(adapters)
  local vectors = C.load_dir(VECTORS)
  local failures, cases = {}, 0
  for _, name in ipairs(ORDER) do
    T.ok(vectors[name], 'no vector file for ' .. name)
    cases = cases + #vectors[name].cases
    for _, f in ipairs(C.run(vectors[name], adapters[name], NAMES[name])) do
      f['function'] = name
      failures[#failures + 1] = f
    end
  end
  return cases, failures
end

local function failed_names(failures)
  local names = {}
  for _, f in ipairs(failures) do
    names[#names + 1] = f.name
  end
  table.sort(names)
  return names
end

for _, backend in ipairs({ true, false }) do
  local label = backend and 'ffi' or 'no ffi'
  T.case('passes every code-kit vector (6 + 21 + 6 + 11 cases), ' .. label, function()
    local vectors = C.load_dir(VECTORS)
    T.eq(#vectors.crc32.cases, 6)
    T.eq(#vectors.decodeContainer.cases, 21)
    T.eq(#vectors.encodeContainer.cases, 6)
    T.eq(#vectors.containerRetrieve.cases, 11)
    V._use_ffi(backend)
    local ok, err = pcall(function()
      local cases, failures = run(ADAPTERS)
      T.eq(cases, 44)
      T.eq(failures, {})
    end)
    V._use_ffi(true)
    if not ok then
      error(err, 0)
    end
  end)
end

T.case('the ffi setting is back on after the cases', function()
  local idx = V.parse({ index_dim = 1, scale = 127, count = 1 }, { 'a' }, '\127')
  T.eq(idx.ffi, has_ffi)
end)

local MANIFEST = {
  schema_version = 2,
  vault = 'v',
  embedding_model = 'm',
  source_dim = 3,
  index_dim = 3,
  granularity = 'note',
  aggregation = 'mean',
  quant = 'int8',
  scale = 127,
  count = 2,
  source_commit = 'abc',
  built_at = '2026-10-17T00:00:00Z',
}
local MATRIX = '\127\0\0\90\90\0'

local function golden_hex()
  local vectors = C.load_dir(VECTORS)
  return vectors.decodeContainer.cases[1].args[1]
end

T.case('crc32: the check value of the CRC-32 catalogue, and the range', function()
  T.eq(vrix.crc32('123456789'), 3421780262)
  T.eq(vrix.crc32(''), 0)
  T.eq(vrix.crc32('\255'), 4278190080, 'above 2^31 stays a positive number')
  T.raises(function()
    vrix.crc32(12)
  end, 'crc32 needs')
end)

T.case('crc32: a long input in one pass agrees with the vector of 1000 bytes', function()
  local parts = {}
  for i = 0, 999 do
    parts[#parts + 1] = string.char(i % 256)
  end
  T.eq(vrix.crc32(table.concat(parts)), 1961098049)
end)

T.case('encode: a path with DEL puts the byte raw into the header, as JSON.stringify does', function()
  local bytes = vrix.encode(MANIFEST, { 'a\127b.md', 'c.md' }, MATRIX)
  T.ok(bytes:find('"a\127b.md"', 1, true), 'DEL is raw')
  T.ok(not bytes:find('u007f', 1, true), 'not masked as \\u007f')
  local d = assert(vrix.decode(bytes))
  T.eq(d.paths, { 'a\127b.md', 'c.md' })
end)

T.case('the gotcha behind the DEL case: vim.json.encode masks DEL, so it cannot write the header', function()
  -- If a Neovim ever stops masking it, the hand-written encoder can go; until then it must stay.
  T.eq(vim.json.encode('a\127b'), '"a\\u007fb"')
end)

T.case('encode: control characters, quote, backslash and slash follow JSON.stringify', function()
  local path = 'a"b\\c/d\ne\rf\tg\bh\fi\1j\31k\127l\195\164.md'
  local bytes = vrix.encode(MANIFEST, { path, 'x.md' }, MATRIX)
  local expected = '"a\\"b\\\\c/d\\ne\\rf\\tg\\bh\\fi\\u0001j\\u001fk\127l\195\164.md"'
  T.ok(bytes:find(expected, 1, true), 'escapes')
  T.eq(assert(vrix.decode(bytes)).paths[1], path)
end)

T.case('the golden container decodes and encodes back to the same bytes', function()
  local bytes = ADAPTERS._from_hex(golden_hex())
  local d = assert(vrix.decode(bytes))
  T.eq(#d.paths, 20)
  T.eq(d.manifest.count, 20)
  T.eq(#d.stamps, 20, 'the golden container carries stamps')
  T.eq(vrix.encode(d.manifest, d.paths, d.matrix, d.stamps), bytes)
end)

T.case('encode: the key order is HEADER_KEYS whatever order the manifest was built in', function()
  local shuffled = {}
  local keys = vim.tbl_keys(MANIFEST)
  table.sort(keys, function(a, b)
    return a > b
  end)
  for _, k in ipairs(keys) do
    shuffled[k] = MANIFEST[k]
  end
  local a = vrix.encode(MANIFEST, { 'a.md', 'b.md' }, MATRIX)
  T.eq(vrix.encode(shuffled, { 'a.md', 'b.md' }, MATRIX), a)
  local len = a:byte(5) + a:byte(6) * 256
  local header = a:sub(9, 8 + len)
  local last = 0
  for _, k in ipairs(vrix.HEADER_KEYS) do
    local at = header:find('"' .. k .. '":', 1, true)
    if k ~= 'stamps' then
      T.ok(at and at > last, k .. ' in order')
      last = at
    end
  end
  T.ok(not header:find('stamps', 1, true), 'no stamps unless given')
end)

T.case('encode: schema_version is always 2; stamps only at the length of paths', function()
  local m = vim.tbl_extend('force', MANIFEST, { schema_version = 7 })
  local d = assert(vrix.decode(vrix.encode(m, { 'a.md', 'b.md' }, MATRIX)))
  T.eq(d.manifest.schema_version, 2)
  local stamps = { { 1760000000000, 120 }, { 1760000001000, 4096 } }
  d = assert(vrix.decode(vrix.encode(MANIFEST, { 'a.md', 'b.md' }, MATRIX, stamps)))
  T.eq(d.stamps, stamps)
  d = assert(vrix.decode(vrix.encode(MANIFEST, { 'a.md', 'b.md' }, MATRIX, { { 1, 2 } })))
  T.ok(d.stamps == nil)
  d = assert(vrix.decode(vrix.encode(MANIFEST, {}, '', {})))
  T.eq(d.stamps, {}, 'zero stamps for zero paths are the same length, as in the source')
end)

T.case('encode: an unknown key, a fraction or a foreign type raises', function()
  T.raises(function()
    vrix.encode(vim.tbl_extend('force', MANIFEST, { extra = 'x' }), { 'a', 'b' }, MATRIX)
  end, 'unknown manifest key')
  T.raises(function()
    vrix.encode(vim.tbl_extend('force', MANIFEST, { paths = { 'x' } }), { 'a', 'b' }, MATRIX)
  end, 'unknown manifest key')
  T.raises(function()
    vrix.encode(vim.tbl_extend('force', MANIFEST, { scale = 127.5 }), { 'a', 'b' }, MATRIX)
  end, 'integers')
  T.raises(function()
    vrix.encode(vim.tbl_extend('force', MANIFEST, { count = 0 / 0 }), { 'a', 'b' }, MATRIX)
  end, 'integers')
  T.raises(function()
    vrix.encode(vim.tbl_extend('force', MANIFEST, { vault = true }), { 'a', 'b' }, MATRIX)
  end, 'integers')
  T.raises(function()
    vrix.encode(MANIFEST, { 'a', 'b' }, MATRIX, { { 1.5, 2 }, { 3, 4 } })
  end, 'integers')
  T.raises(function()
    vrix.encode(MANIFEST, { 'a', 7 }, MATRIX)
  end, 'paths must be strings')
  T.raises(function()
    vrix.encode(MANIFEST, { 'a' }, { 1 })
  end, 'encode needs')
end)

T.case('encode: integers are written without exponent or sign of zero', function()
  local bytes = vrix.encode(
    vim.tbl_extend('force', MANIFEST, { count = 0 }),
    { 'a.md', 'b.md' },
    MATRIX,
    { { 1760000000000, -0 }, { 0, 4096 } }
  )
  T.ok(bytes:find('"count":0,', 1, true))
  T.ok(bytes:find('"stamps":[[1760000000000,0],[0,4096]]', 1, true))
end)

local function with_crc(body)
  return body
    .. string.char(unpack({
      vrix.crc32(body) % 256,
      math.floor(vrix.crc32(body) / 256) % 256,
      math.floor(vrix.crc32(body) / 65536) % 256,
      math.floor(vrix.crc32(body) / 16777216) % 256,
    }))
end

local function raw(header, matrix)
  local n = #header
  local len = string.char(n % 256, math.floor(n / 256) % 256, 0, 0)
  return with_crc('VRIX' .. len .. header .. (matrix or ''))
end

T.case('decode: checks in the order truncated, magic, truncated header, crc, header, schema', function()
  local good = vrix.encode(MANIFEST, { 'a.md', 'b.md' }, MATRIX)
  T.eq({ vrix.decode('') }, { nil, 'truncated' })
  T.eq({ vrix.decode('XXXX') }, { nil, 'truncated' }, 'short wins over magic')
  T.eq({ vrix.decode('XXXXabcdefgh') }, { nil, 'magic' })
  T.eq({ vrix.decode('VRIX\255\0\0\0abcd') }, { nil, 'truncated' }, 'header longer than the file')
  local flipped = good:sub(1, 20) .. string.char((good:byte(21) + 1) % 256) .. good:sub(22)
  T.eq({ vrix.decode(flipped) }, { nil, 'crc' })
  T.eq({ vrix.decode(raw('{nope')) }, { nil, 'header' })
  T.eq({ vrix.decode(raw('{"schema_version":3,"paths":[]}')) }, { nil, 'schema' })
  T.eq({ vrix.decode(raw('{"schema_version":2}')) }, { nil, 'header' }, 'no paths')
  T.raises(function()
    vrix.decode(nil)
  end, 'decode needs')
end)

T.case('decode: a header that is no object is "header", an empty object has no schema', function()
  for _, h in ipairs({ 'null', '42', '[]', '"x"', 'true', '[1,2]', '[{"schema_version":2}]' }) do
    T.eq({ vrix.decode(raw(h)) }, { nil, 'header' }, h)
  end
  T.eq({ vrix.decode(raw('{}')) }, { nil, 'schema' }, 'an empty object is an object')
  T.eq({ vrix.decode(raw('{"schema_version":2,"paths":{}}')) }, { nil, 'header' }, 'paths as {}')
  T.eq({ vrix.decode(raw('{"schema_version":2,"paths":["a",null]}')) }, { nil, 'header' }, 'null path')
end)

T.case('decode: unusable stamps are left out, not an error; null stamps are none', function()
  local function stamps_of(json)
    local d = assert(vrix.decode(raw('{"schema_version":2,"paths":["a","b"],"stamps":' .. json .. '}')))
    return d.stamps
  end
  T.eq(stamps_of('[[1,2],[3,4]]'), { { 1, 2 }, { 3, 4 } })
  T.eq(stamps_of('null'), nil)
  T.eq(stamps_of('[[1,2]]'), nil, 'wrong length')
  T.eq(stamps_of('[[1,2],[3,"x"]]'), nil, 'not a number')
  T.eq(stamps_of('[[1,2],[3,4,5]]'), nil, 'a triple')
  T.eq(stamps_of('[[1,2],null]'), nil, 'a null entry')
  T.eq(stamps_of('{"0":1}'), nil, 'an object')
  T.eq(stamps_of('[[1,2],{}]'), nil, 'an empty object as an entry')
end)

T.case(
  'decode: manifest has neither paths nor stamps; the matrix is the bytes between header and CRC',
  function()
    local d = assert(vrix.decode(vrix.encode(MANIFEST, { 'a.md', 'b.md' }, MATRIX, { { 1, 2 }, { 3, 4 } })))
    T.eq(d.manifest, MANIFEST)
    T.eq(d.matrix, MATRIX)
    T.ok(d.manifest.paths == nil and d.manifest.stamps == nil)
  end
)

T.case('round trip: random paths and matrices come back unchanged, with and without stamps', function()
  local paths, rows = {}, 50
  local parts = {}
  for i = 1, rows do
    paths[i] = ('n/%03d \195\188 %s.md'):format(i, string.char(1 + i % 120))
    for c = 1, 3 do
      parts[#parts + 1] = string.char((i * 37 + c * 11) % 256)
    end
  end
  local matrix = table.concat(parts)
  local m = vim.tbl_extend('force', MANIFEST, { count = rows })
  local stamps = {}
  for i = 1, rows do
    stamps[i] = { 1760000000000 + i, i * 10 }
  end
  for _, s in ipairs({ false, true }) do
    local bytes = vrix.encode(m, paths, matrix, s and stamps or nil)
    local d = assert(vrix.decode(bytes))
    T.eq(d.paths, paths)
    T.eq(d.matrix, matrix)
    T.eq(d.stamps, s and stamps or nil)
    T.eq(vrix.encode(d.manifest, d.paths, d.matrix, d.stamps), bytes)
  end
end)

T.case('crc32: 5 MB in well under a second where it matters (the size of a big vault index)', function()
  local mb = ('\1\2\3\4\5\6\7\8'):rep(131072 * 5)
  local t0 = vim.uv.hrtime()
  vrix.crc32(mb)
  local ms = (vim.uv.hrtime() - t0) / 1e6
  T.ok(ms < 2000, ('crc32 of 5 MB took %.0f ms'):format(ms))
end)

T.case('counter-check: a crc32 off by one fails every container the vectors decode', function()
  local _, failures = run(vim.tbl_extend('force', {}, ADAPTERS, {
    crc32 = function(hex)
      return (vrix.crc32(ADAPTERS._from_hex(hex)) + 1) % 4294967296
    end,
  }))
  T.eq(#failures, 6, 'every crc32 case')
end)

T.case(
  'counter-check: a decoder that repairs the CRC first fails "crc mismatch" and the damaged retriever',
  function()
    local real = ADAPTERS.decodeContainer
    local function repaired(hex)
      local bytes = ADAPTERS._from_hex(hex)
      local body = bytes:sub(1, #bytes - 4)
      return ADAPTERS._to_hex(with_crc(body))
    end
    local _, failures = run(vim.tbl_extend('force', {}, ADAPTERS, {
      decodeContainer = function(hex)
        return real(repaired(hex))
      end,
    }))
    T.eq(failed_names(failures), { 'crc mismatch' })
  end
)
