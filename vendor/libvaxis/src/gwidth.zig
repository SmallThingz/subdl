const std = @import("std");
const testing = std.testing;
const uucode = @import("uucode");

/// the method to use when calculating the width of a grapheme
pub const Method = enum {
    unicode,
    wcwidth,
    no_zwj,
};

/// Convert a measured display width to the bounded representation stored in a
/// `Cell.Character`. Callers may still use the full measurement for layout;
/// this conversion only prevents an oversized grapheme from trapping while
/// populating the cell.
pub fn cellWidth(width: usize) u8 {
    return @intCast(@min(width, std.math.maxInt(u8)));
}

/// Calculate width from east asian width property and Unicode properties
fn eawToWidth(cp: u21, eaw: uucode.types.EastAsianWidth) i16 {
    // Based on wcwidth implementation
    // Control characters
    if (cp == 0) return 0;
    if (cp < 32 or (cp >= 0x7f and cp < 0xa0)) return -1;

    // Use general category for comprehensive zero-width detection
    const gc = uucode.get(.general_category, cp);
    switch (gc) {
        .mark_nonspacing, .mark_enclosing => return 0,
        else => {},
    }

    // Additional zero-width characters not covered by general category
    if (cp == 0x00ad) return 0; // soft hyphen
    if (cp == 0x200b) return 0; // zero-width space
    if (cp == 0x200c) return 0; // zero-width non-joiner
    if (cp == 0x200d) return 0; // zero-width joiner
    if (cp == 0x2060) return 0; // word joiner
    if (cp == 0x034f) return 0; // combining grapheme joiner
    if (cp == 0xfeff) return 0; // zero-width no-break space (BOM)
    if (cp >= 0x180b and cp <= 0x180d) return 0; // Mongolian variation selectors
    if (cp >= 0xfe00 and cp <= 0xfe0f) return 0; // variation selectors
    if (cp >= 0xe0100 and cp <= 0xe01ef) return 0; // Plane-14 variation selectors

    // East Asian Width: fullwidth or wide = 2
    // ambiguous in East Asian context = 2, otherwise 1
    // halfwidth, narrow, or neutral = 1
    return switch (eaw) {
        .fullwidth, .wide => 2,
        else => 1,
    };
}

/// returns the width of the provided string, as measured by the method chosen
pub fn gwidth(str: []const u8, method: Method) u16 {
    switch (method) {
        .unicode => {
            var total: u16 = 0;
            var grapheme_iter = uucode.grapheme.Iterator(uucode.utf8.Iterator).init(.init(str));

            while (grapheme_iter.nextGrapheme()) |grapheme| {
                const grapheme_bytes = str[grapheme.start..grapheme.end];

                // Calculate grapheme width
                var g_iter = uucode.utf8.Iterator.init(grapheme_bytes);
                var width: i16 = 0;
                var has_emoji_vs: bool = false;
                var has_text_vs: bool = false;
                var has_emoji_base: bool = false;
                var has_emoji_presentation: bool = false;
                var previous_is_emoji_base: bool = false;
                var ri_count: u8 = 0;

                while (g_iter.next()) |cp| {
                    // Check for emoji variation selector (U+FE0F)
                    if (cp == 0xfe0f) {
                        has_emoji_vs = has_emoji_vs or previous_is_emoji_base;
                        previous_is_emoji_base = false;
                        continue;
                    }

                    // Check for text variation selector (U+FE0E)
                    if (cp == 0xfe0e) {
                        has_text_vs = has_text_vs or previous_is_emoji_base;
                        previous_is_emoji_base = false;
                        continue;
                    }

                    // Presentation selectors only affect emoji-capable bases.
                    const is_emoji_base = uucode.get(.is_emoji_vs_base, cp);
                    if (is_emoji_base) {
                        has_emoji_base = true;
                    }

                    // Check if this codepoint has emoji presentation
                    if (uucode.get(.is_emoji_presentation, cp)) {
                        has_emoji_presentation = true;
                    }

                    // Count regional indicators (for flag emojis)
                    if (cp >= 0x1F1E6 and cp <= 0x1F1FF) {
                        ri_count += 1;
                    }

                    const eaw = uucode.get(.east_asian_width, cp);
                    const w = eawToWidth(cp, eaw);
                    // Take max of non-zero widths
                    if (w > 0 and w > width) width = w;
                    previous_is_emoji_base = is_emoji_base;
                }

                // Handle variation selectors and emoji presentation
                if (has_text_vs and has_emoji_base) {
                    // Text presentation explicit - keep width as-is (usually 1)
                    width = @max(1, width);
                } else if ((has_emoji_vs and has_emoji_base) or has_emoji_presentation or ri_count == 2) {
                    // Emoji presentation or flag pair - force width 2
                    width = @max(2, width);
                }

                total +|= @intCast(@max(0, width));
            }

            return total;
        },
        .wcwidth => {
            var total: u16 = 0;
            var iter = uucode.utf8.Iterator.init(str);
            while (iter.next()) |cp| {
                const w: i16 = switch (cp) {
                    // undo an override in zg for emoji skintone selectors
                    0x1f3fb...0x1f3ff => 2,
                    else => blk: {
                        const eaw = uucode.get(.east_asian_width, cp);
                        break :blk eawToWidth(cp, eaw);
                    },
                };
                total +|= @intCast(@max(0, w));
            }
            return total;
        },
        .no_zwj => {
            var iter = std.mem.splitSequence(u8, str, "\u{200D}");
            var result: u16 = 0;
            while (iter.next()) |s| {
                result +|= gwidth(s, .unicode);
            }
            return result;
        },
    }
}

test "gwidth: a" {
    try testing.expectEqual(1, gwidth("a", .unicode));
    try testing.expectEqual(1, gwidth("a", .wcwidth));
    try testing.expectEqual(1, gwidth("a", .no_zwj));
}

test "gwidth: emoji with ZWJ" {
    try testing.expectEqual(2, gwidth("👩‍🚀", .unicode));
    try testing.expectEqual(4, gwidth("👩‍🚀", .wcwidth));
    try testing.expectEqual(4, gwidth("👩‍🚀", .no_zwj));
}

test "gwidth: emoji with VS16 selector" {
    try testing.expectEqual(2, gwidth("\xE2\x9D\xA4\xEF\xB8\x8F", .unicode));
    try testing.expectEqual(1, gwidth("\xE2\x9D\xA4\xEF\xB8\x8F", .wcwidth));
    try testing.expectEqual(2, gwidth("\xE2\x9D\xA4\xEF\xB8\x8F", .no_zwj));
}

test "gwidth: emoji with skin tone selector" {
    try testing.expectEqual(2, gwidth("👋🏿", .unicode));
    try testing.expectEqual(4, gwidth("👋🏿", .wcwidth));
    try testing.expectEqual(2, gwidth("👋🏿", .no_zwj));
}

test "gwidth: zero-width space" {
    try testing.expectEqual(0, gwidth("\u{200B}", .unicode));
    try testing.expectEqual(0, gwidth("\u{200B}", .wcwidth));
}

test "gwidth: zero-width non-joiner" {
    try testing.expectEqual(0, gwidth("\u{200C}", .unicode));
    try testing.expectEqual(0, gwidth("\u{200C}", .wcwidth));
}

test "gwidth: combining marks" {
    // Hebrew combining mark
    try testing.expectEqual(0, gwidth("\u{05B0}", .unicode));
    // Devanagari combining mark
    try testing.expectEqual(0, gwidth("\u{093C}", .unicode));
}

test "gwidth: flag emoji (regional indicators)" {
    // US flag 🇺🇸
    try testing.expectEqual(2, gwidth("🇺🇸", .unicode));
    // UK flag 🇬🇧
    try testing.expectEqual(2, gwidth("🇬🇧", .unicode));
}

test "gwidth: text variation selector" {
    // U+2764 (heavy black heart) + U+FE0E (text variation selector)
    // Should be width 1 with text presentation
    try testing.expectEqual(1, gwidth("❤︎", .unicode));
}

test "gwidth: variation selectors require an emoji base" {
    try testing.expectEqual(0, gwidth("\u{FE0E}", .unicode));
    try testing.expectEqual(0, gwidth("\u{FE0F}", .unicode));
    try testing.expectEqual(1, gwidth("A\u{FE0F}", .unicode));
}

test "gwidth: variation selectors apply only to the adjacent emoji base" {
    // The combining mark breaks adjacency, so VS16 must not promote the
    // preceding text-default heart to emoji presentation.
    try testing.expectEqual(1, gwidth("\u{2764}\u{0301}\u{FE0F}", .unicode));

    // The adjacent VS16 promotes the heart. A later VS15 following a
    // combining mark must not demote that earlier, valid presentation choice.
    try testing.expectEqual(2, gwidth("\u{2764}\u{FE0F}\u{0301}\u{FE0E}", .unicode));
}

test "gwidth: keycap sequence" {
    // Digit 1 + U+FE0F + U+20E3 (combining enclosing keycap)
    // Should be width 2
    try testing.expectEqual(2, gwidth("1️⃣", .unicode));
}

test "gwidth: base letter with combining mark" {
    // 'a' + combining acute accent (NFD form)
    // Should be width 1 (combining mark is zero-width)
    try testing.expectEqual(1, gwidth("á", .unicode));
}

test "gwidth: malformed utf8 before combining mark" {
    try testing.expectEqual(1, gwidth("\xff\xcc\x81", .unicode));
}

test "gwidth: saturates at the public return width" {
    const over_max: [@as(usize, std.math.maxInt(u16)) + 1]u8 = @splat('a');
    const at_max = over_max[0..std.math.maxInt(u16)];

    try testing.expectEqual(std.math.maxInt(u16), gwidth(at_max, .unicode));
    try testing.expectEqual(std.math.maxInt(u16), gwidth(&over_max, .unicode));
    try testing.expectEqual(std.math.maxInt(u16), gwidth(at_max, .wcwidth));
    try testing.expectEqual(std.math.maxInt(u16), gwidth(&over_max, .wcwidth));
    try testing.expectEqual(std.math.maxInt(u16), gwidth(at_max, .no_zwj));
    try testing.expectEqual(std.math.maxInt(u16), gwidth(&over_max, .no_zwj));
}

test "gwidth: no_zwj saturates across individually bounded segments" {
    const segment: [32768]u8 = @splat('a');
    const joined = segment ++ "\u{200D}" ++ segment;

    try testing.expectEqual(@as(u16, 32768), gwidth(&segment, .unicode));
    try testing.expectEqual(std.math.maxInt(u16), gwidth(joined, .no_zwj));
}

test "cell width clamps a long valid grapheme" {
    const long_grapheme = blk: {
        var bytes: [1 + 3 * 300]u8 = undefined;
        bytes[0] = 'a';
        for (0..300) |index| {
            const offset = 1 + 3 * index;
            bytes[offset] = 0xE0;
            bytes[offset + 1] = 0xA4;
            bytes[offset + 2] = 0xBE;
        }
        break :blk bytes;
    };
    var grapheme_iter = uucode.grapheme.Iterator(uucode.utf8.Iterator).init(.init(&long_grapheme));
    const grapheme = grapheme_iter.nextGrapheme().?;
    try testing.expectEqual(@as(usize, 0), grapheme.start);
    try testing.expectEqual(long_grapheme.len, grapheme.end);
    try testing.expectEqual(null, grapheme_iter.nextGrapheme());

    const measured = gwidth(&long_grapheme, .wcwidth);
    try testing.expect(measured > std.math.maxInt(u8));
    try testing.expectEqual(std.math.maxInt(u8), cellWidth(measured));
    try testing.expectEqual(@as(u8, 0), cellWidth(0));
}

test {
    std.testing.refAllDecls(@This());
}
