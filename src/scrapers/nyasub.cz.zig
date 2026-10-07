const std = @import("std");
const common = @import("common.zig");

const Allocator = std.mem.Allocator;
const site = "https://nyasub.cz";
const catalog_url = site ++ "/hotove-preklady/";
const max_search_items = 24;
const max_subtitle_items = 80;

pub const MediaKind = common.MediaKind;

pub const SearchItem = struct {
    title: []const u8,
    release_label: []const u8,
    media_kind: MediaKind,
    season: ?u16,
    episode: ?u16,
    page_url: []const u8,
};

pub const SubtitleItem = common.SubtitleFile;

pub const SearchResponse = common.SearchResponse(SearchItem);

pub const SubtitlesResponse = common.TitledSubtitlesResponse(SubtitleItem);

const ParsedQuery = common.EpisodeQuery;
const parseQuery = common.parseEpisodeQuery;

const CatalogEntry = struct {
    title: []const u8,
    release_label: []const u8,
    page_url: []const u8,
    release_season: ?u16,
    release_index: usize,
};

pub const Scraper = struct {
    allocator: Allocator,
    client: *std.http.Client,

    pub fn init(allocator: Allocator, client: *std.http.Client) Scraper {
        return .{ .allocator = allocator, .client = client };
    }

    pub fn search(self: *Scraper, query: []const u8) !SearchResponse {
        var arena = std.heap.ArenaAllocator.init(self.allocator);
        errdefer arena.deinit();
        const a = arena.allocator();

        const parsed_query = parseQuery(query);
        if (parsed_query.title.len < 2) return .{ .arena = arena, .items = &.{} };
        const wanted = try common.normalizeTitle(a, parsed_query.title);
        if (wanted.len == 0) return .{ .arena = arena, .items = &.{} };

        const response = try common.fetchBytes(self.client, a, catalog_url, .{
            .accept = "text/html,application/xhtml+xml,*/*",
            .cache = true,
            .max_attempts = 2,
            .require_public_origin = true,
            .require_https = true,
            .require_same_origin = true,
        });
        const entries = try parseCatalog(a, response.body);
        const items = try buildSearchItems(a, entries, parsed_query, wanted);
        return common.finishResponse(SearchResponse, &arena, .{ .arena = arena, .items = items });
    }

    pub fn fetchSubtitlesBySearchItem(self: *Scraper, item: SearchItem) !SubtitlesResponse {
        var arena = std.heap.ArenaAllocator.init(self.allocator);
        errdefer arena.deinit();
        const a = arena.allocator();

        try validateProviderEndpoint(item.page_url, .details);
        const response = try common.fetchBytes(self.client, a, item.page_url, .{
            .accept = "text/html,application/xhtml+xml,*/*",
            .cache = false,
            .max_attempts = 2,
            .require_public_origin = true,
            .require_https = true,
            .require_same_origin = true,
        });
        const links = try parseDownloadLinks(a, response.body);

        var subtitles: std.ArrayListUnmanaged(SubtitleItem) = .empty;
        if (item.episode) |episode| {
            if (episode > 0 and episode <= links.len) {
                const idx: usize = @intCast(episode - 1);
                try appendSubtitle(a, &subtitles, item, links[idx], episode);
            }
        } else {
            for (links, 0..) |link, idx| {
                if (subtitles.items.len >= max_subtitle_items) break;
                try appendSubtitle(a, &subtitles, item, link, @intCast(idx + 1));
            }
        }

        return common.finishResponse(SubtitlesResponse, &arena, .{
            .arena = arena,
            .title = try a.dupe(u8, item.title),
            .subtitles = try subtitles.toOwnedSlice(a),
        });
    }
};

fn buildSearchItems(
    allocator: Allocator,
    entries: []const CatalogEntry,
    parsed_query: ParsedQuery,
    wanted: []const u8,
) ![]const SearchItem {
    var exact: std.ArrayListUnmanaged(SearchItem) = .empty;
    var partial: std.ArrayListUnmanaged(SearchItem) = .empty;

    for (entries) |entry| {
        if (exact.items.len >= max_search_items and partial.items.len >= max_search_items) break;
        const normalized = try common.normalizeTitle(allocator, entry.title);
        const is_exact = std.mem.eql(u8, normalized, wanted);
        const is_partial = common.normalizedTitlesRelated(normalized, wanted);
        if (!is_exact and !is_partial) continue;
        if ((is_exact and exact.items.len >= max_search_items) or
            (!is_exact and partial.items.len >= max_search_items)) continue;

        const media_kind: MediaKind = if (parsed_query.episode != null or entry.release_season != null) .tv else .movie;
        if (parsed_query.episode != null and !releaseMatchesSeason(entry, parsed_query.season orelse 1)) continue;

        const item: SearchItem = .{
            .title = try allocator.dupe(u8, entry.title),
            .release_label = try allocator.dupe(u8, entry.release_label),
            .media_kind = media_kind,
            .season = if (media_kind == .tv) parsed_query.season orelse entry.release_season else null,
            .episode = if (media_kind == .tv) parsed_query.episode else null,
            .page_url = try allocator.dupe(u8, entry.page_url),
        };
        if (is_exact)
            try exact.append(allocator, item)
        else
            try partial.append(allocator, item);
    }

    // If a requested season had no explicit N.série label, NyaSub's own addon
    // falls back to release position. Preserve that behavior only for exact
    // title matches and only when it yields one deterministic entry.
    if (parsed_query.episode != null and exact.items.len == 0) {
        const requested_season = parsed_query.season orelse 1;
        for (entries) |entry| {
            const normalized = try common.normalizeTitle(allocator, entry.title);
            if (!std.mem.eql(u8, normalized, wanted)) continue;
            if (entry.release_index + 1 != requested_season) continue;
            try exact.append(allocator, .{
                .title = try allocator.dupe(u8, entry.title),
                .release_label = try allocator.dupe(u8, entry.release_label),
                .media_kind = .tv,
                .season = requested_season,
                .episode = parsed_query.episode,
                .page_url = try allocator.dupe(u8, entry.page_url),
            });
            break;
        }
    }

    var items: std.ArrayListUnmanaged(SearchItem) = .empty;
    const exact_count = @min(exact.items.len, max_search_items);
    try items.appendSlice(allocator, exact.items[0..exact_count]);
    if (items.items.len < max_search_items) {
        const remaining = max_search_items - items.items.len;
        try items.appendSlice(allocator, partial.items[0..@min(remaining, partial.items.len)]);
    }
    return items.toOwnedSlice(allocator);
}

fn appendSubtitle(
    allocator: Allocator,
    out: *std.ArrayListUnmanaged(SubtitleItem),
    item: SearchItem,
    download_url: []const u8,
    episode: u16,
) !void {
    const safe_title = try slugify(allocator, item.title);
    const filename = if (item.media_kind == .tv)
        try std.fmt.allocPrint(allocator, "nyasub-{s}-s{d:0>2}e{d:0>2}.ass", .{ safe_title, item.season orelse 1, episode })
    else
        try std.fmt.allocPrint(allocator, "nyasub-{s}-{d}.ass", .{ safe_title, episode });
    try out.append(allocator, .{
        .language_code = "cs",
        .filename = filename,
        .download_url = try allocator.dupe(u8, download_url),
    });
}

fn parseCatalog(allocator: Allocator, body: []const u8) ![]const CatalogEntry {
    var out: std.ArrayListUnmanaged(CatalogEntry) = .empty;
    var cursor: usize = 0;

    while (findIgnoreCase(body[cursor..], "<h2")) |relative_h2| {
        const h2_start = cursor + relative_h2;
        const h2_open_end_rel = std.mem.indexOfScalar(u8, body[h2_start..], '>') orelse break;
        const h2_text_start = h2_start + h2_open_end_rel + 1;
        const h2_close_rel = findIgnoreCase(body[h2_text_start..], "</h2>") orelse break;
        const h2_close = h2_text_start + h2_close_rel;
        const title = try htmlFragmentText(allocator, body[h2_text_start..h2_close]);
        const section_start = h2_close + "</h2>".len;
        const next_h2_rel = findIgnoreCase(body[section_start..], "<h2");
        const section_end = if (next_h2_rel) |rel| section_start + rel else body.len;

        var release_index: usize = 0;
        var pos = section_start;
        while (pos < section_end) {
            const anchor_rel = findIgnoreCase(body[pos..section_end], "<a") orelse break;
            const anchor_start = pos + anchor_rel;
            const tag_end_rel = std.mem.indexOfScalar(u8, body[anchor_start..section_end], '>') orelse break;
            const tag_end = anchor_start + tag_end_rel;
            const tag = body[anchor_start .. tag_end + 1];
            const href_raw = attrValue(tag, "href") orelse {
                pos = tag_end + 1;
                continue;
            };
            if (!isNyaSubReleaseHref(href_raw)) {
                pos = tag_end + 1;
                continue;
            }
            const close_rel = findIgnoreCase(body[tag_end + 1 .. section_end], "</a>") orelse break;
            const text_end = tag_end + 1 + close_rel;
            const label = try htmlFragmentText(allocator, body[tag_end + 1 .. text_end]);
            if (title.len > 0 and label.len > 0) {
                const page_url = resolveProviderUrl(allocator, href_raw, .details) catch |err| switch (err) {
                    error.OutOfMemory => return error.OutOfMemory,
                    else => {
                        pos = text_end + "</a>".len;
                        continue;
                    },
                };
                try out.append(allocator, .{
                    .title = try allocator.dupe(u8, title),
                    .release_label = label,
                    .page_url = page_url,
                    .release_season = parseSeasonLabel(label),
                    .release_index = release_index,
                });
                release_index += 1;
            }
            pos = text_end + "</a>".len;
        }

        cursor = section_end;
    }

    return out.toOwnedSlice(allocator);
}

fn parseDownloadLinks(allocator: Allocator, body: []const u8) ![]const []const u8 {
    var out: std.ArrayListUnmanaged([]const u8) = .empty;
    var seen = std.StringHashMapUnmanaged(void).empty;
    var cursor: usize = 0;

    while (cursor < body.len) {
        const anchor_rel = findIgnoreCase(body[cursor..], "<a") orelse break;
        const anchor_start = cursor + anchor_rel;
        const tag_end_rel = std.mem.indexOfScalar(u8, body[anchor_start..], '>') orelse break;
        const tag_end = anchor_start + tag_end_rel;
        const tag = body[anchor_start .. tag_end + 1];
        const href_raw = attrValue(tag, "href") orelse {
            cursor = tag_end + 1;
            continue;
        };
        if (std.mem.indexOf(u8, href_raw, "?wpdmdl=") == null) {
            cursor = tag_end + 1;
            continue;
        }
        const close_rel = findIgnoreCase(body[tag_end + 1 ..], "</a>") orelse break;
        const text_end = tag_end + 1 + close_rel;
        cursor = text_end + "</a>".len;
        const label = try htmlFragmentText(allocator, body[tag_end + 1 .. text_end]);
        if (indexOfIgnoreCase(label, "Titulky") != null) {
            const decoded_href = try decodeBasicEntities(allocator, href_raw);
            defer allocator.free(decoded_href);
            const url = resolveProviderUrl(allocator, decoded_href, .download) catch |err| switch (err) {
                error.OutOfMemory => return error.OutOfMemory,
                else => continue,
            };
            if (!seen.contains(url)) {
                try seen.put(allocator, url, {});
                try out.append(allocator, url);
            }
        }
    }

    return out.toOwnedSlice(allocator);
}

const ProviderRoute = enum { details, download };

fn resolveProviderUrl(allocator: Allocator, href: []const u8, route: ProviderRoute) ![]const u8 {
    const resolved = try common.resolveUrl(allocator, site, href);
    errdefer allocator.free(resolved);
    try validateProviderEndpoint(resolved, route);
    return resolved;
}

fn validateProviderEndpoint(url: []const u8, route: ProviderRoute) !void {
    try common.validatePublicHttpUrl(url);
    if (!(try common.sameOrigin(site, url))) return error.UnsafeHttpTarget;

    const uri = std.Uri.parse(url) catch return error.UnsafeHttpTarget;
    if (uri.user != null or uri.password != null or uri.fragment != null) return error.UnsafeHttpTarget;
    const path = switch (uri.path) {
        .raw, .percent_encoded => |value| value,
    };
    const query = if (uri.query) |component| switch (component) {
        .raw, .percent_encoded => |value| value,
    } else null;

    switch (route) {
        .details => {
            if (query != null or !isSingleSlugRoute(path, "/hotove-preklady/", "/")) {
                return error.UnsafeHttpTarget;
            }
        },
        .download => {
            if (!isSingleSlugRoute(path, "/download/", "/") or
                query == null or !isDownloadQuery(query.?)) return error.UnsafeHttpTarget;
        },
    }
}

fn isSingleSlugRoute(path: []const u8, prefix: []const u8, suffix: []const u8) bool {
    if (!std.mem.startsWith(u8, path, prefix) or !std.mem.endsWith(u8, path, suffix) or
        path.len <= prefix.len + suffix.len) return false;
    return isSafeEncodedSegment(path[prefix.len .. path.len - suffix.len]);
}

fn isDownloadQuery(query: []const u8) bool {
    var download_id: ?[]const u8 = null;
    var master_key: ?[]const u8 = null;
    var fields = std.mem.splitScalar(u8, query, '&');
    while (fields.next()) |field| {
        const equals = std.mem.indexOfScalar(u8, field, '=') orelse return false;
        const key = field[0..equals];
        const value = field[equals + 1 ..];
        if (std.mem.eql(u8, key, "wpdmdl")) {
            if (download_id != null or !isCanonicalPositiveId(value)) return false;
            download_id = value;
        } else if (std.mem.eql(u8, key, "masterkey")) {
            if (master_key != null or !isSafeQueryValue(value)) return false;
            master_key = value;
        } else return false;
    }
    return download_id != null;
}

fn isCanonicalPositiveId(value: []const u8) bool {
    if (value.len == 0 or value.len > 19 or value[0] == '0') return false;
    for (value) |c| if (!std.ascii.isDigit(c)) return false;
    return true;
}

fn isSafeQueryValue(value: []const u8) bool {
    if (value.len == 0 or value.len > 256) return false;
    var index: usize = 0;
    while (index < value.len) {
        const c = value[index];
        if (std.ascii.isAlphanumeric(c) or c == '-' or c == '_' or c == '.' or c == '~' or c == '+') {
            index += 1;
            continue;
        }
        if (c != '%' or value.len - index < 3 or
            !std.ascii.isHex(value[index + 1]) or !std.ascii.isHex(value[index + 2])) return false;
        const decoded = std.fmt.parseInt(u8, value[index + 1 .. index + 3], 16) catch return false;
        if (decoded == '&' or decoded == '=' or decoded == '%' or decoded < 0x20 or decoded == 0x7f) return false;
        index += 3;
    }
    return true;
}

fn isSafeEncodedSegment(segment: []const u8) bool {
    if (segment.len == 0 or segment.len > 512 or
        std.mem.eql(u8, segment, ".") or std.mem.eql(u8, segment, "..")) return false;
    var decoded_len: usize = 0;
    var decoded_all_dots = true;
    var index: usize = 0;
    while (index < segment.len) {
        const c = segment[index];
        if (std.ascii.isAlphanumeric(c) or c == '-' or c == '_' or c == '.' or c == '~') {
            decoded_len += 1;
            if (c != '.') decoded_all_dots = false;
            index += 1;
            continue;
        }
        if (c != '%' or segment.len - index < 3 or
            !std.ascii.isHex(segment[index + 1]) or !std.ascii.isHex(segment[index + 2])) return false;
        const decoded = std.fmt.parseInt(u8, segment[index + 1 .. index + 3], 16) catch return false;
        if (decoded < 0x20 or decoded == 0x7f or decoded == '/' or decoded == '\\' or
            decoded == '?' or decoded == '#' or decoded == '%') return false;
        decoded_len += 1;
        if (decoded != '.') decoded_all_dots = false;
        index += 3;
    }
    return !(decoded_all_dots and decoded_len <= 2);
}

fn releaseMatchesSeason(entry: CatalogEntry, season: u16) bool {
    if (entry.release_season) |value| return value == season;
    return false;
}

fn parseSeasonLabel(label: []const u8) ?u16 {
    const trimmed = std.mem.trim(u8, label, " \t\r\n");
    var cursor: usize = 0;
    while (cursor < trimmed.len and std.ascii.isDigit(trimmed[cursor]) and cursor < 2) : (cursor += 1) {}
    if (cursor == 0) return null;
    const season = std.fmt.parseInt(u16, trimmed[0..cursor], 10) catch return null;
    while (cursor < trimmed.len and std.ascii.isWhitespace(trimmed[cursor])) : (cursor += 1) {}
    if (cursor >= trimmed.len or trimmed[cursor] != '.') return null;
    cursor += 1;
    while (cursor < trimmed.len and std.ascii.isWhitespace(trimmed[cursor])) : (cursor += 1) {}
    if (cursor >= trimmed.len or std.ascii.toLower(trimmed[cursor]) != 's') return null;
    return season;
}

fn isNyaSubReleaseHref(href: []const u8) bool {
    return std.mem.startsWith(u8, href, "https://nyasub.cz/hotove-preklady/") or
        std.mem.startsWith(u8, href, "/hotove-preklady/");
}

fn attrValue(tag: []const u8, name: []const u8) ?[]const u8 {
    var pos: usize = 0;
    while (pos + name.len < tag.len) {
        const rel = findIgnoreCase(tag[pos..], name) orelse return null;
        const start = pos + rel;
        if (start > 0) {
            const prev = tag[start - 1];
            if (std.ascii.isAlphanumeric(prev) or prev == '-' or prev == '_') {
                pos = start + name.len;
                continue;
            }
        }
        var cursor = start + name.len;
        while (cursor < tag.len and std.ascii.isWhitespace(tag[cursor])) : (cursor += 1) {}
        if (cursor >= tag.len or tag[cursor] != '=') {
            pos = cursor;
            continue;
        }
        cursor += 1;
        while (cursor < tag.len and std.ascii.isWhitespace(tag[cursor])) : (cursor += 1) {}
        if (cursor >= tag.len) return null;
        const quote = tag[cursor];
        if (quote == '"' or quote == '\'') {
            const value_start = cursor + 1;
            const end = std.mem.indexOfScalarPos(u8, tag, value_start, quote) orelse return null;
            return tag[value_start..end];
        }
        const value_start = cursor;
        while (cursor < tag.len and !std.ascii.isWhitespace(tag[cursor]) and tag[cursor] != '>') : (cursor += 1) {}
        return tag[value_start..cursor];
    }
    return null;
}

fn htmlFragmentText(allocator: Allocator, fragment: []const u8) ![]const u8 {
    var raw: std.ArrayListUnmanaged(u8) = .empty;
    errdefer raw.deinit(allocator);
    var in_tag = false;
    var pending_space = false;
    for (fragment) |c| {
        if (c == '<') {
            in_tag = true;
            pending_space = raw.items.len > 0;
            continue;
        }
        if (c == '>') {
            in_tag = false;
            continue;
        }
        if (in_tag) continue;
        if (std.ascii.isWhitespace(c)) {
            pending_space = raw.items.len > 0;
            continue;
        }
        if (pending_space and raw.items.len > 0 and raw.items[raw.items.len - 1] != ' ') try raw.append(allocator, ' ');
        pending_space = false;
        try raw.append(allocator, c);
    }
    const decoded = try decodeBasicEntities(allocator, raw.items);
    raw.deinit(allocator);
    return decoded;
}

fn decodeBasicEntities(allocator: Allocator, input: []const u8) ![]const u8 {
    var out: std.ArrayListUnmanaged(u8) = .empty;
    errdefer out.deinit(allocator);
    var i: usize = 0;
    while (i < input.len) {
        if (input[i] == '&') {
            const replacements = [_]struct { encoded: []const u8, decoded: []const u8 }{
                .{ .encoded = "&amp;", .decoded = "&" },
                .{ .encoded = "&quot;", .decoded = "\"" },
                .{ .encoded = "&#39;", .decoded = "'" },
                .{ .encoded = "&#039;", .decoded = "'" },
                .{ .encoded = "&apos;", .decoded = "'" },
                .{ .encoded = "&lt;", .decoded = "<" },
                .{ .encoded = "&gt;", .decoded = ">" },
                .{ .encoded = "&nbsp;", .decoded = " " },
            };
            var matched = false;
            for (replacements) |replacement| {
                if (!std.mem.startsWith(u8, input[i..], replacement.encoded)) continue;
                try out.appendSlice(allocator, replacement.decoded);
                i += replacement.encoded.len;
                matched = true;
                break;
            }
            if (matched) continue;

            if (std.mem.startsWith(u8, input[i..], "&#")) {
                const tail = input[i..];
                const semicolon = std.mem.indexOfScalar(u8, tail, ';') orelse {
                    try out.append(allocator, input[i]);
                    i += 1;
                    continue;
                };
                if (semicolon > 2 and semicolon <= 10) {
                    const numeric = tail[2..semicolon];
                    const hex = numeric.len > 1 and (numeric[0] == 'x' or numeric[0] == 'X');
                    const digits = if (hex) numeric[1..] else numeric;
                    const codepoint = std.fmt.parseInt(u21, digits, if (hex) 16 else 10) catch {
                        try out.append(allocator, input[i]);
                        i += 1;
                        continue;
                    };
                    var encoded: [4]u8 = undefined;
                    const encoded_len = std.unicode.utf8Encode(codepoint, &encoded) catch {
                        try out.append(allocator, input[i]);
                        i += 1;
                        continue;
                    };
                    try out.appendSlice(allocator, encoded[0..encoded_len]);
                    i += semicolon + 1;
                    continue;
                }
            }
        }
        try out.append(allocator, input[i]);
        i += 1;
    }
    return out.toOwnedSlice(allocator);
}

fn slugify(allocator: Allocator, input: []const u8) ![]u8 {
    var out: std.ArrayListUnmanaged(u8) = .empty;
    errdefer out.deinit(allocator);
    var pending_dash = false;
    for (input) |c| {
        if (std.ascii.isAlphanumeric(c)) {
            if (pending_dash and out.items.len > 0) try out.append(allocator, '-');
            pending_dash = false;
            try out.append(allocator, std.ascii.toLower(c));
        } else {
            pending_dash = out.items.len > 0;
        }
    }
    return out.toOwnedSlice(allocator);
}

const findIgnoreCase = std.ascii.findIgnoreCase;
const indexOfIgnoreCase = std.ascii.findIgnoreCase;

test "nyasub parses catalog titles and release links" {
    const fixture =
        \\<h2>Spy x Family</h2><p><a href="https://nyasub.cz/hotove-preklady/spy-x-family-1-serie/">1.série</a></p>
        \\<h2>Ryuu to Sobakasu no Hime</h2><p><a href="https://nyasub.cz/hotove-preklady/ryuu-to-sobakasu-no-hime/">Ryuu to Sobakasu no Hime</a></p>
    ;
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const entries = try parseCatalog(arena.allocator(), fixture);
    try std.testing.expectEqual(@as(usize, 2), entries.len);
    try std.testing.expectEqualStrings("Spy x Family", entries[0].title);
    try std.testing.expectEqual(@as(?u16, 1), entries[0].release_season);
    try std.testing.expectEqual(MediaKind.tv, if (entries[0].release_season != null) MediaKind.tv else MediaKind.movie);
}

test "nyasub partial cap does not hide a later exact catalog match" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const entries = try a.alloc(CatalogEntry, max_search_items * 4 + 1);
    for (entries[0 .. entries.len - 1], 0..) |*entry, index| {
        entry.* = .{
            .title = "Target extended",
            .release_label = "release",
            .page_url = site ++ "/hotove-preklady/target-extended/",
            .release_season = null,
            .release_index = index,
        };
    }
    entries[entries.len - 1] = .{
        .title = "Target",
        .release_label = "exact",
        .page_url = site ++ "/hotove-preklady/target/",
        .release_season = null,
        .release_index = entries.len - 1,
    };

    const items = try buildSearchItems(a, entries, parseQuery("Target"), "target");
    try std.testing.expectEqual(@as(usize, max_search_items), items.len);
    try std.testing.expectEqualStrings("Target", items[0].title);
}

test "nyasub parses episode links in page order" {
    const fixture =
        \\<a href="https://nyasub.cz/download/a/?wpdmdl=1&amp;masterkey=abc"><span>Titulky</span></a>
        \\<a href="https://nyasub.cz/download/b/?wpdmdl=2&amp;masterkey=def"><i></i><span>Titulky</span></a>
    ;
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const links = try parseDownloadLinks(arena.allocator(), fixture);
    try std.testing.expectEqual(@as(usize, 2), links.len);
    try std.testing.expect(std.mem.indexOf(u8, links[0], "wpdmdl=1&masterkey=abc") != null);
}

test "nyasub skips unsafe download candidates and keeps later valid links" {
    const fixture =
        \\<a href="http://127.0.0.1/?wpdmdl=1"><span>Titulky</span></a>
        \\<a href="https://nyasub.cz/download/a/?wpdmdl=2&amp;masterkey=ok"><span>Titulky</span></a>
    ;
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const links = try parseDownloadLinks(arena.allocator(), fixture);
    try std.testing.expectEqual(@as(usize, 1), links.len);
    try std.testing.expectEqualStrings("https://nyasub.cz/download/a/?wpdmdl=2&masterkey=ok", links[0]);
}

test "nyasub decodes numeric url entities" {
    const decoded = try decodeBasicEntities(std.testing.allocator, "?wpdmdl=1&#038;masterkey=x&#x26;y=2");
    defer std.testing.allocator.free(decoded);
    try std.testing.expectEqualStrings("?wpdmdl=1&masterkey=x&y=2", decoded);
}

test "nyasub parses SxxExx queries" {
    const parsed = parseQuery("Spy x Family S01E01");
    try std.testing.expectEqualStrings("Spy x Family", parsed.title);
    try std.testing.expectEqual(@as(?u16, 1), parsed.season);
    try std.testing.expectEqual(@as(?u16, 1), parsed.episode);
}

test "nyasub does not fetch its catalog for punctuation-only queries" {
    var client: std.http.Client = .{ .allocator = std.testing.allocator, .io = std.testing.io };
    defer client.deinit();
    var scraper = Scraper.init(std.testing.allocator, &client);
    var response = try scraper.search("---...");
    defer response.deinit();
    try std.testing.expectEqual(@as(usize, 0), response.items.len);
}

test "nyasub rejects unsafe provider links before fetch" {
    try validateProviderEndpoint(site ++ "/hotove-preklady/caf%C3%A9/", .details);
    try std.testing.expectError(error.UnsafeHttpTarget, resolveProviderUrl(std.testing.allocator, "http://127.0.0.1/?wpdmdl=1", .download));
    try std.testing.expectError(error.UnsafeHttpTarget, resolveProviderUrl(std.testing.allocator, "https://user:pass@nyasub.cz/?wpdmdl=1", .download));
    try std.testing.expectError(error.UnsafeHttpTarget, resolveProviderUrl(std.testing.allocator, "https://www.google.com/?wpdmdl=1", .download));
    try std.testing.expectError(error.UnsafeHttpTarget, validateProviderEndpoint(site ++ "/hotove-preklady/show/?next=/", .details));
    try std.testing.expectError(error.UnsafeHttpTarget, validateProviderEndpoint(site ++ "/hotove-preklady/a%252fb/", .details));
    try std.testing.expectError(error.UnsafeHttpTarget, validateProviderEndpoint(site ++ "/download/show/?wpdmdl=0", .download));
    try std.testing.expectError(error.UnsafeHttpTarget, validateProviderEndpoint(site ++ "/download/show/?wpdmdl=2&next=/", .download));
    try std.testing.expectError(error.UnsafeHttpTarget, validateProviderEndpoint(site ++ "/wp-admin/export/?wpdmdl=2", .download));
    try std.testing.expectError(error.UnsafeHttpTarget, validateProviderEndpoint(site ++ "/hotove-preklady/%2e%2E/", .details));
}

test "live nyasub tv search and subtitle listing" {
    if (!common.shouldRunLiveTests(std.testing.allocator)) return error.SkipZigTest;
    if (!common.providerMatchesLiveFilter(common.liveProviderFilter(), "nyasub.cz")) return error.SkipZigTest;

    var client: std.http.Client = .{ .allocator = std.testing.allocator, .io = std.testing.io };
    defer client.deinit();
    var scraper = Scraper.init(std.testing.allocator, &client);

    var search = try scraper.search("30-sai made Doutei dato Mahoutsukai ni Nareru Rashii S01E01");
    defer search.deinit();
    try std.testing.expect(search.items.len > 0);
    var subtitles = try scraper.fetchSubtitlesBySearchItem(search.items[0]);
    defer subtitles.deinit();
    try std.testing.expectEqual(@as(usize, 1), subtitles.subtitles.len);
    try std.testing.expect(std.mem.indexOf(u8, subtitles.subtitles[0].download_url, "?wpdmdl=") != null);
}
