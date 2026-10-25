local T = require('nvim_kit.test')
local C = require('nvim_kit.conformance')
local V = require('nvim_kit.vectors')
local here = vim.fn.fnamemodify(debug.getinfo(1, 'S').source:sub(2), ':p:h')
local VECTORS = here .. '/conformance/code-kit'
-- The vectors use code-kit's names and shapes; the adapters are the only translation.
local ADAPTERS = dofile(here .. '/adapters/vectors.lua')

local has_ffi = pcall(require, 'ffi')

-- name -> comparison; the float32 steps of toIndexVector and the integers of quantizeInt8 are exact,
-- the float64 sums of the rank and the renormalised rows agree to 1e-6 (the vector README).
local NAMES = {
  toIndexVector = nil,
  quantizeInt8 = nil,
  parseIndex = { tolerance = 1e-6 },
  retrieverSearch = { tolerance = 1e-6 },
  retrieverRelated = { tolerance = 1e-6 },
}
local ORDER = { 'toIndexVector', 'quantizeInt8', 'parseIndex', 'retrieverSearch', 'retrieverRelated' }

-- Runs body with the ffi backend on or off, and puts it back on, also when body raises.
local function with_ffi(on, body)
  V._use_ffi(on)
  local ok, err = pcall(body)
  V._use_ffi(true)
  if not ok then
    error(err, 0)
  end
end

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

local function with(name, wrap)
  local adapters = vim.tbl_extend('force', {}, ADAPTERS)
  adapters[name] = wrap(ADAPTERS[name])
  return adapters
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
  T.case('passes every code-kit vector (7 + 5 + 3 + 6 + 5 cases), ' .. label, function()
    local vectors = C.load_dir(VECTORS)
    T.eq(#vectors.toIndexVector.cases, 7)
    T.eq(#vectors.quantizeInt8.cases, 5)
    T.eq(#vectors.parseIndex.cases, 3)
    T.eq(#vectors.retrieverSearch.cases, 6)
    T.eq(#vectors.retrieverRelated.cases, 5)
    with_ffi(backend, function()
      local cases, failures = run(ADAPTERS)
      T.eq(cases, 26)
      T.eq(failures, {})
    end)
  end)
end

T.case('the spec restores the ffi setting after a failing body', function()
  V._use_ffi(true)
  T.raises(function()
    with_ffi(false, function()
      error('boom')
    end)
  end, 'boom')
  -- The restore is observable: a fresh index is built natively again where ffi exists.
  local idx = V.parse({ index_dim = 1, scale = 127, count = 1 }, { 'a' }, '\127')
  T.eq(idx.ffi, has_ffi)
end)

T.case('counter-check: a mean that skips the float32 rounding fails "float32 rounding"', function()
  -- Same arithmetic as to_index_vector, in doubles all the way: the vector pins the rounding.
  local _, failures = run(with('toIndexVector', function()
    return function(vecs, dim)
      local n = #vecs
      local d = math.min(dim, n > 0 and #vecs[1] or 0)
      local mean = {}
      for i = 1, d do
        mean[i] = 0
        for r = 1, n do
          mean[i] = mean[i] + vecs[r][i] / n
        end
      end
      local norm = 0
      for i = 1, d do
        norm = norm + mean[i] * mean[i]
      end
      norm = math.sqrt(norm)
      if norm == 0 then
        norm = 1
      end
      for i = 1, d do
        mean[i] = mean[i] / norm
      end
      return mean
    end
  end))
  T.ok(vim.tbl_contains(failed_names(failures), 'float32 rounding'))
end)

T.case(
  'counter-check: rounding halves to even instead of toward +inf fails "halves round toward +inf"',
  function()
    local _, failures = run(with('quantizeInt8', function()
      return function(vec, scale)
        local out = {}
        for i, v in ipairs(vec) do
          local y = v * scale
          local f = math.floor(y)
          local d = y - f
          local r = (d > 0.5 or (d == 0.5 and f % 2 == 1)) and f + 1 or f
          out[i] = math.max(-scale, math.min(scale, r))
        end
        return out
      end
    end))
    T.ok(vim.tbl_contains(failed_names(failures), 'halves round toward +inf'))
  end
)

T.case('counter-check: a tie broken against the row order fails "ties keep row order"', function()
  local _, failures = run(with('retrieverSearch', function(real)
    return function(...)
      local hits = real(...)
      table.sort(hits, function(a, b)
        if a.score ~= b.score then
          return a.score > b.score
        end
        return a.path > b.path
      end)
      return hits
    end
  end))
  T.ok(vim.tbl_contains(failed_names(failures), 'ties keep row order'))
end)

T.case('counter-check: without the skip, related answers with the note itself', function()
  local _, failures = run(with('retrieverRelated', function()
    return function(manifest, paths, matrix, path, o)
      local idx = assert(V.parse(manifest, paths, ADAPTERS._bytes(matrix)))
      local q = {}
      local r
      for i, p in ipairs(paths) do
        if p == path then
          r = i
        end
      end
      if not r then
        return {}
      end
      local values = V.values(idx)
      for c = 1, idx.dim do
        q[c] = values[(r - 1) * idx.dim + c]
      end
      return V.search(idx, q, { k = o.k, min_sim = o.minSim, exclude = o.exclude })
    end
  end))
  T.ok(vim.tbl_contains(failed_names(failures), 'skips the active row'))
end)

T.case('parse: a count that differs from the paths, or a matrix of the wrong length, is corrupt', function()
  with_ffi(true, function()
    local manifest = { index_dim = 3, scale = 127, count = 3 }
    local idx, err = V.parse(manifest, { 'a', 'b' }, ('\1'):rep(6))
    T.eq({ idx, err }, { nil, 'corrupt' })
    idx, err = V.parse({ index_dim = 3, scale = 127, count = 2 }, { 'a', 'b' }, ('\1'):rep(5))
    T.eq({ idx, err }, { nil, 'corrupt' })
    idx, err = V.parse({ index_dim = 3, scale = 127, count = 2 }, { 'a', 'b' }, ('\1'):rep(7))
    T.eq({ idx, err }, { nil, 'corrupt' })
    idx, err = V.parse({ index_dim = 3, scale = 127, count = 2 }, { 'a', 'b' }, ('\1'):rep(6))
    T.ok(idx and not err, 'control: the right sizes parse')
  end)
end)

T.case('parse: wrong argument types raise', function()
  T.raises(function()
    V.parse(nil, {}, '')
  end, 'parse needs')
  T.raises(function()
    V.parse({ index_dim = 1, scale = 127, count = 0 }, {}, { 1 })
  end, 'parse needs')
end)

T.case('parse: an empty index is valid and ranks nothing', function()
  for _, on in ipairs({ true, false }) do
    with_ffi(on, function()
      local idx = assert(V.parse({ index_dim = 2, scale = 127, count = 0 }, {}, ''))
      T.eq(V.values(idx), {})
      T.eq(V.search(idx, { 1, 0 }, { k = 5, min_sim = -1 }), {})
    end)
  end
end)

-- A little deterministic noise (no math.random: the cases must repeat).
local function noise(seed)
  local s = seed
  return function()
    s = (s * 1103515245 + 12345) % 2147483648
    return s / 2147483648
  end
end

T.case('fround: known float32 values, halves to even, subnormals, overflow, special values', function()
  for _, on in ipairs({ true, false }) do
    with_ffi(on, function()
      local f = V.fround
      T.eq(f(0.1), 0.10000000149011612)
      T.eq(f(16777217), 16777216, 'a tie between 2^24 and 2^24+2 goes to the even one')
      T.eq(f(16777219), 16777220, 'a tie goes to the even mantissa also upward')
      T.eq(f(1.5 * 2 ^ -149), 2 ^ -148, 'subnormal tie goes to even')
      T.eq(f(0.5 * 2 ^ -149), 0, 'half the smallest subnormal rounds to zero')
      T.eq(f(0.75 * 2 ^ -149), 2 ^ -149)
      T.eq(f(1e-46), 0)
      T.eq(f(3.4028234663852886e38), 3.4028234663852886e38, 'the largest float32 stays')
      T.eq(f(3.4028235677973366e38), math.huge, 'the tie above the largest float32 goes to even: infinity')
      T.eq(f(-1e39), -math.huge)
      T.eq(f(0), 0)
      T.ok(f(0 / 0) ~= f(0 / 0), 'NaN stays NaN')
      T.eq(f(math.huge), math.huge)
      T.eq(f(-0.1), -0.10000000149011612)
    end)
  end
end)

T.case('fround: the ffi-free rounding agrees with the ffi one on 20000 values of every magnitude', function()
  local rnd = noise(7)
  local values = {}
  for i = 1, 20000 do
    local mag = (rnd() - 0.5) * 80 -- exponents from 2^-40 to 2^40 and signs
    values[i] = (rnd() - 0.5) * 2 ^ mag
  end
  for _, e in ipairs({ -149, -140, -126, -125, -1, 0, 23, 24, 25, 127 }) do
    values[#values + 1] = 2 ^ e + 2 ^ (e - 24) -- a tie
    values[#values + 1] = 2 ^ e + 2 ^ (e - 24) * 3 -- the next tie, odd side
    values[#values + 1] = -(2 ^ e) * 1.00000005
  end
  local viaffi, plain = {}, {}
  with_ffi(true, function()
    for i, x in ipairs(values) do
      viaffi[i] = V.fround(x)
    end
  end)
  with_ffi(false, function()
    for i, x in ipairs(values) do
      plain[i] = V.fround(x)
    end
  end)
  if has_ffi then
    for i = 1, #values do
      if viaffi[i] ~= plain[i] then
        error(('fround differs for %.17g: ffi %.17g, plain %.17g'):format(values[i], viaffi[i], plain[i]))
      end
    end
  end
end)

local function random_rows(rnd, rows, dim)
  local out = {}
  for r = 1, rows do
    out[r] = {}
    for c = 1, dim do
      out[r][c] = (rnd() - 0.5) * 2
    end
  end
  return out
end

T.case('to_index_vector: both backends give the same bits on random input', function()
  local rows = random_rows(noise(11), 5, 37)
  local a, b
  with_ffi(true, function()
    a = V.to_index_vector(rows, 30)
  end)
  with_ffi(false, function()
    b = V.to_index_vector(rows, 30)
  end)
  T.eq(a, b)
  T.eq(#a, 30)
  local norm = 0
  for _, x in ipairs(a) do
    norm = norm + x * x
  end
  T.ok(math.abs(norm - 1) < 1e-6, 'a unit vector')
end)

T.case('to_index_vector: a source shorter than dim keeps its length, no vectors give {}', function()
  T.eq(#V.to_index_vector({ { 1, 2, 3 } }, 10), 3)
  T.eq(V.to_index_vector({}, 10), {})
  T.eq(V.to_index_vector({ { 0, 0 } }, 2), { 0, 0 })
end)

T.case('quantize_int8: NaN is zero, a bad scale raises, the scale defaults to 127', function()
  T.eq(V.quantize_int8({ 0 / 0, 1, -1 }), { 0, 127, -127 })
  T.eq(
    V.quantize_int8({ 0.49999999999999994 }, 1),
    { 0 },
    'just below one half rounds down (floor(y + 0.5) would not)'
  )
  for _, bad in ipairs({ 0, 128, 1.5, -3 }) do
    T.raises(function()
      V.quantize_int8({ 1 }, bad)
    end, 'scale')
  end
end)

local function matrix_of(rnd, rows, dim)
  local parts = {}
  for _ = 1, rows * dim do
    parts[#parts + 1] = string.char(math.floor(rnd() * 256))
  end
  return table.concat(parts)
end

T.case('parse: both backends give the same bits and the same ranking on a random matrix', function()
  local rnd = noise(3)
  local rows, dim = 40, 16
  local matrix = matrix_of(rnd, rows, dim)
  local paths = {}
  for i = 1, rows do
    paths[i] = ('n/%02d.md'):format(i)
  end
  local manifest = { index_dim = dim, scale = 127, count = rows }
  local query = random_rows(rnd, 1, dim)[1]
  local values, hits = {}, {}
  for _, on in ipairs({ true, false }) do
    with_ffi(on, function()
      local idx = assert(V.parse(manifest, paths, matrix))
      T.eq(idx.ffi, on and has_ffi)
      values[#values + 1] = V.values(idx)
      hits[#hits + 1] = V.search(idx, query, { k = 10, min_sim = -1 })
      hits[#hits + 1] = V.related(idx, paths[5], { k = 10, min_sim = -1 })
    end)
  end
  T.eq(values[1], values[2])
  T.eq(hits[1], hits[3])
  T.eq(hits[2], hits[4])
  T.eq(#hits[1], 10)
  T.eq(#hits[2], 10)
end)

T.case('search: k of zero gives {}, an exclude list is optional, bad opts raise', function()
  local idx = assert(V.parse({ index_dim = 2, scale = 127, count = 2 }, { 'a', 'b' }, '\127\0\0\127'))
  T.eq(V.search(idx, { 1, 0 }, { k = 0, min_sim = -1 }), {})
  T.eq(#V.search(idx, { 1, 0 }, { k = 5, min_sim = -1 }), 2)
  T.raises(function()
    V.search(idx, { 1, 0 }, { k = 5 })
  end, 'opts needs')
  T.raises(function()
    V.related(idx, 'a', nil)
  end, 'opts needs')
end)

T.case('search: many equal scores come back in row order', function()
  local rows = 60
  local matrix = ('\127\0'):rep(rows)
  local paths = {}
  for i = 1, rows do
    paths[i] = ('p%02d'):format(i)
  end
  local idx = assert(V.parse({ index_dim = 2, scale = 127, count = rows }, paths, matrix))
  local got = V.search(idx, { 1, 0 }, { k = rows, min_sim = 0.5 })
  T.eq(#got, rows)
  for i = 1, rows do
    T.eq(got[i].path, paths[i])
  end
end)

T.case('search: a query longer than dim uses its first dim values; exclude matches prefixes only', function()
  local idx =
    assert(V.parse({ index_dim = 2, scale = 127, count = 3 }, { 'books/x', 'b', 'bb' }, '\127\0\127\0\127\0'))
  T.eq(#V.search(idx, { 1, 0, 99 }, { k = 5, min_sim = 0 }), 3)
  local got = V.search(idx, { 1, 0 }, { k = 5, min_sim = 0, exclude = { 'b/', 'bb' } })
  T.eq({ got[1].path, got[2].path, #got }, { 'books/x', 'b', 2 }, 'a bare "b/" does not hit "books/"')
end)

T.case(
  'related: with a repeated path the last row is the query and every row of that path is skipped',
  function()
    -- rows: a=(1,0), b=(0,1), a=(0,1); the last "a" is the query (0,1), both "a" rows are skipped.
    local idx =
      assert(V.parse({ index_dim = 2, scale = 127, count = 3 }, { 'a', 'b', 'a' }, '\127\0\0\127\0\127'))
    local got = V.related(idx, 'a', { k = 5, min_sim = -1 })
    T.eq(#got, 1)
    T.eq(got[1].path, 'b')
    T.ok(
      math.abs(got[1].score - 1) < 1e-6,
      'b = (0,1) against the query (0,1), not against the first row (1,0)'
    )
  end
)
