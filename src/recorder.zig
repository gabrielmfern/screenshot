const std = @import("std");
const posix = std.posix;
const wl = @import("wayland.zig");
const Rect = @import("image.zig").Rect;
const ShmBuffer = @import("shm.zig").ShmBuffer;

const av = @cImport({
    @cInclude("libavcodec/avcodec.h");
    @cInclude("libavformat/avformat.h");
    @cInclude("libavutil/avutil.h");
    @cInclude("libavutil/opt.h");
    @cInclude("libavutil/imgutils.h");
    @cInclude("libswscale/swscale.h");
});

/// Screen recorder using native Wayland capture protocols + libav for encoding.
///
/// Captures frames via ext-image-copy-capture-v1 (preferred) or wlr-screencopy-unstable-v1,
/// converts BGRA pixels to YUV420P via libswscale and encodes to H.264 MP4 via libavcodec.
pub const Recorder = struct {
    // Wayland globals (borrowed references)
    display: *wl.c.wl_display,
    shm: *wl.c.wl_shm,
    output: *wl.c.wl_output,

    // Capture backend
    backend: CaptureBackend,
    capture_manager: ?*wl.c.ext_image_copy_capture_manager_v1,
    source_manager: ?*wl.c.ext_output_image_capture_source_manager_v1,
    screencopy_manager: ?*wl.c.zwlr_screencopy_manager_v1,

    // ext-image-copy-capture session (kept alive for continuous capture)
    ext_session: ?*wl.c.ext_image_copy_capture_session_v1 = null,
    ext_source: ?*wl.c.ext_image_capture_source_v1 = null,

    // Capture buffer (single buffer, reused per frame)
    capture_buffer: ?ShmBuffer = null,
    buffer_width: u32 = 0,
    buffer_height: u32 = 0,
    buffer_stride: u32 = 0,
    shm_format: u32 = 0,
    buffer_info_done: bool = false,

    // Frame state
    frame_ready: bool = false,
    frame_failed: bool = false,

    // Region to crop
    region: Rect,

    // Encoder state
    enc_ctx: ?*av.AVCodecContext = null,
    fmt_ctx: ?*av.AVFormatContext = null,
    stream: ?*av.AVStream = null,
    sws_ctx: ?*av.SwsContext = null,
    yuv_frame: ?*av.AVFrame = null,
    pkt: ?*av.AVPacket = null,
    frame_count: i64 = 0,
    // Padded dimensions (must be even for H.264 yuv420p)
    enc_width: u32 = 0,
    enc_height: u32 = 0,

    // State
    output_path: [:0]const u8,
    allocator: std.mem.Allocator,
    paused: bool = false,
    stopped: bool = false,

    // Crop buffer (for extracting the selected region from the full-screen capture)
    crop_buffer: ?[]u8 = null,

    const CaptureBackend = enum {
        ext_image_copy_capture,
        wlr_screencopy,
    };

    const FRAMERATE = 60;

    /// Start recording the given screen region to a temporary file.
    pub fn start(
        allocator: std.mem.Allocator,
        io: std.Io,
        region: Rect,
        display: *wl.c.wl_display,
        shm: *wl.c.wl_shm,
        output: *wl.c.wl_output,
        capture_manager: ?*wl.c.ext_image_copy_capture_manager_v1,
        source_manager: ?*wl.c.ext_output_image_capture_source_manager_v1,
        screencopy_manager: ?*wl.c.zwlr_screencopy_manager_v1,
    ) !Recorder {
        const output_path: [:0]const u8 = "/tmp/screenshot-recording.mp4";

        // Remove any previous recording
        std.Io.Dir.deleteFileAbsolute(io, output_path) catch {};

        const has_ext = capture_manager != null and source_manager != null;
        const backend: CaptureBackend = if (has_ext) .ext_image_copy_capture else .wlr_screencopy;

        var self = Recorder{
            .display = display,
            .shm = shm,
            .output = output,
            .backend = backend,
            .capture_manager = capture_manager,
            .source_manager = source_manager,
            .screencopy_manager = screencopy_manager,
            .region = region,
            .output_path = output_path,
            .allocator = allocator,
        };

        // Set up the capture session and learn buffer constraints
        try self.initCapture();

        // Allocate crop buffer for the selected region
        const crop_stride = region.width * ShmBuffer.bpp;
        self.crop_buffer = try allocator.alloc(u8, @as(usize, region.height) * crop_stride);

        // Initialize encoder
        try self.initEncoder();

        return self;
    }

    // ── Wayland capture setup ───────────────────────────────────────────────

    fn initCapture(self: *Recorder) !void {
        switch (self.backend) {
            .ext_image_copy_capture => try self.initExtCapture(),
            .wlr_screencopy => try self.initScreencopySession(),
        }
    }

    fn initExtCapture(self: *Recorder) !void {
        const source = wl.c.ext_output_image_capture_source_manager_v1_create_source(
            self.source_manager.?,
            self.output,
        ) orelse return error.FailedToCreateCaptureSource;
        self.ext_source = @ptrCast(source);

        self.ext_session = wl.c.ext_image_copy_capture_manager_v1_create_session(
            self.capture_manager.?,
            @ptrCast(source),
            1, // paint cursors
        ) orelse return error.FailedToCreateCaptureSession;

        _ = wl.c.ext_image_copy_capture_session_v1_add_listener(
            self.ext_session.?,
            &ext_session_listener,
            self,
        );

        // Wait for buffer constraints
        while (!self.buffer_info_done) {
            if (wl.c.wl_display_roundtrip(self.display) == -1)
                return error.WaylandRoundtripFailed;
        }

        if (self.buffer_width == 0 or self.buffer_height == 0)
            return error.InvalidBufferConstraints;

        self.capture_buffer = try ShmBuffer.create(self.shm, self.buffer_width, self.buffer_height, self.shm_format);
        self.buffer_stride = self.capture_buffer.?.stride;
    }

    fn initScreencopySession(self: *Recorder) !void {
        // Capture one frame to get buffer constraints, then destroy it.
        const frame = wl.c.zwlr_screencopy_manager_v1_capture_output(
            self.screencopy_manager.?,
            1, // overlay cursor
            self.output,
        ) orelse return error.FailedToCreateFrame;

        _ = wl.c.zwlr_screencopy_frame_v1_add_listener(frame, &screencopy_frame_listener, self);

        while (!self.buffer_info_done and !self.frame_failed) {
            if (wl.c.wl_display_roundtrip(self.display) == -1)
                return error.WaylandRoundtripFailed;
        }

        wl.c.zwlr_screencopy_frame_v1_destroy(frame);

        if (self.frame_failed) return error.CaptureFailed;
        if (self.buffer_width == 0 or self.buffer_height == 0)
            return error.InvalidBufferConstraints;

        self.capture_buffer = try ShmBuffer.create(self.shm, self.buffer_width, self.buffer_height, self.shm_format);
        self.buffer_stride = self.capture_buffer.?.stride;
    }

    // ── libav encoder setup ─────────────────────────────────────────────────

    fn initEncoder(self: *Recorder) !void {
        const region = self.region;

        // H.264 with yuv420p requires even dimensions
        self.enc_width = (region.width + 1) & ~@as(u32, 1);
        self.enc_height = (region.height + 1) & ~@as(u32, 1);

        const w: c_int = @intCast(self.enc_width);
        const h: c_int = @intCast(self.enc_height);

        // ── Output format context ───────────────────────────────────────
        var fmt_ctx: ?*av.AVFormatContext = null;
        var ret = av.avformat_alloc_output_context2(&fmt_ctx, null, "mp4", self.output_path.ptr);
        if (ret < 0 or fmt_ctx == null) return error.EncoderInitFailed;
        self.fmt_ctx = fmt_ctx;

        // ── Find H.264 encoder ──────────────────────────────────────────
        const codec = av.avcodec_find_encoder(av.AV_CODEC_ID_H264) orelse
            return error.EncoderNotFound;

        // ── Create stream ───────────────────────────────────────────────
        const stream = av.avformat_new_stream(fmt_ctx, codec) orelse
            return error.EncoderInitFailed;
        stream.*.id = @intCast(fmt_ctx.?.*.nb_streams - 1);
        self.stream = stream;

        // ── Codec context ───────────────────────────────────────────────
        const enc_ctx = av.avcodec_alloc_context3(codec) orelse
            return error.EncoderInitFailed;
        self.enc_ctx = enc_ctx;

        enc_ctx.*.width = w;
        enc_ctx.*.height = h;
        enc_ctx.*.time_base = .{ .num = 1, .den = FRAMERATE };
        enc_ctx.*.framerate = .{ .num = FRAMERATE, .den = 1 };
        enc_ctx.*.pix_fmt = av.AV_PIX_FMT_YUV420P;
        enc_ctx.*.gop_size = 30;
        enc_ctx.*.max_b_frames = 0;

        // Ultrafast preset for low latency
        _ = av.av_opt_set(enc_ctx.*.priv_data, "preset", "ultrafast", 0);
        _ = av.av_opt_set(enc_ctx.*.priv_data, "crf", "23", 0);

        // Global header if container needs it
        if (fmt_ctx.?.*.oformat.*.flags & av.AVFMT_GLOBALHEADER != 0) {
            enc_ctx.*.flags |= av.AV_CODEC_FLAG_GLOBAL_HEADER;
        }

        ret = av.avcodec_open2(enc_ctx, codec, null);
        if (ret < 0) return error.EncoderInitFailed;

        // Copy codec params to stream
        ret = av.avcodec_parameters_from_context(stream.*.codecpar, enc_ctx);
        if (ret < 0) return error.EncoderInitFailed;

        // ── Open output file ────────────────────────────────────────────
        ret = av.avio_open(&fmt_ctx.?.*.pb, self.output_path.ptr, av.AVIO_FLAG_WRITE);
        if (ret < 0) return error.EncoderInitFailed;

        // ── Write header ────────────────────────────────────────────────
        var opts: ?*av.AVDictionary = null;
        _ = av.av_dict_set(&opts, "movflags", "faststart", 0);
        ret = av.avformat_write_header(fmt_ctx, &opts);
        if (opts != null) av.av_dict_free(&opts);
        if (ret < 0) return error.EncoderInitFailed;

        // ── Allocate YUV frame ──────────────────────────────────────────
        const yuv_frame = av.av_frame_alloc() orelse return error.EncoderInitFailed;
        yuv_frame.*.format = av.AV_PIX_FMT_YUV420P;
        yuv_frame.*.width = w;
        yuv_frame.*.height = h;
        ret = av.av_frame_get_buffer(yuv_frame, 0);
        if (ret < 0) return error.EncoderInitFailed;
        self.yuv_frame = yuv_frame;

        // ── Allocate packet ─────────────────────────────────────────────
        self.pkt = av.av_packet_alloc() orelse return error.EncoderInitFailed;

        // ── swscale context: BGRA → YUV420P ─────────────────────────────
        self.sws_ctx = av.sws_getContext(
            @intCast(region.width),
            @intCast(region.height),
            av.AV_PIX_FMT_BGRA,
            w,
            h,
            av.AV_PIX_FMT_YUV420P,
            av.SWS_FAST_BILINEAR,
            null,
            null,
            null,
        ) orelse return error.EncoderInitFailed;
    }

    // ── Frame capture + encode ──────────────────────────────────────────────

    /// Capture a single frame and encode it.
    /// Returns false if recording should stop (encoder error, etc.).
    pub fn captureFrame(self: *Recorder) bool {
        if (self.stopped) return false;
        if (self.paused) return true;

        // Capture a frame from Wayland
        const captured = switch (self.backend) {
            .ext_image_copy_capture => self.captureExtFrame(),
            .wlr_screencopy => self.captureScreencopyFrame(),
        };
        if (!captured) return true; // skip frame on failure, don't stop

        // Extract the selected region from the full-screen capture
        const buf = &self.capture_buffer.?;
        const crop_buf = self.crop_buffer orelse return false;
        const region = self.region;
        const src_stride = buf.stride;
        const crop_stride = region.width * ShmBuffer.bpp;

        for (0..region.height) |row| {
            const src_offset = (region.y + @as(u32, @intCast(row))) * src_stride + region.x * ShmBuffer.bpp;
            const dst_offset = row * crop_stride;
            if (src_offset + crop_stride <= buf.data.len and dst_offset + crop_stride <= crop_buf.len) {
                @memcpy(
                    crop_buf[dst_offset..][0..crop_stride],
                    buf.data[src_offset..][0..crop_stride],
                );
            }
        }

        // Convert BGRA → YUV420P and encode
        return self.encodeFrame(crop_buf.ptr, @intCast(crop_stride));
    }

    fn encodeFrame(self: *Recorder, data: [*]const u8, linesize: c_int) bool {
        const sws = self.sws_ctx orelse return false;
        const yuv_frame = self.yuv_frame orelse return false;
        const enc_ctx = self.enc_ctx orelse return false;
        const pkt = self.pkt orelse return false;

        // Make frame writable
        if (av.av_frame_make_writable(yuv_frame) < 0) return false;

        // Convert BGRA → YUV420P
        const src_slices = [_][*c]const u8{ data, null, null, null, null, null, null, null };
        const src_strides = [_]c_int{ linesize, 0, 0, 0, 0, 0, 0, 0 };
        _ = av.sws_scale(
            sws,
            &src_slices,
            &src_strides,
            0,
            @intCast(self.region.height),
            &yuv_frame.*.data,
            &yuv_frame.*.linesize,
        );

        yuv_frame.*.pts = self.frame_count;
        self.frame_count += 1;

        // Send frame to encoder
        var ret = av.avcodec_send_frame(enc_ctx, yuv_frame);
        if (ret < 0) return false;

        // Receive and write all available packets
        while (true) {
            ret = av.avcodec_receive_packet(enc_ctx, pkt);
            if (ret == av.AVERROR(av.EAGAIN) or ret == av.AVERROR_EOF) break;
            if (ret < 0) return false;

            av.av_packet_rescale_ts(pkt, enc_ctx.*.time_base, self.stream.?.*.time_base);
            pkt.*.stream_index = self.stream.?.*.index;

            ret = av.av_interleaved_write_frame(self.fmt_ctx, pkt);
            av.av_packet_unref(pkt);
            if (ret < 0) return false;
        }

        return true;
    }

    fn captureExtFrame(self: *Recorder) bool {
        const session = self.ext_session orelse return false;
        const buf = &(self.capture_buffer orelse return false);

        self.frame_ready = false;
        self.frame_failed = false;

        const frame = wl.c.ext_image_copy_capture_session_v1_create_frame(
            session,
        ) orelse return false;

        _ = wl.c.ext_image_copy_capture_frame_v1_add_listener(
            frame,
            &ext_frame_listener,
            self,
        );

        wl.c.ext_image_copy_capture_frame_v1_attach_buffer(frame, buf.wl_buffer);
        wl.c.ext_image_copy_capture_frame_v1_damage_buffer(
            frame,
            0,
            0,
            @intCast(self.buffer_width),
            @intCast(self.buffer_height),
        );
        wl.c.ext_image_copy_capture_frame_v1_capture(frame);

        while (!self.frame_ready and !self.frame_failed) {
            if (wl.c.wl_display_roundtrip(self.display) == -1) {
                wl.c.ext_image_copy_capture_frame_v1_destroy(frame);
                return false;
            }
        }

        wl.c.ext_image_copy_capture_frame_v1_destroy(frame);
        return self.frame_ready;
    }

    fn captureScreencopyFrame(self: *Recorder) bool {
        const buf = &(self.capture_buffer orelse return false);

        self.frame_ready = false;
        self.frame_failed = false;

        const frame = wl.c.zwlr_screencopy_manager_v1_capture_output(
            self.screencopy_manager.?,
            1, // overlay cursor
            self.output,
        ) orelse return false;

        _ = wl.c.zwlr_screencopy_frame_v1_add_listener(frame, &screencopy_frame_listener_capture, self);

        // Wait for buffer info (protocol requires it each time)
        self.buffer_info_done = false;
        while (!self.buffer_info_done and !self.frame_failed) {
            if (wl.c.wl_display_roundtrip(self.display) == -1) {
                wl.c.zwlr_screencopy_frame_v1_destroy(frame);
                return false;
            }
        }

        if (self.frame_failed) {
            wl.c.zwlr_screencopy_frame_v1_destroy(frame);
            return false;
        }

        wl.c.zwlr_screencopy_frame_v1_copy(frame, buf.wl_buffer);

        while (!self.frame_ready and !self.frame_failed) {
            if (wl.c.wl_display_roundtrip(self.display) == -1) {
                wl.c.zwlr_screencopy_frame_v1_destroy(frame);
                return false;
            }
        }

        wl.c.zwlr_screencopy_frame_v1_destroy(frame);
        return self.frame_ready;
    }

    // ── Public controls ─────────────────────────────────────────────────────

    /// Pause or resume recording.
    pub fn togglePause(self: *Recorder) void {
        self.paused = !self.paused;
    }

    /// Stop recording: flush encoder, write trailer, close output.
    pub fn stop(self: *Recorder) void {
        if (self.stopped) return;
        self.stopped = true;

        // Flush encoder (send NULL frame)
        if (self.enc_ctx) |enc_ctx| {
            _ = av.avcodec_send_frame(enc_ctx, null);

            if (self.pkt) |pkt| {
                while (true) {
                    const ret = av.avcodec_receive_packet(enc_ctx, pkt);
                    if (ret == av.AVERROR(av.EAGAIN) or ret == av.AVERROR_EOF) break;
                    if (ret < 0) break;

                    av.av_packet_rescale_ts(pkt, enc_ctx.*.time_base, self.stream.?.*.time_base);
                    pkt.*.stream_index = self.stream.?.*.index;

                    _ = av.av_interleaved_write_frame(self.fmt_ctx, pkt);
                    av.av_packet_unref(pkt);
                }
            }
        }

        // Write trailer
        if (self.fmt_ctx) |fmt_ctx| {
            _ = av.av_write_trailer(fmt_ctx);
        }
    }

    /// Returns the path to the recorded file.
    pub fn getOutputPath(self: *const Recorder) [:0]const u8 {
        return self.output_path;
    }

    /// Clean up all resources.
    pub fn deinit(self: *Recorder) void {
        if (!self.stopped) self.stop();

        // Free encoder resources
        if (self.pkt) |pkt| av.av_packet_free(@constCast(&@as(?*av.AVPacket, pkt)));
        if (self.yuv_frame) |f| av.av_frame_free(@constCast(&@as(?*av.AVFrame, f)));
        if (self.sws_ctx) |sws| av.sws_freeContext(sws);
        if (self.enc_ctx) |ctx| av.avcodec_free_context(@constCast(&@as(?*av.AVCodecContext, ctx)));
        if (self.fmt_ctx) |fmt_ctx| {
            if (fmt_ctx.*.pb != null) {
                _ = av.avio_closep(&fmt_ctx.*.pb);
            }
            av.avformat_free_context(fmt_ctx);
        }

        // Destroy Wayland capture resources
        switch (self.backend) {
            .ext_image_copy_capture => {
                if (self.ext_session) |s| wl.c.ext_image_copy_capture_session_v1_destroy(s);
                if (self.ext_source) |s| wl.c.ext_image_capture_source_v1_destroy(s);
            },
            .wlr_screencopy => {},
        }

        if (self.capture_buffer) |*b| b.destroy();
        if (self.crop_buffer) |buf| self.allocator.free(buf);
    }

    // ── ext-image-copy-capture session listener ─────────────────────────────

    fn extSessionBufferSize(data: ?*anyopaque, _: ?*wl.c.ext_image_copy_capture_session_v1, w: u32, h: u32) callconv(.c) void {
        const self: *Recorder = @ptrCast(@alignCast(data));
        self.buffer_width = w;
        self.buffer_height = h;
    }

    fn extSessionShmFormat(data: ?*anyopaque, _: ?*wl.c.ext_image_copy_capture_session_v1, format: u32) callconv(.c) void {
        const self: *Recorder = @ptrCast(@alignCast(data));
        if (format == wl.c.WL_SHM_FORMAT_ARGB8888 or format == wl.c.WL_SHM_FORMAT_XRGB8888) {
            self.shm_format = format;
        }
    }

    fn extSessionDmabufDevice(_: ?*anyopaque, _: ?*wl.c.ext_image_copy_capture_session_v1, _: [*c]wl.c.wl_array) callconv(.c) void {}
    fn extSessionDmabufFormat(_: ?*anyopaque, _: ?*wl.c.ext_image_copy_capture_session_v1, _: u32, _: [*c]wl.c.wl_array) callconv(.c) void {}

    fn extSessionDone(data: ?*anyopaque, _: ?*wl.c.ext_image_copy_capture_session_v1) callconv(.c) void {
        const self: *Recorder = @ptrCast(@alignCast(data));
        self.buffer_info_done = true;
    }

    fn extSessionStopped(_: ?*anyopaque, _: ?*wl.c.ext_image_copy_capture_session_v1) callconv(.c) void {
        std.log.warn("capture session stopped unexpectedly during recording", .{});
    }

    // ── ext-image-copy-capture frame listener ───────────────────────────────

    fn extFrameTransform(_: ?*anyopaque, _: ?*wl.c.ext_image_copy_capture_frame_v1, _: u32) callconv(.c) void {}
    fn extFrameDamage(_: ?*anyopaque, _: ?*wl.c.ext_image_copy_capture_frame_v1, _: i32, _: i32, _: i32, _: i32) callconv(.c) void {}
    fn extFramePresentationTime(_: ?*anyopaque, _: ?*wl.c.ext_image_copy_capture_frame_v1, _: u32, _: u32, _: u32) callconv(.c) void {}

    fn extFrameReady(data: ?*anyopaque, _: ?*wl.c.ext_image_copy_capture_frame_v1) callconv(.c) void {
        const self: *Recorder = @ptrCast(@alignCast(data));
        self.frame_ready = true;
    }

    fn extFrameFailed(data: ?*anyopaque, _: ?*wl.c.ext_image_copy_capture_frame_v1, reason: u32) callconv(.c) void {
        const self: *Recorder = @ptrCast(@alignCast(data));
        self.frame_failed = true;
        std.log.err("ext-image-copy-capture frame failed during recording: {}", .{reason});
    }

    // ── wlr-screencopy listeners ────────────────────────────────────────────

    fn screencopyBuffer(data: ?*anyopaque, _: ?*wl.c.zwlr_screencopy_frame_v1, format: u32, w: u32, h: u32, _: u32) callconv(.c) void {
        const self: *Recorder = @ptrCast(@alignCast(data));
        self.shm_format = format;
        self.buffer_width = w;
        self.buffer_height = h;
        self.buffer_info_done = true;
    }

    fn screencopyFlags(_: ?*anyopaque, _: ?*wl.c.zwlr_screencopy_frame_v1, _: u32) callconv(.c) void {}

    fn screencopyReady(data: ?*anyopaque, _: ?*wl.c.zwlr_screencopy_frame_v1, _: u32, _: u32, _: u32) callconv(.c) void {
        const self: *Recorder = @ptrCast(@alignCast(data));
        self.frame_ready = true;
    }

    fn screencopyFailed(data: ?*anyopaque, _: ?*wl.c.zwlr_screencopy_frame_v1) callconv(.c) void {
        const self: *Recorder = @ptrCast(@alignCast(data));
        self.frame_failed = true;
    }

    fn screencopyDamage(_: ?*anyopaque, _: ?*wl.c.zwlr_screencopy_frame_v1, _: u32, _: u32, _: u32, _: u32) callconv(.c) void {}
    fn screencopyLinuxDmabuf(_: ?*anyopaque, _: ?*wl.c.zwlr_screencopy_frame_v1, _: u32, _: u32, _: u32) callconv(.c) void {}
    fn screencopyBufferDone(data: ?*anyopaque, _: ?*wl.c.zwlr_screencopy_frame_v1) callconv(.c) void {
        const self: *Recorder = @ptrCast(@alignCast(data));
        self.buffer_info_done = true;
    }
};

const ext_session_listener: wl.c.ext_image_copy_capture_session_v1_listener = .{
    .buffer_size = Recorder.extSessionBufferSize,
    .shm_format = Recorder.extSessionShmFormat,
    .dmabuf_device = Recorder.extSessionDmabufDevice,
    .dmabuf_format = Recorder.extSessionDmabufFormat,
    .done = Recorder.extSessionDone,
    .stopped = Recorder.extSessionStopped,
};

const ext_frame_listener: wl.c.ext_image_copy_capture_frame_v1_listener = .{
    .transform = Recorder.extFrameTransform,
    .damage = Recorder.extFrameDamage,
    .presentation_time = Recorder.extFramePresentationTime,
    .ready = Recorder.extFrameReady,
    .failed = Recorder.extFrameFailed,
};

const screencopy_frame_listener: wl.c.zwlr_screencopy_frame_v1_listener = .{
    .buffer = Recorder.screencopyBuffer,
    .flags = Recorder.screencopyFlags,
    .ready = Recorder.screencopyReady,
    .failed = Recorder.screencopyFailed,
    .damage = Recorder.screencopyDamage,
    .linux_dmabuf = Recorder.screencopyLinuxDmabuf,
    .buffer_done = Recorder.screencopyBufferDone,
};

const screencopy_frame_listener_capture: wl.c.zwlr_screencopy_frame_v1_listener = .{
    .buffer = Recorder.screencopyBuffer,
    .flags = Recorder.screencopyFlags,
    .ready = Recorder.screencopyReady,
    .failed = Recorder.screencopyFailed,
    .damage = Recorder.screencopyDamage,
    .linux_dmabuf = Recorder.screencopyLinuxDmabuf,
    .buffer_done = Recorder.screencopyBufferDone,
};
