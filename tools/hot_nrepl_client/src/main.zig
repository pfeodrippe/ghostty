const std = @import("std");
const json = std.json;
const mem = std.mem;

const max_request_bytes = 16 * 1024 * 1024;
const max_response_bytes = 64 * 1024 * 1024;
const Printed = error{Printed};

const FieldPair = struct {
    key: []const u8,
    value: []const u8,
};

const IntFieldPair = struct {
    key: []const u8,
    value: i64,
};

const PathMapping = struct {
    path: []const u8,
    file_path: []const u8,
};

const ToggleMode = enum {
    status,
    on,
    off,
    toggle,

    fn fromText(text: []const u8) ?ToggleMode {
        if (mem.eql(u8, text, "status")) return .status;
        if (mem.eql(u8, text, "on")) return .on;
        if (mem.eql(u8, text, "off")) return .off;
        if (mem.eql(u8, text, "toggle")) return .toggle;
        return null;
    }

    fn asText(self: ToggleMode) []const u8 {
        return switch (self) {
            .status => "status",
            .on => "on",
            .off => "off",
            .toggle => "toggle",
        };
    }
};

const Options = struct {
    help: bool = false,
    addr: ?[]const u8 = null,
    port_file: ?[]const u8 = null,
    op: ?[]const u8 = null,
    session: []const u8 = "root",
    scope: ?[]const u8 = null,
    path: ?[]const u8 = null,
    file_path: ?[]const u8 = null,
    code: ?[]const u8 = null,
    generation: ?i64 = null,
    timeout_seconds: f64 = 5.0,
    fields: []const FieldPair = &.{},
    int_fields: []const IntFieldPair = &.{},
    toggle_mode: ?ToggleMode = null,
    toggle_probe_path: ?[]const u8 = null,
    toggle_active_code: ?[]const u8 = null,
    toggle_loads: []const PathMapping = &.{},
    toggle_restores: []const PathMapping = &.{},
};

const RuntimePaths = struct {
    allocator: mem.Allocator,
    cwd: []const u8,
    repo_root: ?[]const u8,

    fn init(allocator: mem.Allocator) !RuntimePaths {
        const cwd = try std.process.getCwdAlloc(allocator);
        return .{
            .allocator = allocator,
            .cwd = cwd,
            .repo_root = try findRepoRoot(allocator, cwd),
        };
    }

    fn defaultPortFile(self: RuntimePaths) ![]const u8 {
        if (self.repo_root) |repo_root| {
            return try std.fs.path.join(self.allocator, &.{ repo_root, ".nrepl-port" });
        }
        return try std.fs.path.join(self.allocator, &.{ self.cwd, ".nrepl-port" });
    }

    fn resolvePath(self: RuntimePaths, text: []const u8) ![]const u8 {
        if (std.fs.path.isAbsolute(text)) return text;

        const cwd_candidate = try std.fs.path.join(self.allocator, &.{ self.cwd, text });
        if (std.fs.accessAbsolute(cwd_candidate, .{})) |_| {
            return try std.fs.realpathAlloc(self.allocator, cwd_candidate);
        } else |_| {}

        if (self.repo_root) |repo_root| {
            const repo_candidate = try std.fs.path.join(self.allocator, &.{ repo_root, text });
            if (std.fs.accessAbsolute(repo_candidate, .{})) |_| {
                return try std.fs.realpathAlloc(self.allocator, repo_candidate);
            } else |_| {}
        }

        return text;
    }
};

const DictEntry = struct {
    key: []const u8,
    value: BencodeValue,
};

const BencodeValue = union(enum) {
    integer: i64,
    bytes: []const u8,
    list: []BencodeValue,
    dict: []DictEntry,

    fn dictGet(self: *const BencodeValue, key: []const u8) ?*const BencodeValue {
        if (self.* != .dict) return null;
        for (self.dict) |*entry| {
            if (mem.eql(u8, entry.key, key)) return &entry.value;
        }
        return null;
    }

    fn bytesSlice(self: *const BencodeValue) ?[]const u8 {
        return switch (self.*) {
            .bytes => |bytes| bytes,
            else => null,
        };
    }

    fn listSlice(self: *const BencodeValue) ?[]const BencodeValue {
        return switch (self.*) {
            .list => |items| items,
            else => null,
        };
    }

    fn toJsonValue(self: *const BencodeValue, allocator: mem.Allocator) !json.Value {
        return switch (self.*) {
            .integer => |value| .{ .integer = value },
            .bytes => |bytes| blk: {
                if (std.unicode.utf8ValidateSlice(bytes)) {
                    break :blk .{ .string = bytes };
                }
                var array = json.Array.init(allocator);
                for (bytes) |byte| {
                    try array.append(.{ .integer = byte });
                }
                break :blk .{ .array = array };
            },
            .list => |items| blk: {
                var array = json.Array.init(allocator);
                for (items) |*item| {
                    try array.append(try item.toJsonValue(allocator));
                }
                break :blk .{ .array = array };
            },
            .dict => |entries| blk: {
                var object = json.ObjectMap.init(allocator);
                for (entries) |*entry| {
                    if (!std.unicode.utf8ValidateSlice(entry.key)) {
                        return error.InvalidUtf8DictionaryKey;
                    }
                    try object.put(entry.key, try entry.value.toJsonValue(allocator));
                }
                break :blk .{ .object = object };
            },
        };
    }
};

const ParseResult = struct {
    value: BencodeValue,
    used: usize,
};

const RequestFieldValue = union(enum) {
    string: []const u8,
    integer: i64,
    bytes: []const u8,
};

const RequestEntry = struct {
    key: []const u8,
    value: RequestFieldValue,
};

const Address = struct {
    host: []const u8,
    port: u16,
};

const ToggleResult = struct {
    requested_mode: ToggleMode,
    effective_mode: ToggleMode,
    action: []const u8,
    active_before: bool,
    active: bool,
    generation_before: ?i64 = null,
    generation_after: ?i64 = null,
    touched: []const PathMapping = &.{},
};

pub fn main() !void {
    var arena_state = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena_state.deinit();
    const allocator = arena_state.allocator();

    const exit_code: u8 = run(allocator) catch |err| blk: {
        switch (err) {
            error.Printed => break :blk 1,
            else => {
                try printStdErr("error: {s}\n", .{@errorName(err)});
                break :blk 1;
            },
        }
    };
    if (exit_code != 0) std.process.exit(exit_code);
}

fn run(allocator: mem.Allocator) !u8 {
    const paths = try RuntimePaths.init(allocator);
    const options = try parseOptions(allocator);
    if (options.help) {
        try printHelp();
        return 0;
    }

    if (options.toggle_mode) |toggle_mode| {
        if (options.op != null) return fail("do not combine --toggle with --op", .{});
        const result = try runToggle(allocator, paths, options, toggle_mode);
        try printToggleResult(allocator, result);
        return 0;
    }

    const request = try buildRequest(allocator, paths, options);
    const address = try resolveAddress(allocator, paths, options);
    const response = try sendRequest(allocator, address, options.timeout_seconds, request);
    try printJsonValue(allocator, &response);
    return if (responseFailed(&response)) 1 else 0;
}

fn parseOptions(allocator: mem.Allocator) !Options {
    const args = try std.process.argsAlloc(allocator);
    var fields = std.array_list.Managed(FieldPair).init(allocator);
    var int_fields = std.array_list.Managed(IntFieldPair).init(allocator);
    var toggle_loads = std.array_list.Managed(PathMapping).init(allocator);
    var toggle_restores = std.array_list.Managed(PathMapping).init(allocator);
    var options = Options{};

    var index: usize = 1;
    while (index < args.len) {
        const arg: []const u8 = args[index];
        if (mem.eql(u8, arg, "--help") or mem.eql(u8, arg, "-h")) {
            options.help = true;
            index += 1;
            continue;
        }

        if (mem.eql(u8, arg, "--addr")) {
            options.addr = try requireArg(args, &index, "--addr");
        } else if (mem.eql(u8, arg, "--port-file")) {
            options.port_file = try requireArg(args, &index, "--port-file");
        } else if (mem.eql(u8, arg, "--op")) {
            options.op = try requireArg(args, &index, "--op");
        } else if (mem.eql(u8, arg, "--session")) {
            options.session = try requireArg(args, &index, "--session");
        } else if (mem.eql(u8, arg, "--scope")) {
            options.scope = try requireArg(args, &index, "--scope");
        } else if (mem.eql(u8, arg, "--path")) {
            options.path = try requireArg(args, &index, "--path");
        } else if (mem.eql(u8, arg, "--file-path")) {
            options.file_path = try requireArg(args, &index, "--file-path");
        } else if (mem.eql(u8, arg, "--code")) {
            options.code = try requireArg(args, &index, "--code");
        } else if (mem.eql(u8, arg, "--generation")) {
            const value = try requireArg(args, &index, "--generation");
            options.generation = std.fmt.parseInt(i64, value, 10) catch {
                return fail("invalid --generation: {s}", .{value});
            };
        } else if (mem.eql(u8, arg, "--field")) {
            const entry = try requireArg(args, &index, "--field");
            try fields.append(try parseStringField(entry, "--field"));
        } else if (mem.eql(u8, arg, "--int-field")) {
            const entry = try requireArg(args, &index, "--int-field");
            try int_fields.append(try parseIntField(entry));
        } else if (mem.eql(u8, arg, "--timeout")) {
            const value = try requireArg(args, &index, "--timeout");
            options.timeout_seconds = std.fmt.parseFloat(f64, value) catch {
                return fail("invalid --timeout: {s}", .{value});
            };
            if (!(options.timeout_seconds > 0)) {
                return fail("--timeout must be greater than zero", .{});
            }
        } else if (mem.eql(u8, arg, "--toggle")) {
            const value = try requireArg(args, &index, "--toggle");
            options.toggle_mode = ToggleMode.fromText(value) orelse return fail(
                "--toggle expects status, on, off, or toggle: {s}",
                .{value},
            );
        } else if (mem.eql(u8, arg, "--toggle-probe-path")) {
            options.toggle_probe_path = try requireArg(args, &index, "--toggle-probe-path");
        } else if (mem.eql(u8, arg, "--toggle-active-code")) {
            options.toggle_active_code = try requireArg(args, &index, "--toggle-active-code");
        } else if (mem.eql(u8, arg, "--toggle-load")) {
            const entry = try requireArg(args, &index, "--toggle-load");
            try toggle_loads.append(try parsePathMapping(entry, "--toggle-load"));
        } else if (mem.eql(u8, arg, "--toggle-restore")) {
            const entry = try requireArg(args, &index, "--toggle-restore");
            try toggle_restores.append(try parsePathMapping(entry, "--toggle-restore"));
        } else {
            return fail("unknown flag: {s}", .{arg});
        }

        index += 1;
    }

    options.fields = try fields.toOwnedSlice();
    options.int_fields = try int_fields.toOwnedSlice();
    options.toggle_loads = try toggle_loads.toOwnedSlice();
    options.toggle_restores = try toggle_restores.toOwnedSlice();
    return options;
}

fn requireArg(args: []const [:0]u8, index: *usize, flag: []const u8) ![]const u8 {
    index.* += 1;
    if (index.* >= args.len) return fail("missing value for {s}", .{flag});
    return args[index.*];
}

fn parseStringField(entry: []const u8, flag_name: []const u8) !FieldPair {
    const eq_index = mem.indexOfScalar(u8, entry, '=') orelse {
        return fail("{s} expects KEY=VALUE entries: {s}", .{ flag_name, entry });
    };
    const key = entry[0..eq_index];
    if (key.len == 0) return fail("{s} entry has empty key: {s}", .{ flag_name, entry });
    return .{ .key = key, .value = entry[eq_index + 1 ..] };
}

fn parseIntField(entry: []const u8) !IntFieldPair {
    const pair = try parseStringField(entry, "--int-field");
    const value = std.fmt.parseInt(i64, pair.value, 10) catch {
        return fail("--int-field expects integer values: {s}", .{entry});
    };
    return .{ .key = pair.key, .value = value };
}

fn parsePathMapping(entry: []const u8, flag_name: []const u8) !PathMapping {
    const pair = try parseStringField(entry, flag_name);
    return .{ .path = pair.key, .file_path = pair.value };
}

fn buildRequest(allocator: mem.Allocator, paths: RuntimePaths, options: Options) ![]const u8 {
    const op = options.op orelse return fail("--op is required", .{});
    if (mem.eql(u8, op, "eval") and options.code == null) {
        return fail("--op eval requires --code", .{});
    }
    if (mem.eql(u8, op, "load-file") and options.file_path == null) {
        return fail("--op load-file requires --file-path", .{});
    }
    if (mem.eql(u8, op, "in-file") and options.path == null) {
        return fail("--op in-file requires --path", .{});
    }

    var entries = std.array_list.Managed(RequestEntry).init(allocator);
    try entries.append(.{ .key = "op", .value = .{ .string = op } });
    try entries.append(.{ .key = "session", .value = .{ .string = options.session } });

    if (options.scope) |scope| {
        try entries.append(.{ .key = "scope", .value = .{ .string = scope } });
    }
    if (options.generation) |generation| {
        try entries.append(.{ .key = "generation", .value = .{ .integer = generation } });
    }
    if (options.path) |path_text| {
        try entries.append(.{ .key = "path", .value = .{ .string = try paths.resolvePath(path_text) } });
    }
    if (options.code) |code_text| {
        const code = if (mem.eql(u8, code_text, "-"))
            try std.fs.File.stdin().readToEndAlloc(allocator, max_request_bytes)
        else
            code_text;
        try entries.append(.{ .key = "code", .value = .{ .string = code } });
    }
    for (options.fields) |field| {
        try entries.append(.{ .key = field.key, .value = .{ .string = field.value } });
    }
    for (options.int_fields) |field| {
        try entries.append(.{ .key = field.key, .value = .{ .integer = field.value } });
    }
    if (options.file_path) |file_path_text| {
        const resolved_file_path = try paths.resolvePath(file_path_text);
        const file_bytes = try readFileAlloc(allocator, resolved_file_path, max_request_bytes);
        try entries.append(.{ .key = "file", .value = .{ .bytes = file_bytes } });
        const request_path = if (options.path) |path_text|
            try paths.resolvePath(path_text)
        else
            resolved_file_path;
        try entries.append(.{ .key = "path", .value = .{ .string = request_path } });
    }

    return try encodeRequestDict(allocator, entries.items);
}

fn resolveAddress(allocator: mem.Allocator, paths: RuntimePaths, options: Options) !Address {
    if (options.addr) |addr_text| {
        const colon_index = mem.lastIndexOfScalar(u8, addr_text, ':') orelse {
            return fail("invalid --addr: {s}", .{addr_text});
        };
        const host = if (colon_index == 0) "127.0.0.1" else addr_text[0..colon_index];
        const port_text = addr_text[colon_index + 1 ..];
        const port = std.fmt.parseInt(u16, port_text, 10) catch {
            return fail("invalid --addr port: {s}", .{addr_text});
        };
        return .{ .host = host, .port = port };
    }

    const port_file = options.port_file orelse try paths.defaultPortFile();
    const resolved_port_file = try paths.resolvePath(port_file);
    const port_text = readFileText(allocator, resolved_port_file, 128) catch |err| switch (err) {
        error.FileNotFound => return fail("missing port file: {s}", .{resolved_port_file}),
        else => return err,
    };
    const trimmed = mem.trim(u8, port_text, " \t\r\n");
    const port = std.fmt.parseInt(u16, trimmed, 10) catch {
        return fail("invalid port file contents: {s}", .{resolved_port_file});
    };
    return .{ .host = "127.0.0.1", .port = port };
}

fn sendRequest(allocator: mem.Allocator, address: Address, timeout_seconds: f64, request: []const u8) !BencodeValue {
    var stream = try std.net.tcpConnectToHost(allocator, address.host, address.port);
    defer stream.close();
    try applySocketTimeout(stream.handle, timeout_seconds);
    try stream.writeAll(request);
    return try readResponse(allocator, stream);
}

fn applySocketTimeout(handle: std.net.Stream.Handle, timeout_seconds: f64) !void {
    const micros_float = timeout_seconds * 1_000_000.0;
    const micros: u64 = @intFromFloat(micros_float);
    const timeout = std.c.timeval{
        .sec = @intCast(micros / 1_000_000),
        .usec = @intCast(micros % 1_000_000),
    };
    const timeout_bytes = std.mem.toBytes(timeout);
    try std.posix.setsockopt(handle, std.posix.SOL.SOCKET, std.posix.SO.RCVTIMEO, &timeout_bytes);
    try std.posix.setsockopt(handle, std.posix.SOL.SOCKET, std.posix.SO.SNDTIMEO, &timeout_bytes);
}

fn readResponse(allocator: mem.Allocator, stream: std.net.Stream) !BencodeValue {
    var data = std.array_list.Managed(u8).init(allocator);
    var buffer: [65536]u8 = undefined;

    while (true) {
        const amount = stream.read(&buffer) catch |err| switch (err) {
            error.WouldBlock, error.ConnectionTimedOut => return fail("timed out waiting for nREPL response", .{}),
            else => return err,
        };
        if (amount == 0) break;
        if (data.items.len + amount > max_response_bytes) {
            return fail("nREPL response exceeded maximum supported size", .{});
        }
        try data.appendSlice(buffer[0..amount]);
        const parsed = parseBencode(allocator, data.items, 0) catch |err| switch (err) {
            error.NeedMoreData => continue,
            else => return err,
        };
        if (parsed.used != data.items.len) {
            return fail("unexpected trailing data in nREPL response", .{});
        }
        return parsed.value;
    }

    if (data.items.len == 0) return fail("empty nREPL response", .{});
    const parsed = parseBencode(allocator, data.items, 0) catch |err| switch (err) {
        error.NeedMoreData => return fail("incomplete nREPL response", .{}),
        else => return err,
    };
    if (parsed.used != data.items.len) {
        return fail("unexpected trailing data in nREPL response", .{});
    }
    return parsed.value;
}

fn responseFailed(response: *const BencodeValue) bool {
    const status_value = response.dictGet("status") orelse return false;
    const items = status_value.listSlice() orelse return false;
    for (items) |*item| {
        const text = item.bytesSlice() orelse continue;
        if (mem.eql(u8, text, "error")) return true;
    }
    return false;
}

fn runToggle(
    allocator: mem.Allocator,
    paths: RuntimePaths,
    options: Options,
    toggle_mode: ToggleMode,
) !ToggleResult {
    if (options.toggle_probe_path == null) return fail("--toggle requires --toggle-probe-path", .{});
    if (options.toggle_active_code == null) return fail("--toggle requires --toggle-active-code", .{});
    if (toggle_mode != .status and options.toggle_loads.len == 0) {
        return fail("toggle on/off/toggle requires at least one --toggle-load PATH=FILE entry", .{});
    }

    const address = try resolveAddress(allocator, paths, options);
    const probe_path = try paths.resolvePath(options.toggle_probe_path.?);
    const active_code = if (mem.eql(u8, options.toggle_active_code.?, "-"))
        try std.fs.File.stdin().readToEndAlloc(allocator, max_request_bytes)
    else
        options.toggle_active_code.?;

    const active_before = try probeActive(allocator, address, options.timeout_seconds, probe_path, active_code);
    const effective_mode: ToggleMode = switch (toggle_mode) {
        .toggle => if (active_before) .off else .on,
        else => toggle_mode,
    };

    var result = ToggleResult{
        .requested_mode = toggle_mode,
        .effective_mode = effective_mode,
        .action = "none",
        .active_before = active_before,
        .active = active_before,
    };

    switch (effective_mode) {
        .status => {},
        .on => {
            if (active_before) return result;
            result.generation_before = try currentGeneration(allocator, address, options.timeout_seconds);
            try applyMappings(allocator, paths, address, options.timeout_seconds, options.toggle_loads, options.toggle_restores);
            result.generation_after = try currentGeneration(allocator, address, options.timeout_seconds);
            result.action = "on";
            result.active = true;
            result.touched = options.toggle_loads;
        },
        .off => {
            if (!active_before) return result;
            const restore_mappings = try deriveRestoreMappings(allocator, options.toggle_loads, options.toggle_restores);
            result.generation_before = try currentGeneration(allocator, address, options.timeout_seconds);
            try applyMappingsUnchecked(allocator, paths, address, options.timeout_seconds, restore_mappings);
            result.generation_after = try currentGeneration(allocator, address, options.timeout_seconds);
            result.action = "off";
            result.active = false;
            result.touched = restore_mappings;
        },
        .toggle => unreachable,
    }

    return result;
}

fn probeActive(
    allocator: mem.Allocator,
    address: Address,
    timeout_seconds: f64,
    probe_path: []const u8,
    active_code: []const u8,
) !bool {
    const clone_response = try requestExpectSuccess(
        allocator,
        address,
        timeout_seconds,
        &.{
            .{ .key = "op", .value = .{ .string = "clone" } },
            .{ .key = "session", .value = .{ .string = "root" } },
        },
    );
    const new_session = responseStringField(&clone_response, "new-session") orelse {
        return fail("clone response did not include new-session", .{});
    };

    defer closeSessionIgnore(allocator, address, timeout_seconds, new_session);

    _ = try requestExpectSuccess(
        allocator,
        address,
        timeout_seconds,
        &.{
            .{ .key = "op", .value = .{ .string = "in-file" } },
            .{ .key = "session", .value = .{ .string = new_session } },
            .{ .key = "path", .value = .{ .string = probe_path } },
        },
    );

    const eval_response = try sendRequestWithEntries(
        allocator,
        address,
        timeout_seconds,
        &.{
            .{ .key = "op", .value = .{ .string = "eval" } },
            .{ .key = "session", .value = .{ .string = new_session } },
            .{ .key = "code", .value = .{ .string = active_code } },
        },
    );
    if (responseFailed(&eval_response)) return false;
    return responseBoolLikeValue(&eval_response, "value") orelse {
        return fail("toggle probe did not return a boolean-like value", .{});
    };
}

fn currentGeneration(allocator: mem.Allocator, address: Address, timeout_seconds: f64) !i64 {
    const response = try requestExpectSuccess(
        allocator,
        address,
        timeout_seconds,
        &.{
            .{ .key = "op", .value = .{ .string = "current-generation" } },
            .{ .key = "session", .value = .{ .string = "root" } },
        },
    );
    return responseIntLikeValue(&response, "generation") orelse {
        return fail("current-generation response did not include generation", .{});
    };
}

fn applyMappings(
    allocator: mem.Allocator,
    paths: RuntimePaths,
    address: Address,
    timeout_seconds: f64,
    load_mappings: []const PathMapping,
    explicit_restores: []const PathMapping,
) !void {
    for (load_mappings, 0..) |mapping, index| {
        loadFile(allocator, paths, address, timeout_seconds, mapping) catch |err| {
            var rollback_index = index;
            while (rollback_index > 0) {
                rollback_index -= 1;
                const previous = load_mappings[rollback_index];
                const restore_mapping = findRestoreMapping(previous.path, explicit_restores) orelse PathMapping{
                    .path = previous.path,
                    .file_path = previous.path,
                };
                loadFile(allocator, paths, address, timeout_seconds, restore_mapping) catch {};
            }
            return err;
        };
    }
}

fn applyMappingsUnchecked(
    allocator: mem.Allocator,
    paths: RuntimePaths,
    address: Address,
    timeout_seconds: f64,
    mappings: []const PathMapping,
) !void {
    for (mappings) |mapping| {
        try loadFile(allocator, paths, address, timeout_seconds, mapping);
    }
}

fn deriveRestoreMappings(
    allocator: mem.Allocator,
    load_mappings: []const PathMapping,
    explicit_restores: []const PathMapping,
) ![]const PathMapping {
    if (explicit_restores.len != 0) return explicit_restores;
    var mappings = try allocator.alloc(PathMapping, load_mappings.len);
    for (load_mappings, 0..) |mapping, index| {
        mappings[index] = .{ .path = mapping.path, .file_path = mapping.path };
    }
    return mappings;
}

fn findRestoreMapping(path: []const u8, explicit_restores: []const PathMapping) ?PathMapping {
    for (explicit_restores) |mapping| {
        if (mem.eql(u8, mapping.path, path)) return mapping;
    }
    return null;
}

fn loadFile(
    allocator: mem.Allocator,
    paths: RuntimePaths,
    address: Address,
    timeout_seconds: f64,
    mapping: PathMapping,
) !void {
    const resolved_path = try paths.resolvePath(mapping.path);
    const resolved_file_path = try paths.resolvePath(mapping.file_path);
    const file_bytes = try readFileAlloc(allocator, resolved_file_path, max_request_bytes);
    _ = try requestExpectSuccess(
        allocator,
        address,
        timeout_seconds,
        &.{
            .{ .key = "op", .value = .{ .string = "load-file" } },
            .{ .key = "session", .value = .{ .string = "root" } },
            .{ .key = "path", .value = .{ .string = resolved_path } },
            .{ .key = "file", .value = .{ .bytes = file_bytes } },
        },
    );
}

fn sendRequestWithEntries(
    allocator: mem.Allocator,
    address: Address,
    timeout_seconds: f64,
    entries: []const RequestEntry,
) !BencodeValue {
    const request = try encodeRequestDict(allocator, entries);
    return try sendRequest(allocator, address, timeout_seconds, request);
}

fn requestExpectSuccess(
    allocator: mem.Allocator,
    address: Address,
    timeout_seconds: f64,
    entries: []const RequestEntry,
) !BencodeValue {
    const response = try sendRequestWithEntries(allocator, address, timeout_seconds, entries);
    if (!responseFailed(&response)) return response;

    try printJsonValueToStream(allocator, &response, .stderr, true);
    return error.Printed;
}

fn closeSessionIgnore(
    allocator: mem.Allocator,
    address: Address,
    timeout_seconds: f64,
    session: []const u8,
) void {
    _ = requestExpectSuccess(
        allocator,
        address,
        timeout_seconds,
        &.{
            .{ .key = "op", .value = .{ .string = "close" } },
            .{ .key = "session", .value = .{ .string = session } },
        },
    ) catch {};
}

fn responseStringField(response: *const BencodeValue, field: []const u8) ?[]const u8 {
    const value = response.dictGet(field) orelse return null;
    return value.bytesSlice();
}

fn responseBoolLikeValue(response: *const BencodeValue, field: []const u8) ?bool {
    const value = response.dictGet(field) orelse return null;
    return switch (value.*) {
        .bytes => |bytes| if (mem.eql(u8, bytes, "true"))
            true
        else if (mem.eql(u8, bytes, "false"))
            false
        else
            null,
        .integer => |integer| integer != 0,
        else => null,
    };
}

fn responseIntLikeValue(response: *const BencodeValue, field: []const u8) ?i64 {
    const value = response.dictGet(field) orelse return null;
    return switch (value.*) {
        .integer => |integer| integer,
        .bytes => |bytes| std.fmt.parseInt(i64, bytes, 10) catch null,
        else => null,
    };
}

fn encodeRequestDict(allocator: mem.Allocator, entries: []const RequestEntry) ![]const u8 {
    var output = std.array_list.Managed(u8).init(allocator);
    try output.append('d');
    for (entries) |entry| {
        try encodeBytes(&output, entry.key);
        switch (entry.value) {
            .string => |value| try encodeBytes(&output, value),
            .integer => |value| try encodeInteger(&output, value),
            .bytes => |value| try encodeBytes(&output, value),
        }
    }
    try output.append('e');
    return try output.toOwnedSlice();
}

fn encodeBytes(output: *std.array_list.Managed(u8), value: []const u8) !void {
    try output.writer().print("{d}:", .{value.len});
    try output.appendSlice(value);
}

fn encodeInteger(output: *std.array_list.Managed(u8), value: i64) !void {
    try output.append('i');
    try output.writer().print("{d}", .{value});
    try output.append('e');
}

fn parseBencode(allocator: mem.Allocator, data: []const u8, start: usize) !ParseResult {
    if (start >= data.len) return error.NeedMoreData;
    const marker = data[start];
    switch (marker) {
        'i' => {
            const end = mem.indexOfScalarPos(u8, data, start + 1, 'e') orelse return error.NeedMoreData;
            const integer = std.fmt.parseInt(i64, data[start + 1 .. end], 10) catch return error.InvalidBencode;
            return .{ .value = .{ .integer = integer }, .used = end + 1 };
        },
        'l' => {
            var items = std.array_list.Managed(BencodeValue).init(allocator);
            var cursor = start + 1;
            while (true) {
                if (cursor >= data.len) return error.NeedMoreData;
                if (data[cursor] == 'e') {
                    return .{ .value = .{ .list = try items.toOwnedSlice() }, .used = cursor + 1 };
                }
                const parsed = try parseBencode(allocator, data, cursor);
                try items.append(parsed.value);
                cursor = parsed.used;
            }
        },
        'd' => {
            var entries = std.array_list.Managed(DictEntry).init(allocator);
            var cursor = start + 1;
            while (true) {
                if (cursor >= data.len) return error.NeedMoreData;
                if (data[cursor] == 'e') {
                    return .{ .value = .{ .dict = try entries.toOwnedSlice() }, .used = cursor + 1 };
                }
                const parsed_key = try parseBencode(allocator, data, cursor);
                const key_bytes = parsed_key.value.bytesSlice() orelse return error.InvalidBencode;
                const parsed_value = try parseBencode(allocator, data, parsed_key.used);
                try entries.append(.{ .key = key_bytes, .value = parsed_value.value });
                cursor = parsed_value.used;
            }
        },
        '0'...'9' => {
            const colon = mem.indexOfScalarPos(u8, data, start, ':') orelse return error.NeedMoreData;
            const size = std.fmt.parseInt(usize, data[start..colon], 10) catch return error.InvalidBencode;
            const bytes_start = colon + 1;
            const bytes_end = bytes_start + size;
            if (bytes_end > data.len) return error.NeedMoreData;
            const bytes = try allocator.dupe(u8, data[bytes_start..bytes_end]);
            return .{ .value = .{ .bytes = bytes }, .used = bytes_end };
        },
        else => return error.InvalidBencode,
    }
}

fn printJsonValue(allocator: mem.Allocator, value: *const BencodeValue) !void {
    try printJsonValueToStream(allocator, value, .stdout, true);
}

const OutputStream = enum { stdout, stderr };

fn printJsonValueToStream(
    allocator: mem.Allocator,
    value: *const BencodeValue,
    which: OutputStream,
    trailing_newline: bool,
) !void {
    const json_value = try value.toJsonValue(allocator);
    var out: std.io.Writer.Allocating = .init(allocator);
    defer out.deinit();
    try json.Stringify.value(json_value, .{ .whitespace = .indent_2 }, &out.writer);
    switch (which) {
        .stdout => {
            if (trailing_newline) {
                try printStdOut("{s}\n", .{out.written()});
            } else {
                try printStdOut("{s}", .{out.written()});
            }
        },
        .stderr => {
            if (trailing_newline) {
                try printStdErr("{s}\n", .{out.written()});
            } else {
                try printStdErr("{s}", .{out.written()});
            }
        },
    }
}

fn printToggleResult(allocator: mem.Allocator, result: ToggleResult) !void {
    var object = json.ObjectMap.init(allocator);
    try object.put("requested-mode", .{ .string = result.requested_mode.asText() });
    try object.put("effective-mode", .{ .string = result.effective_mode.asText() });
    try object.put("action", .{ .string = result.action });
    try object.put("active-before", .{ .bool = result.active_before });
    try object.put("active", .{ .bool = result.active });
    if (result.generation_before) |generation_before| {
        try object.put("generation-before", .{ .integer = generation_before });
    }
    if (result.generation_after) |generation_after| {
        try object.put("generation-after", .{ .integer = generation_after });
    }

    var touched = json.Array.init(allocator);
    for (result.touched) |mapping| {
        var entry = json.ObjectMap.init(allocator);
        try entry.put("path", .{ .string = mapping.path });
        try entry.put("file-path", .{ .string = mapping.file_path });
        try touched.append(.{ .object = entry });
    }
    try object.put("touched", .{ .array = touched });

    const value = json.Value{ .object = object };
    var out: std.io.Writer.Allocating = .init(allocator);
    defer out.deinit();
    try json.Stringify.value(value, .{ .whitespace = .indent_2 }, &out.writer);
    try printStdOut("{s}\n", .{out.written()});
}

fn readFileAlloc(allocator: mem.Allocator, path: []const u8, max_bytes: usize) ![]u8 {
    if (std.fs.path.isAbsolute(path)) {
        const file = try std.fs.openFileAbsolute(path, .{});
        defer file.close();
        return try file.readToEndAlloc(allocator, max_bytes);
    }

    const file = try std.fs.cwd().openFile(path, .{});
    defer file.close();
    return try file.readToEndAlloc(allocator, max_bytes);
}

fn readFileText(allocator: mem.Allocator, path: []const u8, max_bytes: usize) ![]u8 {
    return try readFileAlloc(allocator, path, max_bytes);
}

fn findRepoRoot(allocator: mem.Allocator, cwd: []const u8) !?[]const u8 {
    if (std.process.getEnvVarOwned(allocator, "GHOSTTY_REPO")) |env_repo| {
        if (try looksLikeRepoRoot(allocator, env_repo)) return env_repo;
    } else |_| {}

    if (std.fs.selfExeDirPathAlloc(allocator)) |exe_dir| {
        if (try searchRepoRootFrom(allocator, exe_dir)) |repo_root| return repo_root;
    } else |_| {}

    return try searchRepoRootFrom(allocator, cwd);
}

fn searchRepoRootFrom(allocator: mem.Allocator, start: []const u8) !?[]const u8 {
    var current = start;
    while (true) {
        if (try looksLikeRepoRoot(allocator, current)) return current;
        const parent = std.fs.path.dirname(current) orelse return null;
        if (mem.eql(u8, parent, current)) return null;
        current = parent;
    }
}

fn looksLikeRepoRoot(allocator: mem.Allocator, candidate: []const u8) !bool {
    const build_zig = try std.fs.path.join(allocator, &.{ candidate, "build.zig" });
    std.fs.accessAbsolute(build_zig, .{}) catch return false;
    const src_dir = try std.fs.path.join(allocator, &.{ candidate, "src" });
    std.fs.accessAbsolute(src_dir, .{}) catch return false;
    const tools_dir = try std.fs.path.join(allocator, &.{ candidate, "tools" });
    std.fs.accessAbsolute(tools_dir, .{}) catch return false;
    return true;
}

fn printHelp() !void {
    const text =
        \\Usage:
        \\  hot_nrepl --op describe
        \\  hot_nrepl --op eval --code '1 + 2'
        \\  hot_nrepl --toggle toggle --toggle-probe-path src/input/mouse.zig \\
        \\    --toggle-active-code 'math.__hot_sample_math_overlay_active()' \\
        \\    --toggle-load src/math.zig=/tmp/math_overlay.zig
        \\
        \\Core options:
        \\  --addr HOST:PORT          Override the target address.
        \\  --port-file PATH          Read the port from a file (defaults to repo .nrepl-port).
        \\  --op NAME                 nREPL operation.
        \\  --session ID              Session id (default: root).
        \\  --scope NAME              Request scope.
        \\  --path PATH               Logical source path for in-file/load-file style requests.
        \\  --file-path PATH          File whose bytes should be sent as the request payload.
        \\  --code TEXT|-             Eval code; use - to read from stdin.
        \\  --generation N            Generation id for generation-bound requests.
        \\  --field KEY=VALUE         Extra string field; repeat as needed.
        \\  --int-field KEY=VALUE     Extra integer field; repeat as needed.
        \\  --timeout SECONDS         Socket timeout in seconds (default: 5.0).
        \\
        \\Toggle options:
        \\  --toggle MODE             One of: status, on, off, toggle.
        \\  --toggle-probe-path PATH  File context used to probe the marker decl.
        \\  --toggle-active-code CODE Probe code that should evaluate to true/false.
        \\  --toggle-load P=F         Load logical path P from file F; repeat as needed.
        \\  --toggle-restore P=F      Restore logical path P from file F; defaults to P=P.
    ;
    try printStdOut("{s}\n", .{text});
}

fn printStdOut(comptime fmt: []const u8, args: anytype) !void {
    var buffer: [4096]u8 = undefined;
    var writer_impl = std.fs.File.stdout().writer(&buffer);
    const writer = &writer_impl.interface;
    try writer.print(fmt, args);
    try writer.flush();
}

fn printStdErr(comptime fmt: []const u8, args: anytype) !void {
    var buffer: [4096]u8 = undefined;
    var writer_impl = std.fs.File.stderr().writer(&buffer);
    const writer = &writer_impl.interface;
    try writer.print(fmt, args);
    try writer.flush();
}

fn fail(comptime fmt: []const u8, args: anytype) Printed {
    printStdErr(fmt ++ "\n", args) catch {};
    return error.Printed;
}

test "encode and parse bencode dictionary" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const allocator = arena_state.allocator();

    const encoded = try encodeRequestDict(allocator, &.{
        .{ .key = "op", .value = .{ .string = "describe" } },
        .{ .key = "generation", .value = .{ .integer = 3 } },
    });
    const parsed = try parseBencode(allocator, encoded, 0);
    try std.testing.expectEqual(encoded.len, parsed.used);
    const op = parsed.value.dictGet("op") orelse return error.TestUnexpectedResult;
    try std.testing.expectEqualStrings("describe", op.bytesSlice().?);
    const generation = parsed.value.dictGet("generation") orelse return error.TestUnexpectedResult;
    try std.testing.expectEqual(@as(i64, 3), generation.integer);
}

test "responseFailed detects error status" {
    var status_items = [_]BencodeValue{
        .{ .bytes = "done" },
        .{ .bytes = "error" },
    };
    var dict_entries = [_]DictEntry{
        .{ .key = "status", .value = .{ .list = status_items[0..] } },
    };
    const response = BencodeValue{ .dict = dict_entries[0..] };
    try std.testing.expect(responseFailed(&response));
}
