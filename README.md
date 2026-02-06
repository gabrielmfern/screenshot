# Screenshot

A CleanShot X alternative for Linux, built natively for Wayland.

CleanShot X is widely regarded as the best screen capture tool on macOS. Linux deserves something just as good. This project aims to bring that same level of polish, power, and workflow efficiency to the Linux desktop -- built from the ground up for Wayland with Zig.

## Planned Features

### Screenshots

- **Capture Area** -- select a specific region of the screen
- **Capture Window** -- grab a single window (with or without background/shadow)
- **Capture Fullscreen** -- screenshot the entire display
- **Scrolling Capture** -- capture content that extends beyond the visible screen
- **Self-Timer** -- delay capture by a configurable number of seconds
- **Freeze Screen** -- freeze the display to capture transient or moving UI elements
- **Crosshair Mode** -- show a crosshair overlay for precise alignment
- **Magnifier** -- pixel-level zoom while selecting a capture region
- **All-In-One Mode** -- a single shortcut to access all capture modes, lock aspect ratio, specify dimensions, and recall the last selection
- **Custom Wallpaper** -- set a specific image or plain color as the background for window captures
- **Hide Desktop Icons** -- remove desktop clutter before capturing

### Annotation / Editing

- **Crop** -- with aspect ratio lock and edge snapping
- **Arrow** -- multiple styles including curved
- **Rectangle / Filled Rectangle**
- **Ellipse**
- **Line**
- **Pixelate** -- with randomization for better security
- **Blur** -- secure and smooth options
- **Spotlight** -- dim everything except the emphasized area
- **Counter** -- numbered step marks for tutorials
- **Pencil** -- freehand drawing with auto-smoothing
- **Highlighter** -- book-style text highlighting
- **Text Tool** -- multiple predefined styles
- **Combine Images** -- drag and drop multiple screenshots into one canvas
- **Editable Project Format** -- save annotated screenshots for later re-editing

### Background Tool

- Add beautiful backgrounds behind screenshots (bundled presets + custom images)
- Adjust padding, alignment, and aspect ratio
- Auto-balance to perfectly center content
- Ideal for social media and blog posts

### Screen Recording

- **Record as MP4 (H.264) or GIF**
- **Capture modes**: window, fullscreen, or custom area with specific dimensions
- **Record Microphone audio**
- **Record System Audio** (PipeWire/PulseAudio)
- **Webcam Overlay** -- overlay camera feed with adjustable position, size, and shape
- **Highlight Mouse Clicks** -- customizable color, size, style, and animation
- **Capture Keystrokes** -- display pressed keys on screen
- **Show/Hide Cursor**
- **Auto Do-Not-Disturb** -- suppress notifications while recording
- **Hide Desktop Icons** during recording
- **Display Recording Timer** in the system tray / bar
- **Control Quality, FPS, and Resolution**

### Video Editor (built-in)

- Trim recordings
- Change quality and resolution
- Convert stereo audio to mono
- Adjust volume or mute audio
- Playback before sharing

### Text Recognition (OCR)

- Select any area containing text and copy it to the clipboard
- Works on images, videos, scanned documents
- Fully on-device, privacy-friendly

### Quick Access Overlay

- Small pop-up after every capture for instant actions
- Copy, save, annotate, or drag-and-drop to other apps
- Restore recently closed overlays
- Adjustable position, size, and auto-close behavior
- Multi-monitor support

### Floating (Pinned) Screenshots

- Pin any screenshot to float above all windows
- Adjust size and opacity
- Position precisely with keyboard
- Pass-through mode to interact with windows underneath

### Capture History

- Access and restore recent captures
- Filter by capture type
- Configurable retention period

### General

- Highly customizable settings and keyboard shortcuts
- Native Wayland application -- no X11 dependency
- Built with Zig for performance and minimal resource usage
- Light and dark mode support

## Building

Requires Zig 0.15.2+ and Wayland development libraries.

```sh
zig build
```

## License

TBD
