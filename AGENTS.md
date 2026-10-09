# AGENTS.md — nvim-kit

> **Role:** context for AI agents working in this repo. Humans start in [`README.md`](README.md). The coordination rules of the Neovim plugins — above all "Bibliothek ab Eins" and its justification gate — live one level up, in `../AGENTS.md` (the `nvim-plugins` Dach).
>
> **Language:** code, comments, identifiers and docs are **English**; commit messages **German**, Conventional Commits. Tags SemVer without `v`.

## TL;DR

**nvim-kit** is a **source library** for Neovim plugins. Plugins copy its modules **byte for byte** under their own namespace (`lua/<plugin>/kit/`) with a provenance line on top and a `VENDOR.json` — never as a dependency. Under the Dach's rule "Bibliothek ab Eins", everything reusable that a plugin needs goes here first, from its first use.

## Modules

| Module | Purpose | Since |
|---|---|---|
| `lua/nvim_kit/test.lua` | test runner for headless Neovim (`case`, `eq`, `ok`, `raises`, `deep_equal`, `run_dir`, `main`; `json_eq` unreleased) | 0.1.0 |
| `lua/nvim_kit/conformance.lua` | runs a port of rules against JSON vectors from the reference implementation | 0.1.0 |
| `lua/nvim_kit/data.lua` | loads JSON data with a required schema version | 0.1.0 |
| `lua/nvim_kit/date.lua` | `YYYY-MM-DD` calendar arithmetic without time zones (`days_from_civil`, `civil_from_days`, `add_days`, `utc_today`) | 0.2.0 |
| `lua/nvim_kit/store.lua` | JSON state file: exact read, atomic write, re-read before every write, broken file moved aside (`read`, `write`, `update`, `set_aside`) | unreleased (0.3.0) |
| `lua/nvim_kit/scratch.lua` | named view buffer with buffer-local keys (`open`, `find`, `set_lines`) | unreleased (0.3.0) |
| `lua/nvim_kit/panel.lua` | virtual lines above line 1 kept visible (`set`, `wrap`) | unreleased (0.3.0) |
| `lua/nvim_kit/keytrack.lua` | typed keys and time in one buffer, own commands excluded (`start`, `format_clock`) | unreleased (0.3.0) |

All of them are `0.x`: their interface may still change when the second real user arrives. That user may adapt or improve them through the gate; SemVer and the consumers' pins absorb the change.

## Commands

```bash
make check     # stylua --check lua tests · selene lua tests · nvim --headless -u NONE -l tests/run.lua
stylua lua tests   # format
```

Tools: `brew install stylua selene`. Neovim ≥ 0.10.

## Rules

- **Every module has tests, and every test suite has a counter-check** that shows it can fail (a wrong implementation, a missing case, a load error). A green run that cannot turn red proves nothing.
- **Never edit a vendored copy** in a plugin. Fix it here, tag, re-vendor.
- **A module here carries no plugin's domain.** If a function needs a plugin's types, tables or vocabulary, it belongs in that plugin (with a `-- domain: <plugin>` header).
- **Fail loudly.** A missing file, an unknown schema, a vector without an implementation — each raises or counts as a failure; nothing is skipped silently.

## Gotchas

- **`vim.NIL` is truthy.** `vim.json.decode` returns JSON `null` as `vim.NIL`; decode with `{ luanil = { object = true } }` so nulls inside objects become absent fields, and compare with `deep_equal`, which treats `vim.NIL` as `nil`. Nulls inside arrays stay `vim.NIL` so positions survive.
- **selene's `lua51` standard does not model `io.stdout` methods** — use `io.write`.
- **`nvim -l` scripts end via `os.exit(code)`;** an uncaught error exits 1.
- **Feeding keys in tests:** `nvim_feedkeys(keys, 'tx', false)`. Without `t`, `vim.on_key`'s `typed` is empty and `q` records nothing; with `n`, mappings are bypassed (a buffer-local `<CR>` never fires).
- **Headless `nvim -l` never fires `CursorMoved`,** and the view's `topline` stays stale until a redraw (`line('w0')` is current). Tests raise `CursorMoved` themselves with `nvim_exec_autocmds`.
- **`vim.on_key`: returning `''` discards the key** (0.11+) — a counting callback returns nothing.

## Memory

- Cockpit (SSOT for status and tasks): `$VAULT/25_Coding/nvim-kit/nvim-kit.md`.
- Design: `$VAULT/25_Coding/neurovim/_SDD/2026-10-08-neurovim-nvim-design.md` § 5.

## Abweichungen von der Leitkonvention

- Keine bekannt.
