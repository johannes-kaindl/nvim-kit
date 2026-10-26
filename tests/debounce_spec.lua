local T = require('nvim_kit.test')
local D = require('nvim_kit.debounce')

local uv = vim.uv or vim.loop

local MS = 120 -- long enough that a loaded machine does not fake a quiet gap between two calls
local STEP = 40

local function wait_for(cond, timeout)
  return vim.wait(timeout or 3000, cond, 5)
end

T.case('call: a burst runs fn once, with the arguments of the last call', function()
  local runs = {}
  local d = D.new(MS, function(...)
    runs[#runs + 1] = vim.F.pack_len(...)
  end)
  d.call('a', 1)
  d.call('b', 2)
  d.call('c', 3)
  T.eq(#runs, 0, 'fn must not run before the quiet time')
  T.ok(wait_for(function()
    return #runs > 0
  end))
  vim.wait(MS * 2) -- room for a wrong second run
  T.eq(runs, { vim.F.pack_len('c', 3) })
end)

T.case('call: every call restarts the timer', function()
  local ran_at
  local d = D.new(MS, function()
    ran_at = uv.hrtime()
  end)
  local t0 = uv.hrtime()
  d.call()
  vim.wait(STEP)
  d.call()
  vim.wait(STEP)
  d.call()
  local t_last = uv.hrtime()
  T.ok(wait_for(function()
    return ran_at ~= nil
  end))
  local since_last = (ran_at - t_last) / 1e6
  T.ok(since_last >= MS - 15, ('ran %.0f ms after the last call, wanted at least %d'):format(since_last, MS))
  T.ok((ran_at - t0) / 1e6 >= 2 * STEP + MS - 15)
end)

T.case('call: arguments that are nil keep their positions', function()
  local got
  local d = D.new(10, function(...)
    got = vim.F.pack_len(...)
  end)
  d.call(nil, 'x', nil)
  T.ok(wait_for(function()
    return got ~= nil
  end))
  T.eq(got.n, 3)
  T.eq(got[2], 'x')
end)

T.case('call: fn runs on the main loop, not in a fast event', function()
  local fast, api_ok
  local d = D.new(10, function()
    fast = vim.in_fast_event()
    api_ok = pcall(vim.api.nvim_get_current_buf)
  end)
  d.call()
  T.ok(wait_for(function()
    return fast ~= nil
  end))
  T.eq(fast, false)
  T.eq(api_ok, true)
end)

T.case('call: usable from a fast callback', function()
  local runs = 0
  local d = D.new(10, function()
    runs = runs + 1
  end)
  local timer = uv.new_timer()
  local ok
  timer:start(0, 0, function()
    ok = pcall(d.call)
  end)
  T.ok(wait_for(function()
    return runs > 0
  end))
  timer:close()
  T.eq(ok, true)
  T.eq(runs, 1)
end)

T.case('call: a debouncer can run again after it has run', function()
  local seen = {}
  local d = D.new(10, function(x)
    seen[#seen + 1] = x
  end)
  d.call(1)
  T.ok(wait_for(function()
    return #seen == 1
  end))
  d.call(2)
  T.ok(wait_for(function()
    return #seen == 2
  end))
  T.eq(seen, { 1, 2 })
end)

T.case('call: a call from inside fn schedules the next run', function()
  local seen = {}
  local d
  d = D.new(10, function(x)
    seen[#seen + 1] = x
    if x == 1 then
      d.call(2)
    end
  end)
  d.call(1)
  T.ok(wait_for(function()
    return #seen == 2
  end))
  T.eq(seen, { 1, 2 })
end)

T.case('cancel: a pending call never runs; it says whether there was one', function()
  local runs = 0
  local d = D.new(30, function()
    runs = runs + 1
  end)
  T.eq(d.cancel(), false)
  d.call()
  T.eq(d.cancel(), true)
  T.eq(d.cancel(), false)
  vim.wait(150)
  T.eq(runs, 0)
  d.call()
  T.ok(
    wait_for(function()
      return runs == 1
    end),
    'the debouncer works again after a cancel'
  )
end)

T.case('cancel: also stops a call whose timer fired but whose run is still queued', function()
  local runs = 0
  local d = D.new(1, function()
    runs = runs + 1
  end)
  -- B is started before the debouncer's timer with the same time: when both are overdue, libuv
  -- runs B first, so its scheduled cancel is queued before the debouncer's scheduled run.
  local b = uv.new_timer()
  b:start(1, 0, function()
    vim.schedule(d.cancel)
  end)
  d.call()
  uv.sleep(30) -- block the loop so both timers are overdue in the same turn
  vim.wait(100)
  b:close()
  T.eq(runs, 0)
end)

T.case('cancel then call: the run queued by the cancelled call does not take the new call early', function()
  local runs = {}
  local d = D.new(100, function(x)
    runs[#runs + 1] = { x, uv.hrtime() }
  end)
  local t_restart
  local b = uv.new_timer()
  b:start(100, 0, function()
    vim.schedule(function()
      d.cancel()
      d.call('b')
      t_restart = uv.hrtime()
    end)
  end)
  d.call('a')
  uv.sleep(150) -- both timers overdue in one turn: B's schedule is queued first, then the run of 'a'
  T.ok(wait_for(function()
    return #runs > 0
  end))
  b:close()
  T.eq(runs[1][1], 'b')
  local waited = (runs[1][2] - t_restart) / 1e6
  T.ok(waited >= 85, ('the new call ran %.0f ms after it was made, wanted about 100'):format(waited))
  vim.wait(200)
  T.eq(#runs, 1)
end)

T.case('flush: runs a pending call now with its arguments, once', function()
  local runs = {}
  local d = D.new(60, function(x)
    runs[#runs + 1] = x
  end)
  d.call('first')
  d.call('last')
  T.eq(d.flush(), true)
  T.eq(runs, { 'last' }, 'synchronous: it has run when flush returns')
  vim.wait(200)
  T.eq(runs, { 'last' }, 'the timer must not run it a second time')
  T.eq(d.flush(), false)
end)

T.case('flush: with nothing pending does nothing', function()
  local runs = 0
  local d = D.new(10, function()
    runs = runs + 1
  end)
  T.eq(d.flush(), false)
  d.call()
  d.cancel()
  T.eq(d.flush(), false)
  T.eq(runs, 0)
end)

T.case('VimLeavePre closes the timer and drops a pending call', function()
  local runs = 0
  local d = D.new(20, function()
    runs = runs + 1
  end)
  d.call()
  vim.api.nvim_exec_autocmds('VimLeavePre', {})
  vim.wait(120)
  T.eq(runs, 0)
  d.call() -- after the close a call is a no-op, not an error on a closed handle
  vim.wait(60)
  T.eq(runs, 0)
  T.eq(d.cancel(), false)
  T.eq(d.flush(), false)
end)

T.case('new: invalid arguments raise', function()
  T.raises(function()
    D.new(-1, function() end)
  end, 'ms')
  T.raises(function()
    D.new('10', function() end)
  end, 'ms')
  T.raises(function()
    D.new(10, nil)
  end, 'fn')
end)
