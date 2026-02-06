const std = @import("std");
const posix = std.posix;
const wl = @import("wayland.zig");
const ShmBuffer = @import("shm.zig").ShmBuffer;
const Rect = @import("image.zig").Rect;

/// Overlay shown during screen recording.
/// Transparent background with a red selection border, timer, and pause/stop buttons.
pub const RecordingOverlay = struct {
    // Wayland globals (borrowed references)
    display: *wl.c.wl_display = undefined,
    compositor: *wl.c.wl_compositor = undefined,
    shm: *wl.c.wl_shm = undefined,
    seat: *wl.c.wl_seat = undefined,
    layer_shell: *wl.c.zwlr_layer_shell_v1 = undefined,
    output: *wl.c.wl_output = undefined,

    // Layer shell surface
    surface: ?*wl.c.wl_surface = null,
    layer_surface: ?*wl.c.zwlr_layer_surface_v1 = null,

    // Input
    pointer: ?*wl.c.wl_pointer = null,
    cursor_theme: ?*wl.c.wl_cursor_theme = null,
    cursor_surface: ?*wl.c.wl_surface = null,

    // Surface dimensions
    surface_width: u32 = 0,
    surface_height: u32 = 0,
    configured: bool = false,

    // SHM buffers (double-buffered)
    buffers: [2]?ShmBuffer = .{ null, null },
    current_buf: u1 = 0,
    allocator: std.mem.Allocator = undefined,

    // Rendering state
    needs_redraw: bool = false,
    frame_pending: bool = false,

    // Pointer state
    pointer_serial: u32 = 0,
    current_x: i32 = 0,
    current_y: i32 = 0,
    hovered_button: ?ControlButton = null,

    // Recording region
    region: Rect = .{ .x = 0, .y = 0, .width = 0, .height = 0 },

    // Timer
    start_time_ns: i128 = 0,
    paused: bool = false,
    paused_elapsed_ns: i128 = 0, // accumulated time before current pause
    pause_start_ns: i128 = 0,

    // Result
    action: RecordAction = .none,
    done: bool = false,

    pub const RecordAction = enum {
        none,
        pause,
        stop,
    };

    pub const ControlButton = enum {
        pause,
        stop,
    };

    // ── Layout constants ────────────────────────────────────────────
    const control_height: u32 = 40;
    const control_padding: u32 = 8;
    const control_gap: u32 = 12;
    const btn_size: u32 = 36;
    const btn_spacing: u32 = 8;
    const btn_corner_radius: u32 = 10;
    const timer_width: u32 = 60;
    const control_corner_radius: u32 = 12;
    // total: padding + timer + spacing + btn + spacing + btn + padding
    const control_total_width: u32 = control_padding + timer_width + btn_spacing + btn_size + btn_spacing + btn_size + control_padding;

    fn controlBarRect(self: *const RecordingOverlay) Rect {
        const center_x = self.region.x + self.region.width / 2;
        const base_x = if (center_x >= control_total_width / 2) center_x - control_total_width / 2 else 0;
        const clamped_x = @min(base_x, self.surface_width -| control_total_width);

        const below_y = self.region.y + self.region.height + control_gap;
        const by = if (below_y + control_height <= self.surface_height)
            below_y
        else if (self.region.y >= control_height + control_gap)
            self.region.y - control_height - control_gap
        else
            self.region.y + self.region.height + 4;

        return .{
            .x = clamped_x,
            .y = by,
            .width = control_total_width,
            .height = control_height,
        };
    }

    fn controlButtonRect(self: *const RecordingOverlay, btn: ControlButton) Rect {
        const bar = self.controlBarRect();
        const by = bar.y + (bar.height -| btn_size) / 2;
        return switch (btn) {
            .pause => .{
                .x = bar.x + control_padding + timer_width + btn_spacing,
                .y = by,
                .width = btn_size,
                .height = btn_size,
            },
            .stop => .{
                .x = bar.x + control_padding + timer_width + btn_spacing + btn_size + btn_spacing,
                .y = by,
                .width = btn_size,
                .height = btn_size,
            },
        };
    }

    fn hitTestControls(self: *const RecordingOverlay, px: i32, py: i32) ?ControlButton {
        if (px < 0 or py < 0) return null;
        const ux: u32 = @intCast(px);
        const uy: u32 = @intCast(py);
        inline for (.{ ControlButton.pause, ControlButton.stop }) |btn| {
            const br = self.controlButtonRect(btn);
            if (ux >= br.x and ux < br.x + br.width and
                uy >= br.y and uy < br.y + br.height)
            {
                return btn;
            }
        }
        return null;
    }

    pub fn init(self: *RecordingOverlay, allocator: std.mem.Allocator) !void {
        self.allocator = allocator;
        self.start_time_ns = std.time.nanoTimestamp();

        self.cursor_theme = wl.c.wl_cursor_theme_load(null, 24, self.shm);
        self.cursor_surface = wl.c.wl_compositor_create_surface(self.compositor);

        self.surface = wl.c.wl_compositor_create_surface(self.compositor) orelse
            return error.FailedToCreateSurface;

        self.layer_surface = wl.c.zwlr_layer_shell_v1_get_layer_surface(
            self.layer_shell,
            self.surface.?,
            self.output,
            wl.c.ZWLR_LAYER_SHELL_V1_LAYER_OVERLAY,
            "screenshot-recording",
        ) orelse return error.FailedToCreateLayerSurface;

        wl.c.zwlr_layer_surface_v1_set_anchor(
            self.layer_surface.?,
            wl.c.ZWLR_LAYER_SURFACE_V1_ANCHOR_TOP |
                wl.c.ZWLR_LAYER_SURFACE_V1_ANCHOR_BOTTOM |
                wl.c.ZWLR_LAYER_SURFACE_V1_ANCHOR_LEFT |
                wl.c.ZWLR_LAYER_SURFACE_V1_ANCHOR_RIGHT,
        );
        wl.c.zwlr_layer_surface_v1_set_exclusive_zone(self.layer_surface.?, -1);
        // No keyboard grab — let the user type in other apps while recording
        wl.c.zwlr_layer_surface_v1_set_keyboard_interactivity(
            self.layer_surface.?,
            wl.c.ZWLR_LAYER_SURFACE_V1_KEYBOARD_INTERACTIVITY_NONE,
        );

        _ = wl.c.zwlr_layer_surface_v1_add_listener(
            self.layer_surface.?,
            &rec_layer_surface_listener,
            self,
        );

        wl.c.wl_surface_commit(self.surface.?);

        self.pointer = wl.c.wl_seat_get_pointer(self.seat);
        if (self.pointer) |ptr| {
            _ = wl.c.wl_pointer_add_listener(ptr, &rec_pointer_listener, self);
        }
        // No keyboard listener — we don't grab keyboard during recording

        while (!self.configured) {
            if (wl.c.wl_display_roundtrip(self.display) == -1)
                return error.WaylandRoundtripFailed;
        }

        try self.createBuffers();
        self.updateInputRegion();
        self.renderToBuffer();
        self.commitBuffer();
        // Start the continuous redraw loop for the timer
        self.scheduleRedraw();
    }

    /// Set the input region to only cover the control bar, so pointer events
    /// pass through everywhere else (the user can interact with other apps).
    fn updateInputRegion(self: *RecordingOverlay) void {
        const bar = self.controlBarRect();
        const region = wl.c.wl_compositor_create_region(self.compositor) orelse return;
        wl.c.wl_region_add(region, @intCast(bar.x), @intCast(bar.y), @intCast(bar.width), @intCast(bar.height));
        wl.c.wl_surface_set_input_region(self.surface.?, region);
        wl.c.wl_region_destroy(region);
    }

    fn createBuffers(self: *RecordingOverlay) !void {
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

    fn getElapsedSeconds(self: *const RecordingOverlay) u32 {
        const now = std.time.nanoTimestamp();
        var elapsed = self.paused_elapsed_ns;
        if (!self.paused) {
            elapsed += now - self.start_time_ns - self.paused_elapsed_ns;
            // Re-derive: total elapsed = (now - start) minus time spent paused
            // paused_elapsed_ns accumulates pause durations
            // Actually let's simplify the model:
        }
        // Simpler: track "effective start". When pausing, record how much time passed.
        // When resuming, advance start_time to account for the gap.
        // Already using paused_elapsed_ns as accumulated pause duration.
        if (self.paused) {
            // Time recorded before this pause
            const before_pause = self.pause_start_ns - self.start_time_ns - self.paused_elapsed_ns + self.paused_elapsed_ns;
            _ = before_pause;
            // Actually let's just compute it correctly:
            const total = self.pause_start_ns - self.start_time_ns;
            const paused_dur = self.paused_elapsed_ns;
            const active = total - paused_dur;
            return @intCast(@max(0, @divFloor(active, 1_000_000_000)));
        } else {
            const total = now - self.start_time_ns;
            const paused_dur = self.paused_elapsed_ns;
            const active = total - paused_dur;
            return @intCast(@max(0, @divFloor(active, 1_000_000_000)));
        }
    }

    fn setCursorDefault(self: *RecordingOverlay, serial: u32) void {
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

    fn setCursorHand(self: *RecordingOverlay) void {
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

    // ── Rendering ────────────────────────────────────────────────────

    fn renderToBuffer(self: *RecordingOverlay) void {
        const buf = &(self.buffers[self.current_buf] orelse return);
        const data = buf.data;
        const stride = buf.stride;

        // Clear to fully transparent
        @memset(data, 0);

        // Draw red border around recording region
        self.drawRecordingBorder(data, stride);

        // Draw control bar
        self.drawControlBar(data, stride);
    }

    fn drawRecordingBorder(self: *RecordingOverlay, data: []u8, stride: u32) void {
        const r = self.region;
        const sw = self.surface_width;
        const sh = self.surface_height;
        const border: u32 = 2;

        // Red border (BGRA: B=0x30, G=0x30, R=0xF0)
        const max_x = @min(r.x + r.width, sw);
        const max_y = @min(r.y + r.height, sh);

        // Top
        fillRect(data, stride, r.x, r.y -| border, r.width + border, border, sw, sh, 0xF0, 0x40, 0x40);
        // Bottom
        fillRect(data, stride, r.x, max_y, r.width + border, border, sw, sh, 0xF0, 0x40, 0x40);
        // Left
        fillRect(data, stride, r.x -| border, r.y -| border, border, r.height + border * 2, sw, sh, 0xF0, 0x40, 0x40);
        // Right
        fillRect(data, stride, max_x, r.y -| border, border, r.height + border * 2, sw, sh, 0xF0, 0x40, 0x40);
    }

    fn drawControlBar(self: *RecordingOverlay, data: []u8, stride: u32) void {
        const bar = self.controlBarRect();
        const sw = self.surface_width;
        const sh = self.surface_height;

        // Bar background
        fillRoundedRectAlpha(data, stride, bar.x, bar.y, bar.width, bar.height, sw, sh, control_corner_radius, 0x1A, 0x1A, 0x1A, 0xE0);

        // Timer text
        const elapsed = self.getElapsedSeconds();
        const minutes = elapsed / 60;
        const seconds = elapsed % 60;
        const timer_x = bar.x + control_padding;
        const timer_y = bar.y + (bar.height -| 14) / 2; // 14 = digit height (2x scale of 7)

        // Draw MM:SS
        self.drawDigit(data, stride, sw, sh, timer_x, timer_y, @intCast(minutes / 10));
        self.drawDigit(data, stride, sw, sh, timer_x + 10, timer_y, @intCast(minutes % 10));
        self.drawColon(data, stride, sw, sh, timer_x + 20, timer_y);
        self.drawDigit(data, stride, sw, sh, timer_x + 26, timer_y, @intCast(seconds / 10));
        self.drawDigit(data, stride, sw, sh, timer_x + 36, timer_y, @intCast(seconds % 10));

        // Recording indicator dot (red, blinks when paused)
        if (!self.paused or (elapsed & 1) == 0) {
            const dot_x: i32 = @intCast(timer_x + 50);
            const dot_y: i32 = @intCast(timer_y + 7);
            drawFilledCircle(data, stride, dot_x, dot_y, 4, sw, sh, 0xF0, 0x40, 0x40);
        }

        // Pause button
        const pause_br = self.controlButtonRect(.pause);
        const pause_hovered = self.hovered_button != null and self.hovered_button.? == .pause;
        if (pause_hovered) {
            fillRoundedRectAlpha(data, stride, pause_br.x, pause_br.y, pause_br.width, pause_br.height, sw, sh, btn_corner_radius, 0x50, 0x50, 0x50, 0xE0);
        } else {
            fillRoundedRectAlpha(data, stride, pause_br.x, pause_br.y, pause_br.width, pause_br.height, sw, sh, btn_corner_radius, 0x33, 0x33, 0x33, 0xD0);
        }
        const pcx = pause_br.x + pause_br.width / 2;
        const pcy = pause_br.y + pause_br.height / 2;
        if (self.paused) {
            // Draw play triangle
            self.drawPlayIcon(data, stride, pcx, pcy, sw, sh);
        } else {
            // Draw pause bars
            fillRect(data, stride, pcx -| 5, pcy -| 6, 3, 12, sw, sh, 0xFF, 0xFF, 0xFF);
            fillRect(data, stride, pcx + 2, pcy -| 6, 3, 12, sw, sh, 0xFF, 0xFF, 0xFF);
        }

        // Stop button
        const stop_br = self.controlButtonRect(.stop);
        const stop_hovered = self.hovered_button != null and self.hovered_button.? == .stop;
        if (stop_hovered) {
            fillRoundedRectAlpha(data, stride, stop_br.x, stop_br.y, stop_br.width, stop_br.height, sw, sh, btn_corner_radius, 0x50, 0x50, 0x50, 0xE0);
        } else {
            fillRoundedRectAlpha(data, stride, stop_br.x, stop_br.y, stop_br.width, stop_br.height, sw, sh, btn_corner_radius, 0x33, 0x33, 0x33, 0xD0);
        }
        // Stop square
        const scx = stop_br.x + stop_br.width / 2;
        const scy = stop_br.y + stop_br.height / 2;
        fillRect(data, stride, scx -| 5, scy -| 5, 10, 10, sw, sh, 0xF0, 0x40, 0x40);
    }

    fn drawPlayIcon(_: *const RecordingOverlay, data: []u8, stride: u32, cx: u32, cy: u32, sw: u32, sh: u32) void {
        // Simple triangle pointing right
        var row: i32 = -6;
        while (row <= 6) : (row += 1) {
            const abs_row = if (row < 0) -row else row;
            const width = 6 - @divFloor(abs_row * 6, 6);
            var col: i32 = 0;
            while (col < width) : (col += 1) {
                const px_val: i32 = @as(i32, @intCast(cx)) - 3 + col;
                const py_val: i32 = @as(i32, @intCast(cy)) + row;
                if (px_val >= 0 and py_val >= 0) {
                    const px: u32 = @intCast(px_val);
                    const py: u32 = @intCast(py_val);
                    if (px < sw and py < sh) {
                        setPixel(data, stride, px, py, 0xFF, 0xFF, 0xFF);
                    }
                }
            }
        }
    }

    // ── Bitmap digit rendering (2x scale, 5x7 base) ────────────────

    const digit_glyphs = [10][7]u5{
        .{ 0b01110, 0b10001, 0b10011, 0b10101, 0b11001, 0b10001, 0b01110 }, // 0
        .{ 0b00100, 0b01100, 0b00100, 0b00100, 0b00100, 0b00100, 0b01110 }, // 1
        .{ 0b01110, 0b10001, 0b00001, 0b00110, 0b01000, 0b10000, 0b11111 }, // 2
        .{ 0b01110, 0b10001, 0b00001, 0b00110, 0b00001, 0b10001, 0b01110 }, // 3
        .{ 0b00010, 0b00110, 0b01010, 0b10010, 0b11111, 0b00010, 0b00010 }, // 4
        .{ 0b11111, 0b10000, 0b11110, 0b00001, 0b00001, 0b10001, 0b01110 }, // 5
        .{ 0b00110, 0b01000, 0b10000, 0b11110, 0b10001, 0b10001, 0b01110 }, // 6
        .{ 0b11111, 0b00001, 0b00010, 0b00100, 0b01000, 0b01000, 0b01000 }, // 7
        .{ 0b01110, 0b10001, 0b10001, 0b01110, 0b10001, 0b10001, 0b01110 }, // 8
        .{ 0b01110, 0b10001, 0b10001, 0b01111, 0b00001, 0b00010, 0b01100 }, // 9
    };

    fn drawDigit(self: *const RecordingOverlay, data: []u8, stride: u32, sw: u32, sh: u32, x: u32, y: u32, digit: u4) void {
        _ = self;
        const glyph = digit_glyphs[digit];
        for (0..7) |row| {
            for (0..5) |col| {
                if ((glyph[row] >> @intCast(4 - col)) & 1 == 1) {
                    // 2x scale
                    const px = x + @as(u32, @intCast(col)) * 2;
                    const py = y + @as(u32, @intCast(row)) * 2;
                    if (px + 1 < sw and py + 1 < sh) {
                        setPixel(data, stride, px, py, 0xFF, 0xFF, 0xFF);
                        setPixel(data, stride, px + 1, py, 0xFF, 0xFF, 0xFF);
                        setPixel(data, stride, px, py + 1, 0xFF, 0xFF, 0xFF);
                        setPixel(data, stride, px + 1, py + 1, 0xFF, 0xFF, 0xFF);
                    }
                }
            }
        }
    }

    fn drawColon(self: *const RecordingOverlay, data: []u8, stride: u32, sw: u32, sh: u32, x: u32, y: u32) void {
        _ = self;
        // Two dots
        if (x + 2 < sw and y + 10 < sh) {
            setPixel(data, stride, x, y + 4, 0xFF, 0xFF, 0xFF);
            setPixel(data, stride, x + 1, y + 4, 0xFF, 0xFF, 0xFF);
            setPixel(data, stride, x, y + 5, 0xFF, 0xFF, 0xFF);
            setPixel(data, stride, x + 1, y + 5, 0xFF, 0xFF, 0xFF);

            setPixel(data, stride, x, y + 9, 0xFF, 0xFF, 0xFF);
            setPixel(data, stride, x + 1, y + 9, 0xFF, 0xFF, 0xFF);
            setPixel(data, stride, x, y + 10, 0xFF, 0xFF, 0xFF);
            setPixel(data, stride, x + 1, y + 10, 0xFF, 0xFF, 0xFF);
        }
    }

    // ── Shared pixel helpers ────────────────────────────────────────

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

    fn fillRect(data: []u8, stride: u32, rx: u32, ry: u32, rw: u32, rh: u32, sw: u32, sh: u32, r: u8, g: u8, b: u8) void {
        const x_end = @min(rx + rw, sw);
        const y_end = @min(ry + rh, sh);
        if (rx >= x_end or ry >= y_end) return;
        for (ry..y_end) |y| {
            for (rx..x_end) |x| {
                setPixel(data, stride, @intCast(x), @intCast(y), r, g, b);
            }
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
        data[offset + 3] = @intCast(@min(@as(u16, 255), @as(u16, data[offset + 3]) + alpha));
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

                if (in_rect) {
                    blendPixel(data, stride, @intCast(x), @intCast(y), r, g, b, a);
                }
            }
        }
    }

    fn drawFilledCircle(data: []u8, stride: u32, cx: i32, cy: i32, radius: i32, sw: u32, sh: u32, r: u8, g: u8, b: u8) void {
        const r_sq = radius * radius;
        var dy: i32 = -radius;
        while (dy <= radius) : (dy += 1) {
            var dx: i32 = -radius;
            while (dx <= radius) : (dx += 1) {
                if (dx * dx + dy * dy <= r_sq) {
                    const px = cx + dx;
                    const py = cy + dy;
                    if (px >= 0 and py >= 0) {
                        const upx: u32 = @intCast(px);
                        const upy: u32 = @intCast(py);
                        if (upx < sw and upy < sh) {
                            setPixel(data, stride, upx, upy, r, g, b);
                        }
                    }
                }
            }
        }
    }

    fn commitBuffer(self: *RecordingOverlay) void {
        const buf = &(self.buffers[self.current_buf] orelse return);
        wl.c.wl_surface_attach(self.surface.?, buf.wl_buffer, 0, 0);
        wl.c.wl_surface_damage_buffer(self.surface.?, 0, 0, @intCast(self.surface_width), @intCast(self.surface_height));
        wl.c.wl_surface_commit(self.surface.?);
        self.current_buf +%= 1;
    }

    fn scheduleRedraw(self: *RecordingOverlay) void {
        self.needs_redraw = true;
        if (!self.frame_pending) {
            self.frame_pending = true;
            const cb = wl.c.wl_surface_frame(self.surface.?) orelse return;
            _ = wl.c.wl_callback_add_listener(cb, &rec_frame_listener, self);
            wl.c.wl_surface_commit(self.surface.?);
        }
    }

    pub const RunResult = struct {
        action: RecordAction,
        serial: u32,
    };

    pub fn run(self: *RecordingOverlay) !RunResult {
        while (!self.done) {
            if (wl.c.wl_display_dispatch(self.display) == -1)
                return error.WaylandDispatchFailed;
        }
        return .{
            .action = self.action,
            .serial = self.pointer_serial,
        };
    }

    pub fn deinit(self: *RecordingOverlay) void {
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

// ── Frame callback ──────────────────────────────────────────────────────────

fn recFrameCallback(data: ?*anyopaque, cb: ?*wl.c.wl_callback, _: u32) callconv(.c) void {
    const self: *RecordingOverlay = @ptrCast(@alignCast(data));
    wl.c.wl_callback_destroy(cb);
    self.frame_pending = false;

    if (self.done) return;

    self.needs_redraw = false;
    self.renderToBuffer();
    self.commitBuffer();
    self.scheduleRedraw();
}

const rec_frame_listener: wl.c.wl_callback_listener = .{
    .done = recFrameCallback,
};

// ── Layer surface listener ──────────────────────────────────────────────────

fn recLayerSurfaceConfigure(data: ?*anyopaque, surface: ?*wl.c.zwlr_layer_surface_v1, serial: u32, w: u32, h: u32) callconv(.c) void {
    const self: *RecordingOverlay = @ptrCast(@alignCast(data));
    self.surface_width = w;
    self.surface_height = h;
    self.configured = true;
    wl.c.zwlr_layer_surface_v1_ack_configure(surface, serial);
}

fn recLayerSurfaceClosed(data: ?*anyopaque, _: ?*wl.c.zwlr_layer_surface_v1) callconv(.c) void {
    const self: *RecordingOverlay = @ptrCast(@alignCast(data));
    self.action = .stop;
    self.done = true;
}

const rec_layer_surface_listener: wl.c.zwlr_layer_surface_v1_listener = .{
    .configure = recLayerSurfaceConfigure,
    .closed = recLayerSurfaceClosed,
};

// ── Pointer listener ────────────────────────────────────────────────────────

fn recPointerEnter(data: ?*anyopaque, _: ?*wl.c.wl_pointer, serial: u32, _: ?*wl.c.wl_surface, sx: wl.c.wl_fixed_t, sy: wl.c.wl_fixed_t) callconv(.c) void {
    const self: *RecordingOverlay = @ptrCast(@alignCast(data));
    self.pointer_serial = serial;
    self.current_x = wl.c.wl_fixed_to_int(sx);
    self.current_y = wl.c.wl_fixed_to_int(sy);
    self.setCursorDefault(serial);
}

fn recPointerLeave(_: ?*anyopaque, _: ?*wl.c.wl_pointer, _: u32, _: ?*wl.c.wl_surface) callconv(.c) void {}

fn recPointerMotion(data: ?*anyopaque, _: ?*wl.c.wl_pointer, _: u32, sx: wl.c.wl_fixed_t, sy: wl.c.wl_fixed_t) callconv(.c) void {
    const self: *RecordingOverlay = @ptrCast(@alignCast(data));
    self.current_x = wl.c.wl_fixed_to_int(sx);
    self.current_y = wl.c.wl_fixed_to_int(sy);

    const prev = self.hovered_button;
    self.hovered_button = self.hitTestControls(self.current_x, self.current_y);

    if (self.hovered_button != null and prev == null) {
        self.setCursorHand();
    } else if (self.hovered_button == null and prev != null) {
        self.setCursorDefault(self.pointer_serial);
    }
}

fn recPointerButton(data: ?*anyopaque, _: ?*wl.c.wl_pointer, _: u32, _: u32, button: u32, state: u32) callconv(.c) void {
    const self: *RecordingOverlay = @ptrCast(@alignCast(data));
    const BTN_LEFT = 0x110;

    if (button == BTN_LEFT and state == wl.c.WL_POINTER_BUTTON_STATE_PRESSED) {
        if (self.hitTestControls(self.current_x, self.current_y)) |btn| {
            switch (btn) {
                .pause => {
                    self.action = .pause;
                    // Handle pause state locally
                    if (self.paused) {
                        // Resume: account for pause duration
                        self.paused_elapsed_ns += std.time.nanoTimestamp() - self.pause_start_ns;
                        self.paused = false;
                    } else {
                        // Pause
                        self.pause_start_ns = std.time.nanoTimestamp();
                        self.paused = true;
                    }
                    self.action = .pause;
                    self.done = true;
                },
                .stop => {
                    self.action = .stop;
                    self.done = true;
                },
            }
        }
    }
}

fn recPointerAxis(_: ?*anyopaque, _: ?*wl.c.wl_pointer, _: u32, _: u32, _: wl.c.wl_fixed_t) callconv(.c) void {}
fn recPointerFrame(_: ?*anyopaque, _: ?*wl.c.wl_pointer) callconv(.c) void {}
fn recPointerAxisSource(_: ?*anyopaque, _: ?*wl.c.wl_pointer, _: u32) callconv(.c) void {}

const rec_pointer_listener: wl.c.wl_pointer_listener = .{
    .enter = recPointerEnter,
    .leave = recPointerLeave,
    .motion = recPointerMotion,
    .button = recPointerButton,
    .axis = recPointerAxis,
    .frame = recPointerFrame,
    .axis_source = recPointerAxisSource,
};
