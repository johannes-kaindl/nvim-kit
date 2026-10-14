-- Searching a text, not files, with ripgrep: the text goes in over stdin and rg's JSON lines
-- (--json) come back as hits with byte offsets into that text. With a replacement, rg computes
-- each hit's replaced text itself, so a plugin needs no replacement logic of its own; --replace
-- together with --json needs ripgrep 15.0.0 (CHANGELOG, FEATURE #1872). The user's ripgrep config
-- is ignored (--no-config), because options such as --max-columns or --smart-case would change
-- the output or the matches; --text keeps a NUL byte from ending the search as "binary", and
-- --encoding=none keeps rg from stripping a byte order mark or transcoding UTF-16, either of which
-- would shift the byte offsets against the text.
-- Errors are values ({ ok = false, error = kind, detail }); a call with invalid arguments raises.
-- Error kinds: rg-missing (not on PATH, or older than MIN_VERSION), rg-error (rg refused, e.g.
-- the pattern; or a NUL byte in pattern or replacement, which an argument cannot carry),
-- timeout, cancelled.
local M = {}

M.MIN_VERSION = '15.0.0'
M.TIMEOUT_MS = 5000

local versions = {} -- exe -> '15.2.0'; only successful lookups

local function at_least(v, min)
  local a, b = vim.split(v, '.', { plain = true }), vim.split(min, '.', { plain = true })
  for i = 1, 3 do
    local x, y = tonumber(a[i]) or 0, tonumber(b[i]) or 0
    if x ~= y then
      return x > y
    end
  end
  return true
end

--- The installed ripgrep's version ("15.2.0"), or nil and why not. A found version is cached per
--- executable for the session (a synchronous `rg --version`, a few milliseconds); a failure is
--- not, so the next call asks again (it may have come from a fast callback, where waiting for a
--- process is forbidden, or the user may install ripgrep meanwhile).
function M.version(exe)
  exe = exe or 'rg'
  if versions[exe] then
    return versions[exe], nil
  end
  local ok, res = pcall(function()
    return vim.system({ exe, '--version' }, { text = true }):wait(M.TIMEOUT_MS)
  end)
  if not ok then
    local why = tostring(res):gsub('^.-:%d+: ', '')
    if why:find('ENOENT', 1, true) then
      return nil, ('%s not found on PATH (%s)'):format(exe, why)
    end
    return nil, ('%s could not be run: %s'):format(exe, why)
  end
  if res.code ~= 0 then
    return nil, ('%s --version failed (exit %d)'):format(exe, res.code)
  end
  local v = (res.stdout or ''):match('^ripgrep (%d+%.%d+%.%d+)')
  if not v then
    return nil, ('%s --version: unexpected output'):format(exe)
  end
  versions[exe] = v
  return v, nil
end

--- Forget the cached versions (tests; after the user installed another ripgrep).
function M.reset()
  versions = {}
end

--- nil when ripgrep is usable, else { error = 'rg-missing', detail }.
function M.check(exe)
  local v, err = M.version(exe)
  if not v then
    return { error = 'rg-missing', detail = err }
  end
  if not at_least(v, M.MIN_VERSION) then
    return {
      error = 'rg-missing',
      detail = ('ripgrep %s is older than %s (--replace with --json)'):format(v, M.MIN_VERSION),
    }
  end
  return nil
end

-- rg's "arbitrary data": { text = … } for valid UTF-8, else { bytes = <base64> }.
local function data(d)
  if type(d) ~= 'table' then
    return nil
  end
  if type(d.text) == 'string' then
    return d.text
  end
  if type(d.bytes) == 'string' then
    return vim.base64.decode(d.bytes)
  end
  return nil
end

-- The number of "\n" in s at the 0-based byte offsets from..to-1, found without copying s.
local function count_newlines(s, from, to)
  local n, i = 0, s:find('\n', from + 1, true)
  while i and i <= to do
    n = n + 1
    i = s:find('\n', i + 1, true)
  end
  return n
end

-- The hits in rg's JSON output, at most max_hits (then truncated = true).
local function parse(stdout, max_hits)
  local hits, truncated = {}, false
  for line in vim.gsplit(stdout, '\n', { plain = true }) do
    if line ~= '' then
      local ok, msg = pcall(vim.json.decode, line)
      if ok and type(msg) == 'table' and msg.type == 'match' then
        local d = msg.data
        local lines = data(d.lines) or ''
        -- Lines are counted on from the previous submatch (rg sends them in ascending order):
        -- counting from the block's start for each one is quadratic, and a long line with many
        -- hits would block Neovim for seconds (review finding I2).
        local at, lnum = 0, d.line_number
        for _, sm in ipairs(d.submatches or {}) do
          if max_hits and #hits >= max_hits then
            truncated = true
            return hits, truncated
          end
          lnum = lnum + count_newlines(lines, at, sm.start)
          at = sm.start
          hits[#hits + 1] = {
            start = d.absolute_offset + sm.start,
            stop = d.absolute_offset + sm['end'],
            match = data(sm.match) or '',
            replacement = data(sm.replacement),
            line = lnum,
          }
        end
      end
    end
  end
  return hits, truncated
end

--- Search text with ripgrep, asynchronously. Returns a handle; handle:cancel() stops rg and
--- answers { ok = false, error = 'cancelled' } at once.
--- opts = { pattern, replacement = <string|nil>, multiline = <bool>, max_hits = <n|nil>,
---          timeout_ms = <n|nil>, exe = <'rg'> }
--- cb({ ok = true, hits = { { start, stop, match, replacement, line } }, truncated })
---   | cb({ ok = false, error = kind, detail })
--- start and stop are 0-based byte offsets into text, stop exclusive; line is the 1-based line of
--- start. replacement is set only when opts.replacement was. cb runs on the main loop.
function M.search(text, opts, cb)
  if type(text) ~= 'string' then
    error('nvim-kit rg: search needs text (a string)', 2)
  end
  if type(opts) ~= 'table' or type(opts.pattern) ~= 'string' then
    error('nvim-kit rg: search needs opts.pattern (a string)', 2)
  end
  if opts.replacement ~= nil and type(opts.replacement) ~= 'string' then
    error('nvim-kit rg: opts.replacement must be a string', 2)
  end
  local done = false
  local function finish(v)
    if done then
      return
    end
    done = true
    vim.schedule(function()
      cb(v)
    end)
  end
  local handle = { cancel = function() end }
  -- An argument ends at a NUL byte: 'a\0b' would silently search for 'a'.
  for _, f in ipairs({ 'pattern', 'replacement' }) do
    if opts[f] and opts[f]:find('\0', 1, true) then
      finish({
        ok = false,
        error = 'rg-error',
        detail = ('%s contains a NUL byte (write \\x00)'):format(f),
      })
      return handle
    end
  end
  local exe = opts.exe or 'rg'
  local missing = M.check(exe)
  if missing then
    missing.ok = false
    finish(missing)
    return handle
  end
  local args = { exe, '--no-config', '--json', '--text', '--encoding=none' }
  if opts.multiline then
    args[#args + 1] = '--multiline'
  end
  if opts.replacement ~= nil then
    -- One argument: a replacement that starts with "-" must not read as an option.
    args[#args + 1] = '--replace=' .. opts.replacement
  end
  vim.list_extend(args, { '-e', opts.pattern, '-' })
  local proc = vim.system(
    args,
    { stdin = text, text = true, timeout = opts.timeout_ms or M.TIMEOUT_MS },
    function(res)
      if res.code == 124 then
        return finish({ ok = false, error = 'timeout', detail = 'ripgrep did not finish in time' })
      end
      if res.signal and res.signal ~= 0 then
        -- Killed from outside (OOM, kill -9): its output may be partial, never a result.
        return finish({
          ok = false,
          error = 'rg-error',
          detail = ('ripgrep was killed by signal %d'):format(res.signal),
        })
      end
      if res.code == 0 or res.code == 1 then
        local hits, truncated = parse(res.stdout or '', opts.max_hits)
        return finish({ ok = true, hits = hits, truncated = truncated })
      end
      local msg = vim.trim(res.stderr or '')
      finish({
        ok = false,
        error = 'rg-error',
        detail = msg ~= '' and msg or ('ripgrep ended with exit %d'):format(res.code),
      })
    end
  )
  function handle.cancel()
    pcall(proc.kill, proc, 15)
    finish({ ok = false, error = 'cancelled', detail = 'cancelled' })
  end
  return handle
end

return M
