# AGENTS.md — nvim-kit

> **Role:** context for AI agents working in this repo. Humans start in [`README.md`](README.md). The coordination rules of the Neovim plugins — above all "Bibliothek ab Eins" and its justification gate — live one level up, in `../AGENTS.md` (the `nvim-plugins` Dach).
>
> **Language:** code, comments, identifiers and docs are **English**; commit messages **German**, Conventional Commits. Tags SemVer without `v`.

## TL;DR

**nvim-kit** is a **source library** for Neovim plugins. Plugins copy its modules **byte for byte** under their own namespace (`lua/<plugin>/kit/`) with a provenance line on top and a `VENDOR.json` — never as a dependency. Under the Dach's rule "Bibliothek ab Eins", everything reusable that a plugin needs goes here first, from its first use.

## Modules

| Module | Purpose | Since |
|---|---|---|
| `lua/nvim_kit/test.lua` | test runner for headless Neovim (`case`, `eq`, `ok`, `raises`, `deep_equal`, `run_dir`, `main`; `json_eq` since 0.3.0) | 0.1.0 |
| `lua/nvim_kit/conformance.lua` | runs a port of rules against JSON vectors from the reference implementation | 0.1.0 |
| `lua/nvim_kit/data.lua` | loads JSON data with a required schema version (`load`); a path beside the calling file (`beside`, 0.8.0) | 0.1.0 |
| `lua/nvim_kit/date.lua` | `YYYY-MM-DD` calendar arithmetic without time zones (`days_from_civil`, `civil_from_days`, `add_days`, `utc_today`) | 0.2.0 |
| `lua/nvim_kit/store.lua` | JSON state file: exact read, atomic write, re-read before every write, broken file moved aside (`read`, `write`, `update`, `set_aside`) | 0.3.0 |
| `lua/nvim_kit/scratch.lua` | named view buffer with buffer-local keys (`open`, `find`, `set_lines`, `close`; `reveal`, 0.12.0) | 0.3.0 |
| `lua/nvim_kit/panel.lua` | virtual lines above line 1 kept visible (`set`, `wrap`) | 0.3.0 |
| `lua/nvim_kit/keytrack.lua` | typed keys and time in one buffer, own commands excluded (`start`, `format_clock`); a mapping costs its lhs, the command-line window counts, `exclude_cmdline` as a function, `free_if_left`, `pause_outside` (0.7.0) | 0.3.0 |
| `lua/nvim_kit/winbar.lua` | winbar bound to one buffer (`attach`, `render`) | 0.4.0 |
| `lua/nvim_kit/text.lua` | small text pieces (`bar`; `clean_utf8`, `truncate`, 0.9.0; `language_name`, 0.12.0) | 0.4.0 |
| `lua/nvim_kit/health.lua` | `:checkhealth` building blocks, read-only (`neovim`, `json`, `writable`, `vendored`) | 0.5.0 |
| `lua/nvim_kit/isolate.lua` | one buffer in plain Neovim: Vim keys, Neovim's default options, editor helpers off (`apply`, `overrides`, `global_options`) | 0.7.0 |
| `lua/nvim_kit/sampling.lua` | request profiles per model family × mode × backend, a port of code-kit `sampling-profiles` (`family_from_name`, `thinking_for`, `validate_override`, `sanitize`, `resolve`, `for_call`); tables in `lua/nvim_kit/data/`, vendored from code-kit | 0.8.0 |
| `lua/nvim_kit/llm_json.lua` | reading a model's answer: `strip_think`, `first_json_object`, `candidates`, `is_strict_json` (port of code-kit `think-splitter`/`llm-json`) | 0.8.0 |
| `lua/nvim_kit/llm.lua` | OpenAI-compatible server over `curl`: `endpoints`, `models`, `backend`, `resolve`, `chat` (async, timeout, `cancel`); keys from `api_key_env`/`api_key_cmd` | 0.8.0 |
| `lua/nvim_kit/http_stub.lua` | HTTP/1.1 test server on `vim.uv` (`start`) | 0.8.0 |
| `lua/nvim_kit/rg.lua` | searching a text with ripgrep over stdin: hits with byte offsets and rg's replaced text (`search`, `needs_multiline`, `check`, `version`, `reset`, `MIN_VERSION`, `TIMEOUT_MS`; ripgrep ≥ 15.0.0) | 0.9.0 |
| `lua/nvim_kit/edits.lua` | byte offsets into a range of lines as positions, and replacements written back to front in one undo step (`text`, `line_starts`, `position`, `locate`, `apply`) | 0.9.0 |
| `lua/nvim_kit/wait.lua` | blocking on an asynchronous answer with `vim.wait` (`result`: value and an answered flag, `nil, false` on timeout) | 0.12.0 |

All of them are `0.x`: their interface may still change when the second real user arrives. That user may adapt or improve them through the gate; SemVer and the consumers' pins absorb the change.

## Commands

```bash
make check     # stylua --check lua tests · selene lua tests · nvim --headless -u NONE -l tests/run.lua
make test NVIM=/path/to/nvim   # minimum version run, e.g. the Neovim 0.10.4 release tarball
make vendor-check   # code-kit data and vectors against code-kit@<tag> (needs the nvim-plugins Dach; part of make check)
make live           # one structured chat against a real Ollama/LM Studio; LLM_LIVE_URL, LLM_LIVE_MODEL; exit 2 = nothing measured
stylua lua tests   # format
```

Tools: `brew install stylua selene`. Neovim ≥ 0.10.

## Rules

- **Every module has tests, and every test suite has a counter-check** that shows it can fail (a wrong implementation, a missing case, a load error). A green run that cannot turn red proves nothing.
- **Never edit a vendored copy** in a plugin. Fix it here, tag, re-vendor.
- **A module here carries no plugin's domain.** If a function needs a plugin's types, tables or vocabulary, it belongs in that plugin (with a `-- domain: <plugin>` header).
- **Fail loudly.** A missing file, an unknown schema, a vector without an implementation — each raises or counts as a failure; nothing is skipped silently.
- **Vendored from code-kit:** `lua/nvim_kit/data/sampling-profiles.json` and `tests/conformance/code-kit/` come from code-kit (manifest `vendor/code-kit/VENDOR.json`), written by `../tools/kit/vendor.py`, never edited. A change to a table or a vector is made in code-kit, tagged there, and re-vendored here; `make vendor-check` fails on any drift. The manifest lives outside `lua/` on purpose: a plugin vendors `lua/nvim_kit/data/` with the modules, and a manifest in there would point at nvim-kit paths the plugin does not have.

## Gotchas

- **`vim.NIL` is truthy.** `vim.json.decode` returns JSON `null` as `vim.NIL`; decode with `{ luanil = { object = true } }` so nulls inside objects become absent fields, and compare with `deep_equal`, which treats `vim.NIL` as `nil`. Nulls inside arrays stay `vim.NIL` so positions survive. `T.ok(vim.NIL)` fails (since 0.6.0).
- **An empty object is not an empty list.** `vim.json.decode('{}')` carries the metatable of `vim.empty_dict()`, `'[]'` is a plain `{}`, and `deep_equal` (so `T.eq` and the conformance comparison) tells them apart since 0.6.0, as `vim.json.encode` does. Expect a decoded empty object with `vim.empty_dict()`, not `{}`.
- **selene's `lua51` standard does not model `io.stdout` methods** — use `io.write`.
- **`nvim -l` scripts end via `os.exit(code)`;** an uncaught error exits 1.
- **Feeding keys in tests:** `nvim_feedkeys(keys, 'tx', false)`. Without `t`, `vim.on_key`'s `typed` is empty and `q` records nothing; with `n`, mappings are bypassed (a buffer-local `<CR>` never fires).
- **Headless `nvim -l` never fires `CursorMoved`,** and the view's `topline` stays stale until a redraw (`line('w0')` is current). Tests raise `CursorMoved` themselves with `nvim_exec_autocmds`.
- **`vim.on_key`: returning `''` discards the key** (0.11+) — a counting callback returns nothing.
- **`:enew` reuses an unnamed, empty buffer** instead of switching away from it — no `BufWinLeave`, window options unchanged. Test buffers that must be left get a name and a line of text (measured 2026-10-09, it faked a winbar bug).
- **`vim.on_key` reports a mapping's whole lhs in one call** (`typed` = `iw`, `<Space>p`) at its first rhs key — count the keys in it, not the calls (measured on 0.10.4 and 0.12.6).
- **`q:` and `q/` open their window from a command line:** `CmdlineEnter` fires in the original buffer first, the keys in the window go to the window's own buffer, and `CmdlineLeave` with the executed line fires back in the original buffer. A `:` typed inside the window is a nested command line there; leaving the window with `:q` ends the outer command line with an empty line and `abort` — the abandoned command is the window's cursor line (`CmdwinLeave`).
- **`<C-f>` (`'cedit'`) does not open the command-line window from `nvim_feedkeys(…, 'x')`** — Neovim inserts it as a character there; `q:` takes the same path through the events, so tests use `q:`.
- **`vim.schedule` callbacks queued while `nvim_feedkeys(…, 'x')` runs fire on the next loop turn,** not before `feedkeys` returns — `vim.wait(0)` in a test.
- **Keys a plugin replays with `nvim_feedkeys(…, 't')` arrive as typed in `vim.on_key`** (which-key: `gg` counts 4) — indistinguishable from the person's keys.
- **which-key maps a buffer's triggers from a 0 ms timer, not on `BufEnter`.** A check of `isolate.apply` runs in the same tick as the buffer's `BufEnter` (`scratch.open`, then `apply`), the way a plugin calls it; a probe that waits first passes against a broken fix (0.7.1, measured 2026-10-14 with which-key 3aab214).
- **`debug.getinfo(2)` sees past a tail call.** In LuaJIT `return f()` drops the caller's frame, so a helper that looks one level up resolves against the caller's caller (measured 2026-10-14). That is why `data.beside` takes `debug.getinfo(1, 'S').source` from its caller.
- **`vim.json.decode` is more lenient than JSON:** it accepts `NaN`, `Infinity`, `nan`, `inf`, `0x10`, `01`, `+1`, `1.` and raw control characters in strings; it refuses a lone surrogate escape and nesting deeper than 1000, which `JSON.parse` accepts (measured on 0.12.6). Check with `llm_json.is_strict_json` first where strictness matters.
- **Lua `%s` is ASCII whitespace only;** JS `\s` also matches U+00A0, U+1680, U+2000–U+200A, U+2028, U+2029, U+202F, U+205F, U+3000 and U+FEFF (finding M9).
- **LM Studio answers unknown paths with HTTP 200 and `{"error": …}`** (0.4.x, `/api/version`, `/api/config`). Judge a probe by its body, never by the status alone.
- **curl:** `-q` must be the first argument or `~/.curlrc` applies. Secrets go in the configuration over stdin (`-K -`), in double quotes with `\` and `"` escaped — never in argv, which `ps` shows. `vim.system`'s `timeout` ends with `code 124`, `kill(15)` with `code 0, signal 15`.
- **A test that starts another Neovim uses `vim.v.progpath`,** not `'nvim'`: `make test NVIM=…` replaces only the outer one.

## Memory

- Cockpit (SSOT for status and tasks): `$VAULT/25_Coding/nvim-kit/nvim-kit.md`.
- Design: `$VAULT/25_Coding/neurovim/_SDD/2026-10-08-neurovim-nvim-design.md` § 5.

## Abweichungen von der Leitkonvention

- Keine bekannt.
