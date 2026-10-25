-- The cases of code-kit tests/live-indexer-stamps-snapshot.test.ts (tag 0.37.6), ported:
-- `stamps_snapshot` and `init(index, map)`. A reseeded indexer must not lose the stamps of the rows
-- nobody touched, and must not invent one for a row that never had it.
local T = require('nvim_kit.test')
local L = require('nvim_kit.live_indexer')
local G = require('nvim_kit.index_guard')
local vrix = require('nvim_kit.vrix')

local DIM = 256
local DIR = '_vaultrag'
local FILE = DIR .. '/' .. L.CONTAINER_FILE
local MODEL = 'qwen3-embedding:8b'

local function memory()
  local st = { written = {} }
  function st.exists(p)
    return st.written[p] ~= nil
  end
  function st.read(p)
    return st.written[p]
  end
  function st.write(p, bytes)
    st.written[p] = bytes
  end
  function st.mkdir() end
  return st
end

local function embedder(_, cb)
  local v = { 1 }
  for i = 2, DIM do
    v[i] = 0
  end
  cb({ v })
end

local function fresh(st)
  return L.new(st, DIR, embedder, MODEL)
end

local function upd(ix, path, content, stamp)
  local got, err
  ix:update(path, content, stamp, function(r, e)
    got, err = r, e
  end)
  if got == nil then
    error('update failed: ' .. tostring(err), 2)
  end
end

local function stamps_of(st)
  local d = vrix.decode(st.written[FILE])
  return d.paths, d.stamps
end

-- Three stamped notes, written to disk.
local function seeded(st)
  local old = fresh(st)
  old:mark_fresh()
  upd(old, 'a.md', '# A\nInhalt', { 100, 10 })
  upd(old, 'b.md', '# B\nInhalt', { 999, 99 })
  upd(old, 'c.md', '# C\nInhalt', { 300, 30 })
  T.ok(old:persist('reindex'))
  return old
end

local function sorted_pairs(map)
  local out = {}
  for k, v in pairs(map) do
    out[#out + 1] = { k, v }
  end
  table.sort(out, function(x, y)
    return x[1] < y[1]
  end)
  return out
end

T.case('reproduction: a reseed WITHOUT the snapshot loses every stamp but the touched row', function()
  local st = memory()
  local old = seeded(st)
  local nxt = fresh(st)
  nxt:init(old:build_index())
  upd(nxt, 'b.md', '# B\nneu', { 999, 99 })
  T.ok(nxt:persist('live'))
  local paths, stamps = stamps_of(st)
  T.eq(paths, { 'a.md', 'b.md', 'c.md' })
  T.eq(stamps, { { 0, 0 }, { 999, 99 }, { 0, 0 } })
end)

T.case('with the snapshot the stamps of the rows nobody touched stay', function()
  local st = memory()
  local old = seeded(st)
  local nxt = fresh(st)
  nxt:init(old:build_index(), old:stamps_snapshot())
  upd(nxt, 'b.md', '# B\nneu', { 999, 99 })
  T.ok(nxt:persist('live'))
  local paths, stamps = stamps_of(st)
  T.eq(paths, { 'a.md', 'b.md', 'c.md' })
  T.eq(stamps, { { 100, 10 }, { 999, 99 }, { 300, 30 } })
  T.eq(G.count_unstamped_rows(stamps), 0)
end)

T.case('an update after the reseed replaces the stamp of that row, and only that one', function()
  local st = memory()
  local old = seeded(st)
  local nxt = fresh(st)
  nxt:init(old:build_index(), old:stamps_snapshot())
  upd(nxt, 'a.md', '# A\nnoch einmal', { 555, 55 })
  T.eq(nxt:stamps_snapshot()['a.md'], { 555, 55 })
  T.eq(nxt:stamps_snapshot()['c.md'], { 300, 30 })
end)

T.case('a row the old indexer never stamped stays unstamped: no back-stamping', function()
  local st = memory()
  local old = fresh(st)
  old:mark_fresh()
  upd(old, 'a.md', '# A\nInhalt', { 100, 10 })
  upd(old, 'b.md', '# B\nInhalt')
  T.ok(old:persist('reindex'))
  local snapshot = old:stamps_snapshot()
  T.eq(sorted_pairs(snapshot), { { 'a.md', { 100, 10 } } })
  local nxt = fresh(st)
  nxt:init(old:build_index(), snapshot)
  T.eq(sorted_pairs(nxt:stamps_snapshot()), { { 'a.md', { 100, 10 } } })
  upd(nxt, 'a.md', '# A\nneu', { 100, 10 })
  T.ok(nxt:persist('live'))
  local _, stamps = stamps_of(st)
  T.eq(stamps, { { 100, 10 }, { 0, 0 } })
end)

T.case('stamps for paths the new index does not hold are dropped', function()
  local st = memory()
  local old = seeded(st)
  old:remove('b.md')
  local snapshot = old:stamps_snapshot()
  snapshot['zombie.md'] = { 1, 1 }
  local nxt = fresh(st)
  nxt:init(old:build_index(), snapshot)
  T.eq(sorted_pairs(nxt:stamps_snapshot()), { { 'a.md', { 100, 10 } }, { 'c.md', { 300, 30 } } })
end)

T.case('a map entry that is no stamp is skipped, the good ones stay', function()
  local st = memory()
  local old = seeded(st)
  local index = old:build_index()
  local bad = {
    { 1, 2, 3 },
    { 1 },
    {},
    { 0 / 0, 1 },
    { 1, 0 / 0 },
    { math.huge, 1 },
    { 1, -math.huge },
    { 1.5, 2 },
    { '1', '2' },
    { '1', 2 },
    { 1, '2' },
    { nil, 1 },
    { 1, vim.NIL },
    vim.NIL,
    5,
    'ab',
  }
  for i, b in ipairs(bad) do
    local nxt = fresh(st)
    nxt:init(index, { ['a.md'] = b, ['b.md'] = { 999, 99 } })
    T.eq(sorted_pairs(nxt:stamps_snapshot()), { { 'b.md', { 999, 99 } } }, 'bad entry #' .. i)
  end
end)

T.case('the snapshot is a copy: changing it, or the indexer later, does not reach the other side', function()
  local st = memory()
  local old = seeded(st)
  local snapshot = old:stamps_snapshot()
  snapshot['a.md'] = nil
  snapshot['b.md'][1] = -1
  T.eq(old:stamps_snapshot()['a.md'], { 100, 10 })
  T.eq(old:stamps_snapshot()['b.md'], { 999, 99 })
  local before = old:stamps_snapshot()
  upd(old, 'a.md', '# A\nneu', { 777, 7 })
  T.eq(before['a.md'], { 100, 10 })
end)

T.case('the new indexer does not share the pairs with the map it was given', function()
  local st = memory()
  local old = seeded(st)
  local given = old:stamps_snapshot()
  local nxt = fresh(st)
  nxt:init(old:build_index(), given)
  given['a.md'][1] = -1
  T.eq(nxt:stamps_snapshot()['a.md'], { 100, 10 })
end)

T.case('init clears the stamps of an earlier init: a map is the whole truth for the new index', function()
  local st = memory()
  local old = seeded(st)
  local nxt = fresh(st)
  nxt:init(old:build_index(), old:stamps_snapshot())
  nxt:init(old:build_index(), { ['c.md'] = { 300, 30 } })
  T.eq(sorted_pairs(nxt:stamps_snapshot()), { { 'c.md', { 300, 30 } } })
  nxt:init(old:build_index())
  T.eq(next(nxt:stamps_snapshot()), nil)
end)

T.case(
  'the list form is as before (parallel to the paths), and a list of the wrong length is still ignored',
  function()
    local st = memory()
    local old = seeded(st)
    local a = fresh(st)
    a:init(old:build_index(), { { 1, 1 }, { 2, 2 }, { 3, 3 } })
    T.eq(
      sorted_pairs(a:stamps_snapshot()),
      { { 'a.md', { 1, 1 } }, { 'b.md', { 2, 2 } }, { 'c.md', { 3, 3 } } }
    )
    local b = fresh(st)
    b:init(old:build_index(), { { 1, 1 } })
    T.eq(next(b:stamps_snapshot()), nil)
  end
)

T.case(
  'an indexer that was never stamped hands over an empty snapshot; an empty map equals no argument',
  function()
    local st = memory()
    local old = fresh(st)
    T.eq(next(old:stamps_snapshot()), nil)
    old:mark_fresh()
    upd(old, 'a.md', '# A\nInhalt')
    T.eq(next(old:stamps_snapshot()), nil)
    local nxt = fresh(st)
    nxt:init(old:build_index(), {})
    T.ok(nxt:persist('reindex'))
    local _, stamps = stamps_of(st)
    T.eq(stamps, nil)
  end
)

T.case('rename and remove move the snapshot with them', function()
  local st = memory()
  local old = seeded(st)
  old:rename('a.md', 'z.md')
  old:remove('c.md')
  T.eq(sorted_pairs(old:stamps_snapshot()), { { 'b.md', { 999, 99 } }, { 'z.md', { 100, 10 } } })
end)
