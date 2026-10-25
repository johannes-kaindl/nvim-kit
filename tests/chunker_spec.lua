local T = require('nvim_kit.test')
local C = require('nvim_kit.conformance')
local K = require('nvim_kit.chunker')
local here = vim.fn.fnamemodify(debug.getinfo(1, 'S').source:sub(2), ':p:h')
local VECTORS = here .. '/conformance/code-kit'
-- The vectors use code-kit's names and shapes; the adapters are the only translation.
local ADAPTERS = dofile(here .. '/adapters/chunker.lua')

local NAMES = { 'chunkMarkdown', 'chunkMarkdownUtf16', 'stripFrontmatter' }

local function run(adapters)
  local vectors = C.load_dir(VECTORS)
  local failures, cases = {}, 0
  for _, name in ipairs(NAMES) do
    T.ok(vectors[name], 'no vector file for ' .. name)
    cases = cases + #vectors[name].cases
    for _, f in ipairs(C.run(vectors[name], adapters[name])) do
      f['function'] = name
      failures[#failures + 1] = f
    end
  end
  return cases, failures
end

local function with(name, wrap)
  local adapters = vim.tbl_extend('force', {}, ADAPTERS)
  adapters[name] = wrap(ADAPTERS[name])
  return adapters
end

local function failed_names(failures)
  local names = {}
  for _, f in ipairs(failures) do
    names[#names + 1] = f.name
  end
  table.sort(names)
  return names
end

T.case('passes every code-kit chunker vector (15 + 5 + 11 cases)', function()
  local vectors = C.load_dir(VECTORS)
  T.eq(#vectors.chunkMarkdown.cases, 15)
  T.eq(#vectors.chunkMarkdownUtf16.cases, 5)
  T.eq(#vectors.stripFrontmatter.cases, 11)
  local cases, failures = run(ADAPTERS)
  T.eq(cases, 31)
  T.eq(failures, {})
end)

T.case('counter-check: an overlap of zero fails the vectors that cut hard', function()
  local _, failures = run(with('chunkMarkdown', function(real)
    return function(text, max, _)
      return real(text, max, 0)
    end
  end))
  T.ok(#failures > 0)
  T.ok(vim.tbl_contains(failed_names(failures), 'long prose, hard cuts with overlap'))
end)

T.case('counter-check: counting code points instead of UTF-16 units fails the emoji vectors', function()
  -- 500 emoji are 500 code points (<= 800): one chunk, where JavaScript's 1000 units give two.
  local _, failures = run(with('chunkMarkdownUtf16', function(real)
    return function(text, max, overlap)
      return real(text, max * 2, overlap)
    end
  end))
  T.ok(vim.tbl_contains(failed_names(failures), '500 emoji are 1000 units, two chunks'))
end)

T.case('counter-check: a frontmatter strip that gives up at a blank line fails', function()
  local _, failures = run(with('stripFrontmatter', function(real)
    return function(text)
      if text:find('\n\n---', 1, true) then
        return text
      end
      return real(text)
    end
  end))
  T.ok(#failures > 0)
end)

-- A line start is `\n`, `\r`, U+2028 or U+2029 (JavaScript's `^` with the m flag). The vectors pin the
-- lone carriage return; these pin the other two, which the vectors do not contain.
local function heading_after(sep)
  return ('x'):rep(700) .. sep .. '# H\n' .. ('y'):rep(700)
end

T.case('a heading after U+2028, U+2029, CR and LF is a line start: the cut is at the heading', function()
  for _, sep in ipairs({ '\226\128\168', '\226\128\169', '\r', '\n' }) do
    local got = K.chunk_markdown(heading_after(sep))
    T.eq(#got, 2, vim.inspect(sep))
    T.eq({ got[1].start_offset, got[1].end_offset }, { 0, 701 }, vim.inspect(sep))
    T.eq({ got[2].start_offset, got[2].end_offset }, { 701, 1405 }, vim.inspect(sep))
    T.eq(got[1].text, ('x'):rep(700))
    T.eq(got[2].text:sub(1, 3), '# H')
  end
end)

T.case(
  'counter-check: a separator that is no line start leaves the heading in the middle of a chunk',
  function()
    -- U+2027 (hyphenation point) looks like U+2028 and is none: the first chunk is a hard cut at 800.
    local got = K.chunk_markdown(heading_after('\226\128\167'))
    T.eq(got[1].end_offset, 800)
    -- NEL (U+0085) is a line break to Unicode, not to JavaScript.
    got = K.chunk_markdown(heading_after('\194\133'))
    T.eq(got[1].end_offset, 800)
  end
)

-- The vectors put their seven-hash and no-space lines at the start of the text, where position 0 is a cut
-- anyway; here they sit in the middle (expected offsets from code-kit 0.31.1's chunkMarkdown).
T.case('a heading in the middle: one to six hashes then whitespace, nothing else', function()
  local function cuts(heading)
    local got = K.chunk_markdown(('x'):rep(700) .. '\n' .. heading .. ('y'):rep(700))
    return vim.tbl_map(function(c)
      return { c.start_offset, c.end_offset }
    end, got)
  end
  T.eq(cuts('###### H\n'), { { 0, 701 }, { 701, 1410 } })
  T.eq(cuts('# H\n'), { { 0, 701 }, { 701, 1405 } })
  T.eq(cuts('#\n'), { { 0, 701 }, { 701, 1403 } }, 'a hash and a line break is a heading')
  T.eq(cuts('####### H\n'), { { 0, 800 }, { 650, 1411 } }, 'seven hashes are none')
  T.eq(cuts('#nein H\n'), { { 0, 800 }, { 650, 1409 } }, 'a hash without whitespace is none')
end)

T.case('chunk_markdown: offsets are UTF-16 units of the text after frontmatter and trim', function()
  local got = K.chunk_markdown('---\na: 1\n---\n  ' .. ('😀'):rep(500) .. '  ')
  T.eq(#got, 2)
  T.eq({ got[1].start_offset, got[1].end_offset }, { 0, 800 })
  T.eq(got[1].text, ('😀'):rep(400))
  T.eq(got[2].start_offset, 650)
  T.eq(got[2].end_offset, 1000)
end)

T.case(
  'chunk_markdown: a cut inside a surrogate pair keeps the whole character in the leading chunk',
  function()
    -- JavaScript can cut a pair in two; UTF-8 cannot. Units: 6; windows of 3 cut mid-pair at unit 3.
    local got = K.chunk_markdown(('😀'):rep(3), 3, 1)
    T.eq(#got, 3)
    T.eq({ got[1].text, got[1].start_offset, got[1].end_offset }, { '😀😀', 0, 3 })
    -- The next window starts at unit 2, the start of the second emoji, and ends mid-pair at 5.
    T.eq({ got[2].text, got[2].start_offset, got[2].end_offset }, { '😀😀', 2, 5 })
    T.eq({ got[3].text, got[3].start_offset, got[3].end_offset }, { '😀', 4, 6 })
    for _, c in ipairs(got) do
      T.eq(vim.fn.strchars(c.text), #c.text / 4, 'every chunk is whole characters')
    end
  end
)

T.case('chunk_markdown: invalid UTF-8 is replaced, the chunks are valid text', function()
  local got = K.chunk_markdown('a\255b')
  T.eq(got[1].text, 'a\239\191\189b')
  T.eq(got[1].end_offset, 3)
end)

T.case('chunk_markdown: max_units and overlap default to 800 and 150', function()
  local text = ('word '):rep(400)
  T.eq(K.chunk_markdown(text), K.chunk_markdown(text, 800, 150))
  T.ok(#K.chunk_markdown(text) > 1)
  T.ok(#K.chunk_markdown(text, 5000, 0) == 1, 'control: a larger window gives one chunk')
end)

T.case('chunk_markdown: wrong arguments raise', function()
  T.raises(function()
    K.chunk_markdown(nil)
  end, 'needs s')
  T.raises(function()
    K.chunk_markdown('a', 0)
  end, 'max_units')
  T.raises(function()
    K.chunk_markdown('a', 10.5)
  end, 'max_units')
  T.raises(function()
    K.chunk_markdown('a', 10, -1)
  end, 'overlap')
  T.raises(function()
    K.chunk_markdown('a', 10, 10)
  end, 'smaller than max_units')
  T.raises(function()
    K.strip_frontmatter(1)
  end, 'needs s')
end)

T.case('strip_frontmatter: JavaScript whitespace counts, also beyond ASCII', function()
  -- NBSP and U+3000 around the dashes' line breaks are `\s` in JavaScript.
  T.eq(K.strip_frontmatter('---\194\160\na\n---\227\128\128\nB'), 'B')
  T.eq(K.strip_frontmatter('---\226\128\168\na\n---\nB'), 'B') -- U+2028 in the opening run
  T.eq(K.strip_frontmatter('---x\na\n---\nB'), '---x\na\n---\nB')
end)
