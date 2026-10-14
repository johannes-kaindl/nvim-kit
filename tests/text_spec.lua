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
