const std = @import("std");
pub const Error = std.mem.Allocator.Error || error{ InvalidData, Unsupported };

const color = @import("../color.zig");
const Image = @import("../Image.zig");

/// Flip the image vertically, along the X axis.
pub fn flipVertically(pixels: *const color.PixelStorage, height: usize, allocator: std.mem.Allocator) Error!void {
    var image_data = pixels.asBytes();
    if (height == 0 or image_data.len == 0 or image_data.len % height != 0) {
        return error.InvalidData;
    }
    const row_size = image_data.len / height;

    const temp = try allocator.alloc(u8, row_size);
    defer allocator.free(temp);
    while (image_data.len > row_size) : (image_data = image_data[row_size..(image_data.len - row_size)]) {
        const row1_data = image_data[0..row_size];
        const row2_data = image_data[image_data.len - row_size .. image_data.len];
        @memcpy(temp, row1_data);
        @memcpy(row1_data, row2_data);
        @memcpy(row2_data, temp);
    }
}

/// Create and allocate a cropped subsection of this image.
pub fn crop(image: *const Image, allocator: std.mem.Allocator, crop_area: Box) Error!Image {
    const pixel_format = image.pixelFormat();
    if (pixel_format == .invalid) return error.Unsupported;

    const box = crop_area.clamp(image.width, image.height);
    const crop_pixel_count = std.math.mul(usize, box.width, box.height) catch return error.InvalidData;
    const source_pixel_count = std.math.mul(usize, image.width, image.height) catch return error.InvalidData;
    const pixel_size: usize = pixel_format.pixelStride();
    const expected_source_len = std.math.mul(usize, source_pixel_count, pixel_size) catch return error.InvalidData;
    const original_data = image.pixels.asConstBytes();
    if (original_data.len != expected_source_len) return error.InvalidData;

    var cropped_pixels = try color.PixelStorage.init(
        allocator,
        pixel_format,
        crop_pixel_count,
    );

    if (pixel_format.isIndexed()) {
        const source_palette = image.pixels.getPalette().?;
        cropped_pixels.resizePalette(source_palette.len);

        const destination_palette = cropped_pixels.getPalette().?;

        @memcpy(destination_palette, source_palette);
    }

    if (box.width == 0 or box.height == 0 or
        image.width == 0 or image.height == 0)
    {
        return Image{
            .width = box.width,
            .height = box.height,
            .pixels = cropped_pixels,
        };
    }

    const cropped_data = cropped_pixels.asBytes();
    const expected_crop_len = std.math.mul(usize, crop_pixel_count, pixel_size) catch unreachable;
    std.debug.assert(cropped_data.len == expected_crop_len);

    var y: usize = 0;
    const row_byte_width = std.math.mul(usize, box.width, pixel_size) catch unreachable;
    while (y < box.height) : (y += 1) {
        const start_pixel = box.x + (y + box.y) * image.width;
        const start_byte = start_pixel * pixel_size;
        const source = original_data[start_byte .. start_byte + row_byte_width];
        const destination_pixel = y * row_byte_width;
        const destination = cropped_data[destination_pixel .. destination_pixel + row_byte_width];
        @memcpy(destination, source);
    }

    return Image{
        .width = box.width,
        .height = box.height,
        .pixels = cropped_pixels,
    };
}

/// A box describes the region of an image to be extracted. The crop
/// box should be a subsection of the original image.
///
/// If any of the parameters fall outside of the physical dimensions
/// of the image, the parameters can be normalised. For example, if
/// it is attempted to crop an area wider then the source image, the
/// `width` will be normalised to the physical width of the image.
pub const Box = struct {
    x: usize = 0,
    y: usize = 0,
    width: usize = 0,
    height: usize = 0,

    /// If the crop area falls partially outside the image boundary,
    /// adjust the crop region.
    pub fn clamp(area: Box, image_width: usize, image_height: usize) Box {
        var box = area;
        box.x = @min(box.x, image_width);
        box.y = @min(box.y, image_height);
        box.width = @min(box.width, image_width - box.x);
        box.height = @min(box.height, image_height - box.y);
        return box;
    }
};
