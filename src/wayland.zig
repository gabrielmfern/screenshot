/// Unified C import for all Wayland protocol headers and related libraries.
pub const c = @cImport({
    @cInclude("wayland-client.h");
    @cInclude("wayland-cursor.h");

    @cInclude("xkbcommon/xkbcommon.h");

    @cInclude("xdg-shell-client-protocol.h");
    @cInclude("fractional-scale-v1-client-protocol.h");
    @cInclude("viewporter-client-protocol.h");
    @cInclude("image-copy-capture-client-protocol.h");
    @cInclude("image-capture-source-client-protocol.h");
    @cInclude("foreign-toplevel-list-client-protocol.h");

    @cInclude("wlr-layer-shell-unstable-v1-client-protocol.h");
    @cInclude("wlr-screencopy-unstable-v1-client-protocol.h");
});
