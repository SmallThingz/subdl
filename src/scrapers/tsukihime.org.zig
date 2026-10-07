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

pub const MediaKind = common.MediaKind;

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

pub const SubtitleItem = common.SubtitleFile;

pub const SearchResponse = common.SearchResponse(SearchItem);

pub const SubtitlesResponse = common.TitledSubtitlesResponse(SubtitleItem);

const ParsedQuery = common.EpisodeQuery;
const parseQuery = common.parseEpisodeQuery;

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
        if (parsed_query.title.len == 0) return .{ .arena = arena, .items = &.{} };
        try validateSeasonSelection(parsed_query.season);
        const wanted = try common.normalizeTitle(a, parsed_query.title);
        if (wanted.len == 0) return .{ .arena = arena, .items = &.{} };

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
            .require_public_origin = true,
            .require_https = true,
            .require_same_origin = true,
        });

        const root = try std.json.parseFromSliceLeaky(std.json.Value, a, search_response.body, .{});
        const root_obj = common.jsonObject(root) orelse return error.InvalidFieldType;
        const results = common.jsonArray(root_obj.get("results") orelse return error.MissingField) orelse
            return error.InvalidFieldType;

        const anime_ids = try selectAnimeIds(a, results.items, wanted);

        var items: std.ArrayListUnmanaged(SearchItem) = .empty;
        for (anime_ids) |anime_id| {
            if (items.items.len >= max_search_items) break;
            const meta_url = try std.fmt.allocPrint(a, "{s}/animes/{d}?limit={d}", .{ api, anime_id, search_limit });
            const meta_response = try common.fetchBytes(self.client, a, meta_url, .{
                .accept = "application/json,*/*",
                .cache = false,
                .max_attempts = 2,
                .require_public_origin = true,
                .require_https = true,
                .require_same_origin = true,
            });
            const meta_root = try std.json.parseFromSliceLeaky(std.json.Value, a, meta_response.body, .{});
            const meta_obj = common.jsonObject(meta_root) orelse continue;
            const anime = common.jsonObject(meta_obj.get("anime") orelse continue) orelse continue;
            const media_kind: MediaKind = if ((objectInt(anime, "is_movie") orelse 0) == 1) .movie else .tv;
            if (parsed_query.episode != null and media_kind != .tv) continue;

            const display_title = blk: {
                const english = common.jsonString(anime, "english_title") orelse "";
                if (std.mem.trim(u8, english, " \t\r\n").len > 0) break :blk english;
                break :blk common.jsonString(anime, "title") orelse parsed_query.title;
            };
            const year = objectInt(anime, "release_year");
            const anime_results = common.jsonArray(meta_obj.get("results") orelse continue) orelse continue;

            for (anime_results.items) |torrent_value| {
                if (items.items.len >= max_search_items) break;
                const torrent = common.jsonObject(torrent_value) orelse continue;
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
                if (torrent_id <= 0) continue;
                const release = common.jsonString(torrent, "name") orelse continue;
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

        return common.finishResponse(SearchResponse, &arena, .{ .arena = arena, .items = try items.toOwnedSlice(a) });
    }

    pub fn fetchSubtitlesBySearchItem(self: *Scraper, item: SearchItem) !SubtitlesResponse {
        try validateSeasonSelection(item.season);
        var arena = std.heap.ArenaAllocator.init(self.allocator);
        errdefer arena.deinit();
        const a = arena.allocator();

        try validateTorrentApiUrl(item.page_url, item.torrent_id);

        const response = try common.fetchBytes(self.client, a, item.page_url, .{
            .accept = "application/json,*/*",
            .cache = false,
            .max_attempts = 2,
            .require_public_origin = true,
            .require_https = true,
            .require_same_origin = true,
        });
        const root = try std.json.parseFromSliceLeaky(std.json.Value, a, response.body, .{});
        const root_obj = common.jsonObject(root) orelse return error.InvalidFieldType;
        if (jsonTruthy(root_obj.get("animetosho"))) return error.ProviderAccessBlocked;

        const files = common.jsonArray(root_obj.get("files") orelse return error.MissingField) orelse
            return error.InvalidFieldType;
        var subtitles: std.ArrayListUnmanaged(SubtitleItem) = .empty;
        var seen = std.AutoHashMapUnmanaged(i64, void).empty;

        for (files.items) |file_value| {
            const file_obj = common.jsonObject(file_value) orelse continue;
            const attachments = common.jsonArray(file_obj.get("attachments") orelse continue) orelse continue;
            for (attachments.items) |attachment_value| {
                const attachment = common.jsonObject(attachment_value) orelse continue;
                if ((objectInt(attachment, "type") orelse -1) != 1) continue;
                const attachment_id = objectInt(attachment, "id") orelse continue;
                if (attachment_id <= 0 or attachment_id > std.math.maxInt(u32) or seen.contains(attachment_id)) continue;

                const info = common.jsonObject(attachment.get("info") orelse continue) orelse continue;
                if ((objectInt(info, "cached") orelse 1) == 0) continue;
                if (jsonTruthy(info.get("forced"))) continue;
                const codec = common.jsonString(info, "codec") orelse continue;
                const extension = supportedSubtitleCodec(codec) orelse continue;
                const track_name = common.jsonString(info, "name") orelse "";
                if (looksSignsOnly(track_name)) continue;

                const language = attachmentLanguage(info);
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

        return common.finishResponse(SubtitlesResponse, &arena, .{
            .arena = arena,
            .title = try a.dupe(u8, item.title),
            .subtitles = try subtitles.toOwnedSlice(a),
        });
    }

    pub fn fetchDownloadByToken(self: *Scraper, allocator: Allocator, token: []const u8) !common.HttpResponse {
        const parsed = parseDownloadToken(token) orelse return error.InvalidDownloadUrl;
        const storage_url = try nativeStorageUrl(allocator, parsed.attachment_id);
        defer allocator.free(storage_url);

        const response = try common.fetchBytes(self.client, allocator, storage_url, .{
            .accept = "application/x-xz,application/octet-stream,*/*",
            .cache = false,
            .max_attempts = 2,
            .require_public_origin = true,
            .require_https = true,
            .require_same_origin = true,
        });
        defer allocator.free(response.body);
        if (response.status != .ok) return error.UnexpectedHttpStatus;
        if (response.body.len < 6 or !std.mem.eql(u8, response.body[0..6], &.{ 0xfd, 0x37, 0x7a, 0x58, 0x5a, 0x00 })) {
            return error.UnexpectedResponseType;
        }
        const decoded = try common.decompressXz(allocator, response.body, max_decoded_subtitle_bytes);
        if (decoded.len == 0) {
            allocator.free(decoded);
            return error.UnexpectedResponseType;
        }
        return .{ .status = .ok, .body = decoded };
    }
};

fn selectAnimeIds(allocator: Allocator, results: []const std.json.Value, wanted: []const u8) ![]const i64 {
    var exact_ids: std.ArrayListUnmanaged(i64) = .empty;
    var partial_ids: std.ArrayListUnmanaged(i64) = .empty;

    for (results) |value| {
        const obj = common.jsonObject(value) orelse continue;
        if (!isCompletedNativeResult(obj)) continue;
        const anime = common.jsonObject(obj.get("anime") orelse continue) orelse continue;
        const anime_id = objectInt(anime, "id") orelse continue;
        if (anime_id <= 0) continue;

        const title = common.jsonString(anime, "title") orelse "";
        const english_title = common.jsonString(anime, "english_title") orelse "";
        const normalized_title = try common.normalizeTitle(allocator, title);
        const normalized_english = try common.normalizeTitle(allocator, english_title);
        const exact_match = std.mem.eql(u8, normalized_title, wanted) or
            std.mem.eql(u8, normalized_english, wanted);
        const partial_match = containsEither(normalized_title, wanted) or
            containsEither(normalized_english, wanted);
        if (!exact_match and !partial_match) continue;

        if (exact_match) {
            if (animeIdIndex(exact_ids.items, anime_id) != null) continue;
            if (animeIdIndex(partial_ids.items, anime_id)) |index| {
                _ = partial_ids.orderedRemove(index);
            }
            try exact_ids.append(allocator, anime_id);
            if (exact_ids.items.len >= max_anime_matches) break;
        } else {
            if (animeIdIndex(exact_ids.items, anime_id) != null or
                animeIdIndex(partial_ids.items, anime_id) != null or
                partial_ids.items.len >= max_anime_matches) continue;
            try partial_ids.append(allocator, anime_id);
        }
    }

    var anime_ids: std.ArrayListUnmanaged(i64) = .empty;
    if (exact_ids.items.len > 0) {
        try anime_ids.appendSlice(allocator, exact_ids.items[0..@min(max_anime_matches, exact_ids.items.len)]);
    } else {
        try anime_ids.appendSlice(allocator, partial_ids.items[0..@min(max_anime_matches, partial_ids.items.len)]);
    }
    return anime_ids.toOwnedSlice(allocator);
}

fn animeIdIndex(ids: []const i64, wanted: i64) ?usize {
    for (ids, 0..) |id, index| {
        if (id == wanted) return index;
    }
    return null;
}

const DownloadToken = struct {
    attachment_id: i64,
    extension: []const u8,
};

fn validateSeasonSelection(season: ?u16) !void {
    // The qualified provider path uses unseasoned episode numbering as season 1.
    if (season) |value| if (value != 1) return error.UnsupportedSeasonSelection;
}

fn validateTorrentApiUrl(url: []const u8, expected_torrent_id: i64) !void {
    try common.validatePublicHttpUrl(url);
    if (!(try common.sameOrigin(api, url))) return error.UnsafeHttpTarget;
    if (expected_torrent_id <= 0) return error.InvalidDownloadUrl;

    const uri = std.Uri.parse(url) catch return error.InvalidDownloadUrl;
    if (uri.user != null or uri.password != null or uri.query != null or uri.fragment != null)
        return error.InvalidDownloadUrl;
    const path = switch (uri.path) {
        .raw, .percent_encoded => |value| value,
    };
    const prefix = "/v1/torrents/";
    if (!std.mem.startsWith(u8, path, prefix)) return error.InvalidDownloadUrl;
    const id_text = path[prefix.len..];
    if (id_text.len == 0 or id_text.len > 19 or id_text[0] == '0')
        return error.InvalidDownloadUrl;
    for (id_text) |byte| if (!std.ascii.isDigit(byte)) return error.InvalidDownloadUrl;
    const torrent_id = std.fmt.parseInt(i64, id_text, 10) catch
        return error.InvalidDownloadUrl;
    if (torrent_id != expected_torrent_id) return error.InvalidDownloadUrl;
}

pub fn makeDownloadToken(allocator: Allocator, attachment_id: i64, extension: []const u8) ![]u8 {
    if (attachment_id <= 0 or attachment_id > std.math.maxInt(u32)) return error.InvalidDownloadUrl;
    const canonical_extension = supportedSubtitleCodec(extension) orelse return error.InvalidDownloadUrl;
    return std.fmt.allocPrint(allocator, "{s}{d}|{s}", .{ download_token_prefix, attachment_id, canonical_extension });
}

pub fn parseDownloadToken(value: []const u8) ?DownloadToken {
    if (!std.mem.startsWith(u8, value, download_token_prefix)) return null;
    const payload = value[download_token_prefix.len..];
    const sep = std.mem.indexOfScalar(u8, payload, '|') orelse return null;
    if (sep == 0 or sep + 1 >= payload.len) return null;
    const id_text = payload[0..sep];
    if (id_text[0] == '0') return null;
    for (id_text) |c| if (!std.ascii.isDigit(c)) return null;
    const attachment_id = std.fmt.parseInt(i64, id_text, 10) catch return null;
    if (attachment_id <= 0 or attachment_id > std.math.maxInt(u32)) return null;
    const extension = payload[sep + 1 ..];
    const canonical_extension = supportedSubtitleCodec(extension) orelse return null;
    if (!std.mem.eql(u8, extension, canonical_extension)) return null;
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

fn isCompletedNativeResult(obj: std.json.ObjectMap) bool {
    const state = common.jsonString(obj, "state") orelse return false;
    if (!std.mem.eql(u8, state, "completed")) return false;
    if (jsonTruthy(obj.get("animetosho"))) return false;
    return (objectInt(obj, "is_adult") orelse 0) == 0;
}

fn hasSubtitleLanguages(obj: std.json.ObjectMap) bool {
    const langs = common.jsonArray(obj.get("sublangs") orelse return false) orelse return false;
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

fn attachmentLanguage(info: std.json.ObjectMap) []const u8 {
    const raw = common.jsonString(info, "lang") orelse return "und";
    const trimmed = std.mem.trim(u8, raw, " \t\r\n");
    if (trimmed.len == 0) return "und";
    return common.normalizeLanguageCode(trimmed) orelse trimmed;
}

fn looksSignsOnly(name: []const u8) bool {
    return std.ascii.findIgnoreCase(name, "sign") != null;
}

fn containsEither(a: []const u8, b: []const u8) bool {
    return common.normalizedTitlesRelated(a, b);
}

fn objectInt(obj: std.json.ObjectMap, key: []const u8) ?i64 {
    const value = obj.get(key) orelse return null;
    return switch (value) {
        .integer => |number| number,
        .number_string => |number| std.fmt.parseInt(i64, number, 10) catch null,
        .float => |number| common.jsonInt(.{ .float = number }),
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

test "tsukihime parses episode query" {
    const parsed = parseQuery("Death Note S01E01");
    try std.testing.expectEqualStrings("Death Note", parsed.title);
    try std.testing.expectEqual(@as(?u16, 1), parsed.season);
    try std.testing.expectEqual(@as(?u16, 1), parsed.episode);
}

test "tsukihime search relevance respects normalized token boundaries" {
    try std.testing.expect(!containsEither("preacher", "reacher"));
    try std.testing.expect(containsEither("jack reacher", "reacher"));
    try std.testing.expect(containsEither("reacher", "reacher the series"));
    try std.testing.expect(!containsEither("the matrix", "reacher"));
}

test "tsukihime invalid exact anime ids do not consume the candidate cap" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const root = try std.json.parseFromSliceLeaky(
        std.json.Value,
        allocator,
        \\{"results":[
        \\  {"state":"completed","anime":{"id":0,"title":"Target"}},
        \\  {"state":"completed","anime":{"id":-1,"title":"Target"}},
        \\  {"state":"completed","anime":{"id":-2,"title":"Target"}},
        \\  {"state":"completed","anime":{"id":-3,"title":"Target"}},
        \\  {"state":"completed","anime":{"id":42,"title":"Target"}}
        \\]}
    ,
        .{},
    );
    const root_obj = common.jsonObject(root).?;
    const results = common.jsonArray(root_obj.get("results").?).?;
    const ids = try selectAnimeIds(allocator, results.items, "target");
    try std.testing.expectEqual(@as(usize, 1), ids.len);
    try std.testing.expectEqual(@as(i64, 42), ids[0]);
}

test "tsukihime later exact anime match displaces capped partial matches" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const root = try std.json.parseFromSliceLeaky(
        std.json.Value,
        allocator,
        \\{"results":[
        \\  {"state":"completed","anime":{"id":42,"title":"Target One"}},
        \\  {"state":"completed","anime":{"id":2,"title":"Target Two"}},
        \\  {"state":"completed","anime":{"id":3,"title":"Target Three"}},
        \\  {"state":"completed","anime":{"id":4,"title":"Target Four"}},
        \\  {"state":"completed","anime":{"id":42,"title":"Target"}}
        \\]}
    ,
        .{},
    );
    const root_obj = common.jsonObject(root).?;
    const results = common.jsonArray(root_obj.get("results").?).?;
    const ids = try selectAnimeIds(allocator, results.items, "target");
    try std.testing.expectEqualSlices(i64, &.{42}, ids);
}

test "tsukihime rejects unverified season claims before acquisition" {
    try validateSeasonSelection(null);
    try validateSeasonSelection(1);
    var client: std.http.Client = .{ .allocator = std.testing.allocator, .io = std.testing.io };
    defer client.deinit();
    var scraper = Scraper.init(std.testing.allocator, &client);
    try std.testing.expectError(error.UnsupportedSeasonSelection, scraper.search("Death Note S02E01"));
    try std.testing.expectError(error.UnsupportedSeasonSelection, scraper.search("Death Note S00E01"));
    try std.testing.expectError(error.UnsupportedSeasonSelection, scraper.fetchSubtitlesBySearchItem(.{
        .title = "Death Note",
        .year = null,
        .media_kind = .tv,
        .torrent_id = 1,
        .season = 2,
        .episode = 1,
        .release = "fixture",
        .page_url = "https://fixture.invalid",
    }));
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

    const canonical = try makeDownloadToken(std.testing.allocator, 1, "ASS");
    defer std.testing.allocator.free(canonical);
    try std.testing.expectEqualStrings("ass", parseDownloadToken(canonical).?.extension);
    for ([_]i64{ -1, 0, @as(i64, std.math.maxInt(u32)) + 1 }) |invalid_id| {
        try std.testing.expectError(
            error.InvalidDownloadUrl,
            makeDownloadToken(std.testing.allocator, invalid_id, "ass"),
        );
    }
    try std.testing.expectError(
        error.InvalidDownloadUrl,
        makeDownloadToken(std.testing.allocator, 1, "exe"),
    );
    try std.testing.expect(parseDownloadToken(download_token_prefix ++ "01|ass") == null);
    try std.testing.expect(parseDownloadToken(download_token_prefix ++ "1|ASS") == null);
}

test "tsukihime does not mislabel missing attachment languages as English" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const root = try std.json.parseFromSliceLeaky(
        std.json.Value,
        arena.allocator(),
        "{\"missing\":{},\"blank\":{\"lang\":\"  \"},\"english\":{\"lang\":\"en\"}}",
        .{},
    );
    const obj = common.jsonObject(root).?;
    try std.testing.expectEqualStrings("und", attachmentLanguage(common.jsonObject(obj.get("missing").?).?));
    try std.testing.expectEqualStrings("und", attachmentLanguage(common.jsonObject(obj.get("blank").?).?));
    try std.testing.expectEqualStrings("en", attachmentLanguage(common.jsonObject(obj.get("english").?).?));
}

test "tsukihime rejects unsafe api urls before fetch" {
    for ([_][]const u8{
        "http://127.0.0.1/torrents/1",
        "https://user@api.tsukihime.org/v1/torrents/1",
        "https://api.tsukihime.org.attacker.example/v1/torrents/1",
    }) |url| {
        try std.testing.expectError(error.UnsafeHttpTarget, validateTorrentApiUrl(url, 1));
    }
}

test "tsukihime accepts only the selected canonical torrent API route" {
    try validateTorrentApiUrl("https://api.tsukihime.org/v1/torrents/12765", 12765);

    for ([_][]const u8{
        "https://api.tsukihime.org/v1/torrents/12766",
        "https://api.tsukihime.org/v1/torrents/012765",
        "https://api.tsukihime.org/v1/torrents/-12765",
        "https://api.tsukihime.org/v1/torrents/12765/attachments",
        "https://api.tsukihime.org/v1/torrents/12765?include=files",
        "https://api.tsukihime.org/v1/torrents/12765#files",
        "https://api.tsukihime.org/v1/animes/12765",
        "https://api.tsukihime.org/v1/admin",
    }) |url| {
        try std.testing.expectError(
            error.InvalidDownloadUrl,
            validateTorrentApiUrl(url, 12765),
        );
    }
    try std.testing.expectError(
        error.InvalidDownloadUrl,
        validateTorrentApiUrl("https://api.tsukihime.org/v1/torrents/1", 0),
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
