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

-- The length of the character at byte i of s as Vim counts it (utf_ptr2len): the length its lead
-- byte announces when all those continuation bytes follow, else 1.
local function char_len(s, i)
  local c = s:byte(i)
  local len = c >= 0xFC and c <= 0xFD and 6
    or c >= 0xF8 and c <= 0xFB and 5
    or c >= 0xF0 and c <= 0xF7 and 4
    or c >= 0xE0 and c <= 0xEF and 3
    or c >= 0xC0 and c <= 0xDF and 2
    or 1
  for k = 1, len - 1 do
    local b = s:byte(i + k)
    if not b or b < 0x80 or b > 0xBF then
      return 1
    end
  end
  return len
end

--- s cut to its first max_chars characters plus mark (default U+2026) when it is longer, else s
--- itself. Counts characters (UTF-8 code points), not bytes, so it never cuts inside a multibyte
--- character. Counted in plain Lua the way vim.fn.strchars counts: a lead byte 0xC0..0xFD
--- followed by all the continuation bytes (0x80..0xBF) it announces is one character (2 to 6
--- bytes, as Vim reads them: overlong forms and surrogates included); every other byte is one
--- character, so a run of stray continuation bytes counts byte by byte. A NUL byte is a
--- character too (vim.fn.strchars raised E976 on it), and it runs in a fast callback.
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
  local n, i = 0, 1
  while i <= #s do
    n = n + 1
    if n > max_chars then
      return s:sub(1, i - 1) .. (mark == nil and '…' or mark)
    end
    i = i + char_len(s, i)
  end
  return s
end

-- Language code (lower case, two letters) → the name a model understands; a code alone is too quiet a hint.
local LANGUAGES = {
  cs = 'Czech',
  da = 'Danish',
  de = 'German',
  en = 'English',
  es = 'Spanish',
  fi = 'Finnish',
  fr = 'French',
  it = 'Italian',
  ja = 'Japanese',
  ko = 'Korean',
  nb = 'Norwegian',
  nl = 'Dutch',
  no = 'Norwegian',
  pl = 'Polish',
  pt = 'Portuguese',
  ru = 'Russian',
  sv = 'Swedish',
  tr = 'Turkish',
  uk = 'Ukrainian',
  zh = 'Chinese',
}

--- The English name of the language in a locale or language code: `'de_DE.UTF-8'`, `'de'` and
--- `'pt_BR'` give `'German'`, `'German'`, `'Portuguese'`. A code is two letters, alone or followed
--- by `_`, `.`, `-` or `@` and anything (region, encoding, modifier), in either case. `lang` nil
--- reads `vim.v.lang`. `'C'`, `'POSIX'`, an empty string and every code outside the 20 known
--- ones (cs da de en es fi fr it ja ko nb nl no pl pt ru sv tr uk zh) give `'English'`. Raises
--- when `lang` is neither nil nor a string. Which option or variable to read is the caller's.
function M.language_name(lang)
  if lang == nil then
    lang = vim.v.lang
  end
  if type(lang) ~= 'string' then
    error('nvim-kit text: language_name: lang must be a string or nil', 2)
  end
  local code = lang:match('^(%a%a)[_.%-@]') or lang:match('^(%a%a)$')
  return LANGUAGES[(code or ''):lower()] or 'English'
end

return M
