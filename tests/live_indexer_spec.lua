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

-- ===== commit b: reindex_all, heal_missing, cancel, checkpoints, batching =====

-- A vector that depends on the CONTENT: where "old vs. new vector of one note" must be told apart.
local function content_embedder()
  return function(texts, cb)
    local h = 0
    for _, b in ipairs({ table.concat(texts):byte(1, -1) }) do
      h = (h * 31 + b) % (DIM - 1)
    end
    cb({ unit(h + 2) })
  end
end

-- One distinguishable vector PER TEXT, as a real model gives.
local function per_text_embedder()
  local state = { calls = 0 }
  state.fn = function(texts, cb)
    state.calls = state.calls + 1
    local out = {}
    for i, t in ipairs(texts) do
      local h = 0
      for _, b in ipairs({ t:byte(1, -1) }) do
        h = (h * 31 + b) % (DIM - 1)
      end
      out[i] = unit(h + 2)
    end
    cb(out)
  end
  return state.fn, state
end

local function row_of(d, name)
  for i, x in ipairs(d.paths) do
    if x == name then
      return i
    end
  end
end

local function names(n, fmt)
  local out = {}
  for i = 0, n - 1 do
    out[#out + 1] = (fmt or 'n%d.md'):format(i)
  end
  return out
end

local function reindex(ix, paths, read, progress, stamp_for)
  local report, err, calls = nil, nil, 0
  ix:reindex_all(paths, read, progress, stamp_for, function(r, e)
    calls = calls + 1
    report, err = r, e
  end)
  T.eq(calls, 1, 'reindex_all answered ' .. calls .. ' times')
  if report == nil then
    error('reindex_all failed: ' .. tostring(err), 2)
  end
  return report
end

local function heal(ix, missing, read, progress, stamp_for)
  local report, err
  ix:heal_missing(missing, read, progress, stamp_for, function(r, e)
    report, err = r, e
  end)
  if report == nil then
    error('heal_missing failed: ' .. tostring(err), 2)
  end
  return report
end

local function body(p)
  return '# ' .. p .. '\nInhalt'
end

local function long_body(p)
  return '# ' .. p .. '\nInhalt lang genug fuer einen Chunk'
end

-- ── reindex_all: cancel ──────────────────────────────────────────────────────────────────────
-- Measured 2026-09-05 in the source: a full reindex over 7 210 notes could not be stopped.

T.case('cancel stops between two groups instead of working through the whole list', function()
  local ix = new_ix()
  local read_paths = {}
  local report = reindex(ix, names(200), function(p)
    read_paths[#read_paths + 1] = p
    if #read_paths == 1 then
      ix:cancel_reindex()
    end
    return long_body(p)
  end)
  T.ok(#read_paths < 200, 'read ' .. #read_paths)
  T.eq(report.cancelled, true)
end)

T.case('after a cancel ALL notes are kept, not just the ones reached', function()
  -- THE data-loss case: `fresh` holds only the notes reached, and taking it as the stock would
  -- shrink the index from thousands to a handful.
  local ix = new_ix()
  local paths = names(200)
  reindex(ix, paths, long_body) -- make a full stock
  T.eq(ix:note_count(), 200)
  local n = 0
  reindex(ix, paths, function(p)
    n = n + 1
    if n == 3 then
      ix:cancel_reindex()
    end
    return '# ' .. p .. '\nGEAENDERTER Inhalt lang genug fuer einen Chunk'
  end)
  T.eq(ix:note_count(), 200)
  T.eq(#ix:build_index().paths, 200)
end)

T.case('a cancel writes the mix of recomputed rows and stock to disk', function()
  local st = memory()
  local ix = new_ix(st, nil, content_embedder())
  local paths = names(100)
  reindex(ix, paths, long_body)
  T.ok(ix:persist('reindex'))
  local before = decoded(st)
  local n = 0
  local report = reindex(ix, paths, function(p)
    n = n + 1
    if n == 1 then
      ix:cancel_reindex()
    end
    return '# ' .. p .. '\nGANZ ANDERER Inhalt'
  end)
  T.eq(report.cancelled, true)
  local after = decoded(st)
  T.eq(after.paths, before.paths) -- complete
  T.eq(after.manifest.count, 100)
  T.ok(after.matrix ~= before.matrix, 'the recomputed rows are on disk')
end)

T.case('cancelled is false when the run goes through', function()
  local ix = new_ix()
  T.eq(
    reindex(ix, { 'a.md' }, function()
      return '# a\nInhalt lang genug'
    end).cancelled,
    false
  )
end)

T.case('the wish to cancel is reset, so the next run goes through', function()
  -- The silent trap: a flag left standing would kill the NEXT run at once, without an error, with
  -- a report that looks like a result.
  local ix = new_ix()
  local paths = names(200)
  local n = 0
  reindex(ix, paths, function(p)
    n = n + 1
    if n == 3 then
      ix:cancel_reindex()
    end
    return long_body(p)
  end)
  local second = reindex(ix, paths, long_body)
  T.eq(second.cancelled, false)
  T.eq(ix:note_count(), 200)
end)

T.case('a wish to cancel with no run active evaporates', function()
  local ix = new_ix()
  ix:cancel_reindex()
  local report = reindex(ix, { 'a.md' }, function()
    return '# a\nInhalt lang genug'
  end)
  T.eq(report.cancelled, false)
  T.eq(ix:note_count(), 1)
end)

-- ── reindex_all ──────────────────────────────────────────────────────────────────────────────

T.case('indexes all given paths, and build_index holds exactly these', function()
  local ix = new_ix()
  reindex(ix, { 'a.md', 'b.md', 'c.md' }, body)
  T.eq(ix:note_count(), 3)
  T.eq(ix:build_index().paths, { 'a.md', 'b.md', 'c.md' })
end)

T.case('on_progress is called as (done, indexed, total): (1,1,N) to (N,N,N)', function()
  local ix = new_ix()
  local progress = {}
  reindex(ix, { 'x.md', 'y.md', 'z.md' }, body, function(done, indexed, total)
    progress[#progress + 1] = { done, indexed, total }
  end)
  T.eq(progress, { { 1, 1, 3 }, { 2, 2, 3 }, { 3, 3, 3 } })
end)

T.case(
  'reindex_all replaces the stock in memory only at the end - the previous one stays callable until then',
  function()
    -- This promise holds for the stock in MEMORY only: the search keeps getting the previous index
    -- instead of a drifting mix. On disk there are intermediate states.
    local ix = new_ix()
    local rows = {}
    for r = 1, 3 do
      rows[r] = string.rep('\0', r - 1) .. string.char(SCALE) .. string.rep('\0', DIM - r)
    end
    ix:init(parsed(manifest_of(3), { 'a.md', 'b.md', 'c.md' }, table.concat(rows)))
    T.eq(ix:note_count(), 3)
    local snapshot, first = {}, true
    reindex(ix, { 'neu1.md', 'neu2.md' }, function(p)
      if first then
        first = false
        snapshot = ix:build_index().paths -- mid-flight: the old index must still be visible
      end
      return body(p)
    end)
    T.eq(snapshot, { 'a.md', 'b.md', 'c.md' })
    T.eq(ix:build_index().paths, { 'neu1.md', 'neu2.md' })
  end
)

T.case('writes intermediate states during a long run, not only at the end', function()
  -- Until 0.28.0 the whole run hung on one persist at the end; two full reindexes over ~6 700
  -- notes died near the goal and lost 5 and 6 hours.
  local st = memory()
  local ix = new_ix(st)
  ix:mark_fresh()
  reindex(ix, names(600), body)
  -- 600 notes: states after 250 and 500 notes; the final persist belongs to the caller
  T.eq(st.writes, 2)
end)

T.case('the intermediate state on disk is COMPLETE and carries the rows already renewed', function()
  -- A state that lacks notes would be worse than none: at the next load it looks like a shrunken index.
  local N = 400
  local paths = {}
  for i = 0, N - 1 do
    paths[i + 1] = ('n%03d.md'):format(i)
  end
  local st = memory()
  local ix = new_ix(st, nil, (make_embedder(unit(2)))) -- what the embedder returns now
  local rows = {}
  for _ = 0, N - 1 do
    rows[#rows + 1] = string.char(SCALE) .. string.rep('\0', DIM - 1) -- all with the OLD vector
  end
  ix:init(parsed(manifest_of(N), paths, table.concat(rows)))
  -- in the middle of the run (after the state at 250) read the DISK, not the memory
  local disk
  reindex(ix, paths, function(p)
    if p == 'n300.md' and disk == nil and st.written[FILE] then
      local d = vrix.decode(st.written[FILE])
      local function row(name)
        for i, x in ipairs(d.paths) do
          if x == name then
            return i - 1
          end
        end
      end
      disk = {
        count = #d.paths,
        first_new = d.matrix:byte(row('n000.md') * DIM + 2) == SCALE,
        last_old = d.matrix:byte(row('n399.md') * DIM + 1) == SCALE,
      }
    end
    return body(p)
  end)
  T.ok(disk, 'nothing was on disk in the middle of the run')
  T.eq(disk.count, N) -- complete: no note drops out
  T.eq(disk.first_new, true) -- renewed: the first note carries the new vector
  T.eq(disk.last_old, true) -- not reached: the last one still carries the old
end)

T.case('with a CHANGED MODEL no intermediate states are written', function()
  -- An intermediate state mixes old and new vectors: harmless within one model, but two
  -- incommensurable vector spaces in one container otherwise.
  local st = memory()
  st.written[FILE] = container_bytes(10, 'ein-anderes-modell')
  local ix = new_ix(st)
  ix:mark_fresh()
  reindex(ix, names(600), body)
  T.eq(st.writes, 0)
  T.eq(ix:note_count(), 600) -- the run itself is untouched
end)

T.case('skips a note whose read fails, the others are indexed anyway', function()
  local ix = new_ix()
  local report = reindex(ix, { 'a.md', 'fehler.md', 'c.md' }, function(p)
    if p == 'fehler.md' then
      error('unlesbar')
    end
    return body(p)
  end)
  T.eq(ix:note_count(), 2)
  T.eq(ix:build_index().paths, { 'a.md', 'c.md' })
  T.eq(report.failed, { 'fehler.md' })
end)

T.case('a read that answers nil, err is a failed note too', function()
  local ix = new_ix()
  local report = reindex(ix, { 'a.md', 'weg.md' }, function(p)
    if p == 'weg.md' then
      return nil, 'ENOENT'
    end
    return body(p)
  end)
  T.eq(report.failed, { 'weg.md' })
  T.eq(report.added, 1)
end)

T.case('clears the old stock before re-indexing (a stale path is removed)', function()
  local ix = new_ix()
  ix:init(one_note_index('alt.md'))
  T.eq(ix:note_count(), 1)
  reindex(ix, { 'neu.md' }, body)
  T.eq(ix:note_count(), 1)
  T.eq(ix:build_index().paths, { 'neu.md' })
end)

-- Vault state from the END (2026-09-04): a full reindex maps the vault as it looks at the finish.

T.case('a note CREATED during the run survives the reindex', function()
  local ix = new_ix()
  ix:init(one_note_index('alt.md'))
  reindex(ix, { 'alt.md', 'zwei.md' }, function(p)
    -- a live event in the middle of the run: the note is not in the start snapshot
    if p == 'zwei.md' then
      upd(ix, 'waehrenddessen-neu.md', '# Neu\nangelegt waehrend des Laufs')
    end
    return body(p)
  end)
  T.ok(ix:build_index().rows['waehrenddessen-neu.md'])
end)

T.case('a note CHANGED during the run keeps its NEW vector, not the one read by the run', function()
  -- The silent case: the path is in the index, only the vector is stale; `diff_index_vs_vault` is
  -- set based and never sees it.
  local ix = new_ix(memory(), nil, content_embedder())
  ix:init(one_note_index('a.md'))
  local NEU = '# A\nNEUER INHALT'
  reindex(ix, { 'a.md', 'b.md' }, function(p)
    -- the run has read a.md; now the person changes it
    if p == 'b.md' then
      upd(ix, 'a.md', NEU)
    end
    return '# ' .. p .. '\nalter Inhalt'
  end)
  local reference = new_ix(memory(), nil, content_embedder())
  reference:mark_fresh()
  upd(reference, 'a.md', NEU)
  T.eq(row_values(ix:build_index(), 'a.md'), row_values(reference:build_index(), 'a.md'))
end)

T.case('a note DELETED during the run does not come back', function()
  local ix = new_ix()
  ix:init(one_note_index('a.md'))
  reindex(ix, { 'a.md', 'b.md' }, function(p)
    if p == 'b.md' then
      ix:remove('a.md')
    end
    return body(p)
  end)
  T.eq(ix:build_index().rows['a.md'], nil)
end)

T.case(
  'a live update in the checkpoint window is not lost (adapted: a write that lets a live update in)',
  function()
    -- Hole B: the checkpoint swapped the stock over an await and restored it in a `finally`; an
    -- update in exactly that window wrote into the map that was thrown away. The TS test holds the
    -- write with a promise; here the write itself runs the update, which is the same window.
    local st = memory()
    local real_write = st.write
    local ix
    local inside = false
    function st.write(p, bytes)
      if not inside then
        inside = true
        upd(ix, 'im-fenster.md', '# Fenster\nwaehrend des Checkpoint-Writes')
      end
      real_write(p, bytes)
    end
    ix = new_ix(st)
    ix:init(one_note_index('bestand.md'))
    -- measured at the first read AFTER the checkpoint: the window is closed, and the end of the run
    -- (`stock = fresh`) has not happened yet
    local in_memory_after_checkpoint
    reindex(ix, names(260, 'n%03d.md'), function(p)
      if st.writes > 0 and in_memory_after_checkpoint == nil then
        in_memory_after_checkpoint = ix:build_index().rows['im-fenster.md'] or false
      end
      return body(p)
    end)
    T.ok(in_memory_after_checkpoint ~= nil, 'nothing was measured after the checkpoint')
    T.ok(in_memory_after_checkpoint, 'the live update was lost in memory')
    T.ok(ix:build_index().rows['im-fenster.md'], 'the live update did not survive the run')
    -- and the intermediate state on disk carries it too (it came in before the write)
    T.ok(st.writes >= 1)
  end
)

T.case('the intermediate state on disk carries what came in live before it (added)', function()
  -- Otherwise the new notes would be missing on disk until the end of the run - and for good
  -- after a cancel.
  local st = memory()
  local ix = new_ix(st)
  ix:init(one_note_index('bestand.md'))
  local on_disk
  reindex(ix, names(300, 'n%03d.md'), function(p)
    if p == 'n010.md' then
      upd(ix, 'live-neu.md', '# Neu\nwaehrend des Laufs')
    end
    if p == 'n290.md' and st.written[FILE] then
      on_disk = vrix.decode(st.written[FILE]).paths
    end
    return body(p)
  end)
  T.ok(on_disk, 'no intermediate state on disk')
  T.ok(vim.tbl_contains(on_disk, 'live-neu.md'), 'the live note is missing from the intermediate state')
end)

T.case('COUNTER-CHECK: a note from before the run survives only if its path is in the snapshot', function()
  -- Holds the line the contract does NOT move: `reindex_all` stays a full replacement. A note that
  -- was in the index but is not in `paths` is rightly gone (it is no longer in the vault).
  local ix = new_ix()
  ix:mark_fresh()
  upd(ix, 'verwaist.md', '# Verwaist\nnicht mehr im Vault')
  T.ok(ix:build_index().rows['verwaist.md'])
  reindex(ix, { 'a.md' }, body)
  T.eq(ix:build_index().rows['verwaist.md'], nil)
end)

T.case('an empty note is skipped (no chunk: the stock stays empty)', function()
  local ix = new_ix()
  reindex(ix, { 'leer.md' }, function()
    return '---\ntitle: leer\n---\n   '
  end)
  T.eq(ix:note_count(), 0)
end)

-- ── heal_missing ─────────────────────────────────────────────────────────────────────────────

T.case('heal_missing keeps the existing vectors and adds only the missing', function()
  local ix = new_ix(memory(), 'm')
  ix:mark_fresh()
  upd(ix, 'a.md', '#A') -- present
  local contents = { ['b.md'] = '#B', ['c.md'] = '#C' }
  local report = heal(ix, { 'b.md', 'c.md' }, function(p)
    return contents[p]
  end)
  T.eq(report.added, 2)
  local idx = ix:build_index()
  T.eq(idx.count, 3)
  T.ok(idx.rows['a.md'] and idx.rows['b.md'] and idx.rows['c.md'])
end)

T.case('heal_missing skips unreadable files without stopping', function()
  local ix = new_ix(memory(), 'm')
  ix:mark_fresh()
  local report = heal(ix, { 'x.md', 'y.md' }, function(p)
    if p == 'x.md' then
      error('weg')
    end
    return '#Y'
  end)
  T.eq(report.added, 1)
  T.ok(ix:build_index().rows['y.md'])
end)

T.case('heal_missing reports progress', function()
  local ix = new_ix(memory(), 'm')
  ix:mark_fresh()
  local seen = {}
  heal(ix, { 'a.md', 'b.md' }, function()
    return '#X'
  end, function(d, i, t)
    seen[#seen + 1] = { d, i, t }
  end)
  T.eq(seen[#seen], { 2, 2, 2 })
end)

T.case('heal_missing classifies added / skipped empty / failed', function()
  local ix = new_ix(memory(), 'm')
  ix:mark_fresh()
  local contents = { ['voll.md'] = '# A\nInhalt', ['leer.md'] = '---\ntitle: leer\n---\n   ' }
  local report = heal(ix, { 'voll.md', 'leer.md', 'weg.md' }, function(p)
    if not contents[p] then
      error('weg')
    end
    return contents[p]
  end)
  T.eq(report.added, 1)
  T.eq(report.skipped_empty, { 'leer.md' })
  T.eq(report.failed, { 'weg.md' })
  T.eq(ix:build_index().paths, { 'voll.md' }) -- leer.md must NOT land in the index
end)

T.case(
  'heal_missing takes the stamps through stamp_for, and an embedding failure is a failed note',
  function()
    local st = memory()
    local calls = 0
    local ix = new_ix(st, nil, function(_, cb)
      calls = calls + 1
      if calls == 2 then
        cb(nil, 'HTTP 500')
      else
        cb({ unit(2) })
      end
    end)
    ix:mark_fresh()
    local report = heal(ix, { 'a.md', 'b.md', 'c.md' }, body, nil, function(p)
      return { 1000, #p }
    end)
    T.eq(report.failed, { 'b.md' })
    T.eq(report.added, 2)
    T.ok(ix:persist('heal'))
    T.eq(decoded(st).stamps, { { 1000, 4 }, { 1000, 4 } })
  end
)

-- ── classification, stamps with reindex ──────────────────────────────────────────────────────

T.case('reindex_all reports skipped_empty and failed like heal_missing', function()
  local ix = new_ix(memory(), 'm')
  ix:mark_fresh()
  local contents = { ['voll.md'] = '# A\nInhalt', ['leer.md'] = '---\ntitle: leer\n---\n' }
  local report = reindex(ix, { 'voll.md', 'leer.md', 'weg.md' }, function(p)
    if not contents[p] then
      error('weg')
    end
    return contents[p]
  end)
  T.eq(report.added, 1)
  T.eq(report.skipped_empty, { 'leer.md' })
  T.eq(report.failed, { 'weg.md' })
  T.eq(report.cancelled, false)
end)

T.case('reindex_all takes the stamps through the stamp_for callback', function()
  local st = memory()
  local ix = new_ix(st)
  ix:mark_fresh()
  reindex(ix, { 'a.md', 'b.md' }, body, nil, function(p)
    return p == 'a.md' and { 1000, 10 } or { 2000, 20 }
  end)
  T.ok(ix:persist('reindex'))
  T.eq(decoded(st).stamps, { { 1000, 10 }, { 2000, 20 } })
end)

T.case('a checkpoint stamps the rows already recomputed anew, not with the old state', function()
  -- The state mixes fresh and old vectors. Taking the stamps wholesale from the old stock would
  -- put the stamp of a row's PREVIOUS embedding on it - the vector/stamp mismatch the guard is
  -- built against.
  local st = memory()
  local ix = new_ix(st)
  local paths = names(260, 'n%03d.md')
  ix:mark_fresh()
  for _, p in ipairs(paths) do
    upd(ix, p, '# ' .. p .. '\nalt', { 1000, 10 }) -- old stock: every row stamped 1000
  end
  T.ok(ix:persist('reindex'))
  local writes_before = st.writes
  local checkpoint
  local real_write = st.write
  function st.write(p, bytes)
    if checkpoint == nil then
      checkpoint = bytes
    end
    real_write(p, bytes)
  end
  reindex(
    ix,
    paths,
    function(p)
      return '# ' .. p .. '\nneu'
    end,
    nil,
    function()
      return { 2000, 20 }
    end
  )
  T.eq(writes_before, 1)
  T.ok(checkpoint)
  local d = vrix.decode(checkpoint)
  T.ok(d.stamps)
  local function row(name)
    for i, x in ipairs(d.paths) do
      if x == name then
        return i
      end
    end
  end
  T.eq(d.stamps[row('n000.md')], { 2000, 20 }) -- recomputed: the NEW stamp
  T.eq(d.stamps[row('n259.md')], { 1000, 10 }) -- not reached: still the old one
end)

T.case('after a full reindex the written container carries the stamps', function()
  -- Measured 2026-09-05: a full reindex over 7 210 notes ran for ten hours and left a container
  -- WITHOUT stamps: a forgotten pass-through in persist.
  local st = memory()
  local ix = new_ix(st, nil, (per_text_embedder()))
  ix:mark_fresh()
  reindex(ix, { 'a.md', 'b.md', 'c.md' }, body, nil, function(p)
    return { p == 'a.md' and 1000 or 2000, 42 }
  end)
  T.ok(ix:persist('reindex'))
  local d = decoded(st)
  T.ok(d.stamps)
  T.eq(d.stamps[1], { 1000, 42 })
  T.eq(d.stamps[2], { 2000, 42 })
end)

T.case('a live persist keeps the stamps instead of deleting them from the container', function()
  local st = memory()
  local ix = new_ix(st, nil, (per_text_embedder()))
  ix:mark_fresh()
  reindex(ix, { 'a.md' }, body, nil, function()
    return { 1000, 10 }
  end)
  T.ok(ix:persist('reindex'))
  upd(ix, 'b.md', '# b\nneu', { 3000, 20 })
  T.ok(ix:persist('live'))
  local d = decoded(st)
  T.eq(d.stamps[1], { 1000, 10 })
  T.eq(d.stamps[2], { 3000, 20 })
end)

T.case('a note without a stamp does NOT discard the stamps of the others', function()
  -- The finding of 2026-09-05 that made ten hours of reindex worthless: the first gap dropped the
  -- whole field. `stamp_for` answers nil when a note vanishes between reading and stamping.
  local st = memory()
  local ix = new_ix(st, nil, (per_text_embedder()))
  ix:mark_fresh()
  reindex(ix, { 'a.md', 'verschwunden.md', 'c.md' }, body, nil, function(p)
    if p == 'verschwunden.md' then
      return nil
    end
    return { 1000, 10 }
  end)
  T.ok(ix:persist('reindex'))
  local d = decoded(st)
  T.eq(d.stamps[row_of(d, 'a.md')], { 1000, 10 })
  T.eq(d.stamps[row_of(d, 'c.md')], { 1000, 10 })
  T.eq(d.stamps[row_of(d, 'verschwunden.md')], { 0, 0 }) -- the gap carries the placeholder, not a neighbour's stamp
end)

-- ── bundling across note boundaries ──────────────────────────────────────────────────────────

T.case('the chunks of several notes go out in ONE embed call', function()
  -- `embed()` batches to 32 inside, but the reindex used to call it per note.
  local embedder, state = per_text_embedder()
  local ix = new_ix(memory(), nil, embedder)
  ix:mark_fresh()
  reindex(ix, names(10), function(p)
    return '# ' .. p .. '\nInhalt von ' .. p
  end)
  T.eq(state.calls, 1)
end)

T.case('bundled gives exactly the vectors of the single path', function()
  -- THE invariant of the change: the answer to a group call is split by chunk count. A shift by
  -- one would give every note its neighbour's vector - staircase-like, quiet, and certified by
  -- the CRC.
  local paths = names(12)
  local function text(p)
    return '# ' .. p .. '\nGanz eigener Inhalt fuer ' .. p
  end
  local bundled = new_ix(memory(), nil, (per_text_embedder()))
  bundled:mark_fresh()
  reindex(bundled, paths, text)
  local single = new_ix(memory(), nil, (per_text_embedder()))
  single:mark_fresh()
  for _, p in ipairs(paths) do
    upd(single, p, text(p))
  end
  local a, b = bundled:build_index(), single:build_index()
  for _, p in ipairs(paths) do
    T.eq(row_values(a, p), row_values(b, p), p)
  end
  -- and the vectors can be told apart at all - else the equality above proves nothing
  T.ok(not vim.deep_equal(row_values(a, 'n0.md'), row_values(a, 'n1.md')))
end)

T.case('a note whose embedding fails does not drag its group down', function()
  -- With one call per group a single error would report up to 32 notes as failed: the fallback to
  -- single processing keeps the old cut.
  local per_text = per_text_embedder()
  local ix = new_ix(memory(), nil, function(texts, cb)
    for _, t in ipairs(texts) do
      if t:find('kaputt', 1, true) then
        error('Embedding HTTP 500')
      end
    end
    per_text(texts, cb)
  end)
  ix:mark_fresh()
  local report = reindex(ix, { 'a.md', 'kaputt.md', 'c.md' }, function(p)
    return '# ' .. p .. '\nInhalt von ' .. p
  end)
  T.eq(report.failed, { 'kaputt.md' })
  T.eq(report.added, 2)
  T.ok(ix:build_index().rows['a.md'])
  T.ok(ix:build_index().rows['c.md'])
end)

T.case(
  'an answer with another number of vectors than chunks falls back to one call per note (added)',
  function()
    -- The seat belt of the group call: the length check. An endpoint that answers with fewer
    -- vectors than chunks must not shift the assignment.
    local per_text = per_text_embedder()
    local group_calls, single_calls = 0, 0
    local ix = new_ix(memory(), nil, function(texts, cb)
      if #texts > 1 then
        group_calls = group_calls + 1
        cb({ unit(2) }) -- one vector for many texts
      else
        single_calls = single_calls + 1
        per_text(texts, cb)
      end
    end)
    ix:mark_fresh()
    local paths = { 'a.md', 'b.md', 'c.md' }
    local report = reindex(ix, paths, function(p)
      return '# ' .. p .. '\nGanz eigener Inhalt fuer ' .. p
    end)
    T.eq(group_calls, 1)
    T.eq(single_calls, 3)
    T.eq(report.added, 3)
    T.eq(report.failed, {})
    local reference = new_ix(memory(), nil, (per_text_embedder()))
    reference:mark_fresh()
    for _, p in ipairs(paths) do
      upd(reference, p, '# ' .. p .. '\nGanz eigener Inhalt fuer ' .. p)
    end
    for _, p in ipairs(paths) do
      T.eq(row_values(ix:build_index(), p), row_values(reference:build_index(), p), p)
    end
  end
)

T.case('a group holds up to 32 chunks, and one note may cross the limit', function()
  local embedder, state = per_text_embedder()
  local seen = {}
  local ix = new_ix(memory(), nil, function(texts, cb)
    seen[#seen + 1] = #texts
    embedder(texts, cb)
  end)
  ix:mark_fresh()
  reindex(ix, names(70), body)
  T.eq(seen, { 32, 32, 6 })
  T.eq(state.calls, 3)
end)

-- ── a run with an embedder that answers later (added) ────────────────────────────────────────

T.case(
  'a full run with an embedder on the loop completes, and a cancel in flight stops at the next boundary',
  function()
    local embedder = per_text_embedder()
    local ix
    local in_flight = 0
    ix = new_ix(memory(), nil, function(texts, cb)
      in_flight = in_flight + 1
      if in_flight == 2 then
        ix:cancel_reindex() -- while this request is on its way: it finishes, the loop stops after it
      end
      vim.schedule(function()
        embedder(texts, cb)
      end)
    end)
    ix:mark_fresh()
    local paths = names(200)
    local report
    ix:reindex_all(paths, body, nil, nil, function(r)
      report = r
    end)
    T.eq(report, nil) -- the first request is on its way
    wait_for(function()
      return report ~= nil
    end)
    T.eq(report.cancelled, true)
    T.eq(in_flight, 2)
    T.eq(report.added, 64) -- two groups of 32, both finished
    T.eq(ix:note_count(), 64)

    local ix2 = new_ix(memory(), nil, function(texts, cb)
      vim.schedule(function()
        embedder(texts, cb)
      end)
    end)
    ix2:mark_fresh()
    local report2
    ix2:reindex_all(paths, body, nil, nil, function(r)
      report2 = r
    end)
    wait_for(function()
      return report2 ~= nil
    end)
    T.eq(report2.added, 200)
    T.eq(report2.cancelled, false)
  end
)

T.case(
  'an error inside the run (a stamp_for that is wrong) gives cb(nil, err) and clears the run state',
  function()
    local ix = new_ix()
    ix:mark_fresh()
    upd(ix, 'keep.md', '# keep\nInhalt')
    local got, err
    ix:reindex_all({ 'a.md' }, body, nil, function()
      return { 1.5, 2 }
    end, function(r, e)
      got, err = r, e
    end)
    T.eq(got, nil)
    T.ok(tostring(err):find('stamp', 1, true), tostring(err))
    T.eq(ix:note_count(), 1) -- the stock is untouched
    ix:cancel_reindex() -- no run is active: evaporates
    local report = reindex(ix, { 'a.md' }, body)
    T.eq(report.cancelled, false)
  end
)
