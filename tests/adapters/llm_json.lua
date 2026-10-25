-- Adapters for the code-kit vectors of nvim_kit.llm_json: code-kit's names and shapes in, the port's
-- out. Keys are vector function names.
local J = require('nvim_kit.llm_json')

local function think_opts(o)
  if o == false then
    return false
  end
  return o and { drop_stray_close = o.dropStrayClose, drop_unclosed = o.dropUnclosed } or nil
end

return {
  stripThinkBlocks = function(text, o)
    return J.strip_think(text, think_opts(o))
  end,
  firstJsonObject = function(raw, o)
    o = o or {}
    return J.first_json_object(raw, {
      think = think_opts(o.think),
      fence = o.fence,
      fence_tag = o.fenceTag,
      repair = o.repair,
    })
  end,
}
