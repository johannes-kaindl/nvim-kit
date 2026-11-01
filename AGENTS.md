# AGENTS.md — nvim-kit

> **Role:** context for AI agents working in this repo. Humans start in [`README.md`](README.md). The coordination rules of the Neovim plugins — above all "Bibliothek ab Eins" and its justification gate — live one level up, in `../AGENTS.md` (the `nvim-plugins` Dach).
>
> **Language:** code, comments, identifiers and docs are **English**; commit messages **German**, Conventional Commits. Tags SemVer without `v`.

## TL;DR

**nvim-kit** is a **source library** for Neovim plugins. Plugins copy its modules **byte for byte** under their own namespace (`lua/<plugin>/kit/`) with a provenance line on top and a `VENDOR.json` — never as a dependency. Under the Dach's rule "Bibliothek ab Eins", everything reusable that a plugin needs goes here first, from its first use.

## Modules

Die Modul-Tabelle steht in `.claude/rules/module-tabelle.md` und lädt, sobald du unter `lua/` arbeitest (siehe Context index).

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
- **LuaJIT compares strings bytewise even after `os.setlocale('de_DE.UTF-8', 'collate')`** (measured 2026-10-25 on Neovim 0.12.6: `'Z' < 'a'` stays true and `table.sort` gives `Z a b ä`). So `text.byte_less` guards PUC-Lua builds only (where `<` may use `strcoll`), and a locale counter-check cannot turn red on LuaJIT; use a comparator mutation that really differs from byte order (e.g. `a:lower() < b:lower()`).
- **`vim.json.decode` is more lenient than JSON:** it accepts `NaN`, `Infinity`, `nan`, `inf`, `0x10`, `01`, `+1`, `1.` and raw control characters in strings; it refuses a lone surrogate escape and nesting deeper than 1000, which `JSON.parse` accepts (measured on 0.12.6). Check with `llm_json.is_strict_json` first where strictness matters.
- **Lua `%s` is ASCII whitespace only;** JS `\s` also matches U+00A0, U+1680, U+2000–U+200A, U+2028, U+2029, U+202F, U+205F, U+3000 and U+FEFF (finding M9).
- **LM Studio answers unknown paths with HTTP 200 and `{"error": …}`** (0.4.x, `/api/version`, `/api/config`). Judge a probe by its body, never by the status alone.
- **curl:** `-q` must be the first argument or `~/.curlrc` applies. Secrets go in the configuration over stdin (`-K -`), in double quotes with `\` and `"` escaped — never in argv, which `ps` shows. `vim.system`'s `timeout` ends with `code 124`, `kill(15)` with `code 0, signal 15`.
- **`vim.fn.*` and `vim.notify` raise E5560 in a fast event** (a `vim.uv` callback, `vim.in_fast_event()`); `vim.fn.fnamemodify` and `vim.json` are fine (measured 2026-10-26 on 0.12.6). Code that an embedder's or a timer's callback may reach (`live_indexer`, `store.write_bytes`) uses `vim.uv` only (`store.mkdir_p`) and schedules its notifications. A test makes the callback fast with a `vim.uv.new_timer()` and checks `vim.in_fast_event()` inside it, or it proves nothing.
- **`live_indexer` persist raises on a storage failure** (full disk, no write permission); the old container stays whole and no temp file is left (measured 2026-10-26, also on a real 600 KB FAT volume: `ENOSPC`). A test of a failing write without root uses a `chmod 555` directory, a directory named `index.bin`, or `ulimit -f` with `trap "" XFSZ` (EFBIG).
- **Two timers with the same timeout fire in start order in one `uv_run` turn:** `vim.uv.sleep(n)` blocks the loop so both are overdue, and their `vim.schedule` callbacks queue in that order. That is how `debounce_spec` puts a `cancel` between a timer firing and its scheduled run.
- **The `ffi` and the list path of `vectors` and `live_indexer` are both tested:** `tests/no_ffi_spec.lua` starts a second Neovim (`tests/no_ffi_child.lua`) where `require('ffi')` fails and runs the indexer, vector and container specs there; the golden sha256 inside the child (`live_indexer_dim_spec`) is the proof of vault-rag's bytes, and a deterministic container (ten vectors where float32 rounding decides an int8 value, found by search; a CRC over a whole container is the constant 0x2144DF1C and proves nothing, so the payload's CRC is compared) must equal the run that has `ffi`.
- **A test that starts another Neovim uses `vim.v.progpath`,** not `'nvim'`: `make test NVIM=…` replaces only the outer one.

## Context index

- Bevor du eine Datei unter `lua/nvim_kit/` liest, änderst oder anlegst: `.claude/rules/module-tabelle.md` (Modul-Tabelle mit Zweck und Seit-Version).
- Bevor du ein neues Modul anlegst: `../AGENTS.md`, Abschnitt „Bibliothek ab Eins“ (Dach-Gate).

## Memory

- Cockpit (SSOT for status and tasks): `$VAULT/25_Coding/nvim-kit/nvim-kit.md`.
- Design: `$VAULT/25_Coding/neurovim/_SDD/2026-10-08-neurovim-nvim-design.md` § 5.

## Abweichungen von der Leitkonvention

- Keine bekannt.
