const std = @import("std");

pub const ObjectType = enum {
    integer,
    boolean,
    nil,
    return_val,
    err,
    env,
};

pub const Object = union(ObjectType) {
    integer: Integer,
    boolean: Boolean,
    nil: Nil,
    return_val: ReturnValue,
    err: Error,
    env: Environment,

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
            .env => "ENVIRONMENT",
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

pub const Environment = struct {
    alloc: std.mem.Allocator,
    store: std.StringHashMapUnmanaged(Object),

    pub fn init(alloc: std.mem.Allocator) Environment {
        return .{
            .alloc = alloc,
            .store = std.StringHashMapUnmanaged(Object).empty,
        };
    }

    pub fn deinit(self: *@This()) void {
        var iter = self.store.keyIterator();
        while (iter.next()) |key| {
            self.alloc.free(key.*);
        }

        self.store.deinit(self.alloc);
    }

    pub fn get(self: *@This(), name: []const u8) ?Object {
        return self.store.get(name);
    }

    pub fn set(self: *@This(), name: []const u8, val: Object) !Object {
        const new_name = try self.alloc.alloc(u8, name.len);
        @memcpy(new_name, name);

        try self.store.put(self.alloc, new_name, val);
        return val;
    }

    fn inspect(self: @This(), out: *std.Io.Writer) !void {
        if (self.store.size == 0) return;

        var iter = self.store.iterator();
        while (iter.next()) |entry| {
            try out.print("{s}: ", .{entry.key_ptr.*});
            try entry.value_ptr.inspect(out);
            _ = try out.write("\n");
        }
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
