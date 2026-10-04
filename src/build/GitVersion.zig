const Version = @This();

const std = @import("std");

/// The short hash (7 characters) of the latest commit.
short_hash: []const u8,

/// True if there was a diff at build time.
changes: bool,

/// The tag -- if any -- that this commit is a part of.
tag: ?[]const u8,

/// The branch that was checked out at the time of the build.
branch: []const u8,

/// Initialize the version and detect it from the Git environment. This
/// allocates using the build allocator and doesn't free.
pub fn detect(b: *std.Build) !Version {
    const root = try b.root.toString(b.allocator);
    // Execute a bunch of git commands to determine the automatic version.
    const branch: []const u8 = b: {
        const tmp = switch (b.runFallible(
            &[_][]const u8{ "git", "-C", root, "rev-parse", "--abbrev-ref", "HEAD" },
            .{ .stderr_behavior = .ignore },
        )) {
            .success => |stdout| stdout,
            .spawn_failed => |err| return if (err == error.FileNotFound) error.GitNotFound else err,
            .bad_exit_code => return error.GitNotRepository,
            .crashed => return error.ProcessTerminated,
        };

        // Trim first so the trailing newline isn't sanitized into a '-'.
        const trimmed = tmp[0..std.mem.trim(u8, tmp, &std.ascii.whitespace).len];

        // Replace characters that are not valid in semantic version
        // pre-release identifiers (which only allow [0-9A-Za-z-]).
        // Slashes would also mess up dist tarball paths.
        for (trimmed) |*c| {
            if (!std.ascii.isAlphanumeric(c.*) and c.* != '-') c.* = '-';
        }

        break :b trimmed;
    };

    const short_hash = short_hash: {
        const output = switch (b.runFallible(
            &[_][]const u8{ "git", "-C", root, "-c", "log.showSignature=false", "log", "--pretty=format:%h", "-n", "1" },
            .{ .stderr_behavior = .ignore },
        )) {
            .success => |stdout| stdout,
            .spawn_failed => |err| return if (err == error.FileNotFound) error.GitNotFound else err,
            .bad_exit_code => return error.ExitCodeFailure,
            .crashed => return error.ProcessTerminated,
        };

        break :short_hash std.mem.trim(u8, output, &std.ascii.whitespace);
    };

    const tag = switch (b.runFallible(
        &[_][]const u8{ "git", "-C", root, "describe", "--exact-match", "--tags" },
        .{ .stderr_behavior = .ignore },
    )) {
        .success => |stdout| stdout,
        .spawn_failed => |err| return if (err == error.FileNotFound) error.GitNotFound else err,
        .bad_exit_code => "", // expected for untagged commits
        .crashed => return error.ProcessTerminated,
    };

    const changes = switch (b.runFallible(&[_][]const u8{
        "git",
        "-C",
        root,
        "diff",
        "--quiet",
        "--exit-code",
    }, .{ .stderr_behavior = .ignore })) {
        .success => false,
        .spawn_failed => |err| return if (err == error.FileNotFound) error.GitNotFound else err,
        .bad_exit_code => true,
        .crashed => return error.ProcessTerminated,
    };

    return .{
        .short_hash = short_hash,
        .changes = changes,
        .tag = if (tag.len > 0) std.mem.trimEnd(u8, tag, "\r\n ") else null,
        .branch = branch,
    };
}
