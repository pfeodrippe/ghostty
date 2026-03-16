const Ghostty = @This();

const std = @import("std");
const builtin = @import("builtin");
const RunStep = std.Build.Step.Run;
const Config = @import("Config.zig");
const Docs = @import("GhosttyDocs.zig");
const I18n = @import("GhosttyI18n.zig");
const Resources = @import("GhosttyResources.zig");
const XCFramework = @import("GhosttyXCFramework.zig");

const ad_hoc_codesign_args = [_][]const u8{
    "codesign",
    "--force",
    "--sign",
    "-",
    "--deep",
};

build: *std.Build.Step.Run,
open: *std.Build.Step.Run,
copy: *std.Build.Step.Run,
xctest: *std.Build.Step.Run,

pub const Deps = struct {
    xcframework: *const XCFramework,
    docs: *const Docs,
    i18n: ?*const I18n,
    resources: *const Resources,
};

pub fn init(
    b: *std.Build,
    config: *const Config,
    deps: Deps,
) !Ghostty {
    const xc_config = switch (config.optimize) {
        .Debug => "Debug",
        .ReleaseSafe,
        .ReleaseSmall,
        .ReleaseFast,
        => "ReleaseLocal",
    };

    const xc_arch: ?[]const u8 = switch (deps.xcframework.target) {
        // Universal is our default target, so we don't have to
        // add anything.
        .universal => null,

        // Native we need to override the architecture in the Xcode
        // project with the -arch flag.
        .native => switch (builtin.cpu.arch) {
            .aarch64 => "arm64",
            .x86_64 => "x86_64",
            else => @panic("unsupported macOS arch"),
        },
    };
    const build_destination = try xcodeDestination(b.allocator, .build, xc_arch);
    const test_destination = try xcodeDestination(b.allocator, .xctest, xc_arch);

    const env = try std.process.getEnvMap(b.allocator);
    const build_derived_data_path = xcodeDerivedDataPath(b, config.hot, "build", xc_config);
    const test_derived_data_path = xcodeDerivedDataPath(b, config.hot, "test", xc_config);
    const app_path = try xcodeAppPath(b.allocator, build_derived_data_path, xc_config);
    const run_app_path = try installAppPath(b.allocator, b.install_path);

    // Our step to build the Ghostty macOS app.
    const build = build: {
        // External environment variables can mess up xcodebuild, so
        // we create a new empty environment.
        const env_map = try b.allocator.create(std.process.EnvMap);
        env_map.* = .init(b.allocator);
        try copyXcodeEnvironment(env_map, &env);

        const step = RunStep.create(b, "xcodebuild");
        step.has_side_effects = true;
        step.cwd = b.path("macos");
        step.env_map = env_map;
        step.addArgs(&.{
            "xcodebuild",
            "-derivedDataPath",
            build_derived_data_path,
            "build",
            "-scheme",
            "Ghostty",
            "-configuration",
            xc_config,
        });
        if (build_destination) |destination| step.addArgs(&.{ "-destination", destination });

        // We need the xcframework
        deps.xcframework.addStepDependencies(&step.step);

        // We also need all these resources because the xcode project
        // references them via symlinks.
        deps.resources.addStepDependencies(&step.step);
        if (deps.i18n) |v| v.addStepDependencies(&step.step);
        deps.docs.installDummy(&step.step);

        // Expect success
        step.expectExitCode(0);

        break :build step;
    };

    const xctest = xctest: {
        const env_map = try b.allocator.create(std.process.EnvMap);
        env_map.* = .init(b.allocator);
        try copyXcodeEnvironment(env_map, &env);

        const step = RunStep.create(b, "xcodebuild test");
        step.has_side_effects = true;
        step.cwd = b.path("macos");
        step.env_map = env_map;
        step.addArgs(&.{
            "xcodebuild",
            "test",
            "-derivedDataPath",
            test_derived_data_path,
            "-scheme",
            "Ghostty",
            "-skip-testing",
            "GhosttyUITests",
        });
        if (test_destination) |destination| step.addArgs(&.{ "-destination", destination });
        step.addArgs(&.{
            "CODE_SIGNING_ALLOWED=NO",
            "CODE_SIGNING_REQUIRED=NO",
            "CODE_SIGN_IDENTITY=",
        });

        // We need the xcframework
        deps.xcframework.addStepDependencies(&step.step);

        // We also need all these resources because the xcode project
        // references them via symlinks.
        deps.resources.addStepDependencies(&step.step);
        if (deps.i18n) |v| v.addStepDependencies(&step.step);
        deps.docs.installDummy(&step.step);

        // Expect success
        step.expectExitCode(0);

        break :xctest step;
    };

    // Our step to copy the app bundle to the install path.
    // We have to use `cp -R` because there are symlinks in the
    // bundle.
    const remove_existing_copy = remove_existing_copy: {
        const step = RunStep.create(b, "remove copied app bundle");
        step.has_side_effects = true;
        step.addArgs(&.{ "rm", "-rf" });
        step.addArg(run_app_path);
        step.expectExitCode(0);
        step.step.dependOn(&build.step);
        break :remove_existing_copy step;
    };

    const copy = copy: {
        const step = RunStep.create(b, "copy app bundle");
        step.has_side_effects = true;
        step.addArgs(&.{ "cp", "-R" });
        step.addFileArg(.{ .cwd_relative = app_path });
        step.addArg(b.fmt("{s}", .{b.install_path}));
        step.expectExitCode(0);
        step.step.dependOn(&remove_existing_copy.step);
        break :copy step;
    };

    // Our step to open the resulting Ghostty app. Run the copied
    // bundle so we don't mutate the signed app inside Xcode's
    // derived-data cache.
    const open = open: {
        const disable_save_state = RunStep.create(b, "disable save state");
        disable_save_state.has_side_effects = true;
        disable_save_state.addArgs(&.{
            "plutil",
            "-replace",
            "NSQuitAlwaysKeepsWindows",
            "-bool",
            "NO",
            b.fmt("{s}/Contents/Info.plist", .{run_app_path}),
        });
        disable_save_state.expectExitCode(0);
        disable_save_state.step.dependOn(&copy.step);

        const resign = RunStep.create(b, "resign copied app bundle");
        resign.has_side_effects = true;
        resign.addArgs(&ad_hoc_codesign_args);
        resign.addArg(run_app_path);
        resign.expectExitCode(0);
        resign.step.dependOn(&disable_save_state.step);

        const open = RunStep.create(b, "run Ghostty app");
        open.has_side_effects = true;
        open.cwd = b.path("");
        open.addArgs(&.{b.fmt(
            "{s}/Contents/MacOS/ghostty",
            .{run_app_path},
        )});

        open.step.dependOn(&copy.step);
        open.step.dependOn(&resign.step);

        // This overrides our default behavior and forces logs to show
        // up on stderr (in addition to the centralized macOS log).
        open.setEnvironmentVariable("GHOSTTY_LOG", "stderr,macos");

        // Configure how we're launching
        open.setEnvironmentVariable("GHOSTTY_MAC_LAUNCH_SOURCE", "zig_run");

        if (config.hot) {
            open.setEnvironmentVariable("ZIG_HOT_COMPILER", b.graph.zig_exe);
            const workspace_path = b.path(".zig-hot").getPath3(b, &open.step).toString(b.graph.arena) catch @panic("OOM");
            open.setEnvironmentVariable("ZIG_HOT_WORKSPACE", workspace_path);
            if (b.graph.zig_lib_directory.path) |zig_lib_dir| {
                open.setEnvironmentVariable("ZIG_HOT_ZIG_LIB_DIR", zig_lib_dir);
            }
            if (deps.xcframework.hot_manifest) |manifest| {
                const manifest_rel_path = "share/ghostty/GhosttyKit.hot.json";
                const manifest_install = b.addInstallFile(manifest, manifest_rel_path);
                open.step.dependOn(&manifest_install.step);
                open.setEnvironmentVariable("ZIG_HOT_MANIFEST", b.getInstallPath(.prefix, manifest_rel_path));
            }
        }

        if (b.args) |args| {
            open.addArgs(args);
        }

        break :open open;
    };

    return .{
        .build = build,
        .open = open,
        .copy = copy,
        .xctest = xctest,
    };
}

fn copyXcodeEnvironment(
    env_map: *std.process.EnvMap,
    env: *const std.process.EnvMap,
) !void {
    for (&[_][]const u8{
        "PATH",
        "HOME",
        "TMPDIR",
        "USER",
        "LOGNAME",
    }) |key| {
        if (env.get(key)) |value| try env_map.put(key, value);
    }
}

fn xcodeDerivedDataPath(
    b: *std.Build,
    hot: bool,
    lane: []const u8,
    xc_config: []const u8,
) []const u8 {
    return b.pathResolve(&.{
        b.build_root.path orelse ".",
        ".xcodebuild",
        if (hot) "hot" else "stock",
        "xcodebuild",
        lane,
        xc_config,
    });
}

fn xcodeAppPath(
    allocator: std.mem.Allocator,
    build_derived_data_path: []const u8,
    xc_config: []const u8,
) ![]const u8 {
    return try std.fs.path.join(allocator, &.{
        build_derived_data_path,
        "Build",
        "Products",
        xc_config,
        "Ghostty.app",
    });
}

fn installAppPath(
    allocator: std.mem.Allocator,
    install_path: []const u8,
) ![]const u8 {
    return try std.fs.path.join(allocator, &.{
        install_path,
        "Ghostty.app",
    });
}

const XcodeLane = enum {
    build,
    xctest,
};

fn xcodeDestination(
    allocator: std.mem.Allocator,
    lane: XcodeLane,
    xc_arch: ?[]const u8,
) !?[]const u8 {
    if (xc_arch) |arch| {
        return switch (lane) {
            .build => try std.fmt.allocPrint(allocator, "platform=macOS,arch={s}", .{arch}),
            .xctest => try std.fmt.allocPrint(allocator, "platform=macOS,arch={s}", .{arch}),
        };
    }
    return switch (lane) {
        .build => try allocator.dupe(u8, "generic/platform=macOS"),
        .xctest => try allocator.dupe(u8, "platform=macOS"),
    };
}

test "xcode app path uses derived data products dir" {
    const testing = std.testing;
    const result = try xcodeAppPath(testing.allocator, "/tmp/dd", "Debug");
    defer testing.allocator.free(result);
    try testing.expectEqualStrings(
        "/tmp/dd/Build/Products/Debug/Ghostty.app",
        result,
    );
}

test "hot xcode derived data path is stable outside zig cache" {
    const testing = std.testing;
    var graph: std.Build.Graph = undefined;
    graph.cache_root = .{ .path = "/tmp/ignored-cache-root" };

    const build_root: std.Build.Cache.Directory = .{ .path = "/tmp/ghostty" };
    var b: std.Build = undefined;
    b.graph = &graph;
    b.build_root = build_root;

    const result = xcodeDerivedDataPath(&b, true, "build", "Debug");
    try testing.expectEqualStrings(
        "/tmp/ghostty/.xcodebuild/hot/xcodebuild/build/Debug",
        result,
    );
}

test "stock xcode derived data path is stable outside zig cache" {
    const testing = std.testing;
    var graph: std.Build.Graph = undefined;
    graph.cache_root = .{ .path = "/tmp/ignored-cache-root" };

    const build_root: std.Build.Cache.Directory = .{ .path = "/tmp/ghostty" };
    var b: std.Build = undefined;
    b.graph = &graph;
    b.build_root = build_root;

    const result = xcodeDerivedDataPath(&b, false, "test", "Debug");
    try testing.expectEqualStrings(
        "/tmp/ghostty/.xcodebuild/stock/xcodebuild/test/Debug",
        result,
    );
}

test "install app path uses install root" {
    const testing = std.testing;
    const result = try installAppPath(testing.allocator, "/tmp/out");
    defer testing.allocator.free(result);
    try testing.expectEqualStrings("/tmp/out/Ghostty.app", result);
}

test "copied app bundle is resigned ad hoc after plist mutation" {
    const testing = std.testing;
    try testing.expectEqualStrings("codesign", ad_hoc_codesign_args[0]);
    try testing.expectEqualStrings("--force", ad_hoc_codesign_args[1]);
    try testing.expectEqualStrings("--sign", ad_hoc_codesign_args[2]);
    try testing.expectEqualStrings("-", ad_hoc_codesign_args[3]);
    try testing.expectEqualStrings("--deep", ad_hoc_codesign_args[4]);
}

test "native build xcode destination pins mac arch" {
    const testing = std.testing;
    const result = try xcodeDestination(testing.allocator, .build, "arm64");
    defer testing.allocator.free(result.?);
    try testing.expectEqualStrings("platform=macOS,arch=arm64", result.?);
}

test "native xctest xcode destination pins mac arch" {
    const testing = std.testing;
    const result = try xcodeDestination(testing.allocator, .xctest, "arm64");
    defer testing.allocator.free(result.?);
    try testing.expectEqualStrings("platform=macOS,arch=arm64", result.?);
}

test "universal build uses generic mac destination" {
    const testing = std.testing;
    const result = try xcodeDestination(testing.allocator, .build, null);
    defer testing.allocator.free(result.?);
    try testing.expectEqualStrings("generic/platform=macOS", result.?);
}

test "universal test uses host mac destination" {
    const testing = std.testing;
    const result = try xcodeDestination(testing.allocator, .xctest, null);
    defer testing.allocator.free(result.?);
    try testing.expectEqualStrings("platform=macOS", result.?);
}

pub fn install(self: *const Ghostty) void {
    const b = self.copy.step.owner;
    b.getInstallStep().dependOn(&self.copy.step);
}

pub fn installXcframework(self: *const Ghostty) void {
    const b = self.build.step.owner;
    b.getInstallStep().dependOn(&self.build.step);
}

pub fn addTestStepDependencies(
    self: *const Ghostty,
    other_step: *std.Build.Step,
) void {
    other_step.dependOn(&self.xctest.step);
}
