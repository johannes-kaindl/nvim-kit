-- Byte offsets into a range of buffer lines, and replacements applied back to them. The text of a
-- range is its lines joined with "\n" plus one final "\n" (what a search over the range sees, see
-- nvim_kit.rg). Offsets and columns are bytes, as Neovim's are, so multibyte characters need no
-- conversion. The final "\n" belongs to the range's text, not to the buffer: an edit that reaches
-- into it ends at the end of the last line instead, so text after the range is never joined in.
local M = {}

--- The text a search over lines sees: the lines joined with "\n", plus a final "\n".
function M.text(lines)
  return table.concat(lines, '\n') .. '\n'
end

--- The byte offset of each line's start in M.text(lines) (0-based offsets, 1-based list).
function M.line_starts(lines)
  local starts, at = {}, 0
  for i, l in ipairs(lines) do
    starts[i] = at
    at = at + #l + 1
  end
  return starts
end

--- Row and column (0-based, relative to the first line, bytes) of a byte offset into
--- M.text(lines). An offset at or past the final "\n" is the end of the last line.
function M.position(lines, starts, offset)
  local n = #lines
  if n == 0 then
    return 0, 0
  end
  if offset >= starts[n] + #lines[n] then
    return n - 1, #lines[n]
  end
  local lo, hi = 1, n
  while lo < hi do
    local mid = math.floor((lo + hi + 1) / 2)
    if starts[mid] <= offset then
      lo = mid
    else
      hi = mid - 1
    end
  end
  return lo - 1, offset - starts[lo]
end

--- Each edit { start, stop, text } (byte offsets into M.text(lines), stop exclusive) with its
--- positions added: row, col, end_row, end_col (0-based, relative to the first line). An edit
--- that reaches into the final "\n" loses one trailing "\n" of its text, since that "\n" stays.
function M.locate(lines, list)
  local starts = M.line_starts(lines)
  local total = #M.text(lines)
  local out = {}
  for i, e in ipairs(list) do
    local row, col = M.position(lines, starts, e.start)
    local end_row, end_col = M.position(lines, starts, e.stop)
    local text = e.text
    if e.stop >= total and text:sub(-1) == '\n' then
      text = text:sub(1, -2)
    end
    out[i] = vim.tbl_extend('force', e, {
      row = row,
      col = col,
      end_row = end_row,
      end_col = end_col,
      text = text,
    })
  end
  return out
end

--- Replace the edits' spans of buf, whose lines first..first+#lines-1 (0-based first) must still
--- be exactly lines: else nothing is written and the result is false, 'changed'. Edits are
--- { start, stop, text } as for M.locate; they go in back to front, so earlier offsets stay
--- valid, and all of them form one undo step. Raises on overlapping edits. Returns true, count.
function M.apply(buf, first, lines, list)
  local now = vim.api.nvim_buf_get_lines(buf, first, first + #lines, false)
  if not vim.deep_equal(now, lines) then
    return false, 'changed'
  end
  local located = M.locate(lines, list)
  -- Close the buffer's open undo block first. Vim closes it on a keystroke only in the current
  -- buffer: an edit typed in buf before switching away would otherwise join these edits, and one
  -- `u` would take back both (measured 2026-10-14).
  vim.api.nvim_buf_call(buf, function()
    vim.cmd('let &g:undolevels = &g:undolevels')
  end)
  table.sort(located, function(a, b)
    if a.start ~= b.start then
      return a.start > b.start
    end
    return a.stop > b.stop
  end)
  for i = 2, #located do
    if located[i].stop > located[i - 1].start then
      error(
        ('nvim-kit edits: edits overlap at bytes %d..%d and %d..%d'):format(
          located[i].start,
          located[i].stop,
          located[i - 1].start,
          located[i - 1].stop
        ),
        2
      )
    end
  end
  for _, e in ipairs(located) do
    vim.api.nvim_buf_set_text(
      buf,
      first + e.row,
      e.col,
      first + e.end_row,
      e.end_col,
      vim.split(e.text, '\n', { plain = true })
    )
  end
  return true, #located
end

return M
