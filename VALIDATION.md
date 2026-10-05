# Scrapers repair and validation

Date: 2026-10-05 (UTC). Host: dc-box. Compiler: Zig 0.16.0.

## Scope

Provider parsing and ownership, shared HTTP transport/cache, downloads and
archive integrity, CLI/TUI correctness and responsiveness, build compatibility,
and reproducible regression tests.

## Repairs

- Moved parser arenas exactly once and finalized response arenas after every
  response-field allocation. Added allocation-failure coverage.
- Fixed long relative URL resolution, Unicode whitespace/title normalization,
  episode identifiers, numeric boundary handling and OpenSubtitles TV listing
  URLs. Preserved valid Unicode filenames.
- Isolated cookies/authorization across HTTP redirects and cache identities;
  validated response framing, compressed/chunked bodies, interim responses,
  bodiless responses, size limits and cancellation. Disposable cache writes
  are atomic and ordinary cache I/O failures do not discard successful fetches.
- Added bounded ZIP preflight/CRC verification and transactional extraction.
  Existing files and dangling destination symlinks are not overwritten.
  Harmless endpoint whitespace after a ZIP footer is normalized to the exact
  boundary used by both preflight and the native decoder.
- 7z remains download-only because its native header decoder cannot be bounded
  before allocation. The original archive can be exported, and the UI/CLI
  explicitly reports external extraction. Disabled-unarr builds do likewise.
- Incomplete or malformed translation output preserves original text and is
  explicitly reported; empty fragments no longer silently erase dialogue.
- Fixed persistence and task-result ownership on failures, terminal shutdown
  under a full input queue, paste handling, narrow/large terminal boundaries,
  settings hit testing, and empty/paginated result navigation. Tab no longer
  rescans the download directory; F5 refreshes it explicitly.
- Added CLI search/subtitle page selectors, safe rendering of external text,
  complete help, and reliable flushing of partial-failure warnings.
- Kept dependency pins. The pinned serializer is adapted in generated build
  output with source-identity guards; natural/explicit pointer alignment and
  existing wire bytes are regression-tested.

## Reproducible gates

- `zig build test test-http -j1`: deterministic Debug tests plus isolated
  two-origin HTTP integration. 394 tests passed, 125 network-gated tests skipped
  in the final fresh-cache run (519 total). Skips are not counted as passes.
- `zig build test test-http -Doptimize=ReleaseSafe -j1`: safety-enabled gate,
  394 passed / 125 skipped.
- `zig build test-pty -j1`: native POSIX/Python 3 integration, with 2,000 synthetic
  cached subtitle files. Checks navigation output, resized cursor bounds,
  normalized bracketed paste, normal/burst quit, alternate-screen exit and
  exact terminal-mode restoration. Timing is dirty-host first-output latency,
  not a full-frame benchmark.
- `zig build build-all-targets -j1`: x86-64/ARM64 Linux GNU, x86-64 Windows GNU,
  x86-64/ARM64 macOS cross-compilation. Cross builds are not runtime tests.
  The combined Debug/HTTP/PTY/all-target gate completed all 95 build steps.
- `zig build test -Denable-tui=false -Denable-unarr=false -j1`: minimal features,
  300 passed / 126 skipped.
- `zig build -Denable-alldriver=true -j1`: optional browser-support compilation.
- Fresh source snapshot, no existing project package directory, isolated global
  cache: dependency fetching and full Debug/HTTP tests passed. The upstream
  unarr pin is valid; an extra directory in this host's old shared cached tar
  caused the original failure. Shared caches and dependency pins were unchanged.

Three final read-only review passes found no further actionable defects in the
reviewed runtime/CLI/TUI/help and transport/cache/archive/ownership/build scopes.
This is bounded source review and executed-test evidence, not a claim that an
arbitrary future input or changing third-party website cannot expose a bug.

## Live provider results

Two full sweeps covered all 53 retained implementations, with bounded concurrency
and subprocess deadlines. The second sweep had 41 zero-exit jobs. Follow-up runs
repaired and requalified the remaining code/test failures, including actual TV
selection for OpenSubtitles/iSubtitles, Subsunacs episode matching, Subs4Free ZIP
extraction and Subtitlecat's translation/download path. In total, application
search/list/download paths were observed working for 45 providers across these
runs. This is not a claim that all 45 passed one identical final sweep.

Eight external failures remain in this environment:

| Provider | Observed failure |
| --- | --- |
| opensubtitles.org | Australian access-block page |
| tvsubtitles.net | Australian access-block page |
| moviesubtitlesrt.com | HTTP 403 |
| subtitri.do.am | HTTP 403 |
| greek-subtitles.com | HTTP 524, then subprocess deadline |
| podnapisi.net | DNS NoAddressReturned |
| my-subs.co | DNS NameServerFailure |
| subclub.eu | DNS NameServerFailure |

These results establish conditions during this run, not permanent retirement.
No provider was disabled merely to hide a failed qualification. No CAPTCHA was
solved and no regional block was bypassed. Windows/macOS/ARM64 runtime execution
was not available on this Linux host; their binaries were cross-compiled.

## Evidence and limits

Detailed local logs are under `.tmp/audit-20261005/`, including complete sweeps,
focused live retries, fresh-cache validation, deterministic gates and terminal
probes. Synthetic archive/transport fixtures are committed in `src/app/fixtures`
and `tools`; downloaded provider payloads are not committed. Existing untracked
`ISSUES.md` was preserved.

Windows device-alias behavior follows the
[Microsoft filename documentation](https://learn.microsoft.com/en-us/windows/desktop/fileio/naming-a-file),
including superscript COM/LPT aliases.
