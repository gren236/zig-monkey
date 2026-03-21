const std = @import("std");

const ast = @import("ast.zig");
const Lexer = @import("lexer.zig");
const object = @import("object.zig");
const Parser = @import("parser.zig");

const true_obj = object.Object{ .boolean = .{ .value = true } };
const false_obj = object.Object{ .boolean = .{ .value = false } };

pub fn eval(node: *const ast.Node(.Common)) ?object.Object {
    switch (node.val) {
        .program => |prog| {
            return evalStatements(prog.statements);
        },
    }
}

fn evalStatement(node: *const ast.Node(.Statement)) ?object.Object {
    switch (node.val) {
        .expression_stmt => |stmt| return evalExpression(stmt.expression),
        else => return null,
    }
}

fn evalExpression(node: *const ast.Node(.Expression)) ?object.Object {
    switch (node.val) {
        .int_literal => |int_lit| return object.Object{ .integer = .{ .value = int_lit.value } },
        .boolean => |bool_lit| return if (bool_lit.value) true_obj else false_obj,
        else => return null,
    }
}

fn evalStatements(stmts: []ast.Node(.Statement)) ?object.Object {
    for (stmts) |stmt| {
        return evalStatement(&stmt);
    }

    return null;
}

test {
    std.testing.refAllDecls(@This());
}

test "eval integer expression" {
    const alloc = std.testing.allocator;

    const tests = [_]struct {
        input: []const u8,
        expected: i64,
    }{
        .{ .input = "5", .expected = 5 },
        .{ .input = "10", .expected = 10 },
    };

    for (tests) |t| {
        const evaluated = try testEval(alloc, t.input);
        try testIntegerObject(evaluated, t.expected);
    }
}

test "eval boolean expression" {
    const alloc = std.testing.allocator;

    const tests = [_]struct {
        input: []const u8,
        expected: bool,
    }{
        .{ .input = "true", .expected = true },
        .{ .input = "false", .expected = false },
    };

    for (tests) |t| {
        const evaluated = try testEval(alloc, t.input);
        try testBooleanObject(evaluated, t.expected);
    }
}

fn testEval(alloc: std.mem.Allocator, input: []const u8) !object.Object {
    var l = Lexer.init(input);
    var p = Parser.init(&l);
    defer p.deinit(alloc);

    var program = try p.parseProgram(alloc);
    defer program.deinit(alloc);

    return eval(&ast.Node(.Common){ .val = .{ .program = program } }) orelse error.EmptyObject;
}

fn testIntegerObject(obj: object.Object, expected: i64) !void {
    try std.testing.expectEqual(expected, obj.integer.value);
}

fn testBooleanObject(obj: object.Object, expected: bool) !void {
    try std.testing.expectEqual(expected, obj.boolean.value);
}
