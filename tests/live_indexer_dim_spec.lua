-- The cases of code-kit tests/live-indexer-dim.test.ts (tag 0.31.1), ported: the dimension as an
-- option, `source_dim`, the dimension guard, and the golden index from vault-rag.
local T = require('nvim_kit.test')
local L = require('nvim_kit.live_indexer')
local V = require('nvim_kit.vectors')
local vrix = require('nvim_kit.vrix')
local D = require('nvim_kit.date')

local here = vim.fn.fnamemodify(debug.getinfo(1, 'S').source:sub(2), ':p:h')
local VECTORS = here .. '/conformance/code-kit/'
local ADAPTER = dofile(here .. '/adapters/vrix.lua')

local DIR = '_idx'
local FILE = DIR .. '/' .. L.CONTAINER_FILE

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

-- A model that returns `n` values per text, a different direction for every text.
local function model_with(n)
  return function(texts, cb)
    local out = {}
    for t, text in ipairs(texts) do
      local h = 7
      for _, b in ipairs({ text:byte(1, -1) }) do
        h = (h * 31 + b) % 997
      end
      local v = {}
      for i = 0, n - 1 do
        v[i + 1] = math.sin(h * 0.37 + i * 0.011) + 0.05
      end
      out[t] = v
    end
    cb(out)
  end
end

local CLOCK = function()
  return D.days_from_civil(2026, 10, 11) * 86400000 + 12 * 3600000
end

local function parsed(manifest, paths, matrix)
  local idx = V.parse(manifest, paths, matrix)
  idx.manifest = manifest
  return idx
end

local function manifest_of(dim, count, extra)
  return vim.tbl_extend('force', {
    schema_version = 1,
    embedding_model = 'm',
    index_dim = dim,
    scale = 127,
    count = count,
    granularity = 'note',
    quant = 'int8',
  }, extra or {})
end

local function upd(ix, path, content)
  local got, err
  ix:update(path, content, nil, function(r, e)
    got, err = r, e
  end)
  if got == nil then
    error('update failed: ' .. tostring(err), 2)
  end
  return got
end

local function header(st)
  return vrix.decode(st.written[FILE]).manifest
end

local function flat(idx)
  return V.values(idx)
end

local function refusal(fn)
  local ok, err = pcall(fn)
  T.ok(not ok, 'expected a refusal')
  return err
end

-- ── the dimension as an option ───────────────────────────────────────────────────────────────

T.case('the default is 256, what vault-rag always wrote', function()
  local st = memory()
  local ix = L.new(st, DIR, model_with(4096), 'm', { now = CLOCK })
  T.eq(L.DEFAULT_INDEX_DIM, 256)
  T.eq(ix.dim, 256)
  ix:mark_fresh()
  upd(ix, 'a.md', '# a\ntext')
  T.ok(ix:persist('live'))
  local d = vrix.decode(st.written[FILE])
  T.eq(d.manifest.index_dim, 256)
  T.eq(#d.matrix, 256)
end)

T.case('buildIndex has the same shape as the container', function()
  local ix = L.new(memory(), DIR, model_with(4096), 'm', { dim = 1024 })
  ix:mark_fresh()
  upd(ix, 'a.md', '# a\ntext')
  local idx = ix:build_index()
  T.eq(idx.dim, 1024)
  T.eq(#flat(idx), 1024)
end)

T.case('a dimension of 0, -1, 2.5 or NaN is refused when the indexer is made', function()
  for _, dim in ipairs({ 0, -1, 2.5, 0 / 0, math.huge, '256' }) do
    T.raises(function()
      L.new(memory(), DIR, model_with(4), 'm', { dim = dim })
    end, 'dim')
  end
end)

T.case('a model with fewer values than dim gives rows padded with zeros - as before, no error', function()
  local st = memory()
  local ix = L.new(st, DIR, model_with(100), 'm', { dim = 256, now = CLOCK })
  ix:mark_fresh()
  upd(ix, 'a.md', '# a\ntext')
  T.ok(ix:persist('live'))
  local d = vrix.decode(st.written[FILE])
  T.eq(#d.matrix, 256)
  local head, tail = false, true
  for i = 1, 256 do
    local b = d.matrix:byte(i)
    if i <= 100 and b ~= 0 then
      head = true
    elseif i > 100 and b ~= 0 then
      tail = false
    end
  end
  T.ok(head, 'the first 100 columns carry the vector')
  T.ok(tail, 'the rest is zero')
  T.eq(d.manifest.source_dim, 100)
end)

T.case('a model with more values than dim is cut to dim columns', function()
  -- (the second half of "a row cut at dim": the container has dim columns and unit rows)
  local st = memory()
  local ix = L.new(st, DIR, model_with(300), 'm', { dim = 64, now = CLOCK })
  ix:mark_fresh()
  upd(ix, 'a.md', '# a\ntext')
  T.ok(ix:persist('live'))
  local d = vrix.decode(st.written[FILE])
  T.eq(#d.matrix, 64)
  T.eq(d.manifest.source_dim, 300)
end)

-- ── source_dim ───────────────────────────────────────────────────────────────────────────────

local function old_index(source_dim, dim)
  dim = dim or 256
  local extra = { vault = '' }
  if source_dim ~= nil then
    extra.source_dim = source_dim
  end
  return parsed(manifest_of(dim, 1, extra), { 'old.md' }, string.rep('\1', dim))
end

T.case(
  'what the model returned wins over the manifest (an old index said 256 for a 4 096-value model)',
  function()
    local st = memory()
    local ix = L.new(st, DIR, model_with(4096), 'm', { now = CLOCK })
    ix:init(old_index(256))
    upd(ix, 'new.md', '# n\ntext')
    T.ok(ix:persist('live'))
    T.eq(header(st).source_dim, 4096)
  end
)

T.case(
  "without a vector seen the manifest's value is carried over (nothing was embedded, nothing is learned)",
  function()
    local st = memory()
    local ix = L.new(st, DIR, model_with(4096), 'm', { now = CLOCK })
    ix:init(old_index(4096))
    ix:remove('old.md')
    ix:rename('zz.md', 'yy.md')
    T.ok(ix:persist('reindex'))
    T.eq(header(st).source_dim, 4096)
  end
)

T.case('without either it is the index dimension', function()
  local st = memory()
  local ix = L.new(st, DIR, model_with(4), 'm', { now = CLOCK })
  ix:init(old_index(nil))
  T.ok(ix:persist('reindex'))
  T.eq(header(st).source_dim, 256)
end)

T.case('an empty or nonsensical source_dim in the manifest is not carried over', function()
  for _, bad in ipairs({ 0, -3, 0 / 0 }) do
    local st = memory()
    local ix = L.new(st, DIR, model_with(4), 'm')
    ix:init(old_index(bad))
    T.ok(ix:persist('reindex'))
    T.eq(header(st).source_dim, 256)
  end
end)

T.case('the first vector counts, later ones do not change it', function()
  local st = memory()
  local n = 300
  local ix = L.new(st, DIR, function(texts, cb)
    local out = {}
    for i = 1, #texts do
      local v = {}
      for c = 1, n do
        v[c] = 1
      end
      n = n + 1
      out[i] = v
    end
    cb(out)
  end, 'm')
  ix:mark_fresh()
  upd(ix, 'a.md', '# a\ntext')
  upd(ix, 'b.md', '# b\ntext')
  T.ok(ix:persist('live'))
  T.eq(header(st).source_dim, 300)
end)

-- ── the dimension guard ──────────────────────────────────────────────────────────────────────

local function disk_index(dim, count)
  count = count or 1
  local paths = {}
  for i = 1, count do
    paths[i] = 'd' .. (i - 1) .. '.md'
  end
  return vrix.encode(manifest_of(dim, count), paths, string.rep('\3', count * dim))
end

T.case(
  'init refuses an index with other columns than the indexer, with the kind the caller can read',
  function()
    local idx = parsed(manifest_of(256, 1), { 'a.md' }, string.rep('\0', 256))
    local ix = L.new(memory(), DIR, model_with(4), 'm', { dim = 1024 })
    local err = refusal(function()
      ix:init(idx)
    end)
    T.eq(err.kind, 'dim-mismatch')
    T.ok(err.message:find('256.*1024'), err.message)
    T.ok(tostring(err):find('dim-mismatch', 1, true))
    T.eq(ix:is_ready(), false)
    T.eq(ix:note_count(), 0)
  end
)

T.case('init takes an EMPTY index of another dimension (nothing to damage)', function()
  local idx = parsed(manifest_of(256, 0), {}, '')
  local ix = L.new(memory(), DIR, model_with(4), 'm', { dim = 1024 })
  ix:init(idx)
  T.eq(ix:is_ready(), true)
end)

T.case('live and heal refuse to write over a container of another dimension, and write nothing', function()
  for _, reason in ipairs({ 'live', 'heal' }) do
    local st = memory()
    st.written[FILE] = disk_index(256)
    local ix = L.new(st, DIR, model_with(4096), 'm', { dim = 1024 })
    ix:mark_fresh()
    upd(ix, 'a.md', '# a\ntext')
    local ok, err = ix:persist(reason)
    T.eq(ok, nil, reason)
    T.eq(err.kind, 'dim-mismatch', reason)
    T.ok(st.written[FILE] == disk_index(256), 'the container on disk changed')
    T.eq(st.writes, 0)
  end
end)

T.case('the same dimension on disk is no obstacle, in both sizes', function()
  for _, dim in ipairs({ 256, 1024 }) do
    local st = memory()
    st.written[FILE] = disk_index(dim, 1)
    local ix = L.new(st, DIR, model_with(4096), 'm', { dim = dim })
    ix:mark_fresh()
    upd(ix, 'a.md', '# a\ntext')
    upd(ix, 'd0.md', '# d\ntext')
    T.ok(ix:persist('live'))
  end
end)

T.case('check_model_against_disk says dim-mismatch for heal and nothing for reindex', function()
  local st = memory()
  st.written[FILE] = disk_index(256)
  local ix = L.new(st, DIR, model_with(4096), 'm', { dim = 1024 })
  local d = ix:check_model_against_disk('heal')
  T.eq(d.allowed, false)
  T.eq(d.kind, 'dim-mismatch')
  T.eq(ix:check_model_against_disk('reindex'), { allowed = true })
end)

T.case('the model check still comes first when both differ', function()
  local st = memory()
  st.written[FILE] = disk_index(256)
  local ix = L.new(st, DIR, model_with(4096), 'other-model', { dim = 1024 })
  local d = ix:check_model_against_disk('heal')
  T.eq(d.allowed, false)
  T.eq(d.kind, 'model-mismatch')
end)

-- ── the golden index from vault-rag ──────────────────────────────────────────────────────────

local function golden_case(file, name)
  local f = assert(io.open(VECTORS .. file, 'rb'))
  local vectors = vim.json.decode(f:read('*a'))
  f:close()
  for _, c in ipairs(vectors.cases) do
    if c.name == name then
      return c
    end
  end
  error('no case ' .. name .. ' in ' .. file)
end

-- The golden container: the case "golden" of the vector decodeContainer, the bytes vault-rag wrote.
local GOLDEN = ADAPTER._from_hex(golden_case('decodeContainer.json', 'golden').args[1])

local function loaded(opts)
  local st = memory()
  st.written[FILE] = GOLDEN
  local d = vrix.decode(GOLDEN)
  local idx = parsed(d.manifest, d.paths, d.matrix)
  local ix = L.new(st, DIR, model_with(4096), 'qwen3-embedding:8b', opts or { now = CLOCK })
  ix:init(idx, d.stamps)
  return st, ix
end

local function header_text(bytes)
  local len = bytes:byte(5) + bytes:byte(6) * 256 + bytes:byte(7) * 65536
  return bytes:sub(9, 8 + len)
end

T.case(
  'persisting the golden without a change: the matrix, paths, stamps and header keys come back; only built_at and the CRC differ',
  function()
    local st, ix = loaded()
    T.ok(ix:persist('live'))
    local before, after = vrix.decode(GOLDEN), vrix.decode(st.written[FILE])
    T.eq(after.paths, before.paths)
    T.eq(after.stamps, before.stamps)
    T.eq(after.manifest.built_at, '2026-10-11T12:00:00.000Z')
    local a, b = vim.deepcopy(after.manifest), vim.deepcopy(before.manifest)
    a.built_at, b.built_at = nil, nil
    T.eq(a, b)
    -- the key ORDER is in the header text: the same bytes but the clock
    local want = header_text(GOLDEN):gsub('"built_at":"[^"]*"', '"built_at":"2026-10-11T12:00:00.000Z"')
    T.ok(header_text(st.written[FILE]) == want, 'the header text differs from the golden one beyond built_at')
    -- dequantise, renormalise, requantise gives the very same int8 values
    T.ok(after.matrix == before.matrix, 'the matrix changed')
  end
)

T.case(
  "the bytes are those of the OLD vault-rag code: persist(live) of the golden under a frozen clock, sha256 measured with vault-rag's live_indexer.ts on 2026-10-11",
  function()
    local st, ix = loaded()
    T.ok(ix:persist('live'))
    T.eq(vim.fn.sha256(st.written[FILE]), '19a7b93adb3afa7a6bf42ffd3ce42ea65e02236b3aad7a893dc54cb70a8e314a')
  end
)

T.case('the indexer built from the golden answers related() like the old code did', function()
  local _, ix = loaded()
  local want = golden_case('containerRetrieve.json', 'Notes/Vector embeddings.md')
  T.eq(want.args[2].related, 'Notes/Vector embeddings.md')
  local o = want.args[2].opts
  local hits = V.related(
    ix:build_index(),
    'Notes/Vector embeddings.md',
    { k = o.k, min_sim = o.minSim, exclude = o.exclude }
  )
  local paths, wanted = {}, {}
  for i, h in ipairs(hits) do
    paths[i] = h.path
  end
  for i, h in ipairs(want.expected) do
    wanted[i] = h.path
  end
  T.eq(paths, {
    'Notes/Cosine similarity.md',
    'Notes/Integrator related.md',
    'Notes/Semantic search.md',
    'Notes/Retrieval augmented generation.md',
    'Notes/Chunking strategies.md',
  })
  T.eq(paths, wanted)
  for i, h in ipairs(hits) do
    T.ok(
      math.abs(h.score - want.expected[i].score) < 1e-6,
      ('score %d: %s vs %s'):format(i, h.score, want.expected[i].score)
    )
  end
end)

T.case('an indexer made for 1 024 columns refuses the golden at init', function()
  local d = vrix.decode(GOLDEN)
  local idx = parsed(d.manifest, d.paths, d.matrix)
  local ix = L.new(memory(), DIR, model_with(4096), 'qwen3-embedding:8b', { dim = 1024 })
  T.eq(
    refusal(function()
      ix:init(idx)
    end).kind,
    'dim-mismatch'
  )
end)

-- ===== commit b: cases that run a full reindex =====

local function read(p)
  return '# ' .. p .. '\ntext of ' .. p
end

local function reindex(ix, paths)
  local report, err
  ix:reindex_all(paths, read, nil, nil, function(r, e)
    report, err = r, e
  end)
  if report == nil then
    error('reindex_all failed: ' .. tostring(err), 2)
  end
  return report
end

local function row(idx, path)
  local r = idx.rows[path]
  local all = flat(idx)
  local out = {}
  for c = 1, idx.dim do
    out[c] = all[(r - 1) * idx.dim + c]
  end
  return out
end

-- (dim, source): qwen3-embedding:8b at 1 024 dimensions (Oneiron), vault-rag, a model that
-- returns exactly what the index keeps, and a smaller one
-- (the reindex_all half of this case is in the second part of this file)
local DIM_CASES = { { 1024, 4096 }, { 256, 4096 }, { 1024, 1024 }, { 256, 768 } }

T.case(
  'dim 1024/256 from a model with 4096/768 values: the container has that many columns, the rows are unit vectors, search finds the note',
  function()
    for _, c in ipairs(DIM_CASES) do
      local dim, source = c[1], c[2]
      local tag = ('dim %d, model %d'):format(dim, source)
      local st = memory()
      local ix = L.new(st, DIR, model_with(source), 'm', { dim = dim, now = CLOCK })
      ix:mark_fresh()
      local paths = { 'Lessons/a.md', 'Lessons/b.md', 'Lessons/c.md' }
      local rep = reindex(ix, paths)
      T.eq({ rep.added, rep.failed, rep.skipped_empty }, { 3, {}, {} }, tag)
      T.ok(ix:persist('reindex')) -- reindex_all keeps the result in memory (and writes checkpoints); the caller persists
      local d = vrix.decode(st.written[FILE])
      for k, v in pairs({
        index_dim = dim,
        scale = L.INT8_SCALE,
        count = 3,
        embedding_model = 'm',
        source_dim = source,
        built_at = '2026-10-11T12:00:00.000Z',
      }) do
        T.eq(d.manifest[k], v, tag .. ' ' .. k)
      end
      T.eq(#d.matrix, 3 * dim, tag)
      local index = V.parse(d.manifest, d.paths, d.matrix)
      T.eq(index.dim, dim, tag)
      for _, p in ipairs(paths) do
        local v = row(index, p)
        T.eq(#v, dim, tag)
        local sum = 0
        local beyond = false
        for i, x in ipairs(v) do
          sum = sum + x * x
          if i > 256 and x ~= 0 then
            beyond = true
          end
        end
        T.ok(math.abs(math.sqrt(sum) - 1) < 1e-4, tag .. ' norm ' .. math.sqrt(sum))
        -- the row really uses the columns beyond 256 when the model has them (a row cut at 256 and padded would not)
        if dim > 256 and source > 256 then
          T.ok(beyond, tag .. ' columns beyond 256 are empty')
        end
      end
      -- the stored row of a note is the best hit for the vector it was made from
      local q = row(ix:build_index(), 'Lessons/b.md')
      T.eq(V.search(index, q, { k = 1, min_sim = 0, exclude = {} })[1].path, 'Lessons/b.md', tag)
    end
  end
)

T.case(
  'reindex may replace a container of another dimension: the way from 256 to 1 024 is a full rebuild',
  function()
    local st = memory()
    st.written[FILE] = disk_index(256)
    local ix = L.new(st, DIR, model_with(4096), 'm', { dim = 1024, now = CLOCK })
    ix:mark_fresh()
    reindex(ix, { 'a.md', 'b.md' })
    T.ok(ix:persist('reindex'))
    local m = header(st)
    T.eq(m.index_dim, 1024)
    T.eq(m.count, 2)
  end
)

T.case(
  'a reindex does not write intermediate states over a container of another dimension (checkpoints ask first)',
  function()
    local st = memory()
    st.written[FILE] = disk_index(256)
    local ix = L.new(st, DIR, model_with(8), 'm', { dim = 1024, now = CLOCK })
    ix:mark_fresh()
    local paths = {}
    for i = 1, 300 do
      paths[i] = ('n%03d.md'):format(i)
    end
    reindex(ix, paths)
    T.eq(st.writes, 0) -- the dimension on disk differs: no checkpoint
    T.eq(ix:note_count(), 300)
  end
)
