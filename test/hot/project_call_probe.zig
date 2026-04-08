// These wrappers intentionally call names that are provided by the live hot
// runtime during smoke tests.

fn ghosttyGetSubclass() i64 {
    return getSubclass();
}

fn ghosttyInitStateProbe() i64 {
    return @as(i64, @intCast(ghostty_init(0, @ptrFromInt(0))));
}

fn tigerbeetleCommandVersion() i64 {
    return command_version(0, false);
}
