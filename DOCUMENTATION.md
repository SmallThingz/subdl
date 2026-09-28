# Documentation

## Overview

This project provides subtitle search, subtitle listing, and subtitle download flows across multiple subtitle sites through one Zig API.

Primary entry points:

- Binary: `scrapers`
- Library: `src/lib.zig`
- App layer: `src/app/providers_app.zig`

Default behavior:

- CLI is enabled by default
- TUI is enabled by default and can be disabled with `-Denable-tui=false`
- Archive extraction is compiled out by default
- Browser automation support is compiled out by default

Those features are opt-in because some upstream projects are not fully settled on the current Zig dev toolchain. See [ISSUES.md](./ISSUES.md).

## Requirements

- Zig `0.16.0-dev.2905+`
- Network access for normal provider use

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
zig build build-all-targets -Doptimize=ReleaseFast -Dstrip=true
```

Outputs:

- `scrapers-x86_64-linux-gnu`
- `scrapers-aarch64-linux-gnu`
- `scrapers-x86_64-macos-none`
- `scrapers-aarch64-macos-none`
- `scrapers-x86_64-windows-gnu.exe`

## Optional Build Flags

General:

- `-Doptimize=Debug|ReleaseSafe|ReleaseFast|ReleaseSmall`
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

- `build-all-targets` defaults to `-Doptimize=ReleaseFast`
- `build-all-targets` defaults to `-Dstrip=true`
- `-Dllvm=true` works around native GNU host CRT `.sframe` relocation failures seen with Zig self-hosted codegen/linking
- default host builds keep archive extraction and browser automation off unless you opt in

## Provider IDs

Supported canonical provider IDs:

- `subdl_com`
- `opensubtitles_com`
- `yifysubtitles_ch`
- `subtitlecat_com`
- `isubtitles_org`
- `my_subs_co`
- `subsource_net`
- `sub_scene_com`
- `gestdown_info`
- `greek_subtitles_com`
- `subsunacs_net`

The repository also retains inactive implementations for
`opensubtitles_org`, `moviesubtitles_org`, `moviesubtitlesrt_com`,
`podnapisi_net`, and `tvsubtitles_net`. Targeted live tests still cover
those modules, but the CLI/TUI registry does not expose them while their
current upstream/network path cannot complete a search.

`gestdown_info` is TV-only. `yifysubtitles_ch` is movie-only.

The parser also accepts dotted or hyphenated site forms such as `subsource.net`.

## CLI Reference

Usage:

```text
scrapers --query <text> [--providers a,b] [-p provider] [--title-index N] [--subtitle-index N] [--out-dir DIR] [--extract]
scrapers --list-providers
scrapers --tui
```

Options:

- `--providers <list>`: comma-separated provider IDs or unique prefixes; defaults to all providers
- `--providers none`, `--providers=none`, `-p none`, `-p=none`, and `-pnone`: start with no providers selected
- `-p <provider>`: repeatable provider selector; values may also be comma-separated
- `--provider <name>`: compatibility alias for selecting one provider
- `--query <text>`: search query
- `--title-index <N>`: selected search result, default `0`
- `--subtitle-index <N>`: selected subtitle row, default first downloadable row
- `--out-dir <DIR>`: download destination, default `downloads`
- `--extract`: extract archives after download
- `--list-providers`: print available providers
- `--help`, `-h`: print help
- `--tui`: launch the TUI instead of the CLI

Important:

- `--extract` requires a build with `-Denable-unarr=true`

Examples:

```bash
zig build run -- --query "The Matrix"
zig build run -- --providers subdl_com,subsource_net --query "Inception" --title-index 1 --subtitle-index 0
zig build run -- -p subdl --query "Breaking Bad" --out-dir .tmp/subtitles
zig build run -- -pnone --query "The Matrix"
zig build -Denable-unarr=true run -- --providers subsource --query "The Matrix" --extract
./zig-out/bin/scrapers --providers isubtitles_org --query "Interstellar"
```

## TUI Reference

The TUI is built around the same provider app layer as the CLI and is enabled by default.

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
- `my_subs_co` does not expose pagination in the TUI
- `[` and `]` only navigate pages for providers that actually support pagination

## Pagination Behavior

Search pagination in the active provider registry:

- `isubtitles_org`

The retained inactive implementations `opensubtitles_org`,
`moviesubtitlesrt_com`, and `podnapisi_net` also implement paginated search.

Subtitles pagination in the active provider registry:

- `isubtitles_org`

The retained inactive `opensubtitles_org` implementation also implements
subtitle pagination.

No pagination:

- `my_subs_co`
- providers not listed above

For non-paginated providers:

- page `1` returns normal data
- page `>1` returns an empty page result

## Library API

Import:

```zig
const scrapers = @import("scrapers");
```

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

## Environment Variables

Runtime and provider controls:

- `SUBSOURCE_CF_CLEARANCE`
- `SUBSOURCE_USER_AGENT`
- `SUBDL_CF_HEADLESS`

Live test controls:

- `SCRAPERS_LIVE_PROVIDER_FILTER`
- `SCRAPERS_LIVE_PROVIDERS`
- `SCRAPERS_LIVE_INCLUDE_CAPTCHA`
- `SCRAPERS_LIVE_BATCH`

Debug flags:

- `SCRAPERS_DEBUG_TIMING`
- `SCRAPERS_SELECTOR_DEBUG`
- `SCRAPERS_DEBUG_ISUB`
- `SCRAPERS_DEBUG_OPENSUB_ORG_DOH`

## Live Testing

Smoke suite:

```bash
zig build test-live -Dlive=smoke -Dlive-providers=* -Dlive-include-captcha=false
```

Extensive suite for one provider:

```bash
zig build test-live-single -Dlive=extensive -Dlive-providers=subsource.net
```

All live providers:

```bash
zig build test-live-all
```

Parallel fan-out mode:

```bash
zig build test-live -Dlive=all -Dlive-providers=* -Dlive-include-captcha=true -Dlive-parallel-on-all=true
```

## Upstream Dependencies

Current upstream selections:

- `libvaxis`: `main`
- `htmlparser`: `main` from renamed repo `SmallThingz/htmlparser`
- `alldriver`: `main`
- `unarr`: `main`

If any of those upstreams cause integration issues on current Zig, they should be recorded in [ISSUES.md](./ISSUES.md).

## Project Structure

- `src/lib.zig`: public library exports
- `src/app/providers_app.zig`: unified provider API
- `src/cmd/main.zig`: single-binary entrypoint
- `src/cmd/cli.zig`: CLI flow
- `src/cmd/tui_backend.zig`: TUI feature-gated wrapper
- `src/scrapers/*.zig`: provider implementations
- `src/deps/*_compat.zig`: upstream compatibility wrappers
- `build.zig`: build graph, test steps, target builds
