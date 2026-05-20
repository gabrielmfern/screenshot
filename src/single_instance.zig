const std = @import("std");
const posix = std.posix;
const linux = std.os.linux;

pub const Error = error{
    AlreadyRunning,
    LockSetupFailed,
};

/// Acquires a process-wide exclusive lock on a file in $XDG_RUNTIME_DIR
/// (falling back to /tmp). Returns `error.AlreadyRunning` if another
/// instance already holds the lock. The fd is intentionally leaked: the
/// kernel releases the flock when the process exits.
pub fn acquire(env: std.process.Environ) Error!void {
    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const path = buildLockPath(&path_buf, env) catch return error.LockSetupFailed;

    const fd = posix.openatZ(
        posix.AT.FDCWD,
        path,
        .{ .ACCMODE = .RDWR, .CREAT = true, .CLOEXEC = true },
        0o600,
    ) catch return error.LockSetupFailed;

    const rc = linux.flock(fd, posix.LOCK.EX | posix.LOCK.NB);
    const signed: isize = @bitCast(rc);
    if (signed == 0) return; // success
    _ = std.c.close(fd);
    // Linux encodes -errno in the syscall return. EAGAIN/EWOULDBLOCK = 11.
    if (signed == -11) return error.AlreadyRunning;
    return error.LockSetupFailed;
}

fn buildLockPath(buf: []u8, env: std.process.Environ) ![:0]const u8 {
    if (env.getPosix("XDG_RUNTIME_DIR")) |runtime_dir| {
        if (runtime_dir.len > 0) {
            return std.fmt.bufPrintZ(buf, "{s}/screenshot.lock", .{runtime_dir});
        }
    }
    const uid = std.os.linux.geteuid();
    return std.fmt.bufPrintZ(buf, "/tmp/screenshot-{d}.lock", .{uid});
}
