local T = require('nvim_kit.test')
local C = require('nvim_kit.conformance')
local G = require('nvim_kit.index_guard')
local D = require('nvim_kit.index_delta')
local here = vim.fn.fnamemodify(debug.getinfo(1, 'S').source:sub(2), ':p:h')
local VECTORS = here .. '/conformance/code-kit'
-- The vectors use code-kit's names and shapes; the adapters are the only translation.
local ADAPTERS = vim.tbl_extend(
  'error',
  dofile(here .. '/adapters/index_guard.lua'),
  dofile(here .. '/adapters/index_delta.lua')
)

local NAMES = {
  'assertSafeToPersist',
  'isSuspiciousShrink',
  'embeddingModelMatchesIndex',
  'assertModelSafeToPersist',
  'assertDimSafeToPersist',
  'diffIndexVsVault',
  'findDeadVectorPaths',
  'findStaleVectorPaths',
  'computeIndexDelta',
  'splitHealTargets',
}

local function run(adapters)
  local vectors = C.load_dir(VECTORS)
  local failures, cases = {}, 0
  for _, name in ipairs(NAMES) do
    T.ok(vectors[name], 'no vector file for ' .. name)
    cases = cases + #vectors[name].cases
    for _, f in ipairs(C.run(vectors[name], adapters[name])) do
      f['function'] = name
      failures[#failures + 1] = f
    end
  end
  return cases, failures
end

local function with(name, wrap)
  local adapters = vim.tbl_extend('force', {}, ADAPTERS)
  adapters[name] = wrap(ADAPTERS[name])
  return adapters
end

local function failed_names(failures)
  local names = {}
  for _, f in ipairs(failures) do
    names[#names + 1] = f.name
  end
  table.sort(names)
  return names
end

T.case('passes every code-kit guard and delta vector (7+5+7+6+6+5+4+7 + 4+3 cases)', function()
  local vectors = C.load_dir(VECTORS)
  local counts = {}
  for i, name in ipairs(NAMES) do
    counts[i] = #vectors[name].cases
  end
  T.eq(counts, { 7, 5, 7, 6, 6, 5, 4, 7, 4, 3 })
  local cases, failures = run(ADAPTERS)
  T.eq(cases, 54)
  T.eq(failures, {})
end)

T.case('counter-check: a persist guard that lets a drop of two through fails the shrink vectors', function()
  local _, failures = run(with('assertSafeToPersist', function()
    return function(disk, next_count, reason)
      -- the real rule with `- 2`
      if reason ~= 'live' or next_count >= disk - 2 then
        return { allowed = true }
      end
      return { allowed = false, kind = 'shrink' }
    end
  end))
  T.eq(failed_names(failures), { 'live, two less is blocked' })
end)

T.case('counter-check: a non-strict shrink comparison fails the boundary vector', function()
  local _, failures = run(with('isSuspiciousShrink', function()
    return function(current, incoming, ratio)
      return current > 0 and incoming <= current * (ratio or 0.5)
    end
  end))
  T.eq(failed_names(failures), { 'default ratio, 100 to 50' })
end)

T.case('counter-check: a model comparison without trim fails the whitespace vectors', function()
  local _, failures = run(with('embeddingModelMatchesIndex', function()
    return function(model, index_model)
      return index_model == nil or index_model == '' or model == index_model
    end
  end))
  T.ok(#failures > 0)
  T.ok(vim.tbl_contains(failed_names(failures), 'outer whitespace'))
end)

T.case('counter-check: reporting a row of the unknown stamp fails the skip vector', function()
  local _, failures = run(with('findStaleVectorPaths', function()
    return function(paths, stamps, current)
      local out = {}
      if stamps == nil or #stamps ~= #paths then
        return out
      end
      for r, path in ipairs(paths) do
        local now = current[path]
        if now and (now[1] ~= stamps[r][1] or now[2] ~= stamps[r][2]) then
          out[#out + 1] = path
        end
      end
      return out
    end
  end))
  T.eq(failed_names(failures), { 'unknown stamp [0,0] is skipped' })
end)

T.case('counter-check: counting an empty path that is not missing fails the delta vector', function()
  local _, failures = run(with('computeIndexDelta', function()
    return function(total, missing, empty)
      -- every empty path counts, missing or not
      local n = #empty
      return { embedded = total - n - (#missing - n), total = total - n, emptyCount = n }
    end
  end))
  T.ok(#failures > 0)
end)

-- The vectors fix the shapes; these pin what they cannot carry.

T.case('assert_safe_to_persist: the threshold is exactly one less, whatever the counts', function()
  T.eq(G.assert_safe_to_persist(1, 0, 'live'), { allowed = true })
  T.eq(G.assert_safe_to_persist(0, 0, 'live'), { allowed = true })
  T.eq(G.assert_safe_to_persist(2, 0, 'live'), { allowed = false, kind = 'shrink' })
  -- an unknown reason is not 'live': the person asked for nothing special, the guard does not guess
  T.eq(G.assert_safe_to_persist(100, 0, 'whatever'), { allowed = true })
end)

T.case('assert_dim_safe_to_persist: a dimension that is no finite positive number allows', function()
  T.eq(G.assert_dim_safe_to_persist(0 / 0, 256, 'live'), { allowed = true }, 'NaN')
  T.eq(G.assert_dim_safe_to_persist(math.huge, 256, 'live'), { allowed = true }, 'infinity')
  T.eq(G.assert_dim_safe_to_persist(-1, 256, 'live'), { allowed = true }, 'negative')
  T.eq(G.assert_dim_safe_to_persist('1024', 256, 'live'), { allowed = true }, 'a string is no dimension')
  T.eq(G.assert_dim_safe_to_persist(1, 256, 'live'), { allowed = false, kind = 'dim-mismatch' })
end)

T.case('assert_model_safe_to_persist: the trimmed disk model is compared, blank allows', function()
  T.eq(
    G.assert_model_safe_to_persist('\194\160m\227\128\128', ' m ', 'live'),
    { allowed = true },
    'JS whitespace'
  )
  T.eq(G.assert_model_safe_to_persist('', 'm', 'heal'), { allowed = true })
  T.eq(G.assert_model_safe_to_persist('M', 'm', 'heal'), { allowed = false, kind = 'model-mismatch' })
end)

T.case('diff_index_vs_vault: duplicates and order survive, nothing is shared with the input', function()
  local index = { 'a.md', 'x.md' }
  local vault = { 'b.md', 'a.md', 'b.md' }
  local d = G.diff_index_vs_vault(index, vault)
  T.eq(d, { missing = { 'b.md', 'b.md' }, stale = { 'x.md' } })
  d.stale[1] = 'changed'
  T.eq(index, { 'a.md', 'x.md' })
end)

T.case('find_dead_vector_paths: -0 is zero, a lone small value is alive, the last row counts', function()
  T.eq(G.find_dead_vector_paths({ 'a', 'b' }, { -0.0, 0, 0, 1e-30 }, 2), { 'a' })
  T.eq(G.find_dead_vector_paths({ 'a', 'b' }, { 1, 1, 0, 0 }, 2), { 'b' })
  T.eq(G.find_dead_vector_paths({}, {}, 4), {})
end)

T.case(
  'find_stale_vector_paths: UNKNOWN_STAMP is { 0, 0 }, a path missing from current is skipped',
  function()
    T.eq(G.UNKNOWN_STAMP, { 0, 0 })
    T.eq(G.find_stale_vector_paths({ 'a', 'gone' }, { { 1, 2 }, { 1, 2 } }, { a = { 1, 3 } }), { 'a' })
    -- only a size that differs is enough
    T.eq(G.find_stale_vector_paths({ 'a' }, { { 5, 1 } }, { a = { 5, 2 } }), { 'a' })
    -- a partly unknown stamp is not UNKNOWN_STAMP
    T.eq(G.find_stale_vector_paths({ 'a' }, { { 0, 7 } }, { a = { 1, 7 } }), { 'a' })
  end
)

T.case('compute: only missing paths count as empty; nothing is changed in the arguments', function()
  local missing, empty = { 'a', 'b' }, { 'b', 'in-index.md' }
  T.eq(D.compute(10, missing, empty), { embedded = 8, total = 9, emptyCount = 1 })
  T.eq(missing, { 'a', 'b' })
  T.eq(empty, { 'b', 'in-index.md' })
end)

T.case('split_heal_targets: order of the input, duplicates kept', function()
  T.eq(
    D.split_heal_targets({ 'c', 'a', 'c', 'b' }, { 'a' }),
    { embeddable = { 'c', 'c', 'b' }, knownEmpty = { 'a' } }
  )
end)

T.case('wrong argument types raise', function()
  T.raises(function()
    G.assert_safe_to_persist('100', 0, 'live')
  end, 'disk_count')
  T.raises(function()
    G.assert_safe_to_persist(100, 0)
  end, 'reason')
  T.raises(function()
    G.is_suspicious_shrink(1, 1, 'x')
  end, 'ratio')
  T.raises(function()
    G.embedding_model_matches_index(nil, 'm')
  end, 'model')
  T.raises(function()
    G.diff_index_vs_vault('a', {})
  end, 'index_paths')
  T.raises(function()
    G.find_dead_vector_paths({}, {}, nil)
  end, 'dim')
  T.raises(function()
    D.compute(1, {}, nil)
  end, 'empty')
  T.raises(function()
    D.split_heal_targets(nil, {})
  end, 'missing')
end)
