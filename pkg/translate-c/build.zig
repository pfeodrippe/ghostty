//! C header translation and linked-module setup using Zig's bundled translator.

const std = @import("std");
const apple_sdk = @import("apple_sdk");
pub const Translation = struct {
    step: *std.Build.Step.TranslateC,
    mod: *std.Build.Module,
};

/// Options for translation.
pub const Options = struct {
    /// Describes the specification for a single include file.
    pub const IncludeFile = struct {
        /// Describes the type of an include file.
        pub const Type = enum {
            /// A system include, included as `<file.h>`.
            system,

            /// A user-defined include, included as `"file.h"`.
            user,
        };

        /// The path to the include. Should be either a base path or a relative
        /// path, depending on what is expected via translation based on the
        /// library directory structure.
        path: []const u8,

        /// The type of include file.
        type: Type = .system,
    };

    /// The subject of the translation.
    source: union(enum) {
        /// The subject is an on-disk path and will be passed through directly
        /// for translation.
        file: std.Build.LazyPath,

        /// The subject is a collection of include files. These files will be
        /// included (in order) as system includes (e.g., `#include <foo.h>`).
        includes: struct {
            /// The name of the generated source file in cache. If not
            /// specified, will be inferred from the operation, usually the
            /// name of the import (e.g., `c.h` if the import name was "c").
            generated_name: ?[]const u8 = null,

            /// The files to include.
            files: []const IncludeFile,
        },
    },

    /// The target to perform translation as.
    target: std.Build.ResolvedTarget,

    /// The optimization mode to perform translation as.
    optimize: std.lang.Optimize,

    /// Whether or not to link in libc. Generally you want this.
    link_libc: bool = true,

    /// The system libraries to link against. These will likely line up to
    /// whatever you are translating.
    ///
    /// These system libraries are always linked against preferred-dynamic with
    /// a fallback to static.
    link_system_libs: []const []const u8 = &.{},

    /// The libraries that you want to link against using `linkLibrary`. These
    /// will likely be C/C++ libraries compiled with the Zig build system that
    /// install headers alongside their other artifacts.
    link_libs: []const *std.Build.Step.Compile = &.{},

    /// Any additional include paths. These will be added using `-I` to the
    /// translation process, and made available to the translated code, in the
    /// order they are specified.
    include_paths: []const std.Build.LazyPath = &.{},

    /// Any additional system include paths. These will be added using
    /// `-isystem` to the translation process, and made available to the
    /// translated code, in the order they are specified.
    system_include_paths: []const std.Build.LazyPath = &.{},

    /// If supplied, these frameworks will be linked to the underlying
    /// generated Zig module via `linkFramework` in the order they are
    /// received. It does not affect translation.
    ///
    /// You likely don't need this if you are not building for an Apple
    /// platform.
    link_frameworks: []const []const u8 = &.{},

    /// Extra arguments passed to Aro. Use this if you need to pass along extra
    /// compiler flags to the translation process to make sure the headers are
    /// pre-processed correctly before translation.
    extra_args: []const []const u8 = &.{},
};

/// Creates a translation step and adds the result as import referred to by
/// `name` to the module defined by `module`, making all translated objects
/// available to the module behind the import name.
pub fn addImportToModule(
    b: *std.Build,
    name: []const u8,
    module: *std.Build.Module,
    options: Options,
) !void {
    var init_opts = options;
    if (init_opts.source == .includes and init_opts.source.includes.generated_name == null) {
        init_opts.source.includes.generated_name = try std.fmt.allocPrint(
            b.allocator,
            "{s}.h",
            .{name},
        );
    }
    const translated = try init(b, init_opts);
    module.addImport(name, translated.mod);
}

/// Create the translation step and its module, sharing include and link inputs.
pub fn init(b: *std.Build, options: Options) !Translation {
    const step = b.addTranslateC(.{
        .root_source_file = switch (options.source) {
            .file => |f| f,
            .includes => |includes| b.addWriteFiles().add(
                includes.generated_name orelse "c.h",
                try buildSource(b, includes.files),
            ),
        },
        .target = options.target,
        .optimize = options.optimize,
        .link_libc = options.link_libc,
    });
    step.addCFlags(options.extra_args);
    for (options.link_system_libs) |name| {
        step.linkSystemLibrary(name, .{
            .preferred_link_mode = .dynamic,
            .search_strategy = .mode_first,
        });
    }
    const module = step.createModule();
    for (options.link_libs) |lib| {
        step.addIncludePath(lib.getEmittedIncludeTree());
        module.linkLibrary(lib);
    }
    for (options.include_paths) |path| {
        step.addIncludePath(path);
        module.addIncludePath(path);
    }
    for (options.system_include_paths) |path| {
        step.addSystemIncludePath(path);
        module.addSystemIncludePath(path);
    }
    for (options.link_frameworks) |framework| module.linkFramework(framework, .{});
    if (options.target.result.os.tag.isDarwin()) {
        switch (try apple_sdk.pathsForTarget(b, options.target.result)) {
            .native => |paths| {
                const includes = b.graph.cwdRelativePath(paths.system_include);
                const frameworks = b.graph.cwdRelativePath(paths.framework);
                step.addSystemIncludePath(includes);
                step.addSystemFrameworkPath(frameworks);
                module.addSystemIncludePath(includes);
                module.addSystemFrameworkPath(frameworks);
            },
            .cross => {},
        }
    }
    return .{ .step = step, .mod = module };
}

/// Builds the source for a set of `IncludeFile`s.
///
/// Note that this uses the builder arena and as such does not need to be freed.
fn buildSource(b: *std.Build, files: []const Options.IncludeFile) ![]const u8 {
    var source_builder: std.Io.Writer.Allocating = .init(b.allocator);
    for (files) |file| try fmtInclude(&source_builder.writer, file);
    return source_builder.written();
}

fn fmtInclude(w: *std.Io.Writer, file: Options.IncludeFile) !void {
    if (file.type == .system) {
        try w.print("#include <{s}>\n", .{file.path});
    } else {
        try w.print("#include \"{s}\"\n", .{file.path});
    }
}

pub fn build(b: *std.Build) void {
    _ = b;
}
