local T = require('nvim_kit.test')
local L = require('nvim_kit.linediff')

local function align(a, b, opts)
  return L.align(a, b, opts)
end

-- Lines of a short test text: 'abc' is { 'a', 'b', 'c' }.
local function chars(s)
  local out = {}
  for ch in s:gmatch('.') do
    out[#out + 1] = ch
  end
  return out
end

local function seq(prefix, n, from)
  local out = {}
  for i = 1, n do
    out[i] = prefix .. (from or 1) + i - 1
  end
  return out
end

-- Checks a result against its inputs: the lines of `a` that are not dropped, in order, are a common
-- subsequence of a and b, and the added runs put exactly the missing lines of b between them. Nothing
-- here repeats the algorithm; it only replays the result onto `b`.
local function replay(a, b, r)
  local is_dropped = {}
  for _, i in ipairs(r.dropped) do
    is_dropped[i] = true
  end
  local run_at = {}
  for _, run in ipairs(r.added) do
    run_at[run.at] = (run_at[run.at] or 0) + run.count
  end
  local pos, kept = 0, 0
  for i = 1, #a + 1 do
    pos = pos + (run_at[i] or 0)
    if i <= #a and not is_dropped[i] then
      pos = pos + 1
      kept = kept + 1
      if b[pos] ~= a[i] then
        return false, ('kept a[%d]=%s sits at b[%d]=%s'):format(i, tostring(a[i]), pos, tostring(b[pos]))
      end
    end
  end
  if pos ~= #b then
    return false, ('replay covers %d lines of b, b has %d'):format(pos, #b)
  end
  if kept ~= r.common then
    return false, ('kept %d lines, common says %d'):format(kept, r.common)
  end
  return true
end

-- The length of a longest common subsequence by the plain recursion over prefixes (memoised), a different
-- walk from the module's suffix table.
local function lcs_length(a, b)
  local memo = {}
  local function go(i, j)
    if i == 0 or j == 0 then
      return 0
    end
    local key = i * 1000 + j
    if memo[key] == nil then
      if a[i] == b[j] then
        memo[key] = go(i - 1, j - 1) + 1
      else
        memo[key] = math.max(go(i - 1, j), go(i, j - 1))
      end
    end
    return memo[key]
  end
  return go(#a, #b)
end

T.case('equal lists, and empty ones', function()
  T.eq(align({ 'a', 'b' }, { 'a', 'b' }), { prefix = 2, suffix = 0, common = 2, dropped = {}, added = {} })
  T.eq(align({}, {}), { prefix = 0, suffix = 0, common = 0, dropped = {}, added = {} })
  T.eq(
    align({}, { 'a' }),
    { prefix = 0, suffix = 0, common = 0, dropped = {}, added = { { at = 1, count = 1 } } }
  )
  T.eq(align({ 'a' }, {}), { prefix = 0, suffix = 0, common = 0, dropped = { 1 }, added = {} })
end)

T.case('one line changed: dropped, then added at the next line of a', function()
  T.eq(
    align(chars('aXc'), chars('abc')),
    { prefix = 1, suffix = 1, common = 2, dropped = { 2 }, added = { { at = 3, count = 1 } } }
  )
end)

T.case('a line only in a is dropped, a line only in b is added', function()
  -- inserted into a
  T.eq(
    align({ 'a', 'NEW', 'b', 'c', 'd' }, chars('abcd')),
    { prefix = 1, suffix = 3, common = 4, dropped = { 2 }, added = {} }
  )
  -- deleted from a
  T.eq(
    align(chars('acd'), chars('abcd')),
    { prefix = 1, suffix = 2, common = 3, dropped = {}, added = { { at = 2, count = 1 } } }
  )
  -- lines missing at the end: the run sits behind the last line of a
  T.eq(
    align(chars('a'), chars('abc')),
    { prefix = 1, suffix = 0, common = 1, dropped = {}, added = { { at = 2, count = 2 } } }
  )
  -- lines missing at the very start
  T.eq(
    align(chars('bc'), chars('abc')),
    { prefix = 0, suffix = 2, common = 2, dropped = {}, added = { { at = 1, count = 1 } } }
  )
end)

T.case('a moved line is dropped where it was and added where it belongs', function()
  T.eq(
    align(chars('bca'), chars('abc')),
    { prefix = 0, suffix = 0, common = 2, dropped = { 3 }, added = { { at = 1, count = 1 } } }
  )
end)

-- Rule: the common prefix is matched first, the suffix only over what the prefix left.
T.case('prefix before suffix: the suffix never overlaps the prefix', function()
  -- a suffix-first walk would take the last 'a' as the suffix and drop 'a', 'b'
  T.eq(
    align(chars('aba'), chars('a')),
    { prefix = 1, suffix = 0, common = 1, dropped = { 2, 3 }, added = {} }
  )
  T.eq(align(chars('aa'), chars('a')), { prefix = 1, suffix = 0, common = 1, dropped = { 2 }, added = {} })
  T.eq(
    align(chars('a'), chars('aa')),
    { prefix = 1, suffix = 0, common = 1, dropped = {}, added = { { at = 2, count = 1 } } }
  )
  T.eq(
    align(chars('abab'), chars('ab')),
    { prefix = 2, suffix = 0, common = 2, dropped = { 3, 4 }, added = {} }
  )
end)

T.case('the suffix is cut from what the prefix left, not from the whole', function()
  -- prefix 'x' (1), then the suffix 'z' (1); the middle is 'aa' against 'b'
  T.eq(
    align(chars('xaaz'), chars('xbz')),
    { prefix = 1, suffix = 1, common = 2, dropped = { 2, 3 }, added = { { at = 4, count = 1 } } }
  )
end)

-- Rule: on a tie, drop first, then add.
T.case('tie: a line of a is dropped before a line of b is added', function()
  T.eq(
    align(chars('aab'), chars('ca')),
    { prefix = 0, suffix = 0, common = 1, dropped = { 1, 3 }, added = { { at = 2, count = 1 } } }
  )
  -- the same tie at the start of the middle
  T.eq(
    align(chars('ab'), chars('ba')),
    { prefix = 0, suffix = 0, common = 1, dropped = { 1 }, added = { { at = 3, count = 1 } } }
  )
end)

T.case('a changed first line before an equal line', function()
  T.eq(
    align(chars('ab'), chars('bb')),
    { prefix = 0, suffix = 1, common = 1, dropped = { 1 }, added = { { at = 2, count = 1 } } }
  )
end)

T.case('an added run is one entry, not one per line', function()
  -- a run met while walking the table (not left over at its end), then a dropped line, then a leftover run
  T.eq(align(chars('cx'), chars('abcy')), {
    prefix = 0,
    suffix = 0,
    common = 1,
    dropped = { 2 },
    added = { { at = 1, count = 2 }, { at = 3, count = 1 } },
  })
  T.eq(
    align(chars('ae'), chars('abcde')),
    { prefix = 1, suffix = 1, common = 2, dropped = {}, added = { { at = 2, count = 3 } } }
  )
  -- two runs apart from each other
  T.eq(align(chars('ace'), chars('abcde')), {
    prefix = 1,
    suffix = 1,
    common = 3,
    dropped = {},
    added = { { at = 2, count = 1 }, { at = 3, count = 1 } },
  })
end)

-- Rule: past the cell limit there is no table; every middle line of a is dropped, then every middle line
-- of b is added. At exactly the limit the table is still built.
T.case('cell_limit: the middle is aligned at n*m == limit, dropped and added above it', function()
  local a, b = { 'p', 's' }, { 's', 'q', 'r' } -- middle 2 x 3 = 6 cells, one shared line
  T.eq(
    align(a, b, { cell_limit = 6 }),
    { prefix = 0, suffix = 0, common = 1, dropped = { 1 }, added = { { at = 3, count = 2 } } }
  )
  T.eq(
    align(a, b, { cell_limit = 5 }),
    { prefix = 0, suffix = 0, common = 0, dropped = { 1, 2 }, added = { { at = 3, count = 3 } } }
  )
  T.eq(align(a, b, { cell_limit = 7 }), align(a, b, { cell_limit = 6 }))
end)

T.case('cell_limit: prefix and suffix are kept when the middle is skipped', function()
  T.eq(
    align(chars('xpsz'), chars('xsqrz'), { cell_limit = 5 }),
    { prefix = 1, suffix = 1, common = 2, dropped = { 2, 3 }, added = { { at = 4, count = 3 } } }
  )
end)

T.case('cell_limit 0 still aligns when one side of the middle is empty', function()
  T.eq(align(chars('ab'), chars('abc'), { cell_limit = 0 }), align(chars('ab'), chars('abc')))
  T.eq(
    align(chars('ab'), chars('cd'), { cell_limit = 0 }),
    { prefix = 0, suffix = 0, common = 0, dropped = { 1, 2 }, added = { { at = 3, count = 2 } } }
  )
end)

-- The default limit is 250000 cells (500 x 500). One line of a against a long b reaches the limit exactly
-- without a table of any size, so the default is pinned to the cell, above and below.
T.case('the default limit is 250000: aligned at 250000 cells, dropped and added at 250001', function()
  T.eq(L.CELL_LIMIT, 250000)
  local function with_shared(n)
    local b = seq('b', n)
    b[math.floor(n / 2)] = 'shared'
    return b
  end
  local at_limit = align({ 'shared' }, with_shared(250000))
  T.eq(at_limit.common, 1)
  T.eq(at_limit.dropped, {})
  T.eq(at_limit.added, { { at = 1, count = 124999 }, { at = 2, count = 125000 } })
  local past = align({ 'shared' }, with_shared(250001))
  T.eq(past.common, 0)
  T.eq(past.dropped, { 1 })
  T.eq(past.added, { { at = 2, count = 250001 } })
end)

-- A run time case that reaches the expensive path: 500 x 500 lines that share no prefix and no suffix and
-- one line in the middle, so the table is really built (a skipped table would answer common = 0).
T.case('500 x 500 lines: the table is built, and it is quick', function()
  local a, b = seq('a', 500), seq('b', 500)
  a[250], b[100] = 'shared', 'shared'
  local t0 = vim.uv.hrtime()
  local r = align(a, b)
  local ms = (vim.uv.hrtime() - t0) / 1e6
  T.eq(r.prefix, 0)
  T.eq(r.suffix, 0)
  T.eq(r.common, 1, 'the expensive path was not reached')
  T.eq(#r.dropped, 499)
  T.ok(replay(a, b, r))
  T.ok(ms < 3000, ('500 x 500 took %.0f ms'):format(ms))
  -- one line more on one side: 500 x 501 > 250000, no table, nothing in common
  b[#b + 1] = 'b501'
  local over = align(a, b)
  T.eq(over.common, 0)
  T.eq(#over.dropped, 500)
  T.eq(over.added, { { at = 501, count = 501 } })
end)

T.case('the table path replays onto b and agrees with an independent LCS', function()
  math.randomseed(20261111)
  local letters = { 'a', 'b', 'c' }
  for _ = 1, 400 do
    local a, b = {}, {}
    for i = 1, math.random(0, 8) do
      a[i] = letters[math.random(#letters)]
    end
    for i = 1, math.random(0, 8) do
      b[i] = letters[math.random(#letters)]
    end
    local r = align(a, b)
    local ok, why = replay(a, b, r)
    T.ok(ok, ('a=%s b=%s: %s'):format(table.concat(a), table.concat(b), tostring(why)))
    T.eq(r.common, lcs_length(a, b), ('a=%s b=%s'):format(table.concat(a), table.concat(b)))
  end
end)

T.case('counter-check: replay and the LCS length reject a wrong result', function()
  local a, b = chars('abcab'), chars('cabab')
  local r = align(a, b)
  T.ok(replay(a, b, r))
  local bad_common = vim.deepcopy(r)
  bad_common.common = r.common + 1
  T.ok(not replay(a, b, bad_common), 'a wrong common must be rejected')
  local bad_dropped = vim.deepcopy(r)
  bad_dropped.dropped[1] = bad_dropped.dropped[1] % #a + 1
  T.ok(not replay(a, b, bad_dropped), 'a wrong dropped line must be rejected')
  local bad_added = vim.deepcopy(r)
  bad_added.added = {}
  T.ok(not replay(a, b, bad_added), 'a lost added run must be rejected')
  T.ok(lcs_length(a, b) ~= r.common + 1)
end)

T.case('the inputs are not changed, and the result does not alias them', function()
  local a, b = chars('xaaz'), chars('xbz')
  local a0, b0 = vim.deepcopy(a), vim.deepcopy(b)
  local r = align(a, b)
  T.eq(a, a0)
  T.eq(b, b0)
  r.dropped[1] = 99
  T.eq(align(a, b).dropped, { 2, 3 })
end)

T.case('wrong arguments raise before anything is computed', function()
  for _, bad in ipairs({ 'abc', 1, true }) do
    T.raises(function()
      align(bad, {})
    end, 'nvim-kit linediff')
    T.raises(function()
      align({}, bad)
    end, 'nvim-kit linediff')
  end
  T.raises(function()
    align({ 'a', 1 }, {})
  end, 'nvim-kit linediff')
  T.raises(function()
    align({}, { 'a', {} })
  end, 'nvim-kit linediff')
  for _, bad in ipairs({ -1, 'many', 0 / 0, true }) do
    T.raises(function()
      align({}, {}, { cell_limit = bad })
    end, 'cell_limit')
  end
  T.raises(function()
    align({}, {}, 'opts')
  end, 'nvim-kit linediff')
end)
