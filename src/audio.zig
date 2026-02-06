const std = @import("std");
const posix = std.posix;

const pa = @cImport({
    @cInclude("pulse/simple.h");
    @cInclude("pulse/error.h");
});

/// Sound effects for screenshot/recording events.
/// Uses PulseAudio simple API (routes through PipeWire natively).
pub const Audio = struct {
    const SAMPLE_RATE = 44100;

    pub const Sound = enum {
        shutter,
        record_start,
        record_stop,
    };

    /// Play a sound effect. Non-blocking: forks a child process to handle playback
    /// so the main thread returns immediately.
    pub fn play(sound: Sound) void {
        const pid = posix.fork() catch return;
        if (pid != 0) {
            // Parent: return immediately. We don't waitpid — let init reap the child.
            return;
        }

        // Child: play the sound and exit
        playSync(sound);
        posix.exit(0);
    }

    fn playSync(sound: Sound) void {
        const samples: []const i16 = switch (sound) {
            .shutter => &shutter_samples,
            .record_start => &record_start_samples,
            .record_stop => &record_stop_samples,
        };

        const ss = pa.pa_sample_spec{
            .format = pa.PA_SAMPLE_S16LE,
            .rate = SAMPLE_RATE,
            .channels = 1,
        };

        var err: c_int = 0;
        const s = pa.pa_simple_new(
            null, // default server
            "screenshot", // app name
            pa.PA_STREAM_PLAYBACK,
            null, // default device
            "sound-effect", // stream name
            &ss,
            null, // default channel map
            null, // default buffer attributes
            &err,
        ) orelse return;

        const bytes: [*]const u8 = @ptrCast(samples.ptr);
        const len = samples.len * @sizeOf(i16);
        _ = pa.pa_simple_write(s, bytes, len, &err);
        _ = pa.pa_simple_drain(s, &err);
        pa.pa_simple_free(s);
    }

    // ── Procedurally generated sound effects ────────────────────────────────
    //
    // All samples are generated at comptime — zero runtime cost, no external files.
    // Mono, 16-bit signed, 44100 Hz.

    /// Shutter click: two-tap "ka-chick" (~100ms total).
    /// First tap (shutter open) then a brief gap, then second tap (shutter close).
    /// Each tap is a damped sine — like tapping a hard surface.
    const shutter_samples = blk: {
        @setEvalBranchQuota(500_000);
        const duration_ms = 100;
        const num_samples = SAMPLE_RATE * duration_ms / 1000;
        var samples: [num_samples]i16 = undefined;

        // Tap timing (in samples)
        const tap1_start = 0;
        const tap1_len = SAMPLE_RATE * 12 / 1000; // 12ms
        const gap = SAMPLE_RATE * 30 / 1000; // 30ms silence
        const tap2_start = tap1_len + gap;
        const tap2_len = SAMPLE_RATE * 15 / 1000; // 15ms

        // Tap frequencies — slightly different to give the two-part character
        const freq1: f64 = 1200.0; // first click, slightly lower
        const freq2: f64 = 1500.0; // second click, slightly higher/brighter

        for (0..num_samples) |i| {
            var sample: f64 = 0.0;

            // First tap
            if (i >= tap1_start and i < tap1_start + tap1_len) {
                const ti = i - tap1_start;
                const t: f64 = @as(f64, @floatFromInt(ti)) / SAMPLE_RATE;
                // Sharp exponential decay
                const env = @exp(-t * 350.0);
                const sine = @sin(2.0 * std.math.pi * freq1 * t);
                sample = sine * env * 0.25;
            }

            // Second tap
            if (i >= tap2_start and i < tap2_start + tap2_len) {
                const ti = i - tap2_start;
                const t: f64 = @as(f64, @floatFromInt(ti)) / SAMPLE_RATE;
                const env = @exp(-t * 300.0);
                const sine = @sin(2.0 * std.math.pi * freq2 * t);
                sample = sine * env * 0.20;
            }

            samples[i] = floatToI16(sample);
        }
        break :blk samples;
    };

    /// Record start: ascending two-tone chime (C5 -> E5, ~350ms).
    /// Bright, clear notification that recording has begun.
    const record_start_samples = blk: {
        @setEvalBranchQuota(1_000_000);
        const duration_ms = 350;
        const num_samples = SAMPLE_RATE * duration_ms / 1000;
        var samples: [num_samples]i16 = undefined;

        const freq1 = 523.25; // C5
        const freq2 = 659.25; // E5
        const switch_point = num_samples * 45 / 100; // first tone slightly shorter

        for (0..num_samples) |i| {
            const t: f64 = @as(f64, @floatFromInt(i)) / SAMPLE_RATE;
            const local_t: f64 = if (i < switch_point)
                @as(f64, @floatFromInt(i)) / @as(f64, @floatFromInt(switch_point))
            else
                @as(f64, @floatFromInt(i - switch_point)) / @as(f64, @floatFromInt(num_samples - switch_point));

            const freq = if (i < switch_point) freq1 else freq2;

            // Sine wave with smooth envelope (attack + decay per tone)
            const envelope = @sin(local_t * std.math.pi);

            // Gentle overall fade out
            const global_env = 1.0 - (t / (@as(f64, duration_ms) / 1000.0)) * 0.25;

            const sine = @sin(2.0 * std.math.pi * freq * t);
            // Add a soft harmonic for richness
            const harmonic = @sin(2.0 * std.math.pi * freq * 2.0 * t) * 0.12;

            const sample = (sine + harmonic) * envelope * global_env * 0.15;
            samples[i] = floatToI16(sample);
        }
        break :blk samples;
    };

    /// Record stop: descending two-tone (E5 -> C5, ~350ms).
    /// Mirror of start sound, signals completion.
    const record_stop_samples = blk: {
        @setEvalBranchQuota(1_000_000);
        const duration_ms = 350;
        const num_samples = SAMPLE_RATE * duration_ms / 1000;
        var samples: [num_samples]i16 = undefined;

        const freq1 = 659.25; // E5
        const freq2 = 523.25; // C5
        const switch_point = num_samples * 45 / 100;

        for (0..num_samples) |i| {
            const t: f64 = @as(f64, @floatFromInt(i)) / SAMPLE_RATE;
            const local_t: f64 = if (i < switch_point)
                @as(f64, @floatFromInt(i)) / @as(f64, @floatFromInt(switch_point))
            else
                @as(f64, @floatFromInt(i - switch_point)) / @as(f64, @floatFromInt(num_samples - switch_point));

            const freq = if (i < switch_point) freq1 else freq2;

            const envelope = @sin(local_t * std.math.pi);
            const global_env = 1.0 - (t / (@as(f64, duration_ms) / 1000.0)) * 0.25;

            const sine = @sin(2.0 * std.math.pi * freq * t);
            const harmonic = @sin(2.0 * std.math.pi * freq * 2.0 * t) * 0.12;

            const sample = (sine + harmonic) * envelope * global_env * 0.15;
            samples[i] = floatToI16(sample);
        }
        break :blk samples;
    };

    fn floatToI16(sample: f64) i16 {
        const clamped = @max(-1.0, @min(1.0, sample));
        const scaled = clamped * 32767.0;
        return @intFromFloat(scaled);
    }
};
