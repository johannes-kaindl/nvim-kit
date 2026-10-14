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
  T.eq(X.language_name(nil), X.language_name(vim.v.lang))
  -- v:lang is read-only: a child Neovim under a locale shows the default end to end
  local root = vim.fn.fnamemodify(debug.getinfo(1, 'S').source:sub(2), ':p:h:h')
  local code =
    'vim.opt.rtp:prepend(vim.env.KIT_ROOT) io.write(vim.v.lang, "|", require("nvim_kit.text").language_name())'
  local r = vim
    .system({ vim.v.progpath, '--headless', '-u', 'NONE', '-l', '-' }, {
      stdin = code,
      env = { KIT_ROOT = root, LC_ALL = 'de_DE.UTF-8', LANG = 'de_DE.UTF-8' },
      text = true,
    })
    :wait()
  T.eq(r.code, 0, r.stderr)
  local lang, name = r.stdout:match('^(.-)|(.*)$')
  T.eq(name, X.language_name(lang)) -- whatever locale the machine has, the default follows it
  if lang:sub(1, 2) == 'de' then
    T.eq(name, 'German')
  end
end)

T.case('language_name: a lang that is neither nil nor a string raises', function()
  T.raises(function()
    X.language_name(5)
  end, 'language_name')
  T.raises(function()
    X.language_name({})
  end, 'lang')
end)
