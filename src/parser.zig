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
        .TRUE, .FALSE => parseBoolean,
        .BANG, .MINUS => parsePrefixExpression,
        .LPAREN => parseGroupedExpression,
        .IF => parseIfExpression,
        .FUNCTION => parseFunctionLiteral,
        else => error.UnrecognisedTokenType,
    };
}

inline fn getInfixParseFnFromNodeType(token_type: Lexer.TokenType) !InfixParseFn {
    return switch (token_type) {
        .PLUS, .MINUS, .SLASH, .ASTERISK, .EQ, .NOT_EQ, .LT, .GT => parseInfixExpression,
        .LPAREN => parseCallExpression,
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

fn parseStatement(self: *@This(), alloc: std.mem.Allocator) !ast.Node(.Statement) {
    return switch (self.cur_token.token_type) {
        .LET => try self.parseLetStatement(alloc),
        .RETURN => try self.parseReturnStatement(alloc),
        else => try self.parseExpressionStatement(alloc),
    };
}

fn parseReturnStatement(self: *@This(), alloc: std.mem.Allocator) !ast.Node(.Statement) {
    const return_tok = self.cur_token;

    self.nextToken();

    const return_val = try self.parseExpression(alloc, .lowest);

    if (self.peek_token.token_type == .SEMICOLON) self.nextToken();

    return ast.Node(.Statement){ .val = .{ .return_stmt = try ast.ReturnStatement.init(
        alloc,
        return_tok,
        return_val,
    ) } };
}

fn parseLetStatement(self: *@This(), alloc: std.mem.Allocator) !ast.Node(.Statement) {
    const let_tok = self.cur_token;

    if (!try self.expectPeek(alloc, Lexer.TokenType.IDENT)) return error.ParseError;

    const stmt_name = ast.Identifier{ .token = self.cur_token, .value = self.cur_token.literal };

    if (!try self.expectPeek(alloc, Lexer.TokenType.ASSIGN)) return error.ParseError;

    self.nextToken();

    const stmt_value = try self.parseExpression(alloc, .lowest);

    if (self.peek_token.token_type == .SEMICOLON) self.nextToken();

    const stmt = try ast.LetStatement.init(
        alloc,
        let_tok,
        stmt_name,
        stmt_value,
    );

    return ast.Node(.Statement){ .val = .{ .let_stmt = stmt } };
}

fn parseExpressionStatement(self: *@This(), alloc: std.mem.Allocator) !ast.Node(.Statement) {
    var exp = try self.parseExpression(alloc, .lowest);
    errdefer exp.deinit(alloc);

    const stmt = try ast.ExpressionStatement.init(
        alloc,
        self.cur_token,
        exp,
    );

    if (self.peek_token.token_type == .SEMICOLON) self.nextToken();

    return ast.Node(.Statement){ .val = .{ .expression_stmt = stmt } };
}

fn parseBlockStatement(self: *@This(), alloc: std.mem.Allocator) !ast.BlockStatement {
    var stmts = std.ArrayList(ast.Node(.Statement)).empty;
    errdefer {
        for (stmts.items) |stmt| {
            stmt.deinit(alloc);
        }
        stmts.deinit(alloc);
    }

    self.nextToken();

    while (self.cur_token.token_type != .RBRACE and self.cur_token.token_type != .EOF) {
        const stmt = try self.parseStatement(alloc);
        errdefer stmt.deinit(alloc);

        try stmts.append(alloc, stmt);

        self.nextToken();
    }

    return ast.BlockStatement{ .token = self.cur_token, .statements = try stmts.toOwnedSlice(alloc) };
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
        .LPAREN => .call,
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
    const prefix = getPrefixParseFnFromNodeType(self.cur_token.token_type) catch {
        try self.errors.append(
            alloc,
            try std.fmt.allocPrint(
                alloc,
                "no prefix function is recognised for token {s}",
                .{@tagName(self.cur_token.token_type)},
            ),
        );
        return error.ParseError;
    };

    var left_exp = try prefix(self, alloc);
    errdefer left_exp.deinit(alloc);

    while (self.peek_token.token_type != .SEMICOLON and @intFromEnum(prec) < @intFromEnum(self.peekPrecedence())) {
        const inflix = getInfixParseFnFromNodeType(self.peek_token.token_type) catch {
            return left_exp;
        };

        self.nextToken();

        left_exp = try inflix(self, alloc, left_exp);
        errdefer left_exp.deinit(alloc);
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

fn parseBoolean(self: *@This(), _: std.mem.Allocator) !ast.Node(.Expression) {
    return ast.Node(.Expression){ .val = .{
        .boolean = .{ .token = self.cur_token, .value = self.cur_token.token_type == .TRUE },
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

fn parseCallExpression(self: *@This(), alloc: std.mem.Allocator, function: ast.Node(.Expression)) !ast.Node(.Expression) {
    return ast.Node(.Expression){ .val = .{
        .call_exp = try ast.CallExpression.init(
            alloc,
            self.cur_token,
            function,
            try self.parseCallArguments(alloc),
        ),
    } };
}

fn parseCallArguments(self: *@This(), alloc: std.mem.Allocator) ![]ast.Node(.Expression) {
    var args = std.ArrayList(ast.Node(.Expression)).empty;

    if (self.peek_token.token_type == .RPAREN) {
        self.nextToken();
        return try args.toOwnedSlice(alloc);
    }

    self.nextToken();

    try args.append(alloc, try self.parseExpression(alloc, .lowest));
    errdefer args.deinit(alloc);

    while (self.peek_token.token_type == .COMMA) {
        self.nextToken();
        self.nextToken();

        try args.append(alloc, try self.parseExpression(alloc, .lowest));
    }

    if (!try self.expectPeek(alloc, .RPAREN)) return error.ParseError;

    return try args.toOwnedSlice(alloc);
}

fn parseGroupedExpression(self: *@This(), alloc: std.mem.Allocator) !ast.Node(.Expression) {
    self.nextToken();

    const exp = try self.parseExpression(alloc, .lowest);
    errdefer exp.deinit(alloc);

    if (!try self.expectPeek(alloc, .RPAREN)) return error.ParseError;

    return exp;
}

fn parseIfExpression(self: *@This(), alloc: std.mem.Allocator) !ast.Node(.Expression) {
    const if_tok = self.cur_token;

    if (!try self.expectPeek(alloc, .LPAREN)) return error.ParseError;

    self.nextToken();

    const exp_condition = try self.parseExpression(alloc, .lowest);
    errdefer exp_condition.deinit(alloc);

    if (!try self.expectPeek(alloc, .RPAREN)) return error.ParseError;
    if (!try self.expectPeek(alloc, .LBRACE)) return error.ParseError;

    const exp_consequence = try self.parseBlockStatement(alloc);
    errdefer exp_consequence.deinit(alloc);

    var alt: ?ast.BlockStatement = null;
    if (self.peek_token.token_type == .ELSE) {
        self.nextToken();

        if (!try self.expectPeek(alloc, .LBRACE)) return error.ParseError;

        alt = try self.parseBlockStatement(alloc);
    }

    return ast.Node(.Expression){ .val = .{
        .if_exp = try ast.IfExpression.init(
            alloc,
            if_tok,
            exp_condition,
            exp_consequence,
            alt,
        ),
    } };
}

fn parseFunctionLiteral(self: *@This(), alloc: std.mem.Allocator) !ast.Node(.Expression) {
    const lit_tok = self.cur_token;

    if (!try self.expectPeek(alloc, .LPAREN)) return error.ParseError;

    const params = try self.parseFunctionParameters(alloc);
    errdefer alloc.free(params);

    if (!try self.expectPeek(alloc, .LBRACE)) return error.ParseError;

    const body = try self.parseBlockStatement(alloc);
    errdefer body.deinit(alloc);

    return ast.Node(.Expression){ .val = .{
        .fn_literal = try ast.FunctionLiteral.init(
            alloc,
            lit_tok,
            params,
            body,
        ),
    } };
}

fn parseFunctionParameters(self: *@This(), alloc: std.mem.Allocator) ![]ast.Identifier {
    var idents = std.ArrayList(ast.Identifier).empty;

    if (self.peek_token.token_type == .RPAREN) {
        self.nextToken();
        return try idents.toOwnedSlice(alloc);
    }

    self.nextToken();

    try idents.append(alloc, ast.Identifier{ .token = self.cur_token, .value = self.cur_token.literal });
    errdefer idents.deinit(alloc);

    while (self.peek_token.token_type == .COMMA) {
        self.nextToken();
        self.nextToken();

        try idents.append(alloc, ast.Identifier{ .token = self.cur_token, .value = self.cur_token.literal });
    }

    if (!try self.expectPeek(alloc, .RPAREN)) return error.ParseError;

    return try idents.toOwnedSlice(alloc);
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
    var stmts = std.ArrayList(ast.Node(.Statement)).empty;
    errdefer {
        for (stmts.items) |stmt| {
            stmt.deinit(alloc);
        }
        stmts.deinit(alloc);
    }

    while (self.cur_token.token_type != .EOF) {
        defer self.nextToken();

        const stmt = self.parseStatement(alloc) catch |err| {
            switch (err) {
                error.ParseError => continue,
                else => return err,
            }
        };

        try stmts.append(alloc, stmt);
    }

    return ast.Program{ .statements = try stmts.toOwnedSlice(alloc) };
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
    const alloc = std.testing.allocator;

    const tests = [_]struct {
        input: []const u8,
        expectedIdentifier: []const u8,
        expectedValue: []const u8,
    }{
        .{ .input = "let x = 5;", .expectedIdentifier = "x", .expectedValue = "5" },
        .{ .input = "let y = true;", .expectedIdentifier = "y", .expectedValue = "true" },
        .{ .input = "let foobar = y;", .expectedIdentifier = "foobar", .expectedValue = "y" },
    };

    for (tests) |t| {
        var l = Lexer.init(t.input);
        var p = init(&l);
        defer p.deinit(alloc);

        var program = try p.parseProgram(alloc);
        defer program.deinit(alloc);

        try checkParserErrors(&p);
        try std.testing.expectEqual(1, program.statements.len);

        const stmt = program.statements[0];

        try std.testing.expectEqualStrings("let", stmt.tokenLiteral());

        var let_stmt = stmt.val.let_stmt;
        try std.testing.expectEqualStrings(t.expectedIdentifier, let_stmt.name.value);
        try std.testing.expectEqualStrings(t.expectedIdentifier, let_stmt.name.tokenLiteral());
        try std.testing.expectEqualStrings(t.expectedValue, let_stmt.value.tokenLiteral());
    }
}

test "return statements" {
    const alloc = std.testing.allocator;

    const tests = [_]struct {
        input: []const u8,
        expectedValue: []const u8,
    }{
        .{ .input = "return 5;", .expectedValue = "5" },
        .{ .input = "return true;", .expectedValue = "true" },
        .{ .input = "return y;", .expectedValue = "y" },
    };

    for (tests) |t| {
        var l = Lexer.init(t.input);
        var p = init(&l);
        defer p.deinit(alloc);

        var program = try p.parseProgram(alloc);
        defer program.deinit(alloc);

        try checkParserErrors(&p);
        try std.testing.expectEqual(1, program.statements.len);

        const stmt = program.statements[0];

        try std.testing.expectEqualStrings("return", stmt.tokenLiteral());

        var return_stmt = stmt.val.return_stmt;
        try std.testing.expectEqualStrings(t.expectedValue, return_stmt.return_value.tokenLiteral());
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

test "boolean expression" {
    const input = "true;";

    const alloc = std.testing.allocator;

    var l = Lexer.init(input);
    var p = init(&l);
    defer p.deinit(alloc);

    var program = try p.parseProgram(alloc);
    defer program.deinit(alloc);

    try checkParserErrors(&p);
    try std.testing.expectEqual(1, program.statements.len);

    var boolean = program.statements[0].val.expression_stmt.expression.val.boolean;
    try std.testing.expectEqual(true, boolean.value);
    try std.testing.expectEqualStrings("true", boolean.tokenLiteral());
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

test "if expression" {
    const input = "if (x < y) { x }";

    const alloc = std.testing.allocator;

    var l = Lexer.init(input);
    var p = init(&l);
    defer p.deinit(alloc);

    var program = try p.parseProgram(alloc);
    defer program.deinit(alloc);

    try checkParserErrors(&p);
    try std.testing.expectEqual(1, program.statements.len);

    const if_exp = program.statements[0].val.expression_stmt.expression.val.if_exp;
    const cond_infix = if_exp.condition.val.infix;
    try std.testing.expectEqualStrings("x", cond_infix.left.tokenLiteral());
    try std.testing.expectEqualStrings("<", cond_infix.operator);
    try std.testing.expectEqualStrings("y", cond_infix.right.tokenLiteral());

    try std.testing.expectEqual(1, if_exp.consequence.statements.len);
    const conseq_exp = if_exp.consequence.statements[0].val.expression_stmt.expression;
    try std.testing.expectEqualStrings("x", conseq_exp.val.ident.value);

    try std.testing.expectEqual(null, if_exp.alternative);
}

test "if-else expression" {
    const input = "if (x < y) { x } else { y }";

    const alloc = std.testing.allocator;

    var l = Lexer.init(input);
    var p = init(&l);
    defer p.deinit(alloc);

    var program = try p.parseProgram(alloc);
    defer program.deinit(alloc);

    try checkParserErrors(&p);
    try std.testing.expectEqual(1, program.statements.len);

    const if_exp = program.statements[0].val.expression_stmt.expression.val.if_exp;
    const cond_infix = if_exp.condition.val.infix;
    try std.testing.expectEqualStrings("x", cond_infix.left.tokenLiteral());
    try std.testing.expectEqualStrings("<", cond_infix.operator);
    try std.testing.expectEqualStrings("y", cond_infix.right.tokenLiteral());

    try std.testing.expectEqual(1, if_exp.consequence.statements.len);
    const conseq_exp = if_exp.consequence.statements[0].val.expression_stmt.expression;
    try std.testing.expectEqualStrings("x", conseq_exp.val.ident.value);

    try std.testing.expect(if_exp.alternative != null);
    const alt_exp = if_exp.alternative.?.statements[0].val.expression_stmt.expression;
    try std.testing.expectEqualStrings("y", alt_exp.val.ident.value);
}

test "function literal expression" {
    const input = "fn(x, y) { x + y; }";

    const alloc = std.testing.allocator;

    var l = Lexer.init(input);
    var p = init(&l);
    defer p.deinit(alloc);

    var program = try p.parseProgram(alloc);
    defer program.deinit(alloc);

    try checkParserErrors(&p);
    try std.testing.expectEqual(1, program.statements.len);

    const fn_exp = program.statements[0].val.expression_stmt.expression.val.fn_literal;
    try std.testing.expectEqual(2, fn_exp.parameters.len);
    try std.testing.expectEqualStrings("x", fn_exp.parameters[0].value);
    try std.testing.expectEqualStrings("y", fn_exp.parameters[1].value);

    try std.testing.expectEqual(1, fn_exp.body.statements.len);
    const body_infix = fn_exp.body.statements[0].val.expression_stmt.expression.val.infix;
    try std.testing.expectEqualStrings("x", body_infix.left.tokenLiteral());
    try std.testing.expectEqualStrings("+", body_infix.operator);
    try std.testing.expectEqualStrings("y", body_infix.right.tokenLiteral());
}

test "function parameters" {
    const alloc = std.testing.allocator;

    const tests = [_]struct {
        input: []const u8,
        expectedParams: []const []const u8,
    }{
        .{ .input = "fn() {};", .expectedParams = &[_][]const u8{} },
        .{ .input = "fn(x) {};", .expectedParams = &[_][]const u8{"x"} },
        .{ .input = "fn(x, y, z) {};", .expectedParams = &[_][]const u8{ "x", "y", "z" } },
    };

    for (tests) |t| {
        var l = Lexer.init(t.input);
        var p = init(&l);
        defer p.deinit(alloc);

        var program = try p.parseProgram(alloc);
        defer program.deinit(alloc);

        try checkParserErrors(&p);
        try std.testing.expectEqual(1, program.statements.len);

        const func = program.statements[0].val.expression_stmt.expression.val.fn_literal;
        try std.testing.expectEqual(t.expectedParams.len, func.parameters.len);
        for (0.., t.expectedParams) |i, expectedParam| {
            try std.testing.expectEqualStrings(expectedParam, func.parameters[i].value);
        }
    }
}

test "call expression" {
    const input = "add(1, 2 * 3, 4 + 5);";

    const alloc = std.testing.allocator;

    var l = Lexer.init(input);
    var p = init(&l);
    defer p.deinit(alloc);

    var program = try p.parseProgram(alloc);
    defer program.deinit(alloc);

    try checkParserErrors(&p);
    try std.testing.expectEqual(1, program.statements.len);

    const call_exp = program.statements[0].val.expression_stmt.expression.val.call_exp;
    try std.testing.expectEqualStrings("add", call_exp.function.val.ident.tokenLiteral());

    try std.testing.expectEqual(3, call_exp.arguments.len);
    try testIntegerLiteral(&call_exp.arguments[0], 1);

    const arg2_infix = call_exp.arguments[1].val.infix;
    try std.testing.expectEqualStrings("2", arg2_infix.left.tokenLiteral());
    try std.testing.expectEqualStrings("*", arg2_infix.operator);
    try std.testing.expectEqualStrings("3", arg2_infix.right.tokenLiteral());

    const arg3_infix = call_exp.arguments[2].val.infix;
    try std.testing.expectEqualStrings("4", arg3_infix.left.tokenLiteral());
    try std.testing.expectEqualStrings("+", arg3_infix.operator);
    try std.testing.expectEqualStrings("5", arg3_infix.right.tokenLiteral());
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
        .{
            .input = "true",
            .expected = "true",
        },
        .{
            .input = "false",
            .expected = "false",
        },
        .{
            .input = "3 > 5 == false",
            .expected = "((3 > 5) == false)",
        },
        .{
            .input = "3 < 5 == true",
            .expected = "((3 < 5) == true)",
        },
        .{
            .input = "1 + (2 + 3) + 4",
            .expected = "((1 + (2 + 3)) + 4)",
        },
        .{
            .input = "(5 + 5) * 2",
            .expected = "((5 + 5) * 2)",
        },
        .{
            .input = "2 / (5 + 5)",
            .expected = "(2 / (5 + 5))",
        },
        .{
            .input = "-(5 + 5)",
            .expected = "(-(5 + 5))",
        },
        .{
            .input = "!(true == true)",
            .expected = "(!(true == true))",
        },
        .{
            .input = "a + add(b * c) + d",
            .expected = "((a + add((b * c))) + d)",
        },
        .{
            .input = "add(a, b, 1, 2 * 3, 4 + 5, add(6, 7 * 8))",
            .expected = "add(a, b, 1, (2 * 3), (4 + 5), add(6, (7 * 8)))",
        },
        .{
            .input = "add(a + b + c * d / f + g)",
            .expected = "add((((a + b) + ((c * d) / f)) + g))",
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
