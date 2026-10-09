# Changelog

All notable changes to this project are documented here. The format is based on [Keep a Changelog](https://keepachangelog.com/), and the project follows [Semantic Versioning](https://semver.org/).

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
