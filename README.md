# nvim-kit

Source library for Neovim plugins — vendored into each plugin, never installed as a dependency.

![License: AGPL-3.0](https://img.shields.io/badge/license-AGPL--3.0-blue)

## What it is

A small set of Lua modules that the Neovim plugins of this workspace share: a test runner for headless Neovim, a conformance runner that checks a port of rules against reference vectors, a schema-checked JSON loader, time-zone-free calendar dates, a JSON state store two editors can share, view buffers, a panel above line 1, a buffer-bound winbar, keystroke tracking, a buffer in plain Neovim, small text pieces, a blocking wait for one asynchronous answer, health-check building blocks, searching a text with ripgrep and writing byte spans back in one undo step, and the pieces for talking to a language model: request profiles per model family, an OpenAI-compatible client over `curl` (chat and embeddings), a reader for JSON in a model's answer, and an HTTP server for tests. Since 0.13.0 also the core of a note-retrieval index: a Markdown chunker, vector maths with a cosine rank, the VRIX container file, the guards that stop an index write from losing data, a live indexer, a lock file and the self-find probe. Since 0.15.0 also a walk over the Markdown notes of a directory and a debouncer. Under the rule "Bibliothek ab Eins" (see `../AGENTS.md` in the `nvim-plugins` root), anything reusable a plugin needs lands here from its first use.

## How to consume it

Copy the modules you need into your plugin under its own namespace, byte for byte, with a provenance line on top, and pin the source in a `VENDOR.json` next to them:

```
lua/<plugin>/kit/test.lua          -- line 1: -- vendored from nvim-kit@0.1.1 (lua/nvim_kit/test.lua) — do not edit; re-vendor
lua/<plugin>/kit/VENDOR.json       -- { "source": "nvim-kit", "tag": "0.1.1", "sha": "…", "commit": "…", "files": [...], "license": "AGPL-3.0-only" }
```

Vendoring instead of a shared dependency is deliberate: Neovim loads one version per module name, so two plugins needing different kit versions would collide silently. Under the plugin's own namespace they cannot.

Some modules bring data: `sampling` reads `data/sampling-profiles.json` beside itself. Vendor that directory with the module (`lua/nvim_kit/data/` → `lua/<plugin>/kit/data/`); `llm` needs `sampling`, `llm_json` and `data` next to it.

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

Since 0.13.0 `run` accepts `opts.tolerance` and `test.deep_equal(a, b, tol)` takes a tolerance, so float results of a port compare with a stated margin while everything else stays exact.

**`nvim_kit.data`** — loads a JSON data file only if it declares the expected schema version.

```lua
local data = require('nvim_kit.data').load(path, { schema = 1 })
```

It raises on a missing file, broken JSON, or a different or missing schema. `null` inside objects becomes an absent field.

`data.beside(debug.getinfo(1, 'S').source, 'data/x.json')` gives the path of a file beside the calling module — in the kit and in a vendored copy alike. The caller passes its own source because a helper that looked it up one level higher would see past a tail call.

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

`write_bytes(path, bytes)` (0.13.0) writes bytes to a path atomically for binary files: parent directories are created, the bytes go to a temp file next to the path, are flushed to disk (`fsync`) and one rename puts them over the path; it raises on every failure and leaves no temp file behind. Since 0.15.0 `mkdir_p(path)` (`mkdir -p` with `vim.uv` only) creates the parent directories, so `write_bytes` also works in a fast callback (`vim.in_fast_event()`), where `vim.fn.mkdir` raises E5560.

**`nvim_kit.scratch`** — a named view buffer with buffer-local keys.

```lua
local buf = require('nvim_kit.scratch').open('myplugin://list', lines, {
  filetype = 'markdown',              -- optional; modifiable = false, bufhidden = 'wipe' by default
  keys = { ['<CR>'] = open_item, q = close },
})
require('nvim_kit.scratch').close(buf, source_buf)  -- closes its windows, deletes it
```

`reveal(buf, row, col)` shows `buf` at a position and returns the window: it focuses a window of the current tab page that shows `buf` and can take focus (a float with `focusable = false` does not count), or opens an `aboveleft split` showing it. `row` is 1-based and `col` a 0-based byte offset, the way `nvim_win_set_cursor` takes them; both are clamped to the buffer as it is now (row to 1 .. line count, col to ≥ 0; past the end of the line Neovim puts the cursor on its last character, never inside a multibyte one), so a buffer that shrank since the position was computed never raises "Invalid cursor line". Invalid arguments and an invalid `buf` raise.

`close(buf, fallback)` closes every window that shows `buf` and deletes it. The last window of the instance cannot close; it shows `fallback` instead, or a new empty unlisted scratch buffer when `fallback` is nil, no longer valid or `buf` itself (that placeholder is wiped once the user leaves it, so text typed into it is lost). When `buf` is the only window of a tab page and other tab pages exist, that tab page closes; only the instance's last window gets the fallback. `buf` is deleted even when modified. A `buf` that is already wiped is a no-op, and so is a call from a BufUnload or BufWipeout that `close` itself triggered. Do not call `close(buf)` from `buf`'s own BufUnload/BufWipeout autocmds: when the user or another plugin wipes `buf` (`:bwipeout!`), it raises and the wipe fails with E937.

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

**`nvim_kit.text`** — `require('nvim_kit.text').bar(28, 20)` → `[██████░░░░░░░░░░░░░░]`; `clean_utf8(s)` replaces every byte that is not valid UTF-8 with U+FFFD (`vim.json.encode` copies such bytes into its output; `llm.chat` cleans message text with it); `truncate(s, max_chars, mark)` returns `s` when it has at most `max_chars` characters, else its first `max_chars` characters followed by `mark` (default `…`) — it counts characters (UTF-8 code points), never bytes, so it does not cut inside a multibyte character, and it raises on invalid arguments. It counts in plain Lua, without `vim.fn`, the way `vim.fn.strchars` counts: a lead byte followed by all the continuation bytes it announces is one character (2 to 6 bytes, as Vim reads them), and every other byte is one character of its own, so a run of stray continuation bytes counts byte by byte and the cut stays bounded on text that is not UTF-8. A NUL byte is a character too, and it works in a fast callback.

`language_name(lang)` gives the English name of the language in a locale or language code, for a model prompt: `language_name('de_DE.UTF-8')` → `'German'`, `'pt_BR'` → `'Portuguese'`. A code is two letters, alone or followed by `_`, `.`, `-` or `@` and anything, in either case; 20 are known (cs da de en es fi fr it ja ko nb nl no pl pt ru sv tr uk zh). `lang` nil reads `vim.v.lang`. `'C'`, `'POSIX'`, an empty string and every other code give `'English'`. It raises when `lang` is neither nil nor a string. Choosing between an option and `v:lang` stays with the caller.

Since 0.13.0 `text` also holds the helpers the chunker is built on: `utf16_len(s)` and `utf16_sub(s, i, j)` count and cut in UTF-16 code units like JavaScript, `char_at(s, i)` returns the code point and byte length of the character at byte index `i`, `is_js_space(cp)` and `js_trim(s)` use JavaScript's whitespace set (not Lua's `%s`), and `byte_less(a, b)` compares strings by bytes, never by the locale (it equals JavaScript's order for ASCII).

**`nvim_kit.wait`** — `local value, answered = require('nvim_kit.wait').result(start, timeout_ms)` calls `start(cb)` and blocks with `vim.wait` until `cb` has been called or `timeout_ms` has passed. It returns the value given to `cb`, `true` and whatever `start` returned (a request handle, to `cancel()` after a timeout), or `nil, false, handle` on timeout; the second result tells an answer of `nil` (`nil, true`) from no answer. Only the first argument of `cb` is kept (`cb(nil, err)` gives `nil, true`), and a later call of `cb` is ignored. Events and callbacks run while it waits; Ctrl-C ends the wait early and looks like a timeout. Do not call it from a fast callback (`vim.uv` handlers, `vim.system` callbacks): it raises before `start` runs. It raises when `start` is not a function or `timeout_ms` is not a number ≥ 0; an error in `start` propagates.

```lua
local r, ok = require('nvim_kit.wait').result(function(cb) llm.models(endpoint, cb) end, 3000)
```

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

**`nvim_kit.sampling`** — which sampling values, reasoning effort and token reserve a request sends, per model family × mode × backend; a port of code-kit's `sampling-profiles`, checked against its vectors.

```lua
local sampling = require('myplugin.kit.sampling')
local request, dropped = sampling.sanitize(user_config.request) -- report `dropped`; nothing is dropped silently
local r = sampling.for_call({
  request = request,
  mode = 'structured',
  family = sampling.family_from_name('qwen3.6:27b'),   -- 'qwen3.6'
  backend = 'lmstudio',
})
r.params  -- { temperature = 0.1, top_p = 0.95, top_k = 20, reasoning_effort = 'none' }
r.explain -- per field: value, state ('sent-effective', 'not-sent-unsupported', …), origin, source
```

The tables are code-kit's export, vendored into `lua/nvim_kit/data/` and never edited here.

Since 0.13.0 the profiles follow code-kit 0.28.0: Claude and Anthropic have profiles, gemma 4 on LM Studio turns `off` into `low` (`none` is ignored there), and an unknown backend or family no longer throws: `resolve` falls back to generic values and reports it as `unrecognised` (the ids as passed) and as `fallback` on every explain row. `family_thinking(family, backend)` returns the thinking table of a family on one backend.

**`nvim_kit.llm`** — talks to an OpenAI-compatible server (Ollama, LM Studio, Open WebUI, a hosted API) over `curl`. Setting up a local server: [jkaindl.de/uplink/llm-setup](https://jkaindl.de/uplink/llm-setup/).

```lua
local llm = require('myplugin.kit.llm')
llm.resolve({ endpoints = cfg.endpoints, model = saved_model }, function(r)
  if r.error then -- 'no-model' also carries r.models for a vim.ui.select
    return vim.notify(r.error .. ': ' .. r.detail, vim.log.levels.WARN)
  end
  local h = llm.chat({
    endpoint = r.endpoint, model = r.model, backend = r.backend,
    mode = 'structured', request = request, messages = messages,
  }, function(res)
    if not res.ok then return report(res.error, res.detail) end
    local answer = llm.first_json_object(res.content)
  end)
  -- h.cancel() stops it and answers { ok = false, error = 'cancelled' }
end)
```

An endpoint is `{ url, name?, model?, backend?, api_key_env? or api_key_cmd? }`; the default list is Ollama on `:11434`, then LM Studio on `:1234`. The first endpoint that can be reached wins; one that answers with an error (a wrong key, a refusal) or whose key is missing ends the search with that error, so the text never falls back to the next server. A key comes from an environment variable or a command (`{ 'pass', 'show', 'openai' }`), is read once per session, never appears in curl's argument list or in a message. The backend is detected by a reply only that backend gives, unless the endpoint names it. Errors are values with a `detail`: `unreachable`, `timeout`, `cancelled`, `key-missing`, `http` (the server refused; `status` and its message), `bad-response`, `no-model`, `empty`, `truncated`. Callbacks run on the main loop. Needs `curl` on `PATH`.

Since 0.13.0 `llm.embed(req, cb)` asks `/v1/embeddings` for the vectors of a list of texts in groups of `batch_size`, strictly one request after the other, and answers `{ ok = true, vectors }` or `{ ok = false, error, detail }`; a group that does not return exactly one finite vector per text is `bad-response`, so no vector is ever matched to the wrong text and a failed call delivers no partial result. `req.endpoint`, `model`, `input`, `batch_size` and `timeout_ms` as for `chat`; the returned handle has `cancel()`. A `backend = 'anthropic'` is refused with an error that says to use `'openai'`: `llm` talks to `/v1/chat/completions` only.

**`nvim_kit.llm_json`** — reads a model's answer: `strip_think(text, opts)` removes `<think>` blocks, `first_json_object(text)` returns the first JSON object in it (fenced blocks first), strictly as `JSON.parse` would read it — `vim.json.decode` alone also takes `NaN`, hex numbers and leading zeros. A port of code-kit's `stripThinkBlocks` and `firstJsonObject`; `llm` exposes both too.

**`nvim_kit.http_stub`** — an HTTP/1.1 server for tests, in the test's own Neovim.

```lua
local srv = require('myplugin.kit.http_stub').start({
  ['GET /v1/models'] = { body = { data = { { id = 'm' } } } },
  ['POST /v1/chat/completions'] = function(req) return { status = 500, body = { error = 'nope' } } end,
  ['POST /slow'] = { hang = true },
})
-- … srv.url, srv.requests[1].body … srv.close()
```

Wait for an answer with `vim.wait`; route functions run in a fast event (no `vim.fn`, no `vim.api`).

**`nvim_kit.rg`** — searches a text, not files, with ripgrep: the text goes in over stdin, hits come back with byte offsets into it.

```lua
local rg = require('myplugin.kit.rg')
rg.search(text, { pattern = [[(\d{2})\.(\d{4})]], replacement = '$2-$1', max_hits = 500 }, function(r)
  -- r = { ok = true, hits = { { start, stop, match, replacement, line } }, truncated }
  --   | { ok = false, error = 'rg-missing'|'rg-error'|'timeout'|'cancelled', detail }
end)
```

`start`/`stop` are 0-based byte offsets, `stop` exclusive; `line` is the 1-based line of `start`. With a replacement, ripgrep computes each hit's replaced text (`--replace` with `--json` needs ripgrep 15.0.0; `check()` says `rg-missing` for an older one). The user's ripgrep config is ignored and a NUL byte is text, not a sign of binary. The text is searched as raw bytes (`--encoding=none`): a byte order mark stays in it and counts in the offsets, UTF-16 is not transcoded. A NUL byte in `pattern` or `replacement` cannot travel as an argument and reports `rg-error` (write `\x00` in the pattern). `opts.multiline` (`--multiline`) is derived from the pattern when omitted: `rg.needs_multiline(pattern)` is true for a literal newline or a `\n` escape (an `n` after an odd number of backslashes, also inside a character class; `\\n` is a backslash and an "n"), and raises when `pattern` is not a string. `multiline = false` forces it off (ripgrep then refuses a pattern with `\n` as `rg-error`), `true` forces it on. `opts.exe` names the ripgrep executable (default `'rg'`). Returns a handle with `cancel()`; the callback runs on the main loop.

Lines end at `\n` only (no `--crlf`): in text with `\r\n`, `$` does not match before the `\r` and `.` matches it, so `^(.*)$` → `[$1]` turns `abc\r` into `[abc\r]`. Buffer text with `fileformat=dos` is not affected, since Neovim keeps the `\r` out of the lines.

`rg.MIN_VERSION` (`'15.0.0'`) and `rg.TIMEOUT_MS` (`5000`, the default search timeout; `opts.timeout_ms` overrides it) are public fields. `version()` asks `rg --version` once per executable and caches a found version; a failed lookup is not cached, and its detail carries the system's error text. `rg.reset()` forgets the cache (tests, or after the user installed another ripgrep). A ripgrep killed by a signal reports `rg-error` ("ripgrep was killed by signal N").

**`nvim_kit.edits`** — byte offsets into a range of lines, and replacements written back to them.

```lua
local edits = require('myplugin.kit.edits')
local text = edits.text(lines)            -- lines joined with "\n", plus a final "\n": what rg searched
local ok, n = edits.apply(buf, first, lines, { { start = 9, stop = 19, text = '2026-10-13' } })
-- first is 0-based, like nvim_buf_get_lines: the range is buf's lines first .. first + #lines - 1
-- ok == false, 'changed' when buf's lines first.. are no longer `lines`: nothing is written
```

`apply` writes back to front, so earlier offsets stay valid, all in one undo step — it closes the buffer's open undo block first, since Vim closes it on a keystroke only in the current buffer. Insertions at one offset keep their order in the list. An edit that reaches into the range's final "\n" ends at the end of the last line, so the line after the range is never joined in. Invalid arguments raise before anything is read or written: `first` must be a whole number ≥ 0, `lines` a list of strings, each edit whole numbers `0 <= start <= stop` with a string `text`, and a non-empty list of edits needs non-empty `lines`; overlapping edits raise too. `locate` gives each edit its `row`, `col`, `end_row`, `end_col` (0-based, bytes).

**`nvim_kit.chunker`** (0.13.0) — splits Markdown into overlapping chunks for embedding, a port of code-kit's `chunker.ts`. `strip_frontmatter(s)` drops a leading `---` block; `chunk_markdown(s, max_units, overlap)` returns `{ { text, start_offset, end_offset } }` (defaults 800 and 150), cutting preferably at a heading and after a hard cut repeating `overlap` units. Lengths and offsets count UTF-16 code units like JavaScript's `string.length`, so the chunks equal the TypeScript ones for any text (checked against code-kit's vectors); a cut inside a surrogate pair never splits a UTF-8 character, and invalid UTF-8 is replaced by U+FFFD first.

**`nvim_kit.vectors`** (0.13.0) — unit vectors for notes and queries, their int8 form on disk and the cosine rank over a matrix of them, a port of code-kit's `embed-vector.ts` and `vector-index.ts`. `to_index_vector(vecs, dim)` truncates the embeddings of a note's chunks to `dim`, averages and L2-normalises them (one function for notes and queries), `quantize_int8(vec, scale)` gives the int8 row (default scale 127), `parse(manifest, paths, matrix)` reads a container's matrix into an index, `search(index, query, opts)` and `related(index, path, opts)` return `{ { path, score } }` best first (`opts = { k, min_sim, exclude }`), `values(index)` lists the matrix as a flat list (for tests and checks), and `fround(x)` rounds to float32. Every float32 of the source is rounded, so scores agree to the last bit. The matrix is a LuaJIT `float[]` where `ffi` exists and a Lua list where it does not; both give the same numbers (`parse` of a 12 547 × 256 index measured 4.5 ms with `ffi`, 139 ms without, on Neovim 0.12.6; a `related` call took about 6 ms both ways).

**`nvim_kit.vrix`** (0.13.0) — the VRIX container, the one `index.bin` file of a note index, byte for byte what vault-rag writes: `"VRIX"`, header length, a JSON header (manifest, paths, optional stamps), the int8 matrix and a CRC32. `encode(manifest, paths, matrix, stamps)` and `decode(bytes)` (`nil, reason` with `reason` one of `truncated`, `magic`, `crc`, `header`, `schema`), `crc32(bytes)`, and the fields `SCHEMA_VERSION` and `HEADER_KEYS` (the frozen key order; `vim.json.decode` loses it).

**`nvim_kit.index_guard`** (0.13.0) — the decisions where an index write could lose data, as pure functions: `assert_safe_to_persist`, `is_suspicious_shrink`, `embedding_model_matches_index`, `assert_model_safe_to_persist` and `assert_dim_safe_to_persist` answer `{ allowed = true }` or `{ allowed = false, kind }` with `kind` one of `shrink`, `model-mismatch`, `dim-mismatch`. `diff_index_vs_vault`, `find_dead_vector_paths` and `find_stale_vector_paths` compare an index with the vault; `UNKNOWN_STAMP` marks a row nobody could stamp, and `count_unstamped_rows(stamps)` (0.14.0) counts those rows (the rows `find_stale_vector_paths` skips; `0` for no stamps at all). The caller words its notice from `kind`.

**`nvim_kit.index_delta`** (0.13.0) — the numbers behind "embedded / total notes": `compute(total, missing, empty)` returns `{ embedded, total, emptyCount }` and `split_heal_targets(missing, empty)` splits the healing targets; empty notes (frontmatter only) have no chunks, so they count neither as missing nor in the target.

**`nvim_kit.probe`** (0.13.0) — the core of the self-find probe: `rank(path, seed)` and `order(files, seed)` pick a stable, scattered sample of notes, `query(s, opts)` makes the query for one note (its first 300 UTF-16 units, or nil when the note is no candidate), and `compare_runs(previous, next)` compares two runs over the same notes. Reading the notes and asking the index stay with the caller. `SEED` and `N` are the defaults.

**`nvim_kit.lock`** — a lock file so that two Neovim instances never write the same file at once: `acquire(path, opts)` returns a handle with `path` and an idempotent `release()`, or `nil, { error = 'locked', detail }`. The exclusive create is the arbiter; a lock older than `STALE_AFTER_S` (1800 s, `opts.stale_after_s`) belongs to a dead process and is taken over. `release()` deletes the file only while it is still the handle's own, and the handle also releases on `VimLeavePre`. Any open error other than "exists" raises (0.13.0).

**`nvim_kit.live_indexer`** (0.13.0) — one vector per note in memory, kept current note by note and written as one VRIX container behind the guards of `index_guard`; a behavioural port of code-kit's `live-indexer`, so it writes the bytes vault-rag writes. `M.new(storage, dir, embedder, model, opts)` takes the file store (`M.fs_storage()` is one over the file system), the asynchronous embedder `embedder(texts, cb)`, the model name and `opts = { dim, now, warn }`. The indexer has `init`, `update(path, content, stamp, cb)`, `remove`, `rename`, `note_count`, `is_ready`, `build_index`, `persist(reason, stamp_model)`, `check_model_against_disk`, `reindex_all(paths, read, on_progress, stamp_for, cb)`, `cancel_reindex`, `heal_missing(missing, read, on_progress, stamp_for, cb)` and, since 0.14.0, `stamps_snapshot()`: the stamps by path as a copy, which `init(index, stamps)` takes (next to the list parallel to the rows) when an index is re-seeded, so no stamp is lost on the way. A full reindex embeds in groups of up to `EMBED_BATCH` chunks, writes an intermediate state every `CHECKPOINT_EVERY` notes, can be cancelled and never blocks Neovim between two embedder calls; the old index stays searchable until the end of the run, and what the live handlers change meanwhile wins. `persist` and the other writes **raise** when the storage fails (a full disk, a directory without write permission, a file where the directory should be): the container on disk stays the old one byte for byte, no temp file is left, the indexer's memory is untouched, and a later `persist` writes everything — call it under `pcall` (measured 2026-10-26, also on a real full volume: `ENOSPC`). Since 0.15.0 an embedder may answer from a fast `vim.uv` callback without `vim.schedule` (`fs_storage` and the default `warn` no longer call Vimscript there); `cb`, `on_progress`, `read` and `stamp_for` then run in that context too, so a `cb` that persists should `vim.schedule` first. The specs also run in a Neovim where `require('ffi')` fails (`tests/no_ffi_spec.lua`): the same results on the list path, the golden sha256 of vault-rag's bytes included, and a container written from vectors where float32 rounding decides an int8 value equals the one with `ffi`.

**`nvim_kit.walk`** (0.15.0) — the Markdown notes under a directory. `local r = require('nvim_kit.walk').markdown(root, opts)` returns `{ paths, skipped }`: `paths` are the `*.md` files (extension in lower case) relative to `root`, `/`-separated and sorted by bytes (`text.byte_less`); `skipped` lists the directories that could not be read (or whose read failed half way; what was listed before stays), so a caller can say that notes are missing instead of passing them over silently. A name that starts with `.` (file or directory: `.git`, `.obsidian`, `.trash`) is neither listed nor entered. `opts.exclude` is a list of path prefixes (`{ 'Templates/' }`, case-sensitive `startsWith`; a directory under one is not entered), `opts.skip(rel_dir)` a predicate that prunes a directory. Symbolic links to directories are not followed (no cycle); a link to a Markdown file is listed, a broken link is not. A `root` that cannot be read raises. It is synchronous (`vim.uv.fs_scandir`). Measured 2026-10-26 on Neovim 0.12.6 (macOS, APFS): a personal vault of 10 766 notes in 1 115 directories, 34-42 ms over five runs.

```lua
local r = require('myplugin.kit.walk').markdown(vault, { exclude = { 'Templates/' } })
for _, rel in ipairs(r.paths) do ... end
if #r.skipped > 0 then vim.notify('not readable: ' .. table.concat(r.skipped, ', ')) end
```

**`nvim_kit.debounce`** (0.15.0) — `local d = require('nvim_kit.debounce').new(ms, fn)`; `d.call(...)` (re)starts the timer and remembers the arguments, and when `ms` pass without another call `fn` runs once with the arguments of the **last** call, on the main loop (`vim.schedule`, so the whole Neovim API is available). `d.cancel()` drops a pending call (also one whose timer has fired but whose run is still queued) and returns whether there was one; `d.flush()` runs a pending call now, synchronously, and returns true (false with nothing pending). `call` is safe from a fast callback; `new` is not. On `VimLeavePre` the timer is closed and a pending call is dropped, not run (`flush()` first where that matters); `call` after that does nothing.

## Development

```bash
brew install stylua selene
make check        # stylua --check, selene, tests in headless Neovim
make test NVIM=/path/to/nvim-0.10   # the suite with another Neovim (minimum version)
make live         # one structured chat against a real Ollama/LM Studio (not part of make check)
```

New modules start at `0.x` and become stable with their second real user. Every module ships with tests, including a counter-check that shows the test can fail. Contributor rules: [`AGENTS.md`](AGENTS.md); changes: [`CHANGELOG.md`](CHANGELOG.md).

## License

Code: [AGPL-3.0](LICENSE). Documentation: [CC BY-SA 4.0](LICENSE-DOCS).
