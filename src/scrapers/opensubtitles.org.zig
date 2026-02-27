const std = @import("std");
const common = @import("common.zig");

const Allocator = std.mem.Allocator;
const site = "https://www.opensubtitles.org";
const opensubtitles_host = "www.opensubtitles.org";

pub const SearchItem = struct {
    title: []const u8,
    page_url: []const u8,
};

pub const SubtitleItem = struct {
    language_code: ?[]const u8,
    filename: ?[]const u8,
    release: ?[]const u8,
    fps: ?[]const u8,
    cds: ?[]const u8,
    rating: ?[]const u8,
    downloads: ?[]const u8,
    uploaded_at: ?[]const u8,
    hearing_impaired: bool,
    trusted: bool,
    hd: bool,
    details_url: []const u8,
    direct_zip_url: []const u8,
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

pub const Scraper = struct {
    pub const Options = struct {
        language_code: []const u8 = "all",
    };

    allocator: Allocator,
    client: *std.http.Client,
    options: Options,

    pub fn init(allocator: Allocator, client: *std.http.Client) Scraper {
        return .{ .allocator = allocator, .client = client, .options = .{} };
    }

    pub fn initWithOptions(allocator: Allocator, client: *std.http.Client, options: Options) Scraper {
        return .{ .allocator = allocator, .client = client, .options = options };
    }

    pub fn deinit(_: *Scraper) void {}

    pub fn search(self: *Scraper, query: []const u8) !SearchResponse {
        var arena = std.heap.ArenaAllocator.init(self.allocator);
        errdefer arena.deinit();
        const a = arena.allocator();

        const encoded = try common.encodeUriComponent(a, query);
        const language3 = languageToOpenSubtitles3(self.options.language_code) orelse "all";
        const url = try std.fmt.allocPrint(a, "{s}/en/search2/moviename-{s}/sublanguageid-{s}", .{ site, encoded, language3 });

        const response = try self.fetchHtmlWithDoh(a, url);
        var parsed = try common.parseHtmlStable(a, response.body);
        defer parsed.deinit();

        var items: std.ArrayListUnmanaged(SearchItem) = .empty;
        var anchors = parsed.doc.queryAll("table#search_results td[id^='main'] strong a.bnone[href*='/search/'][href*='idmovie-']");
        while (anchors.next()) |anchor| {
            const href = anchor.getAttributeValue("href") orelse continue;
            const title = try common.innerTextTrimmedOwned(a, anchor);
            const page_url = try common.resolveUrl(a, site, href);
            try items.append(a, .{ .title = title, .page_url = page_url });
        }

        if (items.items.len == 0) {
            const has_subtitle_rows = parsed.doc.queryOne("table#search_results a[href*='/subtitleserve/sub/']") != null;
            if (has_subtitle_rows) {
                const inferred_title = blk: {
                    if (parsed.doc.queryOne("h1")) |n| break :blk try common.innerTextTrimmedOwned(a, n);
                    break :blk try a.dupe(u8, query);
                };
                try items.append(a, .{ .title = inferred_title, .page_url = try a.dupe(u8, url) });
            }
        }

        return .{ .arena = arena, .items = try dedupeSearchItems(a, items.items) };
    }

    pub fn fetchSubtitlesByMoviePage(self: *Scraper, page_url: []const u8) !SubtitlesResponse {
        var arena = std.heap.ArenaAllocator.init(self.allocator);
        errdefer arena.deinit();
        const a = arena.allocator();

        const response = try self.fetchHtmlWithDoh(a, page_url);
        var parsed = try common.parseHtmlStable(a, response.body);
        defer parsed.deinit();

        const title = blk: {
            if (parsed.doc.queryOne("h1")) |n| break :blk try common.innerTextTrimmedOwned(a, n);
            if (parsed.doc.queryOne("title")) |n| break :blk try common.innerTextTrimmedOwned(a, n);
            break :blk "";
        };

        var out: std.ArrayListUnmanaged(SubtitleItem) = .empty;
        var rows = parsed.doc.queryAll("table#search_results tr[id^='name']");
        while (rows.next()) |row| {
            const subtitle_anchor = row.queryOne("td[id^='main'] strong a.bnone[href*='/subtitles/']") orelse continue;
            const details_href = subtitle_anchor.getAttributeValue("href") orelse continue;
            const details_url = try common.resolveUrl(a, site, details_href);

            const subtitle_id = blk_id: {
                const serve_anchor = row.queryOne("a[href*='/subtitleserve/sub/']") orelse break :blk_id null;
                const href = serve_anchor.getAttributeValue("href") orelse break :blk_id null;
                const marker = "/subtitleserve/sub/";
                const start = std.mem.indexOf(u8, href, marker) orelse break :blk_id null;
                const tail = href[start + marker.len ..];
                const end = std.mem.indexOfAny(u8, tail, "/?#") orelse tail.len;
                break :blk_id tail[0..end];
            };
            const direct_zip_url = if (subtitle_id) |sid|
                try std.fmt.allocPrint(a, "https://dl.opensubtitles.org/en/download/sub/{s}", .{sid})
            else
                "";

            const language_code = extractFlagLanguage(row, a) catch null;
            const filename = extractFilename(row, a) catch null;
            const release = extractSubCellText(row, a, 1) catch null;
            const fps = extractSubCellText(row, a, 5) catch null;
            const cds = extractSubCellText(row, a, 4) catch null;
            const rating = extractSubCellText(row, a, 8) catch null;
            const downloads = extractSubCellText(row, a, 7) catch null;
            const uploaded_at = extractSubCellText(row, a, 6) catch null;

            const row_text = try common.innerTextTrimmedOwned(a, row);
            const lower_row = try lowerDup(a, row_text);

            try out.append(a, .{
                .language_code = language_code,
                .filename = filename,
                .release = release,
                .fps = fps,
                .cds = cds,
                .rating = rating,
                .downloads = downloads,
                .uploaded_at = uploaded_at,
                .hearing_impaired = std.mem.indexOf(u8, lower_row, "hearing") != null,
                .trusted = std.mem.indexOf(u8, lower_row, "trusted") != null,
                .hd = std.mem.indexOf(u8, lower_row, "hd") != null,
                .details_url = details_url,
                .direct_zip_url = direct_zip_url,
            });
        }

        return .{ .arena = arena, .title = title, .subtitles = try out.toOwnedSlice(a) };
    }

    fn fetchHtmlWithDoh(self: *Scraper, allocator: Allocator, url: []const u8) !common.HttpResponse {
        var target = try pathFromOpenSubtitlesUrl(allocator, url);
        var redirects: usize = 0;

        while (true) {
            if (redirects > 4) return error.UnexpectedHttpStatus;

            const ip = try self.resolveHostViaDoh(allocator, opensubtitles_host);
            const raw = try fetchHttpsByIp(allocator, opensubtitles_host, ip, target, "text/html");
            if (std.posix.getenv("SCRAPERS_DEBUG_OPENSUB_ORG_DOH") != null) {
                std.debug.print("[opensubtitles.org][doh] ip={s} path={s} status={d}\n", .{
                    ip,
                    target,
                    @intFromEnum(raw.status),
                });
                if (raw.location) |loc| {
                    std.debug.print("[opensubtitles.org][doh] location={s}\n", .{loc});
                }
            }

            if (isRedirectStatus(raw.status)) {
                if (raw.location) |location| {
                    const next_target = try pathFromRedirectLocation(allocator, location);
                    target = next_target;
                    redirects += 1;
                    continue;
                }
            }

            return .{
                .status = raw.status,
                .body = raw.body,
            };
        }
    }

    fn resolveHostViaDoh(self: *Scraper, allocator: Allocator, host: []const u8) ![]const u8 {
        const encoded_host = try common.encodeUriComponent(allocator, host);
        const endpoints = [_][]const u8{
            try std.fmt.allocPrint(allocator, "https://cloudflare-dns.com/dns-query?name={s}&type=A", .{encoded_host}),
            try std.fmt.allocPrint(allocator, "https://dns.google/resolve?name={s}&type=A", .{encoded_host}),
        };

        for (endpoints) |endpoint| {
            const response = common.fetchBytes(self.client, allocator, endpoint, .{
                .accept = "application/dns-json",
                .allow_non_ok = true,
                .max_attempts = 2,
            }) catch continue;

            if (response.status != .ok) continue;

            const root = std.json.parseFromSliceLeaky(std.json.Value, allocator, response.body, .{}) catch continue;
            const obj = switch (root) {
                .object => |o| o,
                else => continue,
            };
            const answers_val = obj.get("Answer") orelse continue;
            const answers = switch (answers_val) {
                .array => |a| a,
                else => continue,
            };

            for (answers.items) |answer| {
                const answer_obj = switch (answer) {
                    .object => |o| o,
                    else => continue,
                };

                const type_val = answer_obj.get("type") orelse continue;
                const rr_type: i64 = switch (type_val) {
                    .integer => |i| i,
                    .number_string => |s| std.fmt.parseInt(i64, s, 10) catch continue,
                    else => continue,
                };
                if (rr_type != 1) continue;

                const data_val = answer_obj.get("data") orelse continue;
                const ip = switch (data_val) {
                    .string => |s| s,
                    else => continue,
                };
                if (ip.len == 0) continue;

                return try allocator.dupe(u8, ip);
            }
        }

        return error.TemporaryNameServerFailure;
    }
};

const RawHttpResponse = struct {
    status: std.http.Status,
    location: ?[]const u8,
    body: []u8,
};

fn fetchHttpsByIp(
    allocator: Allocator,
    host: []const u8,
    ip: []const u8,
    path: []const u8,
    accept: []const u8,
) !RawHttpResponse {
    const addr = try std.net.Address.parseIp(ip, 443);
    var stream = try std.net.tcpConnectToAddress(addr);
    defer stream.close();

    const in_buf = try allocator.alloc(u8, std.crypto.tls.Client.min_buffer_len);
    const out_buf = try allocator.alloc(u8, std.crypto.tls.Client.min_buffer_len);
    const tls_read_buf = try allocator.alloc(u8, std.crypto.tls.Client.min_buffer_len + 8192);
    const tls_write_buf = try allocator.alloc(u8, 4096);
    defer allocator.free(in_buf);
    defer allocator.free(out_buf);
    defer allocator.free(tls_read_buf);
    defer allocator.free(tls_write_buf);

    var stream_reader = stream.reader(in_buf);
    var stream_writer = stream.writer(out_buf);

    var ca_bundle: std.crypto.Certificate.Bundle = .{};
    defer ca_bundle.deinit(allocator);
    try ca_bundle.rescan(allocator);

    var tls_client = try std.crypto.tls.Client.init(
        stream_reader.interface(),
        &stream_writer.interface,
        .{
            .host = .{ .explicit = host },
            .ca = .{ .bundle = ca_bundle },
            .read_buffer = tls_read_buf,
            .write_buffer = tls_write_buf,
            .allow_truncation_attacks = true,
        },
    );

    const request = try std.fmt.allocPrint(
        allocator,
        "GET {s} HTTP/1.1\r\nHost: {s}\r\nUser-Agent: {s}\r\nAccept: {s}\r\nAccept-Encoding: identity\r\nConnection: close\r\n\r\n",
        .{ path, host, common.default_user_agent, accept },
    );
    defer allocator.free(request);

    try tls_client.writer.writeAll(request);
    try tls_client.writer.flush();
    try stream_writer.interface.flush();

    return readHttpResponse(allocator, &tls_client.reader);
}

fn readHttpResponse(allocator: Allocator, reader: *std.Io.Reader) !RawHttpResponse {
    const status_line = try readLine(allocator, reader);
    const status_code = parseHttpStatusCode(status_line) orelse {
        if (std.posix.getenv("SCRAPERS_DEBUG_OPENSUB_ORG_DOH") != null) {
            std.debug.print("[opensubtitles.org][doh] invalid status line: {s}\n", .{status_line});
        }
        return error.UnexpectedHttpStatus;
    };

    var content_length: ?usize = null;
    var chunked = false;
    var location: ?[]const u8 = null;

    while (true) {
        const line = try readLine(allocator, reader);
        if (line.len == 0) break;

        const colon = std.mem.indexOfScalar(u8, line, ':') orelse continue;
        const name = std.mem.trim(u8, line[0..colon], " \t");
        const value = std.mem.trim(u8, line[colon + 1 ..], " \t");

        if (std.ascii.eqlIgnoreCase(name, "content-length")) {
            content_length = std.fmt.parseInt(usize, value, 10) catch null;
            continue;
        }
        if (std.ascii.eqlIgnoreCase(name, "transfer-encoding")) {
            chunked = std.ascii.indexOfIgnoreCase(value, "chunked") != null;
            continue;
        }
        if (std.ascii.eqlIgnoreCase(name, "location")) {
            location = try allocator.dupe(u8, value);
            continue;
        }
    }

    const body = if (chunked)
        try readChunkedBody(allocator, reader)
    else if (content_length) |len|
        try readFixedBody(allocator, reader, len)
    else
        try readBodyToEof(allocator, reader);

    return .{
        .status = @enumFromInt(status_code),
        .location = location,
        .body = body,
    };
}

fn readFixedBody(allocator: Allocator, reader: *std.Io.Reader, len: usize) ![]u8 {
    const body = try allocator.alloc(u8, len);
    if (len == 0) return body;
    try reader.readSliceAll(body);
    return body;
}

fn readBodyToEof(allocator: Allocator, reader: *std.Io.Reader) ![]u8 {
    var out: std.ArrayListUnmanaged(u8) = .empty;
    errdefer out.deinit(allocator);

    var buf: [8192]u8 = undefined;
    while (true) {
        const n = reader.readSliceShort(&buf) catch return error.ReadFailed;
        if (n == 0) break;
        try out.appendSlice(allocator, buf[0..n]);
    }

    return try out.toOwnedSlice(allocator);
}

fn readChunkedBody(allocator: Allocator, reader: *std.Io.Reader) ![]u8 {
    var out: std.ArrayListUnmanaged(u8) = .empty;
    errdefer out.deinit(allocator);

    var tmp: [4096]u8 = undefined;

    while (true) {
        const size_line = try readLine(allocator, reader);
        const chunk_size = parseChunkSize(size_line) orelse return error.InvalidFieldType;
        if (chunk_size == 0) {
            while (true) {
                const trailer = try readLine(allocator, reader);
                if (trailer.len == 0) break;
            }
            break;
        }

        var remaining = chunk_size;
        while (remaining > 0) {
            const n = @min(remaining, tmp.len);
            try reader.readSliceAll(tmp[0..n]);
            try out.appendSlice(allocator, tmp[0..n]);
            remaining -= n;
        }

        _ = try reader.takeArray(2);
    }

    return try out.toOwnedSlice(allocator);
}

fn parseChunkSize(line: []const u8) ?usize {
    const trimmed = std.mem.trim(u8, line, " \t\r\n");
    if (trimmed.len == 0) return null;
    const semi = std.mem.indexOfScalar(u8, trimmed, ';') orelse trimmed.len;
    return std.fmt.parseInt(usize, trimmed[0..semi], 16) catch null;
}

fn readLine(allocator: Allocator, reader: *std.Io.Reader) ![]u8 {
    var out: std.ArrayListUnmanaged(u8) = .empty;
    errdefer out.deinit(allocator);

    while (true) {
        const byte = reader.takeByte() catch |err| switch (err) {
            error.EndOfStream => break,
            error.ReadFailed => return error.ReadFailed,
        };
        if (byte == '\n') break;
        try out.append(allocator, byte);
    }

    if (out.items.len > 0 and out.items[out.items.len - 1] == '\r') {
        out.items.len -= 1;
    }

    return try out.toOwnedSlice(allocator);
}

fn parseHttpStatusCode(status_line: []const u8) ?u16 {
    var it = std.mem.tokenizeAny(u8, status_line, " \t");
    _ = it.next() orelse return null;
    const code_text = it.next() orelse return null;
    return std.fmt.parseInt(u16, code_text, 10) catch null;
}

fn pathFromOpenSubtitlesUrl(allocator: Allocator, url: []const u8) ![]const u8 {
    if (!std.mem.startsWith(u8, url, site)) return error.InvalidFieldType;
    const raw = url[site.len..];
    if (raw.len == 0) return try allocator.dupe(u8, "/");
    if (raw[0] == '/') return try allocator.dupe(u8, raw);
    return try std.fmt.allocPrint(allocator, "/{s}", .{raw});
}

fn pathFromRedirectLocation(allocator: Allocator, location: []const u8) ![]const u8 {
    if (std.mem.startsWith(u8, location, "http://") or std.mem.startsWith(u8, location, "https://")) {
        return pathFromOpenSubtitlesUrl(allocator, location);
    }
    if (location.len == 0) return try allocator.dupe(u8, "/");
    if (location[0] == '/') return try allocator.dupe(u8, location);
    return try std.fmt.allocPrint(allocator, "/{s}", .{location});
}

fn isRedirectStatus(status: std.http.Status) bool {
    return status == .moved_permanently or
        status == .found or
        status == .see_other or
        status == .temporary_redirect or
        status == .permanent_redirect;
}

fn dedupeSearchItems(allocator: Allocator, items: []const SearchItem) ![]const SearchItem {
    var seen = std.StringHashMapUnmanaged(void).empty;
    defer seen.deinit(allocator);

    var out: std.ArrayListUnmanaged(SearchItem) = .empty;
    errdefer out.deinit(allocator);

    for (items) |item| {
        if (seen.contains(item.page_url)) continue;
        try seen.put(allocator, item.page_url, {});
        try out.append(allocator, item);
    }

    return try out.toOwnedSlice(allocator);
}

fn extractFlagLanguage(row: @import("htmlparser").Node, allocator: Allocator) !?[]const u8 {
    const flag_div = row.queryOne("td:nth-child(2) div[class*='flag']") orelse return null;
    const class = flag_div.getAttributeValue("class") orelse return null;
    var it = std.mem.tokenizeScalar(u8, class, ' ');
    while (it.next()) |part| {
        if (std.mem.eql(u8, part, "flag")) continue;
        return try allocator.dupe(u8, part);
    }
    return null;
}

fn extractFilename(row: @import("htmlparser").Node, allocator: Allocator) !?[]const u8 {
    const main = row.queryOne("td[id^='main']") orelse return null;
    if (main.queryOne("span[title]")) |n| {
        if (n.getAttributeValue("title")) |title| {
            if (title.len > 0) return try allocator.dupe(u8, title);
        }
    }
    if (main.queryOne("strong a.bnone")) |n| {
        const text = try common.innerTextTrimmedOwned(allocator, n);
        if (text.len > 0) return text;
    }
    return null;
}

fn extractSubCellText(row: @import("htmlparser").Node, allocator: Allocator, cell_idx_one_based: usize) !?[]const u8 {
    var cells = row.queryAll("td");
    var idx: usize = 1;
    while (cells.next()) |cell| : (idx += 1) {
        if (idx != cell_idx_one_based) continue;
        const text = try common.innerTextTrimmedOwned(allocator, cell);
        if (text.len == 0) return null;
        return text;
    }
    return null;
}

fn lowerDup(allocator: Allocator, input: []const u8) ![]u8 {
    const out = try allocator.dupe(u8, input);
    for (out) |*c| c.* = std.ascii.toLower(c.*);
    return out;
}

fn languageToOpenSubtitles3(code: []const u8) ?[]const u8 {
    if (std.ascii.eqlIgnoreCase(code, "en")) return "eng";
    if (std.ascii.eqlIgnoreCase(code, "es")) return "spa";
    if (std.ascii.eqlIgnoreCase(code, "fr")) return "fre";
    if (std.ascii.eqlIgnoreCase(code, "de")) return "ger";
    if (std.ascii.eqlIgnoreCase(code, "it")) return "ita";
    if (std.ascii.eqlIgnoreCase(code, "pt")) return "por";
    if (std.ascii.eqlIgnoreCase(code, "pt-br")) return "pob";
    if (std.ascii.eqlIgnoreCase(code, "tr")) return "tur";
    if (std.ascii.eqlIgnoreCase(code, "ar")) return "ara";
    if (std.ascii.eqlIgnoreCase(code, "ru")) return "rus";
    if (std.ascii.eqlIgnoreCase(code, "pl")) return "pol";
    if (std.ascii.eqlIgnoreCase(code, "nl")) return "dut";
    if (std.ascii.eqlIgnoreCase(code, "sv")) return "swe";
    if (std.ascii.eqlIgnoreCase(code, "fi")) return "fin";
    if (std.ascii.eqlIgnoreCase(code, "zh")) return "chi";
    if (std.ascii.eqlIgnoreCase(code, "zh-tw")) return "zht";
    return null;
}

test "opensubtitles language mapping" {
    try std.testing.expectEqualStrings("eng", languageToOpenSubtitles3("en").?);
    try std.testing.expect(languageToOpenSubtitles3("xx") == null);
}

test "live opensubtitles.org search and subtitles" {
    if (!common.shouldRunLiveTests(std.testing.allocator)) return error.SkipZigTest;
    if (!common.shouldRunNamedLiveTest(std.testing.allocator, "OPENSUBTITLES_ORG")) return error.SkipZigTest;

    var client: std.http.Client = .{ .allocator = std.testing.allocator };
    defer client.deinit();

    var scraper = Scraper.init(std.testing.allocator, &client);
    var search = try scraper.search("The Matrix");
    defer search.deinit();
    try std.testing.expect(search.items.len > 0);
    const item = search.items[0];
    std.debug.print("[live][opensubtitles.org][search][0]\n", .{});
    try common.livePrintField(std.testing.allocator, "title", item.title);
    try common.livePrintField(std.testing.allocator, "page_url", item.page_url);

    var subtitles = try scraper.fetchSubtitlesByMoviePage(item.page_url);
    defer subtitles.deinit();
    try std.testing.expect(subtitles.subtitles.len > 0);
    try common.livePrintField(std.testing.allocator, "subtitles_title", subtitles.title);
    const sub = subtitles.subtitles[0];
    std.debug.print("[live][opensubtitles.org][subtitle][0]\n", .{});
    try common.livePrintOptionalField(std.testing.allocator, "language_code", sub.language_code);
    try common.livePrintOptionalField(std.testing.allocator, "filename", sub.filename);
    try common.livePrintOptionalField(std.testing.allocator, "release", sub.release);
    try common.livePrintOptionalField(std.testing.allocator, "fps", sub.fps);
    try common.livePrintOptionalField(std.testing.allocator, "cds", sub.cds);
    try common.livePrintOptionalField(std.testing.allocator, "rating", sub.rating);
    try common.livePrintOptionalField(std.testing.allocator, "downloads", sub.downloads);
    try common.livePrintOptionalField(std.testing.allocator, "uploaded_at", sub.uploaded_at);
    std.debug.print("[live] hearing_impaired={any}\n", .{sub.hearing_impaired});
    std.debug.print("[live] trusted={any}\n", .{sub.trusted});
    std.debug.print("[live] hd={any}\n", .{sub.hd});
    try common.livePrintField(std.testing.allocator, "details_url", sub.details_url);
    try common.livePrintField(std.testing.allocator, "direct_zip_url", sub.direct_zip_url);
}
