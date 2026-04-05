const std = @import("std");
const ast = @import("ast.zig");

const BuiltinFunction = *const fn (alloc: std.mem.Allocator, args: []Object) anyerror!Object;

pub const ObjectType = enum {
    integer,
    boolean,
    nil,
    return_val,
    err,
    env,
    func,
    string,
    builtin,
};

pub const Object = union(ObjectType) {
    integer: Integer,
    boolean: Boolean,
    nil: Nil,
    return_val: ReturnValue,
    err: Error,
    env: Environment,
    func: Function,
    string: String,
    builtin: Builtin,

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
            .func => "FUNCTION",
            .string => "STRING",
            .builtin => "BUILTIN",
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
        cloned_val.* = try self.value.clone(alloc);
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
    outer: ?*const Environment,

    pub fn init(alloc: std.mem.Allocator) !Environment {
        const env = Environment{
            .alloc = alloc,
            .store = try alloc.create(std.StringHashMapUnmanaged(Object)),
            .outer = null,
        };
        env.store.* = std.StringHashMapUnmanaged(Object).empty;

        return env;
    }

    pub fn initEnclosed(outer: *const Environment) !Environment {
        var env = try Environment.init(outer.alloc);
        env.outer = outer;

        return env;
    }

    pub fn deinit(self: @This(), _: std.mem.Allocator) void {
        var iter = self.store.iterator();
        while (iter.next()) |entry| {
            entry.value_ptr.*.deinit(self.alloc);
            self.alloc.free(entry.key_ptr.*);
        }

        self.store.deinit(self.alloc);
        self.alloc.destroy(self.store);
    }

    fn clone(self: @This(), alloc: std.mem.Allocator) !Object {
        var new_env = try Environment.init(alloc);
        try new_env.store.ensureTotalCapacity(alloc, self.store.capacity());

        var iter = self.store.iterator();
        while (iter.next()) |entry| {
            try new_env.store.put(
                alloc,
                try alloc.dupe(u8, entry.key_ptr.*),
                try entry.value_ptr.clone(alloc),
            );
        }

        return .{ .env = new_env };
    }

    pub fn get(self: @This(), name: []const u8) ?Object {
        const obj_opt = self.store.get(name);
        if (obj_opt) |obj| {
            return obj;
        }

        if (self.outer) |outer| {
            return outer.get(name);
        }

        return null;
    }

    pub fn set(self: @This(), name: []const u8, val: Object) !Object {
        try self.store.put(self.alloc, try self.alloc.dupe(u8, name), try val.clone(self.alloc));
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

pub const Function = struct {
    parameters: []ast.Identifier,
    body: ast.BlockStatement,
    env: *const Environment,

    pub fn init(alloc: std.mem.Allocator, params: []ast.Identifier, body: ast.BlockStatement, env: *Environment) !Function {
        var new_params = try alloc.alloc(ast.Identifier, params.len);
        for (0.., params) |i, param| {
            new_params[i] = (try param.clone(alloc)).val.ident;
        }

        return .{
            .parameters = new_params,
            .body = (try body.clone(alloc)).val.block_stmt,
            .env = env,
        };
    }

    fn inspect(self: @This(), out: *std.Io.Writer) !void {
        _ = try out.write("fn(");
        for (0.., self.parameters) |i, param| {
            if (i != 0) _ = try out.write(", ");
            try param.writeString(out);
        }
        _ = try out.write(") {\n");
        try self.body.writeString(out);
        _ = try out.write("\n}");
    }

    fn clone(self: @This(), alloc: std.mem.Allocator) !Object {
        var new_params = try alloc.alloc(ast.Identifier, self.parameters.len);
        for (0.., self.parameters) |i, param| {
            new_params[i] = (try param.clone(alloc)).val.ident;
        }

        const new_body = (try self.body.clone(alloc)).val.block_stmt;

        const new_env = try alloc.create(Environment);
        new_env.* = (try self.env.clone(alloc)).env;

        return .{ .func = .{
            .parameters = new_params,
            .body = new_body,
            .env = new_env,
        } };
    }

    fn deinit(self: @This(), alloc: std.mem.Allocator) void {
        for (self.parameters) |param| {
            param.deinit(alloc);
        }
        alloc.free(self.parameters);

        self.body.deinit(alloc);
        self.env.deinit(alloc);
        alloc.destroy(self.env);
    }
};

pub const String = struct {
    value: []const u8,

    pub fn init(alloc: std.mem.Allocator, value: []const u8) !String {
        return .{
            .value = try alloc.dupe(u8, value),
        };
    }

    fn clone(self: @This(), alloc: std.mem.Allocator) !Object {
        return .{ .string = .{
            .value = try alloc.dupe(u8, self.value),
        } };
    }

    fn deinit(self: @This(), alloc: std.mem.Allocator) void {
        alloc.free(self.value);
    }

    fn inspect(self: @This(), out: *std.Io.Writer) !void {
        _ = try out.write(self.value);
    }
};

pub const Builtin = struct {
    func: BuiltinFunction,

    fn clone(self: @This(), _: std.mem.Allocator) !Object {
        return .{ .builtin = self };
    }

    fn deinit(_: @This(), _: std.mem.Allocator) void {}

    fn inspect(_: @This(), out: *std.Io.Writer) !void {
        _ = try out.write("builtin function");
    }
};

pub const Error = struct {
    message: []const u8,

    fn inspect(self: @This(), out: *std.Io.Writer) !void {
        try out.print("ERROR: {s}", .{self.message});
    }

    fn clone(self: @This(), alloc: std.mem.Allocator) !Object {
        return .{ .err = .{
            .message = try alloc.dupe(u8, self.message),
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
        return .{ .nil = self };
    }

    fn deinit(_: @This(), _: std.mem.Allocator) void {}
};
