const std = @import("std");
const posix = std.posix;
const Rect = @import("image.zig").Rect;

/// Screen recorder that wraps wf-recorder for region-based video capture.
pub const Recorder = struct {
    child: std.process.Child,
    output_path: [:0]const u8,
    allocator: std.mem.Allocator,
    paused: bool = false,

    /// Start recording the given screen region to a temporary file.
    pub fn start(allocator: std.mem.Allocator, region: Rect) !Recorder {
        const output_path = "/tmp/screenshot-recording.mp4";

        // Remove any previous recording
        std.fs.deleteFileAbsolute(output_path) catch {};

        // Format geometry as "X,Y WxH" for wf-recorder
        var geom_buf: [64:0]u8 = @splat(0);
        const geom = std.fmt.bufPrint(&geom_buf, "{d},{d} {d}x{d}", .{
            region.x, region.y, region.width, region.height,
        }) catch unreachable;
        geom_buf[geom.len] = 0;
        const geom_z: [:0]const u8 = geom_buf[0..geom.len :0];

        var child = std.process.Child.init(
            &.{ "wf-recorder", "-g", geom_z, "-f", output_path },
            allocator,
        );
        child.stdin_behavior = .Ignore;
        child.stdout_behavior = .Ignore;
        child.stderr_behavior = .Ignore;
        try child.spawn();

        return .{
            .child = child,
            .output_path = output_path,
            .allocator = allocator,
        };
    }

    /// Pause or resume recording by sending SIGUSR1 to wf-recorder.
    pub fn togglePause(self: *Recorder) void {
        posix.kill(self.child.id, posix.SIG.USR1) catch {};
        self.paused = !self.paused;
    }

    /// Stop recording by sending SIGINT to wf-recorder and waiting for it to finish.
    pub fn stop(self: *Recorder) void {
        posix.kill(self.child.id, posix.SIG.INT) catch {};
        _ = self.child.wait() catch {};
    }

    /// Returns the path to the recorded file. Caller should copy it to clipboard.
    pub fn getOutputPath(self: *const Recorder) [:0]const u8 {
        return self.output_path;
    }
};
