-- Small text pieces for plugin views.
local M = {}

--- A text progress bar: `[███░░░░░░░]` for pct (0–100, clamped) over width cells.
function M.bar(pct, width)
  pct = math.max(0, math.min(100, pct))
  local filled = math.floor(pct / 100 * width + 0.5)
  return '[' .. string.rep('█', filled) .. string.rep('░', width - filled) .. ']'
end

-- The length of a valid UTF-8 sequence starting at byte i of s, or nil (RFC 3629: no overlong
-- forms, no surrogates, nothing above U+10FFFF).
local function utf8_len(s, i)
  local c = s:byte(i)
  local len, lo, hi
  if c < 0x80 then
    return 1
  elseif c >= 0xC2 and c <= 0xDF then
    len, lo, hi = 2, 0x80, 0xBF
  elseif c >= 0xE0 and c <= 0xEF then
    len = 3
    lo = c == 0xE0 and 0xA0 or 0x80
    hi = c == 0xED and 0x9F or 0xBF
  elseif c >= 0xF0 and c <= 0xF4 then
    len = 4
    lo = c == 0xF0 and 0x90 or 0x80
    hi = c == 0xF4 and 0x8F or 0xBF
  else
    return nil
  end
  if i + len - 1 > #s then
    return nil
  end
  local b = s:byte(i + 1)
  if b < lo or b > hi then
    return nil
  end
  for k = 2, len - 1 do
    b = s:byte(i + k)
    if b < 0x80 or b > 0xBF then
      return nil
    end
  end
  return len
end

--- s with every byte that is not part of valid UTF-8 replaced by U+FFFD; s itself when it is valid.
--- vim.json.encode copies invalid bytes into its output, and a server then rejects the JSON.
function M.clean_utf8(s)
  local out, i, from = nil, 1, 1
  while i <= #s do
    local len = utf8_len(s, i)
    if len then
      i = i + len
    else
      out = out or {}
      out[#out + 1] = s:sub(from, i - 1)
      out[#out + 1] = '\239\191\189'
      i = i + 1
      from = i
    end
  end
  if not out then
    return s
  end
  out[#out + 1] = s:sub(from)
  return table.concat(out)
end

--- s cut to its first max_chars characters plus mark (default U+2026) when it is longer, else s
--- itself. Counts characters, not bytes, so it never cuts inside a multibyte character.
function M.truncate(s, max_chars, mark)
  if type(s) ~= 'string' then
    error('nvim-kit text: truncate needs s (a string)', 2)
  end
  if type(max_chars) ~= 'number' or max_chars < 0 or max_chars % 1 ~= 0 then
    error('nvim-kit text: truncate needs max_chars (a non-negative whole number)', 2)
  end
  if mark ~= nil and type(mark) ~= 'string' then
    error('nvim-kit text: truncate: mark must be a string', 2)
  end
  if vim.fn.strchars(s) <= max_chars then
    return s
  end
  return vim.fn.strcharpart(s, 0, max_chars) .. (mark == nil and '…' or mark)
end

return M
