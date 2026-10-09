# Changelog

All notable changes to this project are documented here. The format is based on [Keep a Changelog](https://keepachangelog.com/), and the project follows [Semantic Versioning](https://semver.org/).

## [0.1.0] — 2026-10-09

### Added
- `nvim_kit.test` — test runner for headless Neovim: `case`, `eq`, `ok`, `raises`, `deep_equal` (treats `vim.NIL` as `nil`, ignores metatables), `run_dir`, `main`. Exits 1 on a failing case, a spec that fails to load, and when no case ran.
- `nvim_kit.conformance` — runs a port of rules against JSON vectors (`load_dir`, `run`, `run_dir`); a missing implementation is a failure; argument positions survive `null` and `false`.
- `nvim_kit.data` — loads JSON data with a required schema version and fails loudly otherwise.
