-- Request profiles for local and hosted LLM backends: which sampling values, which
-- reasoning_effort and which minimum token budget to send per model family × mode, and which
-- of those fields a backend honours. A port of code-kit src/ts/pure/sampling-profiles.ts
-- (resolveRequestParams, familyFromName, thinkingFor, validateOverride,
-- sanitizeRequestSettings); the tables are code-kit's export in data/sampling-profiles.json,
-- vendored, never edited. Checked against code-kit's conformance vectors.
local M = {}

-- Relative require: a vendored copy loads its sibling under lua/<plugin>/kit/.
local data = require(((...):gsub('sampling$', 'data')))

local D = data.load(data.beside(debug.getinfo(1, 'S').source, 'data/sampling-profiles.json'), { schema = 1 })
M.data = D

local function set_of(list)
  local s = {}
  for _, v in ipairs(list) do
    s[v] = true
  end
  return s
end

local MODES = set_of(D.modeIds)
local FAMILIES = set_of(D.familyIds)
local FIELDS = set_of(D.fieldOrder)
local LEVELS = set_of(D.thinkingLevels)
local EFFORTS = set_of(D.effortValues)

-- Family patterns are JS regexes from a small subset (code-kit src/conformance/README.md): literal
-- characters, `\.`, a class of literals and `?`, flag `i`. Translated into Lua patterns once; a
-- pattern outside the subset raises instead of matching something else. In a Lua pattern `-` is
-- a quantifier and `.` any character, so every literal is escaped.
local JS_META = '\\^$.|?*+()[]{}'

-- One literal character: letters lowercased (flag i, the name is lowercased too), everything
-- else escaped with % (a Lua pattern treats - . % and more as magic).
local function literal(c)
  return c:match('%w') and c:lower() or '%' .. c
end

local function to_lua_pattern(src)
  local out, i = {}, 1
  while i <= #src do
    local c = src:sub(i, i)
    if c == '\\' then
      local n = src:sub(i + 1, i + 1)
      if n ~= '.' then
        error(('nvim-kit sampling: unsupported escape \\%s in family pattern %q'):format(n, src))
      end
      out[#out + 1] = '%.'
      i = i + 2
    elseif c == '[' then
      local close = src:find(']', i + 1, true)
      if not close then
        error(('nvim-kit sampling: unclosed class in family pattern %q'):format(src))
      end
      local class = {}
      for j = i + 1, close - 1 do
        local m = src:sub(j, j)
        if JS_META:find(m, 1, true) then
          error(('nvim-kit sampling: unsupported class member %q in family pattern %q'):format(m, src))
        end
        class[#class + 1] = literal(m)
      end
      out[#out + 1] = '[' .. table.concat(class) .. ']'
      i = close + 1
    elseif c == '?' then
      if #out == 0 then
        error(('nvim-kit sampling: ? without an atom in family pattern %q'):format(src))
      end
      out[#out] = out[#out] .. '?'
      i = i + 1
    elseif JS_META:find(c, 1, true) or c:byte() > 127 then
      error(('nvim-kit sampling: unsupported character %q in family pattern %q'):format(c, src))
    else
      out[#out + 1] = literal(c)
      i = i + 1
    end
  end
  return table.concat(out)
end

local PATTERNS = {}
for _, p in ipairs(D.familyPatterns) do
  if p.flags ~= 'i' then
    error(('nvim-kit sampling: family pattern %q has flags %q, expected "i"'):format(p.source, p.flags))
  end
  PATTERNS[#PATTERNS + 1] = { pattern = to_lua_pattern(p.source), family = p.family }
end
M._to_lua_pattern = to_lua_pattern

--- Best guess of the model family from a model id ("qwen3.6:27b" → "qwen3.6"), or nil. Aliases
--- such as "verdigado-pro" return nil on purpose.
function M.family_from_name(model)
  local name = model:lower()
  for _, p in ipairs(PATTERNS) do
    if name:find(p.pattern) then
      return p.family
    end
  end
  return nil
end

--- The thinking level for a mode: the user's choice in request.thinking, else the mode's default.
function M.thinking_for(request, mode)
  local stored = request and request.thinking and request.thinking[mode]
  return stored or D.modes[mode].thinking
end

local function is_finite(v)
  return v == v and v ~= math.huge and v ~= -math.huge
end

--- The value if it is valid for the field, else nil. Numbers must be finite, inside the range and
--- integral where required; reasoning_effort must be a known word.
function M.validate_override(field, raw)
  if field == 'reasoning_effort' then
    return (type(raw) == 'string' and EFFORTS[raw]) and raw or nil
  end
  if type(raw) ~= 'number' or not is_finite(raw) then
    return nil
  end
  local r = D.ranges[field]
  if raw < r.min or raw > r.max then
    return nil
  end
  if r.int and raw ~= math.floor(raw) then
    return nil
  end
  return raw
end

-- A JSON object as Lua sees it: a table that is not a list. An empty table counts as an object
-- unless it is known to be an empty list; vim.json.decode('[]') gives a plain {}, which looks the
-- same, and code-kit treats both as "nothing configured".
local function is_obj(v)
  return type(v) == 'table' and v ~= vim.NIL and (next(v) == nil or not vim.islist(v))
end

-- Lua's < on strings follows the locale; code-kit sorts by code unit, which is byte order for ASCII.
local function byte_less(a, b)
  local n = math.min(#a, #b)
  for i = 1, n do
    local x, y = a:byte(i), b:byte(i)
    if x ~= y then
      return x < y
    end
  end
  return #a < #b
end

local function sorted_keys(t)
  local keys = vim.tbl_keys(t)
  for i, k in ipairs(keys) do
    keys[i] = tostring(k)
  end
  table.sort(keys, byte_less)
  return keys
end

local function level_map(raw, path, dropped)
  local out = vim.empty_dict()
  if not is_obj(raw) then
    return out
  end
  for _, k in ipairs(sorted_keys(raw)) do
    local v = raw[k]
    if MODES[k] and type(v) == 'string' and LEVELS[v] then
      out[k] = v
    else
      dropped[#dropped + 1] = path .. '.' .. k
    end
  end
  return out
end

--- Validates a plugin's `request` table field by field. Returns the clean settings and the sorted
--- paths of everything that was dropped; the caller reports `dropped` — nothing is discarded
--- silently. Empty maps are vim.empty_dict(), so they stay objects when written as JSON.
function M.sanitize(raw)
  local dropped = {}
  local settings = {
    overrides = vim.empty_dict(),
    thinking = vim.empty_dict(),
    lastOnLevel = vim.empty_dict(),
    levelPickerInChat = false,
  }
  if not is_obj(raw) then
    return settings, dropped
  end
  if is_obj(raw.overrides) then
    for _, mode in ipairs(sorted_keys(raw.overrides)) do
      local by_family = raw.overrides[mode]
      if not MODES[mode] or not is_obj(by_family) then
        dropped[#dropped + 1] = 'overrides.' .. mode
      else
        for _, fam in ipairs(sorted_keys(by_family)) do
          local fields = by_family[fam]
          if not (fam == 'unknown' or FAMILIES[fam]) or not is_obj(fields) then
            dropped[#dropped + 1] = ('overrides.%s.%s'):format(mode, fam)
          else
            local kept = {}
            for _, field in ipairs(sorted_keys(fields)) do
              local ok = FIELDS[field] and M.validate_override(field, fields[field]) or nil
              if ok == nil then
                dropped[#dropped + 1] = ('overrides.%s.%s.%s'):format(mode, fam, field)
              else
                kept[field] = ok
              end
            end
            if next(kept) ~= nil then
              if next(settings.overrides) == nil then
                settings.overrides = {}
              end
              settings.overrides[mode] = settings.overrides[mode] or {}
              settings.overrides[mode][fam] = kept
            end
          end
        end
      end
    end
  end
  settings.thinking = level_map(raw.thinking, 'thinking', dropped)
  settings.lastOnLevel = level_map(raw.lastOnLevel, 'lastOnLevel', dropped)
  if type(raw.levelPickerInChat) == 'boolean' then
    settings.levelPickerInChat = raw.levelPickerInChat
  elseif raw.levelPickerInChat ~= nil then
    dropped[#dropped + 1] = 'levelPickerInChat'
  end
  table.sort(dropped, byte_less)
  return settings, dropped
end

-- reasoning_effort to a strict backend with an unknown model risks HTTP 400 (a model that does
-- not reason), so it is only sent where the backend tolerates it.
local function support(backend, field, family_known)
  if
    field == 'reasoning_effort'
    and not family_known
    and backend ~= 'lmstudio'
    and backend ~= 'openwebui'
  then
    return 'unsupported'
  end
  return D.backends[backend].fields[field]
end

local function candidate(value, origin, sourced, note)
  return {
    value = value,
    origin = origin,
    source = sourced and sourced.source,
    evidence = sourced and sourced.evidence,
    note = note,
  }
end

--- The request parameters for one call, and why each field is (not) sent.
--- input = { family = <id|nil>, mode, backend, thinking, max_tokens = <n|nil>, overrides = <map|nil> }
--- → { params = { field = value }, explain = { { field, value, state, origin, source, evidence, note } } }
--- `overrides` are the user's values already chosen for this mode × family and validated.
function M.resolve(input)
  local fam = input.family and D.families[input.family] or nil
  if input.family and not fam then
    error(('nvim-kit sampling: unknown family %q'):format(input.family), 2)
  end
  local mode = D.modes[input.mode]
  if not mode then
    error(('nvim-kit sampling: unknown mode %q'):format(tostring(input.mode)), 2)
  end
  if not D.backends[input.backend] then
    error(('nvim-kit sampling: unknown backend %q'):format(tostring(input.backend)), 2)
  end
  if not LEVELS[input.thinking] then
    error(('nvim-kit sampling: unknown thinking level %q'):format(tostring(input.thinking)), 2)
  end
  local thinking_on = input.thinking ~= 'off'
  local ov = input.overrides or {}
  local cand = {}

  -- 1. temperature: mode, raised to the family's floor while thinking; an override wins
  local floor = thinking_on and fam and fam.thinkingTemperatureFloor or nil
  if type(ov.temperature) == 'number' then
    cand.temperature = candidate(
      ov.temperature,
      'override',
      nil,
      (floor and ov.temperature < floor.value) and 'below-thinking-floor' or nil
    )
  elseif floor and mode.temperature.value < floor.value then
    cand.temperature = candidate(floor.value, 'family', floor, 'raised-to-thinking-floor')
  else
    cand.temperature = candidate(mode.temperature.value, 'mode', mode.temperature)
  end

  -- 2. the family's sampling fields
  for _, f in ipairs(D.familyFields) do
    if type(ov[f]) == 'number' then
      cand[f] = candidate(ov[f], 'override')
    elseif not fam then
      cand[f] = 'unknown-family'
    else
      local s = (thinking_on and fam.thinking or fam.noThinking)[f]
      cand[f] = s and candidate(s.value, 'family', s) or 'no-value'
    end
  end

  -- 3. reasoning_effort
  if type(ov.reasoning_effort) == 'string' then
    cand.reasoning_effort = candidate(ov.reasoning_effort, 'override')
  elseif fam then
    local e = fam.effort[input.thinking]
    local note = (input.thinking == 'off' and not fam.canTurnOff) and 'off-not-possible' or nil
    cand.reasoning_effort = candidate(e.value, 'family', e, note)
  else
    cand.reasoning_effort = candidate(D.genericEffort[input.thinking], 'mode')
  end

  -- 4. max_tokens: the plugin's budget (or an override), raised to the family's reserve
  local base = type(ov.max_tokens) == 'number' and ov.max_tokens or input.max_tokens
  if base == nil then
    cand.max_tokens = 'no-value'
  else
    local reserve = fam and fam.reserve[input.thinking] or nil
    if reserve and base < reserve.value then
      cand.max_tokens = candidate(reserve.value, 'reserve', reserve, 'raised-to-reserve')
    else
      cand.max_tokens = candidate(base, type(ov.max_tokens) == 'number' and 'override' or 'plugin')
    end
  end

  -- 5. what the backend honours
  local params, explain = {}, {}
  for _, field in ipairs(D.fieldOrder) do
    local c = cand[field]
    if c == nil or c == 'no-value' then
      explain[#explain + 1] = { field = field, state = 'not-sent-no-value' }
    elseif c == 'unknown-family' then
      explain[#explain + 1] = { field = field, state = 'not-sent-unknown-family' }
    else
      local s = support(input.backend, field, fam ~= nil)
      local row = {
        field = field,
        value = c.value,
        origin = c.origin,
        source = c.source,
        evidence = c.evidence,
        note = c.note,
      }
      if s == 'ignored' or s == 'unsupported' then
        row.state = s == 'ignored' and 'not-sent-ignored' or 'not-sent-unsupported'
        row.value = nil
      else
        row.state = s == 'effective' and 'sent-effective' or 'sent-unproven'
        params[field] = c.value
      end
      explain[#explain + 1] = row
    end
  end
  return { params = params, explain = explain }
end

--- Everything a call needs from the user's settings in one step: the thinking level for the mode,
--- the overrides for mode × family (family "unknown" when the model is not recognised), resolved
--- for the backend. `request` must come from M.sanitize.
--- opts = { request, mode, family = <id|nil>, backend, max_tokens = <n|nil> }
function M.for_call(opts)
  local request = opts.request or {}
  local by_mode = request.overrides and request.overrides[opts.mode] or nil
  local overrides = by_mode and by_mode[opts.family or 'unknown'] or nil
  return M.resolve({
    family = opts.family,
    mode = opts.mode,
    backend = opts.backend,
    thinking = M.thinking_for(request, opts.mode),
    max_tokens = opts.max_tokens,
    overrides = overrides,
  })
end

return M
