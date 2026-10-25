-- Adapters for the code-kit vectors of nvim_kit.chunker: code-kit's names and shapes in, the
-- port's out. Keys are vector function names.
local K = require('nvim_kit.chunker')

local function chunks(list)
  local out = {}
  for i, c in ipairs(list) do
    out[i] = { text = c.text, startOffset = c.start_offset, endOffset = c.end_offset }
  end
  return out
end

return {
  chunkMarkdown = function(text, max_chars, overlap)
    return chunks(K.chunk_markdown(text, max_chars, overlap))
  end,
  chunkMarkdownUtf16 = function(text, max_chars, overlap)
    return chunks(K.chunk_markdown(text, max_chars, overlap))
  end,
  stripFrontmatter = function(text)
    return K.strip_frontmatter(text)
  end,
}
