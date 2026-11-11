-- Aligning two lists of lines along a longest common subsequence, with a fixed rule so that two
-- implementations (this one and a TypeScript one) agree line for line:
--   1. the common prefix is matched first;
--   2. then the common suffix, over what the prefix left (the two never overlap);
--   3. the middle is aligned with a suffix-LCS table, walked from the top: equal lines are kept,
--      otherwise the line of `a` is dropped when L[i+1][j] >= L[i][j+1] (a tie drops first), else the
--      line of `b` is added; a side that is used up drops or adds the rest of the other;
--   4. when the middle has more than `cell_limit` cells (n * m) there is no table: every middle line of
--      `a` is dropped, then every middle line of `b` is added. At exactly the limit the table is built.
local M = {}

--- The default for `opts.cell_limit`: 500 x 500 lines.
M.CELL_LIMIT = 250000

local function fail(msg)
  error('nvim-kit linediff: ' .. msg, 3)
end

local function check_lines(name, lines)
  if type(lines) ~= 'table' then
    fail(('%s must be a list of strings, got %s'):format(name, type(lines)))
  end
  for i = 1, #lines do
    if type(lines[i]) ~= 'string' then
      fail(('%s[%d] must be a string, got %s'):format(name, i, type(lines[i])))
    end
  end
end

--- Aligns the lines of `a` (the text as it is) with those of `b` (the text it should be).
---
--- Returns `{ prefix, suffix, common, dropped, added }`, all positions 1-based:
--- - `prefix`, `suffix`: the lengths of the common prefix and of the common suffix after it;
--- - `common`: the lines kept, prefix and suffix included (`#a - common` lines of `a` are dropped,
---   `#b - common` lines of `b` are added);
--- - `dropped`: the indices in `a` of the lines that are not in `b`, ascending;
--- - `added`: runs of lines of `b` that are not in `a`, in order, each `{ at, count }`, `at` being the
---   index of the line of `a` the run sits in front of (`#a + 1` behind the last one). When a run follows
---   a dropped line, `at` is that line's index plus one.
---
--- `opts.cell_limit` (default `M.CELL_LIMIT`, a number >= 0) is the largest middle, in cells (rows
--- times columns), that is aligned with a table. Neither input is changed.
function M.align(a, b, opts)
  check_lines('a', a)
  check_lines('b', b)
  if opts ~= nil and type(opts) ~= 'table' then
    fail('opts must be a table, got ' .. type(opts))
  end
  local limit = opts and opts.cell_limit
  if limit == nil then
    limit = M.CELL_LIMIT
  elseif type(limit) ~= 'number' or limit ~= limit or limit < 0 then
    fail('cell_limit must be a number >= 0, got ' .. tostring(limit))
  end

  local na, nb = #a, #b
  local p = 0
  while p < na and p < nb and a[p + 1] == b[p + 1] do
    p = p + 1
  end
  local q = 0
  while q < na - p and q < nb - p and a[na - q] == b[nb - q] do
    q = q + 1
  end
  local n, m = na - p - q, nb - p - q

  local dropped, added = {}, {}
  local lcs = 0

  if n * m > limit then
    for i = 1, n do
      dropped[i] = p + i
    end
    if m > 0 then
      added[1] = { at = p + n + 1, count = m }
    end
  else
    -- rows[i][j] is the LCS of a[p+i ..] and b[p+j ..] over the middle, i in 1..n+1, j in 1..m+1
    local rows = {}
    for i = 1, n + 1 do
      local row = {}
      for j = 1, m + 1 do
        row[j] = 0
      end
      rows[i] = row
    end
    for i = n, 1, -1 do
      local row, below = rows[i], rows[i + 1]
      local ai = a[p + i]
      for j = m, 1, -1 do
        if ai == b[p + j] then
          row[j] = below[j + 1] + 1
        else
          local down, right = below[j], row[j + 1]
          row[j] = down >= right and down or right
        end
      end
    end
    lcs = rows[1][1]

    local i, j = 1, 1
    local run -- the added run being extended, nil after a kept or dropped line
    while i <= n and j <= m do
      if a[p + i] == b[p + j] then
        i, j, run = i + 1, j + 1, nil
      elseif rows[i + 1][j] >= rows[i][j + 1] then
        dropped[#dropped + 1] = p + i
        i, run = i + 1, nil
      else
        if run then
          run.count = run.count + 1
        else
          run = { at = p + i, count = 1 }
          added[#added + 1] = run
        end
        j = j + 1
      end
    end
    while i <= n do
      dropped[#dropped + 1] = p + i
      i = i + 1
    end
    -- the loop ended on a kept or dropped line or with b used up, so no run is open here
    if j <= m then
      added[#added + 1] = { at = p + i, count = m - j + 1 }
    end
  end

  return { prefix = p, suffix = q, common = p + q + lcs, dropped = dropped, added = added }
end

return M
