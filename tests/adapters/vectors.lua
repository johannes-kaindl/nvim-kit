-- Adapters for the code-kit vectors of nvim_kit.vectors: code-kit's names and shapes in, the
-- port's out. Keys are vector function names.
local V = require('nvim_kit.vectors')

-- A vector carries an int8 matrix as a list of numbers; the port reads a byte string.
local function bytes(list)
  local out = {}
  for i, n in ipairs(list) do
    out[i] = string.char(n < 0 and n + 256 or n)
  end
  return table.concat(out)
end

local function opts(o)
  return { k = o.k, min_sim = o.minSim, exclude = o.exclude }
end

local function index(manifest, paths, matrix)
  local idx, err = V.parse(manifest, paths, bytes(matrix))
  assert(idx, err)
  return idx
end

return {
  _bytes = bytes,
  toIndexVector = function(vecs, dim)
    return V.to_index_vector(vecs, dim)
  end,
  quantizeInt8 = function(vec, scale)
    return V.quantize_int8(vec, scale)
  end,
  parseIndex = function(manifest, paths, matrix)
    return V.values(index(manifest, paths, matrix))
  end,
  retrieverSearch = function(manifest, paths, matrix, query, o)
    return V.search(index(manifest, paths, matrix), query, opts(o))
  end,
  retrieverRelated = function(manifest, paths, matrix, path, o)
    return V.related(index(manifest, paths, matrix), path, opts(o))
  end,
}
