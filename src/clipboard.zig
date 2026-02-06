const std = @import("std");
const posix = std.posix;
const wl = @import("wayland.zig");

/// Native Wayland clipboard using wl_data_device_manager.
///
/// Sets the selection on the existing Wayland connection, then serves paste
/// requests in a blocking event loop until another app claims the selection.
pub const Clipboard = struct {
    data_device_manager: *wl.c.wl_data_device_manager,
    seat: *wl.c.wl_seat,
    display: *wl.c.wl_display,

    /// Copy data to the clipboard and serve it until another app claims the selection.
    /// This function blocks until the clipboard is replaced by another application.
    /// Call from a forked child if you want the parent to return immediately.
    pub fn serve(self: *const Clipboard, mime_type: [*:0]const u8, data: []const u8, serial: u32) !void {
        const data_device = wl.c.wl_data_device_manager_get_data_device(
            self.data_device_manager,
            self.seat,
        ) orelse return error.FailedToGetDataDevice;
        defer wl.c.wl_data_device_destroy(data_device);

        const data_source = wl.c.wl_data_device_manager_create_data_source(
            self.data_device_manager,
        ) orelse return error.FailedToCreateDataSource;

        var state = ServeState{ .data = data };

        _ = wl.c.wl_data_source_add_listener(data_source, &data_source_listener, &state);
        wl.c.wl_data_source_offer(data_source, mime_type);

        wl.c.wl_data_device_set_selection(data_device, data_source, serial);
        _ = wl.c.wl_display_flush(self.display);

        // Serve paste requests until cancelled
        while (!state.cancelled) {
            if (wl.c.wl_display_dispatch(self.display) == -1) break;
        }

        wl.c.wl_data_source_destroy(data_source);
    }

    /// Fork a background process that serves the clipboard data, then return
    /// immediately in the parent. The child blocks until cancelled.
    pub fn copyAndDetach(self: *const Clipboard, mime_type: [*:0]const u8, data: []const u8, serial: u32) !void {
        const data_device = wl.c.wl_data_device_manager_get_data_device(
            self.data_device_manager,
            self.seat,
        ) orelse return error.FailedToGetDataDevice;

        const data_source = wl.c.wl_data_device_manager_create_data_source(
            self.data_device_manager,
        ) orelse return error.FailedToCreateDataSource;

        var state = ServeState{ .data = data };

        _ = wl.c.wl_data_source_add_listener(data_source, &data_source_listener, &state);
        wl.c.wl_data_source_offer(data_source, mime_type);

        // Set the selection on the current (focused) connection
        wl.c.wl_data_device_set_selection(data_device, data_source, serial);
        _ = wl.c.wl_display_flush(self.display);

        const pid = try posix.fork();
        if (pid != 0) {
            // Parent: the selection is set. The child will serve paste requests.
            // We must NOT destroy the data_source or data_device here — the child
            // owns the Wayland connection now. Just return and let the parent
            // call _exit() or avoid closing the display.
            return;
        }

        // Child: detach from terminal, serve clipboard
        _ = posix.setsid() catch {};

        while (!state.cancelled) {
            if (wl.c.wl_display_dispatch(self.display) == -1) break;
        }

        wl.c.wl_data_source_destroy(data_source);
        wl.c.wl_data_device_destroy(data_device);
        posix.exit(0);
    }
};

const ServeState = struct {
    data: []const u8,
    cancelled: bool = false,
};

// ── Data source listener ────────────────────────────────────────────────────

fn dataSourceTarget(_: ?*anyopaque, _: ?*wl.c.wl_data_source, _: [*c]const u8) callconv(.c) void {}

fn dataSourceSend(userdata: ?*anyopaque, _: ?*wl.c.wl_data_source, _: [*c]const u8, fd: i32) callconv(.c) void {
    const state: *ServeState = @ptrCast(@alignCast(userdata));
    var written: usize = 0;
    while (written < state.data.len) {
        const n = posix.write(fd, state.data[written..]) catch break;
        if (n == 0) break;
        written += n;
    }
    posix.close(fd);
}

fn dataSourceCancelled(userdata: ?*anyopaque, _: ?*wl.c.wl_data_source) callconv(.c) void {
    const state: *ServeState = @ptrCast(@alignCast(userdata));
    state.cancelled = true;
}

fn dataSourceDndDropPerformed(_: ?*anyopaque, _: ?*wl.c.wl_data_source) callconv(.c) void {}
fn dataSourceDndFinished(_: ?*anyopaque, _: ?*wl.c.wl_data_source) callconv(.c) void {}
fn dataSourceAction(_: ?*anyopaque, _: ?*wl.c.wl_data_source, _: u32) callconv(.c) void {}

const data_source_listener: wl.c.wl_data_source_listener = .{
    .target = dataSourceTarget,
    .send = dataSourceSend,
    .cancelled = dataSourceCancelled,
    .dnd_drop_performed = dataSourceDndDropPerformed,
    .dnd_finished = dataSourceDndFinished,
    .action = dataSourceAction,
};
