# Changelog

All notable changes to this project are documented here. The format is based on [Keep a Changelog](https://keepachangelog.com/), and the project follows [Semantic Versioning](https://semver.org/).

## [0.5.1] — 2026-10-10

### Fixed
- `nvim_kit.store` treated a file that exists but cannot be read (permissions) like a missing one, so the next `update` replaced it silently. `read` and `update` now raise `cannot read <path> (…) — left untouched`; only a file that does not exist reads as `nil`.
- `nvim_kit.health.json` reported such a file as missing ("no save yet"); it now reports it at the `invalid` level with the error.

## [0.5.0] — 2026-10-10

### Added
- `nvim_kit.health` — building blocks for a plugin's `:checkhealth`: `neovim(min)`, `json(path, opts)` (schema, object, missing/invalid levels, advice), `writable(dir)` (a missing directory counts by its nearest existing parent), `vendored(manifest)`. Diagnosis only: a check never moves, repairs, creates or writes anything.
- `nvim_kit.store.is_object(v)` — public, shared with `health`.
- `make test NVIM=<path>` runs the suite with another Neovim (the minimum version run: Neovim 0.10.4, 77/77).

## [0.4.0] — 2026-10-09

### Added
- `nvim_kit.winbar` — a winbar that belongs to one buffer: `attach(buf, provider)` sets it window-locally wherever the buffer is shown (also when it was attached while hidden); another buffer in the same window has none; the text is shown literally.
- `nvim_kit.text` — `bar(pct, width)`, a text progress bar.
- `nvim_kit.panel.set(buf, render)` — besides a list, a function `render(width)`: width is the text width of the narrowest window showing the buffer (window width minus number, sign and fold columns), and the panel is rendered again on resize, split and column option changes.
- `nvim_kit.scratch.set_lines(buf, lines, marks)` — whole-line highlights `{ { lnum, hl_group } }`, replacing earlier ones.
- `nvim_kit.store.read/update(path, …, { expect = 'object' })` — valid JSON that is not an object is moved aside like broken JSON.

### Fixed
- `nvim_kit.keytrack` no longer counts mouse clicks and the scroll wheel (they arrive as typed keys with Neovim's default `mouse=nvi`), and stops on `:bdelete` (`BufUnload`), not only on wipe. A terminal paste (bracketed, via `nvim_paste`) produces no key event and costs 0 keys — now pinned by a test.
- `nvim_kit.scratch.open` hands every window that showed the replaced buffer over to the new one (deleting it used to close those windows), and the initial text is no longer undoable (`u` past the start emptied the buffer).

## [0.3.0] — 2026-10-09

### Added
- `nvim_kit.store` — a JSON state file two editors can share: read exactly (`null` stays `vim.NIL`, `{}` stays an object, so the file keeps its shape for other programs), written atomically (temp file, then rename), re-read right before every write (`update`), and a file without valid JSON moved aside to `<path>.broken-<UTC time>` instead of being dropped (`read`, `set_aside`).
- `nvim_kit.scratch` — a plugin's own view buffer: named, not backed by a file, with buffer-local keys only; opening the same name replaces the old buffer.
- `nvim_kit.panel` — virtual lines above line 1 (a heading, an objective). Neovim shows them only while the window's `topfill` makes room, and `gg` resets it; the panel makes room again when the cursor is on line 1 without it. `wrap` breaks long lines to a width.
- `nvim_kit.keytrack` — counts the keys a person types in one buffer and times them from the first key. Only typed keys count (a macro replay counts the keys that started it); a plugin's own command line can be excluded, `:` included; optional one-second tick. `format_clock(ms)` gives `mm:ss`.
- `test.json_eq` — strict comparison over canonical JSON: tells `[]` from `{}` and `null` from an absent key, unlike `deep_equal`. For data that goes to disk.

## [0.2.0] — 2026-10-09

### Added
- `nvim_kit.date` — calendar dates as `YYYY-MM-DD` without time zones: `days_from_civil`, `civil_from_days` (day ordinals from 1970-01-01, like code-kit's `civilCalendar`), `add_days(ymd, n)` and `utc_today()`. Pure calendar arithmetic, never `os.time`, whose local time and daylight-saving switch shift a day; malformed and impossible dates raise. First user: neurovim.nvim's streak rule.

## [0.1.1] — 2026-10-09

### Fixed
- `nvim_kit.conformance` loads its sibling `test` module relative to its own name, so a copy vendored under `lua/<plugin>/kit/` works without `nvim_kit` on the runtimepath — and never picks up another kit version from it.
- The conformance runner refuses vector files that could report green for nothing: no cases, the same `function` in two files, a case without an `expected` key (a nil-returning stub passed it), `args` that are not a list. `expected: null` stays a real expectation.
- The test runner collects `*_spec.lua` in subdirectories too; a failing spec in `tests/sub/` used to be skipped while the run reported success.

## [0.1.0] — 2026-10-09

### Added
- `nvim_kit.test` — test runner for headless Neovim: `case`, `eq`, `ok`, `raises`, `deep_equal` (treats `vim.NIL` as `nil`, ignores metatables), `run_dir`, `main`. Exits 1 on a failing case, a spec that fails to load, and when no case ran.
- `nvim_kit.conformance` — runs a port of rules against JSON vectors (`load_dir`, `run`, `run_dir`); a missing implementation is a failure; argument positions survive `null` and `false`.
- `nvim_kit.data` — loads JSON data with a required schema version and fails loudly otherwise.
