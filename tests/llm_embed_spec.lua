local T = require('nvim_kit.test')
local L = require('nvim_kit.llm')
local stub = require('nvim_kit.http_stub')

-- Runs an async call and waits for its single answer; counts how often the callback fired.
local function await(start, ms)
  local result, calls = nil, 0
  start(function(v)
    calls = calls + 1
    result = v
  end)
  vim.wait(ms or 5000, function()
    return result ~= nil
  end, 5)
  return result, function()
    return calls
  end
end

local function dead_url()
  local s = stub.start({})
  s.close()
  return s.url
end

local function texts(n)
  local t = {}
  for i = 1, n do
    t[i] = 'note ' .. i
  end
  return t
end

-- The vector of a text is { n } for 'note n', so an answer shows which text it belongs to.
local function vec(s)
  return { tonumber(s:match('%d+')) }
end

-- A server that answers each request with one vector per input; `shape` may change the answer.
local function server(shape)
  local srv
  srv = stub.start({
    ['POST /v1/embeddings'] = function(req)
      local body = vim.json.decode(req.body)
      local data = {}
      for i, s in ipairs(body.input) do
        data[i] = { object = 'embedding', index = i - 1, embedding = vec(s) }
      end
      if shape then
        data = shape(data, #srv.requests, body) or data
      end
      return { body = { data = data } }
    end,
  })
  return srv
end

local function embed(srv_url, input, extra)
  return await(function(cb)
    L.embed(
      vim.tbl_extend('force', { endpoint = { url = srv_url }, model = 'emb', input = input }, extra or {}),
      cb
    )
  end)
end

local function sizes(srv)
  local out = {}
  for i, r in ipairs(srv.requests) do
    out[i] = #vim.json.decode(r.body).input
  end
  return out
end

T.case('embed: 70 texts go out in groups of 32, 32, 6, vectors in input order', function()
  local srv = server()
  local r = embed(srv.url, texts(70))
  srv.close()
  T.eq(r.ok, true)
  T.eq(sizes(srv), { 32, 32, 6 })
  T.eq(#r.vectors, 70)
  for i = 1, 70 do
    T.eq(r.vectors[i], { i }, 'vector ' .. i)
  end
  T.eq(srv.requests[1].path, '/v1/embeddings')
  T.eq(vim.json.decode(srv.requests[1].body).model, 'emb')
end)

T.case('embed: batch_size sets the group size', function()
  local srv = server()
  local r = embed(srv.url, texts(5), { batch_size = 2 })
  srv.close()
  T.eq(r.ok, true)
  T.eq(sizes(srv), { 2, 2, 1 })
end)

T.case('embed: the position in data counts, not the index field (as code-kit)', function()
  local srv = server(function(data)
    return { data[2], data[1] } -- reversed, with their own index fields
  end)
  local r = embed(srv.url, texts(2))
  srv.close()
  T.eq(r.ok, true)
  T.eq(r.vectors, { { 2 }, { 1 } })
end)

T.case('embed: 31 vectors for 32 texts is bad-response, no partial result', function()
  local srv = server(function(data, n)
    if n == 2 then
      table.remove(data) -- the second group comes back one short
    end
  end)
  local r, calls = embed(srv.url, texts(70))
  vim.wait(200)
  srv.close()
  T.eq(r.ok, false)
  T.eq(r.error, 'bad-response')
  T.eq(r.vectors, nil)
  T.ok(r.detail:find('group 2 of 3', 1, true), r.detail)
  T.ok(r.detail:find('expected 32', 1, true), r.detail)
  T.ok(r.detail:find('received 31', 1, true), r.detail)
  T.eq(#srv.requests, 2, 'the third group must not be asked after the failure')
  T.eq(calls(), 1)
end)

T.case('embed: more vectors than texts is bad-response too', function()
  local srv = server(function(data)
    data[#data + 1] = data[1]
  end)
  local r = embed(srv.url, texts(3))
  srv.close()
  T.eq(r.error, 'bad-response')
  T.ok(r.detail:find('expected 3', 1, true) and r.detail:find('received 4', 1, true), r.detail)
end)

T.case(
  'embed: data missing, not a list, an item without a list or a non-finite value is bad-response',
  function()
    local cases = {
      { 'no data', { body = { object = 'list' } } },
      { 'data an object', { body = { data = { a = 1 } } } },
      { 'data a string', { body = { data = 'x' } } },
      { 'item without embedding', { body = { data = { { index = 0 } } } } },
      { 'embedding a string', { body = { data = { { embedding = 'abc' } } } } },
      { 'a string in the vector', { body = { data = { { embedding = { 1, 'x' } } } } } },
      { 'a null in the vector', { body = '{"data":[{"embedding":[1,null]}]}' } },
      { 'NaN', { body = '{"data":[{"embedding":[1,NaN]}]}' } },
      { 'Infinity', { body = '{"data":[{"embedding":[Infinity]}]}' } },
      { '-Infinity', { body = '{"data":[{"embedding":[-Infinity]}]}' } },
      { 'not JSON', { body = 'oops' } },
    }
    for _, c in ipairs(cases) do
      local srv = stub.start({ ['POST /v1/embeddings'] = c[2] })
      local r = embed(srv.url, { 'note 1' })
      srv.close()
      T.eq(r.error, 'bad-response', c[1])
      T.eq(r.ok, false, c[1])
    end
    -- control: the same route shape with a finite vector passes
    local srv =
      stub.start({ ['POST /v1/embeddings'] = { body = { data = { { embedding = { 1, 2.5, -3 } } } } } })
    local r = embed(srv.url, { 'note 1' })
    srv.close()
    T.eq(r.vectors, { { 1, 2.5, -3 } })
  end
)

T.case('embed: status 500 is http with the status', function()
  local srv =
    stub.start({ ['POST /v1/embeddings'] = { status = 500, body = { error = { message = 'boom' } } } })
  local r = embed(srv.url, texts(2))
  srv.close()
  T.eq(r.ok, false)
  T.eq(r.error, 'http')
  T.eq(r.status, 500)
  T.ok(r.detail:find('boom', 1, true), r.detail)
end)

T.case('embed: a 200 with an error body (LM Studio on unknown paths) is http', function()
  local srv = stub.start({ ['POST /v1/embeddings'] = { body = { error = 'Unexpected endpoint' } } })
  local r = embed(srv.url, texts(1))
  srv.close()
  T.eq(r.error, 'http')
end)

T.case('embed: the key goes in the header over stdin, never in curl argv', function()
  L.reset()
  vim.env.NVIM_KIT_TEST_EMB_KEY = 'sk-emb-0123456789'
  local srv = server()
  local real = vim.system
  local seen = {}
  vim.system = function(cmd, opts, on_exit)
    seen[#seen + 1] = { argv = table.concat(cmd, ' '), stdin = opts and opts.stdin or '' }
    return real(cmd, opts, on_exit)
  end
  local r = embed(srv.url, texts(3), { endpoint = { url = srv.url, api_key_env = 'NVIM_KIT_TEST_EMB_KEY' } })
  vim.system = real
  srv.close()
  T.eq(r.ok, true)
  T.eq(srv.requests[1].headers.authorization, 'Bearer sk-emb-0123456789')
  T.ok(#seen > 0)
  for _, s in ipairs(seen) do
    T.eq(s.argv:find('sk-emb', 1, true), nil, 'key in argv: ' .. s.argv)
  end
  -- counter-check: the capture sees what goes over stdin
  T.ok(seen[1].stdin:find('sk-emb-0123456789', 1, true))
end)

T.case('embed: a missing key is key-missing, before any request', function()
  L.reset()
  vim.env.NVIM_KIT_TEST_EMB_UNSET = nil
  local srv = server()
  local r =
    embed(srv.url, texts(1), { endpoint = { url = srv.url, api_key_env = 'NVIM_KIT_TEST_EMB_UNSET' } })
  srv.close()
  T.eq(r.error, 'key-missing')
  T.eq(#srv.requests, 0)
end)

T.case('embed: a server message that echoes the key is redacted', function()
  L.reset()
  vim.env.NVIM_KIT_TEST_EMB_KEY = 'sk-emb-0123456789'
  local srv = stub.start({
    ['POST /v1/embeddings'] = { status = 401, body = { error = { message = 'bad key sk-emb-0123456789' } } },
  })
  local r = embed(srv.url, texts(1), { endpoint = { url = srv.url, api_key_env = 'NVIM_KIT_TEST_EMB_KEY' } })
  srv.close()
  T.eq(r.error, 'http')
  T.eq(r.detail:find('sk-emb', 1, true), nil, r.detail)
end)

T.case('embed: a cancel after the first group answers cancelled and sends no further request', function()
  local srv
  srv = stub.start({
    ['POST /v1/embeddings'] = function(req)
      if #srv.requests >= 2 then
        return { hang = true }
      end
      local body = vim.json.decode(req.body)
      local data = {}
      for i, s in ipairs(body.input) do
        data[i] = { embedding = vec(s) }
      end
      return { body = { data = data } }
    end,
  })
  local handle
  local r, calls = await(function(cb)
    handle = L.embed({ endpoint = { url = srv.url }, model = 'emb', input = texts(70) }, cb)
    -- the first group is answered, the second hangs: cancel while it is in flight
    vim.wait(2000, function()
      return #srv.requests >= 2
    end, 5)
    handle.cancel()
  end)
  vim.wait(400) -- room for a third request, were it wrongly sent
  srv.close()
  T.eq(r.ok, false)
  T.eq(r.error, 'cancelled')
  T.eq(calls(), 1)
  T.eq(#srv.requests, 2)
  T.eq(r.vectors, nil)
end)

T.case('embed: a cancel that lands between two groups sends no second request', function()
  local srv = server()
  local real = vim.system
  local handle, armed = nil, true
  -- Cancels in the slot between "curl of group 1 exited" and "the callback sends group 2": the
  -- scheduled cancel is queued before curl's own on_exit queues the callback.
  vim.system = function(cmd, opts, on_exit)
    if armed and opts and opts.stdin and opts.stdin:find('/v1/embeddings', 1, true) then
      armed = false
      return real(cmd, opts, function(r)
        vim.schedule(function()
          handle.cancel()
        end)
        on_exit(r)
      end)
    end
    return real(cmd, opts, on_exit)
  end
  local r, calls = await(function(cb)
    handle = L.embed({ endpoint = { url = srv.url }, model = 'emb', input = texts(70) }, cb)
  end)
  vim.wait(500) -- room for the second request, were it wrongly sent
  vim.system = real
  srv.close()
  T.eq(r.error, 'cancelled')
  T.eq(calls(), 1)
  T.eq(#srv.requests, 1, 'group 1 was asked, group 2 must not be')
end)

T.case('embed: a cancel before the key is known sends no request', function()
  L.reset()
  local srv = server()
  local mark = vim.fn.tempname()
  local ep =
    { url = srv.url, api_key_cmd = { 'sh', '-c', ('touch %s; printf sk-late; exec sleep 0.3'):format(mark) } }
  local handle
  local r = await(function(cb)
    handle = L.embed({ endpoint = ep, model = 'emb', input = texts(2) }, cb)
    vim.wait(100)
    handle.cancel()
  end)
  vim.wait(600)
  srv.close()
  T.eq(r.error, 'cancelled')
  T.eq(#srv.requests, 0)
end)

T.case('embed: no answer within timeout_ms is timeout', function()
  local srv = stub.start({ ['POST /v1/embeddings'] = { hang = true } })
  local t0 = vim.uv.hrtime()
  local r = embed(srv.url, texts(2), { timeout_ms = 300 })
  local ms = (vim.uv.hrtime() - t0) / 1e6
  srv.close()
  T.eq(r.error, 'timeout')
  T.ok(ms >= 250 and ms < 3000, ('%d ms'):format(ms))
end)

T.case('embed: a port where nothing listens is unreachable', function()
  local r = embed(dead_url(), texts(2))
  T.eq(r.ok, false)
  T.eq(r.error, 'unreachable')
end)

T.case('embed: empty input answers ok with no vectors and sends no request, on the main loop', function()
  local srv = server()
  local fired_sync = false
  local sync = true
  local r = await(function(cb)
    L.embed({ endpoint = { url = srv.url }, model = 'emb', input = {} }, function(v)
      fired_sync = sync
      cb(v)
    end)
    sync = false
  end)
  vim.wait(100)
  srv.close()
  T.eq(r, { ok = true, vectors = {} })
  T.eq(fired_sync, false, 'cb must not run inside embed()')
  T.eq(#srv.requests, 0)
end)

T.case('embed: text that is not UTF-8 is sent as U+FFFD, so the body stays JSON', function()
  local srv = server()
  local r = embed(srv.url, { 'note 1 caf\233 \255' })
  srv.close()
  T.eq(r.ok, true)
  local body = srv.requests[1].body
  T.ok(require('nvim_kit.llm_json').is_strict_json(body), body)
  T.eq(vim.json.decode(body).input[1], 'note 1 caf\239\191\189 \239\191\189')
end)

T.case('embed: invalid arguments raise at once', function()
  local ep = { url = 'http://127.0.0.1:9' }
  local function ok_req(extra)
    return vim.tbl_extend('force', { endpoint = ep, model = 'm', input = { 'a' } }, extra or {})
  end
  local function call(req, cb)
    return function()
      L.embed(req, cb == nil and function() end or cb)
    end
  end
  T.raises(call(nil), 'embed needs req.endpoint')
  T.raises(call(ok_req({ endpoint = 'http://x' })), 'embed needs req.endpoint')
  T.raises(call(ok_req({ model = 3 })), 'req.model')
  T.raises(call(ok_req({ input = 'text' })), 'req.input')
  T.raises(call(ok_req({ input = { a = 'x' } })), 'req.input')
  T.raises(call(ok_req({ input = { 'a', 2 } })), 'req.input[2]')
  for _, bs in ipairs({ 0, -1, 1.5, '4', math.huge, 0 / 0 }) do
    T.raises(call(ok_req({ batch_size = bs })), 'batch_size must be a positive integer')
  end
  T.raises(call(ok_req({ timeout_ms = 0 })), 'timeout_ms')
  T.raises(call(ok_req({ timeout_ms = 'x' })), 'timeout_ms')
  T.raises(call(ok_req(), 'not a function'), 'callback')
  T.raises(call(ok_req({ endpoint = { url = 'http://x', backend = 'anthropic' } })), "backend 'anthropic'")
  T.raises(call(ok_req({ endpoint = { url = 'nope' } })), 'endpoints[1]')
  -- control: a valid request is accepted (no raise), and an empty input with it
  local h = L.embed(ok_req({ input = {} }), function() end)
  T.ok(type(h.cancel) == 'function')
end)
