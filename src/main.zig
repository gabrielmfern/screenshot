const std = @import("std");
const posix = std.posix;

const wl = @import("wayland.zig");
const Image = @import("image.zig").Image;
const Rect = @import("image.zig").Rect;
const CaptureState = @import("capture.zig").CaptureState;
const Overlay = @import("overlay.zig").Overlay;
const Recorder = @import("recorder.zig").Recorder;
const RecordingOverlay = @import("recording_overlay.zig").RecordingOverlay;
const ScrollingOverlay = @import("scrolling_overlay.zig").ScrollingOverlay;
const Clipboard = @import("clipboard.zig").Clipboard;
const Audio = @import("audio.zig").Audio;

// ── Timer ────────────────────────────────────────────────────────────────────

const Timer = struct {
    start_ns: i128,

    fn start() Timer {
        return .{ .start_ns = std.time.nanoTimestamp() };
    }

    fn elapsedMs(self: Timer) f64 {
        const end_ns = std.time.nanoTimestamp();
        return @as(f64, @floatFromInt(end_ns - self.start_ns)) / 1_000_000.0;
    }
};

// ── Wayland globals ─────────────────────────────────────────────────────────

var wl_display: ?*wl.c.wl_display = null;
var wl_registry: ?*wl.c.wl_registry = null;
var wl_compositor: ?*wl.c.wl_compositor = null;
var wl_shm: ?*wl.c.wl_shm = null;
var wl_seat: ?*wl.c.wl_seat = null;
var wl_output: ?*wl.c.wl_output = null;
var layer_shell: ?*wl.c.zwlr_layer_shell_v1 = null;
var capture_manager: ?*wl.c.ext_image_copy_capture_manager_v1 = null;
var source_manager: ?*wl.c.ext_output_image_capture_source_manager_v1 = null;
var screencopy_manager: ?*wl.c.zwlr_screencopy_manager_v1 = null;
var data_control_manager: ?*wl.c.ext_data_control_manager_v1 = null;

// ── Registry listener ───────────────────────────────────────────────────────

fn BindingInfo(T: type) type {
    return struct {
        interface: *const wl.c.wl_interface,
        version: u32,

        fn new(interface: *const wl.c.wl_interface, version: u32) @This() {
            return .{ .interface = interface, .version = version };
        }

        fn is(self: @This(), name: []const u8) bool {
            const iface_name = self.interface.name[0..std.mem.len(self.interface.name)];
            return std.mem.eql(u8, name, iface_name);
        }

        fn bind(self: @This(), registry: ?*wl.c.wl_registry, name: u32) *T {
            return @ptrCast(@alignCast(
                wl.c.wl_registry_bind(registry, name, self.interface, self.version) orelse
                    @panic("failed to bind global"),
            ));
        }
    };
}

fn registryGlobal(
    _: ?*anyopaque,
    registry: ?*wl.c.wl_registry,
    name: u32,
    interface_ptr: [*c]const u8,
    _: u32,
) callconv(.c) void {
    const iface: []const u8 = interface_ptr[0..std.mem.len(interface_ptr)];

    const compositor_info = BindingInfo(wl.c.wl_compositor).new(&wl.c.wl_compositor_interface, 4);
    const shm_info = BindingInfo(wl.c.wl_shm).new(&wl.c.wl_shm_interface, 1);
    const seat_info = BindingInfo(wl.c.wl_seat).new(&wl.c.wl_seat_interface, 1);
    const output_info = BindingInfo(wl.c.wl_output).new(&wl.c.wl_output_interface, 3);
    const layer_shell_info = BindingInfo(wl.c.zwlr_layer_shell_v1).new(&wl.c.zwlr_layer_shell_v1_interface, 4);
    const capture_mgr_info = BindingInfo(wl.c.ext_image_copy_capture_manager_v1).new(&wl.c.ext_image_copy_capture_manager_v1_interface, 1);
    const source_mgr_info = BindingInfo(wl.c.ext_output_image_capture_source_manager_v1).new(&wl.c.ext_output_image_capture_source_manager_v1_interface, 1);
    const screencopy_info = BindingInfo(wl.c.zwlr_screencopy_manager_v1).new(&wl.c.zwlr_screencopy_manager_v1_interface, 3);
    const data_control_info = BindingInfo(wl.c.ext_data_control_manager_v1).new(&wl.c.ext_data_control_manager_v1_interface, 1);

    if (compositor_info.is(iface)) {
        wl_compositor = compositor_info.bind(registry, name);
    } else if (shm_info.is(iface)) {
        wl_shm = shm_info.bind(registry, name);
    } else if (seat_info.is(iface)) {
        wl_seat = seat_info.bind(registry, name);
    } else if (output_info.is(iface)) {
        // For now, use the first output we find
        if (wl_output == null) {
            wl_output = output_info.bind(registry, name);
        }
    } else if (layer_shell_info.is(iface)) {
        layer_shell = layer_shell_info.bind(registry, name);
    } else if (capture_mgr_info.is(iface)) {
        capture_manager = capture_mgr_info.bind(registry, name);
    } else if (source_mgr_info.is(iface)) {
        source_manager = source_mgr_info.bind(registry, name);
    } else if (screencopy_info.is(iface)) {
        screencopy_manager = screencopy_info.bind(registry, name);
    } else if (data_control_info.is(iface)) {
        data_control_manager = data_control_info.bind(registry, name);
    }
}

fn registryGlobalRemove(_: ?*anyopaque, _: ?*wl.c.wl_registry, _: u32) callconv(.c) void {}

const registry_listener: wl.c.wl_registry_listener = .{
    .global = registryGlobal,
    .global_remove = registryGlobalRemove,
};

// ── Output path generation ──────────────────────────────────────────────────

fn getPicturesDir(allocator: std.mem.Allocator) ![]const u8 {
    var child = std.process.Child.init(&.{ "xdg-user-dir", "PICTURES" }, allocator);
    child.stdout_behavior = .Pipe;
    child.stderr_behavior = .Ignore;
    child.spawn() catch return error.XdgUserDirFailed;

    var buf: [4096]u8 = undefined;
    const n = if (child.stdout) |stdout|
        stdout.readAll(&buf) catch 0
    else
        0;
    _ = child.wait() catch {};

    if (n > 0) {
        const trimmed = std.mem.trimRight(u8, buf[0..n], "\n\r");
        if (trimmed.len > 0) {
            return try allocator.dupe(u8, trimmed);
        }
    }
    return error.XdgUserDirFailed;
}

fn getFallbackPicturesDir(allocator: std.mem.Allocator) ![]const u8 {
    const home = posix.getenv("HOME") orelse return error.NoHomeDir;
    return try allocator.dupe(u8, home);
}

fn generateOutputPath(allocator: std.mem.Allocator, width: u32, height: u32) ![:0]u8 {
    const pictures_dir = getPicturesDir(allocator) catch try getFallbackPicturesDir(allocator);
    defer allocator.free(pictures_dir);

    const timestamp = std.time.timestamp();
    const epoch_seconds = std.time.epoch.EpochSeconds{ .secs = @intCast(timestamp) };
    const day_seconds = epoch_seconds.getDaySeconds();
    const year_day = epoch_seconds.getEpochDay().calculateYearDay();
    const month_day = year_day.calculateMonthDay();

    return std.fmt.allocPrintSentinel(
        allocator,
        "{s}/screenshot-{d}x{d}-{d}-{d:0>2}-{d:0>2}_{d:0>2}{d:0>2}{d:0>2}.png",
        .{
            pictures_dir,
            width,
            height,
            year_day.year,
            month_day.month.numeric(),
            month_day.day_index + 1,
            day_seconds.getHoursIntoDay(),
            day_seconds.getMinutesIntoHour(),
            day_seconds.getSecondsIntoMinute(),
        },
        0,
    );
}

fn generateRecordingPath(allocator: std.mem.Allocator) ![:0]u8 {
    const videos_dir = getVideosDir(allocator) catch try getFallbackPicturesDir(allocator);
    defer allocator.free(videos_dir);

    const timestamp = std.time.timestamp();
    const epoch_seconds = std.time.epoch.EpochSeconds{ .secs = @intCast(timestamp) };
    const day_seconds = epoch_seconds.getDaySeconds();
    const year_day = epoch_seconds.getEpochDay().calculateYearDay();
    const month_day = year_day.calculateMonthDay();

    return std.fmt.allocPrintSentinel(
        allocator,
        "{s}/recording-{d}-{d:0>2}-{d:0>2}_{d:0>2}{d:0>2}{d:0>2}.mp4",
        .{
            videos_dir,
            year_day.year,
            month_day.month.numeric(),
            month_day.day_index + 1,
            day_seconds.getHoursIntoDay(),
            day_seconds.getMinutesIntoHour(),
            day_seconds.getSecondsIntoMinute(),
        },
        0,
    );
}

fn getVideosDir(allocator: std.mem.Allocator) ![]const u8 {
    var child = std.process.Child.init(&.{ "xdg-user-dir", "VIDEOS" }, allocator);
    child.stdout_behavior = .Pipe;
    child.stderr_behavior = .Ignore;
    child.spawn() catch return error.XdgUserDirFailed;

    var buf: [4096]u8 = undefined;
    const n = if (child.stdout) |stdout|
        stdout.readAll(&buf) catch 0
    else
        0;
    _ = child.wait() catch {};

    if (n > 0) {
        const trimmed = std.mem.trimRight(u8, buf[0..n], "\n\r");
        if (trimmed.len > 0) {
            return try allocator.dupe(u8, trimmed);
        }
    }
    return error.XdgUserDirFailed;
}

/// Copy file data to the Wayland clipboard natively via ext-data-control-v1.
/// Forks a background process that serves clipboard requests until cancelled.
/// After this returns, the parent must NOT disconnect the Wayland display
/// (the child process needs the connection to serve paste requests).
fn copyFileToClipboard(allocator: std.mem.Allocator, path: [:0]const u8, mime_type: [*:0]const u8) !void {
    const file = try std.fs.cwd().openFile(path, .{});
    defer file.close();

    // After fork(), the child has its own copy-on-write pages, so the
    // parent can safely free its copy.
    const file_data = try file.readToEndAlloc(allocator, 512 * 1024 * 1024);
    defer allocator.free(file_data);

    try copyDataToClipboard(mime_type, file_data);
}

fn copyDataToClipboard(mime_type: [*:0]const u8, data: []const u8) !void {
    const clipboard = Clipboard{
        .data_control_manager = data_control_manager orelse return error.MissingDataControlManager,
        .seat = wl_seat orelse return error.MissingSeat,
        .display = wl_display orelse return error.NoWaylandDisplay,
    };
    try clipboard.copy(mime_type, data);
}

// ── Main ────────────────────────────────────────────────────────────────────

const Mode = enum {
    fullscreen,
    region,
};

fn mapRectBetweenSpaces(rect: Rect, src_width: u32, src_height: u32, dst_width: u32, dst_height: u32) Rect {
    if (rect.isEmpty() or src_width == 0 or src_height == 0 or dst_width == 0 or dst_height == 0) {
        return .{ .x = 0, .y = 0, .width = 0, .height = 0 };
    }

    const x1 = scaleFloor(rect.x, src_width, dst_width);
    const y1 = scaleFloor(rect.y, src_height, dst_height);
    const x2 = scaleCeil(rect.x +| rect.width, src_width, dst_width);
    const y2 = scaleCeil(rect.y +| rect.height, src_height, dst_height);

    const clamped_x1 = @min(x1, dst_width);
    const clamped_y1 = @min(y1, dst_height);
    const clamped_x2 = @min(x2, dst_width);
    const clamped_y2 = @min(y2, dst_height);

    return .{
        .x = clamped_x1,
        .y = clamped_y1,
        .width = clamped_x2 -| clamped_x1,
        .height = clamped_y2 -| clamped_y1,
    };
}

fn scaleFloor(coord: u32, src_extent: u32, dst_extent: u32) u32 {
    const scaled: u64 = (@as(u64, coord) * dst_extent) / src_extent;
    return @intCast(scaled);
}

fn scaleCeil(coord: u32, src_extent: u32, dst_extent: u32) u32 {
    const scaled: u64 = (@as(u64, coord) * dst_extent + src_extent - 1) / src_extent;
    return @intCast(scaled);
}

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer {
        if (gpa.deinit() == .leak) {
            std.log.err("memory leak detected", .{});
        }
    }
    const allocator = gpa.allocator();

    // Parse CLI args
    var args = try std.process.argsWithAllocator(allocator);
    defer args.deinit();
    _ = args.next(); // skip program name

    var mode: Mode = .region; // default to region selection
    var output_path_arg: ?[]const u8 = null;

    while (args.next()) |arg| {
        if (std.mem.eql(u8, arg, "--fullscreen") or std.mem.eql(u8, arg, "-f")) {
            mode = .fullscreen;
        } else if (std.mem.eql(u8, arg, "--output") or std.mem.eql(u8, arg, "-o")) {
            output_path_arg = args.next() orelse {
                std.log.err("--output requires a file path argument", .{});
                return error.InvalidArgs;
            };
        } else if (std.mem.eql(u8, arg, "--help") or std.mem.eql(u8, arg, "-h")) {
            const help =
                \\Usage: screenshot [OPTIONS]
                \\
                \\Options:
                \\  -f, --fullscreen   Capture the entire screen (no region selection)
                \\  -o, --output PATH  Save screenshot to PATH
                \\  -h, --help         Show this help message
                \\
                \\Controls (region mode):
                \\  Click and drag    Select a region (can re-select)
                \\  Ctrl+C            Copy selection to clipboard
                \\  Ctrl+S            Save selection to file
                \\  Escape            Cancel
                \\
            ;
            _ = posix.write(posix.STDOUT_FILENO, help) catch {};
            return;
        }
    }

    // Connect to Wayland
    wl_display = wl.c.wl_display_connect(null) orelse {
        std.log.err("failed to connect to Wayland display", .{});
        return error.NoWaylandDisplay;
    };
    // NOTE: no defer disconnect here. If we fork a clipboard daemon,
    // the child inherits the fd and we must not close it in the parent.
    // Cleanup is done explicitly at the end, or skipped if clipboard was set.

    wl_registry = wl.c.wl_display_get_registry(wl_display) orelse
        return error.FailedToGetRegistry;
    defer wl.c.wl_registry_destroy(wl_registry);

    _ = wl.c.wl_registry_add_listener(wl_registry, &registry_listener, null);
    _ = wl.c.wl_display_roundtrip(wl_display);

    // Verify required globals
    if (wl_compositor == null) return error.MissingCompositor;
    if (wl_shm == null) return error.MissingShm;
    if (wl_output == null) return error.MissingOutput;

    const has_ext_capture = capture_manager != null and source_manager != null;
    const has_screencopy = screencopy_manager != null;

    if (!has_ext_capture and !has_screencopy) {
        std.log.err("compositor supports neither ext-image-copy-capture-v1 nor wlr-screencopy-unstable-v1", .{});
        return error.NoCaptureProtocol;
    }

    // Step 1: Capture the full screen (prefer ext-image-copy-capture, fall back to wlr-screencopy)
    var capture = CaptureState{};
    if (has_ext_capture) {
        std.log.info("using ext-image-copy-capture-v1", .{});
        try capture.initExtCapture(
            wl_display.?,
            capture_manager.?,
            source_manager.?,
            wl_output.?,
            wl_shm.?,
        );
    } else {
        std.log.info("using wlr-screencopy-unstable-v1", .{});
        try capture.initScreencopy(
            wl_display.?,
            screencopy_manager.?,
            wl_output.?,
            wl_shm.?,
        );
    }
    var screenshot = capture.getImage();

    // Step 2: Region selection or fullscreen
    var cropped_image: ?Image = null;
    defer if (cropped_image) |*img| img.deinit();

    var action: Overlay.Action = .save_to_file; // default for fullscreen mode
    var overlay_selection: ?Rect = null; // selection in overlay surface coordinates
    var capture_selection: ?Rect = null; // selection mapped to capture buffer coordinates

    if (mode == .region) {
        if (wl_seat == null) return error.MissingSeat;
        if (layer_shell == null) {
            std.log.err("compositor does not support wlr-layer-shell", .{});
            return error.MissingLayerShell;
        }

        var overlay = Overlay{
            .display = wl_display.?,
            .compositor = wl_compositor.?,
            .shm = wl_shm.?,
            .seat = wl_seat.?,
            .layer_shell = layer_shell.?,
            .output = wl_output.?,
            .screenshot = &screenshot,
        };
        try overlay.init(allocator);

        const result = try overlay.run();
        action = result.action;

        // Dismiss the overlay immediately so the user sees it disappear
        // before the save/copy work begins.
        overlay.deinit();
        _ = wl.c.wl_display_flush(wl_display);

        if (action == .cancel) {
            std.log.info("cancelled", .{});
            return;
        }

        if (result.selection) |sel| {
            overlay_selection = sel;
            const mapped_sel = mapRectBetweenSpaces(
                sel,
                result.surface_width,
                result.surface_height,
                screenshot.width,
                screenshot.height,
            );
            if (mapped_sel.isEmpty()) {
                std.log.info("selection mapped to empty region", .{});
                return;
            }
            capture_selection = mapped_sel;
            cropped_image = try screenshot.crop(allocator, mapped_sel);
        } else {
            std.log.info("no selection made", .{});
            return;
        }

        // Scrolling screenshot flow: auto-capture periodically, detect overlap and stitch
        if (action == .start_scrolling_capture) {
            // Free the pre-overlay capture; we'll re-capture with the overlay active
            if (cropped_image) |*img| img.deinit();
            cropped_image = null;

            var scroll_overlay = ScrollingOverlay{
                .display = wl_display.?,
                .compositor = wl_compositor.?,
                .shm = wl_shm.?,
                .seat = wl_seat.?,
                .layer_shell = layer_shell.?,
                .output = wl_output.?,
                .region = overlay_selection.?,
            };
            try scroll_overlay.init(allocator);

            // Capture the first slice with the overlay active so all captures
            // are under the same compositing conditions
            var first_capture = CaptureState{};
            if (has_ext_capture) {
                try first_capture.initExtCapture(
                    wl_display.?,
                    capture_manager.?,
                    source_manager.?,
                    wl_output.?,
                    wl_shm.?,
                );
            } else {
                try first_capture.initScreencopy(
                    wl_display.?,
                    screencopy_manager.?,
                    wl_output.?,
                    wl_shm.?,
                );
            }
            var first_full = first_capture.getImage();
            var stitched_image = try first_full.crop(allocator, capture_selection.?);
            first_capture.deinit();

            scroll_overlay.setPreviewImage(&stitched_image);

            const capture_interval_ms: u64 = 400;
            var last_capture_ns: i128 = std.time.nanoTimestamp();

            while (!scroll_overlay.done) {
                // Non-blocking dispatch for overlay events
                const action_triggered = scroll_overlay.dispatchNonBlocking() catch {
                    scroll_overlay.deinit();
                    stitched_image.deinit();
                    return error.WaylandDispatchFailed;
                };
                if (action_triggered) break;

                // Check if it's time to capture another slice
                const now = std.time.nanoTimestamp();
                const elapsed_ms: u64 = @intCast(@max(0, @divFloor(now - last_capture_ns, 1_000_000)));
                if (elapsed_ms >= capture_interval_ms) {
                    last_capture_ns = now;

                    // Capture the screen region
                    var slice_capture = CaptureState{};
                    const capture_ok = blk: {
                        if (has_ext_capture) {
                            slice_capture.initExtCapture(
                                wl_display.?,
                                capture_manager.?,
                                source_manager.?,
                                wl_output.?,
                                wl_shm.?,
                            ) catch break :blk false;
                        } else {
                            slice_capture.initScreencopy(
                                wl_display.?,
                                screencopy_manager.?,
                                wl_output.?,
                                wl_shm.?,
                            ) catch break :blk false;
                        }
                        break :blk true;
                    };
                    if (!capture_ok) continue;

                    var full = slice_capture.getImage();
                    var slice = full.crop(allocator, capture_selection.?) catch {
                        slice_capture.deinit();
                        continue;
                    };
                    defer slice.deinit();
                    slice_capture.deinit();

                    // Try smart stitching with overlap detection
                    if (stitched_image.stitchBelow(allocator, &slice) catch null) |new_img| {
                        stitched_image.deinit();
                        stitched_image = new_img;
                        scroll_overlay.setPreviewImage(&stitched_image);
                        std.log.info("stitched: {d}x{d}", .{ stitched_image.width, stitched_image.height });
                    }
                } else {
                    std.Thread.sleep(10_000_000);
                }
            }

            const scroll_result = scroll_overlay.action;
            scroll_overlay.deinit();
            _ = wl.c.wl_display_flush(wl_display);

            if (scroll_result == .confirm) {
                const timer = Timer.start();
                const owned_path = if (output_path_arg) |p|
                    try allocator.dupeZ(u8, p)
                else
                    try generateOutputPath(allocator, stitched_image.width, stitched_image.height);
                defer allocator.free(owned_path);
                try stitched_image.savePng(owned_path.ptr);
                Audio.play(.shutter);
                std.log.info("saved scrolling screenshot to {s} in {d:.1}ms", .{ owned_path, timer.elapsedMs() });

                const tmp_path = "/tmp/screenshot-clipboard.png";
                try stitched_image.savePng(tmp_path);
                copyFileToClipboard(allocator, tmp_path, "image/png") catch {};
                std.fs.deleteFileAbsolute(tmp_path) catch {};
            }
            stitched_image.deinit();
            capture.deinit();
            return;
        }
    }

    // Step 3: Execute the chosen action
    var save_target: *Image = if (cropped_image) |*img| img else &screenshot;
    var clipboard_forked = false;

    switch (action) {
        .start_scrolling_capture => unreachable, // handled above with early return
        .copy_to_clipboard => {
            const timer = Timer.start();
            const tmp_path = "/tmp/screenshot-clipboard.png";
            try save_target.savePng(tmp_path);
            try copyFileToClipboard(allocator, tmp_path, "image/png");
            clipboard_forked = true;
            std.fs.deleteFileAbsolute(tmp_path) catch {};
            Audio.play(.shutter);
            std.log.info("copied to clipboard in {d:.1}ms", .{timer.elapsedMs()});
        },
        .save_to_file, .take_screenshot => {
            const timer = Timer.start();
            const owned_path = if (output_path_arg) |p|
                try allocator.dupeZ(u8, p)
            else
                try generateOutputPath(allocator, save_target.width, save_target.height);
            defer allocator.free(owned_path);

            try save_target.savePng(owned_path.ptr);
            Audio.play(.shutter);
            std.log.info("saved to {s} in {d:.1}ms", .{ owned_path, timer.elapsedMs() });
        },
        .record => {
            const total_timer = Timer.start();

            const overlay_sel = overlay_selection orelse {
                std.log.info("no selection for recording", .{});
                return;
            };
            const capture_sel = capture_selection orelse overlay_sel;

            // Start native Wayland recorder + ffmpeg encoder
            std.log.info("starting recording ({d}x{d} at {d},{d})", .{ capture_sel.width, capture_sel.height, capture_sel.x, capture_sel.y });
            var recorder = Recorder.start(
                allocator,
                capture_sel,
                wl_display.?,
                wl_shm.?,
                wl_output.?,
                capture_manager,
                source_manager,
                screencopy_manager,
            ) catch |err| {
                std.log.err("failed to start recorder: {} (is ffmpeg installed?)", .{err});
                return;
            };
            defer recorder.deinit();

            Audio.play(.record_start);

            // Show recording overlay
            var rec_overlay = RecordingOverlay{
                .display = wl_display.?,
                .compositor = wl_compositor.?,
                .shm = wl_shm.?,
                .seat = wl_seat.?,
                .layer_shell = layer_shell.?,
                .output = wl_output.?,
                .region = overlay_sel,
            };
            try rec_overlay.init(allocator);

            // Main recording loop: capture frames + handle overlay events
            var recording = true;
            while (recording) {
                // Capture a frame and pipe to ffmpeg
                if (!recorder.captureFrame()) {
                    std.log.warn("frame capture failed, stopping recording", .{});
                    break;
                }

                // Dispatch overlay events (non-blocking)
                const action_triggered = rec_overlay.dispatchNonBlocking() catch break;

                if (action_triggered) {
                    switch (rec_overlay.action) {
                        .pause => {
                            recorder.togglePause();
                            if (recorder.paused) {
                                std.log.info("recording paused", .{});
                            } else {
                                std.log.info("recording resumed", .{});
                            }
                            rec_overlay.done = false;
                            rec_overlay.action = .none;
                        },
                        .stop => {
                            recording = false;
                        },
                        .none => {
                            recording = false;
                        },
                    }
                }
            }

            rec_overlay.deinit();
            _ = wl.c.wl_display_flush(wl_display);

            // Stop recorder (closes ffmpeg stdin, waits for muxing to finish)
            var stop_timer = Timer.start();
            recorder.stop();
            Audio.play(.record_stop);
            std.log.info("recorder stopped in {d:.1}ms", .{stop_timer.elapsedMs()});

            // Move the recording to a permanent location
            stop_timer = Timer.start();
            const recording_path = generateRecordingPath(allocator) catch |err| {
                std.log.err("failed to generate recording path: {}", .{err});
                return;
            };
            defer allocator.free(recording_path);

            const file_size = blk: {
                const stat = std.fs.cwd().statFile(recorder.getOutputPath()) catch |err| {
                    std.log.err("recording file not found: {}", .{err});
                    return;
                };
                break :blk stat.size;
            };

            std.fs.copyFileAbsolute(recorder.getOutputPath(), recording_path, .{}) catch |err| {
                std.log.err("failed to copy recording to {s}: {}", .{ recording_path, err });
                return;
            };
            std.fs.deleteFileAbsolute(recorder.getOutputPath()) catch {};

            const size_mb = @as(f64, @floatFromInt(file_size)) / (1024.0 * 1024.0);
            std.log.info("saved to {s} ({d:.1} MB) in {d:.1}ms", .{ recording_path, size_mb, stop_timer.elapsedMs() });

            // Copy file path to clipboard as text/uri-list
            stop_timer = Timer.start();
            const uri = std.fmt.allocPrint(allocator, "file://{s}\r\n", .{recording_path}) catch |err| {
                std.log.err("failed to format URI: {}", .{err});
                return;
            };
            defer allocator.free(uri);

            copyDataToClipboard("text/uri-list", uri) catch |err| {
                std.log.err("failed to copy recording to clipboard: {}", .{err});
                return;
            };
            clipboard_forked = true;
            std.log.info("copied to clipboard in {d:.1}ms", .{stop_timer.elapsedMs()});
            std.log.info("recording complete in {d:.1}ms total", .{total_timer.elapsedMs()});
        },
        .cancel => unreachable, // handled above
        .none => {
            std.log.info("no action taken", .{});
            return;
        },
    }

    // Clean up capture resources (holds references to protocol objects)
    capture.deinit();

    // When a clipboard daemon was forked, it shares our Wayland connection fd.
    // We cannot disconnect or destroy globals — just let the process exit.
    // When no fork happened, the OS cleans up on exit anyway, so explicit
    // cleanup is unnecessary and was actually causing a use-after-free
    // (capture.deinit running after global destroy).
}

// ── Tests ───────────────────────────────────────────────────────────────────

test "generateOutputPath produces valid filename with resolution and date" {
    const allocator = std.testing.allocator;
    const path = try generateOutputPath(allocator, 1920, 1080);
    defer allocator.free(path);

    // Should end with .png and contain the resolution
    try std.testing.expect(std.mem.endsWith(u8, path, ".png"));
    try std.testing.expect(std.mem.indexOf(u8, path, "screenshot-1920x1080-") != null);
    // Should contain underscore separating date from time
    try std.testing.expect(std.mem.indexOf(u8, path, "_") != null);
}

test "mapRectBetweenSpaces maps logical region to physical pixels" {
    // 1.25x scale: 1536x864 logical -> 1920x1080 physical
    const logical = Rect{ .x = 100, .y = 50, .width = 200, .height = 100 };
    const mapped = mapRectBetweenSpaces(logical, 1536, 864, 1920, 1080);

    try std.testing.expectEqual(@as(u32, 125), mapped.x);
    try std.testing.expectEqual(@as(u32, 62), mapped.y);
    try std.testing.expectEqual(@as(u32, 250), mapped.width);
    try std.testing.expectEqual(@as(u32, 126), mapped.height);
}

test "mapRectBetweenSpaces clamps to destination bounds" {
    const logical = Rect{ .x = 900, .y = 700, .width = 200, .height = 100 };
    const mapped = mapRectBetweenSpaces(logical, 1000, 800, 1920, 1080);

    try std.testing.expectEqual(@as(u32, 1728), mapped.x);
    try std.testing.expectEqual(@as(u32, 945), mapped.y);
    try std.testing.expectEqual(@as(u32, 192), mapped.width);
    try std.testing.expectEqual(@as(u32, 135), mapped.height);
}

test "generateOutputPath different resolutions" {
    const allocator = std.testing.allocator;
    const p1 = try generateOutputPath(allocator, 2560, 1440);
    defer allocator.free(p1);
    try std.testing.expect(std.mem.indexOf(u8, p1, "screenshot-2560x1440-") != null);

    const p2 = try generateOutputPath(allocator, 800, 600);
    defer allocator.free(p2);
    try std.testing.expect(std.mem.indexOf(u8, p2, "screenshot-800x600-") != null);
}

// Pull in tests from all modules
comptime {
    _ = @import("image.zig");
    _ = @import("recorder.zig");
    _ = @import("recording_overlay.zig");
    _ = @import("scrolling_overlay.zig");
    _ = @import("clipboard.zig");
    _ = @import("audio.zig");
}
