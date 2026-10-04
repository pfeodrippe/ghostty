const std = @import("std");

pub const Targets = packed struct {
    x11: bool = false,
    wayland: bool = false,
};

/// Returns the targets that GTK4 was compiled with.
pub fn targets(b: *std.Build) Targets {
    // Run pkg-config. We allow it to fail so that zig build --help
    // works without all dependencies. The build will fail later when
    // GTK isn't found anyways.
    const output = switch (b.runFallible(
        &.{ "pkg-config", "--variable=targets", "gtk4" },
        .{ .stderr_behavior = .ignore },
    )) {
        .success => |stdout| stdout,
        else => return .{},
    };

    const x11 = std.mem.indexOf(u8, output, "x11") != null;
    const wayland = std.mem.indexOf(u8, output, "wayland") != null;

    return .{
        .x11 = x11,
        .wayland = wayland,
    };
}
