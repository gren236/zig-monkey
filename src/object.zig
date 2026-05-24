const std = @import("std");
const ast = @import("ast.zig");
const code = @import("code.zig");

pub const ObjectType = enum {
    integer,
    boolean,
    nil,
    return_val,
    err,
    env,
    func,
    comp_func,
    closure,
    string,
    builtin,
    array,
    hash,
};

pub const Object = union(ObjectType) {
    integer: Integer,
    boolean: Boolean,
    nil: Nil,
    return_val: ReturnValue,
    err: Error,
    env: Environment,
    func: Function,
    comp_func: CompiledFunction,
    closure: Closure,
    string: String,
    builtin: Builtin,
    array: Array,
    hash: Hash,

    pub fn toHashable(self: Object) !Hashable {
        return switch (self) {
            .integer => |int| .{ .integer = int },
            .boolean => |obj| .{ .boolean = obj },
            .string => |str| .{ .string = str },
            else => error.NotHashable,
        };
    }

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
            .array => "ARRAY",
            .hash => "HASH",
            .comp_func => "COMPILED_FUNCTION",
            .closure => "CLOSURE",
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

    fn hashKey(self: @This()) u64 {
        return @intCast(self.value);
    }

    fn eql(self: @This(), other: Hashable) bool {
        return switch (other) {
            .string => false,
            .boolean => false,
            .integer => |int| self.value == int.value,
        };
    }
};

pub const Boolean = struct {
    value: bool,

    fn clone(self: @This(), _: std.mem.Allocator) !Object {
        return .{ .boolean = self };
    }

    fn deinit(_: @This(), _: std.mem.Allocator) void {}

    fn inspect(self: @This(), out: *std.Io.Writer) !void {
        try out.print("{}", .{self.value});
    }

    fn hashKey(self: @This()) u64 {
        return @intFromBool(self.value);
    }

    fn eql(self: @This(), other: Hashable) bool {
        return switch (other) {
            .string => false,
            .integer => false,
            .boolean => |obj| self.value == obj.value,
        };
    }
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

pub const CompiledFunction = struct {
    instructions: code.Instructions,
    num_locals: usize,
    num_parameters: usize,

    pub fn init(alloc: std.mem.Allocator, instructions: code.Instructions, num_locals: usize, num_params: usize) !CompiledFunction {
        return .{
            .instructions = try alloc.dupe(u8, instructions),
            .num_locals = num_locals,
            .num_parameters = num_params,
        };
    }

    fn clone(self: @This(), alloc: std.mem.Allocator) !Object {
        return .{ .comp_func = .{
            .instructions = try alloc.dupe(u8, self.instructions),
            .num_locals = self.num_locals,
            .num_parameters = self.num_parameters,
        } };
    }

    fn deinit(self: @This(), alloc: std.mem.Allocator) void {
        alloc.free(self.instructions);
    }

    fn inspect(self: @This(), out: *std.Io.Writer) !void {
        _ = try out.write("CompiledFunction[");
        try code.writeInstructions(self.instructions, out);
        _ = try out.write("]");
    }
};

pub const Closure = struct {
    func: *const CompiledFunction,
    free: []Object,

    pub fn init(alloc: std.mem.Allocator, func: *const CompiledFunction, free: []const Object) !Closure {
        const func_ptr = try alloc.create(CompiledFunction);
        func_ptr.* = (try func.clone(alloc)).comp_func;

        var free_new = try alloc.alloc(Object, free.len);
        for (free, 0..free.len) |obj, i| {
            free_new[i] = try obj.clone(alloc);
        }

        return .{
            .func = func_ptr,
            .free = free_new,
        };
    }

    fn clone(self: @This(), alloc: std.mem.Allocator) !Object {
        return .{ .closure = try Closure.init(alloc, self.func, self.free) };
    }

    fn deinit(self: @This(), alloc: std.mem.Allocator) void {
        self.func.deinit(alloc);
        alloc.destroy(self.func);

        for (self.free) |obj| {
            obj.deinit(alloc);
        }
        alloc.free(self.free);
    }

    fn inspect(self: @This(), out: *std.Io.Writer) !void {
        try out.print("Closure[{}]", .{self});
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

    fn hashKey(self: @This()) u64 {
        return std.hash_map.hashString(self.value);
    }

    fn eql(self: @This(), other: Hashable) bool {
        return switch (other) {
            .integer => false,
            .boolean => false,
            .string => |str| std.mem.eql(u8, self.value, str.value),
        };
    }
};

pub const BuiltinFunction = *const fn (alloc: std.mem.Allocator, args: []Object) anyerror!Object;

pub fn lenBuiltin(alloc: std.mem.Allocator, args: []Object) !Object {
    if (args.len != 1) return try newError(alloc, "wrong number of arguments. got={d}, want=1", .{args.len});

    return switch (args[0]) {
        .string => |str| Object{ .integer = .{ .value = @intCast(str.value.len) } },
        .array => |arr| Object{ .integer = .{ .value = @intCast(arr.elements.len) } },
        else => try newError(alloc, "argument to `len` not supported, got {s}", .{args[0].tagName()}),
    };
}

pub fn firstBuiltin(alloc: std.mem.Allocator, args: []Object) !Object {
    if (args.len != 1) return try newError(alloc, "wrong number of arguments. got={d}, want=1", .{args.len});
    if (@as(ObjectType, args[0]) != .array)
        return try newError(alloc, "argument to `first` must be ARRAY, got {s}", .{args[0].tagName()});

    const elems = args[0].array.elements;
    if (elems.len > 0) return elems[0];

    return nil;
}

pub fn lastBuiltin(alloc: std.mem.Allocator, args: []Object) !Object {
    if (args.len != 1) return try newError(alloc, "wrong number of arguments. got={d}, want=1", .{args.len});
    if (@as(ObjectType, args[0]) != .array)
        return try newError(alloc, "argument to `last` must be ARRAY, got {s}", .{args[0].tagName()});

    const elems = args[0].array.elements;
    if (elems.len > 0) return elems[elems.len - 1];

    return nil;
}

pub fn restBuiltin(alloc: std.mem.Allocator, args: []Object) !Object {
    if (args.len != 1) return try newError(alloc, "wrong number of arguments. got={d}, want=1", .{args.len});
    if (@as(ObjectType, args[0]) != .array)
        return try newError(alloc, "argument to `rest` must be ARRAY, got {s}", .{args[0].tagName()});

    const elems = args[0].array.elements;
    if (elems.len > 0) {
        return Object{ .array = try Array.init(alloc, elems[1..]) };
    }

    return nil;
}

pub fn pushBuiltin(alloc: std.mem.Allocator, args: []Object) !Object {
    if (args.len != 2) return try newError(alloc, "wrong number of arguments. got={d}, want=2", .{args.len});
    if (@as(ObjectType, args[0]) != .array)
        return try newError(alloc, "argument to `push` must be ARRAY, got {s}", .{args[0].tagName()});

    const elems = args[0].array.elements;
    return .{ .array = .{
        .elements = try std.mem.concat(
            alloc,
            Object,
            &[2][]const Object{ elems, &[_]Object{args[1]} },
        ),
    } };
}

pub fn putsBuiltin(alloc: std.mem.Allocator, args: []Object) !Object {
    if (args.len == 0) return nil;

    var buf: [1024]u8 = undefined;
    var threaded: std.Io.Threaded = .init(alloc, .{});
    var out_writer = std.Io.File.stdout().writer(threaded.io(), &buf);
    var writer = &out_writer.interface;
    for (args) |arg| {
        try arg.inspect(writer);
        _ = try writer.write("\n");
        try writer.flush();
    }

    return nil;
}

pub const BuiltinFnIdent = enum(u8) {
    len,
    first,
    last,
    rest,
    push,
    puts,

    pub fn getObjectByName(ident: []const u8) ?Object {
        const ident_name = std.meta.stringToEnum(@This(), ident) orelse return null;

        return ident_name.getObject();
    }

    pub fn getObject(self: @This()) Object {
        return Object{ .builtin = .{
            .func = switch (self) {
                .len => lenBuiltin,
                .first => firstBuiltin,
                .last => lastBuiltin,
                .rest => restBuiltin,
                .push => pushBuiltin,
                .puts => putsBuiltin,
            },
        } };
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

pub const Array = struct {
    elements: []Object,

    pub fn init(alloc: std.mem.Allocator, elements: []Object) !Array {
        var new_elems = try alloc.alloc(Object, elements.len);
        for (0.., elements) |i, obj| {
            new_elems[i] = try obj.clone(alloc);
        }

        return .{
            .elements = new_elems,
        };
    }

    fn inspect(self: @This(), out: *std.Io.Writer) !void {
        _ = try out.write("[");
        for (0.., self.elements) |i, obj| {
            if (i != 0) _ = try out.write(", ");
            try obj.inspect(out);
        }
        _ = try out.write("]");
    }

    fn clone(self: @This(), alloc: std.mem.Allocator) !Object {
        return .{ .array = try Array.init(alloc, self.elements) };
    }

    fn deinit(self: @This(), alloc: std.mem.Allocator) void {
        for (self.elements) |obj| {
            obj.deinit(alloc);
        }
        alloc.free(self.elements);
    }
};

pub const Hashable = union(enum) {
    integer: Integer,
    boolean: Boolean,
    string: String,

    pub fn toObject(self: Hashable) Object {
        return switch (self) {
            .integer => |obj| Object{ .integer = obj },
            .boolean => |obj| Object{ .boolean = obj },
            .string => |obj| Object{ .string = obj },
        };
    }

    pub fn hashKey(self: Hashable) u64 {
        return switch (self) {
            inline else => |obj| obj.hashKey(),
        };
    }

    pub fn eql(self: Hashable, other: Hashable) bool {
        return switch (self) {
            inline else => |obj| obj.eql(other),
        };
    }
};

pub const HashMapContext = struct {
    pub fn hash(_: @This(), key: Hashable) u64 {
        return key.hashKey();
    }

    pub fn eql(_: @This(), a: Hashable, b: Hashable) bool {
        return a.eql(b);
    }
};

pub const HashMap = std.HashMapUnmanaged(
    Hashable,
    Object,
    HashMapContext,
    std.hash_map.default_max_load_percentage,
);

pub const Hash = struct {
    pairs: HashMap,

    fn clone(self: @This(), alloc: std.mem.Allocator) !Object {
        var new = Hash{
            .pairs = HashMap.empty,
        };
        try new.pairs.ensureTotalCapacity(alloc, self.pairs.size);

        var iter = self.pairs.iterator();
        while (iter.next()) |entry| {
            try new.pairs.put(
                alloc,
                try (try entry.key_ptr.toObject().clone(alloc)).toHashable(),
                try entry.value_ptr.clone(alloc),
            );
        }

        return .{ .hash = new };
    }

    fn deinit(self: @This(), alloc: std.mem.Allocator) void {
        var iter = self.pairs.iterator();
        while (iter.next()) |entry| {
            entry.key_ptr.toObject().deinit(alloc);
            entry.value_ptr.deinit(alloc);
        }
        var pairs = self.pairs;
        pairs.deinit(alloc);
    }

    fn inspect(self: @This(), out: *std.Io.Writer) !void {
        _ = try out.write("{");
        var iter = self.pairs.iterator();
        var i: usize = 0;
        while (iter.next()) |entry| {
            if (i != 0) _ = try out.write(", ");

            try entry.key_ptr.toObject().inspect(out);
            _ = try out.write(": ");
            try entry.value_ptr.inspect(out);

            i += 1;
        }
        _ = try out.write("}");
    }
};

pub fn newError(alloc: std.mem.Allocator, comptime format: []const u8, args: anytype) !Object {
    return Object{
        .err = .{ .message = try std.fmt.allocPrint(alloc, format, args) },
    };
}

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

pub const nil = Object{ .nil = .{} };

pub const Nil = struct {
    fn inspect(_: @This(), out: *std.Io.Writer) !void {
        _ = try out.write("nil");
    }

    fn clone(self: @This(), _: std.mem.Allocator) !Object {
        return .{ .nil = self };
    }

    fn deinit(_: @This(), _: std.mem.Allocator) void {}
};
