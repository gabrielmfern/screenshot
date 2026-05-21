const std = @import("std");
const posix = std.posix;
const wl = @import("wayland.zig");
const single_instance = @import("single_instance.zig");

/// Native Wayland clipboard using ext-data-control-v1.
///
/// This protocol does NOT require a serial or keyboard focus, making it
/// ideal for clipboard managers and tools like ours that may not have
/// a surface when setting the clipboard.
pub const Clipboard = struct {
    data_control_manager: *wl.c.ext_data_control_manager_v1,
    seat: *wl.c.wl_seat,
    display: *wl.c.wl_display,
    /// fd of the single-instance flock, if any. The forked child must
    /// release it — otherwise the daemon keeps the lock alive and blocks
    /// new screenshot invocations until the clipboard is replaced.
    lock_fd: ?i32 = null,

    /// Copy data to the clipboard. Forks a background process that serves
    /// paste requests until another app claims the selection.
    pub fn copy(self: *const Clipboard, mime_type: [*:0]const u8, data: []const u8) !void {
        const data_device = wl.c.ext_data_control_manager_v1_get_data_device(
            self.data_control_manager,
            self.seat,
        ) orelse return error.FailedToGetDataDevice;

        const data_source = wl.c.ext_data_control_manager_v1_create_data_source(
            self.data_control_manager,
        ) orelse return error.FailedToCreateDataSource;

        var state = ServeState{ .data = data };

        _ = wl.c.ext_data_control_source_v1_add_listener(data_source, &data_source_listener, &state);
        wl.c.ext_data_control_source_v1_offer(data_source, mime_type);

        // No serial needed! ext-data-control-v1 set_selection takes no serial.
        wl.c.ext_data_control_device_v1_set_selection(data_device, data_source);
        _ = wl.c.wl_display_flush(self.display);

        // Fork: parent returns, child serves paste requests
        const pid = std.c.fork();
        if (pid < 0) return error.ForkFailed;
        if (pid != 0) {
            // Parent returns immediately
            return;
        }

        // Child: detach from terminal, serve clipboard
        _ = std.c.setsid();

        // Release the inherited single-instance flock so new screenshot
        // invocations aren't blocked while this clipboard daemon lives on.
        if (self.lock_fd) |fd| single_instance.releaseInChild(fd);

        while (!state.cancelled) {
            if (wl.c.wl_display_dispatch(self.display) == -1) break;
        }

        wl.c.ext_data_control_source_v1_destroy(data_source);
        wl.c.ext_data_control_device_v1_destroy(data_device);
        std.c.exit(0);
    }
};

const ServeState = struct {
    data: []const u8,
    cancelled: bool = false,
};

// ── ext_data_control_source_v1 listener ─────────────────────────────────────

fn dataSourceSend(userdata: ?*anyopaque, _: ?*wl.c.ext_data_control_source_v1, _: [*c]const u8, fd: i32) callconv(.c) void {
    const state: *ServeState = @ptrCast(@alignCast(userdata));
    var written: usize = 0;
    while (written < state.data.len) {
        const remaining = state.data[written..];
        const n = std.c.write(fd, remaining.ptr, remaining.len);
        if (n <= 0) break;
        written += @intCast(n);
    }
    _ = std.c.close(fd);
}

fn dataSourceCancelled(userdata: ?*anyopaque, _: ?*wl.c.ext_data_control_source_v1) callconv(.c) void {
    const state: *ServeState = @ptrCast(@alignCast(userdata));
    state.cancelled = true;
}

const data_source_listener: wl.c.ext_data_control_source_v1_listener = .{
    .send = dataSourceSend,
    .cancelled = dataSourceCancelled,
};
