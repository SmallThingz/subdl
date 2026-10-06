# Scrapers repair and validation

Date: 2026-10-06 (Australia/Brisbane). Host: dc-box. Compiler: Zig 0.16.0.

## Current scraper qualification

The current registry retains 53 implementations: 46 active providers exposed by
the CLI/TUI and seven inactive recovery probes (`opensubtitles_org`,
`moviesubtitlesrt_com`, `podnapisi_net`, `my_subs_co`, `tvsubtitles_net`,
`greek_subtitles_com`, and `animesubtitle_ir`). The source/build snapshot used
for the final deterministic gates was captured at
`f86497cb5bb75d7d72360eb4c31b93a01505c1ee` plus the documented working-tree
changes, with content digest
`2d488c9deb6d5392f3fceee08a993ca80b99daea761d9cc3ecb4a99e0d64cf98`.

### Deterministic and build gates

- `zig build test test-http -j1`: 26/26 steps; 771 passed, 127 skipped
  (898 total). The isolated transport fixtures reported
  `HTTP_TRANSPORT_PASS cases=18` and
  `HTTP_LOOPBACK_PASS requests=28 cross_origin_credentials=0`.
- `zig build test test-http -Doptimize=ReleaseSafe -j1`: the same 26/26 steps
  and 771 passed / 127 skipped result under safety-enabled optimization, with
  the same transport counts.
- `zig build test -Denable-alldriver=true -j1`: 24/24 steps; 771 passed and
  127 skipped. This is the provider/browser-enabled unit-test boundary.
- `SUBDL_CHROMIUM_SMOKE=1 SUBDL_CHROMIUM_PATH=/opt/brave-bin/brave zig build
  test -Denable-alldriver=true -j1`: 24/24 steps; 773 passed and 125 skipped.
  Both opt-in Chromium pipe/egress smoke tests therefore ran. This validates
  the browser process and network policy, not CAPTCHA completion.
- `zig build -Denable-alldriver=true -j1`: 14/14 production build steps.
- `zig build build-all-targets -Denable-alldriver=true -j1`: 62/62 compile
  steps. The default-feature cross build separately passed 57/57 steps. Targets
  were x86-64 and ARM64 Linux GNU, x86-64 Windows GNU, and x86-64 and ARM64
  macOS; these are compile checks, not foreign-platform runtime tests.
- `zig build test-pty -j1`: 14/14 steps and both PTY probes passed with terminal
  restoration, resize handling, and bracketed paste verified.
- `zig build test -Denable-tui=false -Denable-unarr=false -j1`: 13/13 steps;
  677 passed and 128 skipped (805 total).

### Live-provider evidence and current network limitation

The final registry-driven command
`env -u SUBDL_CHROMIUM_SMOKE SUBDL_CHROMIUM_PATH=/opt/brave-bin/brave zig build
test-live-active -Denable-alldriver=true -Dlive-max-jobs=4 -j1 --summary all`
started and ended all 46 active-provider subprocesses. It did **not** produce a
clean qualification: nine exited zero, 29 exited one, and eight reached their
bounded subprocess deadline. The nine zero-exit providers were
`subtitri.nekur.net`, `subtitri.do.am`, `feliratok.eu`, `animekalesi.com`,
`animetosho.xyz`, `nyasub.cz`, `subhd.tv`, `fansubs.ru`, and `zoom.lk`.

The sweep recorded 61 `NameServerFailure` events. The only reported live-test
failures of another class were two `UnexpectedHttpStatus` events from
Prijevodi Online and one `ArchiveExtractionFailed` from Titrari. Several
nonzero subprocesses completed real provider operations before a later lookup
failed, but they are not counted as passes. A focused 11-provider final-source
run likewise ended 359 passed / 52 skipped / 7 failed, with DNS failures
dominating, so it is retained as diagnostic evidence rather than claimed as a
qualification pass.

An independent `getent ahostsv4` diagnostic reproduced the host resolver
failure without scraper code. Repeated lookups of the same public names
alternated between success taking 0.6–6.9 seconds and an 8-second timeout;
`animekalesi.com` timed out on all three attempts. A final isolated
OpenSubtitles.org recovery probe reached three live paths, but all three ended
in `NameServerFailure` (353 passed / 62 skipped / 3 failed overall) before an
access challenge could be reached. These observations prevent an honest claim
that every upstream passed on this final network run. Earlier qualification
below records successful real downloads observed during the repair, but is not
substituted for a clean identical-snapshot sweep.

### CAPTCHA and browser-session boundary

No CAPTCHA solver, CAPTCHA bypass, access-block bypass, TLS downgrade, or
credentialed cross-origin redirect was added. Manual CAPTCHA completion was not
performed because the final isolated challenge-provider probe failed during DNS
resolution before presenting one. Challenge recovery is covered by deterministic
tests and the real Chromium smoke above. Earlier in the audit, AnimeKalesi's
browser-enabled retry completed its normal public path without presenting a
challenge; that is not evidence of CAPTCHA completion.

On Linux, the handoff uses a private nonblocking Chromium 154+ CDP pipe and
private profile with one absolute deadline. Public DNS answers are validated and
pinned, proxies are disabled, and interception is attached before navigation;
only the challenged HTTPS origin and required Cloudflare challenge origins are
allowed, while local/private destinations fail closed. macOS and FreeBSD browser
handoff fails closed until resolver cancellation can be guaranteed. Windows
fails closed pending secure native handle/DACL support. Stale session credentials
are pruned, cache files and locks are private, and transport diagnostics redact
paths and query values.

Ordinary public-origin-pinned HTTP fetches retain one platform limitation:
macOS/FreeBSD Zig 0.16 uses blocking libc `getaddrinfo`, so cancellation waits
for that syscall to return. Address validation still fails closed; only lookup
cancellation latency lacks a hard bound there. A kernel filesystem call on
pathological remote/FUSE cache storage likewise cannot be preempted.

### Current evidence files

Current logs are under `.tmp/audit-20261006/` and are not committed. The frozen
identity is `final-tree-identity-before.log`. Deterministic evidence is in
`final-debug-test-http.log`, `final-releasesafe-test-http.log`,
`test-enabled-provider-final.log`, `final-browser-egress-smoke.log`,
`final-production-alldriver.log`, `final-cross-targets-alldriver.log`,
`final-cross-targets-default.log`, `final-test-pty.log`, and
`final-minimal-features-test.log`. Live evidence is in
`final-live-active.log`, `final-live-active-status.log`,
`final-live-active-failures.log`, `final-live-focused-changed.log`,
`final-live-opensubtitles-org.log`, and `final-dns-diagnostic.log`. The final
log set was scanned for unredacted credential/query material. Downloaded
provider payloads are not committed.

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
That historical snapshot kept eight unavailable providers inactive with recovery probes.
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
