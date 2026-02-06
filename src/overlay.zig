const std = @import("std");
const posix = std.posix;
const wl = @import("wayland.zig");
const ShmBuffer = @import("shm.zig").ShmBuffer;
const Image = @import("image.zig").Image;
const Rect = @import("image.zig").Rect;

/// State for the fullscreen selection overlay.
/// Uses wlr-layer-shell to create an overlay surface, renders the captured
/// screenshot as background (with a dark tint outside the selection), and
/// lets the user click-drag to select a rectangular region.
pub const Overlay = struct {
    // Wayland globals (borrowed references)
    display: *wl.c.wl_display = undefined,
    compositor: *wl.c.wl_compositor = undefined,
    shm: *wl.c.wl_shm = undefined,
    seat: *wl.c.wl_seat = undefined,
    layer_shell: *wl.c.zwlr_layer_shell_v1 = undefined,
    output: *wl.c.wl_output = undefined,

    // Layer shell surface objects
    surface: ?*wl.c.wl_surface = null,
    layer_surface: ?*wl.c.zwlr_layer_surface_v1 = null,

    // Input objects
    pointer: ?*wl.c.wl_pointer = null,
    keyboard: ?*wl.c.wl_keyboard = null,

    // Cursor
    cursor_theme: ?*wl.c.wl_cursor_theme = null,
    cursor_surface: ?*wl.c.wl_surface = null,

    // The screenshot image to display as background
    screenshot: *const Image = undefined,

    // Surface dimensions (assigned by compositor via configure)
    surface_width: u32 = 0,
    surface_height: u32 = 0,
    configured: bool = false,

    // SHM buffers (double-buffered: write to one while the other is committed)
    buffers: [2]?ShmBuffer = .{ null, null },
    current_buf: u1 = 0,

    // Rendering state
    needs_redraw: bool = false,
    frame_pending: bool = false,

    // Selection state
    selecting: bool = false,
    start_x: i32 = 0,
    start_y: i32 = 0,
    current_x: i32 = 0,
    current_y: i32 = 0,

    // Pointer enter serial (needed for set_cursor)
    pointer_serial: u32 = 0,

    // Result
    selection: ?Rect = null,
    cancelled: bool = false,
    done: bool = false,

    /// Initialize and show the overlay.
    pub fn init(self: *Overlay) !void {
        // Load cursor theme for crosshair cursor
        self.cursor_theme = wl.c.wl_cursor_theme_load(null, 24, self.shm);
        self.cursor_surface = wl.c.wl_compositor_create_surface(self.compositor);

        self.surface = wl.c.wl_compositor_create_surface(self.compositor) orelse
            return error.FailedToCreateSurface;

        self.layer_surface = wl.c.zwlr_layer_shell_v1_get_layer_surface(
            self.layer_shell,
            self.surface.?,
            self.output,
            wl.c.ZWLR_LAYER_SHELL_V1_LAYER_OVERLAY,
            "screenshot-selection",
        ) orelse return error.FailedToCreateLayerSurface;

        // Anchor to all edges so the surface fills the entire output
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
            wl.c.ZWLR_LAYER_SURFACE_V1_KEYBOARD_INTERACTIVITY_EXCLUSIVE,
        );

        _ = wl.c.zwlr_layer_surface_v1_add_listener(
            self.layer_surface.?,
            &layer_surface_listener,
            self,
        );

        // Initial commit to trigger configure
        wl.c.wl_surface_commit(self.surface.?);

        // Get pointer and keyboard for input
        self.pointer = wl.c.wl_seat_get_pointer(self.seat);
        if (self.pointer) |ptr| {
            _ = wl.c.wl_pointer_add_listener(ptr, &pointer_listener, self);
        }
        self.keyboard = wl.c.wl_seat_get_keyboard(self.seat);
        if (self.keyboard) |kbd| {
            _ = wl.c.wl_keyboard_add_listener(kbd, &keyboard_listener, self);
        }

        // Wait for configure
        while (!self.configured) {
            if (wl.c.wl_display_roundtrip(self.display) == -1)
                return error.WaylandRoundtripFailed;
        }

        // Create double buffers
        try self.createBuffers();

        // Render and commit the initial frame (darkened screenshot, no selection)
        self.renderToBuffer();
        self.commitBuffer();
    }

    fn createBuffers(self: *Overlay) !void {
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

    /// Set the cursor image to a crosshair.
    fn setCursor(self: *Overlay, serial: u32) void {
        const theme = self.cursor_theme orelse return;
        const cursor_sfc = self.cursor_surface orelse return;

        const cursor_names = [_][*:0]const u8{ "crosshair", "cross", "default", "left_ptr" };
        var cursor: ?*wl.c.wl_cursor = null;
        for (cursor_names) |name| {
            cursor = wl.c.wl_cursor_theme_get_cursor(theme, name);
            if (cursor != null) break;
        }

        const cur = cursor orelse return;
        if (cur.image_count == 0) return;
        const image = cur.images[0].*;
        const buffer = wl.c.wl_cursor_image_get_buffer(cur.images[0]) orelse return;

        wl.c.wl_surface_attach(cursor_sfc, buffer, 0, 0);
        wl.c.wl_surface_damage_buffer(cursor_sfc, 0, 0, @intCast(image.width), @intCast(image.height));
        wl.c.wl_surface_commit(cursor_sfc);

        wl.c.wl_pointer_set_cursor(
            self.pointer.?,
            serial,
            cursor_sfc,
            @intCast(image.hotspot_x),
            @intCast(image.hotspot_y),
        );
    }

    /// Render the overlay into the current back buffer.
    fn renderToBuffer(self: *Overlay) void {
        const buf = &(self.buffers[self.current_buf] orelse return);
        const data = buf.data;
        const stride = buf.stride;
        const bpp = ShmBuffer.bpp;

        const sel = if (self.selecting)
            Rect.fromPoints(self.start_x, self.start_y, self.current_x, self.current_y)
        else
            Rect{ .x = 0, .y = 0, .width = 0, .height = 0 };

        for (0..self.surface_height) |y| {
            for (0..self.surface_width) |x| {
                const dst_offset = y * stride + x * bpp;
                const src_offset = y * self.screenshot.stride + x * Image.bpp;

                const ux: u32 = @intCast(x);
                const uy: u32 = @intCast(y);
                const inside_selection = !sel.isEmpty() and
                    ux >= sel.x and ux < sel.x + sel.width and
                    uy >= sel.y and uy < sel.y + sel.height;

                if (src_offset + 3 < self.screenshot.data.len and dst_offset + 3 < data.len) {
                    if (inside_selection) {
                        data[dst_offset + 0] = self.screenshot.data[src_offset + 0];
                        data[dst_offset + 1] = self.screenshot.data[src_offset + 1];
                        data[dst_offset + 2] = self.screenshot.data[src_offset + 2];
                        data[dst_offset + 3] = 0xFF;
                    } else {
                        data[dst_offset + 0] = self.screenshot.data[src_offset + 0] / 3;
                        data[dst_offset + 1] = self.screenshot.data[src_offset + 1] / 3;
                        data[dst_offset + 2] = self.screenshot.data[src_offset + 2] / 3;
                        data[dst_offset + 3] = 0xFF;
                    }
                }
            }
        }

        // Draw selection border (white, 2px)
        if (!sel.isEmpty()) {
            self.drawSelectionBorder(data, stride, sel);
        }
    }

    /// Commit the current back buffer to the surface and swap.
    fn commitBuffer(self: *Overlay) void {
        const buf = &(self.buffers[self.current_buf] orelse return);
        wl.c.wl_surface_attach(self.surface.?, buf.wl_buffer, 0, 0);
        wl.c.wl_surface_damage_buffer(
            self.surface.?,
            0,
            0,
            @intCast(self.surface_width),
            @intCast(self.surface_height),
        );
        wl.c.wl_surface_commit(self.surface.?);
        // Swap to the other buffer for next frame
        self.current_buf +%= 1;
    }

    /// Request a redraw on the next frame callback.
    fn scheduleRedraw(self: *Overlay) void {
        self.needs_redraw = true;
        if (!self.frame_pending) {
            self.frame_pending = true;
            const cb = wl.c.wl_surface_frame(self.surface.?) orelse return;
            _ = wl.c.wl_callback_add_listener(cb, &frame_listener, self);
            // We still need to commit to get the frame callback
            wl.c.wl_surface_commit(self.surface.?);
        }
    }

    fn drawSelectionBorder(self: *Overlay, data: []u8, stride: u32, sel: Rect) void {
        const border_width: u32 = 2;
        const bpp = ShmBuffer.bpp;

        const max_x = @min(sel.x + sel.width, self.surface_width);
        const max_y = @min(sel.y + sel.height, self.surface_height);

        // Top and bottom borders
        for (sel.x..max_x) |x| {
            for (0..border_width) |d| {
                if (sel.y + d < self.surface_height) {
                    const offset = (sel.y + @as(u32, @intCast(d))) * stride + @as(u32, @intCast(x)) * bpp;
                    if (offset + 3 < data.len) {
                        data[offset + 0] = 0xFF;
                        data[offset + 1] = 0xFF;
                        data[offset + 2] = 0xFF;
                        data[offset + 3] = 0xFF;
                    }
                }
                if (max_y > d) {
                    const by = max_y - 1 - @as(u32, @intCast(d));
                    const offset = by * stride + @as(u32, @intCast(x)) * bpp;
                    if (offset + 3 < data.len) {
                        data[offset + 0] = 0xFF;
                        data[offset + 1] = 0xFF;
                        data[offset + 2] = 0xFF;
                        data[offset + 3] = 0xFF;
                    }
                }
            }
        }

        // Left and right borders
        for (sel.y..max_y) |y| {
            for (0..border_width) |d| {
                if (sel.x + d < self.surface_width) {
                    const offset = @as(u32, @intCast(y)) * stride + (sel.x + @as(u32, @intCast(d))) * bpp;
                    if (offset + 3 < data.len) {
                        data[offset + 0] = 0xFF;
                        data[offset + 1] = 0xFF;
                        data[offset + 2] = 0xFF;
                        data[offset + 3] = 0xFF;
                    }
                }
                if (max_x > d) {
                    const rx = max_x - 1 - @as(u32, @intCast(d));
                    const offset = @as(u32, @intCast(y)) * stride + rx * bpp;
                    if (offset + 3 < data.len) {
                        data[offset + 0] = 0xFF;
                        data[offset + 1] = 0xFF;
                        data[offset + 2] = 0xFF;
                        data[offset + 3] = 0xFF;
                    }
                }
            }
        }
    }

    /// Run the event loop until the user finishes selection or cancels.
    pub fn run(self: *Overlay) !?Rect {
        while (!self.done and !self.cancelled) {
            if (wl.c.wl_display_dispatch(self.display) == -1)
                return error.WaylandDispatchFailed;
        }

        if (self.cancelled) return null;
        return self.selection;
    }

    /// Clean up all overlay resources.
    pub fn deinit(self: *Overlay) void {
        if (self.keyboard) |kbd| wl.c.wl_keyboard_destroy(kbd);
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

// ── Frame callback listener ─────────────────────────────────────────────────

fn frameCallback(data: ?*anyopaque, cb: ?*wl.c.wl_callback, _: u32) callconv(.c) void {
    const self: *Overlay = @ptrCast(@alignCast(data));
    wl.c.wl_callback_destroy(cb);
    self.frame_pending = false;

    if (self.needs_redraw) {
        self.needs_redraw = false;
        self.renderToBuffer();
        self.commitBuffer();

        // If still selecting, keep scheduling redraws
        if (self.selecting) {
            self.scheduleRedraw();
        }
    }
}

const frame_listener: wl.c.wl_callback_listener = .{
    .done = frameCallback,
};

// ── Layer surface listener ──────────────────────────────────────────────────

fn layerSurfaceConfigure(
    data: ?*anyopaque,
    surface: ?*wl.c.zwlr_layer_surface_v1,
    serial: u32,
    w: u32,
    h: u32,
) callconv(.c) void {
    const self: *Overlay = @ptrCast(@alignCast(data));
    self.surface_width = w;
    self.surface_height = h;
    self.configured = true;
    wl.c.zwlr_layer_surface_v1_ack_configure(surface, serial);
}

fn layerSurfaceClosed(data: ?*anyopaque, _: ?*wl.c.zwlr_layer_surface_v1) callconv(.c) void {
    const self: *Overlay = @ptrCast(@alignCast(data));
    self.cancelled = true;
    self.done = true;
}

const layer_surface_listener: wl.c.zwlr_layer_surface_v1_listener = .{
    .configure = layerSurfaceConfigure,
    .closed = layerSurfaceClosed,
};

// ── Pointer listener ────────────────────────────────────────────────────────

fn pointerEnter(data: ?*anyopaque, _: ?*wl.c.wl_pointer, serial: u32, _: ?*wl.c.wl_surface, sx: wl.c.wl_fixed_t, sy: wl.c.wl_fixed_t) callconv(.c) void {
    const self: *Overlay = @ptrCast(@alignCast(data));
    self.pointer_serial = serial;
    self.current_x = wl.c.wl_fixed_to_int(sx);
    self.current_y = wl.c.wl_fixed_to_int(sy);
    self.setCursor(serial);
}

fn pointerLeave(_: ?*anyopaque, _: ?*wl.c.wl_pointer, _: u32, _: ?*wl.c.wl_surface) callconv(.c) void {}

fn pointerMotion(data: ?*anyopaque, _: ?*wl.c.wl_pointer, _: u32, sx: wl.c.wl_fixed_t, sy: wl.c.wl_fixed_t) callconv(.c) void {
    const self: *Overlay = @ptrCast(@alignCast(data));
    self.current_x = wl.c.wl_fixed_to_int(sx);
    self.current_y = wl.c.wl_fixed_to_int(sy);

    if (self.selecting) {
        self.scheduleRedraw();
    }
}

fn pointerButton(data: ?*anyopaque, _: ?*wl.c.wl_pointer, serial: u32, _: u32, button: u32, state: u32) callconv(.c) void {
    const self: *Overlay = @ptrCast(@alignCast(data));
    _ = serial;
    const BTN_LEFT = 0x110; // linux/input-event-codes.h

    if (button == BTN_LEFT) {
        if (state == wl.c.WL_POINTER_BUTTON_STATE_PRESSED) {
            self.selecting = true;
            self.start_x = self.current_x;
            self.start_y = self.current_y;
            self.scheduleRedraw();
        } else if (state == wl.c.WL_POINTER_BUTTON_STATE_RELEASED) {
            if (self.selecting) {
                self.selecting = false;
                const sel = Rect.fromPoints(
                    self.start_x,
                    self.start_y,
                    self.current_x,
                    self.current_y,
                );
                if (!sel.isEmpty()) {
                    self.selection = sel;
                    self.done = true;
                } else {
                    // Selection was too small / a single click -- redraw to clear
                    self.renderToBuffer();
                    self.commitBuffer();
                }
            }
        }
    }
}

fn pointerAxis(_: ?*anyopaque, _: ?*wl.c.wl_pointer, _: u32, _: u32, _: wl.c.wl_fixed_t) callconv(.c) void {}
fn pointerFrame(_: ?*anyopaque, _: ?*wl.c.wl_pointer) callconv(.c) void {}
fn pointerAxisSource(_: ?*anyopaque, _: ?*wl.c.wl_pointer, _: u32) callconv(.c) void {}

const pointer_listener: wl.c.wl_pointer_listener = .{
    .enter = pointerEnter,
    .leave = pointerLeave,
    .motion = pointerMotion,
    .button = pointerButton,
    .axis = pointerAxis,
    .frame = pointerFrame,
    .axis_source = pointerAxisSource,
};

// ── Keyboard listener ───────────────────────────────────────────────────────

fn kbKeymap(_: ?*anyopaque, _: ?*wl.c.wl_keyboard, _: u32, fd: i32, _: u32) callconv(.c) void {
    posix.close(fd);
}

fn kbEnter(_: ?*anyopaque, _: ?*wl.c.wl_keyboard, _: u32, _: ?*wl.c.wl_surface, _: [*c]wl.c.wl_array) callconv(.c) void {}

fn kbLeave(_: ?*anyopaque, _: ?*wl.c.wl_keyboard, _: u32, _: ?*wl.c.wl_surface) callconv(.c) void {}

fn kbKey(data: ?*anyopaque, _: ?*wl.c.wl_keyboard, _: u32, _: u32, key: u32, state: u32) callconv(.c) void {
    const self: *Overlay = @ptrCast(@alignCast(data));
    if (state != wl.c.WL_KEYBOARD_KEY_STATE_PRESSED) return;

    const KEY_ESC = 1; // linux/input-event-codes.h

    if (key == KEY_ESC) {
        self.cancelled = true;
        self.done = true;
    }
}

fn kbModifiers(_: ?*anyopaque, _: ?*wl.c.wl_keyboard, _: u32, _: u32, _: u32, _: u32, _: u32) callconv(.c) void {}

fn kbRepeatInfo(_: ?*anyopaque, _: ?*wl.c.wl_keyboard, _: i32, _: i32) callconv(.c) void {}

const keyboard_listener: wl.c.wl_keyboard_listener = .{
    .keymap = kbKeymap,
    .enter = kbEnter,
    .leave = kbLeave,
    .key = kbKey,
    .modifiers = kbModifiers,
    .repeat_info = kbRepeatInfo,
};
