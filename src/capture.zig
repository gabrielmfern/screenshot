const std = @import("std");
const wl = @import("wayland.zig");
const ShmBuffer = @import("shm.zig").ShmBuffer;
const Image = @import("image.zig").Image;

/// Which capture protocol backend to use.
pub const CaptureBackend = enum {
    wlr_screencopy,
    ext_image_copy_capture,
};

/// Unified capture state that works with either wlr-screencopy or ext-image-copy-capture.
pub const CaptureState = struct {
    backend: CaptureBackend = .wlr_screencopy,

    // Buffer constraints received from compositor
    buffer_width: u32 = 0,
    buffer_height: u32 = 0,
    buffer_stride: u32 = 0,
    shm_format: u32 = 0,

    // Frame state
    frame_ready: bool = false,
    frame_failed: bool = false,
    buffer_info_done: bool = false,

    // The SHM buffer used for capture
    buffer: ?ShmBuffer = null,

    // Protocol objects (depending on backend)
    screencopy_frame: ?*wl.c.zwlr_screencopy_frame_v1 = null,
    ext_session: ?*wl.c.ext_image_copy_capture_session_v1 = null,
    ext_frame: ?*wl.c.ext_image_copy_capture_frame_v1 = null,

    // Reference to the Wayland display for dispatching
    display: *wl.c.wl_display = undefined,

    /// Capture a screenshot using wlr-screencopy.
    pub fn initScreencopy(
        self: *CaptureState,
        display: *wl.c.wl_display,
        screencopy_manager: *wl.c.zwlr_screencopy_manager_v1,
        output: *wl.c.wl_output,
        shm: *wl.c.wl_shm,
    ) !void {
        self.backend = .wlr_screencopy;
        self.display = display;
        self.buffer_width = 0;
        self.buffer_height = 0;
        self.buffer_stride = 0;
        self.shm_format = 0;
        self.buffer_info_done = false;
        self.frame_ready = false;
        self.frame_failed = false;

        // capture_output: overlay_cursor=0 to exclude cursor from screenshot
        self.screencopy_frame = wl.c.zwlr_screencopy_manager_v1_capture_output(
            screencopy_manager,
            0, // overlay_cursor: 0 = no cursor, 1 = include cursor
            output,
        ) orelse return error.FailedToCreateFrame;
        defer {
            if (self.screencopy_frame) |f| {
                wl.c.zwlr_screencopy_frame_v1_destroy(f);
                self.screencopy_frame = null;
            }
        }

        _ = wl.c.zwlr_screencopy_frame_v1_add_listener(
            self.screencopy_frame.?,
            &screencopy_frame_listener,
            self,
        );

        // Wait for buffer info (the "buffer" event followed by "buffer_done" in v3,
        // or just the "buffer" event in v1/v2)
        while (!self.buffer_info_done and !self.frame_failed) {
            if (wl.c.wl_display_roundtrip(display) == -1)
                return error.WaylandRoundtripFailed;
        }
        if (self.frame_failed) return error.CaptureFailed;

        if (self.buffer_width == 0 or self.buffer_height == 0)
            return error.InvalidBufferConstraints;

        // Create SHM buffer matching the compositor's requirements
        self.buffer = try ShmBuffer.create(shm, self.buffer_width, self.buffer_height, self.shm_format);

        // Copy the frame into our buffer
        wl.c.zwlr_screencopy_frame_v1_copy(self.screencopy_frame.?, self.buffer.?.wl_buffer);

        // Wait for ready or failed
        while (!self.frame_ready and !self.frame_failed) {
            if (wl.c.wl_display_roundtrip(display) == -1)
                return error.WaylandRoundtripFailed;
        }

        if (self.frame_failed) return error.CaptureFailed;
    }

    /// Capture a screenshot using ext-image-copy-capture.
    pub fn initExtCapture(
        self: *CaptureState,
        display: *wl.c.wl_display,
        capture_manager: *wl.c.ext_image_copy_capture_manager_v1,
        source_manager: *wl.c.ext_output_image_capture_source_manager_v1,
        output: *wl.c.wl_output,
        shm: *wl.c.wl_shm,
    ) !void {
        self.backend = .ext_image_copy_capture;
        self.display = display;
        self.buffer_width = 0;
        self.buffer_height = 0;
        self.buffer_stride = 0;
        self.shm_format = 0;
        self.buffer_info_done = false;
        self.frame_ready = false;
        self.frame_failed = false;

        const source = wl.c.ext_output_image_capture_source_manager_v1_create_source(
            source_manager,
            output,
        ) orelse return error.FailedToCreateCaptureSource;

        self.ext_session = wl.c.ext_image_copy_capture_manager_v1_create_session(
            capture_manager,
            @ptrCast(source),
            0, // no options: don't paint cursors
        ) orelse return error.FailedToCreateCaptureSession;
        defer {
            if (self.ext_frame) |f| {
                wl.c.ext_image_copy_capture_frame_v1_destroy(f);
                self.ext_frame = null;
            }
            if (self.ext_session) |s| {
                wl.c.ext_image_copy_capture_session_v1_destroy(s);
                self.ext_session = null;
            }
        }

        _ = wl.c.ext_image_copy_capture_session_v1_add_listener(
            self.ext_session.?,
            &ext_session_listener,
            self,
        );

        wl.c.ext_image_capture_source_v1_destroy(source);

        // Wait for buffer constraints
        while (!self.buffer_info_done and !self.frame_failed) {
            if (wl.c.wl_display_roundtrip(display) == -1)
                return error.WaylandRoundtripFailed;
        }
        if (self.frame_failed) return error.CaptureFailed;

        if (self.buffer_width == 0 or self.buffer_height == 0)
            return error.InvalidBufferConstraints;

        self.buffer = try ShmBuffer.create(shm, self.buffer_width, self.buffer_height, self.shm_format);

        self.ext_frame = wl.c.ext_image_copy_capture_session_v1_create_frame(
            self.ext_session.?,
        ) orelse return error.FailedToCreateFrame;

        _ = wl.c.ext_image_copy_capture_frame_v1_add_listener(
            self.ext_frame.?,
            &ext_frame_listener,
            self,
        );

        wl.c.ext_image_copy_capture_frame_v1_attach_buffer(self.ext_frame.?, self.buffer.?.wl_buffer);
        wl.c.ext_image_copy_capture_frame_v1_damage_buffer(
            self.ext_frame.?,
            0,
            0,
            @intCast(self.buffer_width),
            @intCast(self.buffer_height),
        );
        wl.c.ext_image_copy_capture_frame_v1_capture(self.ext_frame.?);

        while (!self.frame_ready and !self.frame_failed) {
            if (wl.c.wl_display_roundtrip(display) == -1)
                return error.WaylandRoundtripFailed;
        }

        if (self.frame_failed) return error.CaptureFailed;
    }

    /// Get the captured image.
    pub fn getImage(self: *CaptureState) Image {
        const buf = &self.buffer.?;
        return Image.wrapExternalBuffer(buf.data.ptr, buf.width, buf.height, buf.stride);
    }

    /// Clean up all capture resources.
    pub fn deinit(self: *CaptureState) void {
        switch (self.backend) {
            .wlr_screencopy => {
                if (self.screencopy_frame) |f| wl.c.zwlr_screencopy_frame_v1_destroy(f);
            },
            .ext_image_copy_capture => {
                if (self.ext_frame) |f| wl.c.ext_image_copy_capture_frame_v1_destroy(f);
                if (self.ext_session) |s| wl.c.ext_image_copy_capture_session_v1_destroy(s);
            },
        }
        if (self.buffer) |*b| b.destroy();
    }
};

// ── wlr-screencopy frame listener ──────────────────────────────────────────

fn screencopyBuffer(
    data: ?*anyopaque,
    _: ?*wl.c.zwlr_screencopy_frame_v1,
    format: u32,
    w: u32,
    h: u32,
    stride: u32,
) callconv(.c) void {
    const state: *CaptureState = @ptrCast(@alignCast(data));
    state.shm_format = format;
    state.buffer_width = w;
    state.buffer_height = h;
    state.buffer_stride = stride;
    // For v1/v2 (no buffer_done event), mark as done immediately
    state.buffer_info_done = true;
}

fn screencopyFlags(_: ?*anyopaque, _: ?*wl.c.zwlr_screencopy_frame_v1, _: u32) callconv(.c) void {}

fn screencopyReady(data: ?*anyopaque, _: ?*wl.c.zwlr_screencopy_frame_v1, _: u32, _: u32, _: u32) callconv(.c) void {
    const state: *CaptureState = @ptrCast(@alignCast(data));
    state.frame_ready = true;
}

fn screencopyFailed(data: ?*anyopaque, _: ?*wl.c.zwlr_screencopy_frame_v1) callconv(.c) void {
    const state: *CaptureState = @ptrCast(@alignCast(data));
    state.frame_failed = true;
    std.log.err("wlr-screencopy frame capture failed", .{});
}

fn screencopyDamage(_: ?*anyopaque, _: ?*wl.c.zwlr_screencopy_frame_v1, _: u32, _: u32, _: u32, _: u32) callconv(.c) void {}

fn screencopyLinuxDmabuf(_: ?*anyopaque, _: ?*wl.c.zwlr_screencopy_frame_v1, _: u32, _: u32, _: u32) callconv(.c) void {}

fn screencopyBufferDone(data: ?*anyopaque, _: ?*wl.c.zwlr_screencopy_frame_v1) callconv(.c) void {
    const state: *CaptureState = @ptrCast(@alignCast(data));
    state.buffer_info_done = true;
}

const screencopy_frame_listener: wl.c.zwlr_screencopy_frame_v1_listener = .{
    .buffer = screencopyBuffer,
    .flags = screencopyFlags,
    .ready = screencopyReady,
    .failed = screencopyFailed,
    .damage = screencopyDamage,
    .linux_dmabuf = screencopyLinuxDmabuf,
    .buffer_done = screencopyBufferDone,
};

// ── ext-image-copy-capture session listener ─────────────────────────────────

fn extSessionBufferSize(data: ?*anyopaque, _: ?*wl.c.ext_image_copy_capture_session_v1, w: u32, h: u32) callconv(.c) void {
    const state: *CaptureState = @ptrCast(@alignCast(data));
    state.buffer_width = w;
    state.buffer_height = h;
}

fn extSessionShmFormat(data: ?*anyopaque, _: ?*wl.c.ext_image_copy_capture_session_v1, format: u32) callconv(.c) void {
    const state: *CaptureState = @ptrCast(@alignCast(data));
    if (format == wl.c.WL_SHM_FORMAT_ARGB8888 or format == wl.c.WL_SHM_FORMAT_XRGB8888) {
        state.shm_format = format;
    }
}

fn extSessionDmabufDevice(_: ?*anyopaque, _: ?*wl.c.ext_image_copy_capture_session_v1, _: [*c]wl.c.wl_array) callconv(.c) void {}
fn extSessionDmabufFormat(_: ?*anyopaque, _: ?*wl.c.ext_image_copy_capture_session_v1, _: u32, _: [*c]wl.c.wl_array) callconv(.c) void {}

fn extSessionDone(data: ?*anyopaque, _: ?*wl.c.ext_image_copy_capture_session_v1) callconv(.c) void {
    const state: *CaptureState = @ptrCast(@alignCast(data));
    state.buffer_info_done = true;
}

fn extSessionStopped(_: ?*anyopaque, _: ?*wl.c.ext_image_copy_capture_session_v1) callconv(.c) void {
    std.log.warn("capture session stopped unexpectedly", .{});
}

const ext_session_listener: wl.c.ext_image_copy_capture_session_v1_listener = .{
    .buffer_size = extSessionBufferSize,
    .shm_format = extSessionShmFormat,
    .dmabuf_device = extSessionDmabufDevice,
    .dmabuf_format = extSessionDmabufFormat,
    .done = extSessionDone,
    .stopped = extSessionStopped,
};

// ── ext-image-copy-capture frame listener ───────────────────────────────────

fn extFrameTransform(_: ?*anyopaque, _: ?*wl.c.ext_image_copy_capture_frame_v1, _: u32) callconv(.c) void {}
fn extFrameDamage(_: ?*anyopaque, _: ?*wl.c.ext_image_copy_capture_frame_v1, _: i32, _: i32, _: i32, _: i32) callconv(.c) void {}
fn extFramePresentationTime(_: ?*anyopaque, _: ?*wl.c.ext_image_copy_capture_frame_v1, _: u32, _: u32, _: u32) callconv(.c) void {}

fn extFrameReady(data: ?*anyopaque, _: ?*wl.c.ext_image_copy_capture_frame_v1) callconv(.c) void {
    const state: *CaptureState = @ptrCast(@alignCast(data));
    state.frame_ready = true;
}

fn extFrameFailed(data: ?*anyopaque, _: ?*wl.c.ext_image_copy_capture_frame_v1, reason: u32) callconv(.c) void {
    const state: *CaptureState = @ptrCast(@alignCast(data));
    state.frame_failed = true;
    std.log.err("ext-image-copy-capture frame failed with reason: {}", .{reason});
}

const ext_frame_listener: wl.c.ext_image_copy_capture_frame_v1_listener = .{
    .transform = extFrameTransform,
    .damage = extFrameDamage,
    .presentation_time = extFramePresentationTime,
    .ready = extFrameReady,
    .failed = extFrameFailed,
};
