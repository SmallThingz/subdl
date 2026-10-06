# SubDL Zig Scrapers

Subtitle scrapers in Zig with a shared provider API and a single `scrapers` binary.

![Zig](https://img.shields.io/badge/Zig-0.17.0-f7a41d)
![Providers](https://img.shields.io/badge/Active_Providers-46-2ea44f)
![Runtime](https://img.shields.io/badge/HTTP-std.http%20(Client)-0366d6)

## Overview

- 46 currently active providers behind one app layer: `providers_app`
- 53 provider implementations retained and covered by targeted live tests
- One binary: `scrapers`
- CLI mode by default
- TUI mode available with `--tui` in the default build
- Runtime HTTP implemented with Zig `std.http.Client`
- No runtime `curl` dependency

## Requirements

- Zig `0.17.0`
- Network access for provider queries and downloads

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
because their current user path is blocked by the Australian website-block page,
`moviesubtitlesrt_com` because its live search path currently returns a non-success
HTTP status, `greeksubtitles_com` because its live search endpoint currently stalls
and returns non-success responses, and `my_subs_co`, `podnapisi_net`, `subtis_io`, and
`animesubtitle_ir` because their required upstream hosts currently have no usable
DNS address. They remain covered by focused live tests so upstream recovery can
be detected without advertising a known-unusable provider in the CLI/TUI.

`gestdown_info` is TV-only. `yifysubtitles_ch` is movie-only.
`subtitles_ajatt_top` focuses on Japanese subtitles for anime TV and movies.
`greeksubs_net` provides Greek subtitles for movies and TV.
`sous_titres_eu` provides French subtitles for movies and TV.
`cc_edatribe_com` provides English anime movie and TV captions.
`subtitrari_noi_ro` provides Romanian movie and TV subtitle archives.
`subclub_eu` provides Estonian subtitles for movies and TV episodes via direct subtitle files.
`subs_ro` provides Romanian and English subtitles for movies and TV.
`subs4free_info` is movie-only and provides Greek and English subtitles through a session-bound archive download flow.
`tsukihime_org` provides anime movie and TV subtitles from TsukiHime native cached subtitle storage; AnimeTosho-mirrored entries are skipped because that redirected storage is not reachable from the live host.
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
`wizdom_xyz` provides Hebrew movie and TV subtitles through the public Wizdom release API.
`miraianime_net` provides Arabic anime movie and TV subtitle archives.
`grupahatak_pl` is TV-only and provides Polish episode subtitle ZIPs.
`jimaku_cc` provides direct Japanese anime movie and TV subtitle files.

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
./zig-out/bin/scrapers -pnone --query "Inception"
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

`build-all-targets` defaults:

- `-Doptimize=fast`
- `-Dstrip=true`

Use `-Dllvm=true` if the native GNU build hits host CRT `.sframe` relocation errors.

## Docs

- [DOCUMENTATION.md](./DOCUMENTATION.md)
- [ISSUES.md](./ISSUES.md)
- [CONTRIBUTIONS.md](./CONTRIBUTIONS.md)
- [SECURITY.md](./SECURITY.md)
- [LICENCE](./LICENCE)

### Navigation and validation

In the TUI, Tab switches panes without rescanning the disk. F5 refreshes cached
files. With results focused, `[` and `]` navigate search pages; PgUp/PgDn move
within the current page. Up to 16 previous search pages are retained; refine the
query or use the CLI page selector for deeper navigation. Query-focused brackets remain ordinary input. The CLI
accepts positive `--search-page N` and `--subtitle-page N` selectors.

ZIP extraction is bounded to 256 entries, 64 MiB per entry and 128 MiB aggregate.
Archives are staged and checked before publication, and existing output files
are never overwritten. 7z archives remain downloadable but require external
extraction; builds with `-Denable-unarr=false` also save archives without
extracting them. The CLI/TUI explicitly report this state.

`zig build test` runs deterministic offline tests. `zig build test-http` is a
separate native-only integration gate requiring Python 3 and loopback sockets.
Network suites are opt-in. The fanout defaults to four concurrent providers and
a 60-second subprocess deadline; individual registry entries have longer defaults.
`-Dlive-max-jobs=N` and positive `-Dlive-timeout-seconds=N` configure these limits.
An explicit deadline replaces the registry defaults.
Single/serial suite execution has one deadline for the entire subprocess.
The exact `active` selection always fans out so every active provider is visible in
the summary. Convenience live targets retain native feature, optimization, limit,
and job options while deliberately ignoring cross-target/CPU settings. They also
override ambient provider-filter variables so `test-live-all` and
`test-live-active` cannot silently narrow their documented provider sets.
Unknown provider filter tokens fail configuration. A live skip or upstream failure
is not proof of a working provider.

Live-test execution currently requires a native Linux host, Bash 4.3 or newer,
GNU `timeout`, Python 3 for `test-http`, and normal network access. Cross-target
builds remain available through `build-all-targets`.

Translation downloads preserve source text for missing or malformed translated
segments and explicitly warn when the result is incomplete. Unicode filenames
are preserved while Windows device-name aliases are made safe.
