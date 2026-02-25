const std = @import("std");

const ast = @import("ast.zig");
const Lexer = @import("lexer.zig");

test {
    std.testing.refAllDecls(@This());
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

fn parseStatement(self: *@This(), alloc: std.mem.Allocator) !?ast.Node(.Statement) {
    return switch (self.cur_token.token_type) {
        .LET => try self.parseLetStatement(alloc),
        .RETURN => self.parseReturnStatement(alloc),
        else => null,
    };
}

fn parseReturnStatement(self: *@This(), alloc: std.mem.Allocator) ast.Node(.Statement) {
    _ = alloc;

    const stmt = ast.ReturnStatement{ .token = self.cur_token };

    self.nextToken();

    // TODO: We're skipping the expressions until we encounter a semicolon
    while (self.cur_token.token_type != Lexer.TokenType.SEMICOLON) {
        self.nextToken();
    }

    return ast.Node(.Statement){ .val = .{ .return_stmt = stmt } };
}

fn parseLetStatement(self: *@This(), alloc: std.mem.Allocator) !?ast.Node(.Statement) {
    var stmt = ast.LetStatement{ .token = self.cur_token };

    if (!try self.expectPeek(alloc, Lexer.TokenType.IDENT)) return null;

    stmt.name = ast.Identifier{ .token = self.cur_token, .value = self.cur_token.literal };

    if (!try self.expectPeek(alloc, Lexer.TokenType.ASSIGN)) return null;

    // TODO: We're skipping the expressions until we encounter a semicolon
    while (self.cur_token.token_type != Lexer.TokenType.SEMICOLON) {
        self.nextToken();
    }

    return ast.Node(.Statement){ .val = .{ .let_stmt = stmt } };
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

    while (self.cur_token.token_type != Lexer.TokenType.EOF) {
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

        try std.testing.expectEqualStrings(stmt.tokenLiteral(), "let");

        var let_stmt = stmt.val.let_stmt;
        try std.testing.expectEqualStrings(t.expectedIdentifier, let_stmt.name.value);
        try std.testing.expectEqualStrings(t.expectedIdentifier, let_stmt.name.tokenLiteral());
    }
}

test "invalid let statements" {
    const input = "let 838383;";

    const alloc = std.testing.allocator;

    var l = Lexer.init(input);
    var p = init(&l);
    defer p.deinit(alloc);

    var program = try p.parseProgram(alloc);
    defer program.deinit(alloc);

    try std.testing.expectEqual(1, p.errors.items.len);
    try std.testing.expectEqualStrings("expected next token to be IDENT, got INT", p.errors.items[0]);
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
