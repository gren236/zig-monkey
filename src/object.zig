const std = @import("std");

pub const ObjectType = enum {
    integer,
    boolean,
    nil,
    return_val,
    err,
};

pub const Object = union(ObjectType) {
    integer: Integer,
    boolean: Boolean,
    nil: Nil,
    return_val: ReturnValue,
    err: Error,

    pub fn inspect(self: Object, out: *std.Io.Writer) anyerror!void {
        return switch (self) {
            inline else => |obj| obj.inspect(out),
        };
    }

    pub fn tagName(self: Object) []const u8 {
        return switch (self) {
            .integer => "INTEGER",
            .boolean => "BOOLEAN",
            .nil => "NIL",
            .return_val => "RETURN_VALUE",
            .err => "ERROR",
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

pub const Error = struct {
    message: []const u8,

    fn inspect(self: @This(), out: *std.Io.Writer) !void {
        try out.print("ERROR: {s}", .{self.message});
    }
};

pub const Nil = struct {
    fn inspect(_: @This(), out: *std.Io.Writer) !void {
        _ = try out.write("nil");
    }
};
