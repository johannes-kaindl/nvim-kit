---
paths:
  - "lua/nvim_kit/**"
---

# Module — Tabelle

Alle Module unter `lua/nvim_kit/` mit Zweck und Seit-Version. Verschoben aus dem Kern der `AGENTS.md` (Wortlaut unverändert); lädt, sobald eine Datei unter `lua/nvim_kit/` berührt wird.

| Module | Purpose | Since |
|---|---|---|
| `lua/nvim_kit/test.lua` | test runner for headless Neovim (`case`, `eq`, `ok`, `raises`, `deep_equal`, `run_dir`, `main`; `json_eq` since 0.3.0) | 0.1.0 |
| `lua/nvim_kit/conformance.lua` | runs a port of rules against JSON vectors from the reference implementation | 0.1.0 |
| `lua/nvim_kit/data.lua` | loads JSON data with a required schema version (`load`); a path beside the calling file (`beside`, 0.8.0) | 0.1.0 |
| `lua/nvim_kit/date.lua` | `YYYY-MM-DD` calendar arithmetic without time zones (`days_from_civil`, `civil_from_days`, `add_days`, `utc_today`) | 0.2.0 |
| `lua/nvim_kit/store.lua` | JSON state file: exact read, atomic write, re-read before every write, broken file moved aside (`read`, `write`, `update`, `set_aside`; `mkdir_p`, 0.15.0) | 0.3.0 |
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
| `lua/nvim_kit/chunker.lua` | Markdown into overlapping chunks, UTF-16 units like JavaScript, a port of code-kit `chunker.ts` (`strip_frontmatter`, `chunk_markdown`) | 0.13.0 |
| `lua/nvim_kit/vectors.lua` | unit vectors, int8 quantisation and the cosine rank over an index matrix (`to_index_vector`, `quantize_int8`, `parse`, `search`, `related`, `values`, `fround`); `float[]` with `ffi`, a list without | 0.13.0 |
| `lua/nvim_kit/vrix.lua` | the VRIX container `index.bin`, byte for byte what vault-rag writes (`encode`, `decode`, `crc32`, `SCHEMA_VERSION`, `HEADER_KEYS`) | 0.13.0 |
| `lua/nvim_kit/index_guard.lua` | pure guards against data loss on an index write (`assert_safe_to_persist`, `is_suspicious_shrink`, `embedding_model_matches_index`, `assert_model_safe_to_persist`, `assert_dim_safe_to_persist`, `diff_index_vs_vault`, `find_dead_vector_paths`, `find_stale_vector_paths`; `count_unstamped_rows`, 0.14.0) | 0.13.0 |
| `lua/nvim_kit/index_delta.lua` | "embedded / total notes" and the split of healing targets (`compute`, `split_heal_targets`) | 0.13.0 |
| `lua/nvim_kit/probe.lua` | core of the self-find probe: sample, query, compare two runs (`rank`, `order`, `query`, `compare_runs`, `SEED`, `N`) | 0.13.0 |
| `lua/nvim_kit/live_indexer.lua` | the live note index: `new`, `fs_storage`; methods `init`, `update`, `remove`, `rename`, `note_count`, `is_ready`, `persist`, `reindex_all`, `cancel_reindex`, `heal_missing`; `stamps_snapshot` and `init(index, map)`, 0.14.0; an embedder may answer from a fast `uv` callback, 0.15.0; a behavioural port of code-kit `live-indexer` at 0.37.6 | 0.13.0 |
| `lua/nvim_kit/lock.lua` | lock file with stale takeover (`acquire`, `STALE_AFTER_S`); a port of code-kit's retrieval-store lock | 0.13.0 |
| `lua/nvim_kit/walk.lua` | the Markdown notes under a directory: relative, `/`-separated, byte-sorted, dot names and symlinked directories left out, unreadable directories reported (`markdown`) | 0.15.0 |
| `lua/nvim_kit/debounce.lua` | `new(ms, fn)` with `call`, `cancel`, `flush`; `fn` runs once with the last arguments on the main loop; the timer closes on `VimLeavePre` | 0.15.0 |
| `lua/nvim_kit/endpoint_model.lua` | the model chosen per server, remembered in a state file: `new(path, opts)` (path a string or a function) gives `model(url)`, `set_model(url, id)`, `choose(endpoint, models, cb, opts)`, `path()`; through `store`, extracted from the identical `state.lua` of transmute.nvim and note-retrieval.nvim | 0.16.0 |

Additions in 0.13.0: `llm.embed` (`/v1/embeddings` in groups), `store.write_bytes` (atomic, `fsync`), `text.utf16_len`, `utf16_sub`, `char_at`, `is_js_space`, `js_trim`, `byte_less`, a tolerance for `conformance.run` and `test.deep_equal`, `sampling.family_thinking` and the new `sampling.resolve` fallback (`unrecognised`, `fallback`); `llm` rejects `backend = 'anthropic'` (use `'openai'`).

All of them are `0.x`: their interface may still change when the second real user arrives. That user may adapt or improve them through the gate; SemVer and the consumers' pins absorb the change.
