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
