const std = @import("std");
const common = @import("scrapers").common;
const runtime_io = @import("runtime_io");

fn expectFetchError(client: *std.http.Client, allocator: std.mem.Allocator, url: []const u8, opts: common.FetchOptions, expected: anyerror) !void {
    if (common.fetchBytes(client, allocator, url, opts)) |response| {
        allocator.free(response.body);
        return error.ExpectedHttpTransportFailure;
    } else |err| if (err != expected) return err;
}

pub fn main(init: std.process.Init) !void {
    runtime_io.set(init.io);
    var gpa: std.heap.SafeAllocator = .init(std.heap.page_allocator, .{});
    defer if (gpa.deinit() != 0) @panic("HTTP fixture leaked allocations");
    const allocator = gpa.allocator();
    const args = try init.minimal.args.toSlice(init.arena.allocator());
    if (args.len != 2) return error.Usage;
    var client: std.http.Client = .{ .allocator = allocator, .io = init.io };
    defer client.deinit();
    const headers = [_]std.http.Header{
        .{ .name = "cookie", .value = "fixture=session" },
        .{ .name = "authorization", .value = "Bearer fixture-only" },
        .{ .name = "x-api-key", .value = "fixture-api-key" },
        .{ .name = "user-agent", .value = "fixture-secret-agent" },
        .{ .name = "content-type", .value = "application/x-fixture-secret" },
    };
    const cases = [_]struct { path: []const u8, expected: []const u8, post: bool = false, head: bool = false }{
        .{ .path = "/echo", .expected = "GET private" },
        .{ .path = "/same", .expected = "GET private" },
        .{ .path = "/cross", .expected = "GET public" },
        .{ .path = "/roundtrip", .expected = "GET public" },
        .{ .path = "/post", .expected = "GET public", .post = true },
        .{ .path = "/gzip", .expected = "GET private" },
        .{ .path = "/gzip-chunked", .expected = "GET private" },
        .{ .path = "/chunked", .expected = "GET private" },
        .{ .path = "/chunked-extension", .expected = "GET private" },
        .{ .path = "/gzip-members", .expected = "GET private" },
        .{ .path = "/deflate", .expected = "GET private" },
        .{ .path = "/early-hints", .expected = "GET private" },
        .{ .path = "/no-content", .expected = "" },
        .{ .path = "/not-modified", .expected = "" },
        .{ .path = "/head", .expected = "", .head = true },
    };
    for (cases) |case| {
        const url = try std.fmt.allocPrint(allocator, "{s}{s}", .{ args[1], case.path });
        defer allocator.free(url);
        const response = try common.fetchBytes(&client, allocator, url, .{
            .cache = false,
            .allow_non_ok = true,
            .extra_headers = &headers,
            .method = if (case.head) .HEAD else if (case.post) .POST else .GET,
            .payload = if (case.post) "synthetic input" else null,
        });
        defer allocator.free(response.body);
        if (!std.mem.eql(u8, response.body, case.expected)) {
            std.debug.print("HTTP fixture {s}: expected {s}, got {s}\n", .{ case.path, case.expected, response.body });
            return error.UnexpectedRedirectHeaders;
        }
    }
    const encoding_url = try std.fmt.allocPrint(allocator, "{s}/encoding-policy", .{args[1]});
    defer allocator.free(encoding_url);
    const encoding_response = try common.fetchBytes(&client, allocator, encoding_url, .{ .cache = false });
    defer allocator.free(encoding_response.body);
    if (!std.mem.eql(u8, encoding_response.body, "GET public")) return error.UnexpectedEncodingPolicyBody;
    const identity_headers = [_]std.http.Header{.{ .name = "Accept-Encoding", .value = "identity" }};
    const identity_url = try std.fmt.allocPrint(allocator, "{s}/identity", .{args[1]});
    defer allocator.free(identity_url);
    const identity_response = try common.fetchBytes(&client, allocator, identity_url, .{ .cache = false, .extra_headers = &identity_headers });
    defer allocator.free(identity_response.body);
    if (!std.mem.eql(u8, identity_response.body, "GET public")) return error.UnexpectedIdentityBody;
    const hints_url = try std.fmt.allocPrint(allocator, "{s}/too-many-hints", .{args[1]});
    defer allocator.free(hints_url);
    if (common.fetchBytes(&client, allocator, hints_url, .{ .cache = false })) |response| {
        allocator.free(response.body);
        return error.ExpectedInformationalResponseLimit;
    } else |err| if (err != error.TooManyInformationalResponses) return err;
    for ([_]struct { path: []const u8, failure: anyerror }{
        .{ .path = "/gzip-truncated", .failure = error.HttpChunkTruncated },
        .{ .path = "/gzip-garbage", .failure = error.BadGzipHeader },
    }) |case| {
        const url = try std.fmt.allocPrint(allocator, "{s}{s}", .{ args[1], case.path });
        defer allocator.free(url);
        try expectFetchError(&client, allocator, url, .{ .cache = false, .max_attempts = 1 }, case.failure);
    }
    for ([_]struct { path: []const u8, failure: anyerror }{
        .{ .path = "/gzip-bad-crc", .failure = error.WrongGzipChecksum },
        .{ .path = "/gzip-bad-size", .failure = error.WrongGzipSize },
        .{ .path = "/deflate-bad-checksum", .failure = error.WrongZlibChecksum },
    }) |case| {
        const url = try std.fmt.allocPrint(allocator, "{s}{s}", .{ args[1], case.path });
        defer allocator.free(url);
        try expectFetchError(&client, allocator, url, .{ .cache = false }, case.failure);
    }
    for ([_]struct { path: []const u8, failure: anyerror }{
        .{ .path = "/chunked-truncated", .failure = error.HttpChunkTruncated },
        .{ .path = "/chunk-invalid-size", .failure = error.HttpChunkInvalid },
        .{ .path = "/chunk-overflow-size", .failure = error.HttpChunkInvalid },
        .{ .path = "/chunk-missing-crlf", .failure = error.HttpChunkInvalid },
        .{ .path = "/te-cl", .failure = error.AmbiguousHttpFraming },
        .{ .path = "/duplicate-content-length", .failure = error.AmbiguousHttpFraming },
        // Client.receiveHead intentionally collapses Head.parse failures,
        // including an overflowing Content-Length, to HttpHeadersInvalid.
        .{ .path = "/content-length-overflow", .failure = error.HttpHeadersInvalid },
    }) |case| {
        const url = try std.fmt.allocPrint(allocator, "{s}{s}", .{ args[1], case.path });
        defer allocator.free(url);
        try expectFetchError(&client, allocator, url, .{ .cache = false, .max_attempts = 1 }, case.failure);
    }
    const chunked_cap_url = try std.fmt.allocPrint(allocator, "{s}/chunked-cap", .{args[1]});
    defer allocator.free(chunked_cap_url);
    const exact_cap = try common.fetchBytes(&client, allocator, chunked_cap_url, .{
        .cache = false,
        .max_response_bytes = 10,
        .max_encoded_response_bytes = 10,
    });
    defer allocator.free(exact_cap.body);
    if (!std.mem.eql(u8, exact_cap.body, "0123456789")) return error.UnexpectedExactLimitBody;
    try expectFetchError(&client, allocator, chunked_cap_url, .{
        .cache = false,
        .max_response_bytes = 9,
        .max_encoded_response_bytes = 10,
    }, error.ResponseTooLarge);
    try expectFetchError(&client, allocator, chunked_cap_url, .{
        .cache = false,
        .max_response_bytes = 10,
        .max_encoded_response_bytes = 9,
    }, error.ResponseTooLarge);
    const encoded_size_url = try std.fmt.allocPrint(allocator, "{s}/gzip-wire-chunked", .{args[1]});
    defer allocator.free(encoded_size_url);
    if (common.fetchBytes(&client, allocator, encoded_size_url, .{
        .cache = false,
        .max_response_bytes = 1024,
        .max_encoded_response_bytes = 8,
    })) |response| {
        allocator.free(response.body);
        return error.ExpectedEncodedResponseSizeLimit;
    } else |err| if (err != error.ResponseTooLarge) return err;
    const loop_url = try std.fmt.allocPrint(allocator, "{s}/loop", .{args[1]});
    defer allocator.free(loop_url);
    if (common.fetchBytes(&client, allocator, loop_url, .{ .cache = false, .extra_headers = &headers })) |response| {
        allocator.free(response.body);
        return error.ExpectedRedirectLimit;
    } else |err| if (err != error.TooManyHttpRedirects) return err;
    const broken_url = try std.fmt.allocPrint(allocator, "{s}/truncated", .{args[1]});
    defer allocator.free(broken_url);
    try expectFetchError(&client, allocator, broken_url, .{
        .cache = false,
        .extra_headers = &headers,
        .max_attempts = 1,
    }, error.HttpBodyTruncated);
    try expectFetchError(&client, allocator, broken_url, .{
        .cache = false,
        .max_attempts = 1,
    }, error.HttpBodyTruncated);
    const size_url = try std.fmt.allocPrint(allocator, "{s}/echo", .{args[1]});
    defer allocator.free(size_url);
    if (common.fetchBytes(&client, allocator, size_url, .{ .cache = false, .max_response_bytes = 4 })) |response| {
        allocator.free(response.body);
        return error.ExpectedResponseSizeLimit;
    } else |err| if (err != error.ResponseTooLarge) return err;

    const strict_url = try std.fmt.allocPrint(allocator, "{s}/cross-strict", .{args[1]});
    defer allocator.free(strict_url);
    try expectFetchError(&client, allocator, strict_url, .{
        .cache = false,
        .extra_headers = &headers,
        .require_same_origin = true,
    }, error.UnsafeHttpTarget);

    const slow_url = try std.fmt.allocPrint(allocator, "{s}/slow", .{args[1]});
    defer allocator.free(slow_url);
    try expectFetchError(&client, allocator, slow_url, .{
        .cache = false,
        .deadline_ms = common.compatMilliTimestamp() + 1_000,
    }, error.Timeout);
    // Timeout cancellation must finish unwinding the request before returning;
    // the same client must remain immediately reusable.
    const after_timeout_url = try std.fmt.allocPrint(allocator, "{s}/echo", .{args[1]});
    defer allocator.free(after_timeout_url);
    const after_timeout = try common.fetchBytes(&client, allocator, after_timeout_url, .{ .cache = false });
    defer allocator.free(after_timeout.body);
    if (!std.mem.eql(u8, after_timeout.body, "GET public")) return error.ClientUnusableAfterTimeout;

    const must_not_arrive_url = try std.fmt.allocPrint(allocator, "{s}/must-not-arrive", .{args[1]});
    defer allocator.free(must_not_arrive_url);
    for ([_][]const u8{
        "Host",
        "Connection",
        "Content-Length",
        "Transfer-Encoding",
        "TE",
        "Trailer",
        "Upgrade",
        "Keep-Alive",
        "Expect",
        "Proxy-Authorization",
        "Proxy-Connection",
    }) |name| {
        const rejected = [_]std.http.Header{.{ .name = name, .value = "fixture" }};
        try expectFetchError(&client, allocator, must_not_arrive_url, .{
            .cache = false,
            .extra_headers = &rejected,
        }, error.TransportOwnedHttpHeader);
    }
    const unsupported_encoding = [_]std.http.Header{.{ .name = "Accept-Encoding", .value = "zstd" }};
    try expectFetchError(&client, allocator, must_not_arrive_url, .{
        .cache = false,
        .extra_headers = &unsupported_encoding,
    }, error.UnsupportedCompressionMethod);
    std.debug.print("HTTP_TRANSPORT_PASS checks=53\n", .{});
}
