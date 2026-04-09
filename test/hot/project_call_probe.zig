// These wrappers intentionally call real project code so smoke tests can probe
// downstream hot behavior without modifying app sources.

const global = @import("../../src/global.zig");
const main_c = @import("../../src/main_c.zig");
fn ghosttyGetSubclass() i64 {
    return getSubclass();
}

fn ghosttyGlobalStateActionProbe() i64 {
    return if (global.state.action == null) 7 else 0;
}

fn ghosttyInitStateProbe() i64 {
    return @as(i64, @intCast(main_c.ghostty_init(0, @ptrFromInt(0))));
}

fn ghosttyConfigOpenPathProbe() i64 {
    return if (@intFromPtr(global.state.alloc.vtable) != 0) 7 else 0;
}

fn tigerbeetleCommandVersion() i64 {
    return command_version(0, false);
}
