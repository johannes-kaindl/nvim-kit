local T = require('nvim_kit.test')
local stub = require('nvim_kit.http_stub')

local function curl(args)
  local r
  vim.system(
    vim.list_extend({ 'curl', '-q', '-sS', '-w', '\n%{http_code}' }, args),
    { text = true },
    function(res)
      r = res
    end
  )
  vim.wait(5000, function()
    return r ~= nil
  end, 5)
  return r
end

T.case('answers a route, records method, path, lower-case headers and body', function()
  local srv = stub.start({ ['POST /x'] = { status = 201, body = { ok = true } } })
  local r = curl({ '-H', 'X-Test: 1', '--data-binary', 'payload', srv.url .. '/x' })
  srv.close()
  T.eq(r.stdout, '{"ok":true}\n201')
  T.eq(srv.requests[1].method, 'POST')
  T.eq(srv.requests[1].path, '/x')
  T.eq(srv.requests[1].headers['x-test'], '1')
  T.eq(srv.requests[1].body, 'payload')
end)

T.case('an unknown route is 404; a function route sees the request', function()
  local srv = stub.start({
    ['GET /echo'] = function(req)
      return { body = req.headers['x-name'] }
    end,
  })
  local miss = curl({ srv.url .. '/nope' })
  local echo = curl({ '-H', 'X-Name: ada', srv.url .. '/echo' })
  srv.close()
  T.eq(miss.stdout, '{"error":"no route"}\n404')
  T.eq(echo.stdout, 'ada\n200')
end)

T.case('a large body behind Expect: 100-continue arrives whole and without delay', function()
  local srv = stub.start({ ['POST /big'] = { body = 'ok' } })
  local body = vim.fn.tempname()
  local text = ('x'):rep(2 * 1024 * 1024)
  vim.fn.writefile({ text }, body, 'b')
  local t0 = vim.uv.hrtime()
  local r = curl({ '-H', 'Expect: 100-continue', '--data-binary', '@' .. body, srv.url .. '/big' })
  local ms = (vim.uv.hrtime() - t0) / 1e6
  srv.close()
  T.eq(r.stdout, 'ok\n200')
  T.eq(#srv.requests[1].body, #text)
  T.ok(ms < 900, ('%d ms — curl waited for 100 Continue'):format(ms))
end)

T.case('hang never answers; raw is sent as it is', function()
  local srv = stub.start({
    ['GET /hang'] = { hang = true },
    ['GET /raw'] = { raw = 'HTTP/1.1 200 OK\r\nContent-Length: 2\r\n\r\nhi' },
  })
  local hang = curl({ '-m', '0.3', srv.url .. '/hang' })
  local raw = curl({ srv.url .. '/raw' })
  srv.close()
  T.eq(hang.code, 28)
  T.eq(raw.stdout, 'hi\n200')
end)

T.case('close frees the port: a request afterwards cannot connect', function()
  local srv = stub.start({})
  srv.close()
  vim.wait(50)
  T.eq(curl({ srv.url .. '/x' }).code, 7)
end)
