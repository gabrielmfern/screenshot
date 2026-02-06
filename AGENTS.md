# AGENTS.md

## Project Overview

A native Wayland screenshot utility for Linux (CleanShot X alternative), written in Zig.
Captures the screen via Wayland protocols, shows a fullscreen overlay for region selection,
and saves/copies the result as PNG.

## Build & Run

Requires: Zig 0.15.2+, `wayland-scanner`, `wayland-client`, `wayland-cursor`, `xkbcommon`,
and `wayland-protocols` headers installed on the system.

```bash
# Build
zig build

# Build (release)
zig build -Doptimize=ReleaseFast

# Run
zig build run

# Run with args
zig build run -- --fullscreen
zig build run -- --output /tmp/shot.png
```

## Testing

Tests are defined inline in source files using `test "name" { ... }` blocks.
The root test module is `src/main.zig`, which pulls in other modules via `comptime { _ = @import("image.zig"); }`.

```bash
# Run all tests
zig build test

# Run tests for a single file directly (useful for faster iteration)
zig test src/image.zig --dep wayland -Mroot=src/image.zig

# In practice, `zig build test` is the reliable way since the build system
# handles protocol generation and stb_image linking.
```

There is no separate linter — `zig build` itself catches all compile errors and warnings.

## Architecture

```
src/
  main.zig      — Entry point, CLI parsing, Wayland global binding, output actions
  capture.zig   — Screen capture (ext-image-copy-capture-v1, wlr-screencopy-unstable-v1)
  overlay.zig   — Fullscreen layer-shell overlay for interactive region selection
  image.zig     — Image struct, crop, BGRA↔RGBA conversion, PNG save (via stb_image_write)
  shm.zig       — Wayland SHM buffer allocation (memfd_create + mmap)
  wayland.zig   — Unified @cImport for all Wayland/protocol C headers
```

**Flow:** main connects to Wayland → capture grabs the screen → overlay shows selection UI → image crops/saves.

**Two capture backends** in `capture.zig`:
- `ext-image-copy-capture-v1` (preferred, modern)
- `wlr-screencopy-unstable-v1` (fallback)

**Protocol bindings** are auto-generated at build time by `wayland-scanner`. System protocols
come from `/usr/share/wayland-protocols/`, wlr protocols from `docs/*.xml`.

## Code Style

### Language & Formatting

- **Zig 0.15.2** — use current idioms, no legacy patterns.
- Use `zig fmt` style (the default). No custom formatting rules.
- Maximum line length is not strictly enforced, but keep lines reasonable (~120 chars).

### Imports

- `const std = @import("std");` first, then `const posix = std.posix;` if needed.
- Local imports next: `const wl = @import("wayland.zig");`, then specific types from other modules.
- Import types directly: `const Image = @import("image.zig").Image;`
- All Wayland C bindings go through `wl.c.*` (the single `wayland.zig` cImport). Never add
  separate `@cImport` blocks elsewhere.

### Naming Conventions

- **Types:** PascalCase (`CaptureState`, `ShmBuffer`, `Overlay`, `Rect`).
- **Functions:** camelCase (`initExtCapture`, `savePng`, `renderToBuffer`).
- **Variables/fields:** snake_case (`buffer_width`, `frame_ready`, `wl_display`).
- **Constants:** UPPER_SNAKE_CASE for key codes and protocol constants (`KEY_ESC`, `BTN_LEFT`),
  camelCase for binding info locals.
- **Wayland globals:** prefixed with their protocol (`wl_compositor`, `wl_shm`, `layer_shell`,
  `capture_manager`).

### Types & Structs

- Use Zig structs with default field values as the primary pattern (see `CaptureState`, `Overlay`).
- Structs act as pseudo-objects — methods take `self: *StructName` as first param.
- Use `?*T` (optional pointer) for nullable Wayland objects, not sentinel values.
- Wayland listener structs are file-level `const` values, not inside the struct.
- Callback functions use `callconv(.c)` for Wayland listener compatibility.

### Error Handling

- Use Zig error unions (`!void`, `!ShmBuffer`) for all fallible operations.
- Use `errdefer` for cleanup on error paths (e.g. `errdefer posix.close(fd);`).
- Name errors descriptively: `error.FailedToCreateFrame`, `error.InvalidBufferConstraints`.
- For non-critical failures (cleanup, optional features), use `catch {}` or `catch 0`.
- Wayland roundtrip failures should return `error.WaylandRoundtripFailed`.

### Memory Management

- Use `std.mem.Allocator` passed explicitly — no global allocators.
- `main.zig` uses `GeneralPurposeAllocator` with leak detection in debug builds.
- SHM buffers use `memfd_create` + `posix.mmap`, not the Zig allocator.
- Images that wrap external data (SHM buffers) use `allocator = undefined` to signal
  they don't own their backing memory. Only `crop()` produces allocator-owned images.
- Always `defer`/`errdefer` for resource cleanup.

### Wayland Patterns

- **Synchronous init:** `wl_display_roundtrip()` in a `while (!done)` loop for setup phases
  (registry binding, buffer constraints, surface configure).
- **Async event loop:** `wl_display_dispatch()` for the interactive overlay phase.
- **Double buffering:** Overlay uses two SHM buffers (`buffers: [2]?ShmBuffer`) and alternates
  via `current_buf +%= 1`.
- **Frame callbacks:** Use `wl_surface_frame()` + listener to throttle redraws to compositor
  vsync. Only request a new frame callback when actively selecting.
- Listener callbacks receive `?*anyopaque` data pointer — cast with
  `@ptrCast(@alignCast(data))`.

### Pixel Formats

- Wayland SHM buffers are **BGRA8888** (or XRGB8888). This is the native format throughout.
- PNG requires **RGBA**. Conversion happens in-place in `image.zig:bgraToRgba()` only at
  save time.
- The overlay alpha channel is set to `0xFF` explicitly when copying pixels (the source
  may be XRGB with alpha=0).

### Tests

- Tests live in the same file as the code they test, at the bottom.
- Use `std.testing.allocator` (tracks leaks) in tests, never `std.heap.page_allocator`.
- Clean up temp files in tests: `std.fs.deleteFileAbsolute(path) catch {};`
- Root test file (`main.zig`) must pull in other modules' tests with
  `comptime { _ = @import("image.zig"); }`.

### Adding New Files

- Add a new `src/foo.zig` and import it from the module that uses it.
- If it has tests, add `comptime { _ = @import("foo.zig"); }` in `main.zig` test block.
- No changes to `build.zig` needed for pure Zig source files — only for new C dependencies
  or protocol XML files.
