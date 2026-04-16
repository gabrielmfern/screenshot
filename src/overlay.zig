const std = @import("std");
const posix = std.posix;
const wl = @import("wayland.zig");
const ShmBuffer = @import("shm.zig").ShmBuffer;
const Image = @import("image.zig").Image;
const Rect = @import("image.zig").Rect;

/// State for the fullscreen selection overlay.
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

    // Surface dimensions (assigned by compositor via configure).
    // These are in logical (surface-local) pixels; pointer events and the
    // stored selection are also in this space.
    surface_width: u32 = 0,
    surface_height: u32 = 0,
    configured: bool = false,

    // Buffer is rendered at `scale` times the logical surface size so the
    // overlay stays crisp under compositor magnification (e.g. Hyprland zoom)
    // and fractional output scaling. `wl_surface_set_buffer_scale` is set to
    // match this value. `render_*` are `surface_* * scale` once configured.
    scale: i32 = 2,
    render_width: u32 = 0,
    render_height: u32 = 0,

    // SHM buffers (double-buffered)
    buffers: [2]?ShmBuffer = .{ null, null },
    current_buf: u1 = 0,

    // Pre-rendered darkened background (computed once, memcpy'd each frame)
    dark_bg: ?[]u8 = null,
    allocator: std.mem.Allocator = undefined,

    // Rendering state
    needs_redraw: bool = false,
    frame_pending: bool = false,

    // Selection state
    selecting: bool = false,
    moving: bool = false,
    resizing: bool = false,
    resize_edge: ResizeEdge = .top_left,
    resize_anchor_x: i32 = 0, // the fixed corner opposite to the dragged one
    resize_anchor_y: i32 = 0,
    start_x: i32 = 0,
    start_y: i32 = 0,
    current_x: i32 = 0,
    current_y: i32 = 0,
    move_offset_x: i32 = 0, // pointer offset from selection origin when drag started
    move_offset_y: i32 = 0,

    // Pointer enter serial
    pointer_serial: u32 = 0,

    // Keyboard modifier state
    ctrl_held: bool = false,

    // Toolbar state
    hovered_button: ?ToolbarButton = null,

    // Result
    selection: ?Rect = null,
    action: Action = .none,
    done: bool = false,

    pub const Action = enum {
        none,
        cancel,
        copy_to_clipboard,
        save_to_file,
        take_screenshot,
        record,
    };

    pub const ToolbarButton = enum {
        screenshot,
        record,
    };

    pub const ResizeEdge = enum {
        top_left,
        top_right,
        bottom_left,
        bottom_right,
        top,
        bottom,
        left,
        right,
    };

    // ── Toolbar layout constants ────────────────────────────────────
    const button_size: u32 = 48; // square icon buttons
    const button_spacing: u32 = 12; // gap between buttons
    const toolbar_gap: u32 = 12; // gap between selection and buttons
    const button_corner_radius: u32 = 12;

    fn buttonRect(self: *const Overlay, btn: ToolbarButton) ?Rect {
        const sel = self.selection orelse return null;
        const total_width: u32 = button_size * 2 + button_spacing;
        const center_x = sel.x + sel.width / 2;
        const base_x = if (center_x >= total_width / 2) center_x - total_width / 2 else 0;
        const clamped_x = @min(base_x, self.surface_width -| total_width);

        const bx = switch (btn) {
            .screenshot => clamped_x,
            .record => clamped_x + button_size + button_spacing,
        };

        // Place below selection, above if no room, or centered in selection as last resort
        const below_y = sel.y + sel.height + toolbar_gap;
        const by = if (below_y + button_size <= self.surface_height)
            below_y
        else if (sel.y >= button_size + toolbar_gap)
            sel.y - button_size - toolbar_gap
        else
            sel.y + sel.height / 2 -| button_size / 2;

        return Rect{
            .x = bx,
            .y = by,
            .width = button_size,
            .height = button_size,
        };
    }

    fn toolbarInsideSelection(self: *const Overlay) bool {
        const sel = self.selection orelse return false;
        const below_y = sel.y + sel.height + toolbar_gap;
        const fits_below = below_y + button_size <= self.surface_height;
        const fits_above = sel.y >= button_size + toolbar_gap;
        return !fits_below and !fits_above;
    }

    fn hitTestSelection(self: *const Overlay, px: i32, py: i32) bool {
        const sel = self.selection orelse return false;
        if (px < 0 or py < 0) return false;
        const ux: u32 = @intCast(px);
        const uy: u32 = @intCast(py);
        return ux >= sel.x and ux < sel.x + sel.width and
            uy >= sel.y and uy < sel.y + sel.height;
    }

    fn hitTestToolbar(self: *const Overlay, px: i32, py: i32) ?ToolbarButton {
        if (px < 0 or py < 0) return null;
        const ux: u32 = @intCast(px);
        const uy: u32 = @intCast(py);
        inline for (.{ ToolbarButton.screenshot, ToolbarButton.record }) |btn| {
            if (self.buttonRect(btn)) |br| {
                if (ux >= br.x and ux < br.x + br.width and
                    uy >= br.y and uy < br.y + br.height)
                {
                    return btn;
                }
            }
        }
        return null;
    }

    const corner_grab_radius: u32 = 16; // how close to a corner to trigger resize
    const edge_grab_thickness: u32 = 8; // how close to an edge to trigger resize

    fn hitTestResize(self: *const Overlay, px: i32, py: i32) ?ResizeEdge {
        const sel = self.selection orelse return null;
        if (px < 0 or py < 0) return null;

        const sx = @as(i32, @intCast(sel.x));
        const sy = @as(i32, @intCast(sel.y));
        const sx2 = sx + @as(i32, @intCast(sel.width));
        const sy2 = sy + @as(i32, @intCast(sel.height));
        const r = @as(i32, @intCast(corner_grab_radius));

        // Check corners first (higher priority) — closest within grab radius
        const corners = [_]struct { edge: ResizeEdge, cx: i32, cy: i32 }{
            .{ .edge = .top_left, .cx = sx, .cy = sy },
            .{ .edge = .top_right, .cx = sx2, .cy = sy },
            .{ .edge = .bottom_left, .cx = sx, .cy = sy2 },
            .{ .edge = .bottom_right, .cx = sx2, .cy = sy2 },
        };

        var best_edge: ?ResizeEdge = null;
        var best_dist: i32 = r * r + 1;

        for (corners) |corner| {
            const dx = px - corner.cx;
            const dy = py - corner.cy;
            const dist = dx * dx + dy * dy;
            if (dist < best_dist) {
                best_dist = dist;
                best_edge = corner.edge;
            }
        }

        if (best_edge != null) return best_edge;

        // Check edges — pointer must be within edge_grab_thickness of the edge
        // and within the selection span on the other axis (excluding corner zones)
        const t = @as(i32, @intCast(edge_grab_thickness));
        const on_top = (py >= sy - t and py <= sy + t);
        const on_bottom = (py >= sy2 - t and py <= sy2 + t);
        const on_left = (px >= sx - t and px <= sx + t);
        const on_right = (px >= sx2 - t and px <= sx2 + t);
        const in_x_span = (px > sx + r and px < sx2 - r);
        const in_y_span = (py > sy + r and py < sy2 - r);

        if (on_top and in_x_span) return .top;
        if (on_bottom and in_x_span) return .bottom;
        if (on_left and in_y_span) return .left;
        if (on_right and in_y_span) return .right;

        return null;
    }

    fn cursorForEdge(edge: ResizeEdge) [*:0]const u8 {
        return switch (edge) {
            .top_left => "top_left_corner",
            .top_right => "top_right_corner",
            .bottom_left => "bottom_left_corner",
            .bottom_right => "bottom_right_corner",
            .top => "top_side",
            .bottom => "bottom_side",
            .left => "left_side",
            .right => "right_side",
        };
    }

    pub fn init(self: *Overlay, allocator: std.mem.Allocator) !void {
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
            "screenshot-selection",
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
            wl.c.ZWLR_LAYER_SURFACE_V1_KEYBOARD_INTERACTIVITY_EXCLUSIVE,
        );

        _ = wl.c.zwlr_layer_surface_v1_add_listener(
            self.layer_surface.?,
            &layer_surface_listener,
            self,
        );

        wl.c.wl_surface_commit(self.surface.?);

        self.pointer = wl.c.wl_seat_get_pointer(self.seat);
        if (self.pointer) |ptr| {
            _ = wl.c.wl_pointer_add_listener(ptr, &pointer_listener, self);
        }
        self.keyboard = wl.c.wl_seat_get_keyboard(self.seat);
        if (self.keyboard) |kbd| {
            _ = wl.c.wl_keyboard_add_listener(kbd, &keyboard_listener, self);
        }

        while (!self.configured) {
            if (wl.c.wl_display_roundtrip(self.display) == -1)
                return error.WaylandRoundtripFailed;
        }

        self.render_width = self.surface_width * @as(u32, @intCast(self.scale));
        self.render_height = self.surface_height * @as(u32, @intCast(self.scale));
        wl.c.wl_surface_set_buffer_scale(self.surface.?, self.scale);

        try self.createBuffers();
        try self.preRenderDarkBackground();

        // Clamp any pre-populated selection (e.g. restored from previous session)
        // against the now-known surface size so later logic (hit testing, toolbar
        // placement) sees a well-formed rect.
        if (self.selection) |sel| {
            const clamped = sel.clampToBounds(self.surface_width, self.surface_height);
            self.selection = if (clamped.isEmpty()) null else clamped;
        }

        // Initial frame: either just the darkened background, or the background
        // plus any restored selection.
        self.renderToBuffer();
        self.commitBuffer();
    }

    fn createBuffers(self: *Overlay) !void {
        for (&self.buffers) |*buf| {
            if (buf.*) |*b| b.destroy();
            buf.* = try ShmBuffer.create(
                self.shm,
                self.render_width,
                self.render_height,
                wl.c.WL_SHM_FORMAT_ARGB8888,
            );
        }
    }

    /// Pre-render the darkened screenshot into a CPU-side buffer.
    /// This is done once and then memcpy'd into the back buffer each frame.
    fn preRenderDarkBackground(self: *Overlay) !void {
        const stride = self.render_width * ShmBuffer.bpp;
        const size: usize = @as(usize, self.render_height) * stride;
        self.dark_bg = try self.allocator.alloc(u8, size);
        const bg = self.dark_bg.?;
        const bpp = ShmBuffer.bpp;

        const same_dimensions =
            self.render_width == self.screenshot.width and
            self.render_height == self.screenshot.height;

        for (0..self.render_height) |yy| {
            const y: u32 = @intCast(yy);
            const src_y = if (same_dimensions) y else self.mapRenderToScreenshotY(y);

            for (0..self.render_width) |xx| {
                const x: u32 = @intCast(xx);
                const src_x = if (same_dimensions) x else self.mapRenderToScreenshotX(x);

                const dst_offset = @as(usize, y) * stride + @as(usize, x) * bpp;
                const src_offset = @as(usize, src_y) * self.screenshot.stride + @as(usize, src_x) * Image.bpp;

                if (src_offset + 3 < self.screenshot.data.len and dst_offset + 3 < bg.len) {
                    bg[dst_offset + 0] = self.screenshot.data[src_offset + 0] / 3;
                    bg[dst_offset + 1] = self.screenshot.data[src_offset + 1] / 3;
                    bg[dst_offset + 2] = self.screenshot.data[src_offset + 2] / 3;
                    bg[dst_offset + 3] = 0xFF;
                }
            }
        }
    }

    fn mapRenderToScreenshotX(self: *const Overlay, x: u32) u32 {
        return mapCoordFloor(x, self.render_width, self.screenshot.width);
    }

    fn mapRenderToScreenshotY(self: *const Overlay, y: u32) u32 {
        return mapCoordFloor(y, self.render_height, self.screenshot.height);
    }

    /// Multiply a logical-space scalar to render space.
    fn sc(self: *const Overlay, v: u32) u32 {
        return v * @as(u32, @intCast(self.scale));
    }

    /// Scale a surface-space rect to render space.
    fn toRenderRect(self: *const Overlay, r: Rect) Rect {
        return .{
            .x = self.sc(r.x),
            .y = self.sc(r.y),
            .width = self.sc(r.width),
            .height = self.sc(r.height),
        };
    }

    fn mapCoordFloor(coord: u32, src_extent: u32, dst_extent: u32) u32 {
        if (src_extent == 0 or dst_extent == 0) return 0;
        const mapped: u64 = (@as(u64, coord) * dst_extent) / src_extent;
        return @intCast(@min(mapped, @as(u64, dst_extent - 1)));
    }

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

    fn setCursorShape(self: *Overlay, name: [*:0]const u8) void {
        const theme = self.cursor_theme orelse return;
        const cursor_sfc = self.cursor_surface orelse return;
        const cur = wl.c.wl_cursor_theme_get_cursor(theme, name) orelse return;
        if (cur.*.image_count == 0) return;
        const image = cur.*.images[0].*;
        const buffer = wl.c.wl_cursor_image_get_buffer(cur.*.images[0]) orelse return;

        wl.c.wl_surface_attach(cursor_sfc, buffer, 0, 0);
        wl.c.wl_surface_damage_buffer(cursor_sfc, 0, 0, @intCast(image.width), @intCast(image.height));
        wl.c.wl_surface_commit(cursor_sfc);

        wl.c.wl_pointer_set_cursor(
            self.pointer.?,
            self.pointer_serial,
            cursor_sfc,
            @intCast(image.hotspot_x),
            @intCast(image.hotspot_y),
        );
    }

    /// Render into the current back buffer.
    /// Strategy: memcpy the pre-rendered dark background, then restore only
    /// the pixels inside the selection to full brightness. O(selection_area)
    /// instead of O(screen_area).
    fn renderToBuffer(self: *Overlay) void {
        const buf = &(self.buffers[self.current_buf] orelse return);
        const data = buf.data;
        const stride = buf.stride;
        const bg = self.dark_bg orelse return;

        // Fast bulk copy of the pre-rendered dark background
        @memcpy(data[0..bg.len], bg);

        // Determine which rect to render:
        // 1. If actively dragging, compute live from mouse coordinates
        // 2. If a selection is locked in (mouse released), use that
        // 3. Otherwise, nothing to highlight
        const sel = if (self.selecting)
            Rect.fromPoints(self.start_x, self.start_y, self.current_x, self.current_y)
        else if (self.selection) |s|
            s
        else
            return;

        if (sel.isEmpty()) return;

        // Clamp selection to surface (logical) bounds, then scale to render space
        const clamped = sel.clampToBounds(self.surface_width, self.surface_height);
        if (clamped.isEmpty()) return;
        const render_clamped = self.toRenderRect(clamped);

        const bpp = ShmBuffer.bpp;

        const same_dimensions =
            self.render_width == self.screenshot.width and
            self.render_height == self.screenshot.height;

        // Restore original brightness only inside the selection rectangle
        for (render_clamped.y..render_clamped.y + render_clamped.height) |yy| {
            const y: u32 = @intCast(yy);

            if (same_dimensions) {
                const dst_row_start = @as(usize, y) * stride + @as(usize, render_clamped.x) * bpp;
                const src_row_start = @as(usize, y) * self.screenshot.stride + @as(usize, render_clamped.x) * Image.bpp;
                const row_bytes = @as(usize, render_clamped.width) * bpp;

                if (src_row_start + row_bytes <= self.screenshot.data.len and
                    dst_row_start + row_bytes <= data.len)
                {
                    @memcpy(
                        data[dst_row_start..][0..row_bytes],
                        self.screenshot.data[src_row_start..][0..row_bytes],
                    );
                    // Fix alpha channel (screenshot might be XRGB with alpha=0)
                    var x: usize = dst_row_start;
                    const end = dst_row_start + row_bytes;
                    while (x + 3 < end) : (x += bpp) {
                        data[x + 3] = 0xFF;
                    }
                }
            } else {
                const src_y = self.mapRenderToScreenshotY(y);
                for (render_clamped.x..render_clamped.x + render_clamped.width) |xx| {
                    const x: u32 = @intCast(xx);
                    const src_x = self.mapRenderToScreenshotX(x);

                    const dst_offset = @as(usize, y) * stride + @as(usize, x) * bpp;
                    const src_offset = @as(usize, src_y) * self.screenshot.stride + @as(usize, src_x) * Image.bpp;

                    if (src_offset + 3 < self.screenshot.data.len and dst_offset + 3 < data.len) {
                        data[dst_offset + 0] = self.screenshot.data[src_offset + 0];
                        data[dst_offset + 1] = self.screenshot.data[src_offset + 1];
                        data[dst_offset + 2] = self.screenshot.data[src_offset + 2];
                        data[dst_offset + 3] = 0xFF;
                    }
                }
            }
        }

        // Draw selection border with handles (coords in surface space;
        // drawing functions scale to render internally).
        self.drawSelectionBorder(data, stride, clamped);
        self.drawHandles(data, stride, clamped);

        // Draw toolbar below selection (only when selection is locked in, not while dragging/resizing)
        if (!self.selecting and !self.resizing and self.selection != null) {
            self.drawToolbar(data, stride);
        }
    }

    fn commitBuffer(self: *Overlay) void {
        const buf = &(self.buffers[self.current_buf] orelse return);
        wl.c.wl_surface_attach(self.surface.?, buf.wl_buffer, 0, 0);
        wl.c.wl_surface_damage_buffer(
            self.surface.?,
            0,
            0,
            @intCast(self.render_width),
            @intCast(self.render_height),
        );
        wl.c.wl_surface_commit(self.surface.?);
        self.current_buf +%= 1;
    }

    fn scheduleRedraw(self: *Overlay) void {
        self.needs_redraw = true;
        if (!self.frame_pending) {
            self.frame_pending = true;
            const cb = wl.c.wl_surface_frame(self.surface.?) orelse return;
            _ = wl.c.wl_callback_add_listener(cb, &frame_listener, self);
            wl.c.wl_surface_commit(self.surface.?);
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

    fn drawSelectionBorder(self: *Overlay, data: []u8, stride: u32, sel: Rect) void {
        const rsel = self.toRenderRect(sel);
        const border: u32 = self.sc(1);
        const sw = self.render_width;
        const sh = self.render_height;

        const max_x = @min(rsel.x + rsel.width, sw);
        const max_y = @min(rsel.y + rsel.height, sh);

        // Top edge
        fillRect(data, stride, rsel.x, rsel.y, rsel.width, border, sw, sh, 0xFF, 0xFF, 0xFF);
        // Bottom edge
        if (max_y > 0) {
            fillRect(data, stride, rsel.x, max_y -| border, rsel.width, border, sw, sh, 0xFF, 0xFF, 0xFF);
        }
        // Left edge
        fillRect(data, stride, rsel.x, rsel.y, border, rsel.height, sw, sh, 0xFF, 0xFF, 0xFF);
        // Right edge
        if (max_x > 0) {
            fillRect(data, stride, max_x -| border, rsel.y, border, rsel.height, sw, sh, 0xFF, 0xFF, 0xFF);
        }
    }

    fn drawHandles(self: *Overlay, data: []u8, stride: u32, sel: Rect) void {
        const rsel = self.toRenderRect(sel);
        const sw = self.render_width;
        const sh = self.render_height;

        // Handle dimensions (in render pixels)
        const handle_len: u32 = self.sc(16);
        const handle_thick: u32 = self.sc(3);
        const edge_handle_len: u32 = self.sc(12);
        const edge_handle_thick: u32 = self.sc(3);

        const max_x = @min(rsel.x + rsel.width, sw);
        const max_y = @min(rsel.y + rsel.height, sh);

        if (rsel.width < self.sc(4) or rsel.height < self.sc(4)) return;

        // ── Corner handles (L-shaped) ───────────────────────────────
        const hl = @min(handle_len, rsel.width / 2);
        const vl = @min(handle_len, rsel.height / 2);

        // Top-left corner
        fillRect(data, stride, rsel.x, rsel.y, hl, handle_thick, sw, sh, 0xFF, 0xFF, 0xFF);
        fillRect(data, stride, rsel.x, rsel.y, handle_thick, vl, sw, sh, 0xFF, 0xFF, 0xFF);

        // Top-right corner
        fillRect(data, stride, max_x -| hl, rsel.y, hl, handle_thick, sw, sh, 0xFF, 0xFF, 0xFF);
        fillRect(data, stride, max_x -| handle_thick, rsel.y, handle_thick, vl, sw, sh, 0xFF, 0xFF, 0xFF);

        // Bottom-left corner
        fillRect(data, stride, rsel.x, max_y -| handle_thick, hl, handle_thick, sw, sh, 0xFF, 0xFF, 0xFF);
        fillRect(data, stride, rsel.x, max_y -| vl, handle_thick, vl, sw, sh, 0xFF, 0xFF, 0xFF);

        // Bottom-right corner
        fillRect(data, stride, max_x -| hl, max_y -| handle_thick, hl, handle_thick, sw, sh, 0xFF, 0xFF, 0xFF);
        fillRect(data, stride, max_x -| handle_thick, max_y -| vl, handle_thick, vl, sw, sh, 0xFF, 0xFF, 0xFF);

        // ── Edge midpoint handles (short bars) ──────────────────────
        const mid_x = rsel.x + rsel.width / 2;
        const mid_y = rsel.y + rsel.height / 2;
        const ehl = @min(edge_handle_len, rsel.width / 2);
        const evl = @min(edge_handle_len, rsel.height / 2);

        // Top edge center
        fillRect(data, stride, mid_x -| (ehl / 2), rsel.y, ehl, edge_handle_thick, sw, sh, 0xFF, 0xFF, 0xFF);

        // Bottom edge center
        fillRect(data, stride, mid_x -| (ehl / 2), max_y -| edge_handle_thick, ehl, edge_handle_thick, sw, sh, 0xFF, 0xFF, 0xFF);

        // Left edge center
        fillRect(data, stride, rsel.x, mid_y -| (evl / 2), edge_handle_thick, evl, sw, sh, 0xFF, 0xFF, 0xFF);

        // Right edge center
        fillRect(data, stride, max_x -| edge_handle_thick, mid_y -| (evl / 2), edge_handle_thick, evl, sw, sh, 0xFF, 0xFF, 0xFF);
    }

    // ── Toolbar rendering ──────────────────────────────────────────────

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

                if (in_rect) {
                    blendPixel(data, stride, @intCast(x), @intCast(y), r, g, b, a);
                }
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
        const inner_rad = irad - ithick;
        const inner_rad_sq = inner_rad * inner_rad;

        for (ry..y_end) |y| {
            for (rx..x_end) |x| {
                const lx = @as(i32, @intCast(x)) - @as(i32, @intCast(rx));
                const ly = @as(i32, @intCast(y)) - @as(i32, @intCast(ry));
                const iw = @as(i32, @intCast(rw));
                const ih = @as(i32, @intCast(rh));

                // Check if pixel is inside the rounded rect at all
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

                // Check if pixel is inside the inner (shrunk) rect — if so, skip (not on border)
                const in_inner = lx >= ithick and lx < iw - ithick and ly >= ithick and ly < ih - ithick;
                if (in_inner) {
                    // Still need to check corners of the inner rounded rect
                    const ilx = lx - ithick;
                    const ily = ly - ithick;
                    const iiw = iw - ithick * 2;
                    const iih = ih - ithick * 2;
                    var in_inner_round = true;
                    if (inner_rad > 0) {
                        if (ilx < inner_rad and ily < inner_rad) {
                            const dx = inner_rad - ilx - 1;
                            const dy = inner_rad - ily - 1;
                            if (dx * dx + dy * dy > inner_rad_sq) in_inner_round = false;
                        } else if (ilx >= iiw - inner_rad and ily < inner_rad) {
                            const dx = ilx - (iiw - inner_rad);
                            const dy = inner_rad - ily - 1;
                            if (dx * dx + dy * dy > inner_rad_sq) in_inner_round = false;
                        } else if (ilx < inner_rad and ily >= iih - inner_rad) {
                            const dx = inner_rad - ilx - 1;
                            const dy = ily - (iih - inner_rad);
                            if (dx * dx + dy * dy > inner_rad_sq) in_inner_round = false;
                        } else if (ilx >= iiw - inner_rad and ily >= iih - inner_rad) {
                            const dx = ilx - (iiw - inner_rad);
                            const dy = ily - (iih - inner_rad);
                            if (dx * dx + dy * dy > inner_rad_sq) in_inner_round = false;
                        }
                    }
                    if (in_inner_round) continue;
                }

                blendPixel(data, stride, @intCast(x), @intCast(y), r, g, b, a);
            }
        }
    }

    fn drawCircle(data: []u8, stride: u32, cx: i32, cy: i32, radius: i32, sw: u32, sh: u32, r: u8, g: u8, b: u8, thickness: i32) void {
        const outer_r_sq = radius * radius;
        const inner_r = radius - thickness;
        const inner_r_sq = inner_r * inner_r;

        var dy: i32 = -radius;
        while (dy <= radius) : (dy += 1) {
            var dx: i32 = -radius;
            while (dx <= radius) : (dx += 1) {
                const dist_sq = dx * dx + dy * dy;
                if (dist_sq <= outer_r_sq and dist_sq >= inner_r_sq) {
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

    /// Camera icon: body outline + viewfinder bump + lens circle + inner dot.
    /// Camera icon. cx/cy are in render pixels.
    fn drawCameraIcon(self: *const Overlay, data: []u8, stride: u32, cx: u32, cy: u32) void {
        const sw = self.render_width;
        const sh = self.render_height;
        const icx: i32 = @intCast(cx);
        const icy: i32 = @intCast(cy);

        // Camera body outline (22x16 logical)
        const body_w: u32 = self.sc(22);
        const body_h: u32 = self.sc(16);
        const bx = cx -| (body_w / 2);
        const by = cy -| (body_h / 2) + self.sc(2);
        const thick: u32 = self.sc(2);

        fillRect(data, stride, bx, by, body_w, thick, sw, sh, 0xFF, 0xFF, 0xFF); // top
        fillRect(data, stride, bx, by + body_h -| thick, body_w, thick, sw, sh, 0xFF, 0xFF, 0xFF); // bottom
        fillRect(data, stride, bx, by, thick, body_h, sw, sh, 0xFF, 0xFF, 0xFF); // left
        fillRect(data, stride, bx + body_w -| thick, by, thick, body_h, sw, sh, 0xFF, 0xFF, 0xFF); // right

        // Viewfinder bump on top
        const bump_w: u32 = self.sc(8);
        const bump_h: u32 = self.sc(4);
        fillRect(data, stride, cx -| (bump_w / 2), by -| bump_h + self.sc(1), bump_w, bump_h, sw, sh, 0xFF, 0xFF, 0xFF);

        // Lens circle (ring)
        drawCircle(data, stride, icx, icy + @as(i32, @intCast(self.sc(2))), @as(i32, @intCast(self.sc(5))), sw, sh, 0xFF, 0xFF, 0xFF, @intCast(self.sc(2)));

        // Inner lens dot
        drawFilledCircle(data, stride, icx, icy + @as(i32, @intCast(self.sc(2))), @as(i32, @intCast(self.sc(1))), sw, sh, 0xFF, 0xFF, 0xFF);
    }

    /// Record icon: filled red circle. cx/cy are in render pixels.
    fn drawRecordIcon(self: *const Overlay, data: []u8, stride: u32, cx: u32, cy: u32) void {
        const sw = self.render_width;
        const sh = self.render_height;
        drawFilledCircle(data, stride, @intCast(cx), @intCast(cy), @as(i32, @intCast(self.sc(10))), sw, sh, 0xF0, 0x40, 0x40);
    }

    fn drawToolbar(self: *Overlay, data: []u8, stride: u32) void {
        if (self.buttonRect(.screenshot) == null) return;
        const sw = self.render_width;
        const sh = self.render_height;
        const radius = self.sc(button_corner_radius);
        const stroke_thick = self.sc(2);

        inline for (.{ ToolbarButton.screenshot, ToolbarButton.record }) |btn| {
            if (self.buttonRect(btn)) |br| {
                const rbr = self.toRenderRect(br);
                const is_hovered = self.hovered_button != null and self.hovered_button.? == btn;

                // Button background
                if (is_hovered) {
                    fillRoundedRectAlpha(data, stride, rbr.x, rbr.y, rbr.width, rbr.height, sw, sh, radius, 0x50, 0x50, 0x50, 0xE0);
                } else {
                    fillRoundedRectAlpha(data, stride, rbr.x, rbr.y, rbr.width, rbr.height, sw, sh, radius, 0x1E, 0x1E, 0x1E, 0xD8);
                }

                // Border for visibility when buttons are inside the selection
                if (self.toolbarInsideSelection()) {
                    strokeRoundedRect(data, stride, rbr.x, rbr.y, rbr.width, rbr.height, sw, sh, radius, stroke_thick, 0xFF, 0xFF, 0xFF, 0x40);
                }

                // Icon centered in button
                const icon_cx = rbr.x + rbr.width / 2;
                const icon_cy = rbr.y + rbr.height / 2;
                switch (btn) {
                    .screenshot => self.drawCameraIcon(data, stride, icon_cx, icon_cy),
                    .record => self.drawRecordIcon(data, stride, icon_cx, icon_cy),
                }
            }
        }
    }

    pub const Result = struct {
        selection: ?Rect,
        action: Action,
        serial: u32,
        surface_width: u32,
        surface_height: u32,
    };

    pub fn run(self: *Overlay) !Result {
        while (!self.done) {
            if (wl.c.wl_display_dispatch(self.display) == -1)
                return error.WaylandDispatchFailed;
        }

        return .{
            .selection = self.selection,
            .action = self.action,
            .serial = self.pointer_serial,
            .surface_width = self.surface_width,
            .surface_height = self.surface_height,
        };
    }

    pub fn deinit(self: *Overlay) void {
        if (self.keyboard) |kbd| wl.c.wl_keyboard_destroy(kbd);
        if (self.pointer) |ptr| wl.c.wl_pointer_destroy(ptr);
        if (self.cursor_surface) |s| wl.c.wl_surface_destroy(s);
        if (self.cursor_theme) |t| wl.c.wl_cursor_theme_destroy(t);
        for (&self.buffers) |*buf| {
            if (buf.*) |*b| b.destroy();
        }
        if (self.dark_bg) |bg| self.allocator.free(bg);
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

        if (self.selecting or self.moving or self.resizing) {
            self.scheduleRedraw();
        }
    }
}

const frame_listener: wl.c.wl_callback_listener = .{
    .done = frameCallback,
};

// ── Layer surface listener ──────────────────────────────────────────────────

fn layerSurfaceConfigure(data: ?*anyopaque, surface: ?*wl.c.zwlr_layer_surface_v1, serial: u32, w: u32, h: u32) callconv(.c) void {
    const self: *Overlay = @ptrCast(@alignCast(data));
    self.surface_width = w;
    self.surface_height = h;
    self.configured = true;
    wl.c.zwlr_layer_surface_v1_ack_configure(surface, serial);
}

fn layerSurfaceClosed(data: ?*anyopaque, _: ?*wl.c.zwlr_layer_surface_v1) callconv(.c) void {
    const self: *Overlay = @ptrCast(@alignCast(data));
    self.action = .cancel;
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
    } else if (self.moving) {
        // Move the selection to follow the pointer
        if (self.selection) |sel| {
            const new_x = self.current_x - self.move_offset_x;
            const new_y = self.current_y - self.move_offset_y;
            // Clamp to surface bounds
            const clamped_x: u32 = @intCast(@max(0, @min(new_x, @as(i32, @intCast(self.surface_width -| sel.width)))));
            const clamped_y: u32 = @intCast(@max(0, @min(new_y, @as(i32, @intCast(self.surface_height -| sel.height)))));
            self.selection = .{
                .x = clamped_x,
                .y = clamped_y,
                .width = sel.width,
                .height = sel.height,
            };
            self.scheduleRedraw();
        }
    } else if (self.resizing) {
        // Resize the selection: anchor stays fixed, dragged side/corner follows pointer
        // For edge drags, constrain the axis parallel to the edge
        const sel = self.selection orelse return;
        const drag_x = switch (self.resize_edge) {
            .top, .bottom => self.resize_anchor_x + @as(i32, @intCast(sel.width)),
            else => self.current_x,
        };
        const drag_y = switch (self.resize_edge) {
            .left, .right => self.resize_anchor_y + @as(i32, @intCast(sel.height)),
            else => self.current_y,
        };
        const new_sel = Rect.fromPoints(
            self.resize_anchor_x,
            self.resize_anchor_y,
            drag_x,
            drag_y,
        );
        if (!new_sel.isEmpty()) {
            self.selection = new_sel;
            self.scheduleRedraw();
        }
    } else if (self.selection != null) {
        // Update toolbar hover state and cursor shape
        const prev_hovered = self.hovered_button;
        self.hovered_button = self.hitTestToolbar(self.current_x, self.current_y);
        const on_corner = self.hitTestResize(self.current_x, self.current_y);
        const in_selection = self.hitTestSelection(self.current_x, self.current_y);

        // Update cursor based on hover
        if (self.hovered_button != null) {
            if (prev_hovered == null) self.setCursorShape("hand2");
        } else if (on_corner) |edge| {
            self.setCursorShape(Overlay.cursorForEdge(edge));
        } else if (in_selection) {
            self.setCursorShape("grab");
        } else {
            self.setCursor(self.pointer_serial);
        }

        if ((self.hovered_button == null) != (prev_hovered == null) or
            (self.hovered_button != null and prev_hovered != null and
                @intFromEnum(self.hovered_button.?) != @intFromEnum(prev_hovered.?)))
        {
            self.scheduleRedraw();
        }
    }
}

fn pointerButton(data: ?*anyopaque, _: ?*wl.c.wl_pointer, _: u32, _: u32, button: u32, state: u32) callconv(.c) void {
    const self: *Overlay = @ptrCast(@alignCast(data));
    const BTN_LEFT = 0x110;

    if (button == BTN_LEFT) {
        if (state == wl.c.WL_POINTER_BUTTON_STATE_PRESSED) {
            // Check if clicking a toolbar button
            if (self.selection != null) {
                if (self.hitTestToolbar(self.current_x, self.current_y)) |btn| {
                    switch (btn) {
                        .screenshot => {
                            self.action = .take_screenshot;
                            self.done = true;
                        },
                        .record => {
                            self.action = .record;
                            self.done = true;
                        },
                    }
                    return;
                }
            }

            // Check if clicking near a corner or edge — start resizing
            if (self.hitTestResize(self.current_x, self.current_y)) |edge| {
                const sel = self.selection.?;
                self.resizing = true;
                self.resize_edge = edge;
                // Anchor is the opposite side/corner from the one being dragged
                switch (edge) {
                    .top_left => {
                        self.resize_anchor_x = @intCast(sel.x + sel.width);
                        self.resize_anchor_y = @intCast(sel.y + sel.height);
                    },
                    .top_right => {
                        self.resize_anchor_x = @intCast(sel.x);
                        self.resize_anchor_y = @intCast(sel.y + sel.height);
                    },
                    .bottom_left => {
                        self.resize_anchor_x = @intCast(sel.x + sel.width);
                        self.resize_anchor_y = @intCast(sel.y);
                    },
                    .bottom_right => {
                        self.resize_anchor_x = @intCast(sel.x);
                        self.resize_anchor_y = @intCast(sel.y);
                    },
                    .top => {
                        self.resize_anchor_x = @intCast(sel.x);
                        self.resize_anchor_y = @intCast(sel.y + sel.height);
                    },
                    .bottom => {
                        self.resize_anchor_x = @intCast(sel.x);
                        self.resize_anchor_y = @intCast(sel.y);
                    },
                    .left => {
                        self.resize_anchor_x = @intCast(sel.x + sel.width);
                        self.resize_anchor_y = @intCast(sel.y);
                    },
                    .right => {
                        self.resize_anchor_x = @intCast(sel.x);
                        self.resize_anchor_y = @intCast(sel.y);
                    },
                }
                self.hovered_button = null;
                self.setCursorShape(Overlay.cursorForEdge(edge));
                return;
            }

            // Check if clicking inside existing selection — start moving it
            if (self.hitTestSelection(self.current_x, self.current_y)) {
                const sel = self.selection.?;
                self.moving = true;
                self.move_offset_x = self.current_x - @as(i32, @intCast(sel.x));
                self.move_offset_y = self.current_y - @as(i32, @intCast(sel.y));
                self.hovered_button = null;
                self.setCursorShape("grabbing");
                return;
            }

            // Start a new selection
            self.selecting = true;
            self.selection = null;
            self.hovered_button = null;
            self.start_x = self.current_x;
            self.start_y = self.current_y;
            self.setCursor(self.pointer_serial); // restore crosshair
            self.scheduleRedraw();
        } else if (state == wl.c.WL_POINTER_BUTTON_STATE_RELEASED) {
            if (self.resizing) {
                self.resizing = false;
                // Selection already updated during motion
                if (self.hitTestResize(self.current_x, self.current_y)) |edge| {
                    self.setCursorShape(Overlay.cursorForEdge(edge));
                } else if (self.hitTestSelection(self.current_x, self.current_y)) {
                    self.setCursorShape("grab");
                } else {
                    self.setCursor(self.pointer_serial);
                }
                self.hovered_button = self.hitTestToolbar(self.current_x, self.current_y);
                self.renderToBuffer();
                self.commitBuffer();
            } else if (self.moving) {
                self.moving = false;
                // Selection already updated during motion
                if (self.hitTestResize(self.current_x, self.current_y)) |edge| {
                    self.setCursorShape(Overlay.cursorForEdge(edge));
                } else if (self.hitTestSelection(self.current_x, self.current_y)) {
                    self.setCursorShape("grab");
                } else {
                    self.setCursor(self.pointer_serial);
                }
                self.hovered_button = self.hitTestToolbar(self.current_x, self.current_y);
                self.renderToBuffer();
                self.commitBuffer();
            } else if (self.selecting) {
                self.selecting = false;
                const sel = Rect.fromPoints(
                    self.start_x,
                    self.start_y,
                    self.current_x,
                    self.current_y,
                );
                if (!sel.isEmpty()) {
                    // Lock in the selection, but don't finish --
                    // wait for toolbar button click or Ctrl+C / Ctrl+S / Escape
                    self.selection = sel;
                    // Check if pointer is now over toolbar
                    self.hovered_button = self.hitTestToolbar(self.current_x, self.current_y);
                }
                // Redraw to show final selection state with toolbar
                self.renderToBuffer();
                self.commitBuffer();
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

    // linux/input-event-codes.h
    const KEY_ESC = 1;
    const KEY_C = 46;
    const KEY_S = 31;

    if (key == KEY_ESC) {
        self.action = .cancel;
        self.done = true;
    } else if (self.ctrl_held and key == KEY_C) {
        if (self.selection != null) {
            self.action = .copy_to_clipboard;
            self.done = true;
        }
    } else if (self.ctrl_held and key == KEY_S) {
        if (self.selection != null) {
            self.action = .save_to_file;
            self.done = true;
        }
    }
}

fn kbModifiers(data: ?*anyopaque, _: ?*wl.c.wl_keyboard, _: u32, mods_depressed: u32, _: u32, _: u32, _: u32) callconv(.c) void {
    const self: *Overlay = @ptrCast(@alignCast(data));
    // Bit 2 (0x4) in mods_depressed is typically Ctrl
    self.ctrl_held = (mods_depressed & 0x4) != 0;
}
fn kbRepeatInfo(_: ?*anyopaque, _: ?*wl.c.wl_keyboard, _: i32, _: i32) callconv(.c) void {}

const keyboard_listener: wl.c.wl_keyboard_listener = .{
    .keymap = kbKeymap,
    .enter = kbEnter,
    .leave = kbLeave,
    .key = kbKey,
    .modifiers = kbModifiers,
    .repeat_info = kbRepeatInfo,
};
