const std = @import("std");
const posix = std.posix;

const wl = @import("wayland.zig");
const Image = @import("image.zig").Image;
const Rect = @import("image.zig").Rect;
const CaptureState = @import("capture.zig").CaptureState;
const Overlay = @import("overlay.zig").Overlay;

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

fn generateOutputPath(allocator: std.mem.Allocator) ![:0]u8 {
    const timestamp = std.time.timestamp();
    return std.fmt.allocPrintSentinel(allocator, "screenshot-{d}.png", .{timestamp}, 0);
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
                \\  -o, --output PATH  Save screenshot to PATH (default: screenshot-<timestamp>.png)
                \\  -h, --help         Show this help message
                \\
                \\Controls (region mode):
                \\  Click and drag to select a region
                \\  Escape to cancel
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

    // Step 2: Region selection (unless fullscreen mode)
    var cropped_image: ?Image = null;
    defer if (cropped_image) |*img| img.deinit();

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
        try overlay.init();
        defer overlay.deinit();

        const selection = try overlay.run();
        if (selection) |sel| {
            cropped_image = try screenshot.crop(allocator, sel);
        } else {
            std.log.info("selection cancelled", .{});
            return;
        }
    }

    // Step 3: Save to file
    var save_target: *Image = if (cropped_image) |*img| img else &screenshot;

    const owned_path = if (output_path_arg) |p|
        try allocator.dupeZ(u8, p)
    else
        try generateOutputPath(allocator);
    defer allocator.free(owned_path);

    try save_target.savePng(owned_path.ptr);
    std.log.info("screenshot saved to {s}", .{owned_path});

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

test "generateOutputPath produces valid filename" {
    const allocator = std.testing.allocator;
    const path = try generateOutputPath(allocator);
    defer allocator.free(path);

    try std.testing.expect(std.mem.startsWith(u8, path, "screenshot-"));
    try std.testing.expect(std.mem.endsWith(u8, path, ".png"));
    try std.testing.expect(path.len > "screenshot-.png".len);
}

// Pull in tests from all modules
comptime {
    _ = @import("image.zig");
}
