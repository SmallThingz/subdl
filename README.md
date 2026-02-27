# SubDL Zig Scrapers

Subtitle scrapers in Zig with a shared provider API, a CLI, and a Vaxis TUI.

![Zig](https://img.shields.io/badge/Zig-0.15.2%2B-f7a41d)
![Providers](https://img.shields.io/badge/Providers-12-2ea44f)
![Runtime](https://img.shields.io/badge/HTTP-std.http%20(Client)-0366d6)

## What This Project Provides

- 12 provider integrations behind one unified app layer (`providers_app`).
- Two binaries:
  - `scrapers_cli` for scripted/non-interactive use.
  - `scrapers_tui` for interactive search, browse, and download.
- Library API exported from `src/lib.zig`.
- Runtime networking through Zig `std.http.Client` (no `curl` dependency in runtime flows).

## Providers

| Provider id | Site |
|---|---|
| `subdl_com` | `subdl.com` |
| `opensubtitles_com` | `opensubtitles.com` |
| `opensubtitles_org` | `opensubtitles.org` |
| `moviesubtitles_org` | `moviesubtitles.org` |
| `moviesubtitlesrt_com` | `moviesubtitlesrt.com` |
| `podnapisi_net` | `podnapisi.net` |
| `yifysubtitles_ch` | `yifysubtitles.ch` |
| `subtitlecat_com` | `subtitlecat.com` |
| `isubtitles_org` | `isubtitles.org` |
| `my_subs_co` | `my-subs.co` |
| `subsource_net` | `subsource.net` |
| `tvsubtitles_net` | `tvsubtitles.net` |

## Quick Start

```bash
zig build
zig build test
```

List providers:

```bash
zig build run -- --list-providers
```

Run CLI:

```bash
zig build run -- --provider subsource_net --query "The Matrix"
zig build run -- --provider subsource_net --query "The Matrix" --extract
```

Run TUI:

```bash
zig build run-tui
```

Install binaries:

```bash
zig build install
```

Build cross-target CLI binaries into `zig-out/bin`:

```bash
zig build build-all-targets
zig build build-all-targets -Doptimize=ReleaseFast -Dstrip=true
```

Tunable build flags:

- `-Doptimize=Debug|ReleaseSafe|ReleaseFast|ReleaseSmall`
- `-Dstrip=true|false`
- `-Dsingle-threaded=auto|on|off`
- `-Domit-frame-pointer=auto|on|off`
- `-Derror-tracing=auto|on|off`
- `-Dpic=auto|on|off`

`build-all-targets` uses sane defaults when flags are omitted:
- `-Doptimize` defaults to `ReleaseFast` for that step
- `-Dstrip` defaults to `true` for that step

## Docs

- [DOCUMENTATION.md](./DOCUMENTATION.md)
- [CONTRIBUTIONS.md](./CONTRIBUTIONS.md)
- [SECURITY.md](./SECURITY.md)
- [LICENCE](./LICENCE)
