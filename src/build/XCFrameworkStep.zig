//! A zig builder step that runs "swift build" in the context of
//! a Swift project managed with SwiftPM. This is primarily meant to build
//! executables currently since that is what we build.
const XCFrameworkStep = @This();

const std = @import("std");
const Step = std.Build.Step;
const RunStep = std.Build.Step.Run;
const LazyPath = std.Build.LazyPath;

pub const Options = struct {
    /// The name of the xcframework to create.
    name: []const u8,

    /// The path to write the framework
    out_path: []const u8,

    /// The libraries to bundle
    libraries: []const Library,
};

/// A single library to bundle into the xcframework.
pub const Library = struct {
    /// Library file (dylib, a) to package.
    library: LazyPath,

    /// Path to a directory with the headers.
    headers: LazyPath,

    /// Path to a debug symbols file (.dSYM) if available.
    dsym: ?LazyPath,
};

step: *Step,

pub fn create(b: *std.Build, opts: Options) *XCFrameworkStep {
    const self = b.allocator.create(XCFrameworkStep) catch @panic("OOM");
    const output_path = resolvedOutputPath(b.allocator, b.build_root.path orelse ".", opts.out_path) catch @panic("OOM");

    // We have to delete the old xcframework first since we're writing
    // to a static path.
    const run_delete = b.addRemoveDirTree(b.path(opts.out_path));

    // Then we run xcodebuild to create the framework.
    const run_create = run: {
        const run = RunStep.create(b, b.fmt("xcframework {s}", .{opts.name}));
        run.has_side_effects = true;
        run.addArgs(&.{ "xcodebuild", "-create-xcframework" });
        for (opts.libraries) |lib| {
            run.addArg("-library");
            run.addFileArg(lib.library);
            run.addArg("-headers");
            run.addFileArg(lib.headers);
            if (lib.dsym) |dsym| {
                run.addArg("-debug-symbols");
                run.addFileArg(dsym);
            }
        }
        run.addArg("-output");
        run.addArg(output_path);
        run.expectExitCode(0);
        _ = run.captureStdOut();
        _ = run.captureStdErr();
        break :run run;
    };
    run_create.step.dependOn(&run_delete.step);

    self.* = .{
        .step = &run_create.step,
    };

    return self;
}

fn resolvedOutputPath(
    allocator: std.mem.Allocator,
    build_root: []const u8,
    out_path: []const u8,
) ![]const u8 {
    if (std.fs.path.isAbsolute(out_path)) return allocator.dupe(u8, out_path);
    return std.fs.path.join(allocator, &.{ build_root, out_path });
}

test "resolved output path roots relative output in build root" {
    const testing = std.testing;
    const result = try resolvedOutputPath(testing.allocator, "/tmp/project", "macos/GhosttyKit.xcframework");
    defer testing.allocator.free(result);
    try testing.expectEqualStrings("/tmp/project/macos/GhosttyKit.xcframework", result);
}

test "resolved output path preserves absolute output" {
    const testing = std.testing;
    const result = try resolvedOutputPath(testing.allocator, "/tmp/project", "/tmp/out/GhosttyKit.xcframework");
    defer testing.allocator.free(result);
    try testing.expectEqualStrings("/tmp/out/GhosttyKit.xcframework", result);
}
