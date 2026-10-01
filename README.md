# SubDL Zig Scrapers

Subtitle scrapers in Zig with a shared provider API and a single `scrapers` binary.

![Zig](https://img.shields.io/badge/Zig-0.16.0--dev-f7a41d)
![Providers](https://img.shields.io/badge/Active_Providers-40-2ea44f)
![Runtime](https://img.shields.io/badge/HTTP-std.http%20(Client)-0366d6)

## Overview

- 40 currently active providers behind one app layer: `providers_app`
- 49 provider implementations retained and covered by targeted live tests
- One binary: `scrapers`
- CLI mode by default
- TUI mode available with `--tui` in the default build
- Runtime HTTP implemented with Zig `std.http.Client`
- No runtime `curl` dependency

## Requirements

- Zig `0.16.0-dev.2905+`
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
and returns non-success responses, `subhd_tv` because its search endpoint currently
returns HTTP 502, and `my_subs_co`, `podnapisi_net`, `subtis_io`, and
`animesubtitle_ir` because their required upstream hosts currently have no usable
DNS address. They remain covered by focused live tests so upstream recovery can
be detected without advertising a known-unusable provider in the CLI/TUI.

`gestdown_info` is TV-only. `yifysubtitles_ch` is movie-only.
`subtitles_ajatt_top` focuses on Japanese subtitles for anime TV and movies.
`greeksubs_net` provides Greek subtitles for movies and TV.
`sous_titres_eu` provides French subtitles for movies and TV.
`cc_edatribe_com` provides English anime movie and TV captions.
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
zig build build-all-targets -Doptimize=ReleaseFast -Dstrip=true
```

Targets produced by `build-all-targets`:

- `scrapers-x86_64-linux-gnu`
- `scrapers-aarch64-linux-gnu`
- `scrapers-x86_64-macos-none`
- `scrapers-aarch64-macos-none`
- `scrapers-x86_64-windows-gnu.exe`

## Optional Features

The default build is intentionally conservative because some upstream integrations are still moving on Zig `0.16-dev`.

Run the TUI:

```bash
zig build run -- --tui
```

Enable archive extraction for `--extract`:

```bash
zig build -Denable-unarr=true run -- --providers subsource_net --query "The Matrix" --extract
```

Enable browser automation support:

```bash
zig build -Denable-alldriver=true
```

Tracked upstream issues are documented in [ISSUES.md](./ISSUES.md).

## Build Flags

- `-Doptimize=Debug|ReleaseSafe|ReleaseFast|ReleaseSmall`
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

- `-Doptimize=ReleaseFast`
- `-Dstrip=true`

Use `-Dllvm=true` if the native GNU build hits host CRT `.sframe` relocation errors.

## Docs

- [DOCUMENTATION.md](./DOCUMENTATION.md)
- [ISSUES.md](./ISSUES.md)
- [CONTRIBUTIONS.md](./CONTRIBUTIONS.md)
- [SECURITY.md](./SECURITY.md)
- [LICENCE](./LICENCE)
