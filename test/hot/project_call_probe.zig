// These wrappers intentionally call real project code so smoke tests can probe
// downstream hot behavior without modifying app sources.

const std = @import("std");
const apprt = @import("../../src/apprt.zig");
const action = @import("../../src/apprt/action.zig");
const split_tree = @import("../../src/datastruct/split_tree.zig");
const global = @import("../../src/global.zig");
const main_c = @import("../../src/main_c.zig");

const HotDummyView = struct {
    value: i64 = 0,

    fn ref(view: *HotDummyView, _: std.mem.Allocator) std.mem.Allocator.Error!*HotDummyView {
        view.value += 1;
        return view;
    }

    fn unref(view: *HotDummyView, _: std.mem.Allocator) void {
        view.value -= 1;
    }

    fn eql(left: *const HotDummyView, right: *const HotDummyView) bool {
        return left == right;
    }
};

const HotDummyTree = split_tree.SplitTree(HotDummyView);

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

fn ghosttySizeLimitWrapperProbe() i64 {
    const limit: action.SizeLimit = .{
        .min_width = 1,
        .min_height = 2,
        .max_width = 9,
        .max_height = 11,
    };
    return @as(i64, @intCast(limit.max_width + limit.max_height - limit.min_width - limit.min_height));
}

fn ghosttyClipboardRequestWrapperProbe() i64 {
    const req: apprt.ClipboardRequest = .{ .osc_52_write = .selection };
    return @as(i64, @intFromEnum(req.osc_52_write));
}

fn ghosttySplitTreeCleanupWrapperProbe() i64 {
    var view: HotDummyView = .{};
    var tree = HotDummyTree.init(std.heap.page_allocator, &view) catch return -1;
    defer tree.deinit();
    return @as(i64, @intCast(tree.nodes.len + @as(usize, @intCast(view.value))));
}

fn ghosttySplitTreeNestedMethodProbe() i64 {
    return @as(i64, @intCast(HotDummyTree.Node.Handle.idx(.root))) + 1;
}
