const std = @import("std");

const Lexer = @import("lexer.zig");

pub const NodeType = enum {
    Common,
    Statement,
    Expression,
};

pub const CommonNode = union(enum) {
    program: Program,
};

pub const StatementNode = union(enum) {
    let_stmt: LetStatement,
    return_stmt: ReturnStatement,
    expression_stmt: ExpressionStatement,
};

pub const ExpressionNode = union(enum) {
    ident: Identifier,
};

pub fn Node(comptime T: NodeType) type {
    const NodeUnion = switch (T) {
        .Common => CommonNode,
        .Statement => StatementNode,
        .Expression => ExpressionNode,
    };

    return struct {
        val: NodeUnion,

        pub fn tokenLiteral(self: Node(T)) []const u8 {
            return switch (self.val) {
                inline else => |node| node.tokenLiteral(),
            };
        }

        pub fn writeString(self: Node(T), writer: *std.Io.Writer) !void {
            return switch (self.val) {
                inline else => |node| node.writeString(writer),
            };
        }
    };
}

pub const Program = struct {
    statements: []Node(.Statement) = undefined,

    pub fn deinit(self: *Program, alloc: std.mem.Allocator) void {
        alloc.free(self.statements);
    }

    pub fn tokenLiteral(self: Program) []const u8 {
        if (self.statements.len > 0) {
            return self.statements[0].tokenLiteral();
        }

        return "";
    }

    pub fn writeString(self: Program, writer: *std.Io.Writer) !void {
        for (self.statements) |stmt| {
            try stmt.writeString(writer);
        }
    }

    test writeString {
        const program = Program{
            .statements = @constCast(&[_]Node(.Statement){
                .{ .val = .{
                    .let_stmt = LetStatement{
                        .token = Lexer.Token{ .token_type = Lexer.TokenType.LET, .literal = "let" },
                        .name = Identifier{
                            .token = Lexer.Token{ .token_type = Lexer.TokenType.IDENT, .literal = "myVar" },
                            .value = "myVar",
                        },
                        .value = Node(.Expression){ .val = .{
                            .ident = Identifier{
                                .token = Lexer.Token{ .token_type = Lexer.TokenType.IDENT, .literal = "anotherVar" },
                                .value = "anotherVar",
                            },
                        } },
                    },
                } },
            }),
        };

        var res_buf: [23]u8 = undefined;
        var writer = std.Io.Writer.fixed(&res_buf);

        try program.writeString(&writer);
        try writer.flush();

        try std.testing.expectEqualStrings("let myVar = anotherVar;", &res_buf);
    }
};

pub const LetStatement = struct {
    token: Lexer.Token,
    name: Identifier = undefined,
    value: Node(.Expression) = undefined,

    pub fn tokenLiteral(self: LetStatement) []const u8 {
        return self.token.literal;
    }

    pub fn writeString(self: LetStatement, writer: *std.Io.Writer) !void {
        try writer.print("{s} ", .{self.tokenLiteral()});
        try self.name.writeString(writer);
        _ = try writer.write(" = ");
        try self.value.writeString(writer);
        _ = try writer.write(";");
    }
};

pub const Identifier = struct {
    token: Lexer.Token,
    value: []const u8,

    pub fn tokenLiteral(self: Identifier) []const u8 {
        return self.token.literal;
    }

    pub fn writeString(self: Identifier, writer: *std.Io.Writer) !void {
        _ = try writer.write(self.value);
    }
};

pub const ReturnStatement = struct {
    token: Lexer.Token,
    return_value: Node(.Expression) = undefined,

    pub fn tokenLiteral(self: ReturnStatement) []const u8 {
        return self.token.literal;
    }

    pub fn writeString(self: ReturnStatement, writer: *std.Io.Writer) !void {
        try writer.print("{s} ", .{self.tokenLiteral()});
        try self.return_value.writeString(writer);
        _ = try writer.write(";");
    }
};

pub const ExpressionStatement = struct {
    token: Lexer.Token,
    expression: Node(.Expression) = undefined,

    pub fn tokenLiteral(self: ExpressionStatement) []const u8 {
        return self.token.literal;
    }

    pub fn writeString(self: ExpressionStatement, writer: *std.Io.Writer) !void {
        try self.expression.writeString(writer);
    }
};

test {
    std.testing.refAllDecls(@This());
}
