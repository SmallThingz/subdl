const std = @import("std");
const upstream = @import("htmlparser_upstream");

pub const TextOptions = upstream.TextOptions;
pub const Selector = upstream.Selector;
pub const QueryDebugReport = upstream.QueryDebugReport;
pub const DebugFailureKind = upstream.DebugFailureKind;
pub const NearMiss = upstream.NearMiss;

/// Compatibility facade for the pre-rename html_parser API used by the scrapers.
/// The latest upstream binds document types to parse options, so this facade uses
/// a single safe document layout and maps the old bool parse option at parse time.
pub const ParseOptions = struct {
    pub fn GetDocument(comptime _: @This()) type {
        return Document;
    }

    pub fn GetNode(comptime _: @This()) type {
        return Node;
    }

    pub fn GetNodeRaw(comptime _: @This()) type {
        return RawNode;
    }

    pub fn QueryIter(comptime _: @This()) type {
        return CompatQueryIter;
    }

    pub fn GetQueryIter(comptime _: @This()) type {
        return CompatQueryIter;
    }
};

const upstream_options: upstream.ParseOptions = .{ .drop_whitespace_text_nodes = .none };
const UpstreamDocument = upstream_options.Document();
const UpstreamNode = upstream_options.Node();
const UpstreamRawNode = upstream_options.RawNode();
const UpstreamQueryIter = upstream_options.QueryIter();
const UpstreamChildrenIter = upstream_options.ChildrenIter();

pub const RawNode = UpstreamRawNode;
pub const Document = struct {
    allocator: std.mem.Allocator,
    inner: UpstreamDocument,

    pub fn init(allocator: std.mem.Allocator) Document {
        return .{
            .allocator = allocator,
            .inner = UpstreamDocument.init(allocator),
        };
    }

    pub fn deinit(self: *Document) void {
        self.inner.deinit();
        self.* = undefined;
    }

    pub fn clear(self: *Document) void {
        self.inner.clear();
    }

    pub fn parse(self: *Document, input: []u8, opts: anytype) !void {
        _ = opts;
        self.inner.deinit();
        self.inner = try upstream_options.parse(self.allocator, input);
    }

    pub fn query(self: *const Document, comptime selector: []const u8) CompatQueryIter {
        return .{ .inner = self.inner.query(selector) };
    }

    pub fn queryAll(self: *const Document, comptime selector: []const u8) CompatQueryIter {
        return self.query(selector);
    }

    pub fn queryOne(self: *const Document, comptime selector: []const u8) ?Node {
        var iter = self.query(selector);
        return iter.next();
    }

    pub fn queryOneDebug(self: *const Document, comptime selector: []const u8) QueryDebugResult {
        return .{ .node = self.queryOne(selector), .report = .{} };
    }

    pub fn html(self: *const Document) ?Node {
        return wrapNode(self.inner.html());
    }

    pub fn head(self: *const Document) ?Node {
        return wrapNode(self.inner.head());
    }

    pub fn body(self: *const Document) ?Node {
        return wrapNode(self.inner.body());
    }

    pub fn root(self: *const Document) Node {
        return .{ .inner = self.inner.root() };
    }

    pub fn writeHtml(self: *const Document, writer: anytype) !void {
        try self.inner.writeHtml(writer);
    }
};

pub const Node = struct {
    pub const TextOptions = UpstreamNode.TextOptions;

    inner: UpstreamNode,

    pub fn tagName(self: Node) []const u8 {
        return self.inner.tagName();
    }

    pub fn text(self: Node) []const u8 {
        return self.inner.text();
    }

    pub fn innerTextWithOptions(self: Node, allocator: std.mem.Allocator, opts: UpstreamNode.TextOptions) !UpstreamNode.TextResult {
        if (opts.normalize_whitespace) {
            if (opts.unescape) return self.inner.innerTextWithOptions(allocator, .{ .normalize_whitespace = true, .unescape = true });
            return self.inner.innerTextWithOptions(allocator, .{ .normalize_whitespace = true, .unescape = false });
        }
        if (opts.unescape) return self.inner.innerTextWithOptions(allocator, .{ .normalize_whitespace = false, .unescape = true });
        return self.inner.innerTextWithOptions(allocator, .{ .normalize_whitespace = false, .unescape = false });
    }

    pub fn innerTextOwnedWithOptions(self: Node, allocator: std.mem.Allocator, opts: UpstreamNode.TextOptions) ![]const u8 {
        if (opts.normalize_whitespace) {
            if (opts.unescape) return self.inner.innerTextOwnedWithOptions(allocator, .{ .normalize_whitespace = true, .unescape = true });
            return self.inner.innerTextOwnedWithOptions(allocator, .{ .normalize_whitespace = true, .unescape = false });
        }
        if (opts.unescape) return self.inner.innerTextOwnedWithOptions(allocator, .{ .normalize_whitespace = false, .unescape = true });
        return self.inner.innerTextOwnedWithOptions(allocator, .{ .normalize_whitespace = false, .unescape = false });
    }

    pub fn getAttributeValue(self: Node, name: []const u8) ?[]const u8 {
        const result = self.inner.getAttributeValue(self.inner.doc.allocator, name) catch return null;
        return if (result) |value| value.value else null;
    }

    pub fn getAttributeValueRaw(self: Node, name: []const u8) ?[]const u8 {
        return self.inner.getAttributeValueRaw(name);
    }

    pub fn parentNode(self: Node) ?Node {
        return wrapNode(self.inner.parentNode());
    }

    pub fn nextSibling(self: Node) ?Node {
        return wrapNode(self.inner.nextSibling());
    }

    pub fn prevSibling(self: Node) ?Node {
        return wrapNode(self.inner.prevSibling());
    }

    pub fn children(self: Node) CompatChildrenIter {
        return .{ .inner = self.inner.children() };
    }

    pub fn query(self: Node, comptime selector: []const u8) CompatQueryIter {
        return .{ .inner = self.inner.query(selector) };
    }

    pub fn queryAll(self: Node, comptime selector: []const u8) CompatQueryIter {
        return self.query(selector);
    }

    pub fn queryOne(self: Node, comptime selector: []const u8) ?Node {
        var iter = self.query(selector);
        return iter.next();
    }

    pub fn queryOneDebug(self: Node, comptime selector: []const u8) QueryDebugResult {
        return .{ .node = self.queryOne(selector), .report = .{} };
    }

    pub fn writeHtml(self: Node, writer: anytype) !void {
        try self.inner.writeHtml(writer);
    }
};

pub const CompatQueryIter = struct {
    inner: UpstreamQueryIter,

    pub fn next(self: *CompatQueryIter) ?Node {
        return wrapNode(self.inner.next());
    }
};

pub const CompatChildrenIter = struct {
    inner: UpstreamChildrenIter,

    pub fn next(self: *CompatChildrenIter) ?Node {
        return wrapNode(self.inner.next());
    }
};

pub const QueryDebugResult = struct {
    node: ?Node = null,
    report: QueryDebugReport = .{},
};

pub fn GetDocument(comptime _: ParseOptions) type {
    return Document;
}

pub fn GetNode(comptime _: ParseOptions) type {
    return Node;
}

pub fn GetNodeRaw(comptime _: ParseOptions) type {
    return RawNode;
}

pub fn GetQueryIter(comptime _: ParseOptions) type {
    return CompatQueryIter;
}

fn wrapNode(node: ?UpstreamNode) ?Node {
    return if (node) |inner| .{ .inner = inner } else null;
}
