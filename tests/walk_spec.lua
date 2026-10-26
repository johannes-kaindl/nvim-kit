local T = require('nvim_kit.test')
local W = require('nvim_kit.walk')

local uv = vim.uv or vim.loop

-- A scratch tree: `files` are relative paths (parents are created), `dirs` extra empty directories.
local function tree(files, dirs)
  local root = vim.fn.tempname()
  vim.fn.mkdir(root, 'p')
  for _, d in ipairs(dirs or {}) do
    vim.fn.mkdir(root .. '/' .. d, 'p')
  end
  for _, f in ipairs(files) do
    vim.fn.mkdir(vim.fn.fnamemodify(root .. '/' .. f, ':h'), 'p')
    local h = assert(io.open(root .. '/' .. f, 'wb'))
    h:write('x')
    h:close()
  end
  return root
end

local function drop(root)
  vim.fn.delete(root, 'rf')
end

T.case('markdown: lists *.md relative, with / separators, sorted by bytes', function()
  local root =
    tree({ 'b.md', 'a/alpha.md', 'a/Zed.md', 'A.md', 'ä.md', 'a/deep/er/n.md', 'note.txt', 'x.MD', 'md' })
  local r = W.markdown(root)
  T.eq(r.paths, { 'A.md', 'a/Zed.md', 'a/alpha.md', 'a/deep/er/n.md', 'b.md', 'ä.md' })
  T.eq(r.skipped, {})
  drop(root)
end)

T.case('markdown: a name starting with a dot is neither listed nor entered', function()
  local root =
    tree({ 'ok.md', '.git/x.md', '.obsidian/plugins/y.md', 'a/.hidden.md', 'a/.trash/z.md', '.md' })
  T.eq(W.markdown(root).paths, { 'ok.md' })
  drop(root)
end)

T.case('markdown: exclude prefixes (startsWith, case-sensitive) prune files and directories', function()
  local root = tree({
    'Templates/t.md',
    'Templates/sub/u.md',
    'Tem.md',
    'keep/k.md',
    'keep/Templates/w.md',
  })
  T.eq(
    W.markdown(root, { exclude = { 'Templates/' } }).paths,
    { 'Tem.md', 'keep/Templates/w.md', 'keep/k.md' }
  )
  T.eq(W.markdown(root, { exclude = { 'Tem' } }).paths, { 'keep/Templates/w.md', 'keep/k.md' })
  T.eq(
    W.markdown(root, { exclude = { 'Templates/sub/', 'keep/k.md' } }).paths,
    { 'Tem.md', 'Templates/t.md', 'keep/Templates/w.md' }
  )
  drop(root)
end)

T.case('markdown: skip(rel_dir) prunes a directory and is called with relative paths', function()
  local root = tree({ 'a/x.md', 'a/b/y.md', 'c/z.md', 'top.md' })
  local seen = {}
  local r = W.markdown(root, {
    skip = function(rel)
      seen[#seen + 1] = rel
      return rel == 'a/b'
    end,
  })
  table.sort(seen)
  T.eq(seen, { 'a', 'a/b', 'c' })
  T.eq(r.paths, { 'a/x.md', 'c/z.md', 'top.md' })
  T.eq(r.skipped, {}, 'a pruned directory is not an unreadable one')
  drop(root)
end)

T.case('markdown: a symbolic link to a directory is not followed, a cycle ends', function()
  local root = tree({ 'real/n.md', 'top.md' })
  assert(uv.fs_symlink(root, root .. '/loop', { dir = true }))
  assert(uv.fs_symlink(root .. '/real', root .. '/alias', { dir = true }))
  T.eq(W.markdown(root).paths, { 'real/n.md', 'top.md' })
  drop(root)
end)

T.case('markdown: a link to a Markdown file is listed, a broken link is not', function()
  local root = tree({ 'real.md' })
  assert(uv.fs_symlink(root .. '/real.md', root .. '/link.md'))
  assert(uv.fs_symlink(root .. '/gone.md', root .. '/broken.md'))
  T.eq(W.markdown(root).paths, { 'link.md', 'real.md' })
  drop(root)
end)

T.case('markdown: an unreadable directory is reported in skipped, not passed over silently', function()
  local root = tree({ 'ok.md', 'locked/hidden.md', 'locked/inner/h2.md', 'open/o.md' })
  assert(uv.fs_chmod(root .. '/locked', 0))
  local r = W.markdown(root)
  uv.fs_chmod(root .. '/locked', 493)
  if #r.skipped == 0 then -- root reads any directory: chmod 0 blocks nothing, the other cases cover the path
    drop(root)
    return
  end
  T.eq(r.paths, { 'ok.md', 'open/o.md' })
  T.eq(r.skipped, { 'locked' })
  drop(root)
end)

T.case('markdown: an empty tree gives empty lists; a trailing slash on the root does not matter', function()
  local root = tree({}, { 'empty' })
  T.eq(W.markdown(root), { paths = {}, skipped = {} })
  local root2 = tree({ 'a/b.md' })
  T.eq(W.markdown(root2 .. '/').paths, { 'a/b.md' })
  drop(root)
  drop(root2)
end)

T.case('markdown: a root that is not there raises; so do invalid arguments', function()
  T.raises(function()
    W.markdown(vim.fn.tempname() .. '/missing')
  end, 'cannot read')
  T.raises(function()
    W.markdown(nil)
  end, 'root')
  T.raises(function()
    W.markdown('/', { exclude = 'Templates/' })
  end, 'exclude')
  T.raises(function()
    W.markdown('/', { exclude = { 1 } })
  end, 'exclude')
  T.raises(function()
    W.markdown('/', { skip = 'x' })
  end, 'skip')
end)

T.case('markdown: exclude is case-sensitive', function()
  local root = tree({ 'templates/v.md', 'other.md' })
  T.eq(W.markdown(root, { exclude = { 'Templates/' } }).paths, { 'other.md', 'templates/v.md' })
  T.eq(W.markdown(root, { exclude = { 'templates/' } }).paths, { 'other.md' })
  drop(root)
end)

T.case(
  'markdown: a read that fails half way through a directory is reported, not taken for its end',
  function()
    local root = tree({ 'ok.md', 'sub/a.md', 'sub/b.md', 'sub/c.md' })
    -- fs_scandir_next answers (nil, error) after two entries of `sub`: the way an I/O error looks
    local real = uv.fs_scandir_next
    local seen = {}
    uv.fs_scandir_next = function(handle)
      seen[handle] = (seen[handle] or 0)
      local name, kind = real(handle)
      if name == 'a.md' or name == 'b.md' or name == 'c.md' then
        seen[handle] = seen[handle] + 1
        if seen[handle] == 3 then
          return nil, 'EIO: i/o error'
        end
      end
      return name, kind
    end
    local ok, r = pcall(W.markdown, root)
    uv.fs_scandir_next = real
    assert(ok, r)
    T.eq(r.skipped, { 'sub' })
    T.eq(#r.paths, 3, vim.inspect(r.paths)) -- ok.md and the two entries of sub read before the error
    T.ok(vim.tbl_contains(r.paths, 'ok.md'))
    drop(root)
  end
)
