-- Adapters for the code-kit vectors of nvim_kit.sampling: code-kit's names and shapes in, the port's
-- out. Keys are vector function names.
local S = require('nvim_kit.sampling')

return {
  familyFromName = function(model)
    return S.family_from_name(model)
  end,
  thinkingFor = function(request, mode)
    return S.thinking_for(request, mode)
  end,
  validateOverride = function(field, raw)
    return S.validate_override(field, raw)
  end,
  sanitizeRequestSettings = function(raw)
    local settings, dropped = S.sanitize(raw)
    return { settings = settings, dropped = dropped }
  end,
  resolveRequestParams = function(input)
    return S.resolve({
      family = input.family,
      mode = input.mode,
      backend = input.backend,
      thinking = input.thinking,
      max_tokens = input.maxTokens,
      overrides = input.overrides,
    })
  end,
}
