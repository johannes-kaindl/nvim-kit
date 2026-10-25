local T = require('nvim_kit.test')
local C = require('nvim_kit.conformance')
local L = require('nvim_kit.llm')
local S = require('nvim_kit.sampling')
local stub = require('nvim_kit.http_stub')

-- Runs an async call and waits for its single answer; counts how often the callback fired.
local function await(start, ms)
  local result, calls = nil, 0
  start(function(v)
    calls = calls + 1
    result = v
  end)
  -- not wait.result: these helpers count the callback calls to catch a double answer
  vim.wait(ms or 5000, function()
    return result ~= nil
  end, 5)
  return result, function()
    return calls
  end
end

local MODELS = { body = { data = { { id = 'qwen3.6:27b' } } } }
local function chat_ok(content, extra)
  local message = vim.tbl_extend('force', { role = 'assistant', content = content }, extra or {})
  return { body = { choices = { { message = message, finish_reason = 'stop' } } } }
end
local function msgs()
  return { { role = 'user', content = 'hi' } }
end
-- A port where nothing listens: a stub that was closed again.
local function dead_url()
  local s = stub.start({})
  s.close()
  return s.url
end

T.case('endpoints: the default is Ollama, then LM Studio; URLs are normalized', function()
  local d = L.endpoints()
  T.eq({ d[1].url, d[2].url }, { 'http://localhost:11434', 'http://localhost:1234' })
  T.eq(L.endpoints({ endpoints = { { url = ' http://h:1234/v1/ ' } } })[1].url, 'http://h:1234')
  T.eq(L.normalize_url('http://h/v1'), 'http://h')
end)

T.case('normalize_url passes every code-kit normalizeEndpoint vector', function()
  local here = vim.fn.fnamemodify(debug.getinfo(1, 'S').source:sub(2), ':p:h')
  local v = C.load_dir(here .. '/conformance/code-kit')
  local adapters = dofile(here .. '/adapters/llm.lua')
  T.ok(v.normalizeEndpoint, 'no vector file for normalizeEndpoint')
  T.eq(#v.normalizeEndpoint.cases, 7)
  T.eq(C.run(v.normalizeEndpoint, adapters.normalizeEndpoint), {})
  -- counter-check: a normalizer that keeps the trailing /v1 fails the vectors
  local failures = C.run(v.normalizeEndpoint, function(url)
    return (vim.trim(url):gsub('/+$', ''))
  end)
  T.ok(#failures > 0)
end)

T.case('backend anthropic is refused: llm talks to /v1/chat/completions only', function()
  local msg = "use backend = 'openai'"
  T.raises(function()
    L.endpoints({ endpoints = { { url = 'http://x', backend = 'anthropic' } } })
  end, msg)
  T.raises(function()
    L.chat(
      { endpoint = { url = 'http://x' }, model = 'm', messages = msgs(), backend = 'anthropic' },
      function() end
    )
  end, msg)
  T.raises(function()
    L.chat(
      { endpoint = { url = 'http://x', backend = 'anthropic' }, model = 'm', messages = msgs() },
      function() end
    )
  end, msg)
  -- control: the advised backend passes the same door
  T.eq(L.endpoints({ endpoints = { { url = 'http://x', backend = 'openai' } } })[1].backend, 'openai')
end)

T.case('endpoints: an invalid entry raises, naming index and field', function()
  local cases = {
    { { url = 'localhost:1234' }, 'endpoints[2]: url' },
    { { url = 'http://a', colour = 1 }, 'unknown field "colour"' },
    { { url = 'http://a', backend = 'vllm' }, 'unknown backend' },
    { { url = 'http://a', api_key_env = 'K', api_key_cmd = { 'pass' } }, 'exclude each other' },
    { { url = 'http://a', api_key_cmd = 'pass show x' }, 'api_key_cmd' },
  }
  for _, c in ipairs(cases) do
    T.raises(function()
      L.endpoints({ endpoints = { { url = 'http://ok' }, c[1] } })
    end, c[2])
  end
  T.raises(function()
    L.endpoints({ endpoints = { { url = 'http://ok' }, { url = 'nope' } } })
  end, 'endpoints[2]')
end)

T.case('models lists the ids in server order', function()
  local srv = stub.start({ ['GET /v1/models'] = { body = { data = { { id = 'b' }, { id = 'a' } } } } })
  local r = await(function(cb)
    L.models({ url = srv.url }, cb)
  end)
  srv.close()
  T.eq(r, { 'b', 'a' })
end)

T.case('the key goes over stdin: in the request header, never in curl argv', function()
  L.reset()
  vim.env.NVIM_KIT_TEST_KEY = 'sk-test-0123456789'
  local srv = stub.start({ ['GET /v1/models'] = MODELS })
  local real = vim.system
  local seen = {}
  vim.system = function(cmd, opts, on_exit)
    seen[#seen + 1] = { argv = table.concat(cmd, ' '), stdin = opts and opts.stdin or '' }
    return real(cmd, opts, on_exit)
  end
  local r = await(function(cb)
    L.models({ url = srv.url, api_key_env = 'NVIM_KIT_TEST_KEY' }, cb)
  end)
  vim.system = real
  srv.close()
  T.eq(r, { 'qwen3.6:27b' })
  T.eq(srv.requests[1].headers.authorization, 'Bearer sk-test-0123456789')
  T.ok(#seen > 0)
  for _, s in ipairs(seen) do
    T.eq(s.argv:find('sk-test', 1, true), nil, 'key in argv: ' .. s.argv)
  end
  -- counter-check: the capture sees what goes over stdin
  T.ok(seen[1].stdin:find('sk-test-0123456789', 1, true))
end)

T.case('a missing key is key-missing, before any request', function()
  L.reset()
  vim.env.NVIM_KIT_TEST_UNSET = nil
  local srv = stub.start({ ['GET /v1/models'] = MODELS })
  local r = await(function(cb)
    L.models({ url = srv.url, api_key_env = 'NVIM_KIT_TEST_UNSET' }, cb)
  end)
  srv.close()
  T.eq(r.error, 'key-missing')
  T.ok(r.detail:find('NVIM_KIT_TEST_UNSET', 1, true))
  T.eq(#srv.requests, 0)
end)

T.case('api_key_cmd: the trimmed output is the key, read once per session', function()
  L.reset()
  local count = vim.fn.tempname()
  local srv = stub.start({ ['GET /v1/models'] = MODELS })
  local ep = { url = srv.url, api_key_cmd = { 'sh', '-c', 'echo x >> ' .. count .. '; printf "sk-cmd\\n"' } }
  for _ = 1, 2 do
    await(function(cb)
      L.models(ep, cb)
    end)
  end
  srv.close()
  T.eq(srv.requests[2].headers.authorization, 'Bearer sk-cmd')
  T.eq(#vim.fn.readfile(count), 1)
end)

T.case('api_key_cmd: a failing or missing command is key-missing, without its output', function()
  L.reset()
  local srv = stub.start({ ['GET /v1/models'] = MODELS })
  local failing = await(function(cb)
    L.models({ url = srv.url, api_key_cmd = { 'sh', '-c', 'printf secret-out; exit 3' } }, cb)
  end)
  local missing = await(function(cb)
    L.models({ url = srv.url, api_key_cmd = { 'nvim-kit-no-such-command' } }, cb)
  end)
  srv.close()
  T.eq(failing.error, 'key-missing')
  T.ok(failing.detail:find('exited with 3', 1, true))
  T.eq(failing.detail:find('secret-out', 1, true), nil)
  T.eq(missing.error, 'key-missing')
  T.eq(#srv.requests, 0)
end)

T.case('a server message that echoes the key is redacted', function()
  L.reset()
  vim.env.NVIM_KIT_TEST_KEY = 'sk-echo-42'
  local srv = stub.start({
    ['GET /v1/models'] = { status = 401, body = { error = { message = 'bad key sk-echo-42' } } },
  })
  local r = await(function(cb)
    L.models({ url = srv.url, api_key_env = 'NVIM_KIT_TEST_KEY' }, cb)
  end)
  srv.close()
  T.eq(r.error, 'http')
  T.eq(r.status, 401)
  T.eq(r.detail, 'HTTP 401: bad key ***')
end)

T.case('~/.curlrc does not reach the request (curl -q)', function()
  local home = vim.fn.tempname()
  vim.fn.mkdir(home, 'p')
  vim.fn.writefile({ 'header = "X-Curlrc: leaked"' }, home .. '/.curlrc')
  local old = vim.env.CURL_HOME
  vim.env.CURL_HOME = home
  local srv = stub.start({ ['GET /v1/models'] = MODELS })
  await(function(cb)
    L.models({ url = srv.url }, cb)
  end)
  -- counter-check: plain curl does read that file
  vim.system({ 'curl', '-sS', srv.url .. '/v1/models' }):wait()
  vim.env.CURL_HOME = old
  srv.close()
  T.eq(srv.requests[1].headers['x-curlrc'], nil)
  T.eq(srv.requests[2].headers['x-curlrc'], 'leaked')
end)

T.case('resolve: the first reachable endpoint wins', function()
  L.reset()
  local srv = stub.start({ ['GET /v1/models'] = MODELS })
  local r = await(function(cb)
    L.resolve({ endpoints = { { url = dead_url() }, { url = srv.url, backend = 'ollama' } } }, cb)
  end)
  srv.close()
  T.eq(r.endpoint.url, srv.url)
  T.eq(r.model, 'qwen3.6:27b')
  T.eq(r.backend, 'ollama')
  T.eq(r.family, 'qwen3.6')
end)

T.case(
  'resolve: model choice — endpoint model, remembered model if listed, the only one, else no-model',
  function()
    L.reset()
    local srv = stub.start({ ['GET /v1/models'] = { body = { data = { { id = 'a' }, { id = 'b' } } } } })
    local function run(ep, opts)
      return await(function(cb)
        L.resolve(vim.tbl_extend('force', { endpoints = { ep } }, opts or {}), cb)
      end)
    end
    local base = { url = srv.url, backend = 'unknown' }
    T.eq(run(vim.tbl_extend('force', base, { model = 'c' })).model, 'c')
    T.eq(run(base, { model = 'b' }).model, 'b')
    local none = run(base, { model = 'gone' })
    T.eq(none.error, 'no-model')
    T.eq(none.models, { 'a', 'b' })
    T.eq(none.endpoint.url, srv.url)
    srv.close()
  end
)

T.case('resolve: nothing reachable names every URL; a key problem wins over unreachable', function()
  L.reset()
  local a, b = dead_url(), dead_url()
  local r = await(function(cb)
    L.resolve({ endpoints = { { url = a }, { url = b } } }, cb)
  end)
  T.eq(r.error, 'unreachable')
  T.ok(r.detail:find(a, 1, true) and r.detail:find(b, 1, true), r.detail)
  local k = await(function(cb)
    L.resolve({ endpoints = { { url = a }, { url = b, api_key_env = 'NVIM_KIT_TEST_UNSET' } } }, cb)
  end)
  T.eq(k.error, 'key-missing')
end)

T.case('backend detection by a reply only that backend gives', function()
  local cases = {
    {
      'ollama',
      { ['GET /api/version'] = { body = { version = '0.12.0' } } },
    },
    {
      -- LM Studio answers unknown paths with 200 and an error body (measured, LM Studio 0.4.x)
      'lmstudio',
      {
        ['GET /api/config'] = { body = { error = 'Unexpected endpoint or method. (GET /api/config)' } },
        ['GET /api/version'] = { body = { error = 'Unexpected endpoint or method. (GET /api/version)' } },
        ['GET /api/v0/models'] = { body = { data = { { id = 'm', type = 'llm', state = 'not-loaded' } } } },
      },
    },
    {
      -- Open WebUI also has /api/version; /api/config is asked first
      'openwebui',
      {
        ['GET /api/config'] = { body = { version = '0.11.3', features = {} } },
        ['GET /api/version'] = { body = { version = '0.11.3' } },
      },
    },
    { 'unknown', {} },
  }
  for _, c in ipairs(cases) do
    L.reset()
    local srv = stub.start(c[2])
    local b = await(function(cb)
      L.backend({ url = srv.url }, cb)
    end)
    srv.close()
    T.eq(b, c[1])
  end
end)

T.case('a configured backend sends no probe; a detected one is kept per URL', function()
  L.reset()
  local srv = stub.start({ ['GET /api/version'] = { body = { version = '1' } } })
  T.eq(
    await(function(cb)
      L.backend({ url = srv.url, backend = 'openai' }, cb)
    end),
    'openai'
  )
  T.eq(#srv.requests, 0)
  for _ = 1, 2 do
    await(function(cb)
      L.backend({ url = srv.url }, cb)
    end)
  end
  srv.close()
  T.eq(#srv.requests, 2, 'one probe run: /api/config, /api/version')
end)

T.case('chat sends model, messages and the profile for mode × family × backend', function()
  local srv = stub.start({ ['POST /v1/chat/completions'] = chat_ok('{"a":1}') })
  local function body_for(backend)
    srv.requests = {}
    await(function(cb)
      L.chat(
        { endpoint = { url = srv.url }, model = 'qwen3.6:27b', messages = msgs(), backend = backend },
        cb
      )
    end)
    return vim.json.decode(srv.requests[1].body)
  end
  local lms = body_for('lmstudio')
  local oll = body_for('ollama')
  srv.close()
  T.eq(lms.model, 'qwen3.6:27b')
  T.eq(lms.messages, msgs())
  T.eq(lms.stream, false)
  T.eq(lms.temperature, 0.1)
  T.eq(lms.top_k, 20)
  T.eq(oll.top_k, nil, 'Ollama takes standard fields only')
  T.eq(oll.reasoning_effort, 'none')
end)

T.case('chat answers on the main loop with content, reasoning and finish_reason', function()
  local srv = stub.start({
    ['POST /v1/chat/completions'] = chat_ok('<think>x</think>{"a":1}', { reasoning_content = 'r' }),
  })
  local r = await(function(cb)
    L.chat({ endpoint = { url = srv.url }, model = 'm', messages = msgs(), backend = 'unknown' }, function(v)
      vim.api.nvim_buf_set_lines(0, 0, -1, false, { 'callback may use the API' }) -- E5560 in a fast event
      cb(v)
    end)
  end)
  srv.close()
  T.eq(r.ok, true)
  T.eq(r.content, '<think>x</think>{"a":1}')
  T.eq(r.reasoning, 'r')
  T.eq(r.finish_reason, 'stop')
  T.eq(L.first_json_object(r.content), { a = 1 })
end)

T.case(
  'chat errors are values: http, 200 with an error body, a text error page, empty, truncated, cut off',
  function()
    local routes = {
      ['POST /http'] = { status = 500, body = { error = { message = 'model not found' } } },
      ['POST /err200'] = { body = { error = 'Unexpected endpoint' } },
      ['POST /badgateway'] = { status = 502, body = 'Bad Gateway' },
      ['POST /empty'] = chat_ok('  '),
      ['POST /trunc'] = {
        body = { choices = { { message = { content = '<think>long' }, finish_reason = 'length' } } },
      },
      ['POST /cut'] = { raw = 'HTTP/1.1 200 OK\r\nContent-Length: 500\r\n\r\n{"choi' },
    }
    local srv = stub.start({})
    local expect = {
      http = 'http',
      err200 = 'http',
      badgateway = 'http',
      empty = 'empty',
      trunc = 'truncated',
      cut = 'bad-response',
    }
    for name, kind in pairs(expect) do
      srv.close()
      srv = stub.start({ ['POST /v1/chat/completions'] = routes['POST /' .. name] })
      local r = await(function(cb)
        L.chat({ endpoint = { url = srv.url }, model = 'm', messages = msgs(), backend = 'unknown' }, cb)
      end)
      T.eq(r.ok, false, name)
      T.eq(r.error, kind, name .. ': ' .. tostring(r.detail))
    end
    srv.close()
  end
)

T.case('chat: a 200 that is not JSON is bad-response', function()
  local srv = stub.start({
    ['POST /v1/chat/completions'] = { raw = 'HTTP/1.1 200 OK\r\nContent-Length: 4\r\n\r\nnope' },
  })
  local r = await(function(cb)
    L.chat({ endpoint = { url = srv.url }, model = 'm', messages = msgs(), backend = 'unknown' }, cb)
  end)
  srv.close()
  T.eq(r.error, 'bad-response')
end)

T.case('chat: no answer within timeout_ms is timeout', function()
  local srv = stub.start({ ['POST /v1/chat/completions'] = { hang = true } })
  local t0 = vim.uv.hrtime()
  local r = await(function(cb)
    L.chat(
      { endpoint = { url = srv.url }, model = 'm', messages = msgs(), backend = 'unknown', timeout_ms = 300 },
      cb
    )
  end)
  local ms = (vim.uv.hrtime() - t0) / 1e6
  srv.close()
  T.eq(r.error, 'timeout')
  T.ok(ms >= 250 and ms < 3000, ('%d ms'):format(ms))
end)

T.case('cancel answers cancelled at once and the callback fires exactly once', function()
  local srv = stub.start({ ['POST /v1/chat/completions'] = { hang = true } })
  local handle
  local r, calls = await(function(cb)
    handle = L.chat({ endpoint = { url = srv.url }, model = 'm', messages = msgs(), backend = 'unknown' }, cb)
    vim.defer_fn(function()
      handle.cancel()
    end, 100)
  end)
  vim.wait(300)
  srv.close()
  T.eq(r.error, 'cancelled')
  T.eq(calls(), 1)
end)

T.case('cancel before the backend is known sends no chat request', function()
  L.reset()
  local ping = L.PING_TIMEOUT_MS
  L.PING_TIMEOUT_MS = 200
  local srv = stub.start({ ['GET /api/config'] = { hang = true } })
  local handle = L.chat({ endpoint = { url = srv.url }, model = 'm', messages = msgs() }, function() end)
  handle.cancel()
  vim.wait(1500, function()
    return #srv.requests >= 3 -- all probes ran (the first timed out)
  end)
  L.PING_TIMEOUT_MS = ping
  srv.close()
  T.eq(#srv.requests, 3, 'control: detection went on, so a chat could have been sent')
  for _, req in ipairs(srv.requests) do
    T.ok(req.path ~= '/v1/chat/completions', 'chat was sent after cancel')
  end
end)

T.case('chat refuses invalid arguments and an unsanitized request loudly', function()
  T.raises(function()
    L.chat({ model = 'm', messages = msgs() }, function() end)
  end, 'req.endpoint')
  T.raises(function()
    L.chat({ endpoint = { url = 'http://x' }, model = 'm', messages = {} }, function() end)
  end, 'req.messages')
  T.raises(function()
    L.chat({
      endpoint = { url = 'http://x' },
      model = 'm',
      messages = msgs(),
      request = { overrides = { structured = { unknown = { temperature = 9 } } } },
    }, function() end)
  end, 'overrides.structured.unknown.temperature')
  -- counter-check: a sanitized request is taken
  local srv = stub.start({ ['POST /v1/chat/completions'] = chat_ok('ok') })
  local r = await(function(cb)
    L.chat({
      endpoint = { url = srv.url },
      model = 'm',
      messages = msgs(),
      backend = 'unknown',
      request = S.sanitize({ overrides = { structured = { unknown = { temperature = 0.3 } } } }),
    }, cb)
  end)
  srv.close()
  T.eq(r.ok, true)
  T.eq(r.params.temperature, 0.3)
end)

-- Review findings 2026-10-14 (0.8.0 branch review): redaction before cutting, arguments checked
-- before any key or probe, resolve stops at an endpoint that answered, a cancelled key command
-- caches nothing, a malformed probe body does not hang detection.

T.case('a key straddling the cut of a long error body is redacted whole', function()
  L.reset()
  local key = 'sk-ABCDEFGHIJKLMNOPQRSTUVWXYZ'
  vim.env.NVIM_KIT_TEST_KEY = key
  local srv = stub.start({
    ['GET /v1/models'] = { status = 401, body = ('x'):rep(280) .. ' key=' .. key .. ' rest' },
  })
  local r = await(function(cb)
    L.models({ url = srv.url, api_key_env = 'NVIM_KIT_TEST_KEY' }, cb)
  end)
  srv.close()
  T.eq(r.error, 'http')
  T.eq(r.detail:find('sk-', 1, true), nil, r.detail)
  T.ok(r.detail:find('key=***', 1, true), r.detail)
end)

T.case('chat: a bad-response detail that echoes the key is redacted', function()
  L.reset()
  vim.env.NVIM_KIT_TEST_KEY = 'sk-echo-43'
  local srv = stub.start({ ['POST /v1/chat/completions'] = { body = { msg = 'hello sk-echo-43' } } })
  local r = await(function(cb)
    L.chat({
      endpoint = { url = srv.url, api_key_env = 'NVIM_KIT_TEST_KEY' },
      model = 'm',
      messages = msgs(),
      backend = 'unknown',
    }, cb)
  end)
  srv.close()
  T.eq(r.error, 'bad-response')
  T.eq(r.detail:find('sk-echo-43', 1, true), nil, r.detail)
end)

T.case('chat: an unknown mode, backend or family raises at once, also with a key command', function()
  local ep = { url = 'http://127.0.0.1:9', api_key_cmd = { 'sh', '-c', 'printf k' } }
  T.raises(function()
    L.chat({ endpoint = ep, model = 'm', messages = msgs(), mode = 'Structured' }, function() end)
  end, 'unknown req.mode "Structured"')
  T.raises(function()
    L.chat({ endpoint = ep, model = 'm', messages = msgs(), backend = 'lm-studio' }, function() end)
  end, 'unknown req.backend "lm-studio"')
  T.raises(function()
    L.chat({ endpoint = ep, model = 'm', messages = msgs(), family = 'llama' }, function() end)
  end, 'unknown req.family "llama"')
end)

T.case('chat: a messages entry that is not a table raises at once', function()
  -- the message text is cleaned inside a callback, where this failed and cb never answered
  -- (review finding M6)
  local ep = { url = 'http://127.0.0.1:9', api_key_cmd = { 'sh', '-c', 'printf k' } }
  T.raises(function()
    L.chat({ endpoint = ep, model = 'm', messages = { 42 } }, function() end)
  end, 'req.messages[1]')
  T.raises(function()
    L.chat({ endpoint = ep, model = 'm', messages = { msgs()[1], 'hi' } }, function() end)
  end, 'req.messages[2]')
end)

T.case('resolve: an endpoint that answers with an error ends the search, the next is not asked', function()
  L.reset()
  local bad = stub.start({ ['GET /v1/models'] = { status = 401, body = { error = 'invalid key' } } })
  local good = stub.start({ ['GET /v1/models'] = MODELS })
  local r = await(function(cb)
    L.resolve({ endpoints = { { url = bad.url }, { url = good.url, backend = 'ollama' } } }, cb)
  end)
  vim.env.NVIM_KIT_TEST_UNSET = nil
  local k = await(function(cb)
    L.resolve({
      endpoints = {
        { url = bad.url, api_key_env = 'NVIM_KIT_TEST_UNSET' },
        { url = good.url, backend = 'ollama' },
      },
    }, cb)
  end)
  bad.close()
  good.close()
  T.eq(r.error, 'http')
  T.eq(r.status, 401)
  T.ok(r.detail:find(bad.url, 1, true) and r.detail:find('invalid key', 1, true), r.detail)
  T.eq(r.endpoint.url, bad.url)
  T.eq(k.error, 'key-missing')
  T.eq(#good.requests, 0)
end)

T.case('api_key_cmd: a command stopped by cancel leaves no key behind', function()
  L.reset()
  local srv = stub.start({ ['GET /v1/models'] = MODELS })
  -- The first run prints half a key and is stopped; `exec` so the kill reaches the process that
  -- holds the pipe (a shell's child would keep it open). A second run prints the whole key.
  local mark = vim.fn.tempname()
  local script = ('if [ -f %s ]; then printf sk-full; else touch %s; printf sk-par; exec sleep 2; fi'):format(
    mark,
    mark
  )
  local ep = { url = srv.url, api_key_cmd = { 'sh', '-c', script } }
  local first
  local h = L.models(ep, function(v)
    first = v
  end)
  vim.wait(300)
  h.cancel()
  vim.wait(500) -- the killed command reports back (code 0, signal 15)
  local r = await(function(cb)
    L.models(ep, cb)
  end, 5000)
  srv.close()
  T.eq(first.error, 'cancelled')
  T.eq(r, { 'qwen3.6:27b' })
  T.eq(srv.requests[1].headers.authorization, 'Bearer sk-full')
end)

T.case('backend detection answers unknown for a malformed probe body instead of hanging', function()
  L.reset()
  local srv = stub.start({
    ['GET /api/v0/models'] = { body = { data = { 1 } } },
  })
  local srv2 = stub.start({
    ['GET /api/v0/models'] = { raw = 'HTTP/1.1 200 OK\r\nContent-Length: 15\r\n\r\n{"data":[null]}' },
  })
  local b1 = await(function(cb)
    L.backend({ url = srv.url }, cb)
  end)
  local b2 = await(function(cb)
    L.backend({ url = srv2.url }, cb)
  end)
  srv.close()
  srv2.close()
  T.eq(b1, 'unknown')
  T.eq(b2, 'unknown')
end)

T.case('chat: message text that is not UTF-8 is sent as U+FFFD, so the body stays JSON', function()
  local srv = stub.start({ ['POST /v1/chat/completions'] = chat_ok('{"a":1}') })
  local r = await(function(cb)
    L.chat({
      endpoint = { url = srv.url },
      model = 'qwen3.6:27b',
      backend = 'ollama',
      messages = { { role = 'user', content = 'caf\233 \255' } },
    }, cb)
  end)
  srv.close()
  T.eq(r.ok, true)
  local body = srv.requests[1].body
  T.ok(require('nvim_kit.llm_json').is_strict_json(body), body)
  T.eq(vim.json.decode(body).messages[1].content, 'caf\239\191\189 \239\191\189')
end)
