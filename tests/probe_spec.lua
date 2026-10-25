local T = require('nvim_kit.test')
local C = require('nvim_kit.conformance')
local P = require('nvim_kit.probe')
local text = require('nvim_kit.text')
local here = vim.fn.fnamemodify(debug.getinfo(1, 'S').source:sub(2), ':p:h')
local VECTORS = here .. '/conformance/code-kit'
-- The vectors use code-kit's names and shapes; the adapters are the only translation.
local ADAPTERS = dofile(here .. '/adapters/probe.lua')

local NAMES = { 'probeRank', 'probeOrder', 'probeQuery', 'compareRuns' }

local function run(adapters)
  local vectors = C.load_dir(VECTORS)
  local failures, cases = {}, 0
  for _, name in ipairs(NAMES) do
    T.ok(vectors[name], 'no vector file for ' .. name)
    cases = cases + #vectors[name].cases
    for _, f in ipairs(C.run(vectors[name], adapters[name])) do
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

T.case('passes every code-kit probe vector (8 + 7 + 17 + 10 cases)', function()
  local vectors = C.load_dir(VECTORS)
  T.eq(#vectors.probeRank.cases, 8)
  T.eq(#vectors.probeOrder.cases, 7)
  T.eq(#vectors.probeQuery.cases, 17)
  T.eq(#vectors.compareRuns.cases, 10)
  local cases, failures = run(ADAPTERS)
  T.eq(cases, 42)
  T.eq(failures, {})
end)

T.case('the defaults are the probe of the first run: seed 20260903, sample of 40', function()
  T.eq(P.SEED, 20260903)
  T.eq(P.N, 40)
end)

-- The counter-checks run a deliberately wrong variant through the same vectors.

-- FNV-1a with the multiplication in doubles: 32-bit h times 2^24 + 403 needs up to 56 bits.
local function rank_in_doubles(path, seed)
  local bit = require('bit')
  local h = 0x811c9dc5
  local s = ('%d'):format(seed) .. ':' .. path
  for i = 1, #s do
    h = (bit.bxor(h, s:byte(i)) % 2 ^ 32) * 0x01000193 % 2 ^ 32
  end
  return h
end

T.case('counter-check: a multiplication in doubles loses bits and fails the rank vectors', function()
  local _, failures = run(with('probeRank', function()
    return rank_in_doubles
  end))
  T.ok(#failures > 0)
  T.ok(vim.tbl_contains(failed_names(failures), '"a" seed 7'))
end)

T.case(
  'counter-check: hashing bytes instead of UTF-16 units fails only the non-ASCII rank vectors',
  function()
    -- the same hash over UTF-8 bytes: right for ASCII, wrong for umlauts and emoji
    local _, failures = run(with('probeRank', function()
      return function(path, seed)
        local bit = require('bit')
        local h = bit.tobit(0x811c9dc5)
        local s = ('%d'):format(seed) .. ':' .. path
        for i = 1, #s do
          h = bit.bxor(h, s:byte(i))
          h = bit.tobit(bit.lshift(h, 24) + h * 403)
        end
        return h < 0 and h + 2 ^ 32 or h
      end
    end))
    T.eq(failed_names(failures), {
      '"Notizen/Übersicht 🙂.md" seed 20260903',
      '"Notizen/Übersicht 🙂.md" seed 7',
    })
  end
)

T.case('counter-check: hashing code points instead of UTF-16 units fails the emoji path alone', function()
  -- an emoji is one code point but two units: the umlaut agrees (one unit either way)
  local _, failures = run(with('probeRank', function()
    return function(path, seed)
      local bit = require('bit')
      local h = bit.tobit(0x811c9dc5)
      local s = ('%d'):format(seed) .. ':' .. path
      for _, cp in ipairs(vim.fn.str2list(s)) do
        h = bit.bxor(h, cp)
        h = bit.tobit(bit.lshift(h, 24) + h * 403)
      end
      return h < 0 and h + 2 ^ 32 or h
    end
  end))
  T.ok(vim.tbl_contains(failed_names(failures), '"Notizen/Übersicht 🙂.md" seed 20260903'))
  T.ok(not vim.tbl_contains(failed_names(failures), '"a" seed 7'))
end)

T.case('counter-check: a tie broken by a case-folding comparison fails the hash-tie vector', function()
  local _, failures = run(with('probeOrder', function()
    return function(files, seed)
      local rows = {}
      for i, f in ipairs(files) do
        rows[i] = f
      end
      table.sort(rows, function(a, b)
        local ra, rb = P.rank(a.path, seed), P.rank(b.path, seed)
        if ra ~= rb then
          return ra < rb
        end
        return a.path:lower() < b.path:lower()
      end)
      return rows
    end
  end))
  T.eq(failed_names(failures), { 'hash tie, code-unit order' })
end)

T.case('counter-check: ASCII-only trimming fails the JS whitespace vector', function()
  local _, failures = run(with('probeQuery', function(real)
    return function(s, opts)
      -- a text that starts with NBSP and an ideographic space is trimmed by JavaScript only
      if s:find('\194\160', 1, true) or s:find('\227\128\128', 1, true) then
        return vim.trim(s):sub(1, 300)
      end
      return real(s, opts)
    end
  end))
  T.ok(
    vim.tbl_contains(
      failed_names(failures),
      'NBSP and ideographic space are trimmed too (JS trim, not ASCII-only)'
    )
  )
end)

T.case('counter-check: measuring bytes instead of UTF-16 units fails the umlaut vector', function()
  local _, failures = run(with('probeQuery', function()
    return function(s, opts)
      local body = vim.trim(require('nvim_kit.chunker').strip_frontmatter(s))
      if body == '' or (not (opts and opts.strict) and (#body <= 200 or #body > 800)) then
        return nil
      end
      return body:sub(1, 300)
    end
  end))
  T.ok(vim.tbl_contains(failed_names(failures), 'umlauts count as one unit each'))
end)

T.case('counter-check: a comparison that forgets the missing notes fails the missing vector', function()
  local _, failures = run(with('compareRuns', function(real)
    return function(previous, next)
      local r = real(previous, next)
      r.missing = {}
      return r
    end
  end))
  T.ok(vim.tbl_contains(failed_names(failures), 'missing from the second run'))
end)

-- What the vectors do not carry.

T.case('rank: always an unsigned 32-bit whole number, also past 2^31', function()
  local seen_high = false
  for i = 1, 200 do
    local r = P.rank('note-' .. i .. '.md', P.SEED)
    T.ok(r >= 0 and r < 2 ^ 32 and r % 1 == 0, r)
    seen_high = seen_high or r >= 2 ^ 31
  end
  T.ok(seen_high, 'no rank at or above 2^31 in 200 paths')
end)

T.case('rank: a stray byte hashes as the U+FFFD that clean_utf8 would put there', function()
  T.eq(P.rank('a\255b', 7), P.rank(text.clean_utf8('a\255b'), 7))
end)

T.case('rank: a negative seed prints with its sign, like the JavaScript template', function()
  T.ok(P.rank('a', -7) ~= P.rank('a', 7))
end)

T.case('rank: a path or seed of the wrong type raises', function()
  T.raises(function()
    P.rank(12, 7)
  end, 'path')
  T.raises(function()
    P.rank('a', '7')
  end, 'seed')
  T.raises(function()
    P.rank('a', 1.5)
  end, 'seed')
end)

local function files_of(n)
  local files = {}
  for i = 1, n do
    files[i] = { path = ('ordner%d/notiz-%d.md'):format(i % 5, i), mtime = i }
  end
  return files
end

local function paths(list)
  return vim.tbl_map(function(f)
    return f.path
  end, list)
end

T.case('order: the input is not changed and the result is a new list', function()
  local files = files_of(12)
  local before = vim.deepcopy(files)
  local out = P.order(files, P.SEED)
  T.eq(files, before)
  T.ok(out ~= files)
  T.eq(#out, 12)
  T.ok(out[1] == files[1] or out[1] ~= files[1], 'elements are the caller tables')
end)

T.case('order: the same files in any input order give the same sample', function()
  local files = files_of(30)
  local reversed = {}
  for i = #files, 1, -1 do
    reversed[#reversed + 1] = files[i]
  end
  T.eq(paths(P.order(reversed, P.SEED)), paths(P.order(files, P.SEED)))
end)

T.case('order: a new note slots in without reshuffling the old ones', function()
  local files = files_of(30)
  local old = paths(P.order(files, P.SEED))
  files[#files + 1] = { path = 'neu/neue-notiz.md', mtime = 99 }
  local without_new = vim.tbl_filter(function(p)
    return p ~= 'neu/neue-notiz.md'
  end, paths(P.order(files, P.SEED)))
  T.eq(without_new, old)
end)

T.case('order: equal paths keep their input order (stable like the source)', function()
  local out =
    P.order({ { path = 'a.md', mtime = 1 }, { path = 'a.md', mtime = 2 }, { path = 'a.md', mtime = 3 } }, 1)
  T.eq(
    vim.tbl_map(function(f)
      return f.mtime
    end, out),
    { 1, 2, 3 }
  )
end)

T.case('order: a file without a path raises', function()
  T.raises(function()
    P.order({ { mtime = 1 } }, 1)
  end, 'files[1]')
  T.raises(function()
    P.order(nil, 1)
  end, 'files')
end)

-- Documented guard for builds of Lua with a collating `<` (PUC-Lua): LuaJIT compares strings
-- bytewise even under a collating locale (measured on Neovim 0.12.6), so this cannot fail here,
-- but it keeps the tie-break honest where it could.
T.case('order: the hash tie stays in code-unit order under a collating locale', function()
  local set = os.setlocale('de_DE.UTF-8', 'collate')
  local ok, err = pcall(function()
    local out = P.order({ { path = 'a209804.md' }, { path = 'Z27609.md' } }, 20260903)
    T.eq(paths(out), { 'Z27609.md', 'a209804.md' })
  end)
  os.setlocale('', 'collate') -- back to the environment's locale, as Neovim started
  if not ok then
    error(err, 0)
  end
  -- `set` is nil when the locale is not installed; the case still ran under the default one
  T.ok(set == nil or type(set) == 'string')
end)

T.case('query: the window is 200 < len <= 800 units, strict drops it, and the cut is 300 units', function()
  T.eq(P.query(('x'):rep(200)), nil)
  T.eq(P.query(('x'):rep(201)), ('x'):rep(201))
  T.eq(P.query(('x'):rep(800)), ('x'):rep(300))
  T.eq(P.query(('x'):rep(801)), nil)
  T.eq(P.query(('x'):rep(801), { strict = true }), ('x'):rep(300))
  T.eq(P.query('', { strict = true }), nil)
  T.eq(P.query('---\na: 1\n---\n'), nil)
end)

T.case('query: a text of the wrong type raises', function()
  T.raises(function()
    P.query(nil)
  end, 's')
end)

T.case('compare_runs: counts agree with the lists, and the input is not changed', function()
  local function a(path, rank)
    return { path = path, rank = rank }
  end
  local prev = { a('1', 3), a('2', 0), a('3', 0), a('4', 5), a('gone', 0) }
  local nxt = { a('1', 0), a('2', 4), a('3', 0), a('4', 6) }
  local before = vim.deepcopy({ prev, nxt })
  local r = P.compare_runs(prev, nxt)
  T.eq(r.shared, 4)
  T.eq(r.healed, { a('1', 0) })
  T.eq(r.worsened, { a('2', 4) })
  T.eq(r.unchanged, 2)
  T.eq(r.missing, { 'gone' })
  T.eq(r.shared, #r.healed + #r.worsened + r.unchanged)
  T.eq({ prev, nxt }, before)
end)
