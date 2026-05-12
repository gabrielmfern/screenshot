const std = @import("std");

const c = @cImport({
    @cInclude("stb_image_write.h");
});

/// A rectangular region defined by its top-left corner and dimensions.
pub const Rect = struct {
    x: u32,
    y: u32,
    width: u32,
    height: u32,

    /// Returns true if this rect has zero area.
    pub fn isEmpty(self: Rect) bool {
        return self.width == 0 or self.height == 0;
    }

    /// Clamp this rect so it fits entirely within the given bounds.
    pub fn clampToBounds(self: Rect, bounds_width: u32, bounds_height: u32) Rect {
        const clamped_x = @min(self.x, bounds_width);
        const clamped_y = @min(self.y, bounds_height);
        const max_w = bounds_width -| clamped_x;
        const max_h = bounds_height -| clamped_y;
        return .{
            .x = clamped_x,
            .y = clamped_y,
            .width = @min(self.width, max_w),
            .height = @min(self.height, max_h),
        };
    }

    /// Normalizes a rect that may have been created from a drag (where start > end).
    /// Takes two points and returns a rect with positive width/height.
    pub fn fromPoints(x1: i32, y1: i32, x2: i32, y2: i32) Rect {
        const min_x: u32 = @intCast(@max(0, @min(x1, x2)));
        const min_y: u32 = @intCast(@max(0, @min(y1, y2)));
        const max_x: u32 = @intCast(@max(0, @max(x1, x2)));
        const max_y: u32 = @intCast(@max(0, @max(y1, y2)));
        return .{
            .x = min_x,
            .y = min_y,
            .width = max_x - min_x,
            .height = max_y - min_y,
        };
    }
};

/// A 32-bit per pixel RGBA image, in the byte order compositors deliver
/// when we request WL_SHM_FORMAT_ARGB8888 / XRGB8888 (byte 0 = R, byte 1 = G,
/// byte 2 = B, byte 3 = A).
pub const Image = struct {
    data: []u8,
    width: u32,
    height: u32,
    stride: u32,
    allocator: std.mem.Allocator,

    pub const bpp = 4;

    /// Create an image that wraps externally-owned data (e.g. a Wayland SHM buffer).
    /// The Image does NOT own this data and deinit will not free it.
    pub fn wrapExternalBuffer(data: [*]u8, w: u32, h: u32, stride: u32) Image {
        return .{
            .data = data[0 .. h * stride],
            .width = w,
            .height = h,
            .stride = stride,
            .allocator = undefined, // external data, not our allocation
        };
    }

    /// Create a new image by copying a rectangular region from this image.
    pub fn crop(self: *const Image, allocator: std.mem.Allocator, region: Rect) !Image {
        const r = region.clampToBounds(self.width, self.height);
        if (r.isEmpty()) return error.EmptyCropRegion;

        const new_stride = r.width * bpp;
        const new_data = try allocator.alloc(u8, r.height * new_stride);
        errdefer allocator.free(new_data);

        for (0..r.height) |row| {
            const src_offset = (r.y + @as(u32, @intCast(row))) * self.stride + r.x * bpp;
            const dst_offset: u32 = @intCast(row * new_stride);
            @memcpy(
                new_data[dst_offset..][0..new_stride],
                self.data[src_offset..][0..new_stride],
            );
        }

        return .{
            .data = new_data,
            .width = r.width,
            .height = r.height,
            .stride = new_stride,
            .allocator = allocator,
        };
    }

    /// Save this image as a PNG file.
    pub fn savePng(self: *Image, path: [*:0]const u8) !void {
        // Compositors tested (Hyprland, presumably others using ext-image-copy-
        // capture-v1) deliver pixels in RGBA byte order for WL_SHM_FORMAT_ARGB8888
        // / XRGB8888, despite the Wayland spec describing those formats as
        // little-endian packed (which would be BGRA bytes). Empirically the bytes
        // are already in the order stb expects, so don't swap.
        const result = c.stbi_write_png(
            path,
            @intCast(self.width),
            @intCast(self.height),
            bpp,
            self.data.ptr,
            @intCast(self.stride),
        );
        if (result == 0) return error.PngWriteFailed;
    }

    /// Free the image data if it was allocated by us.
    pub fn deinit(self: *Image) void {
        // Only free if allocator is valid (i.e. we own the data)
        if (@intFromPtr(&self.allocator) != @intFromPtr(&@as(std.mem.Allocator, undefined))) {
            self.allocator.free(self.data);
        }
    }
};

// ── Tests ───────────────────────────────────────────────────────────────────

test "Rect.isEmpty" {
    const empty1 = Rect{ .x = 0, .y = 0, .width = 0, .height = 10 };
    const empty2 = Rect{ .x = 0, .y = 0, .width = 10, .height = 0 };
    const notempty = Rect{ .x = 0, .y = 0, .width = 10, .height = 10 };
    try std.testing.expect(empty1.isEmpty());
    try std.testing.expect(empty2.isEmpty());
    try std.testing.expect(!notempty.isEmpty());
}

test "Rect.fromPoints normalizes coordinates" {
    // Normal top-left to bottom-right
    const r1 = Rect.fromPoints(10, 20, 50, 60);
    try std.testing.expectEqual(@as(u32, 10), r1.x);
    try std.testing.expectEqual(@as(u32, 20), r1.y);
    try std.testing.expectEqual(@as(u32, 40), r1.width);
    try std.testing.expectEqual(@as(u32, 40), r1.height);

    // Reversed: bottom-right to top-left
    const r2 = Rect.fromPoints(50, 60, 10, 20);
    try std.testing.expectEqual(@as(u32, 10), r2.x);
    try std.testing.expectEqual(@as(u32, 20), r2.y);
    try std.testing.expectEqual(@as(u32, 40), r2.width);
    try std.testing.expectEqual(@as(u32, 40), r2.height);

    // Negative coordinates get clamped to 0
    const r3 = Rect.fromPoints(-10, -20, 30, 40);
    try std.testing.expectEqual(@as(u32, 0), r3.x);
    try std.testing.expectEqual(@as(u32, 0), r3.y);
    try std.testing.expectEqual(@as(u32, 30), r3.width);
    try std.testing.expectEqual(@as(u32, 40), r3.height);
}

test "Rect.clampToBounds" {
    // Rect fully inside bounds
    const r1 = (Rect{ .x = 5, .y = 5, .width = 10, .height = 10 }).clampToBounds(100, 100);
    try std.testing.expectEqual(@as(u32, 5), r1.x);
    try std.testing.expectEqual(@as(u32, 5), r1.y);
    try std.testing.expectEqual(@as(u32, 10), r1.width);
    try std.testing.expectEqual(@as(u32, 10), r1.height);

    // Rect extends past bounds - should be clamped
    const r2 = (Rect{ .x = 90, .y = 90, .width = 20, .height = 20 }).clampToBounds(100, 100);
    try std.testing.expectEqual(@as(u32, 90), r2.x);
    try std.testing.expectEqual(@as(u32, 90), r2.y);
    try std.testing.expectEqual(@as(u32, 10), r2.width);
    try std.testing.expectEqual(@as(u32, 10), r2.height);

    // Rect completely outside bounds
    const r3 = (Rect{ .x = 200, .y = 200, .width = 50, .height = 50 }).clampToBounds(100, 100);
    try std.testing.expect(r3.isEmpty());
}

test "Image.crop basic" {
    const allocator = std.testing.allocator;

    // Create a 4x4 BGRA image with known pixel values
    const w: u32 = 4;
    const h: u32 = 4;
    const stride = w * Image.bpp;
    var data = try allocator.alloc(u8, h * stride);
    defer allocator.free(data);

    // Fill each pixel with its (x, y) encoded in the B channel
    for (0..h) |y| {
        for (0..w) |x| {
            const offset = y * stride + x * Image.bpp;
            data[offset + 0] = @intCast(x); // B = x
            data[offset + 1] = @intCast(y); // G = y
            data[offset + 2] = 0xFF; // R
            data[offset + 3] = 0xFF; // A
        }
    }

    var img = Image{
        .data = data,
        .width = w,
        .height = h,
        .stride = stride,
        .allocator = undefined,
    };

    // Crop a 2x2 region starting at (1, 1)
    var cropped = try img.crop(allocator, .{ .x = 1, .y = 1, .width = 2, .height = 2 });
    defer cropped.deinit();

    try std.testing.expectEqual(@as(u32, 2), cropped.width);
    try std.testing.expectEqual(@as(u32, 2), cropped.height);

    // Verify pixel at (0,0) of cropped is (1,1) of original
    try std.testing.expectEqual(@as(u8, 1), cropped.data[0]); // B = original x=1
    try std.testing.expectEqual(@as(u8, 1), cropped.data[1]); // G = original y=1

    // Verify pixel at (1,0) of cropped is (2,1) of original
    const p10_offset: usize = Image.bpp;
    try std.testing.expectEqual(@as(u8, 2), cropped.data[p10_offset]); // B = original x=2
    try std.testing.expectEqual(@as(u8, 1), cropped.data[p10_offset + 1]); // G = original y=1

    // Verify pixel at (0,1) of cropped is (1,2) of original
    const p01_offset: usize = cropped.stride;
    try std.testing.expectEqual(@as(u8, 1), cropped.data[p01_offset]); // B = original x=1
    try std.testing.expectEqual(@as(u8, 2), cropped.data[p01_offset + 1]); // G = original y=2
}

test "Image.crop empty region returns error" {
    const allocator = std.testing.allocator;
    const w: u32 = 4;
    const h: u32 = 4;
    const stride = w * Image.bpp;
    const data = try allocator.alloc(u8, h * stride);
    defer allocator.free(data);
    @memset(data, 0);

    var img = Image{
        .data = data,
        .width = w,
        .height = h,
        .stride = stride,
        .allocator = undefined,
    };

    // Zero-width crop
    try std.testing.expectError(error.EmptyCropRegion, img.crop(allocator, .{ .x = 0, .y = 0, .width = 0, .height = 10 }));

    // Region entirely outside bounds
    try std.testing.expectError(error.EmptyCropRegion, img.crop(allocator, .{ .x = 100, .y = 100, .width = 10, .height = 10 }));
}

test "Image.savePng writes a valid file" {
    const allocator = std.testing.allocator;
    const w: u32 = 2;
    const h: u32 = 2;
    const stride = w * Image.bpp;
    const data = try allocator.alloc(u8, h * stride);
    defer allocator.free(data);

    // Fill with solid red in BGRA: B=0, G=0, R=255, A=255
    var pixel_i: usize = 0;
    while (pixel_i < data.len) : (pixel_i += Image.bpp) {
        data[pixel_i + 0] = 0; // B
        data[pixel_i + 1] = 0; // G
        data[pixel_i + 2] = 255; // R
        data[pixel_i + 3] = 255; // A
    }

    var img = Image{
        .data = data,
        .width = w,
        .height = h,
        .stride = stride,
        .allocator = undefined,
    };

    const test_path = "/tmp/screenshot_test_output.png";
    try img.savePng(test_path);

    var threaded: std.Io.Threaded = .init_single_threaded;
    const io = threaded.io();

    // Verify the file exists and has a PNG header
    const file = try std.Io.Dir.openFileAbsolute(io, test_path, .{});
    defer file.close(io);

    var header: [8]u8 = undefined;
    const bytes_read = try file.readStreaming(io, &.{&header});
    try std.testing.expectEqual(@as(usize, 8), bytes_read);

    // PNG magic bytes
    try std.testing.expectEqual(@as(u8, 0x89), header[0]);
    try std.testing.expectEqual(@as(u8, 'P'), header[1]);
    try std.testing.expectEqual(@as(u8, 'N'), header[2]);
    try std.testing.expectEqual(@as(u8, 'G'), header[3]);

    // Clean up
    std.Io.Dir.deleteFileAbsolute(io, test_path) catch {};
}
