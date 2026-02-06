const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const module = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
    });

    module.linkSystemLibrary("wayland-client", .{});
    module.linkSystemLibrary("wayland-cursor", .{});
    module.linkSystemLibrary("xkbcommon", .{});

    // FFmpeg libraries for video encoding
    module.linkSystemLibrary("libavcodec", .{});
    module.linkSystemLibrary("libavformat", .{});
    module.linkSystemLibrary("libavutil", .{});
    module.linkSystemLibrary("libswscale", .{});

    // PulseAudio simple API for sound effects (routes through PipeWire)
    module.linkSystemLibrary("libpulse-simple", .{});

    const Protocol = struct {
        name: []const u8,
        xmlPath: []const u8,
    };
    const waylandProtocols = comptime [_]Protocol{
        Protocol{
            .name = "xdg-shell",
            .xmlPath = "/usr/share/wayland-protocols/stable/xdg-shell/xdg-shell.xml",
        },
        Protocol{
            .name = "fractional-scale-v1",
            .xmlPath = "/usr/share/wayland-protocols/staging/fractional-scale/fractional-scale-v1.xml",
        },
        Protocol{
            .name = "viewporter",
            .xmlPath = "/usr/share/wayland-protocols/stable/viewporter/viewporter.xml",
        },
        Protocol{
            .name = "image-copy-capture",
            .xmlPath = "/usr/share/wayland-protocols/staging/ext-image-copy-capture/ext-image-copy-capture-v1.xml",
        },
        Protocol{
            .name = "image-capture-source",
            .xmlPath = "/usr/share/wayland-protocols/staging/ext-image-capture-source/ext-image-capture-source-v1.xml",
        },
        Protocol{
            .name = "foreign-toplevel-list",
            .xmlPath = "/usr/share/wayland-protocols/staging/ext-foreign-toplevel-list/ext-foreign-toplevel-list-v1.xml",
        },
        Protocol{
            .name = "ext-data-control-v1",
            .xmlPath = "/usr/share/wayland-protocols/staging/ext-data-control/ext-data-control-v1.xml",
        },
    };

    const allProtocols = waylandProtocols;

    inline for (allProtocols) |protocol| {
        const wf = b.addWriteFiles();

        const cCommand = b.addSystemCommand(&.{
            "wayland-scanner",
            "private-code",
            protocol.xmlPath,
        });
        const cFile = cCommand.addOutputFileArg(protocol.name ++ "-protocol.c");
        const protocolCPath = wf.addCopyFile(cFile, protocol.name ++ "-protocol.c");

        const headerCommand = b.addSystemCommand(&.{
            "wayland-scanner",
            "client-header",
            protocol.xmlPath,
        });
        const headerFile = headerCommand.addOutputFileArg(protocol.name ++ "-client-protocol.h");
        _ = wf.addCopyFile(headerFile, protocol.name ++ "-client-protocol.h");

        module.addIncludePath(wf.getDirectory());
        module.addCSourceFile(.{ .file = protocolCPath, .flags = &.{} });
    }

    // wlr protocols from local docs directory (not system protocols)
    const localProtocols = [_][]const u8{
        "wlr-layer-shell-unstable-v1",
        "wlr-screencopy-unstable-v1",
    };
    inline for (localProtocols) |name| {
        const wf = b.addWriteFiles();
        const localXml = b.path("docs/" ++ name ++ ".xml");

        const cCommand = b.addSystemCommand(&.{ "wayland-scanner", "private-code" });
        cCommand.addFileArg(localXml);
        const cFile = cCommand.addOutputFileArg(name ++ "-protocol.c");
        const protocolCPath = wf.addCopyFile(cFile, name ++ "-protocol.c");

        const headerCommand = b.addSystemCommand(&.{ "wayland-scanner", "client-header" });
        headerCommand.addFileArg(localXml);
        const headerFile = headerCommand.addOutputFileArg(name ++ "-client-protocol.h");
        _ = wf.addCopyFile(headerFile, name ++ "-client-protocol.h");

        module.addIncludePath(wf.getDirectory());
        module.addCSourceFile(.{ .file = protocolCPath, .flags = &.{} });
    }

    // Link stb_image_write
    const stb_image_dep = b.dependency("stb_image", .{
        .target = target,
        .optimize = optimize,
    });
    module.addIncludePath(stb_image_dep.path(""));
    module.linkLibrary(stb_image_dep.artifact("stb_image"));

    const exe = b.addExecutable(.{
        .name = "screenshot",
        .root_module = module,
    });
    b.installArtifact(exe);

    const run_step = b.step("run", "Run the app");
    const run_cmd = b.addRunArtifact(exe);
    run_step.dependOn(&run_cmd.step);
    run_cmd.step.dependOn(b.getInstallStep());
    if (b.args) |args| {
        run_cmd.addArgs(args);
    }

    const exe_tests = b.addTest(.{
        .root_module = exe.root_module,
    });
    const run_exe_tests = b.addRunArtifact(exe_tests);
    const test_step = b.step("test", "Run tests");
    test_step.dependOn(&run_exe_tests.step);
}
