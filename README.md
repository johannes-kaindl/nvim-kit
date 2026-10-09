# nvim-kit

Source library for Neovim plugins — vendored into each plugin, never installed as a dependency.

![License: AGPL-3.0](https://img.shields.io/badge/license-AGPL--3.0-blue)

## What it is

A small set of Lua modules that the Neovim plugins of this workspace share: a test runner for headless Neovim, a conformance runner that checks a port of rules against reference vectors, a schema-checked JSON loader, and time-zone-free calendar dates. Under the rule "Bibliothek ab Eins" (see `../AGENTS.md` in the `nvim-plugins` root), anything reusable a plugin needs lands here from its first use.

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

## Development

```bash
brew install stylua selene
make check        # stylua --check, selene, tests in headless Neovim
```

New modules start at `0.x` and become stable with their second real user. Every module ships with tests, including a counter-check that shows the test can fail. Contributor rules: [`AGENTS.md`](AGENTS.md); changes: [`CHANGELOG.md`](CHANGELOG.md).

## License

Code: [AGPL-3.0](LICENSE). Documentation: [CC BY-SA 4.0](LICENSE-DOCS).
