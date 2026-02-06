const std = @import("std");
const posix = std.posix;

const wl = @import("wayland.zig");

/// Creates an anonymous file using memfd_create for use as a Wayland SHM pool backing store.
pub fn createShmFile(size: usize) !posix.fd_t {
    const fd = try posix.memfd_create("screenshot-shm", 0);
    errdefer posix.close(fd);
    try posix.ftruncate(fd, @intCast(size));
    return fd;
}

/// A Wayland SHM buffer that wraps an mmap'd region backed by a wl_shm_pool.
pub const ShmBuffer = struct {
    wl_buffer: *wl.c.wl_buffer,
    pool: *wl.c.wl_shm_pool,
    data: []align(4096) u8,
    fd: posix.fd_t,
    width: u32,
    height: u32,
    stride: u32,

    pub const bpp = 4; // ARGB8888 / XRGB8888

    /// Create a new SHM buffer suitable for screen capture or surface rendering.
    pub fn create(shm: *wl.c.wl_shm, w: u32, h: u32, format: u32) !ShmBuffer {
        const stride = w * bpp;
        const size: usize = @as(usize, h) * stride;

        const fd = try createShmFile(size);
        errdefer posix.close(fd);

        const data = try posix.mmap(
            null,
            size,
            posix.PROT.READ | posix.PROT.WRITE,
            .{ .TYPE = .SHARED },
            fd,
            0,
        );
        errdefer posix.munmap(data);

        const pool = wl.c.wl_shm_create_pool(shm, fd, @intCast(size)) orelse
            return error.FailedToCreateShmPool;
        errdefer wl.c.wl_shm_pool_destroy(pool);

        const buffer = wl.c.wl_shm_pool_create_buffer(
            pool,
            0,
            @intCast(w),
            @intCast(h),
            @intCast(stride),
            format,
        ) orelse return error.FailedToCreateBuffer;

        return .{
            .wl_buffer = buffer,
            .pool = pool,
            .data = data,
            .fd = fd,
            .width = w,
            .height = h,
            .stride = stride,
        };
    }

    /// Destroy the SHM buffer and release all resources.
    pub fn destroy(self: *ShmBuffer) void {
        wl.c.wl_buffer_destroy(self.wl_buffer);
        wl.c.wl_shm_pool_destroy(self.pool);
        posix.munmap(self.data);
        posix.close(self.fd);
    }
};
