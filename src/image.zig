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

/// An BGRA8888 pixel buffer (the format Wayland compositors typically use for SHM).
pub const Image = struct {
    /// Raw pixel data in BGRA format (4 bytes per pixel).
    data: []u8,
    width: u32,
    height: u32,
    stride: u32,
    allocator: std.mem.Allocator,

    /// Bytes per pixel (BGRA = 4).
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

    /// Append another image below this one (same width). Returns a new allocated image.
    pub fn appendBelow(self: *const Image, allocator: std.mem.Allocator, other: *const Image) !Image {
        if (self.width != other.width) return error.MismatchedWidth;
        const new_height = self.height + other.height;
        const new_stride = self.width * bpp;
        const new_data = try allocator.alloc(u8, new_height * new_stride);
        errdefer allocator.free(new_data);

        for (0..self.height) |row| {
            const src_offset = @as(usize, row) * self.stride;
            const dst_offset = @as(usize, row) * new_stride;
            const row_bytes = self.width * bpp;
            @memcpy(new_data[dst_offset..][0..row_bytes], self.data[src_offset..][0..row_bytes]);
        }
        for (0..other.height) |row| {
            const src_offset = @as(usize, row) * other.stride;
            const dst_offset = @as(usize, self.height + row) * new_stride;
            const row_bytes = other.width * bpp;
            @memcpy(new_data[dst_offset..][0..row_bytes], other.data[src_offset..][0..row_bytes]);
        }

        return .{
            .data = new_data,
            .width = self.width,
            .height = new_height,
            .stride = new_stride,
            .allocator = allocator,
        };
    }

    /// Stitch another image below this one, detecting and removing the overlapping
    /// region. If no overlap is found (or images are identical), returns null.
    pub fn stitchBelow(self: *const Image, allocator: std.mem.Allocator, other: *const Image) !?Image {
        if (self.width != other.width) return error.MismatchedWidth;
        const overlap = findVerticalOverlap(self, other);
        if (overlap == 0) return null;
        if (overlap >= other.height) return null; // identical or fully contained

        const new_rows = other.height - overlap;
        const new_height = self.height + new_rows;
        const new_stride = self.width * bpp;
        const new_data = try allocator.alloc(u8, new_height * new_stride);
        errdefer allocator.free(new_data);

        // Copy all of self
        for (0..self.height) |row| {
            const src_off = @as(usize, row) * self.stride;
            const dst_off = @as(usize, row) * new_stride;
            const row_bytes = self.width * bpp;
            @memcpy(new_data[dst_off..][0..row_bytes], self.data[src_off..][0..row_bytes]);
        }
        // Copy only the non-overlapping part of other
        for (overlap..other.height) |row| {
            const src_off = @as(usize, row) * other.stride;
            const dst_off = @as(usize, self.height + row - overlap) * new_stride;
            const row_bytes = other.width * bpp;
            @memcpy(new_data[dst_off..][0..row_bytes], other.data[src_off..][0..row_bytes]);
        }

        return .{
            .data = new_data,
            .width = self.width,
            .height = new_height,
            .stride = new_stride,
            .allocator = allocator,
        };
    }

    /// Find how many rows from the bottom of `top` match the top of `bottom`.
    /// Compares rows using a sampled subset of pixels for speed.
    fn findVerticalOverlap(top: *const Image, bottom: *const Image) u32 {
        if (top.width != bottom.width) return 0;
        const w = top.width;
        const h_top = top.height;
        const h_bot = bottom.height;
        if (h_top == 0 or h_bot == 0 or w == 0) return 0;

        const max_check = @min(h_top, h_bot);
        // Minimum overlap to consider (avoids single-row false positives)
        const min_overlap: u32 = 4;
        if (max_check < min_overlap) return 0;

        // Sample pixel columns for fast row comparison (every ~8px, plus edges)
        const sample_step: u32 = @max(1, w / 32);

        // Try overlap sizes from large to small, return first good match
        var overlap: u32 = max_check;
        while (overlap >= min_overlap) : (overlap -= 1) {
            if (checkOverlap(top, bottom, overlap, w, h_top, sample_step))
                return overlap;
        }
        return 0;
    }

    fn checkOverlap(top: *const Image, bottom: *const Image, overlap: u32, w: u32, h_top: u32, sample_step: u32) bool {
        const start_row_top = h_top - overlap;
        // Check a few rows spread across the overlap region
        const rows_to_check = @min(overlap, 8);
        const row_step = @max(1, overlap / rows_to_check);
        var rows_checked: u32 = 0;
        var rows_matched: u32 = 0;
        var ri: u32 = 0;
        while (ri < overlap) : (ri += row_step) {
            const top_row = start_row_top + ri;
            const bot_row = ri;
            rows_checked += 1;
            if (rowsMatch(top, bottom, top_row, bot_row, w, sample_step)) {
                rows_matched += 1;
            }
        }
        // Always check the last row too
        rows_checked += 1;
        if (rowsMatch(top, bottom, h_top - 1, overlap - 1, w, sample_step)) {
            rows_matched += 1;
        }

        // Allow a small fraction of mismatched rows for dynamic content/animation noise.
        return rows_matched * 100 >= rows_checked * 85;
    }

    fn rowsMatch(top: *const Image, bottom: *const Image, top_row: u32, bot_row: u32, w: u32, sample_step: u32) bool {
        // Skip edge pixels to avoid compositor blending artifacts at selection boundaries
        const edge_skip: u32 = @min(8, w / 4);
        var samples: u32 = 0;
        var matched: u32 = 0;
        var x: u32 = edge_skip;
        while (x < w -| edge_skip) : (x += sample_step) {
            const t_off = @as(usize, top_row) * top.stride + @as(usize, x) * bpp;
            const b_off = @as(usize, bot_row) * bottom.stride + @as(usize, x) * bpp;
            if (t_off + 2 >= top.data.len or b_off + 2 >= bottom.data.len) return false;
            // Compare RGB with small tolerance (ignore alpha)
            const tolerance: u8 = 6;
            const d0 = if (top.data[t_off] > bottom.data[b_off])
                top.data[t_off] - bottom.data[b_off]
            else
                bottom.data[b_off] - top.data[t_off];
            const d1 = if (top.data[t_off + 1] > bottom.data[b_off + 1])
                top.data[t_off + 1] - bottom.data[b_off + 1]
            else
                bottom.data[b_off + 1] - top.data[t_off + 1];
            const d2 = if (top.data[t_off + 2] > bottom.data[b_off + 2])
                top.data[t_off + 2] - bottom.data[b_off + 2]
            else
                bottom.data[b_off + 2] - top.data[t_off + 2];
            samples += 1;
            if (d0 <= tolerance and d1 <= tolerance and d2 <= tolerance) {
                matched += 1;
            }
        }
        if (samples == 0) return true;
        return matched * 100 >= samples * 80;
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

    /// Convert BGRA pixels to RGBA in-place (swaps B and R channels).
    /// This is needed because PNG expects RGBA but Wayland SHM gives us BGRA.
    pub fn bgraToRgba(self: *Image) void {
        var offset: usize = 0;
        const total = @as(usize, self.height) * self.stride;
        while (offset + 3 < total) : (offset += bpp) {
            const b = self.data[offset + 0];
            const r = self.data[offset + 2];
            self.data[offset + 0] = r;
            self.data[offset + 2] = b;
        }
    }

    /// Save this image as a PNG file.
    /// Converts BGRA to RGBA before writing.
    pub fn savePng(self: *Image, path: [*:0]const u8) !void {
        // Convert BGRA -> RGBA in-place for PNG encoding
        self.bgraToRgba();
        defer self.bgraToRgba(); // convert back

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

test "Image.bgraToRgba swaps channels correctly" {
    const allocator = std.testing.allocator;
    var data = try allocator.alloc(u8, Image.bpp);
    defer allocator.free(data);

    // BGRA: B=0x10, G=0x20, R=0x30, A=0x40
    data[0] = 0x10;
    data[1] = 0x20;
    data[2] = 0x30;
    data[3] = 0x40;

    var img = Image{
        .data = data,
        .width = 1,
        .height = 1,
        .stride = Image.bpp,
        .allocator = undefined,
    };

    img.bgraToRgba();
    // After conversion: RGBA: R=0x30, G=0x20, B=0x10, A=0x40
    try std.testing.expectEqual(@as(u8, 0x30), data[0]); // R (was B position)
    try std.testing.expectEqual(@as(u8, 0x20), data[1]); // G (unchanged)
    try std.testing.expectEqual(@as(u8, 0x10), data[2]); // B (was R position)
    try std.testing.expectEqual(@as(u8, 0x40), data[3]); // A (unchanged)

    // Convert back
    img.bgraToRgba();
    try std.testing.expectEqual(@as(u8, 0x10), data[0]); // B restored
    try std.testing.expectEqual(@as(u8, 0x20), data[1]); // G unchanged
    try std.testing.expectEqual(@as(u8, 0x30), data[2]); // R restored
    try std.testing.expectEqual(@as(u8, 0x40), data[3]); // A unchanged
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

    // Verify the file exists and has a PNG header
    const file = try std.fs.openFileAbsolute(test_path, .{});
    defer file.close();

    var header: [8]u8 = undefined;
    const bytes_read = try file.readAll(&header);
    try std.testing.expectEqual(@as(usize, 8), bytes_read);

    // PNG magic bytes
    try std.testing.expectEqual(@as(u8, 0x89), header[0]);
    try std.testing.expectEqual(@as(u8, 'P'), header[1]);
    try std.testing.expectEqual(@as(u8, 'N'), header[2]);
    try std.testing.expectEqual(@as(u8, 'G'), header[3]);

    // Clean up
    std.fs.deleteFileAbsolute(test_path) catch {};
}
