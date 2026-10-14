# nvim-kit

Source library for Neovim plugins — vendored into each plugin, never installed as a dependency.

![License: AGPL-3.0](https://img.shields.io/badge/license-AGPL--3.0-blue)

## What it is

A small set of Lua modules that the Neovim plugins of this workspace share: a test runner for headless Neovim, a conformance runner that checks a port of rules against reference vectors, a schema-checked JSON loader, time-zone-free calendar dates, a JSON state store two editors can share, view buffers, a panel above line 1, a buffer-bound winbar, keystroke tracking, a buffer in plain Neovim, and small text pieces. Under the rule "Bibliothek ab Eins" (see `../AGENTS.md` in the `nvim-plugins` root), anything reusable a plugin needs lands here from its first use.

## How to consume it

Copy the modules you need into your plugin under its own namespace, byte for byte, with a provenance line on top, and pin the source in a `VENDOR.json` next to them:

```
lua/<plugin>/kit/test.lua          -- line 1: -- vendored from nvim-kit@0.1.1 (lua/nvim_kit/test.lua) — do not edit; re-vendor
lua/<plugin>/kit/VENDOR.json       -- { "source": "nvim-kit", "tag": "0.1.1", "sha": "…", "commit": "…", "files": [...], "license": "AGPL-3.0-only" }
```

Vendoring instead of a shared dependency is deliberate: Neovim loads one version per module name, so two plugins needing different kit versions would collide silently. Under the plugin's own namespace they cannot.

## Modules

**`nvim_kit.test`** — a test runner for headless Neovim with no external dependency.

```lua
-- tests/example_spec.lua
local T = require('nvim_kit.test')
T.case('adds', function() T.eq(1 + 1, 2) end)
T.case('fails loudly', function() T.raises(function() error('boom') end, 'boom') end)
```

```lua
-- tests/run.lua — run with: nvim --headless -u NONE -l tests/run.lua
local root = vim.fn.fnamemodify(debug.getinfo(1, 'S').source:sub(2), ':p:h:h')
vim.opt.rtp:prepend(root)
require('nvim_kit.test').main(root .. '/tests')
```

Specs are collected from the directory and its subdirectories. The run exits 1 on a failing case, on a spec that fails to load, and when no case ran at all.

**`nvim_kit.conformance`** — checks a port of rules against JSON vectors from the reference implementation (`{ schema, function, cases = { { name, args, expected } } }`).

```lua
local report = require('nvim_kit.conformance').run_dir('spec/conformance', { getDiff = my_get_diff })
assert(#report.failures == 0, vim.inspect(report.failures))
```

A vector without an implementation counts as a failure; a vector file without cases, with a case missing `expected`, or defining the same function as another file is refused. Top-level `null` arguments arrive as `nil` at their position; `false` stays `false`.

**`nvim_kit.data`** — loads a JSON data file only if it declares the expected schema version.

```lua
local data = require('nvim_kit.data').load(path, { schema = 1 })
```

It raises on a missing file, broken JSON, or a different or missing schema. `null` inside objects becomes an absent field.

**`nvim_kit.date`** — calendar dates as `YYYY-MM-DD`, without time zones.

```lua
local date = require('nvim_kit.date')
date.add_days('2026-03-30', -1)  -- '2026-03-29', also under TZ=Europe/Berlin
date.utc_today()                  -- today's UTC date
date.days_from_civil(1970, 1, 1)  -- 0; date.civil_from_days(0) → 1970, 1, 1
```

Day arithmetic is pure calendar math, never `os.time`: in local time a daylight-saving switch moves "one day earlier" by an hour and can land on the wrong date. A malformed or impossible date (`2025-02-29`) raises.

**`nvim_kit.store`** — a JSON state file that two editors can share.

```lua
local store = require('nvim_kit.store')
local saved, extra = store.update(path, function(current, info)
  current = current or { runs = 0 }   -- nil when there is no file yet (or it was broken: info.broken)
  current.runs = current.runs + 1
  return current, 'anything else'
end)
```

`update` re-reads the file right before it writes, so an edit another Neovim saved in between is kept; the write goes to a temp file and is renamed over the old one. `null` and `{}` survive a round trip. A file without valid JSON is moved to `<path>.broken-<UTC time>` and reported in `info.broken` — never silently dropped.

**`nvim_kit.scratch`** — a named view buffer with buffer-local keys.

```lua
local buf = require('nvim_kit.scratch').open('myplugin://list', lines, {
  filetype = 'markdown',              -- optional; modifiable = false, bufhidden = 'wipe' by default
  keys = { ['<CR>'] = open_item, q = close },
})
```

**`nvim_kit.panel`** — virtual lines above line 1 that stay visible.

```lua
local panel = require('nvim_kit.panel')
panel.set(buf, { { { 'Objective', 'Title' } }, { { '  ' .. step, 'Comment' } } })
panel.wrap(long_text, width)          -- → list of lines
```

Neovim draws virtual lines above the first line only while the window's `topfill` makes room for them, and `gg` resets it to 0. The panel makes room again whenever the cursor is on line 1 without it, and leaves a panel scrolled half away with `<C-e>` alone.

Long text: pass a function instead of a list, and the panel calls it with the width it may use — the narrowest window showing the buffer, minus number, sign and fold columns — again after every resize or split:

```lua
panel.set(buf, function(width)
  local lines = {}
  for _, l in ipairs(panel.wrap(objective, width - 4)) do
    lines[#lines + 1] = { { '  ' .. l, 'Comment' } }
  end
  return lines
end)
```

**`nvim_kit.keytrack`** — typed keys and time in one buffer.

```lua
local t = require('nvim_kit.keytrack').start(buf, {
  exclude_cmdline = function(line)    -- or a Lua pattern ('^%s*MyPlugin'); free also when abandoned
    local ok, cmd = pcall(vim.api.nvim_parse_cmd, line, {})
    return ok and cmd.cmd == 'MyPlugin'   -- :MyPl check is recognised too
  end,
  free_if_left = true,    -- :enew, :help — leaving the buffer unchanged costs nothing
  pause_outside = true,   -- the clock stops while the buffer is not current
  on_tick = function() vim.cmd('redrawstatus!') end,
})
t.keys(); t.elapsed_ms(); t.stop()
```

Time runs from the first key. Only typed keys count: a macro replay counts the keys that started it, not the ones it replays, and a mapping costs the keys of its lhs. Keys typed in a command-line window opened from the buffer (`q:`, `q/`) count. Only a typed `:` belongs to an excluded command; a mapping that opens it keeps its keys. Mouse clicks and the scroll wheel do not count, a terminal paste costs nothing, and `:bdelete` ends the tracking.

**`nvim_kit.isolate`** — one buffer in plain Neovim, whatever the user's setup does.

```lua
local isolate = require('myplugin.kit.isolate')
isolate.apply(buf, { filetype = 'myplugin-exercise', desc = 'plain Neovim key' })
isolate.overrides()       -- the user's global mappings that change a Vim key: { { mode, lhs, desc } }
isolate.global_options()  -- global options that differ from Neovim's default: { 'ignorecase=true' }
```

Every Vim key in Normal, Visual and Operator-pending mode, and every global mapping that starts with one, maps to itself in this buffer — non-recursively and with the exact lhs, because with keys already waiting Neovim takes the longest match. Neovim's own default mappings (`Y`, `gcc`, matchit's `%`), `<Leader>` mappings, function and window keys stay as they are. The options that change text are set to Neovim's default, `opts.filetype` replaces the filetype so that rendering and snippet plugins leave the buffer alone, and blink.cmp, copilot, minuet, mini.* and which-key are switched off by their own buffer switches, diagnostics too. A global option cannot have a buffer value; `global_options()` names those for a `:checkhealth`. Give the buffer a name or a line of text before `apply`: `:enew` reuses an unnamed, empty buffer and resets it, isolation included.

**`nvim_kit.winbar`** — a winbar that belongs to one buffer.

```lua
require('nvim_kit.winbar').attach(buf, function(b) return 'M-01 · 00:42 · 17 keys' end)
vim.cmd('redrawstatus!')   -- after the text changed
```

It is set window-locally wherever the buffer is shown; another buffer in the same window has no winbar. The text is shown literally.

**`nvim_kit.text`** — `require('nvim_kit.text').bar(28, 20)` → `[██████░░░░░░░░░░░░░░]`.

**`nvim_kit.health`** — building blocks for `:checkhealth <plugin>`; they only read.

```lua
-- lua/myplugin/health.lua
local health = require('myplugin.kit.health')
return {
  check = function()
    vim.health.start('Neovim')
    health.neovim('0.10')
    vim.health.start('Data')
    health.json(data_path, { label = 'data', schema = 1 })
    health.json(save_path, { label = 'save', expect = 'object', missing = 'ok', invalid = 'warn' })
    health.writable(vim.fn.stdpath('data') .. '/myplugin', 'save directory')
    health.vendored(kit_dir .. '/VENDOR.json', 'library')
  end,
}
```

A broken file stays exactly as it is: the check reports it, the plugin decides what to do on its next start.

## Development

```bash
brew install stylua selene
make check        # stylua --check, selene, tests in headless Neovim
make test NVIM=/path/to/nvim-0.10   # the suite with another Neovim (minimum version)
```

New modules start at `0.x` and become stable with their second real user. Every module ships with tests, including a counter-check that shows the test can fail. Contributor rules: [`AGENTS.md`](AGENTS.md); changes: [`CHANGELOG.md`](CHANGELOG.md).

## License

Code: [AGPL-3.0](LICENSE). Documentation: [CC BY-SA 4.0](LICENSE-DOCS).
