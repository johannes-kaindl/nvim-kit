-- A container written by the indexer from deterministic, awkward vectors (negative and tiny
-- values, several chunks per note). Returns its length and CRC32 so that a run with `ffi` and a
-- run without it can be compared byte for byte.
local L = require('nvim_kit.live_indexer')
local V = require('nvim_kit.vectors')
local vrix = require('nvim_kit.vrix')

return function()
  local dim = 64
  local function vec(seed)
    local v = {}
    for k = 1, dim do
      v[k] = (((seed * 31 + k * 17) % 97) - 48) / 53 + (k % 5) * 1e-4
    end
    return v
  end
  local embedder = function(texts, cb)
    local out = {}
    for i, t in ipairs(texts) do
      out[i] = vec(#t + t:byte(1) + i)
    end
    cb(out)
  end
  local written
  local st = {
    exists = function()
      return false
    end,
    read = function()
      return nil
    end,
    write = function(_, bytes)
      written = bytes
    end,
    mkdir = function() end,
  }
  local ix = L.new(st, 'idx', embedder, 'bytes-model', {
    dim = dim,
    now = function()
      return 1700000000000
    end,
  })
  local man = {
    schema_version = 1,
    embedding_model = 'bytes-model',
    index_dim = dim,
    scale = 127,
    count = 0,
    granularity = 'note',
    quant = 'int8',
  }
  local idx = V.parse(man, {}, '')
  idx.manifest = man
  ix:init(idx)
  for i = 1, 40 do
    local body = ('Note %d\n\n'):format(i) .. string.rep(('word%d '):format(i), (i % 4) * 300 + 20)
    ix:update(('Folder/n%02d.md'):format(i), body, { 1700000000 + i, #body }, function() end)
  end
  assert(ix:persist('reindex'))
  return #written, vrix.crc32(written), V ~= nil
end
