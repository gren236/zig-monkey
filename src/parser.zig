const std = @import("std");

const ast = @import("ast.zig");
const Lexer = @import("lexer.zig");

test {
    std.testing.refAllDecls(@This());
}

const PrefixParseFn = *const fn (*@This(), std.mem.Allocator) anyerror!ast.Node(.Expression);
const InfixParseFn = *const fn (*@This(), std.mem.Allocator, ast.Node(.Expression)) anyerror!ast.Node(.Expression);

inline fn getPrefixParseFnFromNodeType(token_type: Lexer.TokenType) !PrefixParseFn {
    return switch (token_type) {
        .IDENT => parseIdentifier,
        .INT => parseIntegerLiteral,
        .BANG, .MINUS => parsePrefixExpression,
        else => error.UnrecognisedTokenType,
    };
}

inline fn getInfixParseFnFromNodeType(token_type: Lexer.TokenType) !InfixParseFn {
    return switch (token_type) {
        .PLUS, .MINUS, .SLASH, .ASTERISK, .EQ, .NOT_EQ, .LT, .GT => parseInfixExpression,
        else => error.UnrecognisedTokenType,
    };
}

l: *Lexer,

cur_token: Lexer.Token = undefined,
peek_token: Lexer.Token = undefined,

errors: std.ArrayList([]const u8),

pub fn init(l: *Lexer) @This() {
    var p = @This(){
        .l = l,
        .errors = std.ArrayList([]const u8).empty,
    };

    // Read 2 tokens, so both tokens are set
    p.nextToken();
    p.nextToken();

    return p;
}

pub fn deinit(self: *@This(), alloc: std.mem.Allocator) void {
    for (self.errors.items) |err| {
        alloc.free(err);
    }
    self.errors.deinit(alloc);
}

pub fn getErrors(self: *@This()) []const []const u8 {
    return self.errors.items;
}

fn peekError(self: *@This(), alloc: std.mem.Allocator, t: Lexer.TokenType) !void {
    try self.errors.append(
        alloc,
        try std.fmt.allocPrint(
            alloc,
            "expected next token to be {s}, got {s}",
            .{ @tagName(t), @tagName(self.peek_token.token_type) },
        ),
    );
}

fn nextToken(self: *@This()) void {
    self.cur_token = self.peek_token;
    self.peek_token = self.l.nextToken();
}

// Statement parsing methods

fn parseStatement(self: *@This(), alloc: std.mem.Allocator) !?ast.Node(.Statement) {
    return switch (self.cur_token.token_type) {
        .LET => try self.parseLetStatement(alloc),
        .RETURN => try self.parseReturnStatement(alloc),
        else => try self.parseExpressionStatement(alloc),
    };
}

fn parseReturnStatement(self: *@This(), alloc: std.mem.Allocator) !ast.Node(.Statement) {
    const stmt = try ast.ReturnStatement.init(
        alloc,
        self.cur_token,
        ast.Node(.Expression){ .val = .{ .noop = ast.NoopExpression{} } },
    );

    self.nextToken();

    // TODO: We're skipping the expressions until we encounter a semicolon
    while (self.cur_token.token_type != Lexer.TokenType.SEMICOLON) {
        self.nextToken();
    }

    return ast.Node(.Statement){ .val = .{ .return_stmt = stmt } };
}

fn parseLetStatement(self: *@This(), alloc: std.mem.Allocator) !?ast.Node(.Statement) {
    const let_tok = self.cur_token;

    if (!try self.expectPeek(alloc, Lexer.TokenType.IDENT)) return null;

    const stmt_name = ast.Identifier{ .token = self.cur_token, .value = self.cur_token.literal };

    if (!try self.expectPeek(alloc, Lexer.TokenType.ASSIGN)) return null;

    // TODO: We're skipping the expressions until we encounter a semicolon
    while (self.cur_token.token_type != Lexer.TokenType.SEMICOLON) {
        self.nextToken();
    }

    const stmt = try ast.LetStatement.init(
        alloc,
        let_tok,
        stmt_name,
        ast.Node(.Expression){ .val = .{ .noop = ast.NoopExpression{} } },
    );

    return ast.Node(.Statement){ .val = .{ .let_stmt = stmt } };
}

fn parseExpressionStatement(self: *@This(), alloc: std.mem.Allocator) !ast.Node(.Statement) {
    const stmt = try ast.ExpressionStatement.init(
        alloc,
        self.cur_token,
        try self.parseExpression(alloc, .lowest),
    );

    if (self.peek_token.token_type == .SEMICOLON) self.nextToken();

    return ast.Node(.Statement){ .val = .{ .expression_stmt = stmt } };
}

// Expression parsing methods

// Order matters: the later it appears, the more precedence it has
const Precedence = enum {
    lowest,
    equals, // ==
    lessgreater, // < or >
    sum, // +
    product, // *
    prefix, // -X or !X
    call, // myFunction(X)
};

inline fn getPrecedenceByTokenType(tok_type: Lexer.TokenType) Precedence {
    return switch (tok_type) {
        .EQ, .NOT_EQ => .equals,
        .LT, .GT => .lessgreater,
        .PLUS, .MINUS => .sum,
        .SLASH, .ASTERISK => .product,
        else => .lowest,
    };
}

fn peekPrecedence(self: *@This()) Precedence {
    return getPrecedenceByTokenType(self.peek_token.token_type);
}

fn curPrecedence(self: *@This()) Precedence {
    return getPrecedenceByTokenType(self.cur_token.token_type);
}

fn parseExpression(self: *@This(), alloc: std.mem.Allocator, prec: Precedence) !ast.Node(.Expression) {
    const prefix = try getPrefixParseFnFromNodeType(self.cur_token.token_type);

    var left_exp = try prefix(self, alloc);

    while (self.peek_token.token_type != .SEMICOLON and @intFromEnum(prec) < @intFromEnum(self.peekPrecedence())) {
        const inflix = getInfixParseFnFromNodeType(self.peek_token.token_type) catch {
            return left_exp;
        };

        self.nextToken();

        left_exp = try inflix(self, alloc, left_exp);
    }

    return left_exp;
}

fn parseIdentifier(self: *@This(), _: std.mem.Allocator) !ast.Node(.Expression) {
    return ast.Node(.Expression){ .val = .{
        .ident = .{ .token = self.cur_token, .value = self.cur_token.literal },
    } };
}

fn parseIntegerLiteral(self: *@This(), _: std.mem.Allocator) !ast.Node(.Expression) {
    const lit = try std.fmt.parseInt(i64, self.cur_token.literal, 10);

    return ast.Node(.Expression){ .val = .{
        .int_literal = .{ .token = self.cur_token, .value = lit },
    } };
}

fn parsePrefixExpression(self: *@This(), alloc: std.mem.Allocator) !ast.Node(.Expression) {
    const prefix_tok = self.cur_token;
    const prefix_op = self.cur_token.literal;

    self.nextToken();

    return ast.Node(.Expression){ .val = .{
        .prefix = try ast.PrefixExpression.init(
            alloc,
            prefix_tok,
            prefix_op,
            try self.parseExpression(alloc, .prefix),
        ),
    } };
}

fn parseInfixExpression(self: *@This(), alloc: std.mem.Allocator, left: ast.Node(.Expression)) !ast.Node(.Expression) {
    const infix_tok = self.cur_token;
    const infix_op = self.cur_token.literal;
    const prec = self.curPrecedence();

    self.nextToken();

    return ast.Node(.Expression){ .val = .{
        .infix = try ast.InfixExpression.init(
            alloc,
            infix_tok,
            left,
            infix_op,
            try self.parseExpression(alloc, prec),
        ),
    } };
}

fn expectPeek(self: *@This(), alloc: std.mem.Allocator, t: Lexer.TokenType) !bool {
    if (self.peek_token.token_type != t) {
        try self.peekError(alloc, t);
        return false;
    }

    self.nextToken();
    return true;
}

pub fn parseProgram(self: *@This(), alloc: std.mem.Allocator) !ast.Program {
    var program = ast.Program{};
    var stmts = std.ArrayList(ast.Node(.Statement)).empty;

    while (self.cur_token.token_type != .EOF) {
        const stmt = try self.parseStatement(alloc);
        if (stmt != null) try stmts.append(alloc, stmt.?);

        self.nextToken();
    }

    program.statements = try stmts.toOwnedSlice(alloc);
    return program;
}

fn checkParserErrors(p: *@This()) !void {
    if (p.errors.items.len == 0) {
        return;
    }

    std.debug.print("parser has {d} errors!\n", .{p.errors.items.len});
    for (p.errors.items) |err| {
        std.debug.print("parser error: {s}\n", .{err});
    }

    return error.ParserTestFailed;
}

test "let statements" {
    const input =
        \\ let x = 5;
        \\ let y = 10;
        \\ let foobar = 838383;
    ;

    const alloc = std.testing.allocator;

    var l = Lexer.init(input);
    var p = init(&l);
    defer p.deinit(alloc);

    var program = try p.parseProgram(alloc);
    defer program.deinit(alloc);

    try checkParserErrors(&p);
    try std.testing.expectEqual(3, program.statements.len);

    const tests = [_]struct {
        expectedIdentifier: []const u8,
    }{
        .{ .expectedIdentifier = "x" },
        .{ .expectedIdentifier = "y" },
        .{ .expectedIdentifier = "foobar" },
    };

    for (0.., tests) |i, t| {
        const stmt = program.statements[i];

        try std.testing.expectEqualStrings("let", stmt.tokenLiteral());

        var let_stmt = stmt.val.let_stmt;
        try std.testing.expectEqualStrings(t.expectedIdentifier, let_stmt.name.value);
        try std.testing.expectEqualStrings(t.expectedIdentifier, let_stmt.name.tokenLiteral());
    }
}

test "return statements" {
    const input =
        \\ return 5;
        \\ return 10;
        \\ return 838383;
    ;

    const alloc = std.testing.allocator;

    var l = Lexer.init(input);
    var p = init(&l);
    defer p.deinit(alloc);

    var program = try p.parseProgram(alloc);
    defer program.deinit(alloc);

    try checkParserErrors(&p);
    try std.testing.expectEqual(3, program.statements.len);

    for (program.statements) |stmt| {
        var return_stmt = stmt.val.return_stmt;
        try std.testing.expectEqualStrings("return", return_stmt.tokenLiteral());
    }
}

test "identifier expression" {
    const input = "foobar;";

    const alloc = std.testing.allocator;

    var l = Lexer.init(input);
    var p = init(&l);
    defer p.deinit(alloc);

    var program = try p.parseProgram(alloc);
    defer program.deinit(alloc);

    try checkParserErrors(&p);
    try std.testing.expectEqual(1, program.statements.len);

    var ident = program.statements[0].val.expression_stmt.expression.val.ident;
    try std.testing.expectEqualStrings("foobar", ident.value);
    try std.testing.expectEqualStrings("foobar", ident.tokenLiteral());
}

fn testIntegerLiteral(il: *const ast.Node(.Expression), value: i64) !void {
    var literal = il.val.int_literal;
    try std.testing.expectEqual(value, literal.value);

    var int_buf: [1024]u8 = undefined;
    const len = std.fmt.printInt(&int_buf, value, 10, .lower, .{});
    try std.testing.expectEqualStrings(int_buf[0..len], literal.tokenLiteral());
}

test "integer expression" {
    const input = "5;";

    const alloc = std.testing.allocator;

    var l = Lexer.init(input);
    var p = init(&l);
    defer p.deinit(alloc);

    var program = try p.parseProgram(alloc);
    defer program.deinit(alloc);

    try checkParserErrors(&p);
    try std.testing.expectEqual(1, program.statements.len);
    try testIntegerLiteral(program.statements[0].val.expression_stmt.expression, 5);
}

test "prefix expressions" {
    const alloc = std.testing.allocator;

    const tests = [_]struct {
        input: []const u8,
        operator: []const u8,
        integer_value: i64,
    }{
        .{ .input = "!5;", .operator = "!", .integer_value = 5 },
        .{ .input = "-15;", .operator = "-", .integer_value = 15 },
    };

    for (tests) |t| {
        var l = Lexer.init(t.input);
        var p = init(&l);
        defer p.deinit(alloc);

        var program = try p.parseProgram(alloc);
        defer program.deinit(alloc);

        try checkParserErrors(&p);
        try std.testing.expectEqual(1, program.statements.len);

        const exp = program.statements[0].val.expression_stmt.expression.val.prefix;
        try std.testing.expectEqualStrings(t.operator, exp.operator);
        try testIntegerLiteral(exp.right, t.integer_value);
    }
}

test "infix expressions" {
    const alloc = std.testing.allocator;

    const tests = [_]struct {
        input: []const u8,
        left_value: i64,
        operator: []const u8,
        right_value: i64,
    }{
        .{ .input = "5 + 5;", .left_value = 5, .operator = "+", .right_value = 5 },
        .{ .input = "5 - 5;", .left_value = 5, .operator = "-", .right_value = 5 },
        .{ .input = "5 * 5;", .left_value = 5, .operator = "*", .right_value = 5 },
        .{ .input = "5 / 5;", .left_value = 5, .operator = "/", .right_value = 5 },
        .{ .input = "5 > 5;", .left_value = 5, .operator = ">", .right_value = 5 },
        .{ .input = "5 < 5;", .left_value = 5, .operator = "<", .right_value = 5 },
        .{ .input = "5 == 5;", .left_value = 5, .operator = "==", .right_value = 5 },
        .{ .input = "5 != 5;", .left_value = 5, .operator = "!=", .right_value = 5 },
    };

    for (tests) |t| {
        var l = Lexer.init(t.input);
        var p = init(&l);
        defer p.deinit(alloc);

        var program = try p.parseProgram(alloc);
        defer program.deinit(alloc);

        try checkParserErrors(&p);
        try std.testing.expectEqual(1, program.statements.len);

        const exp = program.statements[0].val.expression_stmt.expression.val.infix;
        try testIntegerLiteral(exp.left, t.left_value);
        try std.testing.expectEqualStrings(t.operator, exp.operator);
        try testIntegerLiteral(exp.right, t.right_value);
    }
}

test "operator precedence" {
    const alloc = std.testing.allocator;

    const tests = [_]struct {
        input: []const u8,
        expected: []const u8,
    }{
        .{
            .input = "-a * b",
            .expected = "((-a) * b)",
        },
        .{
            .input = "!-a",
            .expected = "(!(-a))",
        },
        .{
            .input = "a + b + c",
            .expected = "((a + b) + c)",
        },
        .{
            .input = "a + b - c",
            .expected = "((a + b) - c)",
        },
        .{
            .input = "a * b * c",
            .expected = "((a * b) * c)",
        },
        .{
            .input = "a * b / c",
            .expected = "((a * b) / c)",
        },
        .{
            .input = "a + b / c",
            .expected = "(a + (b / c))",
        },
        .{
            .input = "a + b * c + d / e - f",
            .expected = "(((a + (b * c)) + (d / e)) - f)",
        },
        .{
            .input = "3 + 4; -5 * 5",
            .expected = "(3 + 4)((-5) * 5)",
        },
        .{
            .input = "5 > 4 == 3 < 4",
            .expected = "((5 > 4) == (3 < 4))",
        },
        .{
            .input = "5 < 4 != 3 > 4",
            .expected = "((5 < 4) != (3 > 4))",
        },
        .{
            .input = "3 + 4 * 5 == 3 * 1 + 4 * 5",
            .expected = "((3 + (4 * 5)) == ((3 * 1) + (4 * 5)))",
        },
    };

    for (tests) |t| {
        var l = Lexer.init(t.input);
        var p = init(&l);
        defer p.deinit(alloc);

        var program = try p.parseProgram(alloc);
        defer program.deinit(alloc);

        try checkParserErrors(&p);

        var buf: [1024]u8 = undefined;
        var writer = std.Io.Writer.fixed(&buf);

        try program.writeString(&writer);
        try writer.flush();

        try std.testing.expectEqualStrings(t.expected, buf[0..t.expected.len]);
    }
}
