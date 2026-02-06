const std = @import("std");
const posix = std.posix;

const wl = @import("wayland.zig");
const Image = @import("image.zig").Image;
const Rect = @import("image.zig").Rect;
const CaptureState = @import("capture.zig").CaptureState;
const Overlay = @import("overlay.zig").Overlay;

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

/// Copy a PNG file to the Wayland clipboard via wl-copy.
fn copyToClipboard(allocator: std.mem.Allocator, png_path: [:0]const u8) !void {
    var child = std.process.Child.init(
        &.{ "wl-copy", "--type", "image/png" },
        allocator,
    );
    child.stdin_behavior = .Pipe;
    child.stdout_behavior = .Ignore;
    child.stderr_behavior = .Ignore;
    try child.spawn();

    // Read the PNG file and write it to wl-copy's stdin
    const file = try std.fs.cwd().openFile(png_path, .{});
    defer file.close();

    const png_data = try file.readToEndAlloc(allocator, 64 * 1024 * 1024);
    defer allocator.free(png_data);

    if (child.stdin) |stdin| {
        var f = stdin;
        f.writeAll(png_data) catch {};
        f.close();
        child.stdin = null;
    }

    _ = child.wait() catch {};
}

// ── Main ────────────────────────────────────────────────────────────────────

const Mode = enum {
    fullscreen,
    region,
};

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
    defer wl.c.wl_display_disconnect(wl_display);

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
    defer capture.deinit();

    var screenshot = capture.getImage();

    // Step 2: Region selection or fullscreen
    var cropped_image: ?Image = null;
    defer if (cropped_image) |*img| img.deinit();

    var action: Overlay.Action = .save_to_file; // default for fullscreen mode

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
            cropped_image = try screenshot.crop(allocator, sel);
        } else {
            std.log.info("no selection made", .{});
            return;
        }
    }

    // Step 3: Execute the chosen action
    var save_target: *Image = if (cropped_image) |*img| img else &screenshot;

    switch (action) {
        .copy_to_clipboard => {
            const timer = Timer.start();
            // Save to a temp file, then pipe to wl-copy
            const tmp_path = "/tmp/screenshot-clipboard.png";
            try save_target.savePng(tmp_path);
            try copyToClipboard(allocator, tmp_path);
            std.fs.deleteFileAbsolute(tmp_path) catch {};
            std.log.info("copied to clipboard in {d:.1}ms", .{timer.elapsedMs()});
        },
        .save_to_file => {
            const timer = Timer.start();
            const owned_path = if (output_path_arg) |p|
                try allocator.dupeZ(u8, p)
            else
                try generateOutputPath(allocator, save_target.width, save_target.height);
            defer allocator.free(owned_path);

            try save_target.savePng(owned_path.ptr);
            std.log.info("saved to {s} in {d:.1}ms", .{ owned_path, timer.elapsedMs() });
        },
        .cancel => unreachable, // handled above
        .none => {
            std.log.info("no action taken", .{});
            return;
        },
    }

    // Cleanup globals
    if (layer_shell) |ls| wl.c.zwlr_layer_shell_v1_destroy(ls);
    if (capture_manager) |cm| wl.c.ext_image_copy_capture_manager_v1_destroy(cm);
    if (source_manager) |sm| wl.c.ext_output_image_capture_source_manager_v1_destroy(sm);
    if (screencopy_manager) |sm| wl.c.zwlr_screencopy_manager_v1_destroy(sm);
    if (wl_seat) |s| wl.c.wl_seat_destroy(s);
    wl.c.wl_shm_destroy(wl_shm.?);
    wl.c.wl_compositor_destroy(wl_compositor.?);
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
}
