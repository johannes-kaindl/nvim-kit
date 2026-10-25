-- Adapters for the code-kit vectors of nvim_kit.vrix: code-kit's names and shapes in, the port's
-- out. Keys are vector function names.
local vrix = require('nvim_kit.vrix')
local V = require('nvim_kit.vectors')

-- Binary data in a vector is a lowercase hex string.
local function from_hex(hex)
  return (hex:gsub('%x%x', function(h)
    return string.char(tonumber(h, 16))
  end))
end

local function to_hex(bytes)
  return (bytes:gsub('.', function(c)
    return ('%02x'):format(c:byte())
  end))
end

-- An int8 matrix is a list of numbers in a vector; the port holds a byte string.
local function bytes_of(list)
  local out = {}
  for i, n in ipairs(list) do
    out[i] = string.char(n < 0 and n + 256 or n)
  end
  return table.concat(out)
end

local function list_of(bytes)
  local out = {}
  for i = 1, #bytes do
    local b = bytes:byte(i)
    out[i] = b >= 128 and b - 256 or b
  end
  return out
end

return {
  _from_hex = from_hex,
  _to_hex = to_hex,
  _bytes_of = bytes_of,
  crc32 = function(hex)
    return vrix.crc32(from_hex(hex))
  end,
  decodeContainer = function(hex)
    local d, reason = vrix.decode(from_hex(hex))
    if not d then
      return { error = reason }
    end
    return { manifest = d.manifest, paths = d.paths, matrix = list_of(d.matrix), stamps = d.stamps }
  end,
  encodeContainer = function(manifest, paths, matrix, stamps)
    return to_hex(vrix.encode(manifest, paths, bytes_of(matrix), stamps))
  end,
  containerRetrieve = function(hex, request)
    local d, reason = vrix.decode(from_hex(hex))
    if not d then
      return { error = reason }
    end
    local idx = V.parse(d.manifest, d.paths, d.matrix)
    if not idx then
      return { error = 'corrupt' }
    end
    local o = request.opts
    local opts = { k = o.k, min_sim = o.minSim, exclude = o.exclude }
    if request.related then
      return V.related(idx, request.related, opts)
    end
    return V.search(idx, V.to_index_vector({ request.search }, d.manifest.index_dim), opts)
  end,
}
