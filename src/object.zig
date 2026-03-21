const std = @import("std");

pub const ObjectType = enum {
    integer,
    boolean,
    nil,
};

pub const Object = union(ObjectType) {
    integer: Integer,
    boolean: Boolean,
    nil: Nil,

    fn inspect(self: Object, buf: []u8) !usize {
        return switch (self) {
            inline else => |obj| obj.inspect(buf),
        };
    }
};

pub const Integer = struct {
    value: i64,

    fn inspect(self: *@This(), buf: []u8) !usize {
        return std.fmt.printInt(buf, self.value, 10, .lower, .{});
    }
};

pub const Boolean = struct {
    value: bool,

    fn inspect(self: *@This(), buf: []u8) !usize {
        return (try std.fmt.bufPrint(buf, "{}", .{self.value})).len;
    }
};

pub const Nil = struct {
    fn inspect(_: *@This(), buf: []u8) !usize {
        try std.fmt.bufPrint(buf, "nil", .{});
        return 3;
    }
};
