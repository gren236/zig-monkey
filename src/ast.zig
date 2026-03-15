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
    int_literal: IntegerLiteral,
    boolean: Boolean,
    prefix: PrefixExpression,
    infix: InfixExpression,
    if_exp: IfExpression,
    fn_literal: FunctionLiteral,
    call_exp: CallExpression,

    noop: NoopExpression,
};

pub fn Node(comptime T: NodeType) type {
    const NodeUnion = switch (T) {
        .Common => CommonNode,
        .Statement => StatementNode,
        .Expression => ExpressionNode,
    };

    return struct {
        val: NodeUnion,

        pub fn deinit(self: Node(T), alloc: std.mem.Allocator) void {
            return switch (self.val) {
                inline else => |node| node.deinit(alloc),
            };
        }

        pub fn tokenLiteral(self: Node(T)) []const u8 {
            return switch (self.val) {
                inline else => |node| node.tokenLiteral(),
            };
        }

        pub fn writeString(self: Node(T), writer: *std.Io.Writer) anyerror!void {
            return switch (self.val) {
                inline else => |node| node.writeString(writer),
            };
        }
    };
}

pub const Program = struct {
    statements: []Node(.Statement) = undefined,

    pub fn deinit(self: *Program, alloc: std.mem.Allocator) void {
        for (self.statements) |stmt| {
            stmt.deinit(alloc);
        }

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
                        .value = &Node(.Expression){ .val = .{
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

pub const ReturnStatement = struct {
    token: Lexer.Token,
    return_value: *const Node(.Expression),

    pub fn init(alloc: std.mem.Allocator, tok: Lexer.Token, return_value: Node(.Expression)) !ReturnStatement {
        const exp_ptr = try alloc.create(Node(.Expression));
        exp_ptr.* = return_value;

        return .{ .token = tok, .return_value = exp_ptr };
    }

    pub fn deinit(self: ReturnStatement, alloc: std.mem.Allocator) void {
        self.return_value.deinit(alloc);
        alloc.destroy(self.return_value);
    }

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
    expression: *const Node(.Expression),

    pub fn init(alloc: std.mem.Allocator, tok: Lexer.Token, exp: Node(.Expression)) !ExpressionStatement {
        const exp_ptr = try alloc.create(Node(.Expression));
        exp_ptr.* = exp;

        return .{ .token = tok, .expression = exp_ptr };
    }

    pub fn deinit(self: ExpressionStatement, alloc: std.mem.Allocator) void {
        self.expression.deinit(alloc);
        alloc.destroy(self.expression);
    }

    pub fn tokenLiteral(self: ExpressionStatement) []const u8 {
        return self.token.literal;
    }

    pub fn writeString(self: ExpressionStatement, writer: *std.Io.Writer) !void {
        try self.expression.writeString(writer);
    }
};

pub const LetStatement = struct {
    token: Lexer.Token,
    name: Identifier,
    value: *const Node(.Expression),

    pub fn init(alloc: std.mem.Allocator, tok: Lexer.Token, name: Identifier, exp: Node(.Expression)) !LetStatement {
        const exp_ptr = try alloc.create(Node(.Expression));
        exp_ptr.* = exp;

        return .{ .token = tok, .name = name, .value = exp_ptr };
    }

    pub fn deinit(self: LetStatement, alloc: std.mem.Allocator) void {
        self.value.deinit(alloc);
        alloc.destroy(self.value);
    }

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

pub const BlockStatement = struct {
    token: Lexer.Token,
    statements: []Node(.Statement) = undefined,

    pub fn deinit(self: BlockStatement, alloc: std.mem.Allocator) void {
        for (self.statements) |stmt| {
            stmt.deinit(alloc);
        }

        alloc.free(self.statements);
    }

    pub fn tokenLiteral(self: BlockStatement) []const u8 {
        return self.token.literal;
    }

    pub fn writeString(self: BlockStatement, writer: *std.Io.Writer) !void {
        for (self.statements) |stmt| {
            try stmt.writeString(writer);
        }
    }
};

pub const Identifier = struct {
    token: Lexer.Token,
    value: []const u8,

    pub fn deinit(_: Identifier, _: std.mem.Allocator) void {}

    pub fn tokenLiteral(self: Identifier) []const u8 {
        return self.token.literal;
    }

    pub fn writeString(self: Identifier, writer: *std.Io.Writer) !void {
        _ = try writer.write(self.value);
    }
};

pub const IntegerLiteral = struct {
    token: Lexer.Token,
    value: i64,

    pub fn deinit(_: IntegerLiteral, _: std.mem.Allocator) void {}

    pub fn tokenLiteral(self: IntegerLiteral) []const u8 {
        return self.token.literal;
    }

    pub fn writeString(self: IntegerLiteral, writer: *std.Io.Writer) !void {
        _ = try writer.write(self.token.literal);
    }
};

pub const Boolean = struct {
    token: Lexer.Token,
    value: bool,

    pub fn deinit(_: Boolean, _: std.mem.Allocator) void {}

    pub fn tokenLiteral(self: Boolean) []const u8 {
        return self.token.literal;
    }

    pub fn writeString(self: Boolean, writer: *std.Io.Writer) !void {
        _ = try writer.write(self.token.literal);
    }
};

pub const PrefixExpression = struct {
    token: Lexer.Token,
    operator: []const u8,
    right: *const Node(.Expression),

    pub fn init(alloc: std.mem.Allocator, tok: Lexer.Token, operator: []const u8, right: Node(.Expression)) !PrefixExpression {
        const exp_ptr = try alloc.create(Node(.Expression));
        exp_ptr.* = right;

        return .{ .token = tok, .operator = operator, .right = exp_ptr };
    }

    pub fn deinit(self: PrefixExpression, alloc: std.mem.Allocator) void {
        self.right.deinit(alloc);
        alloc.destroy(self.right);
    }

    pub fn tokenLiteral(self: PrefixExpression) []const u8 {
        return self.token.literal;
    }

    pub fn writeString(self: PrefixExpression, writer: *std.Io.Writer) !void {
        _ = try writer.write("(");
        _ = try writer.write(self.operator);
        try self.right.writeString(writer);
        _ = try writer.write(")");
    }
};

pub const InfixExpression = struct {
    token: Lexer.Token,
    left: *const Node(.Expression),
    operator: []const u8,
    right: *const Node(.Expression),

    pub fn init(alloc: std.mem.Allocator, tok: Lexer.Token, left: Node(.Expression), operator: []const u8, right: Node(.Expression)) !InfixExpression {
        const left_ptr = try alloc.create(Node(.Expression));
        left_ptr.* = left;

        const right_ptr = try alloc.create(Node(.Expression));
        right_ptr.* = right;

        return .{
            .token = tok,
            .left = left_ptr,
            .operator = operator,
            .right = right_ptr,
        };
    }

    pub fn deinit(self: InfixExpression, alloc: std.mem.Allocator) void {
        self.left.deinit(alloc);
        self.right.deinit(alloc);
        alloc.destroy(self.left);
        alloc.destroy(self.right);
    }

    pub fn tokenLiteral(self: InfixExpression) []const u8 {
        return self.token.literal;
    }

    pub fn writeString(self: InfixExpression, writer: *std.Io.Writer) !void {
        _ = try writer.write("(");
        try self.left.writeString(writer);
        try writer.print(" {s} ", .{self.operator});
        try self.right.writeString(writer);
        _ = try writer.write(")");
    }
};

pub const IfExpression = struct {
    token: Lexer.Token,
    condition: *const Node(.Expression),
    consequence: *const BlockStatement,
    alternative: ?*const BlockStatement = null,

    pub fn init(alloc: std.mem.Allocator, tok: Lexer.Token, condition: Node(.Expression), cons: BlockStatement, alt: ?BlockStatement) !IfExpression {
        const cond_ptr = try alloc.create(Node(.Expression));
        cond_ptr.* = condition;

        const cons_ptr = try alloc.create(BlockStatement);
        cons_ptr.* = cons;

        var exp = IfExpression{
            .token = tok,
            .condition = cond_ptr,
            .consequence = cons_ptr,
        };

        if (alt) |alt_val| {
            const alt_ptr = try alloc.create(BlockStatement);
            alt_ptr.* = alt_val;
            exp.alternative = alt_ptr;
        }

        return exp;
    }

    pub fn deinit(self: IfExpression, alloc: std.mem.Allocator) void {
        self.condition.deinit(alloc);
        alloc.destroy(self.condition);
        self.consequence.deinit(alloc);
        alloc.destroy(self.consequence);
        if (self.alternative) |alt| {
            alt.deinit(alloc);
            alloc.destroy(alt);
        }
    }

    pub fn tokenLiteral(self: IfExpression) []const u8 {
        return self.token.literal;
    }

    pub fn writeString(self: IfExpression, writer: *std.Io.Writer) !void {
        _ = try writer.write("if");
        try self.condition.writeString(writer);
        _ = try writer.write(" ");
        try self.consequence.writeString(writer);

        if (self.alternative != null) {
            _ = try writer.write("else ");
            try self.alternative.?.writeString(writer);
        }
    }
};

pub const FunctionLiteral = struct {
    token: Lexer.Token,
    parameters: []Identifier,
    body: *const BlockStatement,

    pub fn init(alloc: std.mem.Allocator, tok: Lexer.Token, params: []Identifier, body: BlockStatement) !FunctionLiteral {
        const block_ptr = try alloc.create(BlockStatement);
        block_ptr.* = body;

        return .{
            .token = tok,
            .parameters = params,
            .body = block_ptr,
        };
    }

    pub fn deinit(self: FunctionLiteral, alloc: std.mem.Allocator) void {
        for (self.parameters) |param| {
            param.deinit(alloc);
        }
        alloc.free(self.parameters);
        self.body.deinit(alloc);
        alloc.destroy(self.body);
    }

    pub fn tokenLiteral(self: FunctionLiteral) []const u8 {
        return self.token.literal;
    }

    pub fn writeString(self: FunctionLiteral, writer: *std.Io.Writer) !void {
        _ = try writer.write(self.tokenLiteral());
        _ = try writer.write("(");

        for (0.., self.parameters) |i, param| {
            if (i != 0) _ = try writer.write(", ");
            try param.writeString(writer);
        }

        _ = try writer.write(") ");
        try self.body.writeString(writer);
    }
};

pub const CallExpression = struct {
    token: Lexer.Token,
    function: *const Node(.Expression),
    arguments: []Node(.Expression),

    pub fn init(alloc: std.mem.Allocator, tok: Lexer.Token, func: Node(.Expression), args: []Node(.Expression)) !CallExpression {
        const func_ptr = try alloc.create(Node(.Expression));
        func_ptr.* = func;

        return .{
            .token = tok,
            .function = func_ptr,
            .arguments = args,
        };
    }

    pub fn deinit(self: CallExpression, alloc: std.mem.Allocator) void {
        for (self.arguments) |arg| {
            arg.deinit(alloc);
        }
        alloc.free(self.arguments);
        self.function.deinit(alloc);
        alloc.destroy(self.function);
    }

    pub fn tokenLiteral(self: CallExpression) []const u8 {
        return self.token.literal;
    }

    pub fn writeString(self: CallExpression, writer: *std.Io.Writer) !void {
        try self.function.writeString(writer);
        _ = try writer.write("(");

        for (0.., self.arguments) |i, arg| {
            if (i != 0) _ = try writer.write(", ");
            try arg.writeString(writer);
        }

        _ = try writer.write(")");
    }
};

pub fn debugPrintNode(node: anytype) !void {
    var buf: [1024]u8 = undefined;
    var stdout_writer = std.fs.File.stdout().writer(&buf);
    var writer = &stdout_writer.interface;
    try node.writeString(writer);
    try writer.flush();
}

// TODO for testing purposes, delete later
pub const NoopExpression = struct {
    pub fn deinit(self: NoopExpression, _: std.mem.Allocator) void {
        _ = self;
    }

    pub fn tokenLiteral(self: NoopExpression) []const u8 {
        _ = self;
        return "noop";
    }

    pub fn writeString(self: NoopExpression, writer: *std.Io.Writer) !void {
        _ = self;
        _ = try writer.write("noop");
    }
};

test {
    std.testing.refAllDecls(@This());
}
