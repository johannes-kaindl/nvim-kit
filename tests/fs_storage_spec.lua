-- Measurement 2026-10-26 (task "live_indexer — nicht geprüfte Review-Grenzen"): what `persist`
-- does when `fs_storage().write` fails. The result: it RAISES (documented: "a failing `storage`
-- raises"), the container on disk stays the old one byte for byte, no temp file is left, and the
-- indexer's memory is untouched. A plugin therefore calls `persist` under `pcall`. Checked once on
-- a real full volume (ENOSPC, a 600 KB FAT image); these cases use failures that need no root.
local T = require('nvim_kit.test')
local L = require('nvim_kit.live_indexer')
local V = require('nvim_kit.vectors')
local vrix = require('nvim_kit.vrix')

local uv = vim.uv or vim.loop
local DIM = 16

local function embedder(texts, cb)
  local out = {}
  for i = 1, #texts do
    local v = {}
    for k = 1, DIM do
      v[k] = ((i * 5 + k) % 7) - 3
    end
    out[i] = v
  end
  cb(out)
end

local function read_all(path)
  local f = assert(io.open(path, 'rb'))
  local s = f:read('*a')
  f:close()
  return s
end

local function listing(dir)
  local out = {}
  for name in vim.fs.dir(dir) do
    out[#out + 1] = name
  end
  table.sort(out)
  return out
end

-- An indexer over the real file system with `n` notes, persisted once; returns it with its dir.
local function persisted_indexer(n)
  local root = vim.fn.tempname()
  local dir = root .. '/idx'
  local ix = L.new(L.fs_storage(), dir, embedder, 'm', { dim = DIM })
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
  for i = 1, n do
    ix:update(('n%02d.md'):format(i), 'text ' .. i, { i, 6 }, function(status)
      assert(status == 'indexed', tostring(status))
    end)
  end
  assert(ix:persist('live'))
  return ix, dir, root
end

local function add_notes(ix, from, n)
  for i = from, from + n - 1 do
    ix:update(('n%02d.md'):format(i), 'text ' .. i, { i, 6 }, function(status)
      assert(status == 'indexed', tostring(status))
    end)
  end
end

local function drop(root, dir)
  uv.fs_chmod(dir, 493)
  vim.fn.delete(root, 'rf')
end

T.case('persist into a directory that cannot be written raises; the old container stays whole', function()
  local ix, dir, root = persisted_indexer(5)
  local before = read_all(dir .. '/index.bin')
  add_notes(ix, 6, 3)
  assert(uv.fs_chmod(dir, 365)) -- r-xr-xr-x: no new files
  local probe = io.open(dir .. '/probe', 'w')
  if probe then -- root writes anywhere; the other cases cover the error path
    probe:close()
    drop(root, dir)
    return
  end
  local ok, err = pcall(ix.persist, ix, 'live')
  uv.fs_chmod(dir, 493)
  T.eq(ok, false)
  T.ok(
    tostring(err):find('cannot create', 1, true) and tostring(err):find('nvim-kit store', 1, true),
    tostring(err)
  )
  T.ok(read_all(dir .. '/index.bin') == before, 'the container on disk changed')
  T.eq(listing(dir), { 'index.bin' }, 'a temp file was left behind')
  T.eq(ix:note_count(), 8, 'the memory of the indexer must be untouched')
  T.eq(vrix.decode(before).manifest.count, 5)
  -- and once the directory is writable again, the same indexer persists everything
  T.eq(ix:persist('live'), true)
  T.eq(vrix.decode(read_all(dir .. '/index.bin')).manifest.count, 8)
  drop(root, dir)
end)

T.case(
  'persist when the final rename fails (a directory is named index.bin) raises and leaves no temp file',
  function()
    local ix, dir, root = persisted_indexer(3)
    -- replace the container by a directory of that name: the guards read it as unreadable, so ask
    -- with 'reindex', which writes without reading the disk
    assert(os.remove(dir .. '/index.bin'))
    vim.fn.mkdir(dir .. '/index.bin/inside', 'p')
    local ok, err = pcall(ix.persist, ix, 'reindex')
    T.eq(ok, false)
    T.ok(tostring(err):find('cannot replace', 1, true), tostring(err))
    T.eq(listing(dir), { 'index.bin' }, 'a temp file was left behind')
    T.eq(vim.fn.isdirectory(dir .. '/index.bin/inside'), 1)
    drop(root, dir)
  end
)

T.case('persist creates a missing index directory; a file where the directory should be raises', function()
  local ix, dir, root = persisted_indexer(2)
  vim.fn.delete(dir, 'rf')
  T.eq(ix:persist('reindex'), true)
  T.eq(vrix.decode(read_all(dir .. '/index.bin')).manifest.count, 2)
  vim.fn.delete(dir, 'rf')
  vim.fn.writefile({ 'a file, not a directory' }, dir)
  local ok, err = pcall(ix.persist, ix, 'reindex')
  T.eq(ok, false)
  T.ok(tostring(err):find('in the way', 1, true), tostring(err))
  T.eq(vim.fn.readfile(dir), { 'a file, not a directory' })
  vim.fn.delete(root, 'rf')
end)

T.case('a failing write during reindex_all warns per intermediate state; the run completes', function()
  local warns = {}
  local fs = L.fs_storage()
  local storage = {
    exists = fs.exists,
    read = fs.read,
    mkdir = fs.mkdir,
    write = function()
      error('nvim-kit store: cannot write x: ENOSPC: no space left on device', 0)
    end,
  }
  local ix = L.new(storage, vim.fn.tempname() .. '/idx', embedder, 'm', {
    dim = DIM,
    warn = function(m)
      warns[#warns + 1] = m
    end,
  })
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
  local paths = {}
  for i = 1, 5 do
    paths[i] = ('n%02d.md'):format(i)
  end
  local report
  local ok, err = pcall(function()
    ix:reindex_all(
      paths,
      function(p)
        return 'text ' .. p
      end,
      nil,
      nil,
      function(r)
        report = r
      end
    )
  end)
  L.CHECKPOINT_EVERY, L.EMBED_BATCH = old_every, old_batch
  assert(ok, err)
  T.ok(report, 'the run did not complete')
  T.eq(report.added, 5)
  T.eq(#warns, 2, vim.inspect(warns))
  T.ok(warns[1]:find('ENOSPC', 1, true), warns[1])
  -- the final persist is the caller's: it raises, the memory keeps all five notes
  local pok = pcall(ix.persist, ix, 'reindex')
  T.eq(pok, false)
  T.eq(ix:note_count(), 5)
end)
