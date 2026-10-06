const std = @import("std");
const common = @import("scrapers").common;
const runtime_io = @import("runtime_io");

pub fn main(init: std.process.Init) !void {
    runtime_io.set(init.io);
    var gpa: std.heap.DebugAllocator(.{}) = .init;
    defer if (gpa.deinit() == .leak) @panic("HTTP fixture leaked allocations");
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
        .{ .name = "connection", .value = "close" },
        .{ .name = "accept-encoding", .value = "identity" },
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
        .{ .path = "/gzip-members", .expected = "GET private" },
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
    const zstd_url = try std.fmt.allocPrint(allocator, "{s}/zstd", .{args[1]});
    defer allocator.free(zstd_url);
    const zstd_response = try common.fetchBytes(&client, allocator, zstd_url, .{ .cache = false });
    defer allocator.free(zstd_response.body);
    if (!std.mem.eql(u8, zstd_response.body, "GET public")) return error.UnexpectedZstdBody;
    const hints_url = try std.fmt.allocPrint(allocator, "{s}/too-many-hints", .{args[1]});
    defer allocator.free(hints_url);
    if (common.fetchBytes(&client, allocator, hints_url, .{ .cache = false })) |response| {
        allocator.free(response.body);
        return error.ExpectedInformationalResponseLimit;
    } else |err| if (err != error.TooManyInformationalResponses) return err;
    for ([_][]const u8{ "/gzip-truncated", "/gzip-garbage" }) |path| {
        const url = try std.fmt.allocPrint(allocator, "{s}{s}", .{ args[1], path });
        defer allocator.free(url);
        if (common.fetchBytes(&client, allocator, url, .{ .cache = false, .max_attempts = 1 })) |response| {
            allocator.free(response.body);
            return error.ExpectedInvalidCompressedBodyFailure;
        } else |_| {}
    }
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
    if (common.fetchBytes(&client, allocator, broken_url, .{ .cache = false, .extra_headers = &headers })) |response| {
        allocator.free(response.body);
        return error.ExpectedTruncatedBodyFailure;
    } else |_| {}
    if (common.fetchBytes(&client, allocator, broken_url, .{ .cache = false })) |response| {
        allocator.free(response.body);
        return error.ExpectedPublicTruncatedBodyFailure;
    } else |_| {}
    const size_url = try std.fmt.allocPrint(allocator, "{s}/echo", .{args[1]});
    defer allocator.free(size_url);
    if (common.fetchBytes(&client, allocator, size_url, .{ .cache = false, .max_response_bytes = 4 })) |response| {
        allocator.free(response.body);
        return error.ExpectedResponseSizeLimit;
    } else |err| if (err != error.ResponseTooLarge) return err;
    std.debug.print("HTTP_TRANSPORT_PASS cases=21\n", .{});
}
