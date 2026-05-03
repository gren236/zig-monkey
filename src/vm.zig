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
};

const stack_size = 2048;
const globals_size = 65536;
const string_arena_size = 1024 * 1024 * 5; // 5mb
const array_arena_size = 1024 * 1024 * 5; // 5mb

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

pub fn create(alloc: std.mem.Allocator) !*Self {
    const self = try alloc.create(Self);

    self.* = .{
        .stack = @splat(nil),
        .sp = 0,

        .globals = @splat(nil),

        .string_arena = undefined,
        .string_fba = undefined,
        .array_arena = undefined,
        .array_fba = undefined,
    };

    self.string_fba = .init(&self.string_arena);
    self.array_fba = .init(&self.array_arena);

    return self;
}

pub fn destroy(self: *Self, alloc: std.mem.Allocator) void {
    alloc.destroy(self);
}

pub fn run(self: *Self, bytecode: Compiler.Bytecode) !void {
    var ip: usize = 0;
    while (ip < bytecode.instructions.len) {
        const op = std.enums.fromInt(code.Opcode, bytecode.instructions[ip]) orelse
            return Error.UnknownOpcode;

        switch (op) {
            .constant => {
                const width = 2;
                const const_index = code.readOperandInt(width, bytecode.instructions[ip + 1 ..][0..width]);
                ip += width;

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
                const pos = code.readOperandInt(width, bytecode.instructions[ip + 1 ..][0..width]);

                ip = @intCast(pos - 1);
            },
            .jump_not_truthy => {
                const width = 2;
                const pos = code.readOperandInt(width, bytecode.instructions[ip + 1 ..][0..width]);
                ip += width;

                const condition = self.pop() orelse return Error.StackExhausted;
                if (!isTruthy(condition)) ip = @intCast(pos - 1);
            },
            .set_global => {
                const width = 2;
                const global_index = code.readOperandInt(width, bytecode.instructions[ip + 1 ..][0..width]);
                ip += width;

                self.globals[global_index] = self.pop() orelse nil;
            },
            .get_global => {
                const width = 2;
                const global_index = code.readOperandInt(width, bytecode.instructions[ip + 1 ..][0..width]);
                ip += width;

                try self.push(self.globals[global_index]);
            },
            .array => {
                const width = 2;
                const num_elements = code.readOperandInt(width, bytecode.instructions[ip + 1 ..][0..width]);
                ip += width;

                const array = try self.buildArray(self.sp - num_elements, self.sp);
                try self.push(array);
            },
            .nil => try self.push(nil),
        }

        ip += 1;
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

fn buildArray(self: *Self, start_index: usize, end_index: usize) !object.Object {
    var alloc = self.array_fba.allocator();
    var elements = try alloc.alloc(object.Object, end_index - start_index);

    for (start_index..end_index) |i| {
        elements[i - start_index] = self.stack[i];
    }

    return .{ .array = .{ .elements = elements } };
}

// Testing

const VmTestCase = struct {
    input: []const u8,
    expected: ?union(enum) {
        int: i64,
        boolean: bool,
        str: []const u8,
        arr: []const i64,
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
    }
}

fn runVmTests(tests: []const VmTestCase) !void {
    const alloc = std.testing.allocator;

    for (tests) |tt| {
        var program, var p = try parse(alloc, tt.input);
        defer program.val.program.deinit(alloc);
        defer p.deinit(alloc);

        var compiler = Compiler.init();
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
