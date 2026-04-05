const std = @import("std");

const ast = @import("ast.zig");
const Lexer = @import("lexer.zig");
const object = @import("object.zig");
const Parser = @import("parser.zig");

const true_obj = object.Object{ .boolean = .{ .value = true } };
const false_obj = object.Object{ .boolean = .{ .value = false } };
const nil_obj = object.Object{ .nil = .{} };

fn newError(alloc: std.mem.Allocator, comptime format: []const u8, args: anytype) !object.Object {
    return object.Object{
        .err = .{ .message = try std.fmt.allocPrint(alloc, format, args) },
    };
}

fn isError(obj: object.Object) bool {
    return @as(object.ObjectType, obj) == .err;
}

pub fn eval(alloc: std.mem.Allocator, node: *const ast.Node(.Common), env: *object.Environment) !object.Object {
    switch (node.val) {
        .program => |prog| {
            return try evalProgram(alloc, prog, env);
        },
    }
}

fn evalProgram(alloc: std.mem.Allocator, program: ast.Program, env: *object.Environment) anyerror!object.Object {
    var result = nil_obj;

    for (program.statements) |stmt| {
        result = try evalStatement(alloc, &stmt, env);

        switch (result) {
            .return_val => return result.return_val.value.*,
            .err => return result,
            else => continue,
        }
    }

    return result;
}

fn evalStatement(alloc: std.mem.Allocator, node: *const ast.Node(.Statement), env: *object.Environment) !object.Object {
    switch (node.val) {
        .expression_stmt => |stmt| return try evalExpression(alloc, stmt.expression, env),
        .block_stmt => |stmt| return try evalBlockStatements(alloc, stmt, env),
        .return_stmt => |stmt| {
            const val = try evalExpression(alloc, stmt.return_value, env);
            if (isError(val)) return val;

            const val_ptr = try alloc.create(object.Object);
            val_ptr.* = val;
            return object.Object{ .return_val = .{ .value = val_ptr } };
        },
        .let_stmt => |stmt| {
            const val = try evalExpression(alloc, stmt.value, env);
            if (isError(val)) return val;

            return try env.set(stmt.name.value, val);
        },
    }
}

fn evalExpression(alloc: std.mem.Allocator, node: *const ast.Node(.Expression), env: *object.Environment) anyerror!object.Object {
    switch (node.val) {
        .int_literal => |int_lit| return object.Object{ .integer = .{ .value = int_lit.value } },
        .boolean => |bool_lit| return if (bool_lit.value) true_obj else false_obj,
        .prefix => |pref| {
            const right = try evalExpression(alloc, pref.right, env);
            if (isError(right)) return right;

            return try evalPrefixExpression(alloc, pref.operator, right, env);
        },
        .infix => |inf| {
            const left = try evalExpression(alloc, inf.left, env);
            if (isError(left)) return left;
            const right = try evalExpression(alloc, inf.right, env);
            if (isError(right)) return right;

            return evalInfixExpression(alloc, inf.operator, left, right, env);
        },
        .if_exp => |if_exp| return try evalIfExpression(alloc, if_exp, env),
        .ident => |ident_exp| return try evalIdentifier(alloc, ident_exp, env),
        .fn_literal => |fn_exp| {
            return object.Object{ .func = try object.Function.init(
                alloc,
                fn_exp.parameters,
                fn_exp.body.*,
                env,
            ) };
        },
        .call_exp => |call_exp| {
            const func = try evalExpression(alloc, call_exp.function, env);
            if (isError(func)) return func;

            const args = try evalExpressions(alloc, call_exp.arguments, env);
            if (args.len == 1 and isError(args[0])) {
                return args[0];
            }

            return try applyFunction(alloc, func, args);
        },
        .string_literal => |str_lit| return object.Object{
            .string = try object.String.init(alloc, str_lit.value),
        },
    }
}

fn evalExpressions(alloc: std.mem.Allocator, exps: []ast.Node(.Expression), env: *object.Environment) ![]object.Object {
    var result_list = std.ArrayListUnmanaged(object.Object).empty;

    for (exps) |exp| {
        const evaluated = try evalExpression(alloc, &exp, env);
        try result_list.append(alloc, evaluated);

        if (isError(evaluated)) break;
    }

    return try result_list.toOwnedSlice(alloc);
}

fn applyFunction(alloc: std.mem.Allocator, func: object.Object, args: []object.Object) !object.Object {
    if (@as(object.ObjectType, func) != .func) return newError(alloc, "not a function: {s}", .{func.tagName()});
    const function = func.func;

    var extended_env = try extendFunctionEnv(function, args);
    defer extended_env.deinit(extended_env.alloc);

    const evaluated = try evalStatement(
        alloc,
        &ast.Node(.Statement){ .val = .{
            .block_stmt = function.body,
        } },
        &extended_env,
    );

    return unwrapReturnValue(evaluated);
}

fn extendFunctionEnv(func: object.Function, args: []object.Object) !object.Environment {
    var env = try object.Environment.initEnclosed(func.env);

    for (0.., func.parameters) |i, param| {
        _ = try env.set(param.value, args[i]);
    }

    return env;
}

fn unwrapReturnValue(obj: object.Object) object.Object {
    if (@as(object.ObjectType, obj) == .return_val) return obj.return_val.value.*;

    return obj;
}

fn evalBlockStatements(alloc: std.mem.Allocator, block: ast.BlockStatement, env: *object.Environment) anyerror!object.Object {
    var result = nil_obj;

    for (block.statements) |stmt| {
        result = try evalStatement(alloc, &stmt, env);

        switch (result) {
            .return_val, .err => return result,
            else => continue,
        }
    }

    return result;
}

fn evalIdentifier(alloc: std.mem.Allocator, node: ast.Identifier, env: *object.Environment) !object.Object {
    return env.get(node.value) orelse newError(alloc, "identifier not found: {s}", .{node.value});
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

fn evalPrefixExpression(alloc: std.mem.Allocator, operator: []const u8, right: object.Object, _: *object.Environment) !object.Object {
    const op = std.meta.stringToEnum(Operator, operator) orelse return nil_obj;
    switch (op) {
        .@"!" => return evalBangOperatorExpression(right),
        .@"-" => return try evalMinusPrefixOperatorExpression(alloc, right),
        else => return try newError(alloc, "unknown operator: {s}{s}", .{
            operator,
            right.tagName(),
        }),
    }
}

fn evalBangOperatorExpression(right: object.Object) object.Object {
    return switch (right) {
        .boolean => |obj| if (obj.value) false_obj else true_obj,
        .nil => true_obj,
        else => false_obj,
    };
}

fn evalMinusPrefixOperatorExpression(alloc: std.mem.Allocator, right: object.Object) !object.Object {
    // check that the tag active for object union is indeed .integer
    if (@as(object.ObjectType, right) != .integer) {
        return try newError(alloc, "unknown operator: -{s}", .{right.tagName()});
    }

    return object.Object{ .integer = .{ .value = -right.integer.value } };
}

fn evalInfixExpression(
    alloc: std.mem.Allocator,
    operator: []const u8,
    left: object.Object,
    right: object.Object,
    _: *object.Environment,
) !object.Object {
    const op = std.meta.stringToEnum(Operator, operator) orelse return nil_obj;

    // check that the tags active for left/right objects are the same
    if (@as(object.ObjectType, left) != @as(object.ObjectType, right)) {
        return try newError(alloc, "type mismatch: {s} {s} {s}", .{
            left.tagName(),
            operator,
            right.tagName(),
        });
    }

    // special case if both sides are booleans
    if (@as(object.ObjectType, left) == .boolean and @as(object.ObjectType, right) == .boolean) {
        return switch (op) {
            .@"==" => if (left.boolean.value == right.boolean.value) true_obj else false_obj,
            .@"!=" => if (left.boolean.value != right.boolean.value) true_obj else false_obj,
            else => try newError(alloc, "unknown operator: {s} {s} {s}", .{
                left.tagName(),
                operator,
                right.tagName(),
            }),
        };
    }

    return try evalIntegerInfixExpression(alloc, op, left, right);
}

fn evalIntegerInfixExpression(alloc: std.mem.Allocator, operator: Operator, left: object.Object, right: object.Object) !object.Object {
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
        else => return try newError(alloc, "unknown operator: {s} {s} {s}", .{
            left.tagName(),
            @tagName(operator),
            right.tagName(),
        }),
    }
}

fn evalIfExpression(alloc: std.mem.Allocator, ie: ast.IfExpression, env: *object.Environment) anyerror!object.Object {
    const condition = try evalExpression(alloc, ie.condition, env);
    if (isError(condition)) return condition;

    if (isTruthy(condition)) {
        return try evalStatement(
            alloc,
            &ast.Node(.Statement){ .val = .{ .block_stmt = ie.consequence.* } },
            env,
        );
    } else if (ie.alternative) |alt| {
        return try evalStatement(
            alloc,
            &ast.Node(.Statement){ .val = .{ .block_stmt = alt.* } },
            env,
        );
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

test "string literal" {
    const input = "\"Hello World!\"";

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();
    const evaluated = try testEval(alloc, input);

    try std.testing.expectEqualStrings("Hello World!", evaluated.string.value);
}

test "error handling" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const tests = [_]struct {
        input: []const u8,
        expected: []const u8,
    }{
        .{
            .input = "5 + true",
            .expected = "type mismatch: INTEGER + BOOLEAN",
        },
        .{
            .input = "5 + true; 5;",
            .expected = "type mismatch: INTEGER + BOOLEAN",
        },
        .{
            .input = "-true",
            .expected = "unknown operator: -BOOLEAN",
        },
        .{
            .input = "true + false",
            .expected = "unknown operator: BOOLEAN + BOOLEAN",
        },
        .{
            .input = "5; true + false; 5",
            .expected = "unknown operator: BOOLEAN + BOOLEAN",
        },
        .{
            .input = "if (10 > 1) { true + false; }",
            .expected = "unknown operator: BOOLEAN + BOOLEAN",
        },
        .{
            .input =
            \\if (10 > 1) {
            \\  if (10 > 1) {
            \\    return true + false;
            \\  }
            \\
            \\  return 1;
            \\}
            ,
            .expected = "unknown operator: BOOLEAN + BOOLEAN",
        },
        .{
            .input = "foobar",
            .expected = "identifier not found: foobar",
        },
    };

    for (tests) |t| {
        const evaluated = try testEval(alloc, t.input);

        try std.testing.expectEqual(object.ObjectType.err, @as(object.ObjectType, evaluated));
        try std.testing.expectEqualStrings(t.expected, evaluated.err.message);
    }
}

test "let statements" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const tests = [_]struct {
        input: []const u8,
        expected: i64,
    }{
        .{ .input = "let a = 5; a;", .expected = 5 },
        .{ .input = "let a = 5 * 5; a;", .expected = 25 },
        .{ .input = "let a = 5; let b = a; b;", .expected = 5 },
        .{ .input = "let a = 5; let b = a; let c = a + b + 5; c;", .expected = 15 },
    };

    for (tests) |t| {
        const evaluated = try testEval(alloc, t.input);
        try testIntegerObject(evaluated, t.expected);
    }
}

test "function object" {
    const input = "fn(x) { x + 2; };";

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const evaluated = try testEval(alloc, input);

    try std.testing.expectEqual(1, evaluated.func.parameters.len);

    var param_buf: [1024]u8 = undefined;
    var param_writer = std.Io.Writer.fixed(&param_buf);
    try evaluated.func.parameters[0].writeString(&param_writer);
    try param_writer.flush();
    try std.testing.expectEqualStrings("x", param_buf[0..1]);

    var body_buf: [1024]u8 = undefined;
    var body_writer = std.Io.Writer.fixed(&body_buf);
    try evaluated.func.body.writeString(&body_writer);
    try body_writer.flush();
    try std.testing.expectEqualStrings("(x + 2)", body_buf[0..7]);
}

test "function application" {
    const talloc = std.testing.allocator;
    var arena = std.heap.ArenaAllocator.init(talloc);
    defer arena.deinit();
    const alloc = arena.allocator();

    const tests = [_]struct {
        input: []const u8,
        expected: i64,
    }{
        .{ .input = "let identity = fn(x) { x; }; identity(5);", .expected = 5 },
        .{ .input = "let identity = fn(x) { return x; }; identity(5);", .expected = 5 },
        .{ .input = "let double = fn(x) { x * 2; }; double(5);", .expected = 10 },
        .{ .input = "let add = fn(x, y) { x + y; }; add(5, 5);", .expected = 10 },
        .{ .input = "let add = fn(x, y) { x + y; }; add(5 + 5, add(5, 5));", .expected = 20 },
        .{ .input = "fn(x) { x; }(5)", .expected = 5 },
    };

    for (tests) |t| {
        var env = try object.Environment.init(talloc);
        defer env.deinit(talloc);

        const evaluated = try testEvalWithEnv(alloc, t.input, &env);
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

    var env = try object.Environment.init(alloc);

    return try eval(
        alloc,
        &ast.Node(.Common){ .val = .{ .program = program } },
        &env,
    );
}

fn testEvalWithEnv(alloc: std.mem.Allocator, input: []const u8, env: *object.Environment) !object.Object {
    var l = Lexer.init(input);
    var p = Parser.init(&l);
    defer p.deinit(alloc);

    var program = try p.parseProgram(alloc);
    defer program.deinit(alloc);

    return try eval(
        alloc,
        &ast.Node(.Common){ .val = .{ .program = program } },
        env,
    );
}

fn testIntegerObject(obj: object.Object, expected: i64) !void {
    try std.testing.expectEqual(expected, obj.integer.value);
}

fn testBooleanObject(obj: object.Object, expected: bool) !void {
    try std.testing.expectEqual(expected, obj.boolean.value);
}
