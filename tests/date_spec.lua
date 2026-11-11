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

-- The clock is held still by passing an instant (seconds since the epoch) instead of reading the system
-- clock, so the zone is the only thing that varies. 22:30 UTC on 2026-10-14 is 00:30 on the 15th in
-- Berlin (CEST, UTC+2) and still the 14th in UTC.
local function instant(ymd_utc, hour, min)
  local y, m, d = ymd_utc:match('^(%d+)-(%d+)-(%d+)$')
  return D.days_from_civil(tonumber(y), tonumber(m), tonumber(d)) * 86400 + hour * 3600 + min * 60
end

local function in_zone(tz, fn)
  local old = vim.env.TZ
  vim.env.TZ = tz
  local ok, a, b = pcall(fn)
  vim.env.TZ = old
  if not ok then
    error(a, 0)
  end
  return a, b
end

T.case('local_today is the calendar date in the local zone, utc_today the one in UTC', function()
  local t = instant('2026-10-14', 22, 30)
  -- guard: the zone switch arrives (the hour differs), otherwise every check below proves nothing
  T.eq(
    in_zone('Europe/Berlin', function()
      return os.date('%H', t)
    end),
    '00'
  )
  T.eq(
    in_zone('UTC', function()
      return os.date('%H', t)
    end),
    '22'
  )
  T.eq(
    in_zone('Europe/Berlin', function()
      return D.local_today(t)
    end),
    '2026-10-15'
  )
  T.eq(
    in_zone('UTC', function()
      return D.local_today(t)
    end),
    '2026-10-14'
  )
  -- winter time (CET, UTC+1): 23:30 UTC is already the next day in Berlin
  T.eq(
    in_zone('Europe/Berlin', function()
      return D.local_today(instant('2026-01-14', 23, 30))
    end),
    '2026-01-15'
  )
  -- a zone behind UTC goes the other way: 03:00 UTC is still the day before in Los Angeles
  T.eq(
    in_zone('America/Los_Angeles', function()
      return D.local_today(instant('2026-10-14', 3, 0))
    end),
    '2026-10-13'
  )
  -- utc_today ignores the zone
  T.eq(
    in_zone('Europe/Berlin', function()
      return D.utc_today(t)
    end),
    '2026-10-14'
  )
end)

T.case('local_today without an argument reads the clock: today in the local zone', function()
  T.ok(D.local_today():match('^%d%d%d%d%-%d%d%-%d%d$'), D.local_today())
  T.eq(D.local_today(), os.date('%Y-%m-%d'))
end)

T.case('local_today and utc_today refuse an instant that is no number', function()
  for _, bad in ipairs({ '2026-10-14', true, {} }) do
    T.raises(function()
      D.local_today(bad)
    end, 'nvim-kit date')
    T.raises(function()
      D.utc_today(bad)
    end, 'nvim-kit date')
  end
end)

-- add_days stays pure calendar arithmetic whatever the zone is: across the EU autumn switch (25 hours
-- long) as across the spring one.
T.case('add_days does not move with the zone', function()
  for _, tz in ipairs({ 'UTC', 'Europe/Berlin', 'America/Los_Angeles' }) do
    in_zone(tz, function()
      T.eq(D.add_days('2026-10-25', 1), '2026-10-26', tz)
      T.eq(D.add_days('2026-10-26', -1), '2026-10-25', tz)
      T.eq(D.add_days('2026-03-29', 1), '2026-03-30', tz)
    end)
  end
end)
