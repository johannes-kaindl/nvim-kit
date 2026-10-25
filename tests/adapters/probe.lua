-- Adapters for the code-kit vectors of nvim_kit.probe: code-kit's names and shapes in, the port's
-- out. Keys are vector function names.
local P = require('nvim_kit.probe')

return {
  probeRank = function(path, seed)
    return P.rank(path, seed)
  end,
  probeOrder = function(files, seed)
    return P.order(files, seed)
  end,
  probeQuery = function(text, opts)
    return P.query(text, opts)
  end,
  compareRuns = function(previous, next)
    return P.compare_runs(previous, next)
  end,
}
