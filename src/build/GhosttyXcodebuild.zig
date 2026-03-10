const Ghostty = @This();

const std = @import("std");
const builtin = @import("builtin");
const RunStep = std.Build.Step.Run;
const Config = @import("Config.zig");
const Docs = @import("GhosttyDocs.zig");
const I18n = @import("GhosttyI18n.zig");
const Resources = @import("GhosttyResources.zig");
const XCFramework = @import("GhosttyXCFramework.zig");

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

    const env = try std.process.getEnvMap(b.allocator);
    const app_path = b.fmt("macos/build/{s}/Ghostty.app", .{xc_config});
    const build_derived_data_path = xcodeDerivedDataPath(b, "build", xc_config);
    const test_derived_data_path = xcodeDerivedDataPath(b, "test", xc_config);

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

        // If we have a specific architecture, we need to pass it
        // to xcodebuild.
        if (xc_arch) |arch| step.addArgs(&.{ "-arch", arch });

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
        if (xc_arch) |arch| step.addArgs(&.{ "-arch", arch });
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

    // Our step to open the resulting Ghostty app.
    const open = open: {
        const disable_save_state = RunStep.create(b, "disable save state");
        disable_save_state.has_side_effects = true;
        disable_save_state.addArgs(&.{
            "plutil",
            "-replace",
            "NSQuitAlwaysKeepsWindows",
            "-bool",
            "NO",
            b.fmt("{s}/Contents/Info.plist", .{app_path}),
        });
        disable_save_state.expectExitCode(0);
        disable_save_state.step.dependOn(&build.step);

        const open = RunStep.create(b, "run Ghostty app");
        open.has_side_effects = true;
        open.cwd = b.path("");
        open.addArgs(&.{b.fmt(
            "{s}/Contents/MacOS/ghostty",
            .{app_path},
        )});

        // Open depends on the app
        open.step.dependOn(&build.step);
        open.step.dependOn(&disable_save_state.step);

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

    // Our step to copy the app bundle to the install path.
    // We have to use `cp -R` because there are symlinks in the
    // bundle.
    const copy = copy: {
        const step = RunStep.create(b, "copy app bundle");
        step.addArgs(&.{ "cp", "-R" });
        step.addFileArg(b.path(app_path));
        step.addArg(b.fmt("{s}", .{b.install_path}));
        step.step.dependOn(&build.step);
        break :copy step;
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
    lane: []const u8,
    xc_config: []const u8,
) []const u8 {
    return b.pathResolve(&.{
        b.build_root.path orelse ".",
        b.cache_root.path orelse ".zig-cache",
        "xcodebuild",
        lane,
        xc_config,
    });
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
