const ccitt = @import("../compressions/ccitt.zig");
const color = @import("../color.zig");
const FormatInterface = @import("../FormatInterface.zig");
const Image = @import("../Image.zig");
const io = @import("../io.zig");
const lzw = @import("../compressions/lzw.zig");
const packbits = @import("../compressions/packbits.zig");
const PixelFormat = @import("../pixel_format.zig").PixelFormat;
const std = @import("std");
const types = @import("tiff/types.zig");
const utils = @import("../utils.zig");

pub const Header = types.Header;
pub const IFD = types.IFD;
pub const BitmapDescriptor = types.BitmapDescriptor;
pub const TagField = types.TagField;

pub const TIFF = struct {
    endianess: std.builtin.Endian = undefined,
    header: Header = undefined,
    // TIFF can have many images but right now
    // we handle only the first one
    ifd: IFD = undefined,
    bitmap: BitmapDescriptor = undefined,

    pub fn width(self: *TIFF) usize {
        return self.bitmap.image_width;
    }

    pub fn height(self: *TIFF) usize {
        return self.bitmap.image_height;
    }

    pub fn formatInterface() FormatInterface {
        return FormatInterface{
            .formatDetect = formatDetect,
            .readImage = readImage,
            .writeImage = writeImage,
        };
    }

    pub fn decodeBitmap(self: *TIFF, allocator: std.mem.Allocator, read_stream: *io.ReadStream) !void {
        const endianess = self.endianess;
        const ifd = self.ifd;
        const tags_map = ifd.tags_map;
        const bitmap = &self.bitmap;

        bitmap.bits_per_sample.resize(1);
        bitmap.bits_per_sample.data[0] = 1;

        var iterator = tags_map.keyIterator();

        while (iterator.next()) |key| {
            const tag: TagField = tags_map.get(key.*).?;
            switch (key.*) {
                .image_width => {
                    bitmap.image_width = try tag.toLongOrShort(endianess);
                },
                .image_height => {
                    bitmap.image_height = try tag.toLongOrShort(endianess);
                },
                .compression => {
                    const value = try tag.toShort(endianess);
                    bitmap.compression = std.enums.fromInt(types.CompressionType, value) orelse return Image.ReadError.InvalidData;
                },
                // Parsed after the unordered tag walk, once bits_per_sample is known.
                .color_map => {},
                .strip_byte_counts => {
                    bitmap.strip_byte_counts = try tag.readTagData(allocator, read_stream, endianess);
                },
                .strip_offsets => {
                    bitmap.strip_offsets = try tag.readTagData(allocator, read_stream, endianess);
                },
                .rows_per_strip => {
                    bitmap.rows_per_strip = try tag.toLongOrShort(endianess);
                },
                .photometric_interpretation => {
                    bitmap.photometric_interpretation = try tag.toShort(endianess);
                },
                .samples_per_pixel => {
                    bitmap.samples_per_pixel = try tag.toShort(endianess);
                },
                .resolution_unit => {
                    const value = try tag.toShort(endianess);
                    bitmap.resolution_unit = std.enums.fromInt(types.ResolutionUnit, value) orelse return Image.ReadError.InvalidData;
                },
                .new_subfile_type => {
                    bitmap.new_subfile_type = try tag.toLong();
                },
                .bits_per_sample => {
                    var bits_per_sample = &bitmap.bits_per_sample;
                    switch (tag.data_count) {
                        1 => {
                            bits_per_sample.resize(1);
                            bits_per_sample.data[0] = try tag.toShort(endianess);
                        },
                        3, 4 => {
                            const components_bits_per_sample = try tag.readTagData(allocator, read_stream, endianess);
                            defer allocator.free(components_bits_per_sample);
                            bits_per_sample.resize(tag.data_count);
                            for (0..tag.data_count) |index| {
                                bits_per_sample.data[index] = @truncate(components_bits_per_sample[index]);
                            }
                        },
                        else => return Image.Error.Unsupported,
                    }
                },
                .extra_samples => {
                    var extra_samples = &bitmap.extra_samples;
                    switch (tag.data_count) {
                        1 => {
                            extra_samples.resize(1);
                            extra_samples.data[0] = try tag.toShort(endianess);
                        },
                        else => return Image.Error.Unsupported,
                    }
                },
                .x_resolution => {
                    bitmap.x_resolution = try tag.readRational(read_stream, endianess);
                },
                .y_resolution => {
                    bitmap.y_resolution = try tag.readRational(read_stream, endianess);
                },
                .planar_configuration => {
                    bitmap.planar_configuration = try tag.toShort(endianess);
                },
                .predictor => {
                    bitmap.predictor = try tag.toShort(endianess);
                },
                else => {
                    // skip optional tags
                },
            }
        }

        if (tags_map.get(.color_map)) |tag| {
            const bits = bitmap.bits_per_sample.data[0];
            if (bits > 8) return Image.Error.Unsupported;

            const num_colors = @as(usize, 1) << @intCast(bits);
            const expected_count = std.math.mul(usize, num_colors, 3) catch return Image.ReadError.InvalidData;
            const palette = try tag.readTagData(allocator, read_stream, endianess);
            defer allocator.free(palette);
            if (palette.len != expected_count) return Image.ReadError.InvalidData;

            var color_map = &bitmap.color_map;
            color_map.resize(num_colors);
            for (0..num_colors) |color_index| {
                // TIFF stores all 16-bit red, green, then blue components.
                color_map.data[color_index] = color.Rgba32.from.rgb(@truncate(palette[color_index] / 256), @truncate(palette[color_index + num_colors] / 256), @truncate(palette[color_index + num_colors * 2] / 256));
            }
        } else if (bitmap.photometric_interpretation == 3) {
            return Image.ReadError.InvalidData;
        }

        // The TIFF default is one strip containing the whole image.
        if (!tags_map.contains(.rows_per_strip)) bitmap.rows_per_strip = bitmap.image_height;
    }

    pub fn uncompressDeflate(_: *TIFF, read_stream: *io.ReadStream, dest_buffer: []u8) !void {
        const reader = read_stream.reader();
        var writer = std.Io.Writer.fixed(dest_buffer);

        var decompress_buffer: [std.compress.flate.max_window_len]u8 = undefined;
        var zlib_decompress = std.compress.flate.Decompress.init(reader, .zlib, decompress_buffer[0..]);

        _ = zlib_decompress.reader.streamRemaining(&writer) catch {
            return Image.ReadError.InvalidData;
        };
    }

    pub fn uncompressLZW(_: *TIFF, allocator: std.mem.Allocator, read_stream: *io.ReadStream, dest_buffer: []u8, compressed_length: u32) !void {
        // Read compressed data into a temporary buffer first.
        // This ensures we don't read beyond the strip boundary, which can happen
        // when the LZW stream doesn't end exactly at the expected position.
        const compressed_buffer = try allocator.alloc(u8, compressed_length);
        defer allocator.free(compressed_buffer);

        const reader = read_stream.reader();
        _ = try reader.readSliceAll(compressed_buffer);

        // Create a fixed buffer reader for the compressed data
        var compressed_stream = io.ReadStream.initMemory(compressed_buffer);

        var writer = std.Io.Writer.fixed(dest_buffer);
        var lzw_decoder = try lzw.Decoder(.big).init(allocator, 8, 1);
        defer lzw_decoder.deinit();

        lzw_decoder.decode(compressed_stream.reader(), &writer) catch |err| {
            // Some TIFF encoders don't include EOI code and rely on strip byte counts.
            // If WriteFailed occurs but we've filled the buffer completely, that's OK -
            // the strip decoded successfully, just with trailing data we should ignore.
            if (err == error.WriteFailed and writer.end == dest_buffer.len) {
                return; // Success - buffer is full
            }
            return Image.ReadError.InvalidData;
        };
    }

    pub fn uncompressCCITT(self: *TIFF, read_stream: *io.ReadStream, dest_buffer: []u8, image_width: usize, num_rows: usize) !void {
        var writer = std.Io.Writer.fixed(dest_buffer);

        var ccitt_decoder = try ccitt.Decoder.init(image_width, num_rows, @truncate(self.bitmap.photometric_interpretation));

        ccitt_decoder.decode(read_stream.reader(), &writer) catch {
            return Image.ReadError.InvalidData;
        };
    }

    pub fn calRowByteSize(self: *TIFF) Image.ReadError!usize {
        const bitmap = &self.bitmap;
        const sample_count = std.math.cast(usize, bitmap.samples_per_pixel) orelse return Image.ReadError.InvalidData;
        if (sample_count == 0 or sample_count > bitmap.bits_per_sample.data.len) return Image.ReadError.InvalidData;

        var total_bits: usize = 0;

        for (bitmap.bits_per_sample.data[0..sample_count]) |bits| {
            total_bits = std.math.add(usize, total_bits, @as(usize, bits)) catch return Image.ReadError.InvalidData;
        }

        const pixel_width = std.math.cast(usize, bitmap.image_width) orelse return Image.ReadError.InvalidData;
        if (total_bits == 1) {
            return pixel_width / 8 + @intFromBool(pixel_width % 8 != 0);
        } else if (total_bits >= 8 and total_bits % 8 == 0) {
            return std.math.mul(usize, pixel_width, total_bits / 8) catch return Image.ReadError.InvalidData;
        }

        return Image.Error.Unsupported;
    }

    pub fn readStrips(self: *TIFF, allocator: std.mem.Allocator, read_stream: *io.ReadStream, pixel_storage: *color.PixelStorage) Image.ReadError!void {
        const bitmap = &self.bitmap;
        const image_width = std.math.cast(usize, bitmap.image_width) orelse return Image.ReadError.InvalidData;
        const image_height = std.math.cast(usize, bitmap.image_height) orelse return Image.ReadError.InvalidData;
        const rows_per_strip = std.math.cast(usize, bitmap.rows_per_strip) orelse return Image.ReadError.InvalidData;
        if (image_width == 0 or image_height == 0 or rows_per_strip == 0) return Image.ReadError.InvalidData;

        const total_strips = 1 + (image_height - 1) / rows_per_strip;
        const byte_counts_array = bitmap.strip_byte_counts orelse return Image.ReadError.InvalidData;
        const offsets_array = bitmap.strip_offsets orelse return Image.ReadError.InvalidData;
        if (byte_counts_array.len < total_strips or offsets_array.len < total_strips) return Image.ReadError.InvalidData;

        const pixel_count = std.math.mul(usize, image_width, image_height) catch return Image.ReadError.InvalidData;
        if (pixel_storage.len() != pixel_count) return Image.ReadError.InvalidData;

        const photometric_interpretation = bitmap.photometric_interpretation;
        const predictor = bitmap.predictor;
        const compression = bitmap.compression;
        const row_byte_size = try self.calRowByteSize();
        const reader = read_stream.reader();

        for (0..total_strips) |index| {
            const row_start = std.math.mul(usize, index, rows_per_strip) catch return Image.ReadError.InvalidData;
            if (row_start >= image_height) return Image.ReadError.InvalidData;
            const current_row_size = @min(rows_per_strip, image_height - row_start);
            const byte_count = std.math.mul(usize, current_row_size, row_byte_size) catch return Image.ReadError.InvalidData;
            const compressed_byte_count = byte_counts_array[index];
            const compressed_byte_count_usize = std.math.cast(usize, compressed_byte_count) orelse return Image.ReadError.InvalidData;
            const offset = offsets_array[index];
            var pixel_index = std.math.mul(usize, row_start, image_width) catch return Image.ReadError.InvalidData;
            // allocate buffer for the uncompressed strip_buffer
            const strip_buffer: []u8 = try allocator.alloc(u8, byte_count);
            defer allocator.free(strip_buffer);
            _ = try read_stream.seekTo(offset);

            switch (compression) {
                .uncompressed => {
                    if (compressed_byte_count_usize < byte_count) return Image.ReadError.InvalidData;
                    try reader.readSliceAll(strip_buffer);
                },
                .packbits => _ = try packbits.decode(read_stream, strip_buffer, compressed_byte_count),
                .ccitt_rle => _ = try self.uncompressCCITT(read_stream, strip_buffer, image_width, current_row_size),
                .lzw => try self.uncompressLZW(allocator, read_stream, strip_buffer, compressed_byte_count),
                .deflate, .pixar_deflate => _ = try self.uncompressDeflate(read_stream, strip_buffer),
                else => return Image.Error.Unsupported,
            }

            blk: switch (pixel_storage.*) {
                .grayscale1 => |pixels| {
                    for (0..current_row_size) |strip_row| {
                        const source_row_start = strip_row * row_byte_size;
                        const source_row = strip_buffer[source_row_start..][0..row_byte_size];
                        for (0..image_width) |column| {
                            const bit_shift: u3 = @intCast(7 - column % 8);
                            const value: u1 = @truncate(source_row[column / 8] >> bit_shift);
                            pixels[pixel_index].value = if (photometric_interpretation == 1) value else value ^ 1;
                            pixel_index += 1;
                        }
                    }
                },
                .grayscale8 => |pixels| {
                    for (0..byte_count) |strip_index| {
                        if (predictor == 1 or pixel_index % image_width == 0) {
                            pixels[pixel_index].value = strip_buffer[strip_index];
                        } else {
                            pixels[pixel_index].value = pixels[pixel_index - 1].value +% strip_buffer[strip_index];
                        }
                        pixel_index += 1;
                        if (pixel_index >= pixels.len)
                            break :blk;
                    }
                },
                .indexed8 => |*storage| {
                    const tiff_color_map = bitmap.color_map;
                    const palette = storage.palette;
                    for (0..bitmap.color_map.data.len) |color_index| {
                        palette[color_index] = tiff_color_map.data[color_index];
                    }
                    for (0..byte_count) |strip_index| {
                        if (predictor == 1 or pixel_index % image_width == 0) {
                            storage.indices[pixel_index] = strip_buffer[strip_index];
                        } else {
                            storage.indices[pixel_index] = storage.indices[pixel_index - 1] +% strip_buffer[strip_index];
                        }
                        pixel_index += 1;
                        if (pixel_index >= storage.indices.len)
                            break :blk;
                    }
                },
                .rgb24 => |storage| {
                    var strip_index: usize = 0;
                    while (strip_index + 2 < byte_count) : (strip_index += 3) {
                        if (predictor == 1 or pixel_index % image_width == 0) {
                            storage[pixel_index] = color.Rgb24.from.rgb(strip_buffer[strip_index], strip_buffer[strip_index + 1], strip_buffer[strip_index + 2]);
                        } else {
                            const previous_color = storage[pixel_index - 1];
                            storage[pixel_index] = color.Rgb24.from.rgb(previous_color.r +% strip_buffer[strip_index], previous_color.g +% strip_buffer[strip_index + 1], previous_color.b +% strip_buffer[strip_index + 2]);
                        }
                        pixel_index += 1;
                        if (pixel_index >= storage.len)
                            break :blk;
                    }
                },
                .rgba32 => |storage| {
                    var strip_index: usize = 0;
                    while (strip_index + 3 < byte_count) : (strip_index += 4) {
                        if (predictor == 1 or pixel_index % image_width == 0) {
                            storage[pixel_index] = color.Rgba32.from.rgba(strip_buffer[strip_index], strip_buffer[strip_index + 1], strip_buffer[strip_index + 2], strip_buffer[strip_index + 3]);
                        } else {
                            const previous_color = storage[pixel_index - 1];
                            storage[pixel_index] = color.Rgba32.from.rgba(previous_color.r +% strip_buffer[strip_index], previous_color.g +% strip_buffer[strip_index + 1], previous_color.b +% strip_buffer[strip_index + 2], previous_color.a +% strip_buffer[strip_index + 3]);
                        }
                        pixel_index += 1;
                        if (pixel_index >= storage.len)
                            break :blk;
                    }
                },
                else => return Image.Error.Unsupported,
            }
        }
    }

    pub fn read(self: *TIFF, allocator: std.mem.Allocator, read_stream: *io.ReadStream) Image.ReadError!color.PixelStorage {
        self.endianess = try takeEndianess(read_stream);

        const reader = read_stream.reader();

        self.header = Header{
            .version = try reader.takeInt(u16, self.endianess),
            .idf_offset = try reader.takeInt(u32, self.endianess),
        };
        if (self.header.version != 42) return Image.ReadError.InvalidData;

        self.bitmap = BitmapDescriptor{};

        defer self.bitmap.deinit(allocator);

        self.ifd = try IFD.init(allocator, read_stream, self.header.idf_offset);
        defer self.ifd.deinit();

        try self.ifd.readTags(self.endianess);

        try self.decodeBitmap(allocator, read_stream);

        const pixel_format = try self.bitmap.guessPixelFormat();

        const image_width = std.math.cast(usize, self.bitmap.image_width) orelse return Image.ReadError.InvalidData;
        const image_height = std.math.cast(usize, self.bitmap.image_height) orelse return Image.ReadError.InvalidData;
        if (image_width == 0 or image_height == 0) return Image.ReadError.InvalidData;
        const pixel_count = std.math.mul(usize, image_width, image_height) catch return Image.ReadError.InvalidData;

        var pixels = try color.PixelStorage.init(allocator, pixel_format, pixel_count);
        errdefer pixels.deinit(allocator);

        switch (pixels) {
            .grayscale1, .grayscale8, .indexed8, .rgb24, .rgba32 => try self.readStrips(allocator, read_stream, &pixels),
            else => return Image.Error.Unsupported,
        }

        return pixels;
    }

    pub fn readImage(allocator: std.mem.Allocator, read_stream: *io.ReadStream) Image.ReadError!Image {
        var result = Image{};
        errdefer result.deinit(allocator);

        var tiff = TIFF{};

        const pixels = try tiff.read(allocator, read_stream);

        result.pixels = pixels;
        result.width = tiff.width();
        result.height = tiff.height();

        return result;
    }

    pub fn writeImage(allocator: std.mem.Allocator, write_stream: *io.WriteStream, image: Image, encoder_options: Image.EncoderOptions) Image.WriteError!void {
        _ = allocator;
        _ = write_stream;
        _ = image;
        _ = encoder_options;
    }

    fn peekEndianess(read_stream: *io.ReadStream) Image.ReadError!std.builtin.Endian {
        const reader = read_stream.reader();

        const magic_buffer = try reader.peek(Header.little_endian_magic.len);

        if (std.mem.eql(u8, magic_buffer[0..], Header.little_endian_magic[0..])) {
            return std.builtin.Endian.little;
        } else if (std.mem.eql(u8, magic_buffer[0..], Header.big_endian_magic[0..])) {
            return std.builtin.Endian.big;
        }

        return Image.ReadError.InvalidData;
    }

    fn takeEndianess(read_stream: *io.ReadStream) Image.ReadError!std.builtin.Endian {
        const reader = read_stream.reader();

        const endianess = try peekEndianess(read_stream);
        reader.toss(Header.little_endian_magic.len);

        return endianess;
    }

    pub fn formatDetect(read_stream: *io.ReadStream) Image.ReadError!bool {
        _ = peekEndianess(read_stream) catch return false;

        return true;
    }
};

// Test for LZW tolerance when decoder produces slightly more data than expected.
// Some TIFF encoders (e.g., VueScan) don't include proper EOI codes, and the
// decoder may produce extra output. If the buffer is exactly filled, this should
// succeed rather than fail.
test "LZW decode should succeed when buffer is exactly filled without EOI" {
    const allocator = std.testing.allocator;

    // Create LZW-encoded data without proper EOI (just clear code + some data)
    // that will fill an 8-byte buffer exactly, then have trailing garbage
    var encoder = try lzw.Encoder(.big).init(8);
    defer encoder.deinit();

    var encoded_buffer: [256]u8 = undefined;
    var encode_stream = io.WriteStream.initMemory(&encoded_buffer);
    const encode_writer = encode_stream.writer();

    // Encode exactly 8 bytes of data
    const test_data = [_]u8{ 'A', 'B', 'C', 'D', 'E', 'F', 'G', 'H' };
    try encoder.encode(encode_writer, &test_data);
    try encoder.finish(encode_writer);

    const encoded_len = encode_writer.end;

    // Now create a TIFF instance and try to decompress into an 8-byte buffer.
    // The encoded stream has proper EOI so this should succeed normally.
    var tiff = TIFF{};
    var dest_buffer: [8]u8 = undefined;

    var read_stream = io.ReadStream.initMemory(encoded_buffer[0..encoded_len]);
    try tiff.uncompressLZW(allocator, &read_stream, &dest_buffer, @intCast(encoded_len));

    // Verify the output
    try std.testing.expectEqualSlices(u8, &test_data, &dest_buffer);
}
