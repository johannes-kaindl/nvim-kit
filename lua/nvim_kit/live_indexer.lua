-- The live indexer: one vector per note in memory, kept current note by note (`update`, `remove`,
-- `rename`), rebuilt all at once (`reindex_all`) or only where it is missing (`heal_missing`), and
-- written as one VRIX container with the guards of `index_guard` in front of every write. A
-- behavioural port of code-kit `live-indexer.ts` (tag 0.31.1, from vault-rag's `LiveIndexer`):
-- the same steps in the same order, so what it writes is byte for byte what vault-rag writes.
--
-- Everything outside is injected: the file store (`storage`), the embedding source (`embedder`)
-- and the way a note is read (`read`); there is no I/O in here besides them. The embedder is
-- asynchronous, by callback: `embedder(texts, cb)` with `cb(vectors)` (one list of numbers per
-- text) or `cb(nil, err)`. Call `cb` from the main loop: the indexer carries on right there and
-- then reads, decodes and writes files. A long run does not block Neovim: between two embedder
-- calls the indexer only does cheap work, and the next call waits for its answer. An embedder
-- that answers at once (a test double) works as well, with no recursion.
--
-- `dim` is the number of columns of the index (default 256, what vault-rag always wrote). An
-- index on disk with other columns is refused like one built with another model. `source_dim` in
-- the header is the length of the vectors the model returned before they were cut to `dim`: the
-- first one this indexer saw, else the value of the manifest it was initialised from, else `dim`.
--
-- Differences from the source, all of them about Lua and none about the bytes: results come by
-- callback or as `nil, err` instead of promises and exceptions; `read` is synchronous
-- (`read(path) -> text` or `nil, err`); numbers in the header are integers (`vrix.encode` raises
-- on a fraction, so a stamp or a `source_dim` that is no whole number is refused, not rounded);
-- a refusal text is English and no contract, the caller words its notice from `kind`.
local M = {}

-- Relative requires: a vendored copy loads its siblings under the plugin's namespace.
local base = (...):gsub('live_indexer$', '')
local chunker = require(base .. 'chunker')
local vectors = require(base .. 'vectors')
local vrix = require(base .. 'vrix')
local guard = require(base .. 'index_guard')
local text_lib = require(base .. 'text')
local date = require(base .. 'date')
local store = require(base .. 'store')

local has_ffi, ffi = pcall(require, 'ffi')

local floor = math.floor

--- What vault-rag always used.
M.DEFAULT_INDEX_DIM = 256
--- Notes between two intermediate states of a full reindex: small enough that an abort costs
--- little, large enough that writing the container does not dominate the run.
M.CHECKPOINT_EVERY = 250
--- Chunks per embedding request in a full reindex.
M.EMBED_BATCH = 32
--- int8 quantisation of a unit vector: +-1 is +-127. Part of the format; the reader takes `scale`
--- from the manifest.
M.INT8_SCALE = 127
--- The one file of an index, in the index directory.
M.CONTAINER_FILE = 'index.bin'

local REASONS = { live = true, reindex = true, heal = true }

local Ix = {}
Ix.__index = Ix

local function whole(v, min)
  return type(v) == 'number' and v == floor(v) and v >= min and v < math.huge
end

local function blocked(kind, message)
  return { kind = kind, message = message }
end

-- t[from..to] as a new list (`unpack` would put them all on the stack).
local function slice(t, from, to)
  local out = {}
  for i = from, to do
    out[#out + 1] = t[i]
  end
  return out
end

local function count_keys(t)
  local n = 0
  for _ in pairs(t) do
    n = n + 1
  end
  return n
end

-- The keys of a map sorted by bytes, never by the locale.
local function sorted_keys(t)
  local keys = {}
  for k in pairs(t) do
    keys[#keys + 1] = k
  end
  table.sort(keys, text_lib.byte_less)
  return keys
end

-- A stamp is { mtime, size }, two whole numbers (the header holds integers only).
local function check_stamp(stamp, fn)
  if stamp ~= nil then
    if type(stamp) ~= 'table' or not whole(stamp[1], -2 ^ 53) or not whole(stamp[2], -2 ^ 53) then
      error(('nvim-kit live_indexer: %s: a stamp is { mtime, size }, two whole numbers'):format(fn), 3)
    end
  end
end

-- Milliseconds since the epoch as JavaScript's `toISOString` writes them.
local function iso8601(ms)
  ms = floor(ms)
  local secs = floor(ms / 1000)
  local msec = ms - secs * 1000
  local days = floor(secs / 86400)
  local rest = secs - days * 86400
  local y, m, d = date.civil_from_days(days)
  return ('%04d-%02d-%02dT%02d:%02d:%02d.%03dZ'):format(
    y,
    m,
    d,
    floor(rest / 3600),
    floor(rest % 3600 / 60),
    rest % 60,
    msec
  )
end

-- Coroutines inside, callbacks outside. `run` starts `body(task)`; when it returns, `done` gets
-- its results; an error in it goes to `cleanup` and then `done(nil, message)`. No `pcall` around
-- a yield (plain Lua 5.1 cannot cross one): `coroutine.resume` catches the error.
local function run(body, done, cleanup)
  local co = coroutine.create(body)
  local task = {}
  function task.resume(...)
    local ok, a, b = coroutine.resume(co, ...)
    if not ok then
      if cleanup then
        cleanup()
      end
      done(nil, tostring(a))
    elseif coroutine.status(co) == 'dead' then
      done(a, b)
    end
  end
  task.resume(task)
end

-- Calls `fn(cb)` and returns what `cb` is called with, suspending the task until then. An answer
-- that comes before `fn` returns is taken without suspending; a second answer is ignored.
local function await(task, fn)
  local state, ra, rb = 'running', nil, nil
  local function cb(a, b)
    if state == 'answered' then
      return
    end
    local before = state
    state = 'answered'
    if before == 'running' then
      ra, rb = a, b
    else
      task.resume(a, b)
    end
  end
  fn(cb)
  if state == 'answered' then
    return ra, rb
  end
  state = 'waiting'
  return coroutine.yield()
end

--- A new indexer. `storage = { exists(path) -> bool, read(path) -> bytes | nil, write(path,
--- bytes), mkdir(path) }` (`M.fs_storage()` is one over the file system); `dir` is the index
--- directory, `embedder(texts, cb)` as described on top, `model` the embedding model's name.
--- `opts = { dim = 256, now = function() return ms end, warn = function(message) end }`: `now`
--- is the clock for `built_at` in milliseconds since the epoch (default `os.time() * 1000`),
--- `warn` hears what a run survives (an intermediate state that could not be written; default
--- `vim.notify`). A `dim` that is no positive whole number raises.
function M.new(storage, dir, embedder, model, opts)
  opts = opts or {}
  if
    type(storage) ~= 'table'
    or type(dir) ~= 'string'
    or type(embedder) ~= 'function'
    or type(model) ~= 'string'
  then
    error(
      'nvim-kit live_indexer: new needs storage (table), dir (string), embedder (function) and model (string)',
      2
    )
  end
  local dim = opts.dim
  if dim == nil then
    dim = M.DEFAULT_INDEX_DIM
  end
  if not whole(dim, 1) then
    error(('nvim-kit live_indexer: dim must be a positive whole number, was %s'):format(tostring(dim)), 2)
  end
  return setmetatable({
    dim = dim,
    _storage = storage,
    _dir = dir,
    _embedder = embedder,
    _model = model,
    _now = opts.now or function()
      return os.time() * 1000
    end,
    _warn = opts.warn or function(message)
      vim.notify('nvim-kit live_indexer: ' .. message, vim.log.levels.WARN)
    end,
    _vectors = {}, -- path -> list of numbers
    -- path -> { mtime, size } of the note when it was embedded; kept in step with `_vectors`:
    -- every change there changes this too, or a stamp points at a foreign vector. Optional: a
    -- caller without stamps gets rows that persist writes as the unknown stamp.
    _stamps = {},
    _manifest = nil,
    _ready = false,
    -- Paths touched by a live handler DURING a `reindex_all` (a set); nil while none runs. A full
    -- reindex works through a snapshot of the paths and replaces the whole stock at the end:
    -- without this record everything that appears or changes meanwhile would fall out. The index
    -- ends up as the vault looks at the END of the run. Paths only, not vectors: the vector is
    -- looked up when applied, and `_vectors` is always the newest. A path that is gone there was
    -- a `remove`. Two runs at once share this field (a known limit, as in the source).
    _live = nil,
    _cancel = false,
    _observed_dim = nil, -- length of the first vector the model returned
    _loaded_dim = nil, -- `source_dim` of the manifest this indexer was initialised from
  }, Ix)
end

--- An storage over the file system: `io.open` for reading, `store.write_bytes` (atomic, fsync)
--- for writing, `mkdir -p` for the directory.
function M.fs_storage()
  return {
    exists = function(path)
      return vim.uv.fs_stat(path) ~= nil
    end,
    read = function(path)
      local f = io.open(path, 'rb')
      if not f then
        return nil
      end
      local data = f:read('*a')
      f:close()
      return data
    end,
    write = function(path, bytes)
      store.write_bytes(path, bytes)
    end,
    mkdir = function(path)
      vim.fn.mkdir(path, 'p')
    end,
  }
end

local function refusal_text(kind, a, b)
  if kind == 'not-ready' then
    return 'persist refused: the index is not initialised (load failure) - the good index on disk stays'
  elseif kind == 'unreadable' then
    return 'persist refused: the index on disk is not readable right now (a running sync or a parallel write) - the good index on disk stays untouched'
  elseif kind == 'shrink' then
    return ('persist refused: the index on disk has %d notes, this write has %d - a confused indexer would flatten a good index'):format(
      a,
      b
    )
  elseif kind == 'model-mismatch' then
    return ('persist refused: the index on disk was built with %q, this indexer embeds with %q - mixing two vector spaces is the damage itself'):format(
      a,
      b
    )
  end
  return ('persist refused: the index has %s columns, this indexer %d - the vectors would be cut or padded with zeros'):format(
    tostring(a),
    b
  )
end

--- Takes over a loaded index (`vectors.parse`, with its container's `manifest` on it as
--- `index.manifest` when `vault` and `source_dim` should be carried over) and, as `stamps`, the
--- list of `{ mtime, size }` that goes with it row for row. Raises `{ kind = 'dim-mismatch',
--- message }` when it has other columns than this indexer (an empty index has no vectors to
--- damage and is taken as it is). An indexer that has taken an index is ready.
function Ix:init(index, stamps)
  if type(index) ~= 'table' or type(index.paths) ~= 'table' then
    error('nvim-kit live_indexer: init needs an index (vectors.parse)', 2)
  end
  if index.count > 0 then
    local decision = guard.assert_dim_safe_to_persist(index.dim, self.dim, 'live')
    if not decision.allowed then
      error(
        setmetatable(blocked('dim-mismatch', refusal_text('dim-mismatch', index.dim, self.dim)), {
          __tostring = function(e)
            return 'nvim-kit live_indexer: dim-mismatch: ' .. e.message
          end,
        }),
        0
      )
    end
  end
  self._manifest = index.manifest
  local sd = index.manifest and index.manifest.source_dim
  self._loaded_dim = whole(sd, 1) and sd or nil
  self._vectors, self._stamps = {}, {}
  local dim = index.dim
  local data, first = index.data, index.ffi and 0 or 1
  for r = 1, #index.paths do
    local path = index.paths[r]
    local row = index.rows and index.rows[path] or r -- a path that repeats: the last row (a Map)
    local v = {}
    local at = first + (row - 1) * dim
    for c = 1, dim do
      v[c] = data[at + c - 1]
    end
    self._vectors[path] = v
  end
  -- Without taking the stamps over the guard would be blind after every restart: the first live
  -- persist would write the container without them.
  if stamps and #stamps == #index.paths then
    for i, path in ipairs(index.paths) do
      local st = stamps[i]
      if st and self._vectors[path] then
        self._stamps[path] = { st[1], st[2] }
      end
    end
  end
  self._ready = true
end

-- The length of the first vector the model returns, for `source_dim`.
function Ix:_observe(vecs)
  if self._observed_dim == nil then
    local first = vecs[1]
    local n = type(first) == 'table' and #first or 0
    if n > 0 then
      self._observed_dim = n
    end
  end
end

-- The vectors of one note (all its chunks) -> the row for the index.
function Ix:_row_from(vecs)
  self:_observe(vecs)
  return vectors.to_index_vector(vecs, self.dim)
end

-- Asks the embedder for `texts`; the list of vectors, or nil and why.
function Ix:_embed(task, texts)
  local vecs, err = await(task, function(cb)
    local ok, thrown = pcall(self._embedder, texts, cb)
    if not ok then
      cb(nil, thrown)
    end
  end)
  if type(vecs) ~= 'table' then
    return nil, err and tostring(err) or 'the embedder returned no vectors'
  end
  return vecs
end

local function chunk_texts(content)
  local out = {}
  for i, c in ipairs(chunker.chunk_markdown(content)) do
    out[i] = c.text
  end
  return out
end

-- The row for a note's content: the row, `false` when it has no chunk, or nil and why.
function Ix:_embed_note(task, content)
  local texts = chunk_texts(content)
  if #texts == 0 then
    return false
  end
  local vecs, err = self:_embed(task, texts)
  if not vecs then
    return nil, err
  end
  return self:_row_from(vecs)
end

-- No-op outside a reindex: the normal case costs one nil check.
function Ix:_note_live(path)
  if self._live then
    self._live[path] = true
  end
end

--- Embeds the note and keeps its vector (and `stamp`, `{ mtime, size }`, when given), then
--- `cb('indexed')`; a note without chunks (empty, frontmatter only) is taken out of the index
--- instead: `cb('empty')`. An embedding that fails changes nothing: `cb(nil, err)`.
function Ix:update(path, content, stamp, cb)
  if type(stamp) == 'function' and cb == nil then
    cb, stamp = stamp, nil
  end
  if type(path) ~= 'string' or type(content) ~= 'string' or type(cb) ~= 'function' then
    error('nvim-kit live_indexer: update(path, content, stamp?, cb) needs strings and a callback', 2)
  end
  check_stamp(stamp, 'update')
  run(function(task)
    local row, err = self:_embed_note(task, content)
    if row == nil then
      return nil, err
    end
    self:_note_live(path)
    if row then
      self._vectors[path] = row
      self._stamps[path] = stamp and { stamp[1], stamp[2] } or nil
      return 'indexed'
    end
    self._vectors[path] = nil
    self._stamps[path] = nil
    return 'empty'
  end, cb)
end

--- Takes a note out of the index, with its stamp.
function Ix:remove(path)
  self:_note_live(path)
  self._vectors[path] = nil
  self._stamps[path] = nil
end

--- Moves a note's vector and stamp to its new path.
function Ix:rename(old, new)
  self:_note_live(old)
  self:_note_live(new)
  local v = self._vectors[old]
  if v then
    self._vectors[new] = v
    self._vectors[old] = nil
  end
  local st = self._stamps[old]
  if st then
    self._stamps[new] = st
    self._stamps[old] = nil
  end
end

--- The number of notes in memory.
function Ix:note_count()
  return count_keys(self._vectors)
end

function Ix:is_ready()
  return self._ready
end

--- The no-index path: nothing on disk, so an empty indexer may build up safely.
function Ix:mark_fresh()
  self._ready = true
end

--- The danger state in the middle of a session: live persists are refused until `init` or
--- `mark_fresh`.
function Ix:mark_unready()
  self._ready = false
end

-- Stamps in row order, WITHOUT GAPS: a row without a known stamp carries the unknown one (a row
-- that is unchecked, not suspect). nil only when no stamp is known at all (an index from before
-- the guard); then the field stays out instead of filling every row with a placeholder. A gap
-- must not cost the stamps of the whole run: the field is parallel to `paths`.
function Ix:_stamps_for(paths, source)
  source = source or self._stamps
  if next(source) == nil then
    return nil
  end
  local out = {}
  for i, p in ipairs(paths) do
    local st = source[p]
    out[i] = st and { st[1], st[2] } or { guard.UNKNOWN_STAMP[1], guard.UNKNOWN_STAMP[2] }
  end
  return out
end

--- The index as it is in memory: `{ paths (sorted by bytes), dim, count, data, ffi, rows,
--- manifest }`, shaped like `vectors.parse` makes it (so `vectors.search` and `vectors.related`
--- take it), with the values as they are, not quantised. Its manifest names THIS indexer's
--- model, whatever index it was initialised from.
function Ix:build_index()
  local paths = sorted_keys(self._vectors)
  local n, dim = #paths, self.dim
  local native = has_ffi
  local data = native and ffi.new('float[?]', math.max(n * dim, 1)) or {}
  local first = native and 0 or 1
  local rows = {}
  for r, p in ipairs(paths) do
    rows[p] = r
    local v = self._vectors[p]
    local at = first + (r - 1) * dim
    for c = 1, dim do
      local x = v[c] or 0
      data[at + c - 1] = native and x or vectors.fround(x)
    end
  end
  return {
    paths = paths,
    dim = dim,
    count = n,
    data = data,
    ffi = native,
    rows = rows,
    manifest = {
      schema_version = 1,
      embedding_model = self._model,
      index_dim = dim,
      scale = M.INT8_SCALE,
      count = n,
      granularity = 'note',
      quant = 'int8',
    },
  }
end

-- Number of notes and model of the container on disk, read from the disk itself (not from the
-- memory), ONE read for all the guards. nil: state unknown, refuse to be safe (a container is
-- there but cannot be read or decoded - a foreign process or a sync is writing it, or the CRC or
-- magic is wrong). No container is legitimately fresh (count 0, no model: nothing to protect).
function Ix:_disk_state()
  local path = self._dir .. '/' .. M.CONTAINER_FILE
  local ok, exists = pcall(self._storage.exists, path)
  if not ok then
    return nil
  end
  if not exists then
    return { count = 0, model = '', dim = nil }
  end
  local read_ok, bytes = pcall(self._storage.read, path)
  if not read_ok or type(bytes) ~= 'string' then
    return nil
  end
  local d = vrix.decode(bytes)
  if not d or type(d.manifest.count) ~= 'number' then
    return nil
  end
  local model, dim = d.manifest.embedding_model, d.manifest.index_dim
  return {
    count = d.manifest.count,
    model = type(model) == 'string' and model or '',
    dim = type(dim) == 'number' and dim or nil,
  }
end

-- The model and dimension guards against the disk state; a refusal or nil.
function Ix:_model_and_dim_refusal(disk, reason)
  local model_decision = guard.assert_model_safe_to_persist(disk.model, self._model, reason)
  if not model_decision.allowed then
    return blocked(
      model_decision.kind or 'model-mismatch',
      refusal_text('model-mismatch', disk.model, self._model)
    )
  end
  local dim_decision = guard.assert_dim_safe_to_persist(disk.dim, self.dim, reason)
  if not dim_decision.allowed then
    return blocked(dim_decision.kind or 'dim-mismatch', refusal_text('dim-mismatch', disk.dim, self.dim))
  end
  return nil
end

-- Writes ANY map of vectors as a container. The map is an argument and not `_vectors` because
-- the intermediate states write a map that is not the current stock; hanging it into the field
-- for a moment was the cause of a lost live update in the source (its "hole B").
-- Returns true, or nil and { kind, message } when a guard refuses.
function Ix:_persist_vectors(map, reason, stamp_model, stamps)
  local next_count = count_keys(map)
  if not self._ready and reason == 'live' then
    return nil, blocked('not-ready', refusal_text('not-ready'))
  end
  if reason ~= 'reindex' then
    -- The truth on disk instead of a cached state: a stale memory (a `mark_fresh` while a sync
    -- download was still running) must not overwrite a real, larger index.
    local disk = self:_disk_state()
    -- nil is no disk truth (damaged container, running sync). For `live` that stops the write;
    -- `heal` may go on, or the auto-heal could never overwrite a defective container.
    if disk == nil then
      if reason == 'live' then
        return nil, blocked('unreadable', refusal_text('unreadable'))
      end
    else
      -- The guards decide for themselves for whom they apply; the comparison is always against
      -- the container, never against the manifest in memory.
      local decision = guard.assert_safe_to_persist(disk.count, next_count, reason)
      if not decision.allowed then
        return nil, blocked(decision.kind or 'shrink', refusal_text('shrink', disk.count, next_count))
      end
      local refusal = self:_model_and_dim_refusal(disk, reason)
      if refusal then
        return nil, refusal
      end
    end
  end
  local paths = sorted_keys(map)
  local n, dim = #paths, self.dim
  local chunks = {}
  for r, p in ipairs(paths) do
    local v = map[p]
    -- a row longer than `dim` is cut, a shorter one is padded with zeros
    local q = vectors.quantize_int8(#v > dim and slice(v, 1, dim) or v, M.INT8_SCALE)
    local bytes = {}
    for i = 1, dim do
      local x = q[i] or 0
      bytes[i] = x < 0 and x + 256 or x
    end
    -- string.char takes its arguments from the stack: a row goes out in pieces
    local pieces = {}
    for from = 1, dim, 512 do
      pieces[#pieces + 1] = string.char(unpack(bytes, from, math.min(from + 511, dim)))
    end
    chunks[r] = table.concat(pieces)
  end
  self._storage.mkdir(self._dir)
  local manifest = {
    -- Purely informative, read by nobody. The indexer knows no vault name: empty is more honest
    -- than a stranger's.
    vault = self._manifest and self._manifest.vault or '',
    embedding_model = stamp_model or self._model,
    source_dim = self._observed_dim or self._loaded_dim or dim,
    index_dim = dim,
    granularity = 'note',
    aggregation = 'mean',
    quant = 'int8',
    scale = M.INT8_SCALE,
    count = n,
    source_commit = '',
    built_at = iso8601(self._now()),
  }
  -- ONE container instead of three files: a sync cannot mix generations any more.
  self._storage.write(
    self._dir .. '/' .. M.CONTAINER_FILE,
    vrix.encode(manifest, paths, table.concat(chunks), self:_stamps_for(paths, stamps))
  )
  self._ready = true
  return true
end

--- Writes the vectors in memory as the container, after the guards. `reason` is why: 'live' (a
--- note changed; the default), 'reindex' (a full rebuild; no guard applies) or 'heal' (additions
--- to an existing index). `stamp_model` is the model to write into the manifest when it is not
--- this indexer's: the vectors of an auto-heal that restores a backup come from the backup's
--- model, and stamping the configured endpoint would disarm the model guard at the next live
--- persist. Returns true, or nil and `{ kind, message }` with `kind` one of 'not-ready',
--- 'unreadable', 'shrink', 'model-mismatch', 'dim-mismatch'. Synchronous: it reads the disk
--- state and writes; a failing `storage` raises.
function Ix:persist(reason, stamp_model)
  reason = reason or 'live'
  if not REASONS[reason] then
    error(
      ('nvim-kit live_indexer: persist: unknown reason %q (live, reindex or heal)'):format(tostring(reason)),
      2
    )
  end
  return self:_persist_vectors(self._vectors, reason, stamp_model, nil)
end

--- The question before an ADDITIVE run that embeds first and persists after (`heal_missing`, then
--- `persist('heal')`): same rule and same disk truth as `persist`, asked before. A blocked heal
--- would otherwise leave foreign vectors in memory that nothing takes back, and a later, regular
--- persist would write them. Not embedding is cheaper than rolling back. Returns `{ allowed =
--- true }` or `{ allowed = false, kind, message }`; no mutation. 'reindex' is not asked (a full
--- replacement is the way out). Stricter than `persist` in one point: no readable container
--- (`unreadable`) forbids the run here, while `persist('heal')` lets it through - that case
--- belongs to the auto-heal that works on a proven backup; a person's "complete the index" has no
--- such base and nothing to check an additive mix against.
function Ix:check_model_against_disk(reason)
  if reason == 'reindex' then
    return { allowed = true }
  end
  if not REASONS[reason] then
    error(('nvim-kit live_indexer: check_model_against_disk: unknown reason %q'):format(tostring(reason)), 2)
  end
  local disk = self:_disk_state()
  if disk == nil then
    return { allowed = false, kind = 'unreadable', message = refusal_text('unreadable') }
  end
  local refusal = self:_model_and_dim_refusal(disk, reason)
  if refusal then
    return { allowed = false, kind = refusal.kind, message = refusal.message }
  end
  return { allowed = true }
end

return M
