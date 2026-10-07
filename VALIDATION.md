# Validation

2026-10-07 · Zig 0.17.0 · package 0.2.0.

The **gate7 isolated candidate on `finalize/20261007` passed** native safe tests,
HTTP/browser checks, five-target compilation, real terminal/CLI checks and fresh
package consumers. The recorded source maps stayed unchanged during the gates;
all 247 consumer code-map inputs still matched before this document-only update.
Newer original-checkout edits are outside this qualification.

## Completed qualification

| Check | Result |
| --- | --- |
| Native safe tests with headless browser enabled | 30/30 steps; **904/970 tests passed, 66 skipped**; exit 0; no source drift |
| HTTP loopback integration | **53 checks, 51 requests, zero cross-origin credentials** |
| Offline live-runner contract | **13 normal scenarios passed**; signal execution skipped, cleanup assertions static-only |
| Cross-target build, browser support enabled | **71/71 steps**, five executables; exit 0; no source drift |
| Real terminal and CLI | Normal/burst PTY passed; **18/18 CLI checks**; all **267** sealed files stable |
| Fresh public-module consumers | Default **11/11**, minimal **5/5** build steps; both loopbacks passed; zero code/package drift |
| Package archive audit | **255 files, 255 matching hashes**, no cache artifacts; public facade/runtime and retained notices present |

Cross targets: Linux x86_64/aarch64, Windows x86_64, macOS x86_64/aarch64.
Foreign targets received compile/link coverage only. PTY/CLI exercised the newly
built Linux x86_64 artifact, including navigation, resize, bracketed paste,
2,000 cache fixtures, normal/burst shutdown and terminal-mode restoration.

Local evidence is under `.tmp/finalize-20261007/` in the qualified isolated
checkout: `safe-http-browser-gate7.log`, its result/start/end JSON files,
`gate7/report.json`, its start/end maps, and `final-package-consumer-gate7/RESULT.md` with per-stage
logs, exits and seals. Safe integration ran 11:47:05–11:51:12 UTC with zero source changes.
Cross/PTY/CLI file-map SHA-256 (sorted compact JSON):
`d1602b108fa13c2558c333ae0eab1cd9331dd913c40814af7b65906c2438dc24`.
Consumer code-map SHA-256:
`3bc870c90549f5a454170afad5e3d2ca031a91d0acab17bd33a5646363a631f1`.

The runtime-tested package passed all seven audit/build/loopback stages. Its
247-file code seal includes source, vendor, tools and build inputs, excluding
only top-level Markdown, LICENCE and COPYING. Archive identity and exact file
maps are retained in the consumer evidence, not embedded here. A
post-documentation static repack audits archive inclusion against the unchanged
tested inputs. Runtime qualification applies to those inputs; it does not
claim the consumers ran against subsequently edited documentation.
Local evidence and harnesses are not shipped package files.

## Configurations and reproduction

Defaults: TUI and unarr enabled, browser handoff disabled. All executable/test
configurations require threaded I/O; `-Dsingle-threaded=true` is rejected.
Libraries call `scrapers.setIo(init.io)` or `subdl.setIo(init.io)` and keep the
compatible runtime alive until work completes.

Gate commands below use Zig 0.17 on PATH; dedicated cache/prefix paths were
recorded in the evidence. Native runner checks require Bash 4.3+, GNU timeout,
flock, mkfifo and standard shell utilities. HTTP/PTY checks need Python 3;
headless smoke needs local Chromium (`SUBDL_CHROMIUM_PATH` selects it).

```sh
SUBDL_CHROMIUM_SMOKE=1 zig build test test-http -Doptimize=safe -Denable-alldriver=true -j2 --summary all
zig build build-all-targets -Denable-alldriver=true -j2 --summary all
zig build test-live-runner -Doptimize=safe -j2 --summary all
```

Supported feature combinations can be checked explicitly below. These are
reproduction commands, not separate final-tree passes for every combination:

```sh
zig build test -Doptimize=debug -Denable-tui=true -Denable-unarr=true -Denable-alldriver=false -j2
zig build test -Doptimize=debug -Denable-tui=false -Denable-unarr=false -Denable-alldriver=false -j2
zig build test -Doptimize=debug -Denable-tui=true -Denable-unarr=false -Denable-alldriver=false -j2
zig build test -Doptimize=debug -Denable-tui=false -Denable-unarr=true -Denable-alldriver=false -j2
```

The retained consumer fixture pins the tested archive. Default options enable
TUI/unarr and disable browser handoff; `-Dminimal=true` disables TUI/unarr.
Both imports and both public I/O setters were exercised through two loopback
requests per executable, exact NUL-containing payloads, independent response
ownership, client/search cleanup and allocator leak checks. Reproduce from the
isolated checkout containing that local fixture:

```sh
cd .tmp/finalize-20261007/final-package-consumer-gate7
ZIG_GLOBAL_CACHE_DIR=cache/global zig build -j1 --cache-dir cache/default --prefix output/default --summary all
python3 -B loopback.py output/default/bin/package-consumer
ZIG_GLOBAL_CACHE_DIR=cache/global zig build -j1 --cache-dir cache/minimal --prefix output/minimal --summary all -Dminimal=true
python3 -B loopback.py output/minimal/bin/package-consumer
```

For a new package, audit a clean snapshot with fetch outputs outside its source:
Zig stages local directories before applying manifest exclusions. Do not place
fetch caches beneath the directory being fetched.

## Focused coverage and live limits

Gate7 focused checks already completed: IndexSubtitle **22 passed, 1 live
skip** after replacing inline iteration that rejected runtime continue;
Greeksubs **18 passed, 1 live skip**; Grupahatak **15 passed, 1 live skip**;
Unicode helper **2 passed**. Focused vendor qualification passed **41/41 tests**, with all **150 vendor
files stable**.
These focused results are separate from the integrated totals.

The runner's focused qualification passed **13 normal fixture scenarios** and
**2/2 build steps**. Ten missing-tool cases (five tools removed individually
from each of production preflight and the contract harness) returned the
expected exit 2 before creating temporary directories. A complete-PATH positive
control reached its deliberate exit-99 sentinel. No timeout signals were sent;
signal scenarios remain skipped/static-only. Evidence:
`runner-delta7-qualification/STATUS.md` and `preflight-results.json`.
Index repair evidence: `review2/index-inline-loop-fix/STATUS.md`. Focused vendor
evidence: `vendor-delta7-qualification/test.log` and `test.exit`.

Earlier TIFF/TGA qualification passed **17** with **26 absent-fixture skips**,
scoped to the unchanged tested decoder implementations. No vendor full-suite
or image-fixture completeness claim is inferred from focused checks.

The 53 provider implementations (46 exposed in CLI/TUI) are not an availability
claim. Bounded real downloads established only these selected paths:

| Provider | Observed result and limit |
| --- | --- |
| IndexSubtitle | Matrix/Chernobyl HTTP 200 ZIP payloads; signatures checked, archives not extracted |
| Kitsunekko | Death Note ASS and Spirited Away SRT; initial movie attempt failed NameServerFailure; varying catalog latency, English downloads only |
| Subtitrari-noi | Selected Matrix Resurrections/Reacher CRC-valid ZIPs with timed subtitles; not exhaustive season coverage |
| Subs4free | Matrix session-token download, CRC-valid ZIP with 1,231 cues; one movie path |
| Prijevodi | Explicit consenting-session adapter: HTTP 200, CRC-valid ZIP with 424 cues; absent configuration returns DownloadConsentRequired |

Live evidence: `.tmp/provider-a-m-live/CARSON-HANDOFF.md` and
`.tmp/provider-tail-live-20261007/{RESULTS.md,ticket-status.md}` in the parent
checkout. These probes retain their own source scope. Prijevodi's original bare
request failed missing-ticket HTTP 403; the legitimate session/ticket repair
passed 7 focused tests, 1 disabled-live skip and a separate transport regression.
Use the [documented session setup](DOCUMENTATION.md#prijevodi-download-setup).
Consent, CAPTCHA, quota/cooldown and access refusals remain explicit errors.

Broader historical sweeps had resolver failures, access blocks, timeouts and
assertions. No universal live-provider pass is claimed. Skips, absent probes
and phase-end markers are not passes. Image fixture gaps remain untested.
Browser smoke checks session plumbing, not CAPTCHA completion; headed browser
operation has no qualifying result here. Browser handoff is Linux-only.
Ordinary public-origin lookup cancellation on macOS/FreeBSD can wait for libc
getaddrinfo; address validation remains fail-closed. Terminal timings are
busy-host diagnostics, not performance benchmarks.

Archive extraction requires unarr. See [SECURITY.md](SECURITY.md) for plain-HTTP
provider and credential limits, and [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md)
for the unresolved project-grant/static-unarr distribution conditions. Passing
tests and shipping notices alone do not establish binary-release compliance.
