// These wrappers intentionally call names that are provided by the live hot
// runtime during smoke tests.

fn ghosttyGetSubclass() i64 {
    return getSubclass();
}

fn tigerbeetleCommandVersion() i64 {
    return command_version(0, false);
}
