# Documentation

## Overview

This project provides subtitle scraping and download workflows across multiple providers using:

- A shared app layer in `src/app/providers_app.zig`
- A CLI binary: `scrapers_cli`
- A TUI binary: `scrapers_tui`
- A library surface exported from `src/lib.zig`

The runtime HTTP path uses Zig `std.http.Client`.

## Requirements

- Zig `0.15.2+` (as defined in `build.zig.zon`)
- Network access for provider queries/downloads

## Build, Test, and Run

Build:

```bash
zig build
```

Install binaries:

```bash
zig build install
ls -l zig-out/bin/
```

Run all unit/integration tests configured in `build.zig`:

```bash
zig build test
```

Run CLI:

```bash
zig build run -- --list-providers
zig build run -- --provider subsource_net --query "The Matrix"
```

Run TUI:

```bash
zig build run-tui
```

## Provider IDs

The canonical provider IDs accepted by the app layer and CLI are:

- `subdl_com`
- `opensubtitles_com`
- `opensubtitles_org`
- `moviesubtitles_org`
- `moviesubtitlesrt_com`
- `podnapisi_net`
- `yifysubtitles_ch`
- `subtitlecat_com`
- `isubtitles_org`
- `my_subs_co`
- `subsource_net`
- `tvsubtitles_net`

Alias parsing is supported for selected providers (for example `subsource`, `isubtitles`, `subtitlecat`, `yify`).

## Pagination Support Matrix

Pagination is provider-specific in `providers_app`.

Search pagination supported:

- `opensubtitles_org`
- `moviesubtitlesrt_com`
- `podnapisi_net`
- `isubtitles_org`

Subtitles pagination supported:

- `opensubtitles_org`
- `isubtitles_org`

No pagination:

- `my_subs_co`
- `tvsubtitles_net`
- Others not listed in the pagination-supported sets above

For non-paginated providers, page `1` returns data and page `>1` returns empty page results.

## CLI Reference (`scrapers_cli`)

Usage:

```text
scrapers_cli --provider <name> --query <text> [--title-index N] [--subtitle-index N] [--out-dir DIR]
scrapers_cli --list-providers
```

Options:

- `--provider <name>`: provider ID (or accepted alias)
- `--query <text>`: search query
- `--title-index <N>`: selected title from search results (default `0`)
- `--subtitle-index <N>`: selected subtitle row (default: first downloadable row)
- `--out-dir <DIR>`: destination directory (default `downloads`)
- `--list-providers`: print all provider IDs
- `--help`, `-h`: print usage

Exit behavior:

- `0`: success
- `1`: runtime/provider failure (search/subtitle fetch/download)
- `2`: argument/validation failure (invalid provider, missing value, index out of range)

### CLI Usage Examples

List providers:

```bash
zig build run -- --list-providers
```

Basic query and download (defaults to first title and first downloadable subtitle):

```bash
zig build run -- --provider subsource_net --query "The Matrix"
```

Select explicit search and subtitle rows:

```bash
zig build run -- \
  --provider podnapisi_net \
  --query "Inception" \
  --title-index 1 \
  --subtitle-index 0
```

Download into a custom directory:

```bash
zig build run -- \
  --provider subdl_com \
  --query "Breaking Bad" \
  --out-dir /tmp/subtitles
```

Use the installed binary directly:

```bash
./zig-out/bin/scrapers_cli --provider isubtitles_org --query "Interstellar"
```

## TUI Reference (`scrapers_tui`)

Launch:

```bash
zig build run-tui
```

Flow:

1. Select provider
2. Enter query
3. Select title
4. Select subtitle row
5. Confirm download (unless confirm is toggled off)

Global keys:

- `Esc` or `q`: back/quit depending on screen
- `Ctrl+C`: cancel current fetch/download
- `F2`: toggle download confirmation screen
- `F3`: toggle theme

List/navigation keys:

- `j` / `k` or arrow keys: move selection
- `Enter`: select
- `/`: filter mode
- `s`: cycle subtitle sort mode (subtitle list)
- `[` and `]`: previous/next page only for providers with pagination support

`my_subs_co` and `tvsubtitles_net` do not expose pagination in the TUI.

## Library API

`src/lib.zig` exports the app layer and provider modules:

```zig
const scrapers = @import("scrapers");
```

Common app-layer entry points:

- `providers_app.providers()`
- `providers_app.parseProvider()`
- `providers_app.search()`
- `providers_app.searchPage()`
- `providers_app.fetchSubtitles()`
- `providers_app.fetchSubtitlesPage()`
- `providers_app.downloadSubtitle()`
- `providers_app.downloadSubtitleWithProgress()`

### Library Example: Search -> Subtitle Rows -> Download

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

    const selected = subtitles.items[0];
    if (selected.download_url == null) return;

    var result = try scrapers.providers_app.downloadSubtitle(
        allocator,
        &client,
        selected,
        "downloads",
    );
    defer result.deinit(allocator);

    std.debug.print("saved to: {s}\n", .{result.file_path});
}
```

### Library Example: Paginated Search

```zig
const std = @import("std");
const scrapers = @import("scrapers");

pub fn main() !void {
    var gpa_state = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa_state.deinit();
    const allocator = gpa_state.allocator();

    var client: std.http.Client = .{ .allocator = allocator };
    defer client.deinit();

    var page1 = try scrapers.providers_app.searchPage(
        allocator,
        &client,
        .opensubtitles_org,
        "The Office",
        1,
    );
    defer page1.deinit();

    if (page1.has_next_page) {
        var page2 = try scrapers.providers_app.searchPage(
            allocator,
            &client,
            .opensubtitles_org,
            "The Office",
            2,
        );
        defer page2.deinit();
        _ = page2;
    }
}
```

### Library Example: Download Progress Hook

```zig
const std = @import("std");
const scrapers = @import("scrapers");

fn onPhase(_: ?*anyopaque, phase: scrapers.providers_app.DownloadPhase) void {
    std.debug.print("phase: {s}\n", .{@tagName(phase)});
}

fn onUnits(_: ?*anyopaque, done: usize, total: usize) void {
    std.debug.print("progress: {d}/{d}\n", .{ done, total });
}

pub fn main() !void {
    var gpa_state = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa_state.deinit();
    const allocator = gpa_state.allocator();

    var client: std.http.Client = .{ .allocator = allocator };
    defer client.deinit();

    var search = try scrapers.providers_app.search(allocator, &client, .subsource_net, "The Matrix");
    defer search.deinit();
    if (search.items.len == 0) return;

    var subs = try scrapers.providers_app.fetchSubtitles(allocator, &client, search.items[0].ref);
    defer subs.deinit();
    if (subs.items.len == 0 or subs.items[0].download_url == null) return;

    const progress = scrapers.providers_app.DownloadProgress{
        .on_phase = onPhase,
        .on_units = onUnits,
    };

    var result = try scrapers.providers_app.downloadSubtitleWithProgress(
        allocator,
        &client,
        subs.items[0],
        "downloads",
        &progress,
    );
    defer result.deinit(allocator);
}
```

## Output Files and Extensions

- Downloaded filenames retain extensions where available.
- If needed, extension fallback is inferred from URL/content.
- For archive formats (`.zip`/`.rar`/other recognized archive patterns), the saved file is preserved as an archive artifact and surfaced via `DownloadResult.archive_path`.

## Environment Variables

Runtime/provider controls:

- `SUBSOURCE_CF_CLEARANCE`: optional Cloudflare clearance token for `subsource.net`
- `SUBSOURCE_USER_AGENT`: override User-Agent for `subsource.net` requests
- `SUBDL_CF_HEADLESS`: toggles headless browser behavior in Cloudflare handling paths

Live test controls:

- `SCRAPERS_LIVE_PROVIDER_FILTER`: provider filter for live test runs
- `SCRAPERS_LIVE_PROVIDERS`: alternative provider filter variable used by common test helpers
- `SCRAPERS_LIVE_INCLUDE_CAPTCHA`: include captcha/cloudflare providers in live runs
- `SCRAPERS_LIVE_BATCH`: enables batch mode behavior in live app tests

Debug flags:

- `SCRAPERS_DEBUG_TIMING`
- `SCRAPERS_SELECTOR_DEBUG`
- `SCRAPERS_DEBUG_ISUB`
- `SCRAPERS_DEBUG_OPENSUB_ORG_DOH`

## Live Testing

Run smoke live suite:

```bash
zig build test-live -Dlive=smoke -Dlive-providers=* -Dlive-include-captcha=false
```

Run extensive live suite for one provider:

```bash
zig build test-live-single -Dlive=extensive -Dlive-providers=subsource.net
```

Run all live providers (including captcha/cloudflare targets):

```bash
zig build test-live-all
```

Run parallel provider fan-out when supported:

```bash
zig build test-live -Dlive=all -Dlive-providers=* -Dlive-include-captcha=true -Dlive-parallel-on-all=true
```

## Troubleshooting

No results:

- Validate provider and query.
- Retry with another provider to isolate provider-side issues.
- For paginated providers, test page `1` first.

Cloudflare/session errors:

- Set `SUBSOURCE_CF_CLEARANCE` and `SUBSOURCE_USER_AGENT` when required by `subsource.net`.
- For captcha-heavy providers, use `-Dlive-include-captcha=true` only when you intend to test those paths.

Download has no direct URL:

- Some rows are listing entries without direct links.
- Choose another subtitle row where `download_url` is present.

## Project Structure

Key paths:

- `src/lib.zig`: public library exports
- `src/app/providers_app.zig`: unified provider app layer
- `src/cmd/cli.zig`: CLI entrypoint
- `src/cmd/tui.zig`: TUI entrypoint
- `src/scrapers/*.zig`: provider implementations
- `build.zig`: build graph, binaries, and test steps

