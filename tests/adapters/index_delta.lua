-- Adapters for the code-kit vectors of nvim_kit.index_delta: code-kit's names and shapes in, the
-- port's out. Keys are vector function names. The vectors pass the empty paths as a list, which
-- is what the port takes.
local D = require('nvim_kit.index_delta')

return {
  computeIndexDelta = function(total, missing, empty)
    return D.compute(total, missing, empty)
  end,
  splitHealTargets = function(missing, empty)
    return D.split_heal_targets(missing, empty)
  end,
}
