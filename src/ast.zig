const std = @import("std");

const Lexer = @import("lexer.zig");

pub const NodeType = enum {
    Common,
    Statement,
    Expression,
};

pub fn Node(comptime T: NodeType) type {
    return switch (T) {
        .Common => union(enum) {
            program: Program,

            pub fn tokenLiteral(self: Node(T)) []const u8 {
                return switch (self) {
                    inline else => |node| node.tokenLiteral(),
                };
            }
        },
        .Statement => union(enum) {
            let_stmt: LetStatement,
            return_stmt: ReturnStatement,

            pub fn tokenLiteral(self: Node(T)) []const u8 {
                return switch (self) {
                    inline else => |node| node.tokenLiteral(),
                };
            }
        },
        .Expression => union(enum) {
            ident: Identifier,

            pub fn tokenLiteral(self: Node(T)) []const u8 {
                return switch (self) {
                    inline else => |node| node.tokenLiteral(),
                };
            }
        },
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
};

pub const LetStatement = struct {
    token: Lexer.Token,
    name: Identifier = undefined,
    value: Node(.Expression) = undefined,

    pub fn tokenLiteral(self: LetStatement) []const u8 {
        return self.token.literal;
    }
};

pub const Identifier = struct {
    token: Lexer.Token,
    value: []const u8,

    pub fn tokenLiteral(self: Identifier) []const u8 {
        return self.token.literal;
    }
};

pub const ReturnStatement = struct {
    token: Lexer.Token,
    return_value: Node(.Expression) = undefined,

    pub fn tokenLiteral(self: ReturnStatement) []const u8 {
        return self.token.literal;
    }
};
