# Scrapers repair and validation

Date: 2026-10-06 (Australia/Brisbane). Host: dc-box. Compiler: Zig 0.16.0.

## Current scraper qualification

The final source snapshot passed these deterministic and build gates:

- `zig build test test-http -j1`: 26/26 build steps; 602 tests passed and
  125 network-gated tests skipped (727 total). All 18 transport cases and
  28 isolated loopback requests passed; no credentials reached the
  cross-origin fixture.
- `zig build test -Doptimize=ReleaseSafe -j1`: 23/23 build steps and the same
  602/727 test result under safety-enabled optimization.
- `zig build -Denable-alldriver=true -j1`: 14/14 build steps for optional
  browser-session support. This is compilation evidence, not CAPTCHA completion.
- `zig build build-all-targets -j1`: 57/57 build steps for x86-64 and ARM64
  Linux GNU, x86-64 Windows GNU, and x86-64 and ARM64 macOS. These are compile
  checks, not foreign-platform runtime tests.

All 45 active providers passed application search, subtitle listing, and real
file downloads on the final unchanged source, including TV selection where
advertised. This qualification combines the full sweep and isolated reruns:

- `zig build test-live-active -Dtarget=aarch64-linux-gnu -Dlive-max-jobs=4
  -j1` started and completed all 45 providers; 41 passed. Kitsunekko, Subsunacs,
  and Subclub encountered `NameServerFailure`; Closed Caption Browser exceeded
  its test deadline. The convenience target ignored the deliberately foreign
  outer target and an ambient filter naming an inactive provider, as documented.
- Each of those four providers then passed `zig build test-live -Dlive=all
  -Dlive-providers=<provider> -Dlive-timeout-seconds=120 -j1` individually.
  Source and HEAD hashes matched across the sweep and reruns. Normal resolver
  and HTTP probes confirmed recovery; no resolver settings were changed.

SubHD passed movie and TV downloads through its official prepare/temporary-page/
download API sequence. Its inferred CDN shortcut was removed. Subtitri's public
uCoz cookie redirect, SubCentral's legacy HTTP attachment link, and AnimeKalesi's
public CDN redirect also completed. Critique findings were repaired and covered
by regressions for session polling/reuse, cookie scope, bounded refresh, terminal
rate limits, response ownership, body-size limits, and season-aware filenames.

All 53 retained implementations were also probed earlier in this audit. The
eight inactive providers remained unavailable because of upstream DNS failures, HTTP/access-block
responses, or a stalled endpoint; they remain recovery probes rather than being
advertised by the CLI/TUI. An earlier AnimeKalesi run reported
`CloudflareChallenge` before its browser-session handoff was added. Deterministic
tests cover handoff and bounded refresh; a browser-enabled live retry completed
the normal public download path without presenting a challenge. Actual manual
CAPTCHA completion was not verified. No CAPTCHA solver or access-block bypass
was added. Passive Cloudflare background scripts are distinguished from actual
challenge pages.

Current logs are under `.tmp/audit-20261006/`: `qualification-final-r4-*` records
the deterministic/build gates and full fanout; `live-recovery-final-*` records
the four successful isolated reruns. Child exit codes and source hashes are
preserved alongside both successful and failed attempts. Downloaded provider
payloads are not committed.

## Earlier qualification

The remaining sections preserve evidence from the earlier repair snapshot.
Their counts and provider availability are historical; consult the current
registry and README for the active provider set and reproduce the current gates
above when qualifying another snapshot.

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

## Earlier live provider results

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

These results establish conditions during that run, not permanent retirement.
At that snapshot no provider was disabled merely to hide a failed qualification.
The current registry keeps eight unavailable providers inactive with recovery probes.
No CAPTCHA was solved and no regional block was bypassed. Windows/macOS/ARM64 runtime execution
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
