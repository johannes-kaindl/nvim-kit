-- Calendar dates as YYYY-MM-DD strings, without time zones: day arithmetic is pure proleptic
-- Gregorian calendar math (H. Hinnant's algorithms), never os.time, whose local time and DST
-- would shift a day. Day ordinals count from 1970-01-01 like code-kit's civilCalendar.
-- Only `utc_today` and `local_today` read the clock, and say which zone they read.
local M = {}

--- Days since 1970-01-01 for a civil date (month 1–12).
function M.days_from_civil(y, m, d)
  y = m <= 2 and y - 1 or y
  local era = math.floor(y / 400)
  local yoe = y - era * 400
  local doy = math.floor((153 * ((m + 9) % 12) + 2) / 5) + d - 1
  local doe = yoe * 365 + math.floor(yoe / 4) - math.floor(yoe / 100) + doy
  return era * 146097 + doe - 719468
end

--- The civil date (year, month 1–12, day) of a day ordinal.
function M.civil_from_days(z)
  z = z + 719468
  local era = math.floor(z / 146097)
  local doe = z - era * 146097
  local yoe =
    math.floor((doe - math.floor(doe / 1460) + math.floor(doe / 36524) - math.floor(doe / 146096)) / 365)
  local doy = doe - (365 * yoe + math.floor(yoe / 4) - math.floor(yoe / 100))
  local mp = math.floor((5 * doy + 2) / 153)
  local d = doy - math.floor((153 * mp + 2) / 5) + 1
  local m = mp < 10 and mp + 3 or mp - 9
  local y = yoe + era * 400
  return m <= 2 and y + 1 or y, m, d
end

local function format(y, m, d)
  return ('%04d-%02d-%02d'):format(y, m, d)
end

-- Ordinal of a YYYY-MM-DD string; refuses malformed and impossible dates (2025-02-29) loudly.
local function ordinal(ymd)
  local y, m, d = tostring(ymd):match('^(%d%d%d%d)%-(%d%d)%-(%d%d)$')
  if y then
    local n = M.days_from_civil(tonumber(y), tonumber(m), tonumber(d))
    if format(M.civil_from_days(n)) == ymd then
      return n
    end
  end
  error(('nvim-kit date: %q is not a valid YYYY-MM-DD date'):format(tostring(ymd)), 3)
end

--- The date n days after ymd (n may be negative), as YYYY-MM-DD.
function M.add_days(ymd, n)
  return format(M.civil_from_days(ordinal(ymd) + n))
end

-- An instant is seconds since the epoch; nil is "now". Refused loudly when it is anything else, since
-- os.date would read a string like '2026-10-14' as a format and answer with garbage.
local function instant(t)
  if t ~= nil and type(t) ~= 'number' then
    error(('nvim-kit date: an instant is a number of seconds, got %s'):format(type(t)), 3)
  end
  return t or os.time()
end

--- Today's date in UTC, as YYYY-MM-DD. `t` is an instant in seconds since the epoch (default: now).
function M.utc_today(t)
  return os.date('!%Y-%m-%d', instant(t))
end

--- Today's date in the local time zone, as YYYY-MM-DD: the calendar day a person on this machine is
--- living in, which between local midnight and the zone's offset is not the UTC day. `t` is an instant
--- in seconds since the epoch (default: now); a test holds the clock still with it.
function M.local_today(t)
  return os.date('%Y-%m-%d', instant(t))
end

return M
