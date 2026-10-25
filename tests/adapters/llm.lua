-- Adapters for the code-kit vectors of nvim_kit.llm: code-kit's names and shapes in, the port's
-- out. Keys are vector function names.
local L = require('nvim_kit.llm')

return {
  normalizeEndpoint = function(url)
    return L.normalize_url(url)
  end,
}
