const std = @import("std");
const common = @import("common.zig");

const Allocator = std.mem.Allocator;
const site = "https://nyasub.cz";
const catalog_url = site ++ "/hotove-preklady/";
const max_search_items = 24;
const max_subtitle_items = 80;

pub const MediaKind = enum {
    movie,
    tv,
};

pub const SearchItem = struct {
    title: []const u8,
    release_label: []const u8,
    media_kind: MediaKind,
    season: ?u16,
    episode: ?u16,
    page_url: []const u8,
};

pub const SubtitleItem = struct {
    language_code: []const u8,
    filename: []const u8,
    download_url: []const u8,
};

pub const SearchResponse = struct {
    arena: std.heap.ArenaAllocator,
    items: []const SearchItem,

    pub fn deinit(self: *SearchResponse) void {
        self.arena.deinit();
        self.* = undefined;
    }
};

pub const SubtitlesResponse = struct {
    arena: std.heap.ArenaAllocator,
    title: []const u8,
    subtitles: []const SubtitleItem,

    pub fn deinit(self: *SubtitlesResponse) void {
        self.arena.deinit();
        self.* = undefined;
    }
};

const ParsedQuery = struct {
    title: []const u8,
    season: ?u16,
    episode: ?u16,
};

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

    pub fn deinit(_: *Scraper) void {}

    pub fn search(self: *Scraper, query: []const u8) !SearchResponse {
        var arena = std.heap.ArenaAllocator.init(self.allocator);
        errdefer arena.deinit();
        const a = arena.allocator();

        const parsed_query = parseQuery(query);
        if (parsed_query.title.len < 2) return .{ .arena = arena, .items = &.{} };

        const response = try common.fetchBytes(self.client, a, catalog_url, .{
            .accept = "text/html,application/xhtml+xml,*/*",
            .cache = true,
            .max_attempts = 2,
        });
        const entries = try parseCatalog(a, response.body);
        const wanted = try normalizeTitle(a, parsed_query.title);

        var exact: std.ArrayListUnmanaged(SearchItem) = .empty;
        var partial: std.ArrayListUnmanaged(SearchItem) = .empty;

        for (entries) |entry| {
            if (exact.items.len + partial.items.len >= max_search_items * 4) break;
            const normalized = try normalizeTitle(a, entry.title);
            const is_exact = std.mem.eql(u8, normalized, wanted);
            const is_partial = std.mem.indexOf(u8, normalized, wanted) != null or std.mem.indexOf(u8, wanted, normalized) != null;
            if (!is_exact and !is_partial) continue;

            const media_kind: MediaKind = if (parsed_query.episode != null or entry.release_season != null) .tv else .movie;
            if (parsed_query.episode != null and !releaseMatchesSeason(entry, parsed_query.season orelse 1)) continue;

            const item: SearchItem = .{
                .title = try a.dupe(u8, entry.title),
                .release_label = try a.dupe(u8, entry.release_label),
                .media_kind = media_kind,
                .season = if (media_kind == .tv) parsed_query.season orelse entry.release_season else null,
                .episode = if (media_kind == .tv) parsed_query.episode else null,
                .page_url = try a.dupe(u8, entry.page_url),
            };
            if (is_exact)
                try exact.append(a, item)
            else
                try partial.append(a, item);
        }

        // If a requested season had no explicit N.série label, NyaSub's own
        // addon falls back to release position. Preserve that behavior only for
        // exact title matches and only when it yields one deterministic entry.
        if (parsed_query.episode != null and exact.items.len == 0) {
            const requested_season = parsed_query.season orelse 1;
            for (entries) |entry| {
                const normalized = try normalizeTitle(a, entry.title);
                if (!std.mem.eql(u8, normalized, wanted)) continue;
                if (entry.release_index + 1 != requested_season) continue;
                try exact.append(a, .{
                    .title = try a.dupe(u8, entry.title),
                    .release_label = try a.dupe(u8, entry.release_label),
                    .media_kind = .tv,
                    .season = requested_season,
                    .episode = parsed_query.episode,
                    .page_url = try a.dupe(u8, entry.page_url),
                });
                break;
            }
        }

        var items: std.ArrayListUnmanaged(SearchItem) = .empty;
        const exact_count = @min(exact.items.len, max_search_items);
        try items.appendSlice(a, exact.items[0..exact_count]);
        if (items.items.len < max_search_items) {
            const remaining = max_search_items - items.items.len;
            try items.appendSlice(a, partial.items[0..@min(remaining, partial.items.len)]);
        }

        return .{ .arena = arena, .items = try items.toOwnedSlice(a) };
    }

    pub fn fetchSubtitlesBySearchItem(self: *Scraper, item: SearchItem) !SubtitlesResponse {
        var arena = std.heap.ArenaAllocator.init(self.allocator);
        errdefer arena.deinit();
        const a = arena.allocator();

        const response = try common.fetchBytes(self.client, a, item.page_url, .{
            .accept = "text/html,application/xhtml+xml,*/*",
            .cache = false,
            .max_attempts = 2,
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

        return .{
            .arena = arena,
            .title = try a.dupe(u8, item.title),
            .subtitles = try subtitles.toOwnedSlice(a),
        };
    }
};

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
                const page_url = try common.resolveUrl(allocator, site, href_raw);
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
        const label = try htmlFragmentText(allocator, body[tag_end + 1 .. text_end]);
        if (indexOfIgnoreCase(label, "Titulky") != null) {
            const decoded_href = try decodeBasicEntities(allocator, href_raw);
            const url = try common.resolveUrl(allocator, site, decoded_href);
            if (!seen.contains(url)) {
                try seen.put(allocator, url, {});
                try out.append(allocator, url);
            }
        }
        cursor = text_end + "</a>".len;
    }

    return out.toOwnedSlice(allocator);
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

fn parseQuery(input: []const u8) ParsedQuery {
    const trimmed = std.mem.trim(u8, input, " \t\r\n");
    var i: usize = 0;
    while (i < trimmed.len) : (i += 1) {
        if (std.ascii.toLower(trimmed[i]) != 's') continue;
        var cursor = i + 1;
        const season_start = cursor;
        while (cursor < trimmed.len and std.ascii.isDigit(trimmed[cursor]) and cursor - season_start < 2) : (cursor += 1) {}
        if (cursor == season_start or cursor >= trimmed.len or std.ascii.toLower(trimmed[cursor]) != 'e') continue;
        const season = std.fmt.parseInt(u16, trimmed[season_start..cursor], 10) catch continue;
        cursor += 1;
        const episode_start = cursor;
        while (cursor < trimmed.len and std.ascii.isDigit(trimmed[cursor]) and cursor - episode_start < 3) : (cursor += 1) {}
        if (cursor == episode_start) continue;
        const episode = std.fmt.parseInt(u16, trimmed[episode_start..cursor], 10) catch continue;
        const title = std.mem.trim(u8, trimmed[0..i], " \t\r\n-._");
        if (title.len == 0) continue;
        return .{ .title = title, .season = season, .episode = episode };
    }
    return .{ .title = trimmed, .season = null, .episode = null };
}

fn normalizeTitle(allocator: Allocator, input: []const u8) ![]u8 {
    var out: std.ArrayListUnmanaged(u8) = .empty;
    errdefer out.deinit(allocator);
    var pending_space = false;
    for (input) |c| {
        if (std.ascii.isAlphanumeric(c)) {
            if (pending_space and out.items.len > 0) try out.append(allocator, ' ');
            pending_space = false;
            try out.append(allocator, std.ascii.toLower(c));
        } else {
            pending_space = out.items.len > 0;
        }
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

fn findIgnoreCase(haystack: []const u8, needle: []const u8) ?usize {
    if (needle.len == 0) return 0;
    if (needle.len > haystack.len) return null;
    var i: usize = 0;
    while (i + needle.len <= haystack.len) : (i += 1) {
        if (std.ascii.eqlIgnoreCase(haystack[i .. i + needle.len], needle)) return i;
    }
    return null;
}

fn indexOfIgnoreCase(haystack: []const u8, needle: []const u8) ?usize {
    return findIgnoreCase(haystack, needle);
}

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
