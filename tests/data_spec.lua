local T = require('nvim_kit.test')
local D = require('nvim_kit.data')

local function file(text)
  local p = vim.fn.tempname() .. '.json'
  vim.fn.writefile(vim.split(text, '\n'), p)
  return p
end

T.case('loads a file with the expected schema; null fields are absent', function()
  local d = D.load(file('{"schema": 2, "name": "x", "gone": null, "list": [1, 2]}'), { schema = 2 })
  T.eq(d.name, 'x')
  T.eq(rawget(d, 'gone'), nil)
  T.eq(d.list, { 1, 2 })
end)

T.case('a different schema is refused', function()
  T.raises(function()
    D.load(file('{"schema": 1}'), { schema = 2 })
  end, 'has schema 1, expected 2')
end)

T.case('a missing schema is refused', function()
  T.raises(function()
    D.load(file('{"name": "x"}'), { schema = 1 })
  end, 'has schema nil, expected 1')
end)

T.case('broken JSON is refused with the path', function()
  local p = file('{"schema": 1,')
  T.raises(function()
    D.load(p, { schema = 1 })
  end, p)
end)

T.case('a missing file is refused', function()
  T.raises(function()
    D.load('/nonexistent/x.json', { schema = 1 })
  end, 'cannot read /nonexistent/x.json')
end)

T.case('opts.schema is required', function()
  T.raises(function()
    D.load(file('{"schema": 1}'), {})
  end, 'opts.schema')
end)
