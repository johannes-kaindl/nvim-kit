-- A container written by the indexer from deterministic, awkward vectors (negative and tiny
-- values, several chunks per note). Returns its length and the CRC32 of its payload so that a run with `ffi` and a
-- run without it can be compared byte for byte.
--
-- The first ten notes carry vectors (SEEDS) found by a search over 300 000 seeds for inputs where
-- float32 rounding decides an int8 value: with `round_even` in `fround_lua` replaced by `floor`
-- fifteen of them quantise differently. Without such inputs int8 quantisation absorbs the ~1e-7
-- error and this comparison could not tell a wrong list-path `fround` from a right one.
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
  local SEEDS = { 7985, 15498, 24378, 41312, 95654, 111537, 120496, 134419, 153822, 177856 }
  local function seeded(seed)
    local v = {}
    for k = 1, dim do
      v[k] = (((seed * 2654435761 + k * 40503) % 1000003) / 1000003) * 2 - 1
    end
    return v
  end
  local embedder = function(texts, cb)
    local out = {}
    for i, t in ipairs(texts) do
      local n = t:match('^Note (%d+)\n')
      out[i] = n and SEEDS[tonumber(n)] and seeded(SEEDS[tonumber(n)]) or vec(#t + t:byte(1) + i)
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
    -- the seeded notes are one chunk each, so their vector is the one the seed made
    local reps = i <= #SEEDS and 3 or (i % 4) * 300 + 20
    local body = ('Note %d\n\n'):format(i) .. string.rep(('word%d '):format(i), reps)
    ix:update(('Folder/n%02d.md'):format(i), body, { 1700000000 + i, #body }, function() end)
  end
  assert(ix:persist('reindex'))
  -- the CRC of everything before the container's own trailing CRC: a CRC over the whole container
  -- is the constant 0x2144DF1C for any content (the CRC-32 residue) and would prove nothing
  return #written, vrix.crc32(written:sub(1, -5))
end
