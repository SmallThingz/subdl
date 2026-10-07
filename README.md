# SubDL Zig Scrapers

Subtitle scrapers in Zig with a shared provider API and a single `scrapers` binary.

![Package](https://img.shields.io/badge/Package-0.2.0-6f42c1)
![Zig](https://img.shields.io/badge/Zig-0.17.0-f7a41d)
![Providers](https://img.shields.io/badge/Active_Providers-46-2ea44f)
![Runtime](https://img.shields.io/badge/HTTP-std.http%20(Client)-0366d6)

## Overview

- 46 active providers exposed through one app layer: `providers_app`
- 53 provider implementations retained in the registry and represented in the
  live-test harness; harness coverage is not a live qualification result
- One binary: `scrapers`
- CLI mode by default
- TUI mode available with `--tui` in the default threaded build
- Runtime HTTP implemented with Zig `std.http.Client`
- No runtime `curl` dependency

## Requirements

- Zig `0.17.0`
- Network access for the initial dependency fetch and for provider queries and
  downloads

On native Linux, `zig build test` also runs the offline live-runner cleanup
contract. That contract requires Bash 4.3 or newer, GNU `timeout`, `flock`,
`mkfifo`, and standard `tee`, `grep`, `sed`, and `mktemp` utilities. It executes success, failure, and
missing-marker cases; signal scenarios are deliberately not executed, while the
generated trap and cleanup structure is checked statically. These tools are not
runtime dependencies of the application.
After `zig build --fetch` has populated the Zig cache, deterministic builds and
tests do not require network access.

Package version `0.2.0` publishes the recommended `scrapers` module and the
lower-level compatibility module `subdl`. The optional `unarr` dependency is
lazy and is resolved only when archive extraction is selected. Browser handoff
is implemented locally, and TUI persistence uses Zig's `std.json`; neither
feature adds an upstream package dependency.

## Library initialization

After wiring the `scrapers` module into your build, initialize its I/O runtime
before calling scraper APIs or starting workers:

```zig
const std = @import("std");
const scrapers = @import("scrapers");

pub fn main(init: std.process.Init) !void {
    scrapers.setIo(init.io);
    var client: std.http.Client = .{ .allocator = init.gpa, .io = init.io };
    defer client.deinit();

    var results = try scrapers.providers_app.search(init.gpa, &client, .subsource_net, "The Matrix");
    defer results.deinit();
}
```

Call `setIo` once during initialization and keep the runtime alive until all
scraper work ends. It must support concurrent tasks for request deadlines; do
not replace it while work is running. The compatibility module exposes the same
setter as `subdl.setIo(init.io)`. See [Library API](DOCUMENTATION.md#library-api)
for build wiring and download examples.

## Providers

| Provider id | Site |
|---|---|
| `subdl_com` | `subdl.com` |
| `opensubtitles_com` | `opensubtitles.com` |
| `moviesubtitles_org` | `moviesubtitles.org` |
| `yifysubtitles_ch` | `yifysubtitles.ch` |
| `subtitlecat_com` | `subtitlecat.com` |
| `isubtitles_org` | `isubtitles.org` |
| `subsource_net` | `subsource.net` |
| `sub_scene_com` | `sub-scene.com` |
| `gestdown_info` | `gestdown.info` |
| `subsunacs_net` | `subsunacs.net` |
| `subtitles_ajatt_top` | `subtitles.ajatt.top` |
| `subtis_io` | `subtis.io` |
| `greeksubs_net` | `greeksubs.net` |
| `indexsubtitle_cc` | `indexsubtitle.cc` |
| `sous_titres_eu` | `sous-titres.eu` |
| `cc_edatribe_com` | `cc.edatribe.com` |
| `subtitrari_noi_ro` | `subtitrari-noi.ro` |
| `subclub_eu` | `subclub.eu` |
| `subs_ro` | `subs.ro` |
| `subs4free_info` | `subs4free.info` |
| `tsukihime_org` | `tsukihime.org` |
| `subtitri_nekur_net` | `subtitri.nekur.net` |
| `subsynchro_com` | `subsynchro.com` |
| `titrari_ro` | `titrari.ro` |
| `subs_sab_bz` | `subs.sab.bz` |
| `subtitri_do_am` | `subtitri.do.am` |
| `prijevodi_online_org` | `prijevodi-online.org` |
| `animekalesi_com` | `animekalesi.com` |
| `subcentral_de` | `subcentral.de` |
| `subtitulamos_tv` | `subtitulamos.tv` |
| `feliratok_eu` | `feliratok.eu` |
| `animesub_info` | `animesub.info` |
| `animetosho_xyz` | `animetosho.xyz` |
| `kitsunekko_net` | `kitsunekko.net` |
| `thesubtitledb_org` | `thesubtitledb.org` |
| `napisy24_pl` | `napisy24.pl` |
| `nyasub_cz` | `nyasub.cz` |
| `subhd_tv` | `subhd.tv` |
| `fansubs_ru` | `fansubs.ru` |
| `legendei_net` | `legendei.net` |
| `zoom_lk` | `zoom.lk` |
| `justsubtitles_com` | `justsubtitles.com` |
| `wizdom_xyz` | `wizdom.xyz` |
| `miraianime_net` | `miraianime.net` |
| `grupahatak_pl` | `grupahatak.pl` |
| `jimaku_cc` | `jimaku.cc` |

Retained inactive implementations are `opensubtitles_org` and `tvsubtitles_net`
because their last observed user path was blocked by the Australian website-block page,
`moviesubtitlesrt_com` because its host was unreachable in that qualification,
`greek_subtitles_com` because its live search endpoint stalled or returned HTTP 524,
and `my_subs_co`, `podnapisi_net`, and `animesubtitle_ir` because their required
upstream hosts had no usable address.
They remain selectable by the live smoke harness, with other focused probes where
implemented, so future upstream recovery can be checked without advertising a
provider whose complete user path is known to be unreliable.
Here, “active” means exposed by the current CLI/TUI registry; it is not a claim
that every upstream was freshly reachable during the latest local run. Registry
and harness counts likewise do not mean that all 53 providers passed a current
live qualification.

`gestdown_info` is TV-only. `yifysubtitles_ch` is movie-only.
`subtis_io` is movie-only.
`subtitles_ajatt_top` focuses on Japanese subtitles for anime TV and movies.
`greeksubs_net` provides Greek subtitles for movies and TV.
`sous_titres_eu` provides French subtitles for movies and TV.
`cc_edatribe_com` provides English anime movie and TV captions.
`subtitrari_noi_ro` provides Romanian movie and TV subtitle archives.
`subclub_eu` provides Estonian subtitles for movies and TV episodes via direct subtitle files.
`subs_ro` provides Romanian and English subtitles for movies and TV.
`subs4free_info` is movie-only and provides Greek and English subtitles through a session-bound archive download flow.
`tsukihime_org` provides anime movie and TV subtitles from TsukiHime native cached subtitle storage; AnimeTosho-mirrored entries are skipped because that redirected storage was not reachable during qualification.
`subtitri_nekur_net` provides Latvian movie subtitles.
`subsynchro_com` is movie-only and provides French subtitles.
`titrari_ro` provides Romanian and English subtitles for movies and TV.
`subs_sab_bz` provides English and Bulgarian subtitles for movies and TV.
`subtitri_do_am` is movie-only and provides Latvian subtitles.
`prijevodi_online_org` is TV-only and provides Croatian, Serbian, Bosnian, Montenegrin, and related subtitle variants.
`animekalesi_com` is TV-only and provides Turkish anime subtitles.
`subcentral_de` is TV-only and provides German and English series subtitles.
`subtitulamos_tv` is TV-only and provides English, Spanish, Portuguese, Catalan, and Galician subtitles.
`feliratok_eu` is movie-only and provides Hungarian and English subtitles.
`animesub_info` provides Polish anime movie and TV subtitles.
`animetosho_xyz` provides multi-language anime movie and TV subtitles through AnimeTosho's public feed and verified XZ attachment downloads.
`kitsunekko_net` provides English and Japanese anime subtitles from the public Kitsunekko title directories; RAR and 7z entries are intentionally excluded.
`thesubtitledb_org` provides public multi-language movie and TV subtitles via IMDb title resolution and TheSubtitleDB's direct file API; no API key is required.
`napisy24_pl` provides Polish and selected English movie/TV subtitles through Napisy24's anonymous XML API and direct ZIP download endpoint.
`nyasub_cz` provides Czech anime movie/OVA and TV subtitles from NyaSub's public finished-translations catalog and direct WPDM subtitle links.
`subhd_tv` provides movie and TV subtitles through SubHD's public prepare-download flow.
`fansubs_ru` provides Russian anime movie and TV subtitles.
`legendei_net` provides Portuguese movie and TV subtitle archives, with language-specific posts when available.
`zoom_lk` provides Sinhala movie and TV season subtitle archives.
`justsubtitles_com` is movie-only and exposes server-rendered subtitle ZIPs through the public SubDL CDN.
`wizdom_xyz` provides Hebrew movie and TV subtitles through the public Wizdom
release API. Set `SUBDL_WIZDOM_TMDB_API_KEY` to an exact 32-character lowercase
hexadecimal TMDB v3 key to override the provider's upstream-published legacy
resolver key.
`miraianime_net` provides Arabic anime movie and TV subtitle archives.
`grupahatak_pl` is TV-only and provides Polish episode subtitle ZIPs.
`jimaku_cc` provides direct Japanese anime movie and TV subtitle files.

Network warning: `subsynchro_com`, `subs_sab_bz`, `animesub_info`, and
`fansubs_ru` currently depend on upstream workflows available only over plain
HTTP. The retained inactive `tvsubtitles_net` recovery path is also plain HTTP.
Searches and downloads through these paths are unencrypted, so avoid them on
untrusted networks. AnimeSub's short-lived cookie is restricted to the exact
provider route, but that does not encrypt the network hop.

## Quick Start

Build and test:

```bash
zig build
zig build test
zig build test-http # native Python 3 + isolated loopback integration gate
zig build test-pty  # native POSIX Python 3 + actual terminal navigation/shutdown
```

List providers:

```bash
zig build run -- --list-providers
```

Run the CLI:

```bash
zig build run -- --query "The Matrix"
```

Install the binary:

```bash
zig build install
./zig-out/bin/scrapers --providers subdl_com,subsource_net --query "Inception"
./zig-out/bin/scrapers -pnone -p subdl_com --query "Inception"
```

Build all supported targets into `zig-out/bin`:

```bash
zig build build-all-targets
zig build build-all-targets -Doptimize=fast -Dstrip=true
```

Targets produced by `build-all-targets`:

- `scrapers-x86_64-linux-gnu`
- `scrapers-aarch64-linux-gnu`
- `scrapers-x86_64-macos-none`
- `scrapers-aarch64-macos-none`
- `scrapers-x86_64-windows-gnu.exe`

## Optional Features

TUI and archive extraction are enabled by default. Browser automation is opt-in.

Run the TUI:

```bash
zig build run -- --tui
```

Extract downloaded archives with `--extract`:

```bash
zig build run -- --providers subsource_net --query "The Matrix" --extract
```

Enable browser automation support:

```bash
zig build -Denable-alldriver=true
```

On Linux, when a fresh Cloudflare session is needed, session handoff launches a
locally installed Chromium-family browser through a private, deadline-bounded
CDP pipe.
Auto-discovery covers Chrome, Chromium, Edge, Brave, and Vivaldi; the root CDP
product must report Chrome or Chromium 154 or newer. DNS is restricted to pinned
public addresses for the challenged host and Cloudflare's challenge host. A
process-wide unroutable proxy denies traffic by default, with direct bypasses
limited to those exact HTTPS hosts on port 443; ambient and corporate proxy
settings are intentionally ignored. Required subdomains, CDNs, WebSockets, and
other origins therefore fail closed. New browsing targets, downloads, and
local/private targets are denied by browser policy and Chromium controls.
External-protocol navigation is monitored. The private browser's session bus
points to an inaccessible socket, and private failing `xdg-email`/`xdg-open`
stubs shadow ambient helpers while the inherited `PATH` remains available to
browser launch wrappers and graphical-session utilities.
With `SUBDL_CF_HEADLESS` unset or set to `auto`, a non-empty `DISPLAY` or
`WAYLAND_DISPLAY` starts an automatic visible-browser pass; if it does not
acquire a session, every browser candidate is retried headlessly. Each automatic
visible attempt is capped at 60 seconds, and the final 60 seconds of the
four-minute global acquisition deadline are reserved for the headless pass.
Without a graphical-display variable, automatic mode is headless-only. Use
`SUBDL_CF_HEADLESS=0` (or `headed`) for a visible-only attempt with the full
remaining global deadline, and `SUBDL_CF_HEADLESS=1` (or `headless`) for a
headless-only attempt. Empty and unrecognized `SUBDL_CF_HEADLESS` values also
select automatic mode. Set `SUBDL_CHROMIUM_PATH` to an absolute browser path when
auto-discovery does not cover the installation. macOS and FreeBSD fail closed
until browser DNS can be cancelled at the deadline; Windows fails closed pending
secure native handle and DACL support. An authorized user may manually complete
a challenge only while a visible attempt remains open; unresolved challenges
fail explicitly. The feature contains no CAPTCHA solver and does not bypass
access controls.

The TUI stores bounded, framed JSON: each `*.json` state file begins with a
`subdl-tui-*-json-v1` magic line followed by one JSON value. Legacy
`*.oneserial` files are never overwritten or deleted. When only legacy state is
present, the TUI uses defaults and displays a nonfatal migration/reset notice.

## Build Flags

- `-Doptimize=debug|safe|fast|small`
- `-Dstrip=true|false`
- `-Dsingle-threaded=true|false`
- `-Domit-frame-pointer=true|false`
- `-Derror-tracing=true|false`
- `-Dpic=true|false`
- `-Dllvm=true|false`
- `-Denable-tui=true|false`
- `-Denable-alldriver=true|false`
- `-Denable-unarr=true|false`

Ordinary host build, run, and install steps default to `-Doptimize=fast`.
Tests default to `-Doptimize=debug` when no optimization mode is requested.
`--release=safe|fast|small` selects that mode for builds and tests, including
nested live convenience targets. An explicit `-Doptimize` takes precedence.
The executable and test targets reject `-Dsingle-threaded=true`: HTTP request
deadlines and terminal I/O require concurrency from Zig's threaded I/O backend.
Disabling the TUI does not remove the HTTP requirement. Library dependencies
still expose their modules; a custom embedding must supply an I/O backend that
supports every concurrent operation it uses.

`build-all-targets` defaults:

- `-Doptimize=fast`
- `-Dstrip=true`

LLVM code generation is enabled by default. If it was explicitly disabled and a
native GNU build hits host CRT `.sframe` relocation errors, restore
`-Dllvm=true`.

## Docs

- [DOCUMENTATION.md](./DOCUMENTATION.md)
- [VALIDATION.md](./VALIDATION.md)
- [CONTRIBUTIONS.md](./CONTRIBUTIONS.md)
- [SECURITY.md](./SECURITY.md)
- [LICENCE](./LICENCE)
- [COPYING](./COPYING)
- [THIRD_PARTY_NOTICES.md](./THIRD_PARTY_NOTICES.md)

`LICENCE` contains the GNU Lesser General Public License version 3 supplemental
terms. `COPYING` is included only as the verbatim GPLv3 companion text that
those terms incorporate and reference; it was fetched from the official FSF
source at <https://www.gnu.org/licenses/gpl-3.0.txt> and has SHA-256
`3972dc9744f6499f0f9b2dbf76696f2ae7ad8af9b23dde66d6af86c9dfb36986`.
Its presence does not apply GPLv3 to the project, state whether the project
chooses an “only” or “or later” LGPL version, or establish project copyright
terms. No choice should be inferred; a project owner must still clarify the
intended project-wide license before release.

Default install and `build-all-targets` copy the project texts, dependency
licenses and notices, and vendor provenance below `share/licenses/scrapers`
and `share/doc/scrapers`. This improves artifact metadata; it is not a
compliance determination. Because the default `-Denable-unarr=true` build
statically links LGPLv3 unarr code, those artifacts remain non-publishable
until the owner approves a compatible project license grant and the release
includes the required corresponding source and application material,
relinking instructions, and installation information where applicable. See
[THIRD_PARTY_NOTICES.md](./THIRD_PARTY_NOTICES.md) before packaging.

### Navigation and validation

In the TUI, Tab switches panes without rescanning the disk. F5 refreshes cached
files. With results focused, `[` and `]` navigate search pages; PgUp/PgDn move
within the current page. Up to 16 previous search pages are retained; refine the
query or use the CLI page selector for deeper navigation. Query-focused brackets remain ordinary input. The CLI
accepts positive `--search-page N` and `--subtitle-page N` selectors.

Archive detection uses payload signatures rather than names or URL suffixes, so
a plain subtitle mislabeled as an archive remains a subtitle. ZIP and stored
RAR4 extraction are bounded to 256 entries, 64 MiB per entry, and 128 MiB
aggregate. Downloaded archives are saved atomically before extraction. Their
contents are preflighted and staged before the extracted directory is
published; existing output paths are never overwritten. 7z, RAR5, and
compressed or otherwise unsupported RAR4 archives remain downloadable but
require an external extraction tool. Builds with `-Denable-unarr=false` also
save archives without extracting them. The CLI/TUI explicitly report this
state.

Filesystem publication assumes that the selected output directory and its parent
are not concurrently modified by an untrusted local process. No-follow opens,
exclusive atomic publication, randomized private staging directories, and
identity rechecks protect ordinary collisions and symlink replacement, but they
are not a security boundary against a process that can mutate or mount within
the output path. Do not use an output directory writable by untrusted users.
Administrator and mount-namespace attacks, and Windows DACL validation, are
outside this guarantee; see [SECURITY.md](./SECURITY.md).

HTTP responses negotiate only identity, gzip, and deflate. Gzip and deflate
container checksums are verified under encoded and decoded size limits. HTTP
zstd is neither advertised nor accepted because Zig 0.17's decoder has a fixed
window ceiling and does not verify content checksums. Provider XZ attachments
use a separate bounded, checksum-verifying decoder.

`zig build test` runs deterministic offline tests. `zig build test-http` is a
separate native-only integration gate requiring Python 3 and loopback sockets.
Network suites are opt-in. The fanout defaults to four concurrent providers and
a 60-second subprocess deadline; individual registry entries have longer defaults.
OpenSubtitles.com, SubSource, and AnimeKalesi share a conservative 5100-second
live-subprocess ceiling. It covers up to six complete recovery chains across all
enabled probes: each chain reserves three two-minute fetch budgets and two
four-minute browser acquisitions, followed by a one-minute runner margin. This
is a ceiling; ordinary runs normally reuse the session cache or fail earlier.
SubSource's extensive probe disables automatic browser recovery and does not add
a chain. The internal deadline for each browser acquisition remains four minutes.
`-Dlive-max-jobs=N` and positive `-Dlive-timeout-seconds=N` configure these limits.
An explicit deadline replaces the registry defaults.
Every selected provider gets its own subprocess deadline, including serialized
selections and the `test-live-single` compatibility target.
Live modes are disjoint to avoid multiplying upstream requests: `smoke` exercises
the application search/list/download path, `named` runs provider-local direct
probes, and `extensive` runs the deeper field-oriented probes for their supported
providers. `all` deliberately composes all three and is therefore more expensive.
Registry capability metadata currently marks all 53 providers as runnable in
`smoke`, 48 in `named`, and 10 in `extensive`. An active `named` selection runs
43 of 46 providers; `isubtitles.org`, `subsource.net`, and `sub-scene.com` have
no named probe. An inactive `named` selection runs five of seven providers;
`my-subs.co` and `tvsubtitles.net` have no named probe. Those five providers
instead have extensive probes. These figures describe harness capabilities, not
successful live outcomes. If every selected provider lacks the requested suite,
configuration fails before any provider starts. In a mixed selection, the runner
reports each unavailable suite as `NO_PROBE` and executes the supported entries;
the overall exit status reflects the started probes, so even an exit status of
zero does not turn `NO_PROBE` entries into passes or skips.
The `test-live-all` and `test-live-active` convenience sweeps use `smoke`; invoke
`test-live -Dlive=named|extensive|all -Dlive-providers=...` explicitly for the
other suites. A TV-only provider uses one series-validated application smoke,
while dual-capability providers retain distinct movie and series smokes.
The exact `active` selection always fans out so every active provider is visible in
the summary. Convenience live targets retain native feature, optimization, and
live-limit options, serialize their nested Zig build with `-j1`, and deliberately
ignore cross-target/CPU settings. They also override ambient provider-filter
variables so `test-live-all` and
`test-live-active` cannot silently narrow their documented provider sets.
Provider filters accept canonical IDs, dotted names, and unambiguous partial
names. Unknown or ambiguous tokens fail configuration. A live skip or upstream
failure is not proof of a working provider.

Network live-test execution requires a native Linux host, Bash 4.3 or newer,
GNU `timeout`, `flock`, `mkfifo`, and normal network access. The separate `test-http` gate
requires Python 3 and loopback sockets. Cross-target builds remain available
through `build-all-targets`.

Translation downloads preserve source text for missing or malformed translated
segments and explicitly warn when the result is incomplete. Unicode filenames
are preserved while Windows device-name aliases are made safe.
