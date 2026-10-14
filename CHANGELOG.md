# Changelog

All notable changes to this project are documented here. The format is based on [Keep a Changelog](https://keepachangelog.com/), and the project follows [Semantic Versioning](https://semver.org/).

## [Unreleased]

## [0.9.0] — 2026-10-14

### Added
- `nvim_kit.rg` — searching a text, not files, with ripgrep over stdin: hits with 0-based byte offsets, the match, ripgrep's replaced text and the line (`search`, async, with timeout, `max_hits` and `cancel()`); `check`, `version` and `reset` (the version cache), the fields `MIN_VERSION` and `TIMEOUT_MS` (ripgrep ≥ 15.0.0, the first with `--replace` and `--json` together). The user's ripgrep config is ignored (`--no-config`), and a NUL byte stays text (`--text`; without it ripgrep converts NUL to a line break and the line numbers after it shift, measured with 15.2.0). Text that is not UTF-8 comes back as base64 from ripgrep and is decoded. The text is searched as raw bytes (`--encoding=none`): without it ripgrep strips a UTF-8 byte order mark and transcodes UTF-16, and every offset after it shifts (measured with 15.2.0: `b` in BOM + `abc` at 1 instead of 4). A NUL byte in pattern or replacement reports `rg-error` instead of being cut off at the argument's end. Each hit's line is counted on from the previous hit, linear in the text (20 000 hits on one 220 KB line: 57 ms, counted from the line's start for each hit 8.7 s). The version cache keeps only found versions; a failed lookup says why in the system's words (`ENOENT`, `E5560` from a fast callback) and is asked again next time. A ripgrep killed by a signal reports `rg-error`.
- `nvim_kit.edits` — byte offsets into a range of lines as positions, and replacements written back to front in one undo step (`text`, `line_starts`, `position`, `locate`, `apply`). `apply` writes nothing when the lines changed, raises on overlapping edits and on invalid arguments before anything is read or written (`first` a whole number ≥ 0, `lines` a list of strings, edits with whole numbers `0 <= start <= stop` and a string `text`, no edits over empty `lines`; unchecked, `first = -2` compared one line and wrote another, and `stop < start` raised after an earlier edit was written), keeps insertions at one offset in list order, and closes the buffer's open undo block first: Vim closes it on a keystroke only in the current buffer, so an edit typed there before would otherwise join the replacements, and one `u` take back both (measured 2026-10-14).
- `text.clean_utf8` — every byte that is not valid UTF-8 becomes U+FFFD.
- `text.truncate` — a text cut to `max_chars` characters (not bytes) plus a mark, default `…`. Counted in plain Lua the way `vim.fn.strchars` counts (a lead byte with all the continuation bytes it announces is one character, every other byte one of its own; 100 000 random byte strings without NUL, 0 differences on 0.12.6 and 0.10.4): `vim.fn.strchars` raised E976 on a NUL byte, which buffer text can hold, and cannot run in a fast callback.

### Fixed
- `llm.chat` sends message text that is not valid UTF-8 (a buffer in latin1) as U+FFFD; `vim.json.encode` copied the bytes into the body, which is then no valid JSON for the server. A `messages` entry that is not a table raises at once: the cleaning runs inside a callback, where it failed and the callback never answered.

## [0.8.0] — 2026-10-14

### Added
- `nvim_kit.sampling` — which sampling values, reasoning effort and token reserve to send per model family × mode × backend, a port of code-kit's `sampling-profiles` (0.26.0): `family_from_name`, `thinking_for`, `validate_override`, `sanitize`, `resolve`, `for_call`. The tables are code-kit's export in `lua/nvim_kit/data/sampling-profiles.json`, vendored and never edited; all 265 code-kit vectors pass, plus Lua-only cases (NaN and infinities, family patterns with `-`).
- `nvim_kit.llm_json` — `strip_think`, `first_json_object`, `candidates` and `is_strict_json`, a port of code-kit's `stripThinkBlocks` and `firstJsonObject` (540 vectors). `vim.json.decode` accepts NaN, Infinity, hex numbers, leading zeros, `+1`, `1.` and raw tabs in strings, `JSON.parse` does not, so a span counts only after the strict check; the repair pass knows every JS whitespace character (U+00A0 included).
- `nvim_kit.llm` — an OpenAI-compatible model server over `curl`: endpoints in priority order (default Ollama on :11434, then LM Studio on :1234), keys from `api_key_env` or `api_key_cmd` (never in curl's argument list: header and body travel as curl configuration over stdin; `~/.curlrc` is ignored; a key echoed by the server is redacted), backend detection by a reply only that backend gives (Open WebUI, Ollama, LM Studio), `models`, `resolve` (the first reachable endpoint; one that answers with an error ends the search), and an asynchronous `chat` with timeout and `cancel()`. Errors are values; callbacks run on the main loop.
- `nvim_kit.http_stub` — a tiny HTTP/1.1 server on `vim.uv` for tests: fixed responses per route, recorded requests, hanging and raw answers.
- `nvim_kit.data.beside(source, rel)` — a path beside the calling Lua file, so a module finds its data in the kit and in a vendored copy alike.
- `make vendor-check` (part of `make check`) checks the vendored code-kit files; `make live` runs one structured chat against a real Ollama or LM Studio (not part of `make check`; exit 2 when nothing was measured).

### Fixed
- Tests that start a second Neovim use `v:progpath`, so `make test NVIM=<path>` runs them with that Neovim too; they used the `nvim` on `PATH`, and the minimum-version run never reached them.

## [0.7.2] — 2026-10-14

### Fixed
- `isolate.apply` keeps which-key's triggers out also when it runs in the same tick as the buffer's `BufEnter`, as a plugin does right after opening its buffer (`scratch.open`, then `apply`). which-key maps the triggers of a buffer's modes from a 0 ms timer, not on `BufEnter` itself; 0.7.1's `clear` came before that timer, dropped the modes, and the timer mapped the triggers anyway (`<Space>` among them, so `<Space>p` still pasted). `apply` now empties the triggers each waiting mode holds before `clear`, on every `BufEnter` too. These are which-key internals (`bufs`, `modes`, `triggers`, each checked by type); measured with which-key 3aab214: 5 triggers left in the same tick with 0.7.1, 0 now, also after `:enew` and back. Not covered: which-key set up only after `apply` (or set up again with its own `disable.ft`) while the buffer stays current maps its triggers until the next `BufEnter`; documented as a limit of `apply`. A path through the public `clear` alone, called after which-key's timer, measured 0 as well but depends on the order of two timers, which a macro (100 ms) or a restarted which-key timer reverses.
- `isolate.apply` no longer sets which-key up early: reading `options` from which-key's config module ran its `setup()` with defaults when the user's had not run yet (measured); it reads the field with `rawget` now.

## [0.7.1] — 2026-10-14

### Fixed
- `isolate.apply` removes the triggers which-key had already put into the buffer: which-key adds them on `BufEnter`, before `apply` sets the filetype, and reads its filetype list only when it adds them, so its `<Space>` trigger stayed and swallowed `<Space>` mappings (`<Space>p` pasted). It calls `require('which-key.buf').clear({ buf = buf })` after listing the filetype, and again on `BufEnter`; with the filetype listed, which-key adds none again. Measured with which-key 3aab214: 6 triggers before `apply`, 2 left with 0.7.0, 0 now.
- `isolate.apply` removes mini.clue's triggers too: mini.clue maps them one tick after `BufWinEnter`, and once `vim.b.miniclue_disable` is set it no longer unmaps them. `apply` calls `MiniClue.disable_buf_triggers(buf)` before setting the switch. Measured with mini.clue 149236a: an `apply` one tick late kept the `<Space>` trigger with 0.7.0, none now.

## [0.7.0] — 2026-10-14

### Added
- `nvim_kit.isolate` — puts one buffer into plain Neovim, so it behaves the same with every user setup: `apply(buf, { filetype, desc })` maps every Vim key in Normal, Visual and Operator-pending mode, and every global mapping that starts with one, to itself (non-recursive, buffer-local, with the exact lhs); keeps Neovim's own default mappings, `<Leader>` mappings, function and window keys; sets the options that change text to Neovim's default; switches off blink.cmp, copilot, minuet, mini.* and which-key by their own buffer switches, and diagnostics. `overrides()` and `global_options()` report what a user's setup changes, for `:checkhealth`. Moved from neurovim.nvim (`1e4c619`), where it was measured against LazyVim: 16 of 16 cases as in `nvim --clean`.
- `nvim_kit.keytrack.start` options: `exclude_cmdline` may be a function `fn(cmdline) → boolean` (an abbreviated command, through `nvim_parse_cmd`); `free_if_left` — a `:` command after which the buffer is no longer current and unchanged costs nothing (`:enew`, `:help`); `pause_outside` — time and `on_tick` stop while the buffer is not current.

### Changed
- `keytrack` counts the keys of a mapping's lhs instead of one per mapping (`<Space>p` costs 2): Neovim reports the whole lhs in one `vim.on_key` call. A command line that a mapping opens keeps the mapping's keys even when its command is excluded; only a typed `:` belongs to an excluded command.
- An excluded command line costs nothing also when it is abandoned with `<Esc>`.

### Fixed
- Keys typed in a command-line window opened from the tracked buffer (`q:`, `q/`) count; they cost nothing before.
- A nested command line (a `:` typed inside the command-line window, `<C-r>=`) no longer ends the open command, so an excluded command run from the window stays free; abandoned by leaving the window with `:q`, it is free too.

## [0.6.0] — 2026-10-13

### Changed
- `nvim_kit.test.deep_equal` (and with it `T.eq` and the conformance comparison) tells an empty object from an empty list, as JSON does: `vim.empty_dict()` or `{}` from `vim.json.decode` no longer equals a plain `{}`. A test that expected `{}` for an empty object now writes `vim.empty_dict()`. Other metatables are still ignored, and `vim.NIL` still equals `nil`.
- `nvim_kit.test.ok` fails on `vim.NIL` like on `nil` and `false` (Lua counts `vim.NIL` as true).
- `nvim_kit.conformance.load_dir` refuses a vector with a `null` inside an array argument (e.g. `args[2].l[2]`), naming file, case and position: the port would receive it as `vim.NIL`, which is truthy, and `nil` would leave a hole. A top-level `null` argument (arrives as `nil`), a `null` inside an object (absent) and a `null` in `expected` stay allowed.

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
