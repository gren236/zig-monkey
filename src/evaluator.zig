const std = @import("std");

const ast = @import("ast.zig");
const Lexer = @import("lexer.zig");
const object = @import("object.zig");
const Parser = @import("parser.zig");

const true_obj = object.Object{ .boolean = .{ .value = true } };
const false_obj = object.Object{ .boolean = .{ .value = false } };
const nil_obj = object.Object{ .nil = .{} };

pub fn eval(alloc: std.mem.Allocator, node: *const ast.Node(.Common)) !object.Object {
    switch (node.val) {
        .program => |prog| {
            return try evalProgram(alloc, prog);
        },
    }
}

fn evalStatement(alloc: std.mem.Allocator, node: *const ast.Node(.Statement)) !object.Object {
    switch (node.val) {
        .expression_stmt => |stmt| return try evalExpression(alloc, stmt.expression),
        .block_stmt => |stmt| return try evalBlockStatements(alloc, stmt),
        .return_stmt => |stmt| {
            const val = try evalExpression(alloc, stmt.return_value);
            const val_ptr = try alloc.create(object.Object);
            val_ptr.* = val;
            return object.Object{ .return_val = .{ .value = val_ptr } };
        },
        else => return nil_obj,
    }
}

fn evalExpression(alloc: std.mem.Allocator, node: *const ast.Node(.Expression)) anyerror!object.Object {
    switch (node.val) {
        .int_literal => |int_lit| return object.Object{ .integer = .{ .value = int_lit.value } },
        .boolean => |bool_lit| return if (bool_lit.value) true_obj else false_obj,
        .prefix => |pref| {
            const right = try evalExpression(alloc, pref.right);
            return evalPrefixExpression(pref.operator, right);
        },
        .infix => |inf| {
            const left = try evalExpression(alloc, inf.left);
            const right = try evalExpression(alloc, inf.right);
            return evalInfixExpression(inf.operator, left, right);
        },
        .if_exp => |if_exp| return try evalIfExpression(alloc, if_exp),
        else => return nil_obj,
    }
}

fn evalProgram(alloc: std.mem.Allocator, program: ast.Program) anyerror!object.Object {
    var result = nil_obj;

    for (program.statements) |stmt| {
        result = try evalStatement(alloc, &stmt);

        if (@as(object.ObjectType, result) == .return_val) {
            return result.return_val.value.*;
        }
    }

    return result;
}

fn evalBlockStatements(alloc: std.mem.Allocator, block: ast.BlockStatement) anyerror!object.Object {
    var result = nil_obj;

    for (block.statements) |stmt| {
        result = try evalStatement(alloc, &stmt);

        if (@as(object.ObjectType, result) == .return_val) {
            return result;
        }
    }

    return result;
}

const Operator = enum {
    @"!",
    @"-",
    @"+",
    @"*",
    @"/",
    @"<",
    @">",
    @"==",
    @"!=",
};

fn evalPrefixExpression(operator: []const u8, right: object.Object) object.Object {
    const op = std.meta.stringToEnum(Operator, operator) orelse return nil_obj;
    switch (op) {
        .@"!" => return evalBangOperatorExpression(right),
        .@"-" => return evalMinusPrefixOperatorExpression(right),
        else => return nil_obj,
    }
}

fn evalBangOperatorExpression(right: object.Object) object.Object {
    return switch (right) {
        .boolean => |obj| if (obj.value) false_obj else true_obj,
        .nil => true_obj,
        else => false_obj,
    };
}

fn evalMinusPrefixOperatorExpression(right: object.Object) object.Object {
    // check that the tag active for object union is indeed .integer
    if (@as(object.ObjectType, right) != .integer) return nil_obj;

    return object.Object{ .integer = .{ .value = -right.integer.value } };
}

fn evalInfixExpression(operator: []const u8, left: object.Object, right: object.Object) object.Object {
    const op = std.meta.stringToEnum(Operator, operator) orelse return nil_obj;

    // special case if both sides are booleans
    if (@as(object.ObjectType, left) == .boolean and @as(object.ObjectType, right) == .boolean) {
        return switch (op) {
            .@"==" => if (left.boolean.value == right.boolean.value) true_obj else false_obj,
            .@"!=" => if (left.boolean.value != right.boolean.value) true_obj else false_obj,
            else => nil_obj,
        };
    }

    // check that the tag active for left/right object union is indeed .integer
    if (@as(object.ObjectType, left) != .integer or @as(object.ObjectType, right) != .integer) return nil_obj;

    return evalIntegerInfixExpression(op, left, right);
}

fn evalIntegerInfixExpression(operator: Operator, left: object.Object, right: object.Object) object.Object {
    const leftVal = left.integer.value;
    const rightVal = right.integer.value;

    switch (operator) {
        .@"+" => return object.Object{ .integer = .{ .value = leftVal + rightVal } },
        .@"-" => return object.Object{ .integer = .{ .value = leftVal - rightVal } },
        .@"*" => return object.Object{ .integer = .{ .value = leftVal * rightVal } },
        .@"/" => return object.Object{
            .integer = .{ .value = std.math.divExact(i64, leftVal, rightVal) catch return nil_obj },
        },
        .@"<" => return if (leftVal < rightVal) true_obj else false_obj,
        .@">" => return if (leftVal > rightVal) true_obj else false_obj,
        .@"==" => return if (leftVal == rightVal) true_obj else false_obj,
        .@"!=" => return if (leftVal != rightVal) true_obj else false_obj,
        else => return nil_obj,
    }
}

fn evalIfExpression(alloc: std.mem.Allocator, ie: ast.IfExpression) anyerror!object.Object {
    const condition = try evalExpression(alloc, ie.condition);

    if (isTruthy(condition)) {
        return try evalStatement(alloc, &ast.Node(.Statement){ .val = .{ .block_stmt = ie.consequence.* } });
    } else if (ie.alternative) |alt| {
        return try evalStatement(alloc, &ast.Node(.Statement){ .val = .{ .block_stmt = alt.* } });
    } else {
        return nil_obj;
    }
}

fn isTruthy(obj: object.Object) bool {
    return switch (obj) {
        .nil => false,
        .boolean => obj.boolean.value,
        else => true,
    };
}

test {
    std.testing.refAllDecls(@This());
}

test "eval integer expression" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const tests = [_]struct {
        input: []const u8,
        expected: i64,
    }{
        .{ .input = "5", .expected = 5 },
        .{ .input = "10", .expected = 10 },
        .{ .input = "-5", .expected = -5 },
        .{ .input = "-10", .expected = -10 },
        .{ .input = "5 + 5 + 5 + 5 - 10", .expected = 10 },
        .{ .input = "2 * 2 * 2 * 2 * 2", .expected = 32 },
        .{ .input = "-50 + 100 + -50", .expected = 0 },
        .{ .input = "5 * 2 + 10", .expected = 20 },
        .{ .input = "5 + 2 * 10", .expected = 25 },
        .{ .input = "20 + 2 * -10", .expected = 0 },
        .{ .input = "50 / 2 * 2 + 10", .expected = 60 },
        .{ .input = "2 * (5 + 10)", .expected = 30 },
        .{ .input = "3 * 3 * 3 + 10", .expected = 37 },
        .{ .input = "3 * (3 * 3) + 10", .expected = 37 },
        .{ .input = "(5 + 10 * 2 + 15 / 3) * 2 + -10", .expected = 50 },
    };

    for (tests) |t| {
        const evaluated = try testEval(alloc, t.input);
        try testIntegerObject(evaluated, t.expected);
    }
}

test "eval boolean expression" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const tests = [_]struct {
        input: []const u8,
        expected: bool,
    }{
        .{ .input = "true", .expected = true },
        .{ .input = "false", .expected = false },
        .{ .input = "1 < 2", .expected = true },
        .{ .input = "1 > 2", .expected = false },
        .{ .input = "1 < 1", .expected = false },
        .{ .input = "1 > 1", .expected = false },
        .{ .input = "1 == 1", .expected = true },
        .{ .input = "1 != 1", .expected = false },
        .{ .input = "1 == 2", .expected = false },
        .{ .input = "1 != 2", .expected = true },
        .{ .input = "true == true", .expected = true },
        .{ .input = "false == false", .expected = true },
        .{ .input = "true == false", .expected = false },
        .{ .input = "true != false", .expected = true },
        .{ .input = "false != true", .expected = true },
        .{ .input = "(1 < 2) == true", .expected = true },
        .{ .input = "(1 < 2) == false", .expected = false },
        .{ .input = "(1 > 2) == true", .expected = false },
        .{ .input = "(1 > 2) == false", .expected = true },
    };

    for (tests) |t| {
        const evaluated = try testEval(alloc, t.input);
        try testBooleanObject(evaluated, t.expected);
    }
}

test "bang operator" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const tests = [_]struct {
        input: []const u8,
        expected: bool,
    }{
        .{ .input = "!true", .expected = false },
        .{ .input = "!false", .expected = true },
        .{ .input = "!5", .expected = false },
        .{ .input = "!!true", .expected = true },
        .{ .input = "!!false", .expected = false },
        .{ .input = "!!5", .expected = true },
    };

    for (tests) |t| {
        const evaluated = try testEval(alloc, t.input);
        try testBooleanObject(evaluated, t.expected);
    }
}

test "if else expression" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const tests = [_]struct {
        input: []const u8,
        expected: ?i64,
    }{
        .{ .input = "if (true) { 10 }", .expected = 10 },
        .{ .input = "if (false) { 10 }", .expected = null },
        .{ .input = "if (1) { 10 }", .expected = 10 },
        .{ .input = "if (1 < 2) { 10 }", .expected = 10 },
        .{ .input = "if (1 > 2) { 10 }", .expected = null },
        .{ .input = "if (1 > 2) { 10 } else { 20 }", .expected = 20 },
        .{ .input = "if (1 < 2) { 10 } else { 20 }", .expected = 10 },
    };

    for (tests) |t| {
        const evaluated = try testEval(alloc, t.input);
        if (t.expected) |exp| {
            try testIntegerObject(evaluated, exp);
        } else {
            try testNilObject(evaluated);
        }
    }
}

test "return statements" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const tests = [_]struct {
        input: []const u8,
        expected: i64,
    }{
        .{ .input = "return 10;", .expected = 10 },
        .{ .input = "return 10; 9;", .expected = 10 },
        .{ .input = "return 2 * 5; 9;", .expected = 10 },
        .{ .input = "9; return 2 * 5; 9;", .expected = 10 },
    };

    for (tests) |t| {
        const evaluated = try testEval(alloc, t.input);
        try testIntegerObject(evaluated, t.expected);
    }
}

fn testNilObject(obj: object.Object) !void {
    try std.testing.expectEqual(object.ObjectType.nil, @as(object.ObjectType, obj));
}

fn testEval(alloc: std.mem.Allocator, input: []const u8) !object.Object {
    var l = Lexer.init(input);
    var p = Parser.init(&l);
    defer p.deinit(alloc);

    var program = try p.parseProgram(alloc);
    defer program.deinit(alloc);

    return try eval(alloc, &ast.Node(.Common){ .val = .{ .program = program } });
}

fn testIntegerObject(obj: object.Object, expected: i64) !void {
    try std.testing.expectEqual(expected, obj.integer.value);
}

fn testBooleanObject(obj: object.Object, expected: bool) !void {
    try std.testing.expectEqual(expected, obj.boolean.value);
}
