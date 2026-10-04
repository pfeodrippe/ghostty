//! Code taken from 0.15.2 `std.testing`. See README.md for license and
//! details.
const builtin = @import("builtin");
const std = @import("std");

/// Given a type, recursively references all the declarations inside, so that the semantic analyzer sees them.
/// For deep types, you may use `@setEvalBranchQuota`.
pub fn refAllDeclsRecursive(comptime T: type) void {
    if (!builtin.is_test) return;
    inline for (comptime std.meta.declarations(T)) |name| {
        if (@TypeOf(@field(T, name)) == type) {
            switch (@typeInfo(@field(T, name))) {
                .@"struct", .@"enum", .@"union", .@"opaque" => refAllDeclsRecursive(@field(T, name)),
                else => {},
            }
        }
        _ = &@field(T, name);
    }
}
