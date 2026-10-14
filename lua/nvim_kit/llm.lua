-- Talking to an OpenAI-compatible model server (Ollama, LM Studio, Open WebUI, hosted APIs):
-- endpoints in priority order, keys from an environment variable or a command, backend
-- detection, the model list, and an asynchronous, cancellable chat call over `curl`.
-- Knows HOW to ask a model, never WHAT: no prompt, no domain. Errors are values
-- ({ error = kind, detail }), never exceptions; a call with invalid arguments raises.
-- Error kinds: unreachable, timeout, cancelled, key-missing, http, bad-response, no-model,
-- empty, truncated.
local M = {}

-- Relative requires: a vendored copy loads its siblings under lua/<plugin>/kit/.
local prefix = (...):gsub('llm$', '')
local sampling = require(prefix .. 'sampling')
local J = require(prefix .. 'llm_json')

M.first_json_object = J.first_json_object
M.strip_think = J.strip_think

M.DEFAULT_ENDPOINTS = {
  { url = 'http://localhost:11434', name = 'Ollama' },
  { url = 'http://localhost:1234', name = 'LM Studio' },
}
M.PING_TIMEOUT_MS = 3000
M.CHAT_TIMEOUT_MS = 60000
M.KEY_CMD_TIMEOUT_MS = 30000
-- A detected backend is kept this long per URL (code-kit BACKEND_CACHE_MS).
M.BACKEND_CACHE_MS = 30000

local BACKENDS = {}
for _, b in ipairs(sampling.data.backendIds) do
  BACKENDS[b] = true
end

local FIELDS =
  { url = true, name = true, model = true, backend = true, api_key_env = true, api_key_cmd = true }

--- Normalizes a base URL: trailing slashes and one trailing /v1 go (the calls add /v1/… themselves).
function M.normalize_url(url)
  return (vim.trim(url):gsub('/+$', ''):gsub('/v1$', ''):gsub('/+$', ''))
end

local function bad(i, msg)
  error(('nvim-kit llm: endpoints[%d]: %s'):format(i, msg), 3)
end

local function normalize(ep, i)
  if type(ep) ~= 'table' then
    bad(i, 'expected a table')
  end
  for k in pairs(ep) do
    if not FIELDS[k] then
      bad(i, ('unknown field %q'):format(tostring(k)))
    end
  end
  if type(ep.url) ~= 'string' or not ep.url:match('^%s*https?://') then
    bad(i, 'url must be an http(s) URL')
  end
  for _, k in ipairs({ 'name', 'model', 'api_key_env' }) do
    if ep[k] ~= nil and type(ep[k]) ~= 'string' then
      bad(i, k .. ' must be a string')
    end
  end
  if ep.backend ~= nil and not BACKENDS[ep.backend] then
    bad(i, ('unknown backend %q'):format(tostring(ep.backend)))
  end
  if ep.api_key_cmd ~= nil then
    if type(ep.api_key_cmd) ~= 'table' or #ep.api_key_cmd == 0 then
      bad(i, 'api_key_cmd must be a non-empty list of strings')
    end
    for _, a in ipairs(ep.api_key_cmd) do
      if type(a) ~= 'string' then
        bad(i, 'api_key_cmd must be a non-empty list of strings')
      end
    end
  end
  if ep.api_key_env and ep.api_key_cmd then
    bad(i, 'api_key_env and api_key_cmd exclude each other')
  end
  local out = vim.deepcopy(ep)
  out.url = M.normalize_url(ep.url)
  return out
end

--- The endpoint list in priority order, checked and normalized; opts.endpoints or the default
--- (Ollama on :11434, LM Studio on :1234). Raises on an invalid entry, naming index and field.
function M.endpoints(opts)
  local list = opts and opts.endpoints or M.DEFAULT_ENDPOINTS
  if type(list) ~= 'table' or #list == 0 then
    error('nvim-kit llm: endpoints must be a non-empty list', 2)
  end
  local out = {}
  for i, ep in ipairs(list) do
    out[i] = normalize(ep, i)
  end
  return out
end

-- State for the session: keys that were read successfully, detected backends per URL.
local keys, backends = {}, {}

--- Forget cached keys and backends (tests; after the user changed a key).
function M.reset()
  keys, backends = {}, {}
end

local function redact(s, key)
  if not key or key == '' or type(s) ~= 'string' then
    return s
  end
  return (s:gsub(vim.pesc(key), '***'))
end

-- Calls cb on the main loop exactly once, whatever happens.
local function once(cb)
  local done = false
  return function(v)
    if done then
      return
    end
    done = true
    vim.schedule(function()
      cb(v)
    end)
  end
end

-- The API key of an endpoint: cb(key|nil) or cb(nil, err). Never in argv, never in a message.
-- Returns a function that stops a running key command.
local function get_key(ep, cb)
  if not ep.api_key_env and not ep.api_key_cmd then
    cb(nil)
    return function() end
  end
  local id = ep.api_key_env and ('env:' .. ep.api_key_env) or ('cmd:' .. table.concat(ep.api_key_cmd, '\0'))
  if keys[id] then
    cb(keys[id])
    return function() end
  end
  if ep.api_key_env then
    local v = vim.env[ep.api_key_env]
    if v and vim.trim(v) ~= '' then
      keys[id] = vim.trim(v)
      cb(keys[id])
    else
      cb(
        nil,
        { error = 'key-missing', detail = ('environment variable %s is not set'):format(ep.api_key_env) }
      )
    end
    return function() end
  end
  local name = ep.api_key_cmd[1]
  local ok, proc = pcall(
    vim.system,
    ep.api_key_cmd,
    { text = true, timeout = M.KEY_CMD_TIMEOUT_MS },
    function(r)
      vim.schedule(function()
        local v = r.code == 0 and vim.trim(r.stdout or '') or ''
        if v ~= '' then
          keys[id] = v
          cb(v)
        elseif r.code == 124 then
          cb(nil, { error = 'key-missing', detail = ('api_key_cmd %s did not finish in time'):format(name) })
        else
          cb(nil, {
            error = 'key-missing',
            detail = ('api_key_cmd %s exited with %d and no key'):format(name, r.code),
          })
        end
      end)
    end
  )
  if not ok then
    cb(nil, { error = 'key-missing', detail = ('api_key_cmd %s cannot be run'):format(name) })
    return function() end
  end
  return function()
    proc:kill(15)
  end
end

-- curl's configuration language, so header and body travel over stdin, never in argv (`ps`).
local function quote(s)
  return '"' .. s:gsub('\\', '\\\\'):gsub('"', '\\"'):gsub('\n', '\\n'):gsub('\r', '\\r') .. '"'
end

-- curl exit codes that mean "nobody to talk to": proxy, host, connect, TLS handshake, certificate.
-- Any other failure after the connection (18 cut off, 52 empty reply, 56 receive) is a bad response.
local UNREACHABLE = { [5] = true, [6] = true, [7] = true, [35] = true, [60] = true }

-- One HTTP call. cb({ status, body }) or cb({ error = kind, detail }), on the main loop.
-- Returns a function that kills curl.
local function http(ep, key, method, path, body, timeout_ms, cb)
  local cfg = {
    'url = ' .. quote(ep.url .. path),
    'request = ' .. quote(method),
    'header = "Expect:"', -- no 100-continue round trip for large bodies
  }
  if key then
    cfg[#cfg + 1] = 'header = ' .. quote('Authorization: Bearer ' .. key)
  end
  if body then
    cfg[#cfg + 1] = 'header = "Content-Type: application/json"'
    cfg[#cfg + 1] = 'data-binary = ' .. quote(vim.json.encode(body))
  end
  -- -q first: no ~/.curlrc, whose options would change the request.
  local argv = { 'curl', '-q', '-sS', '-K', '-', '-w', '\n%{http_code}' }
  local ok, proc = pcall(
    vim.system,
    argv,
    { stdin = table.concat(cfg, '\n') .. '\n', text = true, timeout = timeout_ms },
    function(r)
      vim.schedule(function()
        if r.code == 124 then
          cb({ error = 'timeout', detail = ('%s%s: no answer within %d ms'):format(ep.url, path, timeout_ms) })
        elseif r.signal ~= 0 then
          cb({ error = 'cancelled', detail = 'stopped' })
        elseif r.code ~= 0 then
          local reason = vim.trim(redact(r.stderr or '', key))
          local kind = r.code == 28 and 'timeout' or UNREACHABLE[r.code] and 'unreachable' or 'bad-response'
          cb({ error = kind, detail = ('%s: %s'):format(ep.url, reason) })
        else
          local out = r.stdout or ''
          local cut = out:match('.*()\n')
          local status = cut and tonumber(out:sub(cut + 1)) or nil
          if not status then
            cb({ error = 'bad-response', detail = ('%s%s: no HTTP status'):format(ep.url, path) })
          else
            cb({ status = status, body = out:sub(1, cut - 1) })
          end
        end
      end)
    end
  )
  if not ok then
    cb({ error = 'unreachable', detail = 'curl cannot be run: ' .. tostring(proc) })
    return function() end
  end
  return function()
    proc:kill(15)
  end
end

local function decode(body)
  local ok, v = pcall(vim.json.decode, body, { luanil = { object = true } })
  if ok and type(v) == 'table' then
    return v
  end
  return nil
end

-- The server's message from an error body (code-kit errorMessageFromBody): error.message, error
-- as a string, message, detail — empty values do not count.
local function error_message(j)
  if type(j) ~= 'table' then
    return nil
  end
  local function str(v)
    return type(v) == 'string' and vim.trim(v) ~= '' and vim.trim(v) or nil
  end
  local e = j.error
  return (type(e) == 'table' and str(e.message)) or str(e) or str(j.message) or str(j.detail)
end

-- An answer is an error when the status says so or, with status 200, when the body carries an
-- `error` field (LM Studio answers unknown paths with 200 and {"error": …}, measured 0.4.x).
local function http_error(res, key)
  local j = decode(res.body)
  if res.status ~= 200 or (j and j.error ~= nil) then
    local msg = error_message(j) or vim.trim(res.body):sub(1, 300)
    return {
      error = 'http',
      status = res.status,
      detail = redact(('HTTP %d: %s'):format(res.status, msg), key),
    },
      j
  end
  return nil, j
end

--- The model ids an endpoint serves (GET /v1/models), in server order.
--- cb(list) or cb({ error = kind, detail }). Returns a handle with :cancel().
function M.models(endpoint, cb, opts)
  local ep = normalize(endpoint, 1)
  cb = once(cb)
  local handle = { stop = function() end }
  function handle.cancel()
    handle.cancelled = true
    handle.stop()
    cb({ error = 'cancelled', detail = 'cancelled' })
  end
  local stop_key = get_key(ep, function(key, err)
    if err then
      return cb(err)
    end
    if handle.cancelled then
      return
    end
    handle.sent = true
    handle.stop = http(
      ep,
      key,
      'GET',
      '/v1/models',
      nil,
      (opts and opts.timeout_ms) or M.PING_TIMEOUT_MS,
      function(res)
        if res.error then
          return cb(res)
        end
        local herr, j = http_error(res, key)
        if herr then
          return cb(herr)
        end
        if not j or type(j.data) ~= 'table' then
          return cb({ error = 'bad-response', detail = ep.url .. '/v1/models: no model list' })
        end
        local ids = {}
        for _, m in ipairs(j.data) do
          if type(m) == 'table' and type(m.id) == 'string' then
            ids[#ids + 1] = m.id
          end
        end
        cb(ids)
      end
    )
  end)
  if not handle.sent then
    handle.stop = stop_key -- a key command may still run; a synchronous key already started curl
  end
  return handle
end

-- Which backend answers at a URL, by a reply only that backend gives. Open WebUI first: it also
-- answers below /api/… (code-kit probeEndpoint). The body decides, not the status.
local PROBES = {
  {
    path = '/api/config',
    backend = 'openwebui',
    test = function(j)
      return type(j.version) == 'string' and type(j.features) == 'table'
    end,
  },
  {
    path = '/api/version',
    backend = 'ollama',
    test = function(j)
      return type(j.version) == 'string' and j.error == nil
    end,
  },
  {
    path = '/api/v0/models',
    backend = 'lmstudio',
    test = function(j)
      return type(j.data) == 'table' and (j.data[1] == nil or type(j.data[1].state) == 'string')
    end,
  },
}

local function detect(ep, key, cb)
  if ep.backend then
    return cb(ep.backend)
  end
  local hit = backends[ep.url]
  if hit and vim.uv.now() - hit.at < M.BACKEND_CACHE_MS then
    return cb(hit.backend)
  end
  local function try(i)
    local probe = PROBES[i]
    if not probe then
      backends[ep.url] = { backend = 'unknown', at = vim.uv.now() }
      return cb('unknown')
    end
    http(ep, key, 'GET', probe.path, nil, M.PING_TIMEOUT_MS, function(res)
      local j = res.body and decode(res.body)
      if j and probe.test(j) then
        backends[ep.url] = { backend = probe.backend, at = vim.uv.now() }
        return cb(probe.backend)
      end
      try(i + 1)
    end)
  end
  try(1)
end

--- Detects the backend of one endpoint (or returns its configured `backend`). cb(backend id).
function M.backend(endpoint, cb)
  local ep = normalize(endpoint, 1)
  get_key(ep, function(key)
    detect(ep, key, function(b)
      vim.schedule(function()
        cb(b)
      end)
    end)
  end)
end

--- The first reachable endpoint, its model, backend and model family.
--- opts = { endpoints = <list|nil>, model = <the plugin's remembered choice|nil> }
--- cb({ endpoint, model, backend, family, models })
---   | cb({ error = 'no-model', detail, endpoint, models })  -- several models, none chosen
---   | cb({ error = kind, detail })
--- The model: the endpoint's own `model`, else opts.model if the server lists it, else the only
--- one listed. Remembering a choice is the plugin's job.
function M.resolve(opts, cb)
  opts = opts or {}
  local eps = M.endpoints(opts)
  cb = once(cb)
  local tried = {}
  local function finish_failed()
    for _, t in ipairs(tried) do
      if t.err.error ~= 'unreachable' and t.err.error ~= 'timeout' then
        return cb(t.err)
      end
    end
    local parts = {}
    for _, t in ipairs(tried) do
      parts[#parts + 1] = ('%s (%s)'):format(t.url, t.err.detail)
    end
    cb({ error = 'unreachable', detail = 'no endpoint answered: ' .. table.concat(parts, '; ') })
  end
  local function try(i)
    local ep = eps[i]
    if not ep then
      return finish_failed()
    end
    M.models(ep, function(list)
      if list.error then
        tried[#tried + 1] = { url = ep.url, err = list }
        return try(i + 1)
      end
      local model = ep.model
      if not model and opts.model and vim.tbl_contains(list, opts.model) then
        model = opts.model
      end
      if not model and #list == 1 then
        model = list[1]
      end
      if not model then
        local why = #list == 0 and 'the server lists no model' or ('%d models, none chosen'):format(#list)
        return cb({
          error = 'no-model',
          detail = ('%s: %s'):format(ep.url, why),
          endpoint = ep,
          models = list,
        })
      end
      M.backend(ep, function(backend)
        cb({
          endpoint = ep,
          model = model,
          backend = backend,
          family = sampling.family_from_name(model),
          models = list,
        })
      end)
    end)
  end
  try(1)
end

--- One chat completion, asynchronous. Returns a handle; handle:cancel() stops it and answers
--- { ok = false, error = 'cancelled' } at once.
--- req = { endpoint, model, messages, mode = 'structured', request = <sampling.sanitize result|nil>,
---         backend = <id|nil, else detected>, family = <id|nil, else from the model name>,
---         max_tokens = <n|nil>, timeout_ms = <n|nil> }
--- cb({ ok = true, content, reasoning, finish_reason, params })
---   | cb({ ok = false, error = kind, detail, status?, content?, reasoning? })
--- `content` is the text as the model sent it, <think> blocks included; read it with
--- first_json_object or strip_think. A 200 without visible text is `empty`, or `truncated` when
--- the token limit cut it off.
function M.chat(req, cb)
  if type(req) ~= 'table' or type(req.endpoint) ~= 'table' or type(req.model) ~= 'string' then
    error('nvim-kit llm: chat needs req.endpoint (table) and req.model (string)', 2)
  end
  if type(req.messages) ~= 'table' or #req.messages == 0 then
    error('nvim-kit llm: chat needs req.messages (a non-empty list)', 2)
  end
  local mode = req.mode or 'structured'
  if req.request ~= nil then
    local _, dropped = sampling.sanitize(req.request)
    if #dropped > 0 then
      error(
        'nvim-kit llm: req.request has invalid fields (sanitize and report them first): '
          .. table.concat(dropped, ', '),
        2
      )
    end
  end
  local ep = normalize(req.endpoint, 1)
  local timeout_ms = req.timeout_ms or M.CHAT_TIMEOUT_MS
  local finish = once(cb)
  local handle = { stop = function() end }
  function handle.cancel()
    handle.cancelled = true
    handle.stop()
    finish({ ok = false, error = 'cancelled', detail = 'cancelled' })
  end
  local function fail(e)
    e.ok = false
    finish(e)
  end
  local stop_key = get_key(ep, function(key, kerr)
    if kerr then
      return fail(kerr)
    end
    local function send(backend)
      if handle.cancelled then
        return
      end
      handle.sent = true
      local family = req.family or sampling.family_from_name(req.model)
      local params = sampling.for_call({
        request = req.request,
        mode = mode,
        family = family,
        backend = backend,
        max_tokens = req.max_tokens,
      }).params
      local body =
        vim.tbl_extend('force', params, { model = req.model, messages = req.messages, stream = false })
      handle.stop = http(ep, key, 'POST', '/v1/chat/completions', body, timeout_ms, function(res)
        if res.error then
          return fail(res)
        end
        local herr, j = http_error(res, key)
        if herr then
          return fail(herr)
        end
        local choice = j and type(j.choices) == 'table' and j.choices[1] or nil
        local msg = type(choice) == 'table' and choice.message or nil
        if type(msg) ~= 'table' then
          return fail({
            error = 'bad-response',
            detail = 'no choices[1].message: ' .. vim.trim(res.body):sub(1, 200),
          })
        end
        local content = type(msg.content) == 'string' and msg.content or ''
        local reasoning = msg.reasoning_content or msg.reasoning
        reasoning = type(reasoning) == 'string' and reasoning or ''
        local finish_reason = type(choice.finish_reason) == 'string' and choice.finish_reason or nil
        local visible = vim.trim(J.strip_think(content, { drop_stray_close = true, drop_unclosed = true }))
        if visible == '' then
          return fail({
            error = finish_reason == 'length' and 'truncated' or 'empty',
            detail = finish_reason == 'length' and 'the token limit ended the answer before any text'
              or 'the answer has no text',
            content = content,
            reasoning = reasoning,
          })
        end
        finish({
          ok = true,
          content = content,
          reasoning = reasoning,
          finish_reason = finish_reason,
          params = params,
        })
      end)
    end
    if req.backend then
      send(req.backend)
    else
      detect(ep, key, send)
    end
  end)
  if not handle.sent then
    handle.stop = stop_key
  end
  return handle
end

return M
