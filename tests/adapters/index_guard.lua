-- Adapters for the code-kit vectors of nvim_kit.index_guard: code-kit's names and shapes in, the
-- port's out. Keys are vector function names. The vectors project a decision to
-- `{ allowed, kind? }`, which is what the port returns.
local G = require('nvim_kit.index_guard')

return {
  assertSafeToPersist = function(disk_count, next_count, reason)
    return G.assert_safe_to_persist(disk_count, next_count, reason)
  end,
  isSuspiciousShrink = function(current, incoming, ratio)
    return G.is_suspicious_shrink(current, incoming, ratio)
  end,
  embeddingModelMatchesIndex = function(model, index_model)
    return G.embedding_model_matches_index(model, index_model)
  end,
  assertModelSafeToPersist = function(disk_model, model, reason)
    return G.assert_model_safe_to_persist(disk_model, model, reason)
  end,
  assertDimSafeToPersist = function(disk_dim, dim, reason)
    return G.assert_dim_safe_to_persist(disk_dim, dim, reason)
  end,
  diffIndexVsVault = function(index_paths, vault_paths)
    return G.diff_index_vs_vault(index_paths, vault_paths)
  end,
  findDeadVectorPaths = function(paths, values, dim)
    return G.find_dead_vector_paths(paths, values, dim)
  end,
  -- the vector's third argument is an object path -> [mtime, size], the port's `current` too
  findStaleVectorPaths = function(paths, stamps, current)
    return G.find_stale_vector_paths(paths, stamps, current)
  end,
}
