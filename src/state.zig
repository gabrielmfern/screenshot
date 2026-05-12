const std = @import("std");
const Rect = @import("image.zig").Rect;

const file_name = "last.rect";

fn stateDirPath(allocator: std.mem.Allocator, env: std.process.Environ) ![]u8 {
    if (env.getPosix("XDG_STATE_HOME")) |xdg| {
        if (xdg.len > 0) return std.fmt.allocPrint(allocator, "{s}/screenshot", .{xdg});
    }
    const home = env.getPosix("HOME") orelse return error.NoHomeDir;
    return std.fmt.allocPrint(allocator, "{s}/.local/state/screenshot", .{home});
}

fn statePath(allocator: std.mem.Allocator, env: std.process.Environ) ![]u8 {
    const dir = try stateDirPath(allocator, env);
    defer allocator.free(dir);
    return std.fmt.allocPrint(allocator, "{s}/{s}", .{ dir, file_name });
}

pub fn saveLastRect(rect: Rect, io: std.Io, env: std.process.Environ) void {
    var buf: [512]u8 = undefined;
    var fba = std.heap.FixedBufferAllocator.init(&buf);
    const allocator = fba.allocator();

    const dir = stateDirPath(allocator, env) catch return;
    std.Io.Dir.createDirAbsolute(io, dir, .default_dir) catch |err| switch (err) {
        error.PathAlreadyExists => {},
        else => return,
    };

    const path = std.fmt.allocPrint(allocator, "{s}/{s}", .{ dir, file_name }) catch return;
    const file = std.Io.Dir.createFileAbsolute(io, path, .{ .truncate = true }) catch return;
    defer file.close(io);

    var line_buf: [128]u8 = undefined;
    const line = std.fmt.bufPrint(&line_buf, "{d} {d} {d} {d}\n", .{ rect.x, rect.y, rect.width, rect.height }) catch return;
    file.writeStreamingAll(io, line) catch return;
}

pub fn loadLastRect(allocator: std.mem.Allocator, io: std.Io, env: std.process.Environ) ?Rect {
    const path = statePath(allocator, env) catch return null;
    defer allocator.free(path);

    const file = std.Io.Dir.openFileAbsolute(io, path, .{}) catch return null;
    defer file.close(io);

    var buf: [128]u8 = undefined;
    const n = file.readStreaming(io, &.{&buf}) catch return null;
    const contents = std.mem.trim(u8, buf[0..n], " \t\r\n");

    var it = std.mem.tokenizeScalar(u8, contents, ' ');
    const x = std.fmt.parseInt(u32, it.next() orelse return null, 10) catch return null;
    const y = std.fmt.parseInt(u32, it.next() orelse return null, 10) catch return null;
    const w = std.fmt.parseInt(u32, it.next() orelse return null, 10) catch return null;
    const h = std.fmt.parseInt(u32, it.next() orelse return null, 10) catch return null;
    if (w == 0 or h == 0) return null;
    return .{ .x = x, .y = y, .width = w, .height = h };
}
