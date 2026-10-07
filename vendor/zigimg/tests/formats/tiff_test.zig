const helpers = @import("../helpers.zig");
const std = @import("std");
const tiff = zigimg.formats.tiff;
const zigimg = @import("zigimg");

const test_io = std.testing.io;

test "TIFF inline tag values validate type and preserve both SHORT values" {
    var read_stream = zigimg.io.ReadStream.initMemory(&.{0});

    const little_tag = tiff.TagField{
        .data_type = 3,
        .data_count = 2,
        .data_offset = 0x2222_1111,
    };
    const little_values = try little_tag.readTagData(std.testing.allocator, &read_stream, .little);
    defer std.testing.allocator.free(little_values);
    try std.testing.expectEqualSlices(u32, &.{ 0x1111, 0x2222 }, little_values);

    const little_single_tag = tiff.TagField{
        .data_type = 3,
        .data_count = 1,
        .data_offset = 0xAAAA_1234,
    };
    const little_single = try little_single_tag.readTagData(std.testing.allocator, &read_stream, .little);
    defer std.testing.allocator.free(little_single);
    try std.testing.expectEqualSlices(u32, &.{0x1234}, little_single);

    const big_tag = tiff.TagField{
        .data_type = 3,
        .data_count = 2,
        .data_offset = 0x1111_2222,
    };
    const big_values = try big_tag.readTagData(std.testing.allocator, &read_stream, .big);
    defer std.testing.allocator.free(big_values);
    try std.testing.expectEqualSlices(u32, &.{ 0x1111, 0x2222 }, big_values);

    const big_single_tag = tiff.TagField{
        .data_type = 3,
        .data_count = 1,
        .data_offset = 0x1234_AAAA,
    };
    const big_single = try big_single_tag.readTagData(std.testing.allocator, &read_stream, .big);
    defer std.testing.allocator.free(big_single);
    try std.testing.expectEqualSlices(u32, &.{0x1234}, big_single);

    const invalid_tag = tiff.TagField{
        .data_type = 99,
        .data_count = 1,
        .data_offset = 0,
    };
    try std.testing.expectError(error.InvalidData, invalid_tag.readTagData(std.testing.allocator, &read_stream, .little));
}

test "TIFF tag data rejects empty and truncated values" {
    var read_stream = zigimg.io.ReadStream.initMemory(&.{ 0, 0, 0, 0 });

    const empty_tag = tiff.TagField{
        .data_type = 4,
        .data_count = 0,
        .data_offset = 0,
    };
    try std.testing.expectError(error.InvalidData, empty_tag.readTagData(std.testing.allocator, &read_stream, .little));

    const truncated_tag = tiff.TagField{
        .data_type = 4,
        .data_count = 2,
        .data_offset = 0,
    };
    if (truncated_tag.readTagData(std.testing.allocator, &read_stream, .little)) |values| {
        defer std.testing.allocator.free(values);
        return error.TestUnexpectedResult;
    } else |_| {}
}

test "TIFF scalar tag readers validate type and count" {
    const short_tag = tiff.TagField{
        .data_type = 3,
        .data_count = 1,
        .data_offset = 0xCAFE_1234,
    };
    try std.testing.expectEqual(@as(u16, 0x1234), try short_tag.toShort(.little));
    try std.testing.expectEqual(@as(u32, 0x1234), try short_tag.toLongOrShort(.little));

    const long_tag = tiff.TagField{
        .data_type = 4,
        .data_count = 1,
        .data_offset = 0xCAFE_1234,
    };
    try std.testing.expectEqual(@as(u32, 0xCAFE_1234), try long_tag.toLong());
    try std.testing.expectEqual(@as(u32, 0xCAFE_1234), try long_tag.toLongOrShort(.little));
    try std.testing.expectError(error.InvalidData, long_tag.toShort(.little));

    const repeated_short = tiff.TagField{
        .data_type = 3,
        .data_count = 2,
        .data_offset = 0,
    };
    try std.testing.expectError(error.InvalidData, repeated_short.toShort(.little));
    try std.testing.expectError(error.InvalidData, repeated_short.toLongOrShort(.little));

    var read_stream = zigimg.io.ReadStream.initMemory(&.{0});
    try std.testing.expectError(error.InvalidData, short_tag.readRational(&read_stream, .little));
}

test "TIFF row and strip metadata rejects unsafe shapes" {
    var pixels_buffer: [2]zigimg.color.Grayscale8 = undefined;
    var pixels = zigimg.color.PixelStorage{ .grayscale8 = pixels_buffer[0..] };
    var the_tiff = tiff.TIFF{ .bitmap = tiff.BitmapDescriptor{} };
    the_tiff.bitmap.image_width = 2;
    the_tiff.bitmap.image_height = 1;
    the_tiff.bitmap.bits_per_sample.resize(1);
    the_tiff.bitmap.bits_per_sample.data[0] = 8;

    var read_stream = zigimg.io.ReadStream.initMemory(&.{0});
    try std.testing.expectError(error.InvalidData, the_tiff.readStrips(std.testing.allocator, &read_stream, &pixels));

    the_tiff.bitmap.rows_per_strip = 1;
    try std.testing.expectError(error.InvalidData, the_tiff.readStrips(std.testing.allocator, &read_stream, &pixels));

    var byte_counts = [_]u32{1};
    var offsets = [_]u32{0};
    the_tiff.bitmap.strip_byte_counts = byte_counts[0..];
    the_tiff.bitmap.strip_offsets = offsets[0..];
    try std.testing.expectError(error.InvalidData, the_tiff.readStrips(std.testing.allocator, &read_stream, &pixels));

    the_tiff.bitmap.image_width = 1;
    the_tiff.bitmap.image_height = 2;
    try std.testing.expectError(error.InvalidData, the_tiff.readStrips(std.testing.allocator, &read_stream, &pixels));

    the_tiff.bitmap.image_width = 9;
    the_tiff.bitmap.image_height = 1;
    the_tiff.bitmap.bits_per_sample.data[0] = 1;
    try std.testing.expectEqual(@as(usize, 2), try the_tiff.calRowByteSize());

    the_tiff.bitmap.samples_per_pixel = 2;
    try std.testing.expectError(error.InvalidData, the_tiff.calRowByteSize());
}

test "TIFF 1-bit strips ignore padding at each row boundary" {
    const encoded = [_]u8{
        0b1010_1010, 0b1111_1111,
        0b0101_0101, 0b0000_0000,
    };
    var byte_counts = [_]u32{encoded.len};
    var offsets = [_]u32{0};
    var the_tiff = tiff.TIFF{ .bitmap = tiff.BitmapDescriptor{
        .image_width = 9,
        .image_height = 2,
        .photometric_interpretation = 1,
        .rows_per_strip = 2,
        .strip_offsets = offsets[0..],
        .strip_byte_counts = byte_counts[0..],
    } };
    the_tiff.bitmap.bits_per_sample.resize(1);
    the_tiff.bitmap.bits_per_sample.data[0] = 1;

    var pixel_buffer: [18]zigimg.color.Grayscale1 = undefined;
    var pixels = zigimg.color.PixelStorage{ .grayscale1 = pixel_buffer[0..] };
    var read_stream = zigimg.io.ReadStream.initMemory(&encoded);
    try the_tiff.readStrips(std.testing.allocator, &read_stream, &pixels);

    const expected = [_]u1{
        1, 0, 1, 0, 1, 0, 1, 0, 1,
        0, 1, 0, 1, 0, 1, 0, 1, 0,
    };
    for (pixel_buffer, expected) |actual, wanted| {
        try std.testing.expectEqual(wanted, actual.value);
    }
}

test "Should error on non TIFF images" {
    const file = try helpers.testOpenFile(test_io, helpers.fixtures_path ++ "bmp/simple_v4.bmp");
    defer file.close(test_io);

    var read_buffer: [zigimg.io.DEFAULT_BUFFER_SIZE]u8 = undefined;
    var read_stream = zigimg.io.ReadStream.initFile(test_io, file, read_buffer[0..]);

    var sgi_file = tiff.TIFF{};

    const invalid_file = sgi_file.read(helpers.zigimg_test_allocator, &read_stream);
    try helpers.expectError(invalid_file, zigimg.Image.ReadError.InvalidData);
}

test "TIFF/LE monochrome black uncompressed" {
    const file = try helpers.testOpenFile(test_io, helpers.fixtures_path ++ "tiff/sample-monob-raw.tiff");
    defer file.close(test_io);

    var the_tiff = tiff.TIFF{};

    var read_buffer: [zigimg.io.DEFAULT_BUFFER_SIZE]u8 = undefined;
    var read_stream = zigimg.io.ReadStream.initFile(test_io, file, read_buffer[0..]);

    const pixels = try the_tiff.read(helpers.zigimg_test_allocator, &read_stream);
    defer pixels.deinit(helpers.zigimg_test_allocator);

    try helpers.expectEq(the_tiff.width(), 640);
    try helpers.expectEq(the_tiff.height(), 426);
    try std.testing.expect(pixels == .grayscale1);

    try helpers.expectEq(pixels.grayscale1[0].value, 1);
    try helpers.expectEq(pixels.grayscale1[2].value, 0);
    try helpers.expectEq(pixels.grayscale1[15 * 8 + 7].value, 0);
}

test "TIFF/LE grayscale8 uncompressed" {
    const file = try helpers.testOpenFile(test_io, helpers.fixtures_path ++ "tiff/sample-grayscale8-raw.tiff");
    defer file.close(test_io);

    var the_tiff = tiff.TIFF{};

    var read_buffer: [zigimg.io.DEFAULT_BUFFER_SIZE]u8 = undefined;
    var read_stream = zigimg.io.ReadStream.initFile(test_io, file, read_buffer[0..]);

    const pixels = try the_tiff.read(helpers.zigimg_test_allocator, &read_stream);
    defer pixels.deinit(helpers.zigimg_test_allocator);

    try helpers.expectEq(the_tiff.width(), 128);
    try helpers.expectEq(the_tiff.height(), 128);
    try std.testing.expect(pixels == .grayscale8);

    try helpers.expectEq(pixels.grayscale8[0].value, 76);
    try helpers.expectEq(pixels.grayscale8[8].value, 149);
    try helpers.expectEq(pixels.grayscale8[90].value, 0);
    try helpers.expectEq(pixels.grayscale8[128 * 66 + 72].value, 149);
}

test "TIFF/LE 8-bit with colormap uncompressed" {
    const file = try helpers.testOpenFile(test_io, helpers.fixtures_path ++ "tiff/sample-pal8-raw.tiff");
    defer file.close(test_io);

    var the_tiff = tiff.TIFF{};

    var read_buffer: [zigimg.io.DEFAULT_BUFFER_SIZE]u8 = undefined;
    var read_stream = zigimg.io.ReadStream.initFile(test_io, file, read_buffer[0..]);

    const pixels = try the_tiff.read(helpers.zigimg_test_allocator, &read_stream);
    defer pixels.deinit(helpers.zigimg_test_allocator);

    try helpers.expectEq(the_tiff.width(), 128);
    try helpers.expectEq(the_tiff.height(), 128);
    try std.testing.expect(pixels == .indexed8);

    const palette64 = pixels.indexed8.palette[64];

    try helpers.expectEq(palette64.r, 255);
    try helpers.expectEq(palette64.g, 0);
    try helpers.expectEq(palette64.b, 0);

    try helpers.expectEq(pixels.indexed8.indices[0], 64);
    try helpers.expectEq(pixels.indexed8.indices[12], 128);
}

test "TIFF/LE 24-bit uncompressed" {
    const file = try helpers.testOpenFile(test_io, helpers.fixtures_path ++ "tiff/sample-rgb24-raw.tiff");
    defer file.close(test_io);

    var the_tiff = tiff.TIFF{};

    var read_buffer: [zigimg.io.DEFAULT_BUFFER_SIZE]u8 = undefined;
    var read_stream = zigimg.io.ReadStream.initFile(test_io, file, read_buffer[0..]);

    const pixels = try the_tiff.read(helpers.zigimg_test_allocator, &read_stream);
    defer pixels.deinit(helpers.zigimg_test_allocator);

    try helpers.expectEq(the_tiff.width(), 664);
    try helpers.expectEq(the_tiff.height(), 248);
    try std.testing.expect(pixels == .rgb24);

    const indexes = [_]usize{ 8_754, 43_352, 42_224 };
    const expected_colors = [_]u32{
        0x21282e,
        0xe4ad38,
        0xffffff,
    };

    for (expected_colors, indexes) |hex_color, index| {
        try helpers.expectEq(pixels.rgb24[index].to.u32Rgb(), hex_color);
    }
}

test "TIFF/BE rgb24 gray single strip uncompressed" {
    const file = try helpers.testOpenFile(test_io, helpers.fixtures_path ++ "tiff/big-endian/sample-rgb24-single-strip.tiff");
    defer file.close(test_io);

    var the_tiff = tiff.TIFF{};

    var read_buffer: [zigimg.io.DEFAULT_BUFFER_SIZE]u8 = undefined;
    var read_stream = zigimg.io.ReadStream.initFile(test_io, file, read_buffer[0..]);

    const pixels = try the_tiff.read(helpers.zigimg_test_allocator, &read_stream);
    defer pixels.deinit(helpers.zigimg_test_allocator);

    try helpers.expectEq(the_tiff.width(), 128);
    try helpers.expectEq(the_tiff.height(), 128);
    try std.testing.expect(pixels == .rgb24);

    const indexes = [_]usize{ 0, 12, 24 };
    const expected_colors = [_]u32{
        0x4c4c4c,
        0x959595,
        0x0,
    };

    for (expected_colors, indexes) |hex_color, index| {
        try helpers.expectEq(pixels.rgb24[index].to.u32Rgb(), hex_color);
    }
}

test "TIFF/BE rgb24 color single strip uncompressed" {
    const file = try helpers.testOpenFile(test_io, helpers.fixtures_path ++ "tiff/big-endian/sample-pal8-raw.tiff");
    defer file.close(test_io);

    var the_tiff = tiff.TIFF{};

    var read_buffer: [zigimg.io.DEFAULT_BUFFER_SIZE]u8 = undefined;
    var read_stream = zigimg.io.ReadStream.initFile(test_io, file, read_buffer[0..]);

    const pixels = try the_tiff.read(helpers.zigimg_test_allocator, &read_stream);
    defer pixels.deinit(helpers.zigimg_test_allocator);

    try helpers.expectEq(the_tiff.width(), 128);
    try helpers.expectEq(the_tiff.height(), 128);
    try std.testing.expect(pixels == .rgb24);

    const indexes = [_]usize{ 0, 12, 24 };
    const expected_colors = [_]u32{
        0xff021d,
        0xff37,
        0x0,
    };

    for (expected_colors, indexes) |hex_color, index| {
        try helpers.expectEq(pixels.rgb24[index].to.u32Rgb(), hex_color);
    }
}

test "TIFF/BE 24-bit uncompressed" {
    const file = try helpers.testOpenFile(test_io, helpers.fixtures_path ++ "tiff/big-endian/sample-rgb24-raw.tiff");
    defer file.close(test_io);

    var the_tiff = tiff.TIFF{};

    var read_buffer: [zigimg.io.DEFAULT_BUFFER_SIZE]u8 = undefined;
    var read_stream = zigimg.io.ReadStream.initFile(test_io, file, read_buffer[0..]);

    const pixels = try the_tiff.read(helpers.zigimg_test_allocator, &read_stream);
    defer pixels.deinit(helpers.zigimg_test_allocator);

    try helpers.expectEq(the_tiff.width(), 664);
    try helpers.expectEq(the_tiff.height(), 248);
    try std.testing.expect(pixels == .rgb24);

    const indexes = [_]usize{ 8_754, 43_352, 42_224 };
    const expected_colors = [_]u32{
        0x21282e,
        0xe4ad38,
        0xffffff,
    };

    for (expected_colors, indexes) |hex_color, index| {
        try helpers.expectEq(pixels.rgb24[index].to.u32Rgb(), hex_color);
    }
}

test "TIFF/LE RGBA uncompressed" {
    const file = try helpers.testOpenFile(test_io, helpers.fixtures_path ++ "tiff/sample-rgba-raw.tiff");
    defer file.close(test_io);

    var the_tiff = tiff.TIFF{};

    var read_buffer: [zigimg.io.DEFAULT_BUFFER_SIZE]u8 = undefined;
    var read_stream = zigimg.io.ReadStream.initFile(test_io, file, read_buffer[0..]);

    const pixels = try the_tiff.read(helpers.zigimg_test_allocator, &read_stream);
    defer pixels.deinit(helpers.zigimg_test_allocator);

    try helpers.expectEq(the_tiff.width(), 32);
    try helpers.expectEq(the_tiff.height(), 32);
    try std.testing.expect(pixels == .rgba32);

    const indexes = [_]usize{ 100, 1000, 1018 };
    const expected_colors = [_]u32{ 0xf6ff00, 0xbe0042, 0x2900d7 };

    for (expected_colors, indexes) |hex_color, index| {
        try helpers.expectEq(pixels.rgba32[index].to.u32Rgb(), hex_color);
    }
}

test "TIFF/LE monochrome black packbits" {
    const file = try helpers.testOpenFile(test_io, helpers.fixtures_path ++ "tiff/sample-monob-packbits.tiff");
    defer file.close(test_io);

    var the_tiff = tiff.TIFF{};

    var read_buffer: [zigimg.io.DEFAULT_BUFFER_SIZE]u8 = undefined;
    var read_stream = zigimg.io.ReadStream.initFile(test_io, file, read_buffer[0..]);

    const pixels = try the_tiff.read(helpers.zigimg_test_allocator, &read_stream);
    defer pixels.deinit(helpers.zigimg_test_allocator);

    try helpers.expectEq(the_tiff.width(), 640);
    try helpers.expectEq(the_tiff.height(), 426);
    try std.testing.expect(pixels == .grayscale1);

    try helpers.expectEq(pixels.grayscale1[0].value, 1);
    try helpers.expectEq(pixels.grayscale1[2].value, 0);
    try helpers.expectEq(pixels.grayscale1[15 * 8 + 7].value, 0);
}

test "TIFF/LE grayscale8 packbits" {
    const file = try helpers.testOpenFile(test_io, helpers.fixtures_path ++ "tiff/sample-grayscale8-packbits.tiff");
    defer file.close(test_io);

    var the_tiff = tiff.TIFF{};

    var read_buffer: [zigimg.io.DEFAULT_BUFFER_SIZE]u8 = undefined;
    var read_stream = zigimg.io.ReadStream.initFile(test_io, file, read_buffer[0..]);

    const pixels = try the_tiff.read(helpers.zigimg_test_allocator, &read_stream);
    defer pixels.deinit(helpers.zigimg_test_allocator);

    try helpers.expectEq(the_tiff.width(), 128);
    try helpers.expectEq(the_tiff.height(), 128);
    try std.testing.expect(pixels == .grayscale8);

    try helpers.expectEq(pixels.grayscale8[0].value, 76);
    try helpers.expectEq(pixels.grayscale8[8].value, 149);
    try helpers.expectEq(pixels.grayscale8[90].value, 0);
    try helpers.expectEq(pixels.grayscale8[128 * 66 + 72].value, 149);
}

test "TIFF/LE 8-bit with colormap packbits" {
    const file = try helpers.testOpenFile(test_io, helpers.fixtures_path ++ "tiff/sample-pal8-packbits.tiff");
    defer file.close(test_io);

    var the_tiff = tiff.TIFF{};

    var read_buffer: [zigimg.io.DEFAULT_BUFFER_SIZE]u8 = undefined;
    var read_stream = zigimg.io.ReadStream.initFile(test_io, file, read_buffer[0..]);

    const pixels = try the_tiff.read(helpers.zigimg_test_allocator, &read_stream);
    defer pixels.deinit(helpers.zigimg_test_allocator);

    try helpers.expectEq(the_tiff.width(), 128);
    try helpers.expectEq(the_tiff.height(), 128);
    try std.testing.expect(pixels == .indexed8);

    const palette64 = pixels.indexed8.palette[64];

    try helpers.expectEq(palette64.r, 255);
    try helpers.expectEq(palette64.g, 0);
    try helpers.expectEq(palette64.b, 0);

    try helpers.expectEq(pixels.indexed8.indices[0], 64);
    try helpers.expectEq(pixels.indexed8.indices[12], 128);
}

test "TIFF/LE 24-bit packbits" {
    const file = try helpers.testOpenFile(test_io, helpers.fixtures_path ++ "tiff/sample-rgb24-packbits.tiff");
    defer file.close(test_io);

    var the_tiff = tiff.TIFF{};

    var read_buffer: [zigimg.io.DEFAULT_BUFFER_SIZE]u8 = undefined;
    var read_stream = zigimg.io.ReadStream.initFile(test_io, file, read_buffer[0..]);

    const pixels = try the_tiff.read(helpers.zigimg_test_allocator, &read_stream);
    defer pixels.deinit(helpers.zigimg_test_allocator);

    try helpers.expectEq(the_tiff.width(), 664);
    try helpers.expectEq(the_tiff.height(), 248);
    try std.testing.expect(pixels == .rgb24);

    const indexes = [_]usize{ 8_754, 43_352, 42_224 };
    const expected_colors = [_]u32{
        0x21282e,
        0xe4ad38,
        0xffffff,
    };

    for (expected_colors, indexes) |hex_color, index| {
        try helpers.expectEq(pixels.rgb24[index].to.u32Rgb(), hex_color);
    }
}

test "TIFF/LE RGBA packbits" {
    const file = try helpers.testOpenFile(test_io, helpers.fixtures_path ++ "tiff/sample-rgba-packbits.tiff");
    defer file.close(test_io);

    var the_tiff = tiff.TIFF{};

    var read_buffer: [zigimg.io.DEFAULT_BUFFER_SIZE]u8 = undefined;
    var read_stream = zigimg.io.ReadStream.initFile(test_io, file, read_buffer[0..]);

    const pixels = try the_tiff.read(helpers.zigimg_test_allocator, &read_stream);
    defer pixels.deinit(helpers.zigimg_test_allocator);

    try helpers.expectEq(the_tiff.width(), 32);
    try helpers.expectEq(the_tiff.height(), 32);
    try std.testing.expect(pixels == .rgba32);

    const indexes = [_]usize{ 100, 1000, 1018 };
    const expected_colors = [_]u32{ 0xf6ff00, 0xbe0042, 0x2900d7 };

    for (expected_colors, indexes) |hex_color, index| {
        try helpers.expectEq(pixels.rgba32[index].to.u32Rgb(), hex_color);
    }
}

test "TIFF/LE monochrome black CCITT" {
    const file = try helpers.testOpenFile(test_io, helpers.fixtures_path ++ "tiff/ccitt_rle.tiff");
    defer file.close(test_io);

    var the_tiff = tiff.TIFF{};

    var read_buffer: [zigimg.io.DEFAULT_BUFFER_SIZE]u8 = undefined;
    var read_stream = zigimg.io.ReadStream.initFile(test_io, file, read_buffer[0..]);

    const pixels = try the_tiff.read(helpers.zigimg_test_allocator, &read_stream);
    defer pixels.deinit(helpers.zigimg_test_allocator);

    try helpers.expectEq(the_tiff.width(), 400);
    try helpers.expectEq(the_tiff.height(), 300);
    try std.testing.expect(pixels == .grayscale1);

    try helpers.expectEq(pixels.grayscale1[0].value, 1);
    try helpers.expectEq(pixels.grayscale1[73 * 400 + 48].value, 0);
}

test "TIFF/LE monochrome black LZW" {
    const file = try helpers.testOpenFile(test_io, helpers.fixtures_path ++ "tiff/sample-monob-lzw.tiff");
    defer file.close(test_io);

    var the_tiff = tiff.TIFF{};

    var read_buffer: [zigimg.io.DEFAULT_BUFFER_SIZE]u8 = undefined;
    var read_stream = zigimg.io.ReadStream.initFile(test_io, file, read_buffer[0..]);

    const pixels = try the_tiff.read(helpers.zigimg_test_allocator, &read_stream);
    defer pixels.deinit(helpers.zigimg_test_allocator);

    try helpers.expectEq(the_tiff.width(), 640);
    try helpers.expectEq(the_tiff.height(), 426);
    try std.testing.expect(pixels == .grayscale1);

    try helpers.expectEq(pixels.grayscale1[0].value, 1);
    try helpers.expectEq(pixels.grayscale1[2].value, 0);
    try helpers.expectEq(pixels.grayscale1[15 * 8 + 7].value, 0);
}

test "TIFF/LE grayscale8 LZW" {
    const file = try helpers.testOpenFile(test_io, helpers.fixtures_path ++ "tiff/sample-grayscale8-lzw.tiff");
    defer file.close(test_io);

    var the_tiff = tiff.TIFF{};

    var read_buffer: [zigimg.io.DEFAULT_BUFFER_SIZE]u8 = undefined;
    var read_stream = zigimg.io.ReadStream.initFile(test_io, file, read_buffer[0..]);

    const pixels = try the_tiff.read(helpers.zigimg_test_allocator, &read_stream);
    defer pixels.deinit(helpers.zigimg_test_allocator);

    try helpers.expectEq(the_tiff.width(), 128);
    try helpers.expectEq(the_tiff.height(), 128);
    try std.testing.expect(pixels == .grayscale8);

    try helpers.expectEq(pixels.grayscale8[0].value, 76);
    try helpers.expectEq(pixels.grayscale8[8].value, 149);
    try helpers.expectEq(pixels.grayscale8[90].value, 0);
    try helpers.expectEq(pixels.grayscale8[128 * 66 + 72].value, 149);
}

test "TIFF/LE 8-bit with colormap LZW" {
    const file = try helpers.testOpenFile(test_io, helpers.fixtures_path ++ "tiff/sample-pal8-lzw.tiff");
    defer file.close(test_io);

    var the_tiff = tiff.TIFF{};

    var read_buffer: [zigimg.io.DEFAULT_BUFFER_SIZE]u8 = undefined;
    var read_stream = zigimg.io.ReadStream.initFile(test_io, file, read_buffer[0..]);

    const pixels = try the_tiff.read(helpers.zigimg_test_allocator, &read_stream);
    defer pixels.deinit(helpers.zigimg_test_allocator);

    try helpers.expectEq(the_tiff.width(), 128);
    try helpers.expectEq(the_tiff.height(), 128);
    try std.testing.expect(pixels == .indexed8);

    const palette64 = pixels.indexed8.palette[64];

    try helpers.expectEq(palette64.r, 255);
    try helpers.expectEq(palette64.g, 0);
    try helpers.expectEq(palette64.b, 0);

    try helpers.expectEq(pixels.indexed8.indices[0], 64);
    try helpers.expectEq(pixels.indexed8.indices[12], 128);
}

test "TIFF/LE 24-bit LZW" {
    const file = try helpers.testOpenFile(test_io, helpers.fixtures_path ++ "tiff/sample-rgb24-lzw.tiff");
    defer file.close(test_io);

    var the_tiff = tiff.TIFF{};

    var read_buffer: [zigimg.io.DEFAULT_BUFFER_SIZE]u8 = undefined;
    var read_stream = zigimg.io.ReadStream.initFile(test_io, file, read_buffer[0..]);

    const pixels = try the_tiff.read(helpers.zigimg_test_allocator, &read_stream);
    defer pixels.deinit(helpers.zigimg_test_allocator);

    try helpers.expectEq(the_tiff.width(), 664);
    try helpers.expectEq(the_tiff.height(), 248);
    try std.testing.expect(pixels == .rgb24);

    const indexes = [_]usize{ 8_754, 43_352, 42_224 };
    const expected_colors = [_]u32{
        0x21282e,
        0xe4ad38,
        0xffffff,
    };

    for (expected_colors, indexes) |hex_color, index| {
        try helpers.expectEq(pixels.rgb24[index].to.u32Rgb(), hex_color);
    }
}

test "TIFF/LE RGBA LZW" {
    const file = try helpers.testOpenFile(test_io, helpers.fixtures_path ++ "tiff/sample-rgba-lzw.tiff");
    defer file.close(test_io);

    var the_tiff = tiff.TIFF{};

    var read_buffer: [zigimg.io.DEFAULT_BUFFER_SIZE]u8 = undefined;
    var read_stream = zigimg.io.ReadStream.initFile(test_io, file, read_buffer[0..]);

    const pixels = try the_tiff.read(helpers.zigimg_test_allocator, &read_stream);
    defer pixels.deinit(helpers.zigimg_test_allocator);

    try helpers.expectEq(the_tiff.width(), 32);
    try helpers.expectEq(the_tiff.height(), 32);
    try std.testing.expect(pixels == .rgba32);

    const indexes = [_]usize{ 100, 1000, 1018 };
    const expected_colors = [_]u32{ 0xf6ff00, 0xbe0042, 0x2900d7 };

    for (expected_colors, indexes) |hex_color, index| {
        try helpers.expectEq(pixels.rgba32[index].to.u32Rgb(), hex_color);
    }
}

test "TIFF/LE monochrome black Deflate" {
    const file = try helpers.testOpenFile(test_io, helpers.fixtures_path ++ "tiff/sample-monob-deflate.tiff");
    defer file.close(test_io);

    var the_bitmap = tiff.TIFF{};

    var read_buffer: [zigimg.io.DEFAULT_BUFFER_SIZE]u8 = undefined;
    var read_stream = zigimg.io.ReadStream.initFile(test_io, file, read_buffer[0..]);

    const pixels = try the_bitmap.read(helpers.zigimg_test_allocator, &read_stream);
    defer pixels.deinit(helpers.zigimg_test_allocator);

    try helpers.expectEq(the_bitmap.width(), 640);
    try helpers.expectEq(the_bitmap.height(), 426);
    try std.testing.expect(pixels == .grayscale1);

    try helpers.expectEq(pixels.grayscale1[0].value, 1);
    try helpers.expectEq(pixels.grayscale1[2].value, 0);
    try helpers.expectEq(pixels.grayscale1[15 * 8 + 7].value, 0);
}

test "TIFF/LE grayscale8 Deflate" {
    const file = try helpers.testOpenFile(test_io, helpers.fixtures_path ++ "tiff/sample-grayscale8-deflate.tiff");
    defer file.close(test_io);

    var the_tiff = tiff.TIFF{};

    var read_buffer: [zigimg.io.DEFAULT_BUFFER_SIZE]u8 = undefined;
    var read_stream = zigimg.io.ReadStream.initFile(test_io, file, read_buffer[0..]);

    const pixels = try the_tiff.read(helpers.zigimg_test_allocator, &read_stream);
    defer pixels.deinit(helpers.zigimg_test_allocator);

    try helpers.expectEq(the_tiff.width(), 128);
    try helpers.expectEq(the_tiff.height(), 128);
    try std.testing.expect(pixels == .grayscale8);

    try helpers.expectEq(pixels.grayscale8[0].value, 76);
    try helpers.expectEq(pixels.grayscale8[8].value, 149);
    try helpers.expectEq(pixels.grayscale8[90].value, 0);
    try helpers.expectEq(pixels.grayscale8[128 * 66 + 72].value, 149);
}

test "TIFF/LE 8-bit with colormap Deflate" {
    const file = try helpers.testOpenFile(test_io, helpers.fixtures_path ++ "tiff/sample-pal8-deflate.tiff");
    defer file.close(test_io);

    var the_tiff = tiff.TIFF{};

    var read_buffer: [zigimg.io.DEFAULT_BUFFER_SIZE]u8 = undefined;
    var read_stream = zigimg.io.ReadStream.initFile(test_io, file, read_buffer[0..]);

    const pixels = try the_tiff.read(helpers.zigimg_test_allocator, &read_stream);
    defer pixels.deinit(helpers.zigimg_test_allocator);

    try helpers.expectEq(the_tiff.width(), 128);
    try helpers.expectEq(the_tiff.height(), 128);
    try std.testing.expect(pixels == .indexed8);

    const palette64 = pixels.indexed8.palette[64];

    try helpers.expectEq(palette64.r, 255);
    try helpers.expectEq(palette64.g, 0);
    try helpers.expectEq(palette64.b, 0);

    try helpers.expectEq(pixels.indexed8.indices[0], 64);
    try helpers.expectEq(pixels.indexed8.indices[12], 128);
}

test "TIFF/LE 24-bit Deflate" {
    const file = try helpers.testOpenFile(test_io, helpers.fixtures_path ++ "tiff/sample-rgb24-deflate.tiff");
    defer file.close(test_io);

    var the_tiff = tiff.TIFF{};

    var read_buffer: [zigimg.io.DEFAULT_BUFFER_SIZE]u8 = undefined;
    var read_stream = zigimg.io.ReadStream.initFile(test_io, file, read_buffer[0..]);

    const pixels = try the_tiff.read(helpers.zigimg_test_allocator, &read_stream);
    defer pixels.deinit(helpers.zigimg_test_allocator);

    try helpers.expectEq(the_tiff.width(), 664);
    try helpers.expectEq(the_tiff.height(), 248);
    try std.testing.expect(pixels == .rgb24);

    const indexes = [_]usize{ 8_754, 43_352, 42_224 };
    const expected_colors = [_]u32{
        0x21282e,
        0xe4ad38,
        0xffffff,
    };

    for (expected_colors, indexes) |hex_color, index| {
        try helpers.expectEq(pixels.rgb24[index].to.u32Rgb(), hex_color);
    }
}

test "TIFF/LE RGBA Deflate" {
    const file = try helpers.testOpenFile(test_io, helpers.fixtures_path ++ "tiff/sample-rgba-deflate.tiff");
    defer file.close(test_io);

    var the_tiff = tiff.TIFF{};

    var read_buffer: [zigimg.io.DEFAULT_BUFFER_SIZE]u8 = undefined;
    var read_stream = zigimg.io.ReadStream.initFile(test_io, file, read_buffer[0..]);

    const pixels = try the_tiff.read(helpers.zigimg_test_allocator, &read_stream);
    defer pixels.deinit(helpers.zigimg_test_allocator);

    try helpers.expectEq(the_tiff.width(), 32);
    try helpers.expectEq(the_tiff.height(), 32);
    try std.testing.expect(pixels == .rgba32);

    const indexes = [_]usize{ 100, 1000, 1018 };
    const expected_colors = [_]u32{ 0xf6ff00, 0xbe0042, 0x2900d7 };

    for (expected_colors, indexes) |hex_color, index| {
        try helpers.expectEq(pixels.rgba32[index].to.u32Rgb(), hex_color);
    }
}
