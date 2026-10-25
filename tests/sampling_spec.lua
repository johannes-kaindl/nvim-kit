local T = require('nvim_kit.test')
local C = require('nvim_kit.conformance')
local S = require('nvim_kit.sampling')
local here = vim.fn.fnamemodify(debug.getinfo(1, 'S').source:sub(2), ':p:h')
local VECTORS = here .. '/conformance/code-kit'

-- The vectors use code-kit's names and shapes; the adapters are the only translation.
local SAMPLING = dofile(here .. '/adapters/sampling.lua')

local function only(names)
  local vectors = C.load_dir(VECTORS)
  local failures, cases = {}, 0
  for _, name in ipairs(names) do
    T.ok(vectors[name], 'no vector file for ' .. name)
    cases = cases + #vectors[name].cases
    for _, f in ipairs(C.run(vectors[name], SAMPLING[name])) do
      f['function'] = name
      failures[#failures + 1] = f
    end
  end
  return cases, failures
end

local NAMES =
  { 'familyFromName', 'thinkingFor', 'validateOverride', 'sanitizeRequestSettings', 'resolveRequestParams' }

T.case('passes every code-kit sampling vector', function()
  local cases, failures = only(NAMES)
  T.eq(cases, 372)
  T.eq(failures, {})
end)

T.case('counter-check: a port that ignores the thinking floor fails resolveRequestParams', function()
  local real = SAMPLING.resolveRequestParams
  SAMPLING.resolveRequestParams = function(input)
    input = vim.deepcopy(input)
    input.thinking = 'off'
    return real(input)
  end
  local _, failures = only({ 'resolveRequestParams' })
  SAMPLING.resolveRequestParams = real
  T.ok(#failures > 0)
end)

T.case('counter-check: sorting dropped with the locale-free < still passes, reversed fails', function()
  local real = SAMPLING.sanitizeRequestSettings
  SAMPLING.sanitizeRequestSettings = function(raw)
    local r = real(raw)
    local rev = {}
    for i = #r.dropped, 1, -1 do
      rev[#rev + 1] = r.dropped[i]
    end
    r.dropped = rev
    return r
  end
  local _, failures = only({ 'sanitizeRequestSettings' })
  SAMPLING.sanitizeRequestSettings = real
  T.ok(#failures > 0)
end)

T.case('counter-check: a plain {} for an empty map fails (it must stay an object)', function()
  local real = SAMPLING.sanitizeRequestSettings
  SAMPLING.sanitizeRequestSettings = function(raw)
    local r = real(raw)
    if next(r.settings.thinking) == nil then
      r.settings.thinking = {}
    end
    return r
  end
  local _, failures = only({ 'sanitizeRequestSettings' })
  SAMPLING.sanitizeRequestSettings = real
  T.ok(#failures > 0)
end)

-- Inputs JSON cannot carry, or that only a Lua port can get wrong (review of building block 1).
T.case('validate_override refuses NaN and both infinities', function()
  for _, field in ipairs({ 'temperature', 'top_p', 'top_k', 'min_p', 'presence_penalty', 'max_tokens' }) do
    T.eq(S.validate_override(field, 0 / 0), nil, field .. ' NaN')
    T.eq(S.validate_override(field, math.huge), nil, field .. ' inf')
    T.eq(S.validate_override(field, -math.huge), nil, field .. ' -inf')
  end
  T.eq(S.validate_override('temperature', 0.5), 0.5, 'control: a finite value passes')
end)

T.case('family patterns with - match literally, not as a Lua quantifier', function()
  T.eq(S.family_from_name('gpt-oss:20b'), 'gpt-oss')
  T.eq(S.family_from_name('gptoss'), nil)
  T.eq(S.family_from_name('gposs'), nil)
  T.eq(S.family_from_name('gemma-4'), 'gemma4')
  T.eq(S.family_from_name('gemma%4'), nil)
  T.eq(S.family_from_name('qwen3x8'), nil)
end)

T.case('counter-check: the untranslated JS source as a Lua pattern matches gposs', function()
  T.ok(('gposs'):find('gpt-oss'))
  T.eq(S._to_lua_pattern('gpt-oss'), 'gpt%-oss')
  T.eq(S._to_lua_pattern('gemma[-_]?4'), 'gemma[%-%_]?4')
  T.eq(S._to_lua_pattern('qwen3\\.8'), 'qwen3%.8')
end)

T.case('a family pattern outside the subset raises instead of matching something else', function()
  T.raises(function()
    S._to_lua_pattern('gpt.oss')
  end, 'unsupported character')
  T.raises(function()
    S._to_lua_pattern('llama\\d')
  end, 'unsupported escape')
  T.raises(function()
    S._to_lua_pattern('a(b)')
  end, 'unsupported character')
end)

T.case('resolve refuses an unknown mode or thinking level', function()
  local ok = { family = nil, mode = 'structured', backend = 'ollama', thinking = 'off' }
  T.ok(S.resolve(ok).params.temperature)
  for k, v in pairs({ mode = 'chat', thinking = 'max' }) do
    local bad = vim.deepcopy(ok)
    bad[k] = v
    T.raises(function()
      S.resolve(bad)
    end, 'unknown')
  end
end)

T.case('resolve treats an unknown backend as unknown and an unknown family as none', function()
  local base = { family = 'qwen3.6', mode = 'structured', backend = 'ollama', thinking = 'low' }
  local known = S.resolve(base)
  T.eq(known.unrecognised, nil)
  T.eq(known.explain[1].fallback, nil)

  local b = vim.deepcopy(base)
  b.backend = 'vllm'
  local rb = S.resolve(b)
  T.eq(rb.unrecognised, { backend = 'vllm' })
  for _, row in ipairs(rb.explain) do
    T.eq(row.fallback, { 'backend' }, row.field)
  end
  -- "unknown" takes the standard fields: the same params as a known standard-only backend
  T.eq(rb.params, known.params)

  local f = vim.deepcopy(base)
  f.family = 'llama'
  local rf = S.resolve(f)
  T.eq(rf.unrecognised, { family = 'llama' })
  T.eq(rf.explain[2].state, 'not-sent-unknown-family', 'no family values')
  for _, row in ipairs(rf.explain) do
    T.eq(row.fallback, { 'family' }, row.field)
  end

  local both = vim.deepcopy(f)
  both.backend = 'vllm'
  local rboth = S.resolve(both)
  T.eq(rboth.unrecognised, { backend = 'vllm', family = 'llama' })
  T.eq(rboth.explain[1].fallback, { 'backend', 'family' })

  -- not an id at all: reported the way JavaScript names it, no exception
  local odd = vim.deepcopy(base)
  odd.backend = 42
  T.eq(S.resolve(odd).unrecognised, { backend = '[object Number]' })
end)

T.case(
  'family_thinking lays the backend over the family; an unknown family gets the generic table',
  function()
    local plain = S.family_thinking('gemma4', nil)
    T.eq(plain.canTurnOff, true)
    T.eq(plain.effort.off.value, 'none')
    local lms = S.family_thinking('gemma4', 'lmstudio')
    T.eq(lms.canTurnOff, false)
    T.eq(lms.effort.off.value, 'low')
    T.eq(lms.reserve.off.value, 1024)
    T.eq(lms.effort.high.value, plain.effort.high.value, "levels not named stay the family's")
    T.eq(S.family_thinking('gemma4', 'ollama').effort.off.value, 'none', 'another backend changes nothing')
    T.eq(S.family_thinking('gemma4', 'no-such-backend').canTurnOff, true)
    local generic = S.family_thinking('llama', 'lmstudio')
    T.eq(generic.canTurnOff, true)
    T.eq(generic.effort.off.value, 'none')
    T.eq(generic.reserve.high.value, 0)
    -- the data tables are not changed by the overlay
    T.eq(S.data.families.gemma4.effort.off.value, 'none')
  end
)

T.case(
  "resolve sends the effort under the backend's own key and drops values the backend does not take",
  function()
    local r = S.resolve({ family = 'qwen3.8', mode = 'agent', backend = 'anthropic', thinking = 'high' })
    T.eq(r.params.reasoning_effort, nil)
    T.eq(r.params.effort, 'xhigh')
    local row
    for _, e in ipairs(r.explain) do
      if e.field == 'reasoning_effort' then
        row = e
      end
    end
    T.eq(row.state, 'sent-unproven')
    local off = S.resolve({ family = 'qwen3.8', mode = 'agent', backend = 'anthropic', thinking = 'off' })
    T.eq(off.params.effort, nil, '"none" is not an effort Anthropic takes')
    T.eq(off.params.reasoning_effort, nil)
  end
)

T.case('for_call picks thinking and overrides for mode × family, "unknown" for an unknown model', function()
  local request = S.sanitize({
    overrides = { structured = { unknown = { temperature = 0.3 }, ['qwen3.6'] = { temperature = 0.05 } } },
    thinking = { structured = 'low' },
  })
  local r = S.for_call({
    request = request,
    mode = 'structured',
    family = nil,
    backend = 'lmstudio',
    max_tokens = 100,
  })
  T.eq(r.params.temperature, 0.3)
  T.eq(r.params.reasoning_effort, 'low')
  local q = S.for_call({ request = request, mode = 'structured', family = 'qwen3.6', backend = 'lmstudio' })
  T.eq(q.params.temperature, 0.05)
  local d =
    S.for_call({ request = S.sanitize(nil), mode = 'structured', family = 'qwen3.6', backend = 'ollama' })
  T.eq(d.params, { temperature = 0.1, top_p = 0.95, reasoning_effort = 'none' })
end)

T.case('the data file sits beside the module, also in a vendored copy', function()
  local root = vim.fn.fnamemodify(here, ':h')
  local plug = vim.fn.tempname()
  vim.fn.mkdir(plug .. '/lua/plug/kit/data', 'p')
  for _, m in ipairs({ 'data', 'sampling' }) do
    vim.fn.writefile(
      vim.fn.readfile(root .. '/lua/nvim_kit/' .. m .. '.lua'),
      plug .. '/lua/plug/kit/' .. m .. '.lua'
    )
  end
  vim.fn.writefile(
    vim.fn.readfile(root .. '/lua/nvim_kit/data/sampling-profiles.json'),
    plug .. '/lua/plug/kit/data/sampling-profiles.json'
  )
  local script = plug .. '/probe.lua'
  vim.fn.writefile({
    ('vim.opt.rtp = { %q, vim.env.VIMRUNTIME }'):format(plug),
    "if pcall(require, 'nvim_kit.sampling') then os.exit(3) end",
    "local S = require('plug.kit.sampling')",
    "os.exit(S.family_from_name('qwen3.6:27b') == 'qwen3.6' and 0 or 2)",
  }, script)
  T.eq(vim.system({ vim.v.progpath, '--headless', '-u', 'NONE', '-l', script }):wait().code, 0)
  -- counter-check: without the data file the require fails loudly
  vim.fn.delete(plug .. '/lua/plug/kit/data', 'rf')
  local r = vim.system({ vim.v.progpath, '--headless', '-u', 'NONE', '-l', script }):wait()
  T.eq(r.code, 1)
  T.ok(r.stderr:find('cannot read', 1, true), r.stderr)
end)
