# Changelog

All notable changes to this project are documented here. The format is based on [Keep a Changelog](https://keepachangelog.com/), and the project follows [Semantic Versioning](https://semver.org/).

## [Unreleased]

## [0.18.0] — 2026-11-11

### Added
- `LICENSING.md` and `CLA.md`; the README names code-kit as a private reference implementation whose vectors ship in `tests/conformance/code-kit/`.
- `nvim_kit.linediff` — `align(a, b, opts)` aligns two lists of lines along a longest common subsequence with a fixed rule: common prefix first, the suffix only over what the prefix left, a suffix-LCS table over the middle (a tie drops first, then adds), and above `opts.cell_limit` cells (default 250000, `n * m > limit`) no table at all — the middle of `a` is dropped, then the middle of `b` is added. Returns `{ prefix, suffix, common, dropped, added }` with 1-based indices (`added` as runs `{ at, count }`). Written so that a port of a reference with the same rule can be built on it line for line; checked against 34 line-alignment cases of such a reference outside this repository, none of them copied here.
- `date.local_today(t)` — today's date in the local time zone (`os.date('%Y-%m-%d')`), next to `utc_today`. Between local midnight and the zone's offset the two days differ, so a streak counted by the UTC day breaks or doubles there. `add_days` stays pure calendar arithmetic and is tested not to move with the zone.
- `date.utc_today(t)` and `date.local_today(t)` take an optional instant (seconds since the epoch, default now), so a test holds the clock still without the system clock; a value that is no number raises. Compatible: `utc_today()` is unchanged.

## [0.17.1] — 2026-11-11

### Changed
- `walk`: the comment on the measured walk no longer names a private vault (comment only, no behaviour change). Tagged so that plugins can vendor a copy without the name.

## [0.17.0] — 2026-11-11

### Fixed
- `endpoint_model.choose`: a pick no longer gets lost when `set_model` raises (state file not writable). `choose` called `set_model` unguarded inside the `vim.ui.select` callback, so the error escaped and `cb` never fired. It now catches the error and calls `cb(id, err)` once, `err` being the write error's message (`nil` on success and when the picker is dismissed). Compatible: a caller that reads only `id` is unaffected, and one that wants to say "could not be remembered" reads `err`. Measured in note-retrieval.nvim 2026-11-11 (`pcall` ok=false, cb_fired=0).

## [0.16.1] — 2026-11-01

### Fixed
- `endpoint_model` required `nvim_kit.store` by its absolute name, so a vendored copy (`lua/<plugin>/kit/`) failed to load: `module 'nvim_kit.store' not found`. It requires its sibling relative to its own name now, like every other module. Found when 0.16.0 was vendored into note-retrieval.nvim; 0.16.0 is not vendorable, use 0.16.1.

### Added
- `tests/relative_requires_spec.lua`: no module under `lua/nvim_kit/` requires a sibling by its absolute name (with a control that the scan finds one). The kit's own tests load every module as `nvim_kit.*`, so they could not see this.

## [0.16.0] — 2026-11-01

### Added
- `nvim_kit.endpoint_model` — the model a person chose per server, remembered across sessions: `new(path, opts)` returns `model(url)`, `set_model(url, id)`, `choose(endpoint, models, cb, opts)` and `path()`. `path` is a string or a function (read on every use); `opts.prompt_prefix` starts the picker's prompt, and `choose` takes its own to override. Behaviour of the two plugin copies it replaces (`state.lua` in transmute.nvim and note-retrieval.nvim): a broken file or a file that is no object reads as `nil` and is set aside, `models` as a list is replaced by an object on the next write, an entry that is no string is no model, a dismissed picker stores nothing and answers `cb(nil)`.

## [0.15.0] — 2026-10-26

### Added
- `nvim_kit.walk` — `markdown(root, opts)` lists the `*.md` notes under a directory, relative and `/`-separated, sorted by bytes; names starting with `.` and symbolic links to directories are left out, `opts.exclude` (prefixes) and `opts.skip` (predicate) prune, unreadable directories come back in `skipped`. Measured on a personal vault: 10 766 notes in 34-42 ms (Neovim 0.12.6, 2026-10-26).
- `nvim_kit.debounce` — `new(ms, fn)` with `call(...)`, `cancel()` and `flush()`; `fn` runs once with the last arguments on the main loop, the timer closes on `VimLeavePre`.
- `store.mkdir_p(path)` — `mkdir -p` with `vim.uv` only.

### Fixed
- `live_indexer`: an embedder that answers from a fast `vim.uv` callback (without `vim.schedule`) no longer breaks a full reindex. The intermediate states failed there (`vim.fn.mkdir` raises E5560) and the default `warn` (`vim.notify`) raised too, which ended `reindex_all` with an error. `fs_storage` and `store.write_bytes` create directories with `store.mkdir_p`, and the default `warn` is scheduled in a fast event. `cb`, `on_progress`, `read` and `stamp_for` still run in the caller's context.

### Measured
- `live_indexer` and `vectors` without `ffi`: the indexer, vector and container specs (180 cases) pass in a Neovim where `require('ffi')` fails, and a container written from deterministic vectors (ten of them chosen so that float32 rounding decides an int8 value) has the same length and payload CRC as with `ffi` (`tests/no_ffi_spec.lua`).
- A failing `fs_storage().write` (no write permission, a directory in the way of the rename, a file where the directory should be, `EFBIG` under `ulimit -f`; once a real full volume, `ENOSPC`): `persist` raises (as documented), the container on disk stays the old one byte for byte, no temp file is left, the indexer's memory is untouched and a later `persist` succeeds. A plugin calls `persist` under `pcall`.

## [0.14.0] — 2026-10-26

### Added
- `live_indexer`: `Ix:stamps_snapshot()` returns the stamps by path as a copy, and `Ix:init(index, stamps)` also takes such a map (next to the list parallel to the rows): an indexer re-seeded from another one's `build_index()` keeps the stamps of the rows nobody touched, where it used to write `{ 0, 0 }` for them on the next persist. A map entry that is no stamp is skipped, a row without an entry stays unstamped, nothing is stamped that was not (code-kit 0.37.3).
- `index_guard.count_unstamped_rows(stamps)` — how many rows are stamped `{ 0, 0 }`, the rows `find_stale_vector_paths` skips; `0` for no stamps at all (code-kit 0.37.0).

### Fixed
- `live_indexer`, ported from code-kit 0.37.6 (found by the review of this port, task 10 of 0.13.0): `cancel_reindex` no longer loses a note that came in through `update` or `rename` during the run, in memory and on disk (the live changes are applied after the mix with the stock, as an intermediate state does); a cancel while the index on disk belongs to another embedding model writes nothing and keeps the stock, instead of a container of two vector spaces; `rename(a, a)` leaves the note where it is (it used to delete it).

### Changed
- The port follows code-kit `live-indexer.ts` at 0.37.6 (was 0.31.1); vendor pin code-kit 0.37.6 (vectors and sampling table unchanged). The file header now lists the two remaining deviations only.

## [0.13.0] — 2026-10-25

### Added
- `nvim_kit.chunker` — Markdown into overlapping chunks, lengths and offsets in UTF-16 code units like JavaScript (`strip_frontmatter`, `chunk_markdown`); a port of code-kit `chunker.ts`.
- `nvim_kit.vectors` — unit vectors, int8 quantisation and the cosine rank over an index matrix (`to_index_vector`, `quantize_int8`, `parse`, `search`, `related`, `values`, `fround`); a `float[]` matrix with `ffi`, a list without, same numbers.
- `nvim_kit.vrix` — the VRIX container file `index.bin`, byte for byte what vault-rag writes (`encode`, `decode`, `crc32`, `SCHEMA_VERSION`, `HEADER_KEYS`).
- `nvim_kit.index_guard` — pure guards against data loss on an index write, and index-versus-vault comparisons.
- `nvim_kit.index_delta` — `compute` and `split_heal_targets`.
- `nvim_kit.probe` — the core of the self-find probe (`rank`, `order`, `query`, `compare_runs`).
- `nvim_kit.live_indexer` — one vector per note in memory, updated per note, rebuilt (`reindex_all`, with checkpoints and cancel) or healed (`heal_missing`), written as one VRIX container behind the guards.
- `nvim_kit.lock` — `acquire(path, opts)`, a lock file with stale takeover.
- `llm.embed(req, cb)` — `/v1/embeddings` in groups, strictly one request after the other; a group without exactly one finite vector per text is `bad-response`.
- `store.write_bytes(path, bytes)` — atomic binary write with `fsync`.
- `text.utf16_len`, `text.utf16_sub`, `text.char_at`, `text.is_js_space`, `text.js_trim`, `text.byte_less`.
- `conformance.run` and `test.deep_equal` accept a numeric tolerance for float results.
- `sampling.family_thinking(family, backend)`; `sampling.resolve` reports `unrecognised` and, on every explain row, `fallback` when it falls back.

### Changed
- `sampling` follows code-kit 0.28.0: Claude and Anthropic have profiles, gemma 4 on LM Studio turns reasoning `off` into `low`, and unknown backend or family ids no longer throw. Vendor pin code-kit 0.31.1.

### Fixed
- `llm` rejects `backend = 'anthropic'` (it talks to `/v1/chat/completions` only; use `'openai'`).
- `lock.acquire` raises on an open error other than `EEXIST` instead of reporting `locked`.

### Known limits
- `live_indexer`, carried over from code-kit `live-indexer.ts` 0.31.1 on purpose (to be fixed there and ported again): `cancel_reindex` loses a note that came in through `update` or `rename` during the run, and a cancel while the index on disk belongs to another embedding model writes the mix anyway, so one container can hold vectors of two models.
- `live_indexer`, deviations of the port: an embedder answer that `vectors.to_index_vector` rejects ends the run with `cb(nil, err)` (the source counts a row of length 0; `llm.embed` checks its answer); paths are ordered by code point, JavaScript orders by UTF-16 unit, so characters outside the BMP can give another CRC than vault-rag (also `probe.order`).

## [0.12.0] — 2026-10-14

### Added
- `text.language_name(lang)` — the English name of the language in a locale or language code (`'de_DE.UTF-8'`, `'de'`, `'pt_BR'` → `'German'`, `'German'`, `'Portuguese'`) for 20 codes (cs da de en es fi fr it ja ko nb nl no pl pt ru sv tr uk zh). `lang` nil reads `vim.v.lang`; `'C'`, `'POSIX'`, an empty string and unknown codes give `'English'`. Raises when `lang` is neither nil nor a string.
- `scratch.reveal(buf, row, col)` — focuses a window of the current tab page that shows `buf` and can take focus (not a `focusable = false` float), or opens an `aboveleft split` showing it, and puts the cursor at `row` (1-based) and `col` (0-based byte), row clamped to the buffer and col to ≥ 0 (Neovim puts the cursor on the last character of a shorter line, never inside a multibyte one), so a buffer that shrank never raises "Invalid cursor line". Returns the window. Raises on invalid arguments and on an invalid `buf`.
- `nvim_kit.wait` — `result(start, timeout_ms)` calls `start(cb)` and blocks with `vim.wait` until `cb` is called or the time is up; returns `value, true`, or `nil, false` on timeout (so an answer of `nil` is `nil, true`) and `start`'s return value as a third result (a handle to cancel after a timeout). Only the first argument of `cb` is kept; Ctrl-C looks like a timeout; called from a fast callback it raises before `start` runs.

## [0.11.0] — 2026-10-14

### Added
- `scratch.close(buf, fallback)` — the counterpart of `scratch.open`: closes every window that shows `buf` (floating windows and other tab pages included), then deletes `buf`. A window that cannot be closed because it is the last one (E444) shows `fallback` instead; without a valid `fallback` (nil, wiped, or `buf` itself) it gets a new empty unlisted scratch buffer, so `buf` is never left visible. An invalid `buf` (already wiped) is a no-op; a `buf` that is not a number or a `fallback` that is neither nil nor a number raises. The placeholder is wiped once left (text typed into it is lost). The last window of a tab page closes with its tab page while other tab pages exist. A modified `buf` is deleted anyway; a failing `WinClosed` autocmd, a `winfixbuf` window and a call from a `BufUnload`/`BufWipeout` that `close` itself triggered do not break it (a call from those autocmds when something else wipes `buf` raises, as a plain `nvim_buf_delete` does: do not do that). Neovim alone would also keep the window (`nvim_buf_delete` puts a listed buffer in it), but `close` decides which buffer that is.

## [0.10.0] — 2026-10-14

### Added
- `rg.needs_multiline(pattern)` — whether a ripgrep (Rust regex) pattern needs `--multiline`: it holds a literal newline or an `n` after an odd number of backslashes (`\n`; `\\n` is a backslash and an "n", `\\\n` a backslash and `\n`). A `\n` in a character class counts too. Raises when `pattern` is not a string.

### Changed
- `rg.search` derives `multiline` from the pattern with `needs_multiline` when `opts.multiline` is `nil`; `false` stays an explicit off (ripgrep then refuses a pattern with `\n` as `rg-error`, measured), `true` an explicit on. Before, an omitted `multiline` meant off, so a pattern with `\n` answered `rg-error`.

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
