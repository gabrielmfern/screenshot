const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const module = b.addModule("stb_image", .{
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });

    module.addIncludePath(b.path("."));
    module.addCSourceFile(.{
        .file = b.path("stb_image.c"),
        .flags = &.{
            "-fno-sanitize=alignment",
            "-fno-sanitize=shift",
            "-fno-sanitize=pointer-overflow",
        },
    });
    module.addCSourceFile(.{
        .file = b.path("stb_image_write.c"),
        .flags = &.{
            "-fno-sanitize=alignment",
            "-fno-sanitize=shift",
            "-fno-sanitize=pointer-overflow",
        },
    });

    const lib = b.addLibrary(.{
        .name = "stb_image",
        .root_module = module,
        .linkage = .static,
    });

    lib.installHeader(b.path("stb_image.h"), "stb_image.h");
    lib.installHeader(b.path("stb_image_write.h"), "stb_image_write.h");

    b.installArtifact(lib);
}
