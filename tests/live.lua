-- Live run against a real model server — not part of `make check` (CORE-TEST-02).
--   make live                                   -- default endpoints (Ollama :11434, LM Studio :1234)
--   LLM_LIVE_URL=http://host:1234 LLM_LIVE_MODEL=google/gemma-4-e2b make live
-- Exit 0: a structured answer came back and parsed. Exit 1: something failed. Exit 2: nothing was
-- measured (no server reachable, or several models and none named) — loud, never a pass.
local root = vim.fn.fnamemodify(debug.getinfo(1, 'S').source:sub(2), ':p:h:h')
vim.opt.rtp:prepend(root)
local L = require('nvim_kit.llm')

local function out(line)
  io.write(line, '\n')
end

local function await(start, ms)
  local result
  start(function(v)
    result = v
  end)
  vim.wait(ms, function()
    return result ~= nil
  end, 20)
  return result
end

local endpoints = vim.env.LLM_LIVE_URL and { { url = vim.env.LLM_LIVE_URL } } or nil
local r = await(function(cb)
  L.resolve({ endpoints = endpoints, model = vim.env.LLM_LIVE_MODEL }, cb)
end, 30000)
if not r or r.error then
  local list = r and r.models and table.concat(r.models, ', ') or ''
  out(
    ('live: NOTHING MEASURED — %s: %s %s'):format(r and r.error or 'no answer', r and r.detail or '', list)
  )
  out('live: set LLM_LIVE_URL and/or LLM_LIVE_MODEL')
  os.exit(2)
end
out(
  ('live: %s · backend %s · model %s · family %s'):format(
    r.endpoint.url,
    r.backend,
    r.model,
    tostring(r.family)
  )
)

local t0 = vim.uv.hrtime()
local c = await(function(cb)
  L.chat({
    endpoint = r.endpoint,
    model = r.model,
    backend = r.backend,
    mode = 'structured',
    max_tokens = 200,
    timeout_ms = 300000,
    messages = {
      {
        role = 'system',
        content = 'Answer with exactly one JSON object {"answer": <string>} and nothing else.',
      },
      { role = 'user', content = 'What is the capital of France?' },
    },
  }, cb)
end, 310000)
local ms = (vim.uv.hrtime() - t0) / 1e6
if not c or not c.ok then
  out(('live: FAIL chat — %s: %s'):format(c and c.error or 'no answer', c and c.detail or ''))
  os.exit(1)
end
out(
  ('live: chat %d ms · finish %s · params %s'):format(
    ms,
    tostring(c.finish_reason),
    vim.json.encode(c.params)
  )
)
local obj = L.first_json_object(c.content)
if type(obj) ~= 'table' or type(obj.answer) ~= 'string' then
  out('live: FAIL — no {"answer": …} in: ' .. c.content:sub(1, 300))
  os.exit(1)
end
out('live: ok — answer: ' .. obj.answer)
os.exit(0)
