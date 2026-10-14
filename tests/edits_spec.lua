local T = require('nvim_kit.test')
local E = require('nvim_kit.edits')

local function buffer(lines)
  local buf = vim.api.nvim_create_buf(true, false)
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
  -- A headless script runs as one command: close the undo block, as a keystroke would.
  vim.api.nvim_buf_call(buf, function()
    vim.cmd('let &g:undolevels = &g:undolevels')
  end)
  return buf
end

local function get(buf)
  return vim.api.nvim_buf_get_lines(buf, 0, -1, false)
end

local function undo(buf)
  vim.api.nvim_buf_call(buf, function()
    vim.cmd('silent undo')
  end)
end

T.case('text and line_starts: lines joined with \\n plus a final \\n, offsets in bytes', function()
  local lines = { 'ab', 'Äx', '' }
  T.eq(E.text(lines), 'ab\nÄx\n\n')
  T.eq(E.line_starts(lines), { 0, 3, 7 })
end)

T.case('position: row and byte column of an offset, multibyte included', function()
  local lines = { 'ab', 'Äx', 'c' }
  local s = E.line_starts(lines)
  T.eq({ E.position(lines, s, 0) }, { 0, 0 })
  T.eq({ E.position(lines, s, 2) }, { 0, 2 }) -- the "\n" after "ab": end of line 1
  T.eq({ E.position(lines, s, 3) }, { 1, 0 })
  T.eq({ E.position(lines, s, 5) }, { 1, 2 }) -- after "Ä" (two bytes)
  T.eq({ E.position(lines, s, 7) }, { 2, 0 })
  T.eq({ E.position(lines, s, 8) }, { 2, 1 }) -- the final "\n": end of the last line
  T.eq({ E.position(lines, s, 9) }, { 2, 1 }) -- past it, too
end)

T.case('locate: a hit across lines; one reaching into the final \\n keeps that \\n', function()
  local lines = { 'a', 'b' }
  local got = E.locate(lines, {
    { start = 0, stop = 3, text = 'X' },
    { start = 2, stop = 4, text = 'Y\n' },
  })
  T.eq(got[1], { start = 0, stop = 3, text = 'X', row = 0, col = 0, end_row = 1, end_col = 1 })
  T.eq(got[2], { start = 2, stop = 4, text = 'Y', row = 1, col = 0, end_row = 1, end_col = 1 })
end)

T.case('apply: replaces back to front, so later offsets stay valid', function()
  local buf = buffer({ 'head', 'a1 a22 a333', 'tail' })
  local lines = { 'a1 a22 a333' }
  local ok, n = E.apply(buf, 1, lines, {
    { start = 0, stop = 2, text = 'B' },
    { start = 3, stop = 6, text = 'BBBB' },
    { start = 7, stop = 11, text = '' },
  })
  T.eq({ ok, n }, { true, 3 })
  T.eq(get(buf), { 'head', 'B BBBB ', 'tail' })
end)

T.case('apply: replacement text with \\n makes new lines; a multi-line hit joins lines', function()
  local buf = buffer({ 'a b', 'c', 'd' })
  E.apply(buf, 0, { 'a b', 'c', 'd' }, {
    { start = 1, stop = 2, text = '\n' },
    { start = 3, stop = 5, text = '+' }, -- "\nc": joins line 2 into line 1
  })
  T.eq(get(buf), { 'a', 'b+', 'd' })
end)

T.case('apply: the line after the range is never joined in', function()
  local buf = buffer({ 'x1', 'x2', 'after' })
  -- the range is lines 1..2; a hit "x2\n" ends in the range's final "\n"
  E.apply(buf, 0, { 'x1', 'x2' }, { { start = 3, stop = 6, text = 'y\n' } })
  T.eq(get(buf), { 'x1', 'y', 'after' })
  E.apply(buf, 0, { 'x1', 'y' }, { { start = 3, stop = 5, text = '' } })
  T.eq(get(buf), { 'x1', '', 'after' })
end)

T.case('apply: all edits are one undo step', function()
  local buf = buffer({ 'a a a' })
  E.apply(buf, 0, { 'a a a' }, {
    { start = 0, stop = 1, text = 'b' },
    { start = 2, stop = 3, text = 'b' },
    { start = 4, stop = 5, text = 'b' },
  })
  T.eq(get(buf), { 'b b b' })
  undo(buf)
  T.eq(get(buf), { 'a a a' })
end)

T.case('apply: does not join the undo step of a change made before it in that buffer', function()
  local buf = buffer({ 'one', 'two' })
  -- an edit in buf that nothing closed: buf is not the current buffer, so no keystroke synced it
  vim.api.nvim_buf_set_text(buf, 0, 0, 0, 3, { 'ONE' })
  E.apply(buf, 1, { 'two' }, { { start = 0, stop = 3, text = 'TWO' } })
  T.eq(get(buf), { 'ONE', 'TWO' })
  undo(buf)
  T.eq(get(buf), { 'ONE', 'two' })
end)

T.case('apply: writes nothing when the lines are no longer what was searched', function()
  local buf = buffer({ 'a', 'b' })
  local ok, why = E.apply(buf, 0, { 'a', 'B' }, { { start = 0, stop = 1, text = 'x' } })
  T.eq({ ok, why }, { false, 'changed' })
  T.eq(get(buf), { 'a', 'b' })
  ok, why = E.apply(buf, 1, { 'b', 'c' }, { { start = 0, stop = 1, text = 'x' } })
  T.eq({ ok, why }, { false, 'changed' }) -- the range now runs past the buffer's end
end)

T.case('apply: overlapping edits raise before anything is written', function()
  local buf = buffer({ 'abcd' })
  T.raises(function()
    E.apply(buf, 0, { 'abcd' }, { { start = 0, stop = 2, text = 'x' }, { start = 1, stop = 3, text = 'y' } })
  end, 'overlap')
  T.eq(get(buf), { 'abcd' })
end)

T.case('apply: invalid arguments raise before anything is read or written', function()
  -- review finding I4: first = -2 compared 'ccc' but wrote into 'bbb'; an empty lines list
  -- inserted into the next line; stop < start raised only after an earlier edit was written
  local buf = buffer({ 'aaa', 'bbb', 'ccc' })
  local one = { { start = 0, stop = 1, text = 'x' } }
  local function raises(first, lines, list, what)
    T.raises(function()
      E.apply(buf, first, lines, list)
    end, what)
    T.eq(get(buf), { 'aaa', 'bbb', 'ccc' }, what)
  end
  raises(-2, { 'ccc' }, one, 'first')
  raises(0.5, { 'aaa' }, one, 'first')
  raises('0', { 'aaa' }, one, 'first')
  raises(0, 'aaa', one, 'lines')
  raises(0, { 'aaa', 1 }, one, 'lines')
  raises(1, {}, one, 'empty lines')
  raises(0, { 'aaa' }, 'x', 'list')
  raises(0, { 'aaa' }, { 'x' }, 'edit 1')
  raises(0, { 'aaa' }, { { start = -1, stop = 1, text = 'x' } }, 'edit 1')
  raises(0, { 'aaa' }, { { start = 0.5, stop = 1, text = 'x' } }, 'edit 1')
  raises(0, { 'aaa' }, { { start = 0, stop = '1', text = 'x' } }, 'edit 1')
  raises(0, { 'aaa' }, { { start = 0, stop = 1, text = 5 } }, 'edit 1')
  raises(
    0,
    { 'aaa', 'bbb' },
    { { start = 4, stop = 5, text = 'X' }, { start = 2, stop = 1, text = 'Y' } },
    'edit 2'
  )
  -- counter-check: the same buffer takes valid arguments, and empty lines with no edits are fine
  T.eq({ E.apply(buf, 1, {}, {}) }, { true, 0 })
  T.eq({ E.apply(buf, 2, { 'ccc' }, one) }, { true, 1 })
  T.eq(get(buf), { 'aaa', 'bbb', 'xcc' })
end)

T.case('apply: insertions at one offset keep their order in the list', function()
  local buf = buffer({ 'ab' })
  E.apply(buf, 0, { 'ab' }, {
    { start = 1, stop = 1, text = 'X' },
    { start = 1, stop = 1, text = 'Y' },
    { start = 1, stop = 1, text = 'Z' },
  })
  T.eq(get(buf), { 'aXYZb' })
end)

T.case('apply: an insertion at the start of a replaced span stays in front of it', function()
  local buf = buffer({ 'ab' })
  E.apply(buf, 0, { 'ab' }, { { start = 0, stop = 0, text = '>' }, { start = 0, stop = 1, text = 'A' } })
  T.eq(get(buf), { '>Ab' })
end)
