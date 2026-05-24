const std = @import("std");

const ast = @import("ast.zig");
const code = @import("code.zig");
const Compiler = @import("compiler.zig");
const Lexer = @import("lexer.zig");
const object = @import("object.zig");
const Parser = @import("parser.zig");

const Self = @This();

pub const Error = error{
    UnknownOpcode,
    StackOverflow,
    StackExhausted,
    UnsupportedOperationTypes,
    UnsupportedOperator,
    UnsupportedIndexOperator,
    CallingNonFunction,
    WrongNumberOfArgs,
    BuiltinNotFound,
    NotAFunction,
};

const Frame = struct {
    cl: object.Closure,
    ip: isize,
    base_pointer: usize,

    fn init(cl: object.Closure, base_pointer: usize) Frame {
        return .{
            .cl = cl,
            .ip = -1,
            .base_pointer = base_pointer,
        };
    }

    fn instructions(self: *const Frame) code.Instructions {
        return self.cl.func.instructions;
    }
};

const stack_size = 2048;
const globals_size = 65536;
const max_frames = 1024;

const string_arena_size = 1024 * 1024 * 5; // 5mb
const array_arena_size = 1024 * 1024 * 5; // 5mb
const hash_arena_size = 1024 * 1024 * 5; // 5mb
const builtins_arena_size = 1024 * 1024 * 5; // 5mb

const true_obj: object.Object = .{ .boolean = .{ .value = true } };
const false_obj: object.Object = .{ .boolean = .{ .value = false } };
const nil: object.Object = .{ .nil = .{} };

stack: [stack_size]object.Object,
sp: usize, // Always points to the next value. Top of stack is stack[sp-1]
globals: [globals_size]object.Object,
string_arena: [string_arena_size]u8,
string_fba: std.heap.FixedBufferAllocator,
array_arena: [array_arena_size]u8,
array_fba: std.heap.FixedBufferAllocator,
hash_arena: [hash_arena_size]u8,
hash_fba: std.heap.FixedBufferAllocator,
builtins_arena: [builtins_arena_size]u8,
builtins_fba: std.heap.FixedBufferAllocator,

frames: [max_frames]Frame,
frames_index: usize,

pub fn create(alloc: std.mem.Allocator) !*Self {
    const self = try alloc.create(Self);

    self.* = .{
        .stack = @splat(nil),
        .sp = 0,

        .globals = @splat(nil),
        .frames = @splat(undefined),
        .frames_index = 0,

        .string_arena = undefined,
        .string_fba = undefined,
        .array_arena = undefined,
        .array_fba = undefined,
        .hash_arena = undefined,
        .hash_fba = undefined,
        .builtins_arena = undefined,
        .builtins_fba = undefined,
    };

    self.string_fba = .init(&self.string_arena);
    self.array_fba = .init(&self.array_arena);
    self.hash_fba = .init(&self.hash_arena);
    self.builtins_fba = .init(&self.builtins_arena);

    return self;
}

pub fn destroy(self: *Self, alloc: std.mem.Allocator) void {
    alloc.destroy(self);
}

fn currentFrame(self: *Self) *Frame {
    return &self.frames[self.frames_index - 1];
}

fn pushFrame(self: *Self, f: Frame) void {
    self.frames[self.frames_index] = f;
    self.frames_index += 1;
}

fn popFrame(self: *Self) Frame {
    self.frames_index -= 1;
    return self.frames[self.frames_index];
}

pub fn run(self: *Self, bytecode: Compiler.Bytecode) !void {
    const runFunc: object.CompiledFunction = object.CompiledFunction{
        .instructions = bytecode.instructions,
        .num_locals = 0,
        .num_parameters = 0,
    };

    self.pushFrame(.init(object.Closure{ .func = &runFunc, .free = &.{} }, 0));

    while (self.currentFrame().ip < self.currentFrame().instructions().len - 1) {
        self.currentFrame().ip += 1;

        const ip: usize = @intCast(self.currentFrame().ip);
        const ins = self.currentFrame().instructions();

        const op = std.enums.fromInt(code.Opcode, ins[ip]) orelse
            return Error.UnknownOpcode;

        switch (op) {
            .constant => {
                const width = 2;
                const const_index = code.readOperandInt(width, ins[ip + 1 ..][0..width]);
                self.currentFrame().ip += width;

                try self.push(bytecode.constants[const_index]);
            },
            .add, .sub, .mul, .div => try self.executeBinaryOperation(op),
            .true => try self.push(true_obj),
            .false => try self.push(false_obj),
            .equal, .not_equal, .greater_than => try self.executeComparison(op),
            .bang => try self.executeBangOperator(),
            .minus => try self.executeMinusOperator(),
            .pop => _ = self.pop(),
            .jump => {
                const width = 2;
                const pos = code.readOperandInt(width, ins[ip + 1 ..][0..width]);

                self.currentFrame().ip = @intCast(pos - 1);
            },
            .jump_not_truthy => {
                const width = 2;
                const pos = code.readOperandInt(width, ins[ip + 1 ..][0..width]);
                self.currentFrame().ip += width;

                const condition = self.pop() orelse return Error.StackExhausted;
                if (!isTruthy(condition)) self.currentFrame().ip = @intCast(pos - 1);
            },
            .set_global => {
                const width = 2;
                const global_index = code.readOperandInt(width, ins[ip + 1 ..][0..width]);
                self.currentFrame().ip += width;

                self.globals[global_index] = self.pop() orelse nil;
            },
            .get_global => {
                const width = 2;
                const global_index = code.readOperandInt(width, ins[ip + 1 ..][0..width]);
                self.currentFrame().ip += width;

                try self.push(self.globals[global_index]);
            },
            .array => {
                const width = 2;
                const num_elements = code.readOperandInt(width, ins[ip + 1 ..][0..width]);
                self.currentFrame().ip += width;

                const array = try self.buildArray(self.sp - num_elements, self.sp);
                self.sp = self.sp - num_elements;

                try self.push(array);
            },
            .hash => {
                const width = 2;
                const num_elements = code.readOperandInt(width, ins[ip + 1 ..][0..width]);
                self.currentFrame().ip += width;

                const hash = try self.buildHash(self.sp - num_elements, self.sp);
                self.sp = self.sp - num_elements;

                try self.push(hash);
            },
            .index => {
                const index = self.pop() orelse return Error.StackExhausted;
                const left = self.pop() orelse return Error.StackExhausted;

                try self.executeIndexExpression(left, index);
            },
            .call => {
                const width = 1;
                const num_args = code.readOperandInt(width, ins[ip + 1 ..][0..width]);
                self.currentFrame().ip += width;

                try self.executeCall(num_args);
            },
            .return_value => {
                const return_val = self.pop() orelse return Error.StackExhausted;

                const frame = self.popFrame();
                self.sp = frame.base_pointer - 1;

                try self.push(return_val);
            },
            .@"return" => {
                const frame = self.popFrame();
                self.sp = frame.base_pointer - 1;

                try self.push(nil);
            },
            .set_local => {
                const width = 1;
                const local_index = code.readOperandInt(width, ins[ip + 1 ..][0..width]);
                self.currentFrame().ip += width;

                const frame = self.currentFrame();

                self.stack[frame.base_pointer + local_index] = self.pop() orelse return Error.StackExhausted;
            },
            .get_local => {
                const width = 1;
                const local_index = code.readOperandInt(width, ins[ip + 1 ..][0..width]);
                self.currentFrame().ip += width;

                const frame = self.currentFrame();

                try self.push(self.stack[frame.base_pointer + local_index]);
            },
            .get_builtin => {
                const width = 1;
                const builtin_index = code.readOperandInt(width, ins[ip + 1 ..][0..width]);
                self.currentFrame().ip += width;

                const builtin = std.enums.fromInt(object.BuiltinFnIdent, builtin_index) orelse
                    return Error.BuiltinNotFound;

                try self.push(builtin.getObject());
            },
            .closure => {
                const const_index = code.readOperandInt(2, ins[ip + 1 ..][0..2]);
                _ = code.readOperandInt(1, ins[ip + 3 ..][0..1]); // TODO implement
                self.currentFrame().ip += 3;

                try self.push(.{ .closure = .{
                    .func = &bytecode.constants[const_index].comp_func,
                    .free = &.{},
                } });
            },
            .nil => try self.push(nil),
        }
    }
}

pub fn stackTop(self: *Self) ?object.Object {
    if (self.sp == 0) return null;

    return self.stack[self.sp - 1];
}

pub fn lastPoppedStackElem(self: *Self) object.Object {
    return self.stack[self.sp];
}

fn push(self: *Self, o: object.Object) !void {
    if (self.sp >= stack_size) return Error.StackOverflow;

    self.stack[self.sp] = o;
    self.sp += 1;
}

fn pop(self: *Self) ?object.Object {
    if (self.sp == 0) return null;

    const o = self.stack[self.sp - 1];
    self.sp -= 1;

    return o;
}

fn isTruthy(obj: object.Object) bool {
    return switch (obj) {
        .boolean => |bool_obj| bool_obj.value,
        .nil => false,
        else => true,
    };
}

fn executeBinaryOperation(self: *Self, op: code.Opcode) !void {
    const right = self.pop() orelse return Error.StackExhausted;
    const left = self.pop() orelse return Error.StackExhausted;

    const left_type = @as(object.ObjectType, left);
    const right_type = @as(object.ObjectType, right);

    if (left_type == .integer and right_type == .integer)
        return try self.executeBinaryIntegerOperation(op, left, right);

    if (left_type == .string and right_type == .string)
        return try self.executeBinaryStringOperation(op, left, right);

    return Error.UnsupportedOperationTypes;
}

fn executeBinaryIntegerOperation(self: *Self, op: code.Opcode, left: object.Object, right: object.Object) !void {
    const left_val = left.integer.value;
    const right_val = right.integer.value;

    try self.push(.{ .integer = .{
        .value = switch (op) {
            .add => left_val + right_val,
            .sub => left_val - right_val,
            .mul => left_val * right_val,
            .div => try std.math.divExact(i64, left_val, right_val),
            else => return Error.UnsupportedOperator,
        },
    } });
}

fn executeBinaryStringOperation(self: *Self, op: code.Opcode, left: object.Object, right: object.Object) !void {
    if (op != .add) return Error.UnsupportedOperationTypes;

    const left_val = left.string.value;
    const right_val = right.string.value;

    try self.push(.{ .string = .{
        .value = try std.mem.concat(self.string_fba.allocator(), u8, &.{ left_val, right_val }),
    } });
}

inline fn nativeBoolToBoolObj(in: bool) object.Object {
    return if (in) true_obj else false_obj;
}

fn executeComparison(self: *Self, op: code.Opcode) !void {
    const right = self.pop() orelse return Error.StackExhausted;
    const left = self.pop() orelse return Error.StackExhausted;

    const left_type = @as(object.ObjectType, left);
    const right_type = @as(object.ObjectType, right);

    if (left_type == .integer and right_type == .integer) return try self.executeIntegerComparison(op, left, right);

    switch (op) {
        .equal => try self.push(nativeBoolToBoolObj(right.boolean.value == left.boolean.value)),
        .not_equal => try self.push(nativeBoolToBoolObj(right.boolean.value != left.boolean.value)),
        else => return Error.UnsupportedOperator,
    }
}

fn executeIntegerComparison(self: *Self, op: code.Opcode, left: object.Object, right: object.Object) !void {
    const left_val = left.integer.value;
    const right_val = right.integer.value;

    try self.push(nativeBoolToBoolObj(
        switch (op) {
            .equal => left_val == right_val,
            .not_equal => left_val != right_val,
            .greater_than => left_val > right_val,
            else => return Error.UnsupportedOperator,
        },
    ));
}

fn executeBangOperator(self: *Self) !void {
    const operand = self.pop() orelse return Error.StackExhausted;

    try self.push(
        switch (operand) {
            .boolean => |bool_obj| if (bool_obj.value) false_obj else true_obj,
            .nil => true_obj,
            else => false_obj,
        },
    );
}

fn executeMinusOperator(self: *Self) !void {
    const operand = self.pop() orelse return Error.StackExhausted;

    if (@as(object.ObjectType, operand) != .integer) return Error.UnsupportedOperator;

    try self.push(.{ .integer = .{ .value = -operand.integer.value } });
}

fn executeIndexExpression(self: *Self, left: object.Object, index: object.Object) !void {
    return switch (left) {
        .array => {
            if (@as(object.ObjectType, index) != .integer) return Error.UnsupportedIndexOperator;

            try self.executeArrayIndex(left, index);
        },
        .hash => {
            try self.executeHashIndex(left, index);
        },
        else => Error.UnsupportedIndexOperator,
    };
}

fn executeArrayIndex(self: *Self, left: object.Object, index: object.Object) !void {
    const arr = left.array;
    const i = index.integer.value;
    const len: i64 = @intCast(arr.elements.len);
    const max = len - 1;

    if (i < 0 or i > max) return try self.push(nil);

    return try self.push(arr.elements[@intCast(i)]);
}

fn executeHashIndex(self: *Self, left: object.Object, index: object.Object) !void {
    const hash = left.hash;
    const key = try index.toHashable();

    const val = hash.pairs.get(key) orelse return try self.push(nil);

    return self.push(val);
}

fn buildArray(self: *Self, start_index: usize, end_index: usize) !object.Object {
    var alloc = self.array_fba.allocator();
    var elements = try alloc.alloc(object.Object, end_index - start_index);

    for (start_index..end_index) |i| {
        elements[i - start_index] = self.stack[i];
    }

    return .{ .array = .{ .elements = elements } };
}

fn buildHash(self: *Self, start_index: usize, end_index: usize) !object.Object {
    const alloc = self.hash_fba.allocator();
    var pairs: object.HashMap = .empty;

    var i = start_index;
    while (i < end_index) {
        const key = try self.stack[i].toHashable();
        const val = self.stack[i + 1];

        try pairs.put(alloc, key, val);

        i += 2;
    }

    return .{ .hash = .{ .pairs = pairs } };
}

fn executeCall(self: *Self, num_args: u8) !void {
    const obj = self.stack[self.sp - 1 - num_args];

    switch (obj) {
        .closure => |func| try self.callClosure(func, num_args),
        .builtin => |func| try self.callBuiltin(func, num_args),
        else => return Error.CallingNonFunction,
    }
}

fn callClosure(self: *Self, cl: object.Closure, num_args: u8) !void {
    if (num_args != cl.func.num_parameters) return Error.WrongNumberOfArgs;

    const frame: Frame = .init(cl, self.sp - num_args);
    self.pushFrame(frame);
    self.sp = frame.base_pointer + cl.func.num_locals;
}

fn callBuiltin(self: *Self, builtin: object.Builtin, num_args: u8) !void {
    const args = self.stack[self.sp - num_args .. self.sp];

    const result = try builtin.func(self.builtins_fba.allocator(), args);
    self.sp = self.sp - num_args - 1;

    try self.push(result);
}

// Testing

const VmTestCase = struct {
    input: []const u8,
    expected: ?union(enum) {
        int: i64,
        boolean: bool,
        str: []const u8,
        arr: []const i64,
        hash: []const struct {
            key: object.Hashable,
            val: i64,
        },
        err: []const u8,
    },
};

test "integer arithmetic" {
    const tests: []const VmTestCase = &.{
        .{ .input = "1", .expected = .{ .int = 1 } },
        .{ .input = "2", .expected = .{ .int = 2 } },
        .{ .input = "1 + 2", .expected = .{ .int = 3 } },
        .{ .input = "1 - 2", .expected = .{ .int = -1 } },
        .{ .input = "1 * 2", .expected = .{ .int = 2 } },
        .{ .input = "4 / 2", .expected = .{ .int = 2 } },
        .{ .input = "50 / 2 * 2 + 10 - 5", .expected = .{ .int = 55 } },
        .{ .input = "5 + 5 + 5 + 5 - 10", .expected = .{ .int = 10 } },
        .{ .input = "2 * 2 * 2 * 2 * 2", .expected = .{ .int = 32 } },
        .{ .input = "5 * 2 + 10", .expected = .{ .int = 20 } },
        .{ .input = "5 + 2 * 10", .expected = .{ .int = 25 } },
        .{ .input = "5 * (2 + 10)", .expected = .{ .int = 60 } },
        .{ .input = "-5", .expected = .{ .int = -5 } },
        .{ .input = "-10", .expected = .{ .int = -10 } },
        .{ .input = "-50 + 100 + -50", .expected = .{ .int = 0 } },
        .{ .input = "(5 + 10 * 2 + 15 / 3) * 2 + -10", .expected = .{ .int = 50 } },
    };

    try runVmTests(tests);
}

test "boolean expressions" {
    const tests: []const VmTestCase = &.{
        .{ .input = "true", .expected = .{ .boolean = true } },
        .{ .input = "false", .expected = .{ .boolean = false } },
        .{ .input = "1 < 2", .expected = .{ .boolean = true } },
        .{ .input = "1 > 2", .expected = .{ .boolean = false } },
        .{ .input = "1 < 1", .expected = .{ .boolean = false } },
        .{ .input = "1 > 1", .expected = .{ .boolean = false } },
        .{ .input = "1 == 1", .expected = .{ .boolean = true } },
        .{ .input = "1 != 1", .expected = .{ .boolean = false } },
        .{ .input = "1 == 2", .expected = .{ .boolean = false } },
        .{ .input = "1 != 2", .expected = .{ .boolean = true } },
        .{ .input = "true == true", .expected = .{ .boolean = true } },
        .{ .input = "false == false", .expected = .{ .boolean = true } },
        .{ .input = "true == false", .expected = .{ .boolean = false } },
        .{ .input = "true != false", .expected = .{ .boolean = true } },
        .{ .input = "(1 < 2) == true", .expected = .{ .boolean = true } },
        .{ .input = "(1 < 2) == false", .expected = .{ .boolean = false } },
        .{ .input = "!true", .expected = .{ .boolean = false } },
        .{ .input = "!false", .expected = .{ .boolean = true } },
        .{ .input = "!5", .expected = .{ .boolean = false } },
        .{ .input = "!!true", .expected = .{ .boolean = true } },
        .{ .input = "!!false", .expected = .{ .boolean = false } },
        .{ .input = "!!5", .expected = .{ .boolean = true } },
        .{ .input = "!(if (false) { 5; })", .expected = .{ .boolean = true } },
    };

    try runVmTests(tests);
}

test "conditionals" {
    const tests: []const VmTestCase = &.{
        .{ .input = "if (true) { 10 }", .expected = .{ .int = 10 } },
        .{ .input = "if (true) { 10 } else { 20 }", .expected = .{ .int = 10 } },
        .{ .input = "if (false) { 10 } else { 20 }", .expected = .{ .int = 20 } },
        .{ .input = "if (1) { 10 }", .expected = .{ .int = 10 } },
        .{ .input = "if (1 < 2) { 10 }", .expected = .{ .int = 10 } },
        .{ .input = "if (1 < 2) { 10 } else { 20 }", .expected = .{ .int = 10 } },
        .{ .input = "if (1 > 2) { 10 } else { 20 }", .expected = .{ .int = 20 } },
        .{ .input = "if (1 > 2) { 10 }", .expected = null },
        .{ .input = "if (false) { 10 }", .expected = null },
        .{ .input = "if ((if (false) { 10 })) { 10 } else { 20 }", .expected = .{ .int = 20 } },
    };

    try runVmTests(tests);
}

test "global let statements" {
    const tests: []const VmTestCase = &.{
        .{ .input = "let one = 1; one", .expected = .{ .int = 1 } },
        .{ .input = "let one = 1; let two = 2; one + two", .expected = .{ .int = 3 } },
        .{ .input = "let one = 1; let two = one + one; one + two", .expected = .{ .int = 3 } },
    };

    try runVmTests(tests);
}

test "string expressions" {
    const tests: []const VmTestCase = &.{
        .{ .input = "\"monkey\"", .expected = .{ .str = "monkey" } },
        .{ .input = "\"mon\" + \"key\"", .expected = .{ .str = "monkey" } },
        .{
            .input = "\"mon\" + \"key\" + \"banana\"",
            .expected = .{
                .str = "monkeybanana",
            },
        },
    };

    try runVmTests(tests);
}

test "array literals" {
    const tests: []const VmTestCase = &.{
        .{ .input = "[]", .expected = .{ .arr = &.{} } },
        .{ .input = "[1, 2, 3]", .expected = .{ .arr = &.{ 1, 2, 3 } } },
        .{ .input = "[1 + 2, 3 * 4, 5 + 6]", .expected = .{ .arr = &.{ 3, 12, 11 } } },
    };

    try runVmTests(tests);
}

test "hash literals" {
    const tests: []const VmTestCase = &.{
        .{
            .input = "{}",
            .expected = .{ .hash = &.{} },
        },
        .{
            .input = "{1: 2, 2: 3}",
            .expected = .{ .hash = &.{
                .{ .key = .{ .integer = .{ .value = 1 } }, .val = 2 },
                .{ .key = .{ .integer = .{ .value = 2 } }, .val = 3 },
            } },
        },
        .{
            .input = "{1 + 1: 2 * 2, 3 + 3: 4 * 4}",
            .expected = .{ .hash = &.{
                .{ .key = .{ .integer = .{ .value = 2 } }, .val = 4 },
                .{ .key = .{ .integer = .{ .value = 6 } }, .val = 16 },
            } },
        },
    };

    try runVmTests(tests);
}

test "index expressions" {
    const tests: []const VmTestCase = &.{
        .{ .input = "[1, 2, 3][1]", .expected = .{ .int = 2 } },
        .{ .input = "[1, 2, 3][0 + 2]", .expected = .{ .int = 3 } },
        .{ .input = "[[1, 1, 1]][0][0]", .expected = .{ .int = 1 } },
        .{ .input = "[][0]", .expected = null },
        .{ .input = "[1, 2, 3][99]", .expected = null },
        .{ .input = "[1][-1]", .expected = null },
        .{ .input = "{1: 1, 2: 2}[1]", .expected = .{ .int = 1 } },
        .{ .input = "{1: 1, 2: 2}[2]", .expected = .{ .int = 2 } },
        .{ .input = "{1: 1}[0]", .expected = null },
        .{ .input = "{}[0]", .expected = null },
    };

    try runVmTests(tests);
}

test "calling functions without arguments" {
    const tests: []const VmTestCase = &.{
        .{
            .input =
            \\ let fivePlusTen = fn() { 5 + 10; };
            \\ fivePlusTen();
            ,
            .expected = .{ .int = 15 },
        },
        .{
            .input =
            \\ let one = fn() { 1; };
            \\ let two = fn() { 2; };
            \\ one() + two();
            ,
            .expected = .{ .int = 3 },
        },
    };

    try runVmTests(tests);
}

test "calling functions with return statements" {
    const tests: []const VmTestCase = &.{
        .{
            .input =
            \\ let earlyExit = fn() { return 99; 100; };
            \\ earlyExit();
            ,
            .expected = .{ .int = 99 },
        },
        .{
            .input =
            \\ let earlyExit = fn() { return 99; return 100; };
            \\ earlyExit();
            ,
            .expected = .{ .int = 99 },
        },
    };

    try runVmTests(tests);
}

test "calling functions without return value" {
    const tests: []const VmTestCase = &.{
        .{
            .input =
            \\ let noReturn = fn() { };
            \\ noReturn();
            ,
            .expected = null,
        },
        .{
            .input =
            \\ let noReturn = fn() { };
            \\ let noReturnTwo = fn() { noReturn(); };
            \\ noReturn();
            \\ noReturnTwo();
            ,
            .expected = null,
        },
    };

    try runVmTests(tests);
}

test "first class functions" {
    const tests: []const VmTestCase = &.{
        .{
            .input =
            \\ let returnsOne = fn() { 1; };
            \\ let returnsOneReturner = fn() { returnsOne; };
            \\ returnsOneReturner()();
            ,
            .expected = .{ .int = 1 },
        },
        .{
            .input =
            \\ let returnsOneReturner = fn() {
            \\     let returnsOne = fn() { 1; };
            \\     returnsOne;
            \\ };
            \\ returnsOneReturner()();
            ,
            .expected = .{ .int = 1 },
        },
    };

    try runVmTests(tests);
}

test "calling functions with bindings" {
    const tests: []const VmTestCase = &.{
        .{
            .input =
            \\ let one = fn() { let one = 1; one };
            \\ one();
            ,
            .expected = .{ .int = 1 },
        },
        .{
            .input =
            \\ let oneAndTwo = fn() { let one = 1; let two = 2; one + two; };
            \\ oneAndTwo();
            ,
            .expected = .{ .int = 3 },
        },
        .{
            .input =
            \\ let oneAndTwo = fn() { let one = 1; let two = 2; one + two; };
            \\ let threeAndFour = fn() { let three = 3; let four = 4; three + four; };
            \\ oneAndTwo() + threeAndFour();
            ,
            .expected = .{ .int = 10 },
        },
        .{
            .input =
            \\ let firstFoobar = fn() { let foobar = 50; foobar; };
            \\ let secondFoobar = fn() { let foobar = 100; foobar; };
            \\ firstFoobar() + secondFoobar();
            ,
            .expected = .{ .int = 150 },
        },
        .{
            .input =
            \\ let globalSeed = 50;
            \\ let minusOne = fn() {
            \\     let num = 1;
            \\     globalSeed - num;
            \\ }
            \\ let minusTwo = fn() {
            \\     let num = 2;
            \\     globalSeed - num;
            \\ }
            \\ minusOne() + minusTwo();
            ,
            .expected = .{ .int = 97 },
        },
    };

    try runVmTests(tests);
}

test "calling functions with args and bindings" {
    const tests: []const VmTestCase = &.{
        .{
            .input =
            \\ let identity = fn(a) { a; };
            \\ identity(4);
            ,
            .expected = .{ .int = 4 },
        },
        .{
            .input =
            \\ let sum = fn(a, b) { a + b; };
            \\ sum(1, 2);
            ,
            .expected = .{ .int = 3 },
        },
        .{
            .input =
            \\ let sum = fn(a, b) {
            \\     let c = a + b;
            \\     c;
            \\ };
            \\ let outer = fn() {
            \\     sum(1, 2) + sum(3, 4);
            \\ };
            \\ outer();
            ,
            .expected = .{ .int = 10 },
        },
        .{
            .input =
            \\ let globalNum = 10;
            \\ 
            \\ let sum = fn(a, b) {
            \\     let c = a + b;
            \\     c + globalNum;
            \\ };
            \\ 
            \\ let outer = fn() {
            \\     sum(1, 2) + sum(3, 4) + globalNum;
            \\ };
            \\ 
            \\ outer() + globalNum;
            ,
            .expected = .{ .int = 50 },
        },
    };

    try runVmTests(tests);
}

test "calling functions with wrong args" {
    const tests: []const VmTestCase = &.{
        .{
            .input = "fn() { 1; }(1);",
            .expected = null,
        },
        .{
            .input = "fn(a) { a; }();",
            .expected = null,
        },
        .{
            .input = "fn(a, b) { a + b; }(1);",
            .expected = null,
        },
    };

    const alloc = std.testing.allocator;

    for (tests) |tt| {
        var program, var p = try parse(alloc, tt.input);
        defer program.val.program.deinit(alloc);
        defer p.deinit(alloc);

        var compiler: Compiler = try .init(alloc);
        defer compiler.deinit(alloc);

        try compiler.compile(alloc, program);
        const bcode = compiler.bytecode();

        var vm = try create(alloc);
        defer vm.destroy(alloc);
        try std.testing.expectError(Error.WrongNumberOfArgs, vm.run(bcode));
    }
}

test "builtin functions" {
    const tests: []const VmTestCase = &.{
        .{
            .input = "len(\"\")",
            .expected = .{ .int = 0 },
        },
        .{
            .input = "len(\"four\")",
            .expected = .{ .int = 4 },
        },
        .{
            .input = "len(\"hello world\")",
            .expected = .{ .int = 11 },
        },
        .{
            .input = "len(1)",
            .expected = .{ .err = "argument to `len` not supported, got INTEGER" },
        },
        .{
            .input = "len(\"one\", \"two\")",
            .expected = .{ .err = "wrong number of arguments. got=2, want=1" },
        },
        .{
            .input = "len([1, 2, 3])",
            .expected = .{ .int = 3 },
        },
        .{
            .input = "len([])",
            .expected = .{ .int = 0 },
        },
        .{
            .input = "puts(\"hello\", \"world!\")",
            .expected = null,
        },
        .{
            .input = "first([1, 2, 3])",
            .expected = .{ .int = 1 },
        },
        .{
            .input = "first([])",
            .expected = null,
        },
        .{
            .input = "first(1)",
            .expected = .{ .err = "argument to `first` must be ARRAY, got INTEGER" },
        },
        .{
            .input = "last([1, 2, 3])",
            .expected = .{ .int = 3 },
        },
        .{
            .input = "last([])",
            .expected = null,
        },
        .{
            .input = "last(1)",
            .expected = .{ .err = "argument to `last` must be ARRAY, got INTEGER" },
        },
        .{
            .input = "rest([1, 2, 3])",
            .expected = .{ .arr = &.{ 2, 3 } },
        },
        .{
            .input = "rest([])",
            .expected = null,
        },
        .{
            .input = "push([], 1)",
            .expected = .{ .arr = &.{1} },
        },
        .{
            .input = "push(1, 1)",
            .expected = .{ .err = "argument to `push` must be ARRAY, got INTEGER" },
        },
    };

    try runVmTests(tests);
}

fn parse(alloc: std.mem.Allocator, input: []const u8) !struct { ast.Node(.Common), Parser } {
    var l = Lexer.init(input);
    var p = Parser.init(&l);

    return .{ ast.Node(.Common){ .val = .{ .program = try p.parseProgram(alloc) } }, p };
}

fn testIntegerObject(expected: i64, actual: object.Object) !void {
    try std.testing.expectEqual(object.ObjectType.integer, @as(object.ObjectType, actual));
    try std.testing.expectEqual(expected, actual.integer.value);
}

fn testBooleanObject(expected: bool, actual: object.Object) !void {
    try std.testing.expectEqual(object.ObjectType.boolean, @as(object.ObjectType, actual));
    try std.testing.expectEqual(expected, actual.boolean.value);
}

fn testStringObject(expected: []const u8, actual: object.Object) !void {
    try std.testing.expectEqual(object.ObjectType.string, @as(object.ObjectType, actual));
    try std.testing.expectEqualStrings(expected, actual.string.value);
}

fn testExpectedObject(expected: @FieldType(VmTestCase, "expected"), actual: object.Object) !void {
    if (expected == null) return try std.testing.expectEqual(object.Nil{}, actual.nil);

    switch (expected.?) {
        .int => |exp| try testIntegerObject(exp, actual),
        .boolean => |exp| try testBooleanObject(exp, actual),
        .str => |exp| try testStringObject(exp, actual),
        .arr => |exp| {
            try std.testing.expectEqual(object.ObjectType.array, @as(object.ObjectType, actual));
            const act_arr = actual.array;
            try std.testing.expectEqual(exp.len, act_arr.elements.len);
            for (exp, act_arr.elements) |exp_elem, act_elem| {
                try testIntegerObject(exp_elem, act_elem);
            }
        },
        .hash => |exp| {
            try std.testing.expectEqual(object.ObjectType.hash, @as(object.ObjectType, actual));
            const act_hash = actual.hash;
            try std.testing.expectEqual(exp.len, act_hash.pairs.size);
            for (exp) |exp_item| {
                const val = act_hash.pairs.get(exp_item.key);
                try std.testing.expect(val != null);

                try testIntegerObject(exp_item.val, val.?);
            }
        },
        .err => |exp| {
            try std.testing.expectEqual(object.ObjectType.err, @as(object.ObjectType, actual));
            const act_err = actual.err;
            try std.testing.expectEqualStrings(exp, act_err.message);
        },
    }
}

fn runVmTests(tests: []const VmTestCase) !void {
    const alloc = std.testing.allocator;

    for (tests) |tt| {
        std.debug.print("TESTING INPUT: {s}\n", .{tt.input});

        var program, var p = try parse(alloc, tt.input);
        defer program.val.program.deinit(alloc);
        defer p.deinit(alloc);

        var compiler: Compiler = try .init(alloc);
        defer compiler.deinit(alloc);

        try compiler.compile(alloc, program);
        const bcode = compiler.bytecode();

        var vm = try create(alloc);
        defer vm.destroy(alloc);
        try vm.run(bcode);

        const stack_elem = vm.lastPoppedStackElem();

        try testExpectedObject(tt.expected, stack_elem);
    }
}
