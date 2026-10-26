-- Measurement 2026-10-26 (task "live_indexer — nicht geprüfte Review-Grenzen"): an embedder may
-- answer from a `vim.uv` callback (`vim.in_fast_event()`) without `vim.schedule`. Before 0.15.0 the
-- intermediate states of a full reindex failed there (`vim.fn.mkdir` raises E5560) and the default
-- `warn` (`vim.notify`) raised too, which ended the run. These cases answer from a timer.
local T = require('nvim_kit.test')
local L = require('nvim_kit.live_indexer')
local V = require('nvim_kit.vectors')
local vrix = require('nvim_kit.vrix')

local uv = vim.uv or vim.loop
local DIM = 16

local function unit(i)
  local v = {}
  for k = 1, DIM do
    v[k] = 0
  end
  v[(i % DIM) + 1] = 1
  return v
end

-- An embedder that answers from a fast callback; `seen.fast` records what the callback was.
local function fast_embedder(seen)
  return function(texts, cb)
    local timer = uv.new_timer()
    timer:start(0, 0, function()
      timer:close()
      seen.fast = vim.in_fast_event()
      local out = {}
      for i = 1, #texts do
        out[i] = unit(i)
      end
      cb(out)
    end)
  end
end

local function new_indexer(embedder, opts)
  local dir = vim.fn.tempname() .. '/idx'
  opts = vim.tbl_extend('force', { dim = DIM }, opts or {})
  local ix = L.new(L.fs_storage(), dir, embedder, 'm', opts)
  local man = {
    schema_version = 1,
    embedding_model = 'm',
    index_dim = DIM,
    scale = 127,
    count = 0,
    granularity = 'note',
    quant = 'int8',
  }
  local idx = V.parse(man, {}, '')
  idx.manifest = man
  ix:init(idx)
  return ix, dir
end

local function paths(n)
  local out = {}
  for i = 1, n do
    out[i] = ('n%02d.md'):format(i)
  end
  return out
end

-- Runs `reindex_all` of 6 notes with a checkpoint after every second one; returns the results.
local function reindex_fast(opts)
  local seen = {}
  local ix, dir = new_indexer(fast_embedder(seen), opts)
  local old_every, old_batch = L.CHECKPOINT_EVERY, L.EMBED_BATCH
  L.CHECKPOINT_EVERY, L.EMBED_BATCH = 2, 1
  local done
  local persisted
  local ok, err = pcall(function()
    ix:reindex_all(
      paths(6),
      function(p)
        return 'text of ' .. p
      end,
      nil,
      nil,
      function(report, e)
        -- the callback of a run that ended on a fast callback runs there too
        done = { report = report, err = e, fast = vim.in_fast_event() }
        persisted = { pcall(ix.persist, ix, 'reindex') }
      end
    )
    vim.wait(5000, function()
      return done ~= nil
    end, 5)
  end)
  L.CHECKPOINT_EVERY, L.EMBED_BATCH = old_every, old_batch
  assert(ok, err)
  return { ix = ix, dir = dir, seen = seen, done = done, persisted = persisted }
end

T.case(
  'reindex_all: an embedder answering from a fast callback finishes, checkpoints and persist work',
  function()
    local warns = {}
    local r = reindex_fast({
      warn = function(m)
        warns[#warns + 1] = m
      end,
    })
    T.eq(r.seen.fast, true, 'the embedder must answer from a fast event for this case to mean anything')
    T.ok(r.done, 'the run never called back')
    T.eq(r.done.fast, true)
    T.eq(r.done.err, nil)
    T.eq(r.done.report.added, 6)
    T.eq(warns, {}, 'an intermediate state failed: ' .. vim.inspect(warns))
    T.eq(r.persisted[1], true, tostring(r.persisted[2]))
    local f = assert(io.open(r.dir .. '/index.bin', 'rb'))
    local bytes = f:read('*a')
    f:close()
    local d = assert(vrix.decode(bytes))
    T.eq(d.manifest.count, 6)
    vim.fn.delete(vim.fn.fnamemodify(r.dir, ':h'), 'rf')
  end
)

T.case(
  'reindex_all: a failing intermediate state on a fast callback warns without aborting the run',
  function()
    -- The storage cannot write; the default warn is vim.notify, which raises E5560 in a fast event.
    local notified = {}
    local old_notify = vim.notify
    vim.notify = function(msg)
      -- the real one raises E5560 in a fast event; keep that, but do not print into the test output
      if vim.in_fast_event() then
        error('E5560: vim.notify must not be called in a fast event context')
      end
      notified[#notified + 1] = msg
    end
    local seen = {}
    local storage = {
      exists = function()
        return false
      end,
      read = function()
        return nil
      end,
      write = function()
        error('disk is on fire')
      end,
      mkdir = function() end,
    }
    local ix = L.new(storage, 'idx', fast_embedder(seen), 'm', { dim = DIM })
    local man = {
      schema_version = 1,
      embedding_model = 'm',
      index_dim = DIM,
      scale = 127,
      count = 0,
      granularity = 'note',
      quant = 'int8',
    }
    local idx = V.parse(man, {}, '')
    idx.manifest = man
    ix:init(idx)
    local old_every, old_batch = L.CHECKPOINT_EVERY, L.EMBED_BATCH
    L.CHECKPOINT_EVERY, L.EMBED_BATCH = 2, 1
    local done
    local ok, err = pcall(function()
      ix:reindex_all(
        paths(6),
        function(p)
          return 'text of ' .. p
        end,
        nil,
        nil,
        function(report, e)
          done = { report = report, err = e }
        end
      )
      vim.wait(5000, function()
        return done ~= nil
      end, 5)
      vim.wait(50) -- the scheduled notifications
    end)
    L.CHECKPOINT_EVERY, L.EMBED_BATCH = old_every, old_batch
    vim.notify = old_notify
    assert(ok, err)
    T.eq(seen.fast, true)
    T.ok(done, 'the run never called back')
    T.eq(done.err, nil, 'the run was aborted by its own warning')
    T.eq(done.report.added, 6)
    T.ok(#notified >= 1, 'the warning never reached vim.notify')
    T.ok(notified[1]:find('disk is on fire', 1, true), notified[1])
  end
)

T.case('update and heal_missing: an embedder answering from a fast callback works', function()
  local seen = {}
  local ix = new_indexer(fast_embedder(seen))
  local results = {}
  ix:update('a.md', 'hello world', { 1, 11 }, function(status, e)
    results.update = { status, e, vim.in_fast_event() }
  end)
  vim.wait(2000, function()
    return results.update ~= nil
  end, 5)
  T.eq(results.update, { 'indexed', nil, true })
  T.eq(ix:note_count(), 1)
  local report
  ix:heal_missing(
    { 'b.md', 'c.md' },
    function(p)
      return 'text of ' .. p
    end,
    nil,
    nil,
    function(r)
      report = r
    end
  )
  vim.wait(2000, function()
    return report ~= nil
  end, 5)
  T.ok(report, 'heal_missing never called back')
  T.eq(report.added, 2)
  T.eq(ix:note_count(), 3)
end)
