local T = require('nvim_kit.test')
local D = require('nvim_kit.date')

T.case('day ordinals count from 1970-01-01 and round-trip', function()
  T.eq(D.days_from_civil(1970, 1, 1), 0)
  T.eq(D.days_from_civil(2000, 3, 1), 11017)
  T.eq(D.days_from_civil(1969, 12, 31), -1)
  for n = -800000, 800000, 997 do
    local y, m, d = D.civil_from_days(n)
    T.eq(D.days_from_civil(y, m, d), n, 'ordinal ' .. n)
  end
end)

T.case('add_days crosses month, year and leap-day boundaries', function()
  T.eq(D.add_days('2024-03-01', -1), '2024-02-29')
  T.eq(D.add_days('2023-03-01', -1), '2023-02-28')
  T.eq(D.add_days('2000-03-01', -1), '2000-02-29')
  T.eq(D.add_days('2100-03-01', -1), '2100-02-28')
  T.eq(D.add_days('2026-01-01', -1), '2025-12-31')
  T.eq(D.add_days('2025-12-31', 1), '2026-01-01')
  T.eq(D.add_days('2026-10-09', 0), '2026-10-09')
  T.eq(D.add_days('2026-10-09', 365), '2027-10-09')
end)

T.case('malformed or impossible dates are refused', function()
  for _, bad in ipairs({ '2026-13-01', '2026-02-30', '2025-02-29', '26-01-01', '2026-1-1', '', 'today' }) do
    T.raises(function()
      D.add_days(bad, 1)
    end, 'nvim-kit date')
  end
end)

T.case('utc_today is the UTC calendar date', function()
  T.ok(D.utc_today():match('^%d%d%d%d%-%d%d%-%d%d$'), D.utc_today())
  T.eq(D.utc_today(), os.date('!%Y-%m-%d'))
end)

-- Counter-check: the same day before, done with os.time in local time, loses a day after the EU spring
-- switch — the trap add_days exists to avoid. Both run under TZ=Europe/Berlin.
T.case('counter-check: os.time arithmetic fails under TZ=Europe/Berlin, add_days does not', function()
  local old = vim.env.TZ
  vim.env.TZ = 'Europe/Berlin'
  local ok, err = pcall(function()
    local naive = os.date('%Y-%m-%d', os.time({ year = 2026, month = 3, day = 30, hour = 0 }) - 86400)
    T.eq(naive, '2026-03-28', 'os.time variant (expected to be wrong)')
    T.eq(D.add_days('2026-03-30', -1), '2026-03-29')
  end)
  vim.env.TZ = old
  T.ok(ok, err)
end)
