const std = @import("std");
const assert = std.debug.assert;
const c = @import("c.zig").c;

pub const AffineTransform = extern struct {
    a: c.CGFloat,
    b: c.CGFloat,
    c: c.CGFloat,
    d: c.CGFloat,
    tx: c.CGFloat,
    ty: c.CGFloat,

    pub fn identity() AffineTransform {
        const matrix = c.CGAffineTransformIdentity;
        return .{
            .a = matrix.a,
            .b = matrix.b,
            .c = matrix.c,
            .d = matrix.d,
            .tx = matrix.tx,
            .ty = matrix.ty,
        };
    }

    pub fn toC(self: AffineTransform) c.CGAffineTransform {
        return .{
            .a = self.a,
            .b = self.b,
            .c = self.c,
            .d = self.d,
            .tx = self.tx,
            .ty = self.ty,
        };
    }
};
