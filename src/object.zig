const std = @import("std");

pub const ObjectType = enum {
    integer,
    boolean,
    nil,
    return_val,
};

pub const Object = union(ObjectType) {
    integer: Integer,
    boolean: Boolean,
    nil: Nil,
    return_val: ReturnValue,

    pub fn inspect(self: Object, out: *std.Io.Writer) anyerror!void {
        return switch (self) {
            inline else => |obj| obj.inspect(out),
        };
    }
};

pub const Integer = struct {
    value: i64,

    fn inspect(self: @This(), out: *std.Io.Writer) !void {
        try out.printInt(self.value, 10, .lower, .{});
    }
};

pub const Boolean = struct {
    value: bool,

    fn inspect(self: @This(), out: *std.Io.Writer) !void {
        try out.print("{}", .{self.value});
    }
};

pub const ReturnValue = struct {
    value: *const Object,

    fn inspect(self: @This(), out: *std.Io.Writer) !void {
        try self.value.inspect(out);
    }
};

pub const Nil = struct {
    fn inspect(_: @This(), out: *std.Io.Writer) !void {
        _ = try out.write("nil");
    }
};
