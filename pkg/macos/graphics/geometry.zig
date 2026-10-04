const std = @import("std");
const assert = std.debug.assert;
const c = @import("c.zig").c;

pub const Point = extern struct {
    x: c.CGFloat,
    y: c.CGFloat,
};

pub const Rect = extern struct {
    origin: Point,
    size: Size,

    pub fn init(x: f64, y: f64, width: f64, height: f64) Rect {
        return fromC(c.CGRectMake(x, y, width, height));
    }

    pub fn fromC(rect: c.CGRect) Rect {
        return .{
            .origin = .{ .x = rect.origin.x, .y = rect.origin.y },
            .size = .{ .width = rect.size.width, .height = rect.size.height },
        };
    }

    pub fn toC(self: Rect) c.CGRect {
        return .{
            .origin = .{ .x = self.origin.x, .y = self.origin.y },
            .size = .{ .width = self.size.width, .height = self.size.height },
        };
    }

    pub fn isNull(self: Rect) bool {
        return c.CGRectIsNull(self.toC());
    }

    pub fn getHeight(self: Rect) c.CGFloat {
        return c.CGRectGetHeight(self.toC());
    }

    pub fn getWidth(self: Rect) c.CGFloat {
        return c.CGRectGetWidth(self.toC());
    }
};

pub const Size = extern struct {
    width: c.CGFloat,
    height: c.CGFloat,
};
