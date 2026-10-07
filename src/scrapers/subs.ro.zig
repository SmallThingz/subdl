const std = @import("std");
const common = @import("common.zig");
const html = @import("htmlparser");

const Allocator = std.mem.Allocator;
const site = "https://subs.ro";
const search_path = "/cautare";
const search_endpoint = site ++ "/ajax/search";

pub const MediaKind = common.MediaKind;

pub const SearchItem = struct {
    title: []const u8,
    year: ?i64,
    media_kind: MediaKind,
    language_code: []const u8,
    release: []const u8,
    page_url: []const u8,
    download_url: []const u8,
};

pub const SubtitleItem = common.SubtitleFile;

pub const SearchResponse = common.SearchResponse(SearchItem);

pub const SubtitlesResponse = common.TitledSubtitlesResponse(SubtitleItem);

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

        const trimmed = std.mem.trim(u8, query, " \t\r\n");
        if (trimmed.len == 0) return .{ .arena = arena, .items = &.{} };
        const wanted = try common.normalizeTitle(a, trimmed);
        if (wanted.len == 0) return .{ .arena = arena, .items = &.{} };

        const encoded = try common.encodeUriComponent(a, trimmed);
        const search_page_url = try std.fmt.allocPrint(
            a,
            "{s}{s}?termen-general={s}",
            .{ site, search_path, encoded },
        );
        const page = try common.fetchBytes(self.client, a, search_page_url, searchPageFetchOptions());
        const antispam = try parseAntispamToken(a, page.body);

        const payload = try buildSearchPayload(a, encoded, antispam);
        const headers = [_]std.http.Header{
            .{ .name = "origin", .value = site },
            .{ .name = "referer", .value = search_page_url },
            .{ .name = "hx-request", .value = "true" },
            .{ .name = "x-requested-with", .value = "XMLHttpRequest" },
        };
        const response = try common.fetchBytes(self.client, a, search_endpoint, searchPostFetchOptions(payload, &headers));

        return parseSearchHtml(common.takeArena(&arena), response.body, trimmed);
    }

    pub fn fetchSubtitlesBySearchItem(self: *Scraper, item: SearchItem) !SubtitlesResponse {
        var arena = std.heap.ArenaAllocator.init(self.allocator);
        errdefer arena.deinit();
        const a = arena.allocator();
        const page_route = try providerRouteParts(item.page_url, .details);
        const download_route = try providerRouteParts(item.download_url, .download);
        if (!std.mem.eql(u8, page_route.slug, download_route.slug) or
            !std.mem.eql(u8, page_route.id, download_route.id)) return error.UnsafeHttpTarget;

        const subtitles = try a.alloc(SubtitleItem, 1);
        subtitles[0] = .{
            .language_code = try a.dupe(u8, item.language_code),
            .filename = try subtitleFilename(a, item.release, item.download_url),
            .download_url = try a.dupe(u8, item.download_url),
        };
        return common.finishResponse(SubtitlesResponse, &arena, .{
            .arena = arena,
            .title = try a.dupe(u8, item.title),
            .subtitles = subtitles,
        });
    }
};

fn buildSearchPayload(allocator: Allocator, encoded_query: []const u8, antispam: []const u8) ![]const u8 {
    const encoded_token = try common.encodeUriComponent(allocator, antispam);
    defer allocator.free(encoded_token);
    return std.fmt.allocPrint(allocator, "termen-general={s}&type=subtitrari&antispam={s}", .{ encoded_query, encoded_token });
}

fn searchPageFetchOptions() common.FetchOptions {
    return .{
        .accept = "text/html,application/xhtml+xml,*/*",
        .cache = false,
        .max_attempts = 3,
        .require_public_origin = true,
        .require_https = true,
        .require_same_origin = true,
    };
}

fn searchPostFetchOptions(payload: []const u8, headers: []const std.http.Header) common.FetchOptions {
    return .{
        .method = .POST,
        .payload = payload,
        .content_type = "application/x-www-form-urlencoded; charset=UTF-8",
        .accept = "text/html,application/xhtml+xml,*/*",
        .extra_headers = headers,
        .cache = false,
        .max_attempts = 3,
        .require_public_origin = true,
        .require_https = true,
        .require_same_origin = true,
    };
}

fn parseAntispamToken(allocator: Allocator, body: []const u8) ![]const u8 {
    var scratch = std.heap.ArenaAllocator.init(allocator);
    defer scratch.deinit();
    var parsed = try common.parseHtmlStable(scratch.allocator(), body);
    var found_candidate = false;
    var inputs = parsed.doc.queryAll("input[name='antispam'][value]");
    while (inputs.next()) |input| {
        found_candidate = true;
        const value = common.getAttributeValueSafe(input, "value") orelse continue;
        const trimmed = std.mem.trim(u8, value, " \t\r\n");
        if (trimmed.len < 16 or trimmed.len > 128) continue;
        return allocator.dupe(u8, trimmed);
    }
    if (found_candidate) return error.UnexpectedResponseType;
    return error.MissingField;
}

test "subs.ro encodes form token without adding fields or decoding plus" {
    const payload = try buildSearchPayload(std.testing.allocator, "The%20Matrix%26", "a+b/c=d&e?f%g");
    defer std.testing.allocator.free(payload);
    try std.testing.expectEqualStrings(
        "termen-general=The%20Matrix%26&type=subtitrari&antispam=a%2Bb%2Fc%3Dd%26e%3Ff%25g",
        payload,
    );
}

test "subs ro search transport stays on its fixed HTTPS origin" {
    const page = searchPageFetchOptions();
    try std.testing.expect(page.require_public_origin);
    try std.testing.expect(page.require_https);
    try std.testing.expect(page.require_same_origin);

    const headers = [_]std.http.Header{.{ .name = "origin", .value = site }};
    const post = searchPostFetchOptions("query=fixture", &headers);
    try std.testing.expectEqual(std.http.Method.POST, post.method);
    try std.testing.expect(post.require_public_origin);
    try std.testing.expect(post.require_https);
    try std.testing.expect(post.require_same_origin);
}

fn parseSearchHtml(arena: std.heap.ArenaAllocator, body: []const u8, query: []const u8) !SearchResponse {
    var owned_arena = arena;
    errdefer owned_arena.deinit();
    const a = owned_arena.allocator();
    const wanted = try common.normalizeTitle(a, query);
    if (wanted.len == 0) return .{ .arena = owned_arena, .items = &.{} };

    var parsed = try common.parseHtmlStable(a, body);
    var exact: std.ArrayListUnmanaged(SearchItem) = .empty;
    var partial: std.ArrayListUnmanaged(SearchItem) = .empty;
    var seen = std.StringHashMapUnmanaged(void).empty;

    var rows = parsed.doc.queryAll("div[data-subtitle-result='true']");
    while (rows.next()) |row| {
        candidate_scan: {
            var title_anchors = row.queryAll("a[data-search-result-link='true'][href]");
            while (title_anchors.next()) |title_anchor| {
                const page_href = common.getAttributeValueSafe(title_anchor, "href") orelse continue;
                const title_attr = common.getAttributeValueSafe(title_anchor, "data-movie-name");
                const raw_title = if (title_attr) |value|
                    std.mem.trim(u8, value, " \t\r\n")
                else blk: {
                    const heading = title_anchor.queryOne("h2") orelse continue;
                    break :blk std.mem.trim(u8, try common.innerTextTrimmedOwned(a, heading), " \t\r\n");
                };
                if (raw_title.len == 0) continue;

                const heading_text = if (title_anchor.queryOne("h2")) |heading|
                    try common.innerTextTrimmedOwned(a, heading)
                else
                    raw_title;
                const year = parseYear(heading_text);
                const normalized = try common.normalizeTitle(a, raw_title);
                defer a.free(normalized);
                const exact_match = std.mem.eql(u8, normalized, wanted);
                if (!exact_match and !common.normalizedTitlesRelated(normalized, wanted)) continue;

                const page_url = resolveProviderUrl(a, page_href, .details) catch |err| switch (err) {
                    error.OutOfMemory => return error.OutOfMemory,
                    else => continue,
                };
                errdefer a.free(page_url);
                const page_route = providerRouteParts(page_url, .details) catch unreachable;

                var download_anchors = row.queryAll("a[data-download-source='search-results'][href]");
                while (download_anchors.next()) |download_anchor| {
                    const download_href = common.getAttributeValueSafe(download_anchor, "href") orelse continue;
                    const download_url = resolveProviderUrl(a, download_href, .download) catch |err| switch (err) {
                        error.OutOfMemory => return error.OutOfMemory,
                        else => continue,
                    };
                    errdefer a.free(download_url);
                    if (seen.contains(download_url)) {
                        a.free(download_url);
                        continue;
                    }

                    const download_route = providerRouteParts(download_url, .download) catch unreachable;
                    if (!std.mem.eql(u8, page_route.slug, download_route.slug) or
                        !std.mem.eql(u8, page_route.id, download_route.id))
                    {
                        a.free(download_url);
                        continue;
                    }

                    const destination = if (exact_match) &exact else &partial;
                    try destination.ensureUnusedCapacity(a, 1);
                    try seen.ensureUnusedCapacity(a, 1);

                    const language_code = try parseLanguageCode(a, row);
                    errdefer a.free(language_code);
                    const release = try parseRelease(a, title_anchor, raw_title);
                    errdefer a.free(release);
                    const title = try a.dupe(u8, raw_title);
                    errdefer a.free(title);

                    const item: SearchItem = .{
                        .title = title,
                        .year = year,
                        .media_kind = inferMediaKind(raw_title, page_href),
                        .language_code = language_code,
                        .release = release,
                        .page_url = page_url,
                        .download_url = download_url,
                    };

                    seen.putAssumeCapacityNoClobber(download_url, {});
                    destination.appendAssumeCapacity(item);
                    break :candidate_scan;
                }
                a.free(page_url);
            }
        }
    }

    var items: std.ArrayListUnmanaged(SearchItem) = .empty;
    try items.appendSlice(a, exact.items);
    try items.appendSlice(a, partial.items);
    return common.finishResponse(SearchResponse, &owned_arena, .{ .arena = owned_arena, .items = try items.toOwnedSlice(a) });
}

fn parseLanguageCode(allocator: Allocator, row: anytype) ![]const u8 {
    const flag = row.queryOne("img[src*='/flags/'][alt]") orelse return allocator.dupe(u8, "ro");
    const alt = common.getAttributeValueSafe(flag, "alt") orelse return allocator.dupe(u8, "ro");
    const sep = std.mem.lastIndexOf(u8, alt, " - ") orelse return allocator.dupe(u8, "ro");
    const raw = std.mem.trim(u8, alt[sep + 3 ..], " \t\r\n");
    if (raw.len < 2 or raw.len > 8) return allocator.dupe(u8, "ro");
    return allocator.dupe(u8, common.normalizeLanguageCode(raw) orelse raw);
}

fn parseRelease(allocator: Allocator, title_anchor: anytype, fallback: []const u8) ![]const u8 {
    const title_attr = common.getAttributeValueSafe(title_anchor, "title") orelse return allocator.dupe(u8, fallback);
    var release = std.mem.trim(u8, title_attr, " \t\r\n");
    if (std.ascii.startsWithIgnoreCase(release, "Subtitrare")) {
        release = std.mem.trim(u8, release["Subtitrare".len..], " \t\r\n");
    }
    if (release.len == 0) release = fallback;
    return allocator.dupe(u8, release);
}

fn inferMediaKind(title: []const u8, page_url: []const u8) MediaKind {
    if (std.ascii.findIgnoreCase(title, "sezonul") != null) return .tv;
    if (std.ascii.findIgnoreCase(page_url, "-sezonul-") != null) return .tv;
    return .movie;
}

fn parseYear(text: []const u8) ?i64 {
    var idx: usize = 0;
    while (idx + 6 <= text.len) : (idx += 1) {
        if (text[idx] != '(' or text[idx + 5] != ')') continue;
        const digits = text[idx + 1 .. idx + 5];
        for (digits) |c| if (!std.ascii.isDigit(c)) break else {};
        const year = std.fmt.parseInt(i64, digits, 10) catch continue;
        if (year >= 1890 and year <= 2200) return year;
    }
    return null;
}

fn subtitleFilename(allocator: Allocator, release: []const u8, download_url: []const u8) ![]u8 {
    const id = pathBaseName(download_url);
    if (release.len == 0) return std.fmt.allocPrint(allocator, "subs-ro-{s}.zip", .{id});
    const bounded_release = release[0..@min(release.len, 200)];
    const slug = try common.asciiSlug(allocator, bounded_release);
    defer allocator.free(slug);
    if (slug.len == 0) return std.fmt.allocPrint(allocator, "subs-ro-{s}.zip", .{id});
    return std.fmt.allocPrint(allocator, "{s}.zip", .{slug});
}

fn pathBaseName(path: []const u8) []const u8 {
    const end = std.mem.indexOfAny(u8, path, "?#") orelse path.len;
    const trimmed = path[0..end];
    const slash = std.mem.lastIndexOfScalar(u8, trimmed, '/') orelse return trimmed;
    return trimmed[slash + 1 ..];
}

const ProviderRoute = enum { details, download };

const ProviderRouteParts = struct {
    slug: []const u8,
    id: []const u8,
};

fn resolveProviderUrl(allocator: Allocator, href: []const u8, route: ProviderRoute) ![]const u8 {
    const resolved = try common.resolveUrl(allocator, site, href);
    errdefer allocator.free(resolved);
    _ = try providerRouteParts(resolved, route);
    return resolved;
}

fn providerRouteParts(url: []const u8, route: ProviderRoute) !ProviderRouteParts {
    try common.validatePublicHttpUrl(url);
    if (!(try common.sameOrigin(site, url))) return error.UnsafeHttpTarget;

    const uri = std.Uri.parse(url) catch return error.UnsafeHttpTarget;
    if (uri.user != null or uri.password != null or uri.query != null or uri.fragment != null) {
        return error.UnsafeHttpTarget;
    }
    const path = switch (uri.path) {
        .raw, .percent_encoded => |value| value,
    };
    if (path.len == 0 or path[0] != '/' or path[path.len - 1] == '/') return error.UnsafeHttpTarget;

    var segments = std.mem.splitScalar(u8, path[1..], '/');
    if (!std.mem.eql(u8, segments.next() orelse return error.UnsafeHttpTarget, "subtitrare")) {
        return error.UnsafeHttpTarget;
    }
    if (route == .download and
        !std.mem.eql(u8, segments.next() orelse return error.UnsafeHttpTarget, "descarca"))
    {
        return error.UnsafeHttpTarget;
    }
    const slug = segments.next() orelse return error.UnsafeHttpTarget;
    const id = segments.next() orelse return error.UnsafeHttpTarget;
    if (segments.next() != null or !isSafeEncodedSegment(slug) or !isCanonicalPositiveId(id)) {
        return error.UnsafeHttpTarget;
    }
    return .{ .slug = slug, .id = id };
}

fn isCanonicalPositiveId(value: []const u8) bool {
    if (value.len == 0 or value.len > 19 or value[0] == '0') return false;
    for (value) |c| if (!std.ascii.isDigit(c)) return false;
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

test "subs.ro rejects unsafe provider links" {
    _ = try providerRouteParts(site ++ "/subtitrare/caf%C3%A9/12", .details);
    try std.testing.expectError(error.UnsafeHttpTarget, resolveProviderUrl(std.testing.allocator, "http://127.0.0.1/private", .details));
    try std.testing.expectError(error.UnsafeHttpTarget, resolveProviderUrl(std.testing.allocator, "https://user:pass@subs.ro/private", .details));
    try std.testing.expectError(error.UnsafeHttpTarget, resolveProviderUrl(std.testing.allocator, "https://subs.ro.evil.com/private", .details));
    try std.testing.expectError(error.UnsafeHttpTarget, providerRouteParts(site ++ "/subtitrare/title/0", .details));
    try std.testing.expectError(error.UnsafeHttpTarget, providerRouteParts(site ++ "/subtitrare/title/12?next=/", .details));
    try std.testing.expectError(error.UnsafeHttpTarget, providerRouteParts(site ++ "/subtitrare/descarca/title%252fother/12", .download));
    try std.testing.expectError(error.UnsafeHttpTarget, providerRouteParts(site ++ "/subtitrare/title/12/extra", .details));
    try std.testing.expectError(error.UnsafeHttpTarget, providerRouteParts(site ++ "/subtitrare/%2e%2E/12", .details));
}

test "subs.ro binds detail and download routes and sanitizes output filenames" {
    const details = try providerRouteParts(site ++ "/subtitrare/the-matrix/135", .details);
    const download = try providerRouteParts(site ++ "/subtitrare/descarca/the-matrix/135", .download);
    try std.testing.expectEqualStrings(details.slug, download.slug);
    try std.testing.expectEqualStrings(details.id, download.id);

    const filename = try subtitleFilename(std.testing.allocator, "../Matrix\\Release", site ++ "/subtitrare/descarca/the-matrix/135");
    defer std.testing.allocator.free(filename);
    try std.testing.expectEqualStrings("matrix-release.zip", filename);
}

test "subs ro parses antispam token" {
    const allocator = std.testing.allocator;
    const token = try parseAntispamToken(
        allocator,
        "<form><input type=\"hidden\" name=\"antispam\" value=\"771b40bc37c0fcbb73bac1156406ef3a165901cd\"></form>",
    );
    defer allocator.free(token);
    try std.testing.expectEqualStrings("771b40bc37c0fcbb73bac1156406ef3a165901cd", token);
}

test "subs ro scans past malformed antispam candidates" {
    const allocator = std.testing.allocator;
    const token = try parseAntispamToken(
        allocator,
        "<input name=\"antispam\" value=\"short\"><input name=\"antispam\" value=\"771b40bc37c0fcbb73bac1156406ef3a165901cd\">",
    );
    defer allocator.free(token);
    try std.testing.expectEqualStrings("771b40bc37c0fcbb73bac1156406ef3a165901cd", token);
}

test "subs ro parses movie and tv search rows" {
    const arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    var response = try parseSearchHtml(
        arena,
        \\<div data-subtitle-result="true">
        \\  <a href="https://subs.ro/subtitrare/the-matrix-1999/135"
        \\     title="Subtitrare The Matrix DVDRIP"
        \\     data-search-result-link="true"
        \\     data-movie-name="The Matrix"><h2>The Matrix <span>(1999)</span></h2></a>
        \\  <img src="https://cdn.subs.ro/img/flags/flag-rom-big.png" alt="Subtitrare The Matrix - ro">
        \\  <a href="https://subs.ro/subtitrare/descarca/the-matrix-1999/135" data-download-source="search-results">Descarca</a>
        \\</div>
        \\<div data-subtitle-result="true">
        \\  <a href="/subtitrare/the-matrix-sezonul-1-2019/129054"
        \\     title="Subtitrare The Matrix - Sezonul 1"
        \\     data-search-result-link="true"
        \\     data-movie-name="The Matrix - Sezonul 1"><h2>The Matrix - Sezonul 1 <span>(2019)</span></h2></a>
        \\  <img src="/img/flags/flag-rom-big.png" alt="Subtitrare The Matrix - Sezonul 1 - ro">
        \\  <a href="/subtitrare/descarca/the-matrix-sezonul-1-2019/129054" data-download-source="search-results">Descarca</a>
        \\</div>
    ,
        "The Matrix",
    );
    defer response.deinit();

    try std.testing.expectEqual(@as(usize, 2), response.items.len);
    try std.testing.expectEqualStrings("The Matrix", response.items[0].title);
    try std.testing.expectEqual(@as(?i64, 1999), response.items[0].year);
    try std.testing.expectEqual(MediaKind.movie, response.items[0].media_kind);
    try std.testing.expectEqualStrings("ro", response.items[0].language_code);
    try std.testing.expectEqualStrings("https://subs.ro/subtitrare/descarca/the-matrix-1999/135", response.items[0].download_url);

    try std.testing.expectEqual(MediaKind.tv, response.items[1].media_kind);
    try std.testing.expectEqual(@as(?i64, 2019), response.items[1].year);
}

test "subs ro scans for a bound detail and download pair" {
    const arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    var response = try parseSearchHtml(
        arena,
        \\<div data-subtitle-result="true">
        \\  <a href="/subtitrare/the-matrix/999" data-search-result-link="true" data-movie-name="The Matrix"><h2>The Matrix (1999)</h2></a>
        \\  <a href="/subtitrare/the-matrix/135" data-search-result-link="true" data-movie-name="The Matrix"><h2>The Matrix (1999)</h2></a>
        \\  <a href="/subtitrare/descarca/the-matrix/888" data-download-source="search-results">decoy</a>
        \\  <a href="/subtitrare/descarca/the-matrix/135" data-download-source="search-results">Descarca</a>
        \\</div>
    ,
        "The Matrix",
    );
    defer response.deinit();

    try std.testing.expectEqual(@as(usize, 1), response.items.len);
    try std.testing.expectEqualStrings("https://subs.ro/subtitrare/the-matrix/135", response.items[0].page_url);
    try std.testing.expectEqualStrings(
        "https://subs.ro/subtitrare/descarca/the-matrix/135",
        response.items[0].download_url,
    );
}

test "subs ro search keeps related titles and rejects partial-word and unrelated rows" {
    const arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    var response = try parseSearchHtml(
        arena,
        \\<div data-subtitle-result="true">
        \\  <a href="/subtitrare/preacher/1" data-search-result-link="true" data-movie-name="Preacher"><h2>Preacher</h2></a>
        \\  <a href="/subtitrare/descarca/preacher/1" data-download-source="search-results">Descarca</a>
        \\</div>
        \\<div data-subtitle-result="true">
        \\  <a href="/subtitrare/jack-reacher/2" data-search-result-link="true" data-movie-name="Jack Reacher"><h2>Jack Reacher</h2></a>
        \\  <a href="/subtitrare/descarca/jack-reacher/2" data-download-source="search-results">Descarca</a>
        \\</div>
        \\<div data-subtitle-result="true">
        \\  <a href="/subtitrare/the-matrix/3" data-search-result-link="true" data-movie-name="The Matrix"><h2>The Matrix</h2></a>
        \\  <a href="/subtitrare/descarca/the-matrix/3" data-download-source="search-results">Descarca</a>
        \\</div>
    ,
        "Reacher",
    );
    defer response.deinit();

    try std.testing.expectEqual(@as(usize, 1), response.items.len);
    try std.testing.expectEqualStrings("Jack Reacher", response.items[0].title);
}

test "subs ro normalized-empty search stops before acquisition and parsing" {
    var client: std.http.Client = .{ .allocator = std.testing.allocator, .io = std.testing.io };
    defer client.deinit();
    var scraper = Scraper.init(std.testing.allocator, &client);
    var search = try scraper.search(" ---... ");
    defer search.deinit();
    try std.testing.expectEqual(@as(usize, 0), search.items.len);

    var parsed = try parseSearchHtml(
        std.heap.ArenaAllocator.init(std.testing.allocator),
        \\<div data-subtitle-result="true">
        \\  <a href="/subtitrare/the-matrix/3" data-search-result-link="true" data-movie-name="The Matrix"><h2>The Matrix</h2></a>
        \\  <a href="/subtitrare/descarca/the-matrix/3" data-download-source="search-results">Descarca</a>
        \\</div>
    ,
        "---...",
    );
    defer parsed.deinit();
    try std.testing.expectEqual(@as(usize, 0), parsed.items.len);
}

test "subs ro malformed duplicate does not suppress a valid row" {
    const arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    var response = try parseSearchHtml(
        arena,
        \\<div data-subtitle-result="true">
        \\  <a href="/subtitrare/bad/7" data-search-result-link="true" data-movie-name=""></a>
        \\  <a href="/subtitrare/descarca/the-matrix/7" data-download-source="search-results">Descarca</a>
        \\</div>
        \\<div data-subtitle-result="true">
        \\  <a href="/subtitrare/the-matrix/7" data-search-result-link="true" data-movie-name="The Matrix"><h2>The Matrix (1999)</h2></a>
        \\  <a href="/subtitrare/descarca/the-matrix/7" data-download-source="search-results">Descarca</a>
        \\</div>
        \\<div data-subtitle-result="true">
        \\  <a href="/subtitrare/the-matrix-duplicate/7" data-search-result-link="true" data-movie-name="The Matrix"><h2>The Matrix (1999)</h2></a>
        \\  <a href="/subtitrare/descarca/the-matrix/7" data-download-source="search-results">Descarca</a>
        \\</div>
    ,
        "The Matrix",
    );
    defer response.deinit();

    try std.testing.expectEqual(@as(usize, 1), response.items.len);
    try std.testing.expectEqualStrings("The Matrix", response.items[0].title);
}

test "live subs ro movie and tv downloads" {
    if (!common.shouldRunLiveTests(std.testing.allocator)) return error.SkipZigTest;
    if (!common.providerMatchesLiveFilter(common.liveProviderFilter(), "subs.ro")) return error.SkipZigTest;

    var client: std.http.Client = .{ .allocator = std.testing.allocator, .io = std.testing.io };
    defer client.deinit();
    var scraper = Scraper.init(std.testing.allocator, &client);

    var movie = try scraper.search("The Matrix");
    defer movie.deinit();
    try std.testing.expect(movie.items.len > 0);
    const movie_item = findMediaKind(movie.items, .movie) orelse return error.TestUnexpectedResult;
    var movie_subtitles = try scraper.fetchSubtitlesBySearchItem(movie_item);
    defer movie_subtitles.deinit();
    const movie_download = try common.fetchBytes(&client, std.testing.allocator, movie_subtitles.subtitles[0].download_url, .{
        .accept = "application/zip,application/octet-stream,*/*",
        .cache = false,
        .require_public_origin = true,
    });
    defer std.testing.allocator.free(movie_download.body);
    try std.testing.expect(movie_download.body.len > 4);
    try std.testing.expect(std.mem.eql(u8, movie_download.body[0..2], "PK"));

    var tv = try scraper.search("Chernobyl");
    defer tv.deinit();
    try std.testing.expect(tv.items.len > 0);
    const tv_item = findMediaKind(tv.items, .tv) orelse return error.TestUnexpectedResult;
    var tv_subtitles = try scraper.fetchSubtitlesBySearchItem(tv_item);
    defer tv_subtitles.deinit();
    const tv_download = try common.fetchBytes(&client, std.testing.allocator, tv_subtitles.subtitles[0].download_url, .{
        .accept = "application/zip,application/octet-stream,*/*",
        .cache = false,
        .require_public_origin = true,
    });
    defer std.testing.allocator.free(tv_download.body);
    try std.testing.expect(tv_download.body.len > 4);
    try std.testing.expect(std.mem.eql(u8, tv_download.body[0..2], "PK"));
}

fn findMediaKind(items: []const SearchItem, kind: MediaKind) ?SearchItem {
    for (items) |item| {
        if (item.media_kind == kind) return item;
    }
    return null;
}
