const std = @import("std");
const common = @import("common.zig");

const Allocator = std.mem.Allocator;
const api = "https://api.tsukihime.org/v1";
const storage = "https://storage.tsukihime.org";
const search_limit = 50;
const max_anime_matches = 4;
const max_search_items = 20;
const max_decoded_subtitle_bytes = 16 * 1024 * 1024;

pub const download_token_prefix = "tsukihime-xz:";

pub const MediaKind = enum {
    movie,
    tv,
};

pub const SearchItem = struct {
    title: []const u8,
    year: ?i64,
    media_kind: MediaKind,
    torrent_id: i64,
    season: ?u16,
    episode: ?u16,
    release: []const u8,
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
        if (parsed_query.title.len == 0) return .{ .arena = arena, .items = &.{} };

        const encoded = try common.encodeUriComponent(a, parsed_query.title);
        const search_url = try std.fmt.allocPrint(
            a,
            "{s}/search/torrents?q={s}&limit={d}",
            .{ api, encoded, search_limit },
        );
        const search_response = try common.fetchBytes(self.client, a, search_url, .{
            .accept = "application/json,*/*",
            .cache = false,
            .max_attempts = 2,
        });

        const root = try std.json.parseFromSliceLeaky(std.json.Value, a, search_response.body, .{});
        const root_obj = valueObject(root) orelse return error.InvalidFieldType;
        const results = valueArray(root_obj.get("results") orelse return error.MissingField) orelse
            return error.InvalidFieldType;

        const wanted = try normalizeTitle(a, parsed_query.title);
        var exact_ids: std.ArrayListUnmanaged(i64) = .empty;
        var partial_ids: std.ArrayListUnmanaged(i64) = .empty;
        var seen_ids = std.AutoHashMapUnmanaged(i64, void).empty;

        for (results.items) |value| {
            const obj = valueObject(value) orelse continue;
            if (!isCompletedNativeResult(obj)) continue;
            const anime = valueObject(obj.get("anime") orelse continue) orelse continue;
            const anime_id = objectInt(anime, "id") orelse continue;
            if (seen_ids.contains(anime_id)) continue;

            const title = objectString(anime, "title") orelse "";
            const english_title = objectString(anime, "english_title") orelse "";
            const normalized_title = try normalizeTitle(a, title);
            const normalized_english = try normalizeTitle(a, english_title);
            const exact_match = std.mem.eql(u8, normalized_title, wanted) or
                std.mem.eql(u8, normalized_english, wanted);
            const partial_match = containsEither(normalized_title, wanted) or
                containsEither(normalized_english, wanted);
            if (!exact_match and !partial_match) continue;

            try seen_ids.put(a, anime_id, {});
            if (exact_match)
                try exact_ids.append(a, anime_id)
            else
                try partial_ids.append(a, anime_id);
            if (exact_ids.items.len + partial_ids.items.len >= max_anime_matches) break;
        }

        var anime_ids: std.ArrayListUnmanaged(i64) = .empty;
        if (exact_ids.items.len > 0) {
            try anime_ids.appendSlice(a, exact_ids.items[0..@min(max_anime_matches, exact_ids.items.len)]);
        } else {
            try anime_ids.appendSlice(a, partial_ids.items[0..@min(max_anime_matches, partial_ids.items.len)]);
        }

        var items: std.ArrayListUnmanaged(SearchItem) = .empty;
        for (anime_ids.items) |anime_id| {
            const meta_url = try std.fmt.allocPrint(a, "{s}/animes/{d}?limit={d}", .{ api, anime_id, search_limit });
            const meta_response = try common.fetchBytes(self.client, a, meta_url, .{
                .accept = "application/json,*/*",
                .cache = false,
                .max_attempts = 2,
            });
            const meta_root = try std.json.parseFromSliceLeaky(std.json.Value, a, meta_response.body, .{});
            const meta_obj = valueObject(meta_root) orelse continue;
            const anime = valueObject(meta_obj.get("anime") orelse continue) orelse continue;
            const media_kind: MediaKind = if ((objectInt(anime, "is_movie") orelse 0) == 1) .movie else .tv;
            if (parsed_query.episode != null and media_kind != .tv) continue;

            const display_title = blk: {
                const english = objectString(anime, "english_title") orelse "";
                if (std.mem.trim(u8, english, " \t\r\n").len > 0) break :blk english;
                break :blk objectString(anime, "title") orelse parsed_query.title;
            };
            const year = objectInt(anime, "release_year");
            const anime_results = valueArray(meta_obj.get("results") orelse continue) orelse continue;

            for (anime_results.items) |torrent_value| {
                if (items.items.len >= max_search_items) break;
                const torrent = valueObject(torrent_value) orelse continue;
                if (!isCompletedNativeResult(torrent)) continue;
                if (!hasSubtitleLanguages(torrent)) continue;

                const episode_no_i64 = objectInt(torrent, "episode_no");
                const episode_no: ?u16 = if (episode_no_i64) |value|
                    std.math.cast(u16, value)
                else
                    null;
                if (parsed_query.episode) |wanted_episode| {
                    if (episode_no == null or episode_no.? != wanted_episode) continue;
                }

                const torrent_id = objectInt(torrent, "id") orelse continue;
                const release = objectString(torrent, "name") orelse continue;
                const page_url = try std.fmt.allocPrint(a, "{s}/torrents/{d}", .{ api, torrent_id });
                try items.append(a, .{
                    .title = try a.dupe(u8, display_title),
                    .year = year,
                    .media_kind = media_kind,
                    .torrent_id = torrent_id,
                    .season = if (media_kind == .tv) parsed_query.season else null,
                    .episode = if (media_kind == .tv) (parsed_query.episode orelse episode_no) else null,
                    .release = try a.dupe(u8, release),
                    .page_url = page_url,
                });
            }
        }

        return .{ .arena = arena, .items = try items.toOwnedSlice(a) };
    }

    pub fn fetchSubtitlesBySearchItem(self: *Scraper, item: SearchItem) !SubtitlesResponse {
        var arena = std.heap.ArenaAllocator.init(self.allocator);
        errdefer arena.deinit();
        const a = arena.allocator();

        const response = try common.fetchBytes(self.client, a, item.page_url, .{
            .accept = "application/json,*/*",
            .cache = false,
            .max_attempts = 2,
        });
        const root = try std.json.parseFromSliceLeaky(std.json.Value, a, response.body, .{});
        const root_obj = valueObject(root) orelse return error.InvalidFieldType;
        if (jsonTruthy(root_obj.get("animetosho"))) return error.ProviderAccessBlocked;

        const files = valueArray(root_obj.get("files") orelse return error.MissingField) orelse
            return error.InvalidFieldType;
        var subtitles: std.ArrayListUnmanaged(SubtitleItem) = .empty;
        var seen = std.AutoHashMapUnmanaged(i64, void).empty;

        for (files.items) |file_value| {
            const file_obj = valueObject(file_value) orelse continue;
            const attachments = valueArray(file_obj.get("attachments") orelse continue) orelse continue;
            for (attachments.items) |attachment_value| {
                const attachment = valueObject(attachment_value) orelse continue;
                if ((objectInt(attachment, "type") orelse -1) != 1) continue;
                const attachment_id = objectInt(attachment, "id") orelse continue;
                if (seen.contains(attachment_id)) continue;

                const info = valueObject(attachment.get("info") orelse continue) orelse continue;
                if ((objectInt(info, "cached") orelse 1) == 0) continue;
                if (jsonTruthy(info.get("forced"))) continue;
                const codec = objectString(info, "codec") orelse continue;
                const extension = supportedSubtitleCodec(codec) orelse continue;
                const track_name = objectString(info, "name") orelse "";
                if (looksSignsOnly(track_name)) continue;

                const raw_language = objectString(info, "lang") orelse "en";
                const language = common.normalizeLanguageCode(raw_language) orelse raw_language;
                try seen.put(a, attachment_id, {});
                try subtitles.append(a, .{
                    .language_code = try a.dupe(u8, language),
                    .filename = try std.fmt.allocPrint(
                        a,
                        "tsukihime-{d}-{d}.{s}",
                        .{ item.torrent_id, attachment_id, extension },
                    ),
                    .download_url = try makeDownloadToken(a, attachment_id, extension),
                });
            }
        }

        return .{
            .arena = arena,
            .title = try a.dupe(u8, item.title),
            .subtitles = try subtitles.toOwnedSlice(a),
        };
    }

    pub fn fetchDownloadByToken(self: *Scraper, allocator: Allocator, token: []const u8) !common.HttpResponse {
        const parsed = parseDownloadToken(token) orelse return error.InvalidDownloadUrl;
        const storage_url = try nativeStorageUrl(allocator, parsed.attachment_id);
        defer allocator.free(storage_url);

        const response = try common.fetchBytes(self.client, allocator, storage_url, .{
            .accept = "application/x-xz,application/octet-stream,*/*",
            .cache = false,
            .max_attempts = 2,
        });
        defer allocator.free(response.body);
        if (response.status != .ok) return error.UnexpectedHttpStatus;
        if (response.body.len < 6 or !std.mem.eql(u8, response.body[0..6], &.{ 0xfd, 0x37, 0x7a, 0x58, 0x5a, 0x00 })) {
            return error.UnexpectedResponseType;
        }
        const decoded = try decompressXz(allocator, response.body);
        if (decoded.len == 0) {
            allocator.free(decoded);
            return error.UnexpectedResponseType;
        }
        return .{ .status = .ok, .body = decoded };
    }
};

const DownloadToken = struct {
    attachment_id: i64,
    extension: []const u8,
};

pub fn makeDownloadToken(allocator: Allocator, attachment_id: i64, extension: []const u8) ![]u8 {
    return std.fmt.allocPrint(allocator, "{s}{d}|{s}", .{ download_token_prefix, attachment_id, extension });
}

pub fn parseDownloadToken(value: []const u8) ?DownloadToken {
    if (!std.mem.startsWith(u8, value, download_token_prefix)) return null;
    const payload = value[download_token_prefix.len..];
    const sep = std.mem.indexOfScalar(u8, payload, '|') orelse return null;
    if (sep == 0 or sep + 1 >= payload.len) return null;
    const attachment_id = std.fmt.parseInt(i64, payload[0..sep], 10) catch return null;
    if (attachment_id <= 0) return null;
    const extension = payload[sep + 1 ..];
    if (supportedSubtitleCodec(extension) == null) return null;
    return .{ .attachment_id = attachment_id, .extension = extension };
}

fn nativeStorageUrl(allocator: Allocator, attachment_id: i64) ![]u8 {
    if (attachment_id <= 0 or attachment_id > std.math.maxInt(u32)) return error.InvalidDownloadUrl;
    const value: u32 = @intCast(attachment_id);
    var hex: [8]u8 = undefined;
    const digits = "0123456789ABCDEF";
    for (0..8) |idx| {
        const shift: u5 = @intCast((7 - idx) * 4);
        hex[idx] = digits[@as(usize, @intCast((value >> shift) & 0x0f))];
    }
    return std.fmt.allocPrint(allocator, "{s}/attach/{s}/{d}.xz", .{ storage, &hex, attachment_id });
}

fn decompressXz(allocator: Allocator, compressed: []const u8) ![]u8 {
    var input: std.Io.Reader = .fixed(compressed);
    const scratch = try allocator.alloc(u8, 8192);
    var xz = std.compress.xz.Decompress.init(&input, allocator, scratch) catch |err| {
        allocator.free(scratch);
        return err;
    };
    defer xz.deinit();

    var output: std.ArrayList(u8) = .empty;
    errdefer output.deinit(allocator);
    var buffer: [8192]u8 = undefined;
    while (true) {
        const n = try xz.reader.readSliceShort(&buffer);
        if (n == 0) break;
        if (output.items.len + n > max_decoded_subtitle_bytes) return error.ResponseTooLarge;
        try output.appendSlice(allocator, buffer[0..n]);
    }
    return output.toOwnedSlice(allocator);
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

fn isCompletedNativeResult(obj: std.json.ObjectMap) bool {
    const state = objectString(obj, "state") orelse return false;
    if (!std.mem.eql(u8, state, "completed")) return false;
    if (jsonTruthy(obj.get("animetosho"))) return false;
    return (objectInt(obj, "is_adult") orelse 0) == 0;
}

fn hasSubtitleLanguages(obj: std.json.ObjectMap) bool {
    const langs = valueArray(obj.get("sublangs") orelse return false) orelse return false;
    return langs.items.len > 0;
}

fn supportedSubtitleCodec(codec: []const u8) ?[]const u8 {
    if (std.ascii.eqlIgnoreCase(codec, "ass")) return "ass";
    if (std.ascii.eqlIgnoreCase(codec, "srt")) return "srt";
    if (std.ascii.eqlIgnoreCase(codec, "ssa")) return "ssa";
    if (std.ascii.eqlIgnoreCase(codec, "sub")) return "sub";
    if (std.ascii.eqlIgnoreCase(codec, "vtt")) return "vtt";
    return null;
}

fn looksSignsOnly(name: []const u8) bool {
    return std.ascii.indexOfIgnoreCase(name, "sign") != null;
}

fn containsEither(a: []const u8, b: []const u8) bool {
    if (a.len == 0 or b.len == 0) return false;
    return std.mem.indexOf(u8, a, b) != null or std.mem.indexOf(u8, b, a) != null;
}

fn valueObject(value: std.json.Value) ?std.json.ObjectMap {
    return switch (value) {
        .object => |obj| obj,
        else => null,
    };
}

fn valueArray(value: std.json.Value) ?std.json.Array {
    return switch (value) {
        .array => |array| array,
        else => null,
    };
}

fn objectString(obj: std.json.ObjectMap, key: []const u8) ?[]const u8 {
    const value = obj.get(key) orelse return null;
    return switch (value) {
        .string => |text| text,
        else => null,
    };
}

fn objectInt(obj: std.json.ObjectMap, key: []const u8) ?i64 {
    const value = obj.get(key) orelse return null;
    return switch (value) {
        .integer => |number| number,
        .number_string => |number| std.fmt.parseInt(i64, number, 10) catch null,
        .float => |number| @intFromFloat(number),
        .string => |number| std.fmt.parseInt(i64, number, 10) catch null,
        else => null,
    };
}

fn jsonTruthy(value: ?std.json.Value) bool {
    const actual = value orelse return false;
    return switch (actual) {
        .bool => |flag| flag,
        .integer => |number| number != 0,
        .string => |text| std.ascii.eqlIgnoreCase(text, "true") or std.mem.eql(u8, text, "1"),
        else => false,
    };
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

test "tsukihime parses episode query" {
    const parsed = parseQuery("Death Note S01E01");
    try std.testing.expectEqualStrings("Death Note", parsed.title);
    try std.testing.expectEqual(@as(?u16, 1), parsed.season);
    try std.testing.expectEqual(@as(?u16, 1), parsed.episode);
}

test "tsukihime download token and native storage path" {
    const token = try makeDownloadToken(std.testing.allocator, 12765, "ass");
    defer std.testing.allocator.free(token);
    const parsed = parseDownloadToken(token).?;
    try std.testing.expectEqual(@as(i64, 12765), parsed.attachment_id);
    try std.testing.expectEqualStrings("ass", parsed.extension);
    const url = try nativeStorageUrl(std.testing.allocator, parsed.attachment_id);
    defer std.testing.allocator.free(url);
    try std.testing.expectEqualStrings(
        "https://storage.tsukihime.org/attach/000031DD/12765.xz",
        url,
    );
}

test "live tsukihime movie and episode downloads" {
    if (!common.shouldRunLiveTests(std.testing.allocator)) return error.SkipZigTest;
    if (!common.providerMatchesLiveFilter(common.liveProviderFilter(), "tsukihime.org")) return error.SkipZigTest;

    var client: std.http.Client = .{ .allocator = std.testing.allocator, .io = std.testing.io };
    defer client.deinit();
    var scraper = Scraper.init(std.testing.allocator, &client);

    var movie_search = try scraper.search("Akira");
    defer movie_search.deinit();
    try std.testing.expect(movie_search.items.len > 0);
    try std.testing.expect(movie_search.items[0].media_kind == .movie);
    var movie_subtitles = try scraper.fetchSubtitlesBySearchItem(movie_search.items[0]);
    defer movie_subtitles.deinit();
    try std.testing.expect(movie_subtitles.subtitles.len > 0);
    const movie_download = try scraper.fetchDownloadByToken(std.testing.allocator, movie_subtitles.subtitles[0].download_url);
    defer std.testing.allocator.free(movie_download.body);
    try std.testing.expect(movie_download.body.len > 100);

    var episode_search = try scraper.search("Death Note S01E01");
    defer episode_search.deinit();
    try std.testing.expect(episode_search.items.len > 0);
    try std.testing.expect(episode_search.items[0].media_kind == .tv);
    try std.testing.expectEqual(@as(?u16, 1), episode_search.items[0].episode);
    var episode_subtitles = try scraper.fetchSubtitlesBySearchItem(episode_search.items[0]);
    defer episode_subtitles.deinit();
    try std.testing.expect(episode_subtitles.subtitles.len > 0);
    const episode_download = try scraper.fetchDownloadByToken(std.testing.allocator, episode_subtitles.subtitles[0].download_url);
    defer std.testing.allocator.free(episode_download.body);
    try std.testing.expect(episode_download.body.len > 100);
}
