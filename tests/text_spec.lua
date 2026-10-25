local T = require('nvim_kit.test')
local X = require('nvim_kit.text')

T.case('bar fills cells for a percentage, rounded, clamped to 0..100', function()
  T.eq(X.bar(0, 10), '[░░░░░░░░░░]')
  T.eq(X.bar(28, 10), '[███░░░░░░░]')
  T.eq(X.bar(100, 4), '[████]')
  T.eq(X.bar(150, 4), '[████]')
  T.eq(X.bar(-5, 4), '[░░░░]')
end)

T.case('clean_utf8: valid text comes back unchanged, the same string', function()
  for _, s in ipairs({ '', 'abc', 'Ärger €', '𝄞 \0 \127' }) do
    T.eq(X.clean_utf8(s), s)
  end
end)

T.case('clean_utf8: each invalid byte becomes U+FFFD', function()
  local R = '\239\191\189'
  T.eq(X.clean_utf8('a\255b'), 'a' .. R .. 'b')
  T.eq(X.clean_utf8('\195'), R) -- a sequence cut off at the end
  T.eq(X.clean_utf8('\195a'), R .. 'a') -- a lead byte without its continuation
  T.eq(X.clean_utf8('\192\128'), R .. R) -- overlong form of NUL
  T.eq(X.clean_utf8('\237\160\128'), R .. R .. R) -- a surrogate (U+D800)
  T.eq(X.clean_utf8('\244\144\128\128'), R .. R .. R .. R) -- above U+10FFFF
  T.eq(X.clean_utf8('\128x'), R .. 'x') -- a stray continuation byte
end)

T.case('truncate: text of at most max_chars characters comes back unchanged', function()
  T.eq(X.truncate('abc', 5), 'abc')
  T.eq(X.truncate('abc', 3), 'abc') -- exactly max_chars
  T.eq(X.truncate('', 0), '')
end)

T.case('truncate: longer text is cut to max_chars characters plus the mark, default U+2026', function()
  T.eq(X.truncate('abcdef', 3), 'abc…')
  T.eq(X.truncate('abcdef', 3, '\n…'), 'abc\n…')
  T.eq(X.truncate('abcdef', 3, ''), 'abc')
end)

T.case('truncate: counts characters, never cuts inside a multibyte character', function()
  T.eq(X.truncate('äöü', 2), 'äö…')
  T.eq(X.truncate('äöü', 3), 'äöü') -- 6 bytes, 3 characters
  T.eq(X.truncate('𝄞𝄞𝄞', 2), '𝄞𝄞…')
end)

T.case('truncate: a NUL byte is a character, and it works in a fast callback', function()
  -- buffer text can hold NUL; vim.fn.strchars raised E976 on it (review finding I3)
  T.eq(X.truncate('a\0bcd', 3), 'a\0b…')
  T.eq(X.truncate('a\0b', 3), 'a\0b')
  local fast
  local timer = vim.uv.new_timer()
  timer:start(0, 0, function()
    fast = { pcall(X.truncate, 'äöü', 2) }
    timer:close()
  end)
  vim.wait(2000, function()
    return fast ~= nil
  end, 5)
  T.eq(fast, { true, 'äö…' })
end)

T.case('truncate: an invalid byte counts as one character, nothing is cut inside a sequence', function()
  -- a lead byte takes only the continuation bytes it announces; any other byte is a character
  T.eq(X.truncate('\255\255\255', 2), '\255\255…')
  T.eq(X.truncate('ä\128x', 1), 'ä…') -- a stray continuation byte is a character of its own
  T.eq(X.truncate('\128ab', 0), '…')
  T.eq(X.truncate('\226\130a', 2), '\226\130…') -- a cut-off sequence: each byte is one
  -- a run of continuation bytes is not one long character (re-review of finding I3)
  T.eq(X.truncate('a' .. ('\128'):rep(100), 5), 'a\128\128\128\128…')
  T.eq(X.truncate(('\171'):rep(50), 3), '\171\171\171…')
  -- 5- and 6-byte forms are one character each, as vim.fn.strchars counts them
  T.eq(
    X.truncate('\248\136\128\128\128\252\132\128\128\128\128x', 2),
    '\248\136\128\128\128\252\132\128\128\128\128…'
  )
end)

T.case('truncate: counts as vim.fn.strchars does, invalid UTF-8 included (NUL aside)', function()
  -- what truncate did with strchars/strcharpart, which raise on NUL and need the main loop
  local function reference(s, n)
    if vim.fn.strchars(s) <= n then
      return s
    end
    return vim.fn.strcharpart(s, 0, n) .. '…'
  end
  -- bytes that make up characters of every length 1..6 as Vim counts them, and broken ones
  local pool = { 'a', '\128', '\191', '\192', '\223', '\224', '\239', '\240', '\247', '\248' }
  vim.list_extend(pool, { '\251', '\252', '\253', '\254', '\255', 'ä', '€', '𝄞', 'e\204\129' })
  vim.list_extend(pool, { '\128\128', '\128\128\128\128', '\191\191\191\191\191' })
  math.randomseed(7)
  for _ = 1, 5000 do
    local parts = {}
    for _ = 1, math.random(0, 10) do
      parts[#parts + 1] = pool[math.random(#pool)]
    end
    local s, n = table.concat(parts), math.random(0, 12)
    T.eq(X.truncate(s, n), reference(s, n), vim.inspect({ s, n }))
  end
end)

T.case('truncate: max_chars 0 leaves only the mark', function()
  T.eq(X.truncate('abc', 0), '…')
  T.eq(X.truncate('abc', 0, '!'), '!')
end)

T.case('truncate: invalid arguments raise', function()
  T.raises(function()
    X.truncate(nil, 3)
  end, 'truncate')
  T.raises(function()
    X.truncate('abc', -1)
  end, 'max_chars')
  T.raises(function()
    X.truncate('abc', 1.5)
  end, 'max_chars')
  T.raises(function()
    X.truncate('abc', '3')
  end, 'max_chars')
  T.raises(function()
    X.truncate('abc', 1, 5)
  end, 'mark')
end)

T.case('language_name: language codes, with and without region and encoding', function()
  T.eq(X.language_name('de'), 'German')
  T.eq(X.language_name('de_DE.UTF-8'), 'German')
  T.eq(X.language_name('pt_BR'), 'Portuguese')
  T.eq(X.language_name('zh_CN.UTF-8'), 'Chinese')
  T.eq(X.language_name('sr@latin'), 'English') -- unknown code
  T.eq(X.language_name('nb_NO@euro'), 'Norwegian')
  T.eq(X.language_name('FR_fr'), 'French')
end)

T.case('language_name: all twenty codes', function()
  local want = {
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
  local n = 0
  for code, name in pairs(want) do
    T.eq(X.language_name(code), name)
    T.eq(X.language_name(code .. '_XX.UTF-8'), name)
    n = n + 1
  end
  T.eq(n, 20)
end)

T.case('language_name: C, POSIX, empty and unknown give English', function()
  T.eq(X.language_name('C'), 'English')
  T.eq(X.language_name('C.UTF-8'), 'English')
  T.eq(X.language_name('POSIX'), 'English')
  T.eq(X.language_name(''), 'English')
  T.eq(X.language_name('xx_YY'), 'English')
  T.eq(X.language_name('deu'), 'English')
end)

T.case('language_name: nil reads v:lang', function()
  -- v:lang is read-only: swap the vim.v table for the call
  local orig = vim.v
  vim.v = setmetatable({ lang = 'pt_BR.UTF-8' }, { __index = orig })
  local ok, name = pcall(X.language_name)
  vim.v = orig
  T.ok(ok, tostring(name))
  T.eq(name, 'Portuguese')
end)

T.case('language_name: a lang that is neither nil nor a string raises', function()
  T.raises(function()
    X.language_name(5)
  end, 'language_name')
  T.raises(function()
    X.language_name({})
  end, 'lang')
end)

T.case('utf16_len counts a character beyond U+FFFF as two units', function()
  T.eq(X.utf16_len(''), 0)
  T.eq(X.utf16_len('abc'), 3)
  T.eq(X.utf16_len('a😀b'), 4)
  T.eq(X.utf16_len('äö€'), 3) -- BMP: one unit each
  T.eq(X.utf16_len('\240\144\128\128'), 2) -- U+10000, the first beyond the BMP
  T.eq(X.utf16_len('\239\191\191'), 1) -- U+FFFF, the last inside it
  T.eq(X.utf16_len('a\255b'), 3) -- a stray byte: one unit, like the U+FFFD clean_utf8 puts there
  T.eq(X.utf16_len('a\255b'), X.utf16_len(X.clean_utf8('a\255b')))
  T.raises(function()
    X.utf16_len(nil)
  end, 'needs s')
end)

T.case('utf16_sub slices by units from 0, a surrogate pair stays whole in the front part', function()
  T.eq(X.utf16_sub('a😀b', 1, 3), '😀')
  T.eq(X.utf16_sub('a😀b', 1, 2), '😀') -- the bound is inside the pair: the pair stays
  T.eq(X.utf16_sub('a😀b', 0, 1), 'a')
  T.eq(X.utf16_sub('a😀b', 2, 4), 'b') -- the start is inside the pair: it begins after it
  T.eq(X.utf16_sub('a😀b', 0, 4), 'a😀b')
  T.eq(X.utf16_sub('a😀b', 3), 'b') -- j nil: to the end
  T.eq(X.utf16_sub('a😀b', 0, 99), 'a😀b') -- past the end is the end
  T.eq(X.utf16_sub('a😀b', 4, 9), '')
  T.eq(X.utf16_sub('a😀b', 2, 2), '')
  T.eq(X.utf16_sub('a😀b', 3, 1), '')
  T.eq(X.utf16_sub('', 0, 3), '')
  T.eq(X.utf16_sub('äöü', 1, 2), 'ö')
  T.raises(function()
    X.utf16_sub('abc', -1, 2)
  end, 'whole number')
  T.raises(function()
    X.utf16_sub('abc', 0, 1.5)
  end, 'whole number')
end)

T.case('is_js_space: exactly the characters of JavaScript \\s', function()
  local spaces =
    { 0x09, 0x0A, 0x0B, 0x0C, 0x0D, 0x20, 0xA0, 0x1680, 0x2028, 0x2029, 0x202F, 0x205F, 0x3000, 0xFEFF }
  for cp = 0x2000, 0x200A do
    spaces[#spaces + 1] = cp
  end
  local set = {}
  for _, cp in ipairs(spaces) do
    set[cp] = true
    T.ok(X.is_js_space(cp), ('U+%04X'):format(cp))
  end
  -- every other BMP code point is none: the set is exact, not a superset
  for cp = 0, 0xFFFF do
    if not set[cp] then
      T.ok(not X.is_js_space(cp), ('U+%04X'):format(cp))
    end
  end
  T.ok(not X.is_js_space(0x200B), 'zero width space is no space to JavaScript')
  T.ok(not X.is_js_space(0x85), 'NEL is no space to JavaScript')
  T.ok(not X.is_js_space(0x180E), 'Mongolian vowel separator is no space to JavaScript')
end)

T.case('js_trim strips both ends, NBSP and U+3000 included, nothing inside', function()
  T.eq(X.js_trim('\194\160 x \227\128\128'), 'x')
  T.eq(X.js_trim('  a  b \t\n'), 'a  b')
  T.eq(X.js_trim(''), '')
  T.eq(X.js_trim(' \194\160\239\187\191\226\128\168'), '')
  T.eq(X.js_trim('\226\128\169x\226\128\175'), 'x') -- U+2029 ... U+202F
  T.eq(X.js_trim('ä x ä'), 'ä x ä') -- not eaten: the last byte of ä is 0xA4, of NBSP 0xA0
  T.eq(X.js_trim('x\227\128'), 'x\227\128') -- a truncated U+3000 is no space
  T.eq(X.js_trim('x\194'), 'x\194')
  T.eq(X.js_trim('\128x'), '\128x') -- a stray continuation byte stays
  T.eq(vim.trim('\194\160x'), '\194\160x', 'control: vim.trim keeps the NBSP')
end)

T.case('char_at reads the code point and byte length at a byte index', function()
  local cp, len = X.char_at('aä€😀', 1)
  T.eq({ cp, len }, { 97, 1 })
  cp, len = X.char_at('aä€😀', 2)
  T.eq({ cp, len }, { 0xE4, 2 })
  cp, len = X.char_at('aä€😀', 4)
  T.eq({ cp, len }, { 0x20AC, 3 })
  cp, len = X.char_at('aä€😀', 7)
  T.eq({ cp, len }, { 0x1F600, 4 })
  cp, len = X.char_at('\195', 1) -- cut off: one character of its own
  T.eq({ cp, len }, { 0xC3, 1 })
  T.raises(function()
    X.char_at('abc', 4)
  end, 'byte index')
end)

T.case('byte_less compares bytes: Z before a, a before ä, equal is not less', function()
  T.ok(X.byte_less('Z', 'a'))
  T.ok(not X.byte_less('a', 'Z'))
  T.ok(X.byte_less('a', 'ä'))
  T.ok(not X.byte_less('a', 'a'))
  T.ok(X.byte_less('', 'a'))
  T.ok(not X.byte_less('a', ''))
  T.ok(not X.byte_less('', ''))
  T.ok(X.byte_less('ab', 'abc')) -- a prefix is smaller
  T.ok(not X.byte_less('abc', 'ab'))
  T.ok(X.byte_less('Z27609.md', 'a209804.md'))
  T.ok(X.byte_less('aaaaaaaaaaaaaaaaaaaaa1', 'aaaaaaaaaaaaaaaaaaaaa2'), 'a difference after several blocks')
  T.ok(X.byte_less('aaaaaaaa', 'aaaaaaaab'), 'a prefix of exactly one block')
  T.ok(X.byte_less('\239\191\191', '\240\144\128\128'), 'U+FFFF before U+10000: code point order')
  T.raises(function()
    X.byte_less('a', nil)
  end, 'two strings')
end)

-- Documented guard for builds whose string `<` collates by locale (PUC-Lua's strcoll). LuaJIT, which
-- Neovim ships, compares bytes whatever the locale (measured on 0.12.6), so here this cannot turn
-- red; the counter-check for byte_less itself is a comparator that really differs (case folding).
T.case('byte_less stays bytewise under a collating locale', function()
  -- selene: allow(incorrect_standard_library_use) -- selene's lua51 std does not model the nil query
  local previous = os.setlocale(nil, 'collate')
  local set
  for _, name in ipairs({ 'de_DE.UTF-8', 'de_DE.utf8', 'en_US.UTF-8', 'en_US.utf8' }) do
    set = os.setlocale(name, 'collate')
    if set then
      break
    end
  end
  if not set then
    io.write('SKIPPED: no de_DE or en_US collate locale installed, the locale guard measured nothing\n')
    return
  end
  local ok, err = pcall(function()
    T.ok(X.byte_less('Z', 'a'))
    T.ok(X.byte_less('a', 'ä'))
    T.ok(not X.byte_less('a', 'a'))
    T.ok(X.byte_less('B', 'a'))
  end)
  os.setlocale(previous, 'collate')
  if not ok then
    error(err, 0)
  end
end)

T.case('counter-check: a comparator that folds case disagrees with byte_less', function()
  local function folded(a, b)
    return a:lower() < b:lower()
  end
  T.ok(X.byte_less('Z', 'a'))
  T.ok(not folded('Z', 'a'), 'the mutant puts a before Z, byte_less does not')
  T.ok(X.byte_less('B', 'a') ~= folded('B', 'a'))
end)
