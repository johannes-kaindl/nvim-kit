-- The cases of code-kit tests/live-indexer.test.ts (tag 0.31.1), ported: an in-memory map as the
-- storage, fake embedders that answer at once, and a content-dependent one. A TS case that leans
-- on promises (a write that waits for the test) is adapted where it says so.
local T = require('nvim_kit.test')
local L = require('nvim_kit.live_indexer')
local V = require('nvim_kit.vectors')
local vrix = require('nvim_kit.vrix')
local G = require('nvim_kit.index_guard')
local D = require('nvim_kit.date')
local text_lib = require('nvim_kit.text')

local DIM = 256
local SCALE = 127
local DIR = '_vaultrag'
local FILE = DIR .. '/' .. L.CONTAINER_FILE
local MODEL = 'qwen3-embedding:8b'

-- In-memory storage; `writes` counts the calls of `write`.
local function memory()
  local st = { written = {}, writes = 0 }
  function st.exists(p)
    return st.written[p] ~= nil
  end
  function st.read(p)
    return st.written[p]
  end
  function st.write(p, bytes)
    st.writes = st.writes + 1
    st.written[p] = bytes
  end
  function st.mkdir() end
  return st
end

local function unit(index)
  local v = {}
  for i = 1, DIM do
    v[i] = 0
  end
  v[index] = 1
  return v
end

-- The embedder of the TS file: ONE vector for any number of texts. `state.calls` counts the calls.
local function make_embedder(vec)
  local state = { calls = 0 }
  local v = vec or unit(1)
  state.fn = function(_, cb)
    state.calls = state.calls + 1
    cb({ { unpack(v) } })
  end
  return state.fn, state
end

local function parsed(manifest, paths, matrix)
  local idx = V.parse(manifest, paths, matrix)
  idx.manifest = manifest
  return idx
end

local function manifest_of(count, model)
  return {
    schema_version = 1,
    embedding_model = model or MODEL,
    index_dim = DIM,
    scale = SCALE,
    count = count,
    granularity = 'note',
    quant = 'int8',
  }
end

local function empty_index()
  return parsed(manifest_of(0), {}, '')
end

local function one_note_index(path)
  return parsed(manifest_of(1), { path }, string.char(SCALE) .. string.rep('\0', DIM - 1))
end

-- A valid container with `count` notes: what another process or device could have written.
local function container_bytes(count, model)
  local paths = {}
  for i = 1, count do
    paths[i] = 'disk-note-' .. (i - 1) .. '.md'
  end
  return vrix.encode(manifest_of(count, model), paths, string.rep('\0', count * DIM))
end

local function flip_byte(bytes, pos)
  local b = bytes:byte(pos)
  return bytes:sub(1, pos - 1) .. string.char(require('bit').bxor(b, 0xff)) .. bytes:sub(pos + 1)
end

local function new_ix(st, model, embedder, opts)
  return L.new(st or memory(), DIR, embedder or (make_embedder()), model or MODEL, opts)
end

-- update, answered at once: the result, or raises with the error
local function upd(ix, path, content, stamp)
  local got, err, calls = nil, nil, 0
  ix:update(path, content, stamp, function(r, e)
    calls = calls + 1
    got, err = r, e
  end)
  T.eq(calls, 1, 'update answered ' .. calls .. ' times')
  if got == nil then
    error('update failed: ' .. tostring(err), 2)
  end
  return got
end

-- persist that must be refused: the refusal
local function refused(ix, reason)
  local ok, err = ix:persist(reason)
  T.ok(not ok, 'persist was not refused')
  return err
end

local function decoded(st)
  local d = vrix.decode(st.written[FILE])
  T.ok(d, 'no container written')
  return d
end

local function row_values(idx, path)
  local r = idx.rows[path]
  if not r then
    return nil
  end
  local all = V.values(idx)
  local out = {}
  for c = 1, idx.dim do
    out[c] = all[(r - 1) * idx.dim + c]
  end
  return out
end

-- ── LiveIndexer ──────────────────────────────────────────────────────────────────────────────

T.case('init fills the note vectors from the index', function()
  local ix = new_ix()
  ix:init(one_note_index('a.md'))
  local idx = ix:build_index()
  T.eq(idx.count, 1)
  T.eq(idx.rows['a.md'], 1)
end)

T.case('update adds a new note to the index', function()
  local ix = new_ix()
  ix:init(empty_index())
  upd(ix, 'notes/new.md', '# Heading\nInhalt')
  local idx = ix:build_index()
  T.eq(idx.count, 1)
  T.eq(idx.rows['notes/new.md'], 1)
end)

T.case('update overwrites an existing vector', function()
  local ix = new_ix()
  ix:init(one_note_index('a.md'))
  upd(ix, 'a.md', 'neuer Inhalt')
  T.eq(ix:build_index().count, 1)
end)

T.case('update with empty content removes the note', function()
  local ix = new_ix()
  ix:init(one_note_index('a.md'))
  upd(ix, 'a.md', '---\ntitle: x\n---\n   ') -- frontmatter only
  T.eq(ix:build_index().count, 0)
end)

T.case('remove takes the note out of the index', function()
  local ix = new_ix()
  ix:init(one_note_index('a.md'))
  ix:remove('a.md')
  T.eq(ix:build_index().count, 0)
end)

T.case('rename moves the path', function()
  local ix = new_ix()
  ix:init(one_note_index('old.md'))
  ix:rename('old.md', 'new.md')
  local idx = ix:build_index()
  T.eq(idx.rows['old.md'], nil)
  T.eq(idx.rows['new.md'], 1)
end)

T.case('persist writes exactly ONE file: index.bin, no triple any more', function()
  local st = memory()
  local ix = new_ix(st)
  ix:init(empty_index())
  upd(ix, 'a.md', 'Inhalt A')
  upd(ix, 'b.md', 'Inhalt B')
  T.ok(ix:persist('reindex'))
  T.ok(st.written[FILE])
  T.eq(st.writes, 1)
  T.eq(st.written[DIR .. '/notes.i8'], nil)
  T.eq(st.written[DIR .. '/paths.json'], nil)
  T.eq(st.written[DIR .. '/manifest.json'], nil)
end)

T.case('the persisted container round-trips: count, sorted paths, size of the matrix', function()
  local st = memory()
  local ix = new_ix(st)
  ix:init(empty_index())
  upd(ix, 'b.md', 'Inhalt B')
  upd(ix, 'a.md', 'Inhalt A')
  T.ok(ix:persist('reindex'))
  local d = decoded(st)
  T.eq(d.manifest.count, 2)
  T.eq(d.paths, { 'a.md', 'b.md' })
  T.eq(#d.matrix, 2 * DIM)
end)

T.case('persist writes the int8 format (quantisation)', function()
  local st = memory()
  local ix = new_ix(st)
  ix:init(empty_index())
  upd(ix, 'a.md', 'Inhalt')
  T.ok(ix:persist())
  local d = decoded(st)
  T.eq(#d.matrix, DIM) -- 1 note x 256 columns x 1 byte
  T.eq(d.matrix:byte(1), SCALE) -- first column 1.0 * 127
end)

T.case('build_index gives similar vectors for identical contents', function()
  local ix = new_ix(nil, nil, (make_embedder(unit(6))))
  ix:init(empty_index())
  upd(ix, 'a.md', 'x')
  upd(ix, 'b.md', 'x')
  local idx = ix:build_index()
  local a, b = row_values(idx, 'a.md'), row_values(idx, 'b.md')
  local dot = 0
  for i = 1, DIM do
    dot = dot + a[i] * b[i]
  end
  T.ok(dot > 0.99, 'dot ' .. dot)
end)

T.case('note_count is the number of known notes', function()
  local ix = new_ix()
  T.eq(ix:note_count(), 0)
  upd(ix, 'a.md', 'Hallo Welt das ist ein langer Text für einen Chunk')
  T.eq(ix:note_count(), 1)
  ix:remove('a.md')
  T.eq(ix:note_count(), 0)
end)

T.case('update tells "indexed" for a note with content and "empty" for one without chunks', function()
  local ix = new_ix(nil, 'm')
  ix:init(empty_index())
  T.eq(upd(ix, 'a.md', '# Inhalt'), 'indexed')
  T.eq(upd(ix, 'a.md', '---\ntitle: x\n---\n'), 'empty')
  T.eq(ix:note_count(), 0)
end)

-- ── persist guard ────────────────────────────────────────────────────────────────────────────

T.case('freshly made is NOT ready: a live persist is refused as not-ready', function()
  local ix = new_ix(nil, 'm')
  T.eq(refused(ix, 'live').kind, 'not-ready')
  T.eq(ix:is_ready(), false)
end)

T.case('mark_fresh makes it ready: an empty vault may build up (0 to 1)', function()
  local st = memory()
  local ix = new_ix(st, 'm')
  ix:mark_fresh()
  upd(ix, 'a.md', '# A')
  T.ok(ix:persist('live'))
  T.ok(st.written[FILE])
end)

T.case('no container on disk counts as 0: a fresh build is allowed', function()
  local st = memory()
  local ix = new_ix(st, 'm')
  ix:mark_fresh()
  upd(ix, 'a.md', '#A')
  T.ok(ix:persist('live'))
  T.ok(st.written[FILE])
end)

T.case("the container's count counts: a shrink from 100 to 1 is refused", function()
  local st = memory()
  st.written[FILE] = container_bytes(100)
  local ix = new_ix(st, 'm')
  ix:mark_fresh()
  upd(ix, 'a.md', '#A')
  T.eq(refused(ix, 'live').kind, 'shrink')
end)

T.case("a corrupt container is refused with kind 'unreadable'", function()
  local st = memory()
  st.written[FILE] = flip_byte(container_bytes(3), 11) -- one byte in the header: the CRC no longer fits
  local ix = new_ix(st, 'm')
  ix:mark_fresh()
  upd(ix, 'a.md', '#A')
  upd(ix, 'b.md', '#B')
  upd(ix, 'c.md', '#C')
  T.eq(refused(ix, 'live').kind, 'unreadable')
end)

T.case('a clobber by emptying the memory is stopped against the real disk state (3 to 0)', function()
  local st = memory()
  local ix = new_ix(st, 'm')
  ix:mark_fresh()
  upd(ix, 'a.md', '#A')
  upd(ix, 'b.md', '#B')
  upd(ix, 'c.md', '#C')
  T.ok(ix:persist('live')) -- disk state is now 3
  ix:remove('a.md')
  ix:remove('b.md')
  ix:remove('c.md')
  T.eq(refused(ix, 'live').kind, 'shrink')
end)

T.case('reason reindex may shrink', function()
  local ix = new_ix(nil, 'm')
  ix:mark_fresh()
  upd(ix, 'a.md', '#A')
  upd(ix, 'b.md', '#B')
  T.ok(ix:persist('live'))
  ix:remove('a.md')
  ix:remove('b.md')
  T.ok(ix:persist('reindex')) -- 2 to 0 allowed
end)

T.case('reason heal may shrink - which reasons the shrink guard decides on is index_guard alone', function()
  local ix = new_ix(nil, 'm')
  ix:mark_fresh()
  upd(ix, 'a.md', '#A')
  upd(ix, 'b.md', '#B')
  T.ok(ix:persist('live'))
  ix:remove('a.md')
  ix:remove('b.md')
  T.ok(ix:persist('heal')) -- 2 to 0 allowed
end)

T.case('after a successful persist the (now current) disk state allows a one-step deletion', function()
  local ix = new_ix(nil, 'm')
  ix:mark_fresh()
  upd(ix, 'a.md', '#A')
  upd(ix, 'b.md', '#B')
  T.ok(ix:persist('live'))
  ix:remove('b.md')
  T.ok(ix:persist('live')) -- 2 to 1 (-1) allowed
end)

T.case('mark_unready blocks a live persist in mid-session, also when the indexer was ready before', function()
  local ix = new_ix(nil, 'm')
  ix:mark_fresh()
  upd(ix, 'a.md', '#A')
  T.ok(ix:persist('live'))
  T.eq(ix:is_ready(), true)
  ix:mark_unready()
  T.eq(ix:is_ready(), false)
  T.eq(refused(ix, 'live').kind, 'not-ready')
end)

T.case('after mark_unready a new init restores the ready state', function()
  local ix = new_ix(nil, 'm')
  ix:mark_fresh()
  upd(ix, 'a.md', '#A')
  T.ok(ix:persist('live'))
  ix:mark_unready()
  T.eq(refused(ix, 'live').kind, 'not-ready')
  ix:init(one_note_index('a.md'))
  T.eq(ix:is_ready(), true)
  T.ok(ix:persist('live'))
end)

T.case(
  'sync race: mark_fresh (no manifest seen) and a big index that shows up on disk later blocks the live persist',
  function()
    local st = memory()
    st.written[FILE] = container_bytes(4700)
    local ix = new_ix(st, 'm')
    ix:mark_fresh()
    upd(ix, 'a.md', '#A')
    T.eq(refused(ix, 'live').kind, 'shrink')
    -- the real index on disk is untouched
    T.eq(decoded(st).manifest.count, 4700)
  end
)

T.case(
  "a container that is there but unreadable (a race with a foreign write) is refused with 'unreadable'",
  function()
    local st = memory()
    st.written[FILE] = 'das ist kein gültiger Container'
    local ix = new_ix(st, 'm')
    ix:mark_fresh()
    upd(ix, 'a.md', '#A')
    T.eq(refused(ix, 'live').kind, 'unreadable')
  end
)

-- ── persist guard: embedding model ───────────────────────────────────────────────────────────

-- An indexer whose model does NOT match the container on disk.
local function mismatched()
  local st = memory()
  st.written[FILE] = container_bytes(1, MODEL)
  local ix = new_ix(st, 'text-embedding-3-small')
  ix:mark_fresh()
  return st, ix
end

T.case('live is blocked by a foreign model on disk (kind model-mismatch)', function()
  local st, ix = mismatched()
  upd(ix, 'a.md', '#A')
  T.eq(refused(ix, 'live').kind, 'model-mismatch')
  T.eq(#st.written[FILE], #container_bytes(1)) -- the container on disk is untouched
end)

T.case('heal is blocked as well - additive mixing of foreign vectors', function()
  local _, ix = mismatched()
  upd(ix, 'a.md', '#A')
  T.eq(refused(ix, 'heal').kind, 'model-mismatch')
end)

T.case('reindex stays allowed - a full replacement is the documented way out', function()
  local st, ix = mismatched()
  upd(ix, 'a.md', '#A')
  T.ok(ix:persist('reindex'))
  T.ok(st.written[FILE])
end)

T.case('a matching model writes normally', function()
  local st = memory()
  st.written[FILE] = container_bytes(1, MODEL)
  local ix = new_ix(st)
  ix:mark_fresh()
  upd(ix, 'a.md', '#A')
  T.ok(ix:persist('live'))
end)

T.case('the disk truth beats the memory: init with a foreign manifest changes nothing', function()
  -- A poisoned manifest in memory must not change the guard's mind: it compares with the disk, always.
  local st = memory()
  st.written[FILE] = container_bytes(1, MODEL)
  local ix = new_ix(st, 'text-embedding-3-small')
  ix:init(parsed(manifest_of(1, 'text-embedding-3-small'), { 'a.md' }, string.rep('\0', DIM)))
  upd(ix, 'a.md', '#A')
  T.eq(refused(ix, 'live').kind, 'model-mismatch')
end)

T.case('a corrupt container with heal: no disk truth, the auto-heal cascade may write', function()
  local st = memory()
  st.written[FILE] = flip_byte(container_bytes(3, MODEL), 11)
  local ix = new_ix(st, 'text-embedding-3-small')
  ix:mark_fresh()
  upd(ix, 'a.md', '#A')
  T.ok(ix:persist('heal'))
end)

-- ── check_model_against_disk ─────────────────────────────────────────────────────────────────

T.case('check: a foreign model on disk is not allowed (model-mismatch), without changing anything', function()
  local st = memory()
  st.written[FILE] = container_bytes(1, MODEL)
  local ix = new_ix(st, 'text-embedding-3-small')
  ix:init(one_note_index('a.md'))
  local before = ix:note_count()
  local d = ix:check_model_against_disk('heal')
  T.eq(d.allowed, false)
  T.eq(d.kind, 'model-mismatch')
  -- a pure question, no mutation: the caller may stop afterwards
  T.eq(ix:note_count(), before)
  T.eq(st.writes, 0)
end)

T.case('check: a matching model is allowed', function()
  local st = memory()
  st.written[FILE] = container_bytes(1, MODEL)
  local ix = new_ix(st)
  ix:init(one_note_index('a.md'))
  T.eq(ix:check_model_against_disk('heal').allowed, true)
end)

T.case('check: no container on disk (a fresh install) is allowed', function()
  local ix = new_ix(memory(), 'text-embedding-3-small')
  ix:mark_fresh()
  T.eq(ix:check_model_against_disk('heal').allowed, true)
end)

T.case(
  "check: an unreadable container is not allowed ('unreadable'): no additive run without a disk truth",
  function()
    local st = memory()
    st.written[FILE] = flip_byte(container_bytes(3, MODEL), 11)
    local ix = new_ix(st)
    ix:init(one_note_index('a.md'))
    local d = ix:check_model_against_disk('heal')
    T.eq(d.allowed, false)
    T.eq(d.kind, 'unreadable')
  end
)

T.case('check: the disk truth beats the memory, init with a foreign manifest changes nothing', function()
  local st = memory()
  st.written[FILE] = container_bytes(1, MODEL)
  local ix = new_ix(st, 'text-embedding-3-small')
  ix:init(parsed(manifest_of(1, 'text-embedding-3-small'), { 'a.md' }, string.rep('\0', DIM)))
  local d = ix:check_model_against_disk('heal')
  T.eq(d.allowed, false)
  T.eq(d.kind, 'model-mismatch')
end)

T.case(
  "build_index always stamps THIS indexer's model into the manifest, also after init from a foreign index",
  function()
    -- Why a caller may assign `build_index()` only AFTER a successful persist: the result carries the
    -- indexer's model, not the loaded index's.
    local ix = new_ix(memory(), 'text-embedding-3-small')
    ix:init(one_note_index('a.md')) -- the index manifest says qwen3-embedding:8b
    T.eq(ix:build_index().manifest.embedding_model, 'text-embedding-3-small')
  end
)

T.case(
  'persist stamps a foreign model on request: where the vectors come from, not the active endpoint',
  function()
    local st = memory()
    local ix = new_ix(st, 'text-embedding-3-small')
    ix:init(one_note_index('a.md')) -- the backup's manifest says qwen3-embedding:8b
    T.ok(ix:persist('heal', 'qwen3-embedding:8b'))
    T.eq(decoded(st).manifest.embedding_model, 'qwen3-embedding:8b')
  end
)

T.case("persist without a stamp request stays with the indexer's model", function()
  local st = memory()
  local ix = new_ix(st, 'text-embedding-3-small')
  ix:init(one_note_index('a.md'))
  T.ok(ix:persist('reindex'))
  T.eq(decoded(st).manifest.embedding_model, 'text-embedding-3-small')
end)

T.case('persist invents no vault name when the loaded manifest carries none', function()
  local st = memory()
  local ix = new_ix(st)
  ix:init(one_note_index('a.md'))
  T.ok(ix:persist('reindex'))
  T.eq(decoded(st).manifest.vault, '')
end)

T.case("persist carries the loaded manifest's vault over", function()
  local st = memory()
  local ix = new_ix(st)
  local idx = one_note_index('a.md')
  idx.manifest = vim.tbl_extend('force', idx.manifest, { vault = 'Notes' })
  ix:init(idx)
  T.ok(ix:persist('reindex'))
  T.eq(decoded(st).manifest.vault, 'Notes')
end)

T.case('check: reindex is not even asked - a full replacement stays the way out', function()
  local st = memory()
  st.written[FILE] = container_bytes(1, MODEL)
  local ix = new_ix(st, 'text-embedding-3-small')
  ix:init(one_note_index('a.md'))
  T.eq(ix:check_model_against_disk('reindex').allowed, true)
end)

-- ── file stamps ──────────────────────────────────────────────────────────────────────────────

T.case('persist writes the stamps in the row order of the sorted paths', function()
  local st = memory()
  local ix = new_ix(st)
  ix:mark_fresh()
  upd(ix, 'b.md', '# B\nInhalt', { 2000, 20 })
  upd(ix, 'a.md', '# A\nInhalt', { 1000, 10 })
  T.ok(ix:persist('reindex'))
  local d = decoded(st)
  T.eq(d.paths, { 'a.md', 'b.md' }) -- persist sorts
  T.eq(d.stamps, { { 1000, 10 }, { 2000, 20 } }) -- the stamps move with them
end)

T.case('a note without a stamp gets the placeholder, the stamped ones keep their value', function()
  -- The guard must not take an unchecked row for unremarkable, and ONE gap must not cost the
  -- stamps of the whole run: the row is marked unchecked instead of missing.
  local st = memory()
  local ix = new_ix(st)
  ix:mark_fresh()
  upd(ix, 'a.md', '# A\nInhalt', { 1000, 10 })
  upd(ix, 'b.md', '# B\nInhalt') -- no stamp
  T.ok(ix:persist('reindex'))
  local d = decoded(st)
  T.ok(d.stamps)
  T.eq(d.stamps[1], { 1000, 10 })
  T.eq(d.stamps[2], { 0, 0 })
end)

T.case('without any stamp the field stays out of the container', function()
  local st = memory()
  local ix = new_ix(st)
  ix:mark_fresh()
  upd(ix, 'a.md', '# A\nInhalt')
  T.ok(ix:persist('reindex'))
  T.eq(decoded(st).stamps, nil)
end)

T.case('a deleted path takes its stamp with it (no corpse in the map)', function()
  local st = memory()
  local ix = new_ix(st)
  ix:mark_fresh()
  upd(ix, 'a.md', '# A\nInhalt', { 1000, 10 })
  upd(ix, 'b.md', '# B\nInhalt', { 2000, 20 })
  ix:remove('a.md')
  T.ok(ix:persist('reindex'))
  local d = decoded(st)
  T.eq(d.paths, { 'b.md' })
  T.eq(d.stamps, { { 2000, 20 } })
end)

T.case('rename carries the stamp over to the new path', function()
  local st = memory()
  local ix = new_ix(st)
  ix:mark_fresh()
  upd(ix, 'alt.md', '# A\nInhalt', { 1000, 10 })
  ix:rename('alt.md', 'neu.md')
  T.ok(ix:persist('reindex'))
  local d = decoded(st)
  T.eq(d.paths, { 'neu.md' })
  T.eq(d.stamps, { { 1000, 10 } })
end)

T.case('init takes the stamps over from the loaded index', function()
  -- Otherwise they are lost at the first live persist after a restart.
  local st = memory()
  local ix = new_ix(st)
  ix:init(one_note_index('a.md'), { { 1000, 10 } })
  upd(ix, 'b.md', '# B\nInhalt', { 2000, 20 })
  T.ok(ix:persist('reindex'))
  T.eq(decoded(st).stamps, { { 1000, 10 }, { 2000, 20 } })
end)

T.case(
  'the guard sees a stale row and not the placeholder row (index_guard on the written container)',
  function()
    -- The second half of "a gap costs not all stamps": the placeholder must neither raise a false
    -- alarm nor make the guard deaf.
    local stale = G.find_stale_vector_paths(
      { 'a.md', 'verschwunden.md', 'geaendert.md' },
      { { 1000, 10 }, { 0, 0 }, { 1000, 10 } },
      { ['a.md'] = { 1000, 10 }, ['verschwunden.md'] = { 7777, 99 }, ['geaendert.md'] = { 2000, 10 } }
    )
    T.eq(stale, { 'geaendert.md' })
  end
)

-- ── persist order, header, argument checks (added; the source relies on JavaScript's sort) ────

T.case('persist orders the paths by bytes, never by locale or case: Z, a, b, ä', function()
  local st = memory()
  local ix = new_ix(st)
  ix:mark_fresh()
  for _, p in ipairs({ 'b.md', 'a.md', 'Z.md', 'ä.md' }) do
    upd(ix, p, '# ' .. p .. '\nInhalt')
  end
  T.ok(ix:persist('reindex'))
  T.eq(decoded(st).paths, { 'Z.md', 'a.md', 'b.md', 'ä.md' })
  T.eq(ix:build_index().paths, { 'Z.md', 'a.md', 'b.md', 'ä.md' })
  -- the reference for a locale that collates: byte_less is the rule, the case-folded one differs
  local folded = { 'a.md', 'b.md', 'Z.md', 'ä.md' }
  table.sort(folded, function(x, y)
    return x:lower() < y:lower()
  end)
  T.ok(not vim.deep_equal(folded, { 'Z.md', 'a.md', 'b.md', 'ä.md' }))
  local sorted = { 'b.md', 'a.md', 'Z.md', 'ä.md' }
  table.sort(sorted, text_lib.byte_less)
  T.eq(sorted, { 'Z.md', 'a.md', 'b.md', 'ä.md' })
end)

local function ms_of(y, m, d, h)
  return D.days_from_civil(y, m, d) * 86400000 + h * 3600000
end

T.case('built_at is the clock as ISO 8601 with milliseconds and Z', function()
  local cases = {
    { 1, '1970-01-01T00:00:00.001Z' },
    { 951782400000 + 123, '2000-02-29T00:00:00.123Z' }, -- a leap day
    { ms_of(2026, 6, 11, 12) + 999, '2026-06-11T12:00:00.999Z' },
    { ms_of(2026, 10, 11, 23) + 0.7, '2026-10-11T23:00:00.000Z' }, -- a fraction of a millisecond is cut
  }
  for _, c in ipairs(cases) do
    local st = memory()
    local ix = new_ix(st, nil, nil, {
      now = function()
        return c[1]
      end,
    })
    ix:mark_fresh()
    T.ok(ix:persist('reindex'))
    T.eq(decoded(st).manifest.built_at, c[2])
  end
end)

T.case('the header keys come in the order of the format, and the stamps last', function()
  local st = memory()
  local ix = new_ix(st)
  ix:mark_fresh()
  upd(ix, 'a.md', '# A\nInhalt', { 1000, 10 })
  T.ok(ix:persist('reindex'))
  local bytes = st.written[FILE]
  local header = bytes:sub(9, 8 + bytes:byte(5) + bytes:byte(6) * 256)
  local at, last = 0, 0
  for _, key in ipairs(vrix.HEADER_KEYS) do
    local pos = header:find('"' .. key .. '":', 1, true)
    T.ok(pos and pos > last, key .. ' out of order')
    last = pos
    at = at + 1
  end
  T.eq(at, #vrix.HEADER_KEYS)
end)

T.case('a stamp that is no pair of whole numbers raises, and so does a dim that is none', function()
  local ix = new_ix()
  T.raises(function()
    ix:update('a.md', '# A', { 1.5, 10 }, function() end)
  end, 'stamp')
  T.raises(function()
    ix:update('a.md', '# A', { 1 }, function() end)
  end, 'stamp')
  T.raises(function()
    ix:update('a.md', '# A')
  end, 'callback')
  T.raises(function()
    ix:persist('sometimes')
  end, 'reason')
end)

T.case('fs_storage writes and reads a container on a real disk, with no temp file left', function()
  local dir = vim.fn.tempname()
  local ix = L.new(L.fs_storage(), dir, (make_embedder()), MODEL)
  ix:mark_fresh()
  upd(ix, 'a.md', '# A\nInhalt', { 1000, 10 })
  T.ok(ix:persist('live'))
  local path = dir .. '/' .. L.CONTAINER_FILE
  local f = io.open(path, 'rb')
  T.ok(f)
  local d = vrix.decode(f:read('*a'))
  f:close()
  T.eq(d.paths, { 'a.md' })
  T.eq(vim.fn.glob(dir .. '/.*tmp*', true, true), {})
  -- and a second indexer on the same disk sees it as the truth
  local other = L.new(L.fs_storage(), dir, (make_embedder()), 'other-model')
  other:mark_fresh()
  T.eq(other:check_model_against_disk('heal').kind, 'model-mismatch')
  vim.fn.delete(dir, 'rf')
end)

-- ── embedders that do not answer at once (added; the source awaits promises) ─────────────────

local function wait_for(pred)
  vim.wait(3000, pred, 2)
  T.ok(pred(), 'timed out')
end

T.case('an embedder that answers later (on the loop) completes update; a second answer is ignored', function()
  local answered = 0
  local ix = new_ix(memory(), nil, function(_, cb)
    vim.schedule(function()
      cb({ unit(2) })
      cb({ unit(3) }) -- ignored
    end)
  end)
  ix:mark_fresh()
  local result
  ix:update('a.md', '# A\nInhalt', nil, function(r)
    answered = answered + 1
    result = r
  end)
  T.eq(result, nil) -- nothing yet
  wait_for(function()
    return result ~= nil
  end)
  vim.wait(20)
  T.eq(result, 'indexed')
  T.eq(answered, 1)
  T.eq(row_values(ix:build_index(), 'a.md')[2], 1)
end)

T.case('an embedder that fails, answers nil or raises leaves the index as it was: cb(nil, err)', function()
  local modes = { 'error', 'nothing', 'raise', 'garbage' }
  for _, mode in ipairs(modes) do
    local ix = new_ix(memory(), nil, function(_, cb)
      if mode == 'error' then
        cb(nil, 'HTTP 500')
      elseif mode == 'nothing' then
        cb()
      elseif mode == 'garbage' then
        cb('not a list')
      else
        error('boom')
      end
    end)
    ix:init(one_note_index('a.md'))
    local got, err
    ix:update('a.md', '# A\nneu', nil, function(r, e)
      got, err = r, e
    end)
    T.eq(got, nil, mode)
    T.ok(err, mode)
    T.eq(ix:note_count(), 1, mode)
    T.eq(ix:build_index().rows['a.md'], 1, mode)
  end
end)
