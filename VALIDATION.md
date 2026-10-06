# Scrapers repair and validation

Date: 2026-10-07 (Australia/Brisbane). Host: dc-box. Compiler: Zig 0.16.0.

## Current scraper qualification

The current registry retains 53 implementations: 46 registry-exposed providers
and seven inactive recovery probes (`opensubtitles_org`,
`moviesubtitlesrt_com`, `podnapisi_net`, `my_subs_co`, `tvsubtitles_net`,
`greek_subtitles_com`, and `animesubtitle_ir`). “Active” below means exposed by
the CLI/TUI registry; it does not mean every changing upstream was reachable in
the latest network environment. The final gates use commit
`dd795aa20b0962c6f16976024c8091aa12f667ee` plus the post-critique implementation
changes whose tracked implementation/test/build content digest is
`cedf9ba68bebf93e38709e89314c89c0d6e63df57a68e8f22335170607ce552c`.
The digest covers tracked `src/**`, `tools/**`,
`build.zig`, and `build.zig.zon`, using NUL-sorted paths and SHA-256 file
checksums.

### Deterministic and build gates

- `zig build test test-http -j1`: 26/26 steps; 818 passed, 133 skipped
  (951 total). The isolated transport fixtures reported
  `HTTP_TRANSPORT_PASS cases=21` and
  `HTTP_LOOPBACK_PASS requests=31 cross_origin_credentials=0`.
- `zig build test test-http -Doptimize=ReleaseSafe -j1`: the same 26/26 steps
  and 818 passed / 133 skipped result under safety-enabled optimization, with
  the same transport counts.
- `zig build test -Denable-alldriver=true -j1`: 24/24 steps; 818 passed and
  133 skipped. This is the provider/browser-enabled deterministic boundary.
- `SUBDL_CHROMIUM_SMOKE=1 SUBDL_CHROMIUM_PATH=/opt/brave-bin/brave zig build
  test -Denable-alldriver=true -j1`: 24/24 steps; 824 passed and 127 skipped.
  Three opt-in smoke tests ran in each of two compiled test binaries. They cover
  browser launch, download-denial acknowledgement, browser APIs commonly needed
  by challenge pages, named-frame compatibility, popup target containment,
  allowed navigation, user-agent/cookie retrieval, and one user-gesture
  `mailto:` attempt; they also invoke profile teardown. CDP event rejection is
  reactive defense in depth. The inaccessible session bus and verified private
  failing `xdg-email`/`xdg-open` stubs are the preventive boundary. This probe
  does not prove every protocol/desktop configuration, packet-level WebRTC
  suppression, every proxy-bypass interpretation, off-origin
  worker/OOPIF/service-worker denial, or end-to-end CAPTCHA completion.
- The separately gated headed `mailto:` probe was attempted with
  `SUBDL_CHROMIUM_HEADED_SMOKE=1` but is not counted as a pass. This host had no
  `DISPLAY`; its advertised `WAYLAND_DISPLAY=wayland-1` socket was not listening,
  so both compiled test binaries ended with `BrowserPipeClosed` before CDP
  initialization. A working compositor is required to qualify the visible path.
- `zig build -Denable-alldriver=true -j1`: 14/14 production build steps.
- `zig build build-all-targets -Denable-alldriver=true -j1`: 62/62 compile
  steps. Targets were x86-64 and ARM64 Linux GNU, x86-64 Windows GNU, and
  x86-64 and ARM64 macOS; these are compile checks, not foreign-platform runtime
  tests.
- `zig build test-pty -j1`: 14/14 steps and both PTY probes passed with terminal
  restoration, resize handling, and bracketed paste verified.
- `zig build test -Denable-tui=false -Denable-unarr=false -j1`: 13/13 steps;
  724 passed and 134 skipped (858 total).
- `zig fmt --check` on every changed Zig file and `git diff --check` passed.

### Live-provider evidence and current network limitation

The registry-driven run on the exact implementation digest above used a
30-minute outer bound and the command `env -u SUBDL_CHROMIUM_SMOKE -u
SUBDL_CHROMIUM_HEADED_SMOKE SUBDL_CHROMIUM_PATH=/opt/brave-bin/brave zig build
test-live-active -Denable-alldriver=true -Dlive-max-jobs=4 -j1 --summary all`.
It started and ended all 46 active-provider subprocesses: 40 exited zero and six
exited one; none reached a subprocess deadline. This is substantial live
coverage, but the six nonzero providers prevent a clean all-provider claim.

All nine providers whose raw transport paths changed in the post-critique work
exited zero: `animekalesi.com`, `animesub.info`, `fansubs.ru`, `greeksubs.net`,
`subcentral.de`, `subhd.tv`, `subs4free.info`, `subsynchro.com`, and
`titrari.ro`. The exact-snapshot run observed real search/list/download or
extraction paths for many providers, including AnimeKalesi ZIP download and
extraction. `opensubtitles.com` and `subsource.net` also exited zero.

Four nonzero providers ended only in resolver failures: `subtis.io`,
`kitsunekko.net`, `cc.edatribe.com`, and `subclub.eu`. Prijevodi Online reached
its content and download paths but returned two explicit access-block results
and one HTTP 403. Nyasub completed search/listing but its selected download
eventually returned `UnexpectedHttpStatus`. These changing upstream conditions
are reported as failures, not converted into passes.

A focused current-digest Nyasub rerun subsequently completed all nine build
steps and both real direct-download paths (152,179-byte movie and 48,252-byte
series payloads), with 380 tests passed and 65 skipped. This supports treating
the broad-run status as a transient upstream response, but it does not rewrite
the exact-sweep count. A focused retry of the four resolver-failure providers
completed the direct live tests for `cc.edatribe.com`, `subclub.eu`, and
`kitsunekko.net`, as well as CC Edatribe's provider-app series path. Its three
remaining failures (380 passed / 62 skipped / 3 failed) were all
`NameServerFailure`: the Subtis provider-app and direct-live paths, and the
Subclub provider-app series search. This is evidence of intermittent resolution,
not a clean combined-provider qualification.

For comparison, the earlier `dd795aa`-snapshot sweep on the same host had only
nine zero-exit providers, 29 exit-one providers, eight subprocess deadlines,
and 61 `NameServerFailure` events. That historical run and its focused retries
remain diagnostic evidence rather than current qualification.

An independent `getent ahostsv4` diagnostic reproduced the host resolver
failure without scraper code. Repeated lookups of the same public names
alternated between success taking 0.6–6.9 seconds and an 8-second timeout;
`animekalesi.com` timed out on all three attempts. The isolated
OpenSubtitles.org recovery probe reached three live paths, but all three ended
in `NameServerFailure` (353 passed / 62 skipped / 3 failed overall) before an
access challenge could be reached. These observations prevent an honest claim
that every upstream is reachable consistently from this host. The current
40-of-46 result, deterministic gates, and real-browser smoke are complementary;
none is represented as a clean all-provider sweep.

### CAPTCHA and browser-session boundary

No CAPTCHA solver, CAPTCHA bypass, access-block bypass, TLS downgrade, or
credentialed cross-origin redirect was added. Manual CAPTCHA completion was not
performed: no successful current-snapshot path presented a CAPTCHA, and the
earlier isolated challenge-provider probe failed during DNS resolution before
presenting one. Deterministic tests cover challenge detection,
session/cache ownership, cookie handoff, rejection and refresh behavior; the
real Chromium smoke covers the lower-level browser handoff only. Neither is an
end-to-end completed challenge. Earlier in the audit, AnimeKalesi's browser-
enabled retry completed its normal public path without presenting a challenge;
that is not evidence of CAPTCHA completion. An authorized user may complete a
displayed challenge manually within the deadline; unresolved challenges fail.

On Linux, the handoff uses a private nonblocking Chromium 154+ CDP pipe and
private profile with one absolute deadline. Public DNS answers are validated and
pinned. A process-wide unroutable proxy denies traffic by default, with direct
bypasses limited to the exact challenged HTTPS host and Cloudflare challenge host
on port 443; ambient/corporate proxies, other origins, subdomains/CDNs, and
WebSockets fail closed. Chromium policy denies downloads and new page targets,
and local/private destinations are blocked. External-protocol events are
rejected reactively; an inaccessible session bus and private, execution-verified
failing desktop-helper stubs form the preventive boundary. The headless
`mailto:` smoke partially exercises these controls but is not a packet-level
proof of the process-wide egress boundary or every protocol/desktop combination.
macOS and FreeBSD browser handoff fails closed until resolver cancellation can be
guaranteed. Windows fails closed pending secure native handle/DACL support. Stale
session credentials are pruned, cache files and locks are private, and transport
diagnostics redact paths and query values.

Ordinary public-origin-pinned HTTP fetches retain one platform limitation:
macOS/FreeBSD Zig 0.16 uses blocking libc `getaddrinfo`, so cancellation waits
for that syscall to return. Address validation still fails closed; only lookup
cancellation latency lacks a hard bound there. A kernel filesystem call on
pathological remote/FUSE cache storage likewise cannot be preempted.

### Current evidence files

Current logs are under `.tmp/audit-20261007/` and are not committed.
Post-critique deterministic evidence is in `final-debug-http.log`,
`final-releasesafe-http.log`, `final-alldriver.log`,
`final-browser-smoke.log`, `final-build-alldriver.log`,
`final-cross-alldriver.log`, `final-test-pty.log`, and
`final-minimal.log`. The exact-snapshot active-provider sweep is in
`final-live-active-exact.log`; focused current-snapshot evidence is in
`final-live-nyasub-focused.log` and `final-live-dns-retries.log`. The latter is
a diagnostic partial failure and does not replace the exact sweep. The failed,
non-qualifying visible-window diagnostic is in `headed-browser-diagnostic.log`;
its display-variable, socket-metadata, and listener inspection is in
`headed-host-environment.log`. Historical live evidence remains under
`.tmp/audit-20261006/` in
`final-live-active.log`, `final-live-active-status.log`,
`final-live-active-failures.log`, `final-live-focused-changed.log`,
`final-live-opensubtitles-org.log`, and `final-dns-diagnostic.log`. The qualifying
current logs and focused diagnostics were scanned for unredacted
credential/header material; downloaded provider payloads are not committed.

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

Eight external failures were observed in that environment:

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
and `tools`; downloaded provider payloads are not committed.

Windows device-alias behavior follows the
[Microsoft filename documentation](https://learn.microsoft.com/en-us/windows/desktop/fileio/naming-a-file),
including superscript COM/LPT aliases.
