# Documentation

## Overview

This project provides subtitle search, subtitle listing, and subtitle download flows across multiple subtitle sites through one Zig API.

The package manifest version is `0.2.0` and its minimum supported compiler is
Zig `0.17.0`.
The registry retains 53 provider implementations; the public app layer, CLI,
and TUI expose the 46 currently active providers.

Primary entry points:

- Binary: `scrapers`
- Library: `src/lib.zig`
- App layer: `src/app/providers_app.zig`

Default behavior:

- CLI is enabled by default
- TUI is enabled by default in threaded builds and can be disabled with `-Denable-tui=false`
- Archive extraction is enabled by default and can be disabled with `-Denable-unarr=false`
- Browser automation support is compiled out by default

Browser automation remains opt-in. TUI dependencies use official upstream
sources with project-maintained Zig 0.17 compatibility and runtime-hardening
patches; see [vendor provenance](./vendor/README.md).

## Requirements

- Zig `0.17.0`
- Network access for the initial dependency fetch and for normal provider use

The native-Linux `zig build test` graph includes an offline contract test for
the live-runner's process cleanup. It requires Bash 4.3 or newer, GNU
`timeout`, `flock`, `mkfifo`, and standard `tee`, `grep`, `sed`, and `mktemp`
utilities. The gate
executes success, failure, and missing-marker cases; signal scenarios are
deliberately not executed, while generated trap and cleanup structure is checked
statically. These are test tools, not application runtime dependencies. Once
`zig build --fetch` has populated the Zig cache, deterministic builds and tests
can run offline.

## Build Commands

Build:

```bash
zig build
```

Run tests:

```bash
zig build test
```

Install:

```bash
zig build install
```

Run CLI:

```bash
zig build run -- --list-providers
zig build run -- --query "The Matrix"
```

Run TUI:

```bash
zig build run -- --tui
```

Build all target binaries into `zig-out/bin`:

```bash
zig build build-all-targets
zig build build-all-targets -Doptimize=fast -Dstrip=true
```

Outputs:

- `scrapers-x86_64-linux-gnu`
- `scrapers-aarch64-linux-gnu`
- `scrapers-x86_64-macos-none`
- `scrapers-aarch64-macos-none`
- `scrapers-x86_64-windows-gnu.exe`

## Optional Build Flags

General:

- `-Doptimize=debug|safe|fast|small`
- `-Dstrip=true|false`
- `-Dsingle-threaded=true|false`
- `-Domit-frame-pointer=true|false`
- `-Derror-tracing=true|false`
- `-Dpic=true|false`
- `-Dllvm=true|false`

Feature gates:

- `-Denable-tui=true|false`
- `-Denable-alldriver=true|false`
- `-Denable-unarr=true|false`

Notes:

- ordinary host build, run, and install steps default to `-Doptimize=fast`; test
  steps default to `-Doptimize=debug` when no optimization mode is requested
- `--release=safe|fast|small` selects that mode for builds and tests, including
  nested live convenience targets; an explicit `-Doptimize` takes precedence
- `build-all-targets` defaults to `-Doptimize=fast`
- `build-all-targets` defaults to `-Dstrip=true`
- LLVM code generation is enabled by default; if it was explicitly disabled and
  a native GNU build hits host CRT `.sframe` relocation errors, restore
  `-Dllvm=true`
- default host builds enable TUI and archive extraction; browser automation remains opt-in
- executable and test targets reject `-Dsingle-threaded=true`, including builds
  with the TUI disabled: HTTP request deadlines require concurrent I/O
- dependency-based library consumers can still obtain the public modules, but
  must supply an I/O backend supporting the concurrent operations they use

## Provider IDs

Supported canonical provider IDs:

- `subdl_com`
- `opensubtitles_com`
- `moviesubtitles_org`
- `yifysubtitles_ch`
- `subtitlecat_com`
- `isubtitles_org`
- `subsource_net`
- `sub_scene_com`
- `gestdown_info`
- `subsunacs_net`
- `subtitles_ajatt_top`
- `subtis_io`
- `greeksubs_net`
- `indexsubtitle_cc`
- `sous_titres_eu`
- `cc_edatribe_com`
- `subtitrari_noi_ro`
- `subclub_eu`
- `subs_ro`
- `subs4free_info`
- `tsukihime_org`
- `subtitri_nekur_net`
- `subsynchro_com`
- `titrari_ro`
- `subs_sab_bz`
- `subtitri_do_am`
- `prijevodi_online_org`
- `animekalesi_com`
- `subcentral_de`
- `subtitulamos_tv`
- `feliratok_eu`
- `animesub_info`
- `animetosho_xyz`
- `kitsunekko_net`
- `thesubtitledb_org`
- `napisy24_pl`
- `nyasub_cz`
- `subhd_tv`
- `fansubs_ru`
- `legendei_net`
- `zoom_lk`
- `justsubtitles_com`
- `wizdom_xyz`
- `miraianime_net`
- `grupahatak_pl`
- `jimaku_cc`

The seven retained inactive implementations are `opensubtitles_org`,
`moviesubtitlesrt_com`, `podnapisi_net`, `my_subs_co`, `tvsubtitles_net`,
`greek_subtitles_com`, and `animesubtitle_ir`. Their last observed
upstream failures are described in the README. Targeted live tests retain
recovery coverage. Activation requires anonymous search, subtitle listing and
a real file download for each advertised media class.

`gestdown_info` is TV-only. `yifysubtitles_ch` is movie-only.
`subtis_io` is movie-only.
`subtitles_ajatt_top` focuses on Japanese subtitles for anime TV and movies.
`greeksubs_net` provides Greek subtitles for movies and TV.
`sous_titres_eu` provides French subtitles for movies and TV.
`cc_edatribe_com` provides English anime movie and TV captions.
`subtitrari_noi_ro` provides Romanian movie and TV subtitle archives.
`titrari_ro` provides Romanian and English subtitles for movies and TV.
`subs_sab_bz` provides English and Bulgarian subtitles for movies and TV.
`subtitri_do_am` is movie-only and provides Latvian subtitles.
`prijevodi_online_org` is TV-only and uses the site's current public JSON API.
`animekalesi_com` is TV-only and provides Turkish anime subtitles through the site's session-bound download flow.
`subcentral_de` is TV-only and provides German and English series subtitles.
`subtitulamos_tv` is TV-only and provides direct episode subtitle files in English, Spanish, Portuguese, Catalan, and Galician.
`feliratok_eu` is movie-only and provides direct Hungarian and English subtitle files.
`animesub_info` provides Polish anime movie and TV subtitles with fresh download-token replay.
`subhd_tv` uses SubHD's current prepare-download flow for movie and TV subtitles.
`fansubs_ru` provides Russian anime movie and TV archives.
`legendei_net` uses the public WordPress search API and each post's own subtitle download link.
`zoom_lk` provides Sinhala movie and TV season subtitle archives through the site's public search and `/sub-download` endpoints.
`justsubtitles_com` is movie-only and reads the subtitle rows embedded in the server-rendered Next.js payload; downloads come directly from `dl.subdl.com`.
`wizdom_xyz` resolves titles through TMDB and downloads Hebrew movie and episode subtitle ZIPs from Wizdom's public API.
`miraianime_net` resolves anime through MiraiAnime's public WordPress API and downloads Arabic subtitle archives directly from the subtitle library.
`animesubtitle_ir` uses the site's public WordPress search API and Download Monitor links for Persian anime movie and TV archives.
`grupahatak_pl` is TV-only and replays the series-page Referer required by its public Polish episode ZIPs.
`jimaku_cc` reads Jimaku's public anime catalog and direct entry downloads for Japanese movie and TV subtitles.

Plaintext-network warning: `subsynchro_com`, `subs_sab_bz`, `animesub_info`, and
`fansubs_ru` currently depend on upstream workflows available only over HTTP.
The retained inactive `tvsubtitles_net` recovery path is also plain HTTP.
Searches and downloads through these paths are unencrypted, so avoid them on
untrusted networks. AnimeSub's short-lived cookie is confined to the provider's
exact route, but that does not protect the HTTP hop.

The parser also accepts dotted or hyphenated site forms such as `subsource.net`.

## CLI Reference

Usage:

```text
scrapers --query <text> [--providers a,b] [--provider name] [-p provider] [--search-page N] [--subtitle-page N] [--title-index N] [--subtitle-index N] [--out-dir DIR] [--extract]
scrapers --list-providers
scrapers --tui
```

Options:

- `--providers <list>`: comma-separated active provider IDs or unique prefixes;
  when no provider selector is supplied, all 46 active providers are selected
- `--providers none`, `--providers=none`, `-p none`, `-p=none`, and `-pnone`: reset the selection; add at least one provider afterward for a runnable query
- `-p <provider>`: repeatable provider selector; values may also be comma-separated
- `--provider <name>`: compatibility alias for selecting one provider
- `--query <text>`: search query
- `--search-page <N>`: one-based provider search page, default `1`
- `--subtitle-page <N>`: one-based subtitle-list page, default `1`
- `--title-index <N>`: selected search result, default `0`
- `--subtitle-index <N>`: selected subtitle row, default first downloadable row
- `--out-dir <DIR>`: download destination, default `downloads`
- `--extract`: extract archives after download
- `--list-providers`: print available providers
- `--help`, `-h`: print help
- `--tui`: launch the TUI instead of the CLI (requires TUI support and a
  threaded build; unavailable configurations return an explicit error)

Important:

- `--extract` extracts supported archives when built with
  `-Denable-unarr=true`; otherwise the original archive is saved and the CLI
  reports that an external extraction tool is required

Examples:

```bash
zig build run -- --query "The Matrix"
zig build run -- --providers subdl_com,subsource_net --query "Inception" --title-index 1 --subtitle-index 0
zig build run -- -p subdl --query "Breaking Bad" --out-dir .tmp/subtitles
zig build run -- -pnone -p subdl_com --query "The Matrix"
zig build -Denable-unarr=true run -- --providers subsource --query "The Matrix" --extract
./zig-out/bin/scrapers --providers isubtitles_org --query "Interstellar"
```

## TUI Reference

The TUI is built around the same provider app layer as the CLI and is enabled by
default. Executable builds require threaded I/O for HTTP deadlines and terminal
input, and reject `-Dsingle-threaded=true` even when the TUI is disabled.

Build and run it with:

```bash
zig build run -- --tui
```

Flow:

1. Select providers with `Space`, or leave all providers unselected
2. Enter query
3. Select title
4. Select subtitle row
5. Confirm download if confirmation is enabled

Key behaviors:

- Provider selection starts empty when there is no saved history.
- `Space` toggles the highlighted provider on the home screen.
- `Enter` with zero selected providers opens the highlighted provider.
- `Enter` with one selected provider opens that provider, even if a different provider is highlighted.
- `Enter` with multiple selected providers opens a combined search tab across the selected providers.
- `[` and `]` only navigate pages for providers that actually support pagination

## Pagination Behavior

Search pagination in the active provider registry:

- `isubtitles_org`

The retained inactive implementations `opensubtitles_org`,
`moviesubtitlesrt_com`, and `podnapisi_net` also implement paginated search.

Subtitles pagination in the active provider registry:

- `isubtitles_org`
- `subsource_net`

The retained inactive `opensubtitles_org` implementation also implements
subtitle pagination.

No pagination:

- `my_subs_co`
- providers not listed above

For non-paginated providers:

- page `1` returns normal data
- page `>1` returns an empty page result

## Library API

The package name is `subdl`. It publishes the recommended unified `scrapers`
module and a lower-level compatibility module named `subdl`. Adding the package
to `build.zig.zon` does not put either module into an
application's import table automatically. Assuming the dependency uses its
default `subdl` key, wire it into the application's root module in `build.zig`:

```zig
const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const subdl = b.dependency("subdl", .{
        .target = target,
        .optimize = optimize,
        .@"enable-tui" = false,
        .@"enable-alldriver" = false,
        .@"enable-unarr" = true,
    });
    const app = b.addExecutable(.{
        .name = "subtitle-app",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    app.root_module.addImport("scrapers", subdl.module("scrapers"));
    b.installArtifact(app);
}
```

Library-only consumers should normally disable the TUI as above so libvaxis and
terminal-only modules are not attached to their application. Keep
`enable-unarr` enabled when using archive extraction, and opt into
`enable-alldriver` only when local Chromium session handoff is required. The
quoted dependency fields are required because the corresponding build option
names contain hyphens. A consumer that chooses another dependency key must use
that key in `b.dependency(...)`; the imported module name remains `scrapers`.
Legacy consumers can instead (or additionally) wire the compatibility facade
with `app.root_module.addImport("subdl", subdl.module("subdl"));`. Both published
modules share the canonical scraper module graph and can be imported by one
application without compiling the provider sources as duplicate modules.

Application source can then import the module directly:

```zig
const scrapers = @import("scrapers");
```

Call `scrapers.setIo(init.io)` once before using scraper APIs or starting
workers. Configuring `std.http.Client.io` alone does not initialize the shared
runtime used by scraper timestamps and other helpers. The runtime must support
concurrent tasks for request deadlines and remain alive until all scraper work
ends; the setter is initialization-only, not a concurrent runtime swap.
Compatibility-module consumers use `subdl.setIo(init.io)`. Both aliases
initialize the same shared runtime, so applications importing both modules
initialize it only once.

Common app-layer functions:

- `providers_app.providers()`
- `providers_app.parseProvider()`
- `providers_app.search()`
- `providers_app.searchPage()`
- `providers_app.fetchSubtitles()`
- `providers_app.fetchSubtitlesPage()`
- `providers_app.downloadSubtitleWithOptions()`
- `providers_app.downloadSubtitleWithProgressAndOptions()`

## Library Example: Search Then Download

```zig
const std = @import("std");
const scrapers = @import("scrapers");

pub fn main(init: std.process.Init) !void {
    scrapers.setIo(init.io);
    var client: std.http.Client = .{
        .allocator = init.gpa,
        .io = init.io,
    };
    defer client.deinit();

    var search = try scrapers.providers_app.search(
        init.gpa,
        &client,
        .subsource_net,
        "The Matrix",
    );
    defer search.deinit();

    if (search.items.len == 0) return;

    var subtitles = try scrapers.providers_app.fetchSubtitles(
        init.gpa,
        &client,
        search.items[0].ref,
    );
    defer subtitles.deinit();

    if (subtitles.items.len == 0) return;
    if (subtitles.items[0].download_url == null) return;

    var result = try scrapers.providers_app.downloadSubtitleWithOptions(
        init.gpa,
        &client,
        subtitles.items[0],
        "downloads",
        .{ .extract_archive = false },
    );
    defer result.deinit(init.gpa);
}
```

## Library Example: Paginated Search

```zig
const std = @import("std");
const scrapers = @import("scrapers");

pub fn main(init: std.process.Init) !void {
    scrapers.setIo(init.io);
    var client: std.http.Client = .{
        .allocator = init.gpa,
        .io = init.io,
    };
    defer client.deinit();

    var page1 = try scrapers.providers_app.searchPage(
        init.gpa,
        &client,
        .isubtitles_org,
        "The Office",
        1,
    );
    defer page1.deinit();

    if (!page1.has_next_page) return;

    var page2 = try scrapers.providers_app.searchPage(
        init.gpa,
        &client,
        .isubtitles_org,
        "The Office",
        2,
    );
    defer page2.deinit();
}
```

## Library Example: Download Progress

```zig
const std = @import("std");
const scrapers = @import("scrapers");

fn onPhase(_: ?*anyopaque, phase: scrapers.providers_app.DownloadPhase) void {
    std.debug.print("phase: {s}\n", .{@tagName(phase)});
}

fn onUnits(_: ?*anyopaque, done: usize, total: usize) void {
    std.debug.print("progress: {d}/{d}\n", .{ done, total });
}

pub fn main(init: std.process.Init) !void {
    scrapers.setIo(init.io);
    var client: std.http.Client = .{
        .allocator = init.gpa,
        .io = init.io,
    };
    defer client.deinit();

    var search = try scrapers.providers_app.search(init.gpa, &client, .subsource_net, "The Matrix");
    defer search.deinit();
    if (search.items.len == 0) return;

    var subs = try scrapers.providers_app.fetchSubtitles(init.gpa, &client, search.items[0].ref);
    defer subs.deinit();
    if (subs.items.len == 0 or subs.items[0].download_url == null) return;

    const progress = scrapers.providers_app.DownloadProgress{
        .on_phase = onPhase,
        .on_units = onUnits,
    };

    var result = try scrapers.providers_app.downloadSubtitleWithProgressAndOptions(
        init.gpa,
        &client,
        subs.items[0],
        "downloads",
        &progress,
        .{ .extract_archive = false },
    );
    defer result.deinit(init.gpa);
}
```

## Downloaded Files

- Downloaded filenames retain file extensions where available
- Extension fallback is inferred from URL or response data when needed
- When archive extraction is enabled, the original archive path is still tracked in `DownloadResult.archive_path`

Archive classification is based on payload signatures, not filename or URL
suffixes. ZIP and stored RAR4 extraction are preflighted and bounded to 256
entries, 64 MiB per entry, and 128 MiB total. Extraction uses private staging
and publishes without replacing existing output paths. 7z, RAR5, and compressed
or otherwise unsupported RAR4 archives are retained with
`DownloadResult.extraction_unavailable = true` so an external tool can handle
them. The same unavailable result is returned for recognized archives when
extraction is requested from a build with `-Denable-unarr=false`.

The HTTP transport advertises only identity, gzip, and deflate response
encodings. Gzip CRC/size fields and deflate's zlib checksum are verified, with
separate limits on encoded and decoded bytes. HTTP zstd is neither advertised
nor accepted because Zig 0.17's decoder has a fixed window ceiling and does not
verify content checksums. This does not affect provider XZ attachments, which
use a separate bounded decoder with stream and block checksum validation.

## Prijevodi download setup

Prijevodi downloads require a browser session in which you have enabled the
site's download-protection consent. Configure all three values from that same
authorized browser session before starting the application:

| Variable | Value |
| --- | --- |
| `SCRAPERS_PRIJEVODI_COOKIE` | The browser's Cookie header, including `po_visitor` |
| `SCRAPERS_PRIJEVODI_USER_AGENT` | That browser session's matching user-agent string |
| `SCRAPERS_PRIJEVODI_FINGERPRINT` | The site's actual 64-character hexadecimal SHA-256 browser fingerprint |

In that browser, open DevTools → Network and perform a normal authorized
download. Inspect the `/api/v1/downloads/ticket` request: use its `Cookie`,
`User-Agent`, and `X-PO-Fingerprint` request headers for the three variables
above, respectively. Keep these values private and out of the repository.

Do not invent a fingerprint or mix values from different sessions. With no
session configured, downloads return `DownloadConsentRequired`; partial or
malformed configuration returns `InvalidDownloadSession`. The adapter requests
a fresh ticket immediately before each download. Consent, CAPTCHA, cooldown,
quota, and block refusals remain explicit errors and are not automatically
retried. Session configuration does not guarantee the provider will issue a
ticket.

Library callers can instead pass `DownloadSession { cookie, user_agent,
fingerprint }` to `prijevodi_online_org.Scraper.fetchDownloadByUrlWithSession`.
These values are credentials; keep them out of logs and version control.

## Environment Variables

Runtime and provider controls:

- `SUBSOURCE_CF_CLEARANCE`: an authorized, manually obtained Cloudflare session
  cookie for SubSource. Treat it as a credential; do not share or commit it.
- `SUBSOURCE_USER_AGENT`: the browser user agent paired with that authorized
  cookie. It is also sensitive when it identifies a live session.
- `SUBDL_WIZDOM_TMDB_API_KEY`: optional TMDB v3 API-key override for Wizdom
  title resolution. It must be exactly 32 lowercase hexadecimal characters.
  Invalid or empty configured values fail before a request; when unset, the
  provider uses the public legacy key published by its upstream implementation.
  Treat an override as a credential and do not share or commit it.
- `SUBDL_CHROMIUM_PATH`: absolute path to a local Chrome, Chromium, Edge,
  Brave, or Vivaldi executable. Its root CDP product must report Chrome or
  Chromium 154 or newer. Browser session handoff is supported on Linux. macOS
  and FreeBSD fail closed until browser DNS can be cancelled at the deadline;
  Windows fails closed pending secure native handle and DACL support.
- `SUBDL_CF_HEADLESS`: `1`/`true`/`yes`/`headless` selects headless-only mode;
  `0`/`false`/`no`/`headed` selects visible-only mode; unset, `auto`, empty, or
  unrecognized values select automatic mode. On Linux, automatic mode starts
  visibly when `DISPLAY` or `WAYLAND_DISPLAY` is non-empty, then retries every
  browser candidate headlessly if the visible pass does not acquire a session.
  With neither display variable, automatic mode is headless-only.

Successful browser sessions are cached on a best-effort basis in the
credential-bearing `cloudflare_shared_sessions.json` file when a valid absolute
cache root and writable private storage are available. On Unix it is located at
`$XDG_CACHE_HOME/subdl/` when `XDG_CACHE_HOME` is absolute, otherwise at
`$HOME/.cache/subdl/` when `HOME` is absolute; without either usable root,
persistent caching is unavailable. Remove the file, if present, to invalidate
saved sessions. Use only sessions you are authorized to use. One four-minute
absolute acquisition deadline is shared by queueing, normal cache work, DNS,
browser launch and I/O, and any visible manual completion. In automatic mode,
each visible browser attempt receives at most 60 seconds and the final 60
seconds of the global deadline are reserved for the headless pass; earlier work
can shorten that visible opportunity. Explicit headed mode has no headless
fallback and gives its visible attempt the full time remaining. An authorized
user may manually complete a challenge only during a visible attempt.

Live test controls:

- `SCRAPERS_LIVE_PROVIDER_FILTER`
- `SCRAPERS_LIVE_PROVIDERS`

Debug flags:

- `SCRAPERS_DEBUG_TIMING`
- `SCRAPERS_SELECTOR_DEBUG`
- `SCRAPERS_DEBUG_ISUB`
- `SCRAPERS_DEBUG_TVSUB`

Test-only browser control:

- Both test flags below require `SUBDL_CHROMIUM_PATH` to name the browser
  executable; without it, the corresponding smoke tests skip.
- `SUBDL_CHROMIUM_SMOKE=1`: opt in to the local Chromium integration smoke; it
  runs headlessly and is not needed for normal use.
- `SUBDL_CHROMIUM_HEADED_SMOKE=1`: separately opt in to the visible-window
  external-protocol probe. It requires a working graphical display/compositor
  and is not needed for normal use.

## Live Testing

Smoke suite:

```bash
zig build test-live -Dlive=smoke '-Dlive-providers=*'
```

Live modes are intentionally disjoint. `smoke` runs the application
search/list/download path, `named` runs provider-local direct probes, and
`extensive` runs the deeper field-oriented probes for the providers it covers.
`all` explicitly composes all three modes and therefore sends more requests.

Registry capability metadata currently marks all 53 providers as runnable in
`smoke`, 48 in `named`, and 10 in `extensive`. An active `named` selection runs
43 of 46 providers; `isubtitles.org`, `subsource.net`, and `sub-scene.com` have
no named probe. An inactive `named` selection runs five of seven providers;
`my-subs.co` and `tvsubtitles.net` have no named probe. Those five providers
instead have extensive probes. The runner reports each unavailable suite as
`NO_PROBE`; that status is neither a skip nor a pass.

Extensive suite for one provider:

```bash
zig build test-live-single -Dlive=extensive -Dlive-providers=subsource.net
```

For authorized manual testing of a challenge in a visible browser, use one
provider at a time from a working graphical Linux session:

```bash
SUBDL_CF_HEADLESS=headed \
SUBDL_CHROMIUM_PATH=/absolute/path/to/chromium \
zig build test-live-single \
  -Dlive=all \
  -Dlive-providers=subsource.net \
  -Denable-alldriver=true \
  -Dlive-timeout-seconds=5100 \
  -j1
```

This permits the authorized user to complete a displayed challenge manually; it
does not solve a CAPTCHA or bypass an access block, and an unresolved challenge
remains a test failure.

All providers currently exposed by the CLI/TUI:

```bash
zig build test-live-active
```

All retained provider implementations, including inactive recovery probes:

```bash
zig build test-live-all
```

Parallel fan-out mode:

```bash
zig build test-live -Dlive=all '-Dlive-providers=*' -Dlive-parallel-on-all=true -Dlive-max-jobs=3
```

Live fanout defaults to four jobs and a 60-second deadline, with longer defaults
for selected registry entries. `-Dlive-timeout-seconds=N` must be positive.
An explicit deadline replaces all registry deadlines. The browser-assisted
OpenSubtitles.com, SubSource, and AnimeKalesi entries share a conservative
5100-second subprocess ceiling. It budgets up to six complete recovery chains;
each chain comprises three two-minute fetch budgets and two four-minute session
acquisitions, followed by one minute of runner margin. Six chains cover two
enabled probes with independently browser-assisted search, listing, and download
stages. OpenSubtitles.com needs fewer such stages, and SubSource's extensive
probe explicitly disables automatic browser recovery. Actual runs normally
reuse the session cache or fail earlier. Each individual browser acquisition
remains limited to four minutes. `test-live-single` is a compatibility alias for
`test-live`: both use the marker-validated runner with a separate deadline for
each selected provider, including single-provider and serialized selections.
`test-live` fans out every filter that resolves to more than one distinct
provider. `-Dlive-parallel-on-all=false`
suppresses that fanout only for the special `*`/`all` selection; `active` and
explicit multi-provider selections still fan out so each provider has a visible
result. The `test-live-active` and `test-live-all` convenience targets preserve
the caller's native feature, optimization, and live-limit options, serialize
their nested Zig build with `-j1`, and deliberately ignore target/CPU options
because live binaries execute on the host. They override
ambient provider-filter variables and select the `smoke` suite so a provider
sweep does not repeat the same upstream flow in direct and extensive probes.
TV-only providers receive one series-validated application smoke; providers that
support both media kinds retain distinct movie and series smokes. Use an explicit
`test-live -Dlive=named|extensive|all` command when those suites are required.
Provider filters accept canonical IDs, dotted names, and unambiguous partial
names; unknown or ambiguous tokens fail configuration, including environment
overrides. `*` or `all` must be the only filter token. Check
completed tests and exit status: skipped probes and phase-end log lines do not
establish success.

Network live execution requires a native Linux target, Bash 4.3 or newer, GNU
`timeout`, `flock`, `mkfifo`, and network access. The separate `test-http` gate requires Python
3 and loopback sockets. Non-Linux deterministic tests and
`build-all-targets` cross-compilation do not run the Linux-only runner
contract.

The extensive suite primarily checks metadata. Smoke/all modes exercise application
search, listing and downloads, including TV selection where advertised. Unresolved
challenge and access-block responses remain explicit failures. An authorized user
may manually complete a challenge in the visible browser; qualification does not
solve CAPTCHAs or bypass access controls. Browser support supplies an ordinary
session handoff when explicitly enabled, not a CAPTCHA solver. On Linux it uses
a private, deadline-bounded pipe to a local Chromium-family browser.
Auto-discovery covers Chrome, Chromium, Edge, Brave, and Vivaldi, while
the root CDP product must report Chrome or Chromium 154 or newer. DNS permits
only pinned public answers for the challenged host and Cloudflare's challenge
host. A process-wide unroutable proxy denies traffic by default, and direct
bypasses are limited to those exact HTTPS hosts on port 443. Ambient/corporate
proxy settings, other origins, required subdomains/CDNs, and WebSockets are not
used and therefore fail closed. Browser policy denies downloads and unexpected
browsing targets; Chromium local-network controls reject literal/private targets.
External-protocol attempts are monitored. The private browser's session bus
points to an inaccessible socket, and private failing `xdg-email`/`xdg-open`
stubs shadow ambient helpers while preserving the inherited `PATH` for browser
launch wrappers and graphical-session utilities.
Firefox is not supported. macOS and FreeBSD handoff fails closed until their
blocking resolver path can be cancelled reliably; Windows fails closed pending
secure native handle/DACL support. The single acquisition deadline covers
queueing, normal cache work, DNS, browser launch and I/O, and manual completion.
Automatic graphical mode caps each visible attempt at 60 seconds and reserves
the last 60 seconds for a headless fallback; explicit headed mode instead uses
the full remaining deadline without fallback. A kernel filesystem operation
stuck on pathological remote or FUSE storage cannot be preempted, so the session
cache should reside on local storage.

Outside browser handoff, public-origin-pinned HTTP requests still use the host
resolver. On macOS and FreeBSD, Zig 0.17 delegates that lookup to blocking libc
`getaddrinfo`; cancellation waits for the syscall to return. Public-address
validation still applies, but cancellation latency for that lookup is not a hard
deadline on those platforms.

## Upstream Dependencies

Owned dependencies use immutable commit and content-hash pins in `build.zig.zon`:

- `htmlparser`: `SmallThingz/zhtml` at
  `4130c7c348fd824df72d6096fc21b3e3c53b3bd5` (always required)
- `unarr`: `SmallThingz/unarr.zig` at
  `077de0c78813cf851556a8907911e531d63ac67d` (lazy; selected by
  `-Denable-unarr=true`, which is the default)

The selected `unarr.zig` package in turn pins its native `selmf/unarr`
dependency at commit `00799b5d6a7456eff37276ad376d1715ee222e02` with Zig
content hash `N-V-__8AABWMCgDgDrwfEHLcf0rwMuWfSTEMZsTxuSs3oRJs`. The
wrapper's `LICENSE` and the native package's `COPYING` each retain the LGPLv3
supplemental text.

`-Denable-alldriver=true` remains the compatibility name for the locally
implemented Chromium CDP handoff; it no longer selects an `alldriver` package.
The TUI likewise has no serializer dependency. It uses bounded, allocation-
budgeted framed JSON with a versioned magic line. New state is stored in
`state.json`, `settings.json`, `keywords.json`, and `ui-preferences.json`.
Legacy `*.oneserial` state is detected but never read, overwritten, or deleted;
the TUI uses defaults and reports a nonfatal reset/migration notice until new
state is saved.

The vendored libvaxis manifest lazily pins its nested `uucode` dependency at
`1fb73433bba5d93366c57f23ff2e9d7939746500` with Zig content hash
`uucode-0.2.0-ZZjBPm6FVgBcY-79AHV8ckQj86z0JwOyVyj89VeZrEiv`. Its main MIT
license and the Bjoern Hoehrmann and Unicode notices referenced by that license
are shipped under `vendor/libvaxis/THIRD_PARTY_LICENSES/uucode`; exact hashes
and applicability are in [vendor provenance](./vendor/README.md). All selected dependency manifests
declare Zig 0.17 compatibility. The TUI uses official-source `libvaxis` and
`zigimg` copies with project-maintained Zig 0.17 compatibility plus runtime
correctness, security, and lifecycle hardening. Exact content hashes, source
commits, shipped licenses, and local changes are recorded in the package
manifests, retained license files, and [vendor provenance](./vendor/README.md).

## License texts

The root `COPYING` is included only as the verbatim GPLv3 companion text
incorporated and referenced by the LGPLv3 supplemental terms in `LICENCE`. It
comes from the official FSF source at
<https://www.gnu.org/licenses/gpl-3.0.txt> and has SHA-256
`3972dc9744f6499f0f9b2dbf76696f2ae7ad8af9b23dde66d6af86c9dfb36986`.
Shipping that companion does not apply GPLv3 to the project, choose between an
“only” and “or later” LGPL version, or establish project copyright terms. The
project owner must still clarify the intended project-wide license before
release.

Default install and `build-all-targets` place the project texts, dependency
licenses and notices, and vendor provenance below `share/licenses/scrapers`
and `share/doc/scrapers`. The provenance and exact retained-file hashes are in
[THIRD_PARTY_NOTICES.md](./THIRD_PARTY_NOTICES.md). Installing those files
improves artifact metadata but is not a compliance determination. In
particular, the default `-Denable-unarr=true` build statically links LGPLv3
unarr code. Those artifacts remain non-publishable until the owner approves a
compatible project license grant and the release includes the required
corresponding source and application material, relinking instructions, and
installation information where applicable.

## Project Structure

- `src/lib.zig`: public library exports
- `src/app/providers_app.zig`: unified provider API
- `src/cmd/main.zig`: single-binary entrypoint
- `src/cmd/cli.zig`: CLI flow
- `src/cmd/tui_backend.zig`: TUI feature-gated wrapper
- `src/scrapers/*.zig`: provider implementations
- `src/deps/*_compat.zig`: upstream compatibility wrappers
- `build.zig`: build graph, test steps, target builds
