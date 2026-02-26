const upstream = @import("htmlparser_upstream");

pub const ParseOptions = upstream.ParseOptions;
pub const TextOptions = upstream.TextOptions;
pub const Selector = upstream.Selector;

const default_options: ParseOptions = .{};

pub const Document = default_options.GetDocument();
pub const Node = default_options.GetNode();
pub const NodeRaw = default_options.GetNodeRaw();
pub const QueryIter = default_options.QueryIter();

pub fn GetDocument(comptime options: ParseOptions) type {
    return upstream.GetDocument(options);
}

pub fn GetNode(comptime options: ParseOptions) type {
    return upstream.GetNode(options);
}

pub fn GetNodeRaw(comptime options: ParseOptions) type {
    return upstream.GetNodeRaw(options);
}

pub fn GetQueryIter(comptime options: ParseOptions) type {
    return upstream.GetQueryIter(options);
}
