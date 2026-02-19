const std = @import("std");
const posix = std.posix;
const wl = @import("wayland.zig");
const ShmBuffer = @import("shm.zig").ShmBuffer;
const Rect = @import("image.zig").Rect;
const Image = @import("image.zig").Image;

/// Overlay shown during scrolling screenshot capture.
/// Toolbar with Confirm/Cancel at bottom; preview of stitched image in top-right.
pub const ScrollingOverlay = struct {
    display: *wl.c.wl_display = undefined,
    compositor: *wl.c.wl_compositor = undefined,
    shm: *wl.c.wl_shm = undefined,
    seat: *wl.c.wl_seat = undefined,
    layer_shell: *wl.c.zwlr_layer_shell_v1 = undefined,
    output: *wl.c.wl_output = undefined,

    surface: ?*wl.c.wl_surface = null,
    layer_surface: ?*wl.c.zwlr_layer_surface_v1 = null,

    pointer: ?*wl.c.wl_pointer = null,
    cursor_theme: ?*wl.c.wl_cursor_theme = null,
    cursor_surface: ?*wl.c.wl_surface = null,

    surface_width: u32 = 0,
    surface_height: u32 = 0,
    configured: bool = false,

    buffers: [2]?ShmBuffer = .{ null, null },
    current_buf: u1 = 0,
    allocator: std.mem.Allocator = undefined,

    needs_redraw: bool = false,
    frame_pending: bool = false,

    pointer_serial: u32 = 0,
    current_x: i32 = 0,
    current_y: i32 = 0,
    hovered_button: ?ScrollingButton = null,

    /// Current stitched image to show in preview (main updates this).
    preview_image: ?*const Image = null,

    /// Selection region to highlight (darkened outside, border around it).
    region: Rect = .{ .x = 0, .y = 0, .width = 0, .height = 0 },

    action: ScrollingAction = .none,
    done: bool = false,

    pub const ScrollingAction = enum {
        none,
        confirm,
        cancel,
    };

    pub const ScrollingButton = enum {
        confirm,
        cancel,
    };

    const margin: u32 = 16;
    const preview_max_width: u32 = 240;
    const preview_max_height: u32 = 320;
    const toolbar_height: u32 = 48;
    const btn_size: u32 = 40;
    const btn_spacing: u32 = 12;
    const btn_corner_radius: u32 = 10;
    const toolbar_corner_radius: u32 = 14;
    const control_gap: u32 = 12;

    fn previewRect(self: *const ScrollingOverlay) Rect {
        const w = self.surface_width;
        const h = self.surface_height;
        const max_pw = @min(preview_max_width, w -| margin * 2);
        const max_ph = @min(preview_max_height, h -| margin * 2);

        var pw: u32 = max_pw;
        var ph: u32 = max_ph;

        if (self.preview_image) |img| {
            if (img.width > 0 and img.height > 0 and max_pw > 0 and max_ph > 0) {
                const img_aspect: f64 = @as(f64, @floatFromInt(img.width)) / @as(f64, @floatFromInt(img.height));
                const max_aspect: f64 = @as(f64, @floatFromInt(max_pw)) / @as(f64, @floatFromInt(max_ph));
                if (img_aspect >= max_aspect) {
                    pw = max_pw;
                    ph = @max(1, @as(u32, @intFromFloat(@as(f64, @floatFromInt(max_pw)) / img_aspect)));
                } else {
                    ph = max_ph;
                    pw = @max(1, @as(u32, @intFromFloat(@as(f64, @floatFromInt(max_ph)) * img_aspect)));
                }
            }
        }

        return .{
            .x = w -| margin -| pw,
            .y = margin,
            .width = pw,
            .height = ph,
        };
    }

    fn toolbarRect(self: *const ScrollingOverlay) Rect {
        const total = btn_size * 2 + btn_spacing;
        const center_x = self.region.x + self.region.width / 2;
        const base_x = if (center_x >= total / 2) center_x - total / 2 else 0;
        const clamped_x = @min(base_x, self.surface_width -| total);

        const below_y = self.region.y + self.region.height + control_gap;
        const ty = if (below_y + toolbar_height <= self.surface_height)
            below_y
        else if (self.region.y >= toolbar_height + control_gap)
            self.region.y - toolbar_height - control_gap
        else
            self.region.y + self.region.height / 2 -| toolbar_height / 2;

        return .{
            .x = clamped_x,
            .y = ty,
            .width = total,
            .height = toolbar_height,
        };
    }

    fn buttonRect(self: *const ScrollingOverlay, btn: ScrollingButton) Rect {
        const bar = self.toolbarRect();
        const by = bar.y + (bar.height -| btn_size) / 2;
        const bx = switch (btn) {
            .confirm => bar.x,
            .cancel => bar.x + btn_size + btn_spacing,
        };
        return .{ .x = bx, .y = by, .width = btn_size, .height = btn_size };
    }

    fn hitTestButtons(self: *const ScrollingOverlay, px: i32, py: i32) ?ScrollingButton {
        if (px < 0 or py < 0) return null;
        const ux: u32 = @intCast(px);
        const uy: u32 = @intCast(py);
        inline for (.{ ScrollingButton.confirm, ScrollingButton.cancel }) |btn| {
            const br = self.buttonRect(btn);
            if (ux >= br.x and ux < br.x + br.width and
                uy >= br.y and uy < br.y + br.height)
                return btn;
        }
        return null;
    }

    pub fn init(self: *ScrollingOverlay, allocator: std.mem.Allocator) !void {
        self.allocator = allocator;

        self.cursor_theme = wl.c.wl_cursor_theme_load(null, 24, self.shm);
        self.cursor_surface = wl.c.wl_compositor_create_surface(self.compositor);

        self.surface = wl.c.wl_compositor_create_surface(self.compositor) orelse
            return error.FailedToCreateSurface;

        self.layer_surface = wl.c.zwlr_layer_shell_v1_get_layer_surface(
            self.layer_shell,
            self.surface.?,
            self.output,
            wl.c.ZWLR_LAYER_SHELL_V1_LAYER_OVERLAY,
            "screenshot-scrolling",
        ) orelse return error.FailedToCreateLayerSurface;

        wl.c.zwlr_layer_surface_v1_set_anchor(
            self.layer_surface.?,
            wl.c.ZWLR_LAYER_SURFACE_V1_ANCHOR_TOP |
                wl.c.ZWLR_LAYER_SURFACE_V1_ANCHOR_BOTTOM |
                wl.c.ZWLR_LAYER_SURFACE_V1_ANCHOR_LEFT |
                wl.c.ZWLR_LAYER_SURFACE_V1_ANCHOR_RIGHT,
        );
        wl.c.zwlr_layer_surface_v1_set_exclusive_zone(self.layer_surface.?, -1);
        wl.c.zwlr_layer_surface_v1_set_keyboard_interactivity(
            self.layer_surface.?,
            wl.c.ZWLR_LAYER_SURFACE_V1_KEYBOARD_INTERACTIVITY_NONE,
        );

        _ = wl.c.zwlr_layer_surface_v1_add_listener(
            self.layer_surface.?,
            &scroll_layer_surface_listener,
            self,
        );

        wl.c.wl_surface_commit(self.surface.?);

        self.pointer = wl.c.wl_seat_get_pointer(self.seat);
        if (self.pointer) |ptr| {
            _ = wl.c.wl_pointer_add_listener(ptr, &scroll_pointer_listener, self);
        }

        while (!self.configured) {
            if (wl.c.wl_display_roundtrip(self.display) == -1)
                return error.WaylandRoundtripFailed;
        }

        try self.createBuffers();
        self.updateInputRegion();
        self.renderToBuffer();
        self.commitBuffer();
        self.scheduleRedraw();
    }

    fn updateInputRegion(self: *ScrollingOverlay) void {
        const bar = self.toolbarRect();
        const region = wl.c.wl_compositor_create_region(self.compositor) orelse return;
        wl.c.wl_region_add(region, @intCast(bar.x), @intCast(bar.y), @intCast(bar.width), @intCast(bar.height));
        wl.c.wl_surface_set_input_region(self.surface.?, region);
        wl.c.wl_region_destroy(region);
    }

    fn createBuffers(self: *ScrollingOverlay) !void {
        for (&self.buffers) |*buf| {
            if (buf.*) |*b| b.destroy();
            buf.* = try ShmBuffer.create(
                self.shm,
                self.surface_width,
                self.surface_height,
                wl.c.WL_SHM_FORMAT_ARGB8888,
            );
        }
    }

    /// Call when the stitched image has changed so the preview can be redrawn.
    pub fn setPreviewImage(self: *ScrollingOverlay, img: ?*const Image) void {
        self.preview_image = img;
        self.scheduleRedraw();
    }

    fn setCursorDefault(self: *ScrollingOverlay, serial: u32) void {
        const theme = self.cursor_theme orelse return;
        const cursor_sfc = self.cursor_surface orelse return;
        const cursor = wl.c.wl_cursor_theme_get_cursor(theme, "default") orelse return;
        if (cursor.*.image_count == 0) return;
        const image = cursor.*.images[0].*;
        const buffer = wl.c.wl_cursor_image_get_buffer(cursor.*.images[0]) orelse return;
        wl.c.wl_surface_attach(cursor_sfc, buffer, 0, 0);
        wl.c.wl_surface_damage_buffer(cursor_sfc, 0, 0, @intCast(image.width), @intCast(image.height));
        wl.c.wl_surface_commit(cursor_sfc);
        wl.c.wl_pointer_set_cursor(self.pointer.?, serial, cursor_sfc, @intCast(image.hotspot_x), @intCast(image.hotspot_y));
    }

    fn setCursorHand(self: *ScrollingOverlay) void {
        const theme = self.cursor_theme orelse return;
        const cursor_sfc = self.cursor_surface orelse return;
        const cursor = wl.c.wl_cursor_theme_get_cursor(theme, "hand2") orelse return;
        if (cursor.*.image_count == 0) return;
        const image = cursor.*.images[0].*;
        const buffer = wl.c.wl_cursor_image_get_buffer(cursor.*.images[0]) orelse return;
        wl.c.wl_surface_attach(cursor_sfc, buffer, 0, 0);
        wl.c.wl_surface_damage_buffer(cursor_sfc, 0, 0, @intCast(image.width), @intCast(image.height));
        wl.c.wl_surface_commit(cursor_sfc);
        wl.c.wl_pointer_set_cursor(self.pointer.?, self.pointer_serial, cursor_sfc, @intCast(image.hotspot_x), @intCast(image.hotspot_y));
    }

    fn renderToBuffer(self: *ScrollingOverlay) void {
        const buf = &(self.buffers[self.current_buf] orelse return);
        const data = buf.data;
        const stride = buf.stride;

        @memset(data, 0);

        self.drawDarkenedOutside(data, stride);
        self.drawPreview(data, stride);
        self.drawToolbar(data, stride);
    }

    fn drawDarkenedOutside(self: *ScrollingOverlay, data: []u8, stride: u32) void {
        const r = self.region;
        const sw = self.surface_width;
        const sh = self.surface_height;
        const dim_alpha: u8 = 0x60;

        const rx_end = @min(r.x + r.width, sw);
        const ry_end = @min(r.y + r.height, sh);

        if (r.y > 0) {
            fillRectAlpha(data, stride, 0, 0, sw, r.y, sw, sh, 0x00, 0x00, 0x00, dim_alpha);
        }
        if (ry_end < sh) {
            fillRectAlpha(data, stride, 0, ry_end, sw, sh - ry_end, sw, sh, 0x00, 0x00, 0x00, dim_alpha);
        }
        if (r.x > 0) {
            fillRectAlpha(data, stride, 0, r.y, r.x, ry_end - r.y, sw, sh, 0x00, 0x00, 0x00, dim_alpha);
        }
        if (rx_end < sw) {
            fillRectAlpha(data, stride, rx_end, r.y, sw - rx_end, ry_end - r.y, sw, sh, 0x00, 0x00, 0x00, dim_alpha);
        }
    }

    fn fillRectAlpha(data: []u8, stride: u32, rx: u32, ry: u32, rw: u32, rh: u32, sw: u32, sh: u32, r: u8, g: u8, b: u8, a: u8) void {
        const x_end = @min(rx + rw, sw);
        const y_end = @min(ry + rh, sh);
        if (rx >= x_end or ry >= y_end) return;
        const bpp = ShmBuffer.bpp;
        for (ry..y_end) |y| {
            const row_start = y * stride;
            for (rx..x_end) |x| {
                const offset = row_start + x * bpp;
                if (offset + 3 < data.len) {
                    data[offset + 0] = b;
                    data[offset + 1] = g;
                    data[offset + 2] = r;
                    data[offset + 3] = a;
                }
            }
        }
    }

    fn drawSelectionBorder(self: *ScrollingOverlay, data: []u8, stride: u32) void {
        const r = self.region;
        const sw = self.surface_width;
        const sh = self.surface_height;
        if (r.width == 0 or r.height == 0) return;

        const border: u32 = 2;
        const max_x = @min(r.x + r.width, sw);
        const max_y = @min(r.y + r.height, sh);
        const bpp = ShmBuffer.bpp;

        // Top edge
        for (r.y..@min(r.y + border, max_y)) |y| {
            for (r.x..max_x) |x| {
                const off = y * stride + x * bpp;
                if (off + 3 < data.len) {
                    data[off + 0] = 0xFF;
                    data[off + 1] = 0xFF;
                    data[off + 2] = 0xFF;
                    data[off + 3] = 0xC0;
                }
            }
        }
        // Bottom edge
        for (@max(max_y -| border, r.y)..max_y) |y| {
            for (r.x..max_x) |x| {
                const off = y * stride + x * bpp;
                if (off + 3 < data.len) {
                    data[off + 0] = 0xFF;
                    data[off + 1] = 0xFF;
                    data[off + 2] = 0xFF;
                    data[off + 3] = 0xC0;
                }
            }
        }
        // Left edge
        for (r.y..max_y) |y| {
            for (r.x..@min(r.x + border, max_x)) |x| {
                const off = y * stride + x * bpp;
                if (off + 3 < data.len) {
                    data[off + 0] = 0xFF;
                    data[off + 1] = 0xFF;
                    data[off + 2] = 0xFF;
                    data[off + 3] = 0xC0;
                }
            }
        }
        // Right edge
        for (r.y..max_y) |y| {
            for (@max(max_x -| border, r.x)..max_x) |x| {
                const off = y * stride + x * bpp;
                if (off + 3 < data.len) {
                    data[off + 0] = 0xFF;
                    data[off + 1] = 0xFF;
                    data[off + 2] = 0xFF;
                    data[off + 3] = 0xC0;
                }
            }
        }
    }

    fn drawPreview(self: *ScrollingOverlay, data: []u8, stride: u32) void {
        const prev = self.previewRect();
        const sw = self.surface_width;
        const sh = self.surface_height;
        const bpp = ShmBuffer.bpp;

        // Background for preview area
        fillRoundedRectAlpha(data, stride, prev.x, prev.y, prev.width, prev.height, sw, sh, 12, 0x0A, 0x0A, 0x0A, 0xE0);
        strokeRoundedRect(data, stride, prev.x, prev.y, prev.width, prev.height, sw, sh, 12, 2, 0xFF, 0xFF, 0xFF, 0x50);

        const img = self.preview_image orelse return;
        if (img.width == 0 or img.height == 0) return;

        const inner_margin: u32 = 6;
        const box_w = prev.width -| inner_margin * 2;
        const box_h = prev.height -| inner_margin * 2;
        if (box_w == 0 or box_h == 0) return;

        const start_x = prev.x + inner_margin;
        const start_y = prev.y + inner_margin;

        for (0..box_h) |dy| {
            for (0..box_w) |dx| {
                const src_x = @min((@as(u64, dx) * img.width) / box_w, img.width -| 1);
                const src_y = @min((@as(u64, dy) * img.height) / box_h, img.height -| 1);
                const src_offset = @as(usize, src_y) * img.stride + @as(usize, src_x) * Image.bpp;
                const dst_offset = @as(usize, start_y + dy) * stride + @as(usize, start_x + dx) * bpp;
                if (src_offset + 3 < img.data.len and dst_offset + 3 < data.len) {
                    data[dst_offset + 0] = img.data[src_offset + 0];
                    data[dst_offset + 1] = img.data[src_offset + 1];
                    data[dst_offset + 2] = img.data[src_offset + 2];
                    data[dst_offset + 3] = 0xFF;
                }
            }
        }
    }

    fn drawToolbar(self: *ScrollingOverlay, data: []u8, stride: u32) void {
        const bar = self.toolbarRect();
        const sw = self.surface_width;
        const sh = self.surface_height;

        fillRoundedRectAlpha(data, stride, bar.x, bar.y, bar.width, bar.height, sw, sh, toolbar_corner_radius, 0x1A, 0x1A, 0x1A, 0xE0);

        inline for (.{ ScrollingButton.confirm, ScrollingButton.cancel }) |btn| {
            const br = self.buttonRect(btn);
            const is_hovered = self.hovered_button != null and self.hovered_button.? == btn;

            if (is_hovered) {
                fillRoundedRectAlpha(data, stride, br.x, br.y, br.width, br.height, sw, sh, btn_corner_radius, 0x50, 0x50, 0x50, 0xE0);
            } else {
                fillRoundedRectAlpha(data, stride, br.x, br.y, br.width, br.height, sw, sh, btn_corner_radius, 0x33, 0x33, 0x33, 0xD0);
            }

            const icon_cx = br.x + br.width / 2;
            const icon_cy = br.y + br.height / 2;
            switch (btn) {
                .confirm => drawCheckmark(data, stride, icon_cx, icon_cy, sw, sh),
                .cancel => drawXIcon(data, stride, icon_cx, icon_cy, sw, sh),
            }
        }
    }

    /// Checkmark icon: thick ✓ shape using filled rects for the two legs.
    fn drawCheckmark(data: []u8, stride: u32, cx: u32, cy: u32, sw: u32, sh: u32) void {
        const icx: i32 = @intCast(cx);
        const icy: i32 = @intCast(cy);

        // Short downward leg (left part going down-right)
        var i: i32 = 0;
        while (i < 6) : (i += 1) {
            const px = icx - 4 + i;
            const py = icy + i - 1;
            // 3px thick
            var t: i32 = -1;
            while (t <= 1) : (t += 1) {
                const fpx = px + t;
                if (fpx >= 0 and py >= 0 and fpx < @as(i32, @intCast(sw)) and py < @as(i32, @intCast(sh))) {
                    setPixel(data, stride, @intCast(fpx), @intCast(py), 0xFF, 0xFF, 0xFF);
                }
            }
        }
        // Long upward leg (right part going up-right)
        i = 0;
        while (i < 8) : (i += 1) {
            const px = icx + 2 + i;
            const py = icy + 4 - i;
            var t: i32 = -1;
            while (t <= 1) : (t += 1) {
                const fpx = px + t;
                if (fpx >= 0 and py >= 0 and fpx < @as(i32, @intCast(sw)) and py < @as(i32, @intCast(sh))) {
                    setPixel(data, stride, @intCast(fpx), @intCast(py), 0xFF, 0xFF, 0xFF);
                }
            }
        }
    }

    /// X icon: thick diagonal cross using filled lines.
    fn drawXIcon(data: []u8, stride: u32, cx: u32, cy: u32, sw: u32, sh: u32) void {
        const icx: i32 = @intCast(cx);
        const icy: i32 = @intCast(cy);
        const half: i32 = 6;

        // Both diagonals, 3px thick
        var i: i32 = -half;
        while (i <= half) : (i += 1) {
            // Top-left to bottom-right diagonal
            var t: i32 = -1;
            while (t <= 1) : (t += 1) {
                const px1 = icx + i + t;
                const py1 = icy + i;
                if (px1 >= 0 and py1 >= 0 and px1 < @as(i32, @intCast(sw)) and py1 < @as(i32, @intCast(sh))) {
                    setPixel(data, stride, @intCast(px1), @intCast(py1), 0xFF, 0xFF, 0xFF);
                }
                // Top-right to bottom-left diagonal
                const px2 = icx - i + t;
                const py2 = icy + i;
                if (px2 >= 0 and py2 >= 0 and px2 < @as(i32, @intCast(sw)) and py2 < @as(i32, @intCast(sh))) {
                    setPixel(data, stride, @intCast(px2), @intCast(py2), 0xFF, 0xFF, 0xFF);
                }
            }
        }
    }

    fn setPixel(data: []u8, stride: u32, px: u32, py: u32, r: u8, g: u8, b: u8) void {
        const bpp = ShmBuffer.bpp;
        const offset = @as(usize, py) * stride + @as(usize, px) * bpp;
        if (offset + 3 < data.len) {
            data[offset + 0] = b;
            data[offset + 1] = g;
            data[offset + 2] = r;
            data[offset + 3] = 0xFF;
        }
    }

    fn blendPixel(data: []u8, stride: u32, px: u32, py: u32, r: u8, g: u8, b: u8, a: u8) void {
        const bpp = ShmBuffer.bpp;
        const offset = @as(usize, py) * stride + @as(usize, px) * bpp;
        if (offset + 3 >= data.len) return;
        const alpha = @as(u16, a);
        const inv_alpha = 255 - alpha;
        data[offset + 0] = @intCast((@as(u16, b) * alpha + @as(u16, data[offset + 0]) * inv_alpha) / 255);
        data[offset + 1] = @intCast((@as(u16, g) * alpha + @as(u16, data[offset + 1]) * inv_alpha) / 255);
        data[offset + 2] = @intCast((@as(u16, r) * alpha + @as(u16, data[offset + 2]) * inv_alpha) / 255);
        data[offset + 3] = 0xFF;
    }

    fn fillRoundedRectAlpha(data: []u8, stride: u32, rx: u32, ry: u32, rw: u32, rh: u32, sw: u32, sh: u32, radius: u32, r: u8, g: u8, b: u8, a: u8) void {
        const x_end = @min(rx + rw, sw);
        const y_end = @min(ry + rh, sh);
        if (rx >= x_end or ry >= y_end) return;
        const rad = @min(radius, @min(rw / 2, rh / 2));
        const irad: i32 = @intCast(rad);
        const irad_sq = irad * irad;
        for (ry..y_end) |y| {
            for (rx..x_end) |x| {
                const lx = @as(i32, @intCast(x)) - @as(i32, @intCast(rx));
                const ly = @as(i32, @intCast(y)) - @as(i32, @intCast(ry));
                const iw = @as(i32, @intCast(rw));
                const ih = @as(i32, @intCast(rh));
                var in_rect = true;
                if (lx < irad and ly < irad) {
                    const dx = irad - lx - 1;
                    const dy = irad - ly - 1;
                    if (dx * dx + dy * dy > irad_sq) in_rect = false;
                } else if (lx >= iw - irad and ly < irad) {
                    const dx = lx - (iw - irad);
                    const dy = irad - ly - 1;
                    if (dx * dx + dy * dy > irad_sq) in_rect = false;
                } else if (lx < irad and ly >= ih - irad) {
                    const dx = irad - lx - 1;
                    const dy = ly - (ih - irad);
                    if (dx * dx + dy * dy > irad_sq) in_rect = false;
                } else if (lx >= iw - irad and ly >= ih - irad) {
                    const dx = lx - (iw - irad);
                    const dy = ly - (ih - irad);
                    if (dx * dx + dy * dy > irad_sq) in_rect = false;
                }
                if (in_rect) blendPixel(data, stride, @intCast(x), @intCast(y), r, g, b, a);
            }
        }
    }

    fn strokeRoundedRect(data: []u8, stride: u32, rx: u32, ry: u32, rw: u32, rh: u32, sw: u32, sh: u32, radius: u32, thickness: u32, r: u8, g: u8, b: u8, a: u8) void {
        const x_end = @min(rx + rw, sw);
        const y_end = @min(ry + rh, sh);
        if (rx >= x_end or ry >= y_end) return;
        const rad = @min(radius, @min(rw / 2, rh / 2));
        const irad: i32 = @intCast(rad);
        const irad_sq = irad * irad;
        const ithick: i32 = @intCast(thickness);
        const inner_rad = @max(0, irad - ithick);
        const inner_rad_sq = inner_rad * inner_rad;
        for (ry..y_end) |y| {
            for (rx..x_end) |x| {
                const lx = @as(i32, @intCast(x)) - @as(i32, @intCast(rx));
                const ly = @as(i32, @intCast(y)) - @as(i32, @intCast(ry));
                const iw = @as(i32, @intCast(rw));
                const ih = @as(i32, @intCast(rh));
                var in_outer = true;
                if (lx < irad and ly < irad) {
                    const dx = irad - lx - 1;
                    const dy = irad - ly - 1;
                    if (dx * dx + dy * dy > irad_sq) in_outer = false;
                } else if (lx >= iw - irad and ly < irad) {
                    const dx = lx - (iw - irad);
                    const dy = irad - ly - 1;
                    if (dx * dx + dy * dy > irad_sq) in_outer = false;
                } else if (lx < irad and ly >= ih - irad) {
                    const dx = irad - lx - 1;
                    const dy = ly - (ih - irad);
                    if (dx * dx + dy * dy > irad_sq) in_outer = false;
                } else if (lx >= iw - irad and ly >= ih - irad) {
                    const dx = lx - (iw - irad);
                    const dy = ly - (ih - irad);
                    if (dx * dx + dy * dy > irad_sq) in_outer = false;
                }
                if (!in_outer) continue;
                if (inner_rad > 0) {
                    const ilx = lx - ithick;
                    const ily = ly - ithick;
                    const iiw = iw - ithick * 2;
                    const iih = ih - ithick * 2;
                    if (ilx >= 0 and ilx < iiw and ily >= 0 and ily < iih) {
                        var in_inner = true;
                        if (ilx < inner_rad and ily < inner_rad) {
                            const dx = inner_rad - ilx - 1;
                            const dy = inner_rad - ily - 1;
                            if (dx * dx + dy * dy <= inner_rad_sq) in_inner = false;
                        } else if (ilx >= iiw - inner_rad and ily < inner_rad) {
                            const dx = ilx - (iiw - inner_rad);
                            const dy = inner_rad - ily - 1;
                            if (dx * dx + dy * dy <= inner_rad_sq) in_inner = false;
                        } else if (ilx < inner_rad and ily >= iih - inner_rad) {
                            const dx = inner_rad - ilx - 1;
                            const dy = ily - (iih - inner_rad);
                            if (dx * dx + dy * dy <= inner_rad_sq) in_inner = false;
                        } else if (ilx >= iiw - inner_rad and ily >= iih - inner_rad) {
                            const dx = ilx - (iiw - inner_rad);
                            const dy = ily - (iih - inner_rad);
                            if (dx * dx + dy * dy <= inner_rad_sq) in_inner = false;
                        }
                        if (in_inner) continue;
                    }
                }
                blendPixel(data, stride, @intCast(x), @intCast(y), r, g, b, a);
            }
        }
    }

    fn commitBuffer(self: *ScrollingOverlay) void {
        const buf = &(self.buffers[self.current_buf] orelse return);
        wl.c.wl_surface_attach(self.surface.?, buf.wl_buffer, 0, 0);
        wl.c.wl_surface_damage_buffer(self.surface.?, 0, 0, @intCast(self.surface_width), @intCast(self.surface_height));
        wl.c.wl_surface_commit(self.surface.?);
        self.current_buf +%= 1;
    }

    fn scheduleRedraw(self: *ScrollingOverlay) void {
        self.needs_redraw = true;
        if (!self.frame_pending) {
            self.frame_pending = true;
            const cb = wl.c.wl_surface_frame(self.surface.?) orelse return;
            _ = wl.c.wl_callback_add_listener(cb, &scroll_frame_listener, self);
            wl.c.wl_surface_commit(self.surface.?);
        }
    }

    pub fn run(self: *ScrollingOverlay) !ScrollingAction {
        while (!self.done) {
            if (wl.c.wl_display_dispatch(self.display) == -1)
                return error.WaylandDispatchFailed;
        }
        return self.action;
    }

    /// Non-blocking dispatch; returns true if an action was triggered.
    pub fn dispatchNonBlocking(self: *ScrollingOverlay) !bool {
        _ = wl.c.wl_display_flush(self.display);
        if (wl.c.wl_display_prepare_read(self.display) != 0) {
            _ = wl.c.wl_display_dispatch_pending(self.display);
            return self.done;
        }
        var pollfd = [1]posix.pollfd{.{
            .fd = wl.c.wl_display_get_fd(self.display),
            .events = posix.POLL.IN,
            .revents = 0,
        }};
        const ready = posix.poll(&pollfd, 0) catch 0;
        if (ready > 0) {
            _ = wl.c.wl_display_read_events(self.display);
            _ = wl.c.wl_display_dispatch_pending(self.display);
        } else {
            wl.c.wl_display_cancel_read(self.display);
        }
        return self.done;
    }

    pub fn deinit(self: *ScrollingOverlay) void {
        if (self.pointer) |ptr| wl.c.wl_pointer_destroy(ptr);
        if (self.cursor_surface) |s| wl.c.wl_surface_destroy(s);
        if (self.cursor_theme) |t| wl.c.wl_cursor_theme_destroy(t);
        for (&self.buffers) |*buf| {
            if (buf.*) |*b| b.destroy();
        }
        if (self.layer_surface) |ls| wl.c.zwlr_layer_surface_v1_destroy(ls);
        if (self.surface) |s| wl.c.wl_surface_destroy(s);
    }
};

fn scrollFrameCallback(data: ?*anyopaque, cb: ?*wl.c.wl_callback, _: u32) callconv(.c) void {
    const self: *ScrollingOverlay = @ptrCast(@alignCast(data));
    wl.c.wl_callback_destroy(cb);
    self.frame_pending = false;
    if (self.done) return;
    self.needs_redraw = false;
    self.renderToBuffer();
    self.commitBuffer();
    self.scheduleRedraw();
}

const scroll_frame_listener: wl.c.wl_callback_listener = .{ .done = scrollFrameCallback };

fn scrollLayerSurfaceConfigure(data: ?*anyopaque, surface: ?*wl.c.zwlr_layer_surface_v1, serial: u32, w: u32, h: u32) callconv(.c) void {
    const self: *ScrollingOverlay = @ptrCast(@alignCast(data));
    self.surface_width = w;
    self.surface_height = h;
    self.configured = true;
    wl.c.zwlr_layer_surface_v1_ack_configure(surface, serial);
}

fn scrollLayerSurfaceClosed(data: ?*anyopaque, _: ?*wl.c.zwlr_layer_surface_v1) callconv(.c) void {
    const self: *ScrollingOverlay = @ptrCast(@alignCast(data));
    self.action = .cancel;
    self.done = true;
}

const scroll_layer_surface_listener: wl.c.zwlr_layer_surface_v1_listener = .{
    .configure = scrollLayerSurfaceConfigure,
    .closed = scrollLayerSurfaceClosed,
};

fn scrollPointerEnter(data: ?*anyopaque, _: ?*wl.c.wl_pointer, serial: u32, _: ?*wl.c.wl_surface, sx: wl.c.wl_fixed_t, sy: wl.c.wl_fixed_t) callconv(.c) void {
    const self: *ScrollingOverlay = @ptrCast(@alignCast(data));
    self.pointer_serial = serial;
    self.current_x = wl.c.wl_fixed_to_int(sx);
    self.current_y = wl.c.wl_fixed_to_int(sy);
    self.setCursorDefault(serial);
}

fn scrollPointerLeave(_: ?*anyopaque, _: ?*wl.c.wl_pointer, _: u32, _: ?*wl.c.wl_surface) callconv(.c) void {}

fn scrollPointerMotion(data: ?*anyopaque, _: ?*wl.c.wl_pointer, _: u32, sx: wl.c.wl_fixed_t, sy: wl.c.wl_fixed_t) callconv(.c) void {
    const self: *ScrollingOverlay = @ptrCast(@alignCast(data));
    self.current_x = wl.c.wl_fixed_to_int(sx);
    self.current_y = wl.c.wl_fixed_to_int(sy);
    const prev = self.hovered_button;
    self.hovered_button = self.hitTestButtons(self.current_x, self.current_y);
    if (self.hovered_button != null and prev == null) {
        self.setCursorHand();
    } else if (self.hovered_button == null and prev != null) {
        self.setCursorDefault(self.pointer_serial);
    }
}

fn scrollPointerButton(data: ?*anyopaque, _: ?*wl.c.wl_pointer, _: u32, _: u32, button: u32, state: u32) callconv(.c) void {
    const self: *ScrollingOverlay = @ptrCast(@alignCast(data));
    const BTN_LEFT = 0x110;
    if (button == BTN_LEFT and state == wl.c.WL_POINTER_BUTTON_STATE_PRESSED) {
        if (self.hitTestButtons(self.current_x, self.current_y)) |btn| {
            switch (btn) {
                .confirm => {
                    self.action = .confirm;
                    self.done = true;
                },
                .cancel => {
                    self.action = .cancel;
                    self.done = true;
                },
            }
        }
    }
}

fn scrollPointerAxis(_: ?*anyopaque, _: ?*wl.c.wl_pointer, _: u32, _: u32, _: wl.c.wl_fixed_t) callconv(.c) void {}
fn scrollPointerFrame(_: ?*anyopaque, _: ?*wl.c.wl_pointer) callconv(.c) void {}
fn scrollPointerAxisSource(_: ?*anyopaque, _: ?*wl.c.wl_pointer, _: u32) callconv(.c) void {}

const scroll_pointer_listener: wl.c.wl_pointer_listener = .{
    .enter = scrollPointerEnter,
    .leave = scrollPointerLeave,
    .motion = scrollPointerMotion,
    .button = scrollPointerButton,
    .axis = scrollPointerAxis,
    .frame = scrollPointerFrame,
    .axis_source = scrollPointerAxisSource,
};
