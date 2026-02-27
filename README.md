# 🚀 SubDL Zig Scrapers

High-throughput subtitle scrapers in Zig with a shared provider API, a CLI, and a Vaxis TUI.

![Zig](https://img.shields.io/badge/Zig-0.15.2%2B-f7a41d)
![Providers](https://img.shields.io/badge/Providers-12-2ea44f)
![Runtime](https://img.shields.io/badge/HTTP-std.http%20(Client)-0366d6)

## ⚡ Features

- 🌐 **12 provider integrations** with one unified app layer (`providers_app`).
- 🧭 **Two user-facing binaries**:
  - `scrapers_cli` for scripted/non-interactive usage.
  - `scrapers_tui` for interactive search/browse/download flow.
- 🧩 **Library-friendly API** exposed via `src/lib.zig` for embedding in other Zig apps.
- 🔄 **Built-in live test matrix** with provider filters and captcha/cloudflare toggles.
- 🧱 **Pure Zig HTTP path** (`std.http.Client`) in runtime download/scrape flow.
- 🧪 **Broad test coverage** across parser/unit/app-path/live suites.

## 📦 Providers

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

## 🚀 Quick Start

```bash
zig build
zig build test
```

List available providers:

```bash
zig build run -- --list-providers
```

Run a CLI fetch/download:

```bash
zig build run -- --provider subsource_net --query "The Matrix"
```

Run TUI:

```bash
zig build run-tui
```

Install binaries:

```bash
zig build install
# binaries in zig-out/bin/
# - scrapers_cli
# - scrapers_tui
```

## 🧪 Live Testing

Run regular tests:

```bash
zig build test
```

Run live tests (smoke):

```bash
zig build test-live -Dlive=smoke -Dlive-providers=* -Dlive-include-captcha=false
```

Run a single filtered live suite:

```bash
zig build test-live-single -Dlive=extensive -Dlive-providers=subsource.net
```

Run all providers live (including captcha/cloudflare targets):

```bash
zig build test-live-all
```

## 🧩 Library Usage

`src/lib.zig` re-exports provider modules and the user-facing app layer.

```zig
const std = @import("std");
const scrapers = @import("scrapers");

pub fn main() !void {
    var gpa_state = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa_state.deinit();
    const allocator = gpa_state.allocator();

    var client: std.http.Client = .{ .allocator = allocator };
    defer client.deinit();

    var search = try scrapers.providers_app.search(
        allocator,
        &client,
        .subsource_net,
        "The Matrix",
    );
    defer search.deinit();

    if (search.items.len == 0) return;

    var subtitles = try scrapers.providers_app.fetchSubtitles(
        allocator,
        &client,
        search.items[0].ref,
    );
    defer subtitles.deinit();

    if (subtitles.items.len == 0) return;

    const chosen = subtitles.items[0];
    if (chosen.download_url == null) return;

    var result = try scrapers.providers_app.downloadSubtitle(
        allocator,
        &client,
        chosen,
        "downloads",
    );
    defer result.deinit(allocator);
}
```

## 🔧 Configuration Notes

Environment variables used in common flows:

- `SUBSOURCE_CF_CLEARANCE`: optional `cf_clearance` for `subsource.net`.
- `SUBSOURCE_USER_AGENT`: optional user-agent override for `subsource.net`.
- `SUBDL_CF_HEADLESS`: controls CF browser automation headless behavior.
- `SCRAPERS_LIVE_PROVIDER_FILTER`: provider filter for live runs.
- `SCRAPERS_LIVE_INCLUDE_CAPTCHA`: include captcha/cloudflare providers in live runs.

## 📌 Runtime Notes

- Downloaded filenames now retain file extensions when possible (URL/content-based fallback).
- Archive files are currently kept as downloaded artifacts; auto-extraction is not performed in the app download path.
- Some providers can rate-limit aggressively; live tests should be treated as network-dependent checks.

