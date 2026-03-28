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

    pub fn clone(self: Object, alloc: std.mem.Allocator) anyerror!Object {
        return switch (self) {
            inline else => |obj| obj.clone(alloc),
        };
    }

    pub fn deinit(self: Object, alloc: std.mem.Allocator) void {
        return switch (self) {
            inline else => |obj| obj.deinit(alloc),
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

    fn clone(self: @This(), _: std.mem.Allocator) !Object {
        return .{ .integer = self };
    }

    fn deinit(_: @This(), _: std.mem.Allocator) void {}
};

pub const Boolean = struct {
    value: bool,

    fn inspect(self: @This(), out: *std.Io.Writer) !void {
        try out.print("{}", .{self.value});
    }

    fn clone(self: @This(), _: std.mem.Allocator) !Object {
        return .{ .boolean = self };
    }

    fn deinit(_: @This(), _: std.mem.Allocator) void {}
};

pub const ReturnValue = struct {
    value: *const Object,

    fn inspect(self: @This(), out: *std.Io.Writer) !void {
        try self.value.inspect(out);
    }

    fn clone(self: @This(), alloc: std.mem.Allocator) !Object {
        const cloned_val = try alloc.create(Object);
        cloned_val.* = self.value.clone(alloc);
        return .{ .return_val = .{ .value = cloned_val } };
    }

    fn deinit(self: @This(), alloc: std.mem.Allocator) void {
        self.value.deinit(alloc);
        alloc.destroy(self.value);
    }
};

pub const Environment = struct {
    alloc: std.mem.Allocator,
    store: *std.StringHashMapUnmanaged(Object),

    pub fn init(alloc: std.mem.Allocator) !Environment {
        const env = Environment{
            .alloc = alloc,
            .store = try alloc.create(std.StringHashMapUnmanaged(Object)),
        };
        env.store.* = std.StringHashMapUnmanaged(Object).empty;

        return env;
    }

    pub fn deinit(self: @This(), _: std.mem.Allocator) void {
        var iter = self.store.iterator();
        while (iter.next()) |entry| {
            entry.value_ptr.deinit(self.alloc);
            self.alloc.free(entry.key_ptr.*);
        }

        self.store.deinit(self.alloc);
        self.alloc.destroy(self.store);
    }

    pub fn get(self: *@This(), name: []const u8) ?Object {
        return self.store.get(name);
    }

    pub fn set(self: *@This(), name: []const u8, val: Object) !Object {
        try self.store.put(self.alloc, try self.alloc.dupe(u8, name), val);
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

    fn clone(_: @This(), _: std.mem.Allocator) !Object {
        @panic("not allowed");
    }
};

pub const Error = struct {
    message: []const u8,

    fn inspect(self: @This(), out: *std.Io.Writer) !void {
        try out.print("ERROR: {s}", .{self.message});
    }

    fn clone(self: @This(), alloc: std.mem.Allocator) !Object {
        return .{ .err = .{
            .message = alloc.dupe(u8, self.message),
        } };
    }

    fn deinit(self: @This(), alloc: std.mem.Allocator) void {
        alloc.free(self.message);
    }
};

pub const Nil = struct {
    fn inspect(_: @This(), out: *std.Io.Writer) !void {
        _ = try out.write("nil");
    }

    fn clone(self: @This(), _: std.mem.Allocator) !Object {
        return .{ .nil = self.* };
    }

    fn deinit(_: @This(), _: std.mem.Allocator) void {}
};
