const std = @import("std");

const TokenKeyword = enum {
    @"fn",
    let,
};

pub const TokenType = enum {
    ILLEGAL,
    EOF,

    // Identifiers + literals
    IDENT,
    INT,

    // Operators
    ASSIGN,
    PLUS,

    // Delimiters
    COMMA,
    SEMICOLON,

    LPAREN,
    RPAREN,
    LBRACE,
    RBRACE,

    // Keywords
    FUNCTION,
    LET,

    inline fn lookupIdent(ident: []const u8) TokenType {
        const tok_keyword = std.meta.stringToEnum(TokenKeyword, ident) orelse return .IDENT;
        return switch (tok_keyword) {
            TokenKeyword.@"fn" => .FUNCTION,
            TokenKeyword.let => .LET,
        };
    }
};

pub const Token = struct {
    token_type: TokenType,
    literal: []const u8,
};

input: []const u8,
position: usize = 0,
read_position: usize = 0,
ch: u8 = 0, // ASCII "NUL"

pub fn init(input: []const u8) @This() {
    var l = @This(){
        .input = input,
    };
    l.readChar();

    return l;
}

fn readChar(self: *@This()) void {
    if (self.read_position >= self.input.len) {
        self.ch = 0;
    } else {
        self.ch = self.input[self.read_position];
    }

    self.position = self.read_position;
    self.read_position += 1;
}

fn skipWhitespace(self: *@This()) void {
    while (self.ch == ' ' or self.ch == '\t' or self.ch == '\n' or self.ch == '\r') {
        self.readChar();
    }
}

inline fn getCurrentCharString(self: *@This()) []const u8 {
    return self.input[self.position .. self.position + 1];
}

inline fn isLetter(ch: u8) bool {
    return 'a' <= ch and ch <= 'z' or 'A' <= ch and ch <= 'Z' or ch == '_';
}

fn readIdentifier(self: *@This()) []const u8 {
    const start_pos = self.position;
    while (isLetter(self.ch)) {
        self.readChar();
    }

    return self.input[start_pos..self.position];
}

inline fn isDigit(ch: u8) bool {
    return '0' <= ch and ch <= '9';
}

fn readNumber(self: *@This()) []const u8 {
    const start_pos = self.position;
    while (isDigit(self.ch)) {
        self.readChar();
    }

    return self.input[start_pos..self.position];
}

pub fn nextToken(self: *@This()) Token {
    self.skipWhitespace();

    const tok = sw: switch (self.ch) {
        '=' => Token{ .token_type = TokenType.ASSIGN, .literal = self.getCurrentCharString() },
        ';' => Token{ .token_type = TokenType.SEMICOLON, .literal = self.getCurrentCharString() },
        '(' => Token{ .token_type = TokenType.LPAREN, .literal = self.getCurrentCharString() },
        ')' => Token{ .token_type = TokenType.RPAREN, .literal = self.getCurrentCharString() },
        ',' => Token{ .token_type = TokenType.COMMA, .literal = self.getCurrentCharString() },
        '+' => Token{ .token_type = TokenType.PLUS, .literal = self.getCurrentCharString() },
        '{' => Token{ .token_type = TokenType.LBRACE, .literal = self.getCurrentCharString() },
        '}' => Token{ .token_type = TokenType.RBRACE, .literal = self.getCurrentCharString() },
        0 => Token{ .token_type = TokenType.EOF, .literal = "" },
        else => if (isLetter(self.ch)) {
            const tok_literal = self.readIdentifier();
            return Token{ .token_type = TokenType.lookupIdent(tok_literal), .literal = tok_literal };
        } else if (isDigit(self.ch)) {
            return Token{ .token_type = TokenType.INT, .literal = self.readNumber() };
        } else {
            break :sw Token{ .token_type = TokenType.ILLEGAL, .literal = self.getCurrentCharString() };
        },
    };

    self.readChar();

    return tok;
}

test nextToken {
    const input =
        \\ let five = 5;
        \\ let ten = 10;
        \\
        \\ let add = fn(x, y) {
        \\   x + y;
        \\ };
        \\
        \\ let result = add(five, ten);
    ;

    const tests = [_]struct {
        expectedType: TokenType,
        expectedLiteral: []const u8,
    }{
        .{ .expectedType = TokenType.LET, .expectedLiteral = "let" },
        .{ .expectedType = TokenType.IDENT, .expectedLiteral = "five" },
        .{ .expectedType = TokenType.ASSIGN, .expectedLiteral = "=" },
        .{ .expectedType = TokenType.INT, .expectedLiteral = "5" },
        .{ .expectedType = TokenType.SEMICOLON, .expectedLiteral = ";" },
        .{ .expectedType = TokenType.LET, .expectedLiteral = "let" },
        .{ .expectedType = TokenType.IDENT, .expectedLiteral = "ten" },
        .{ .expectedType = TokenType.ASSIGN, .expectedLiteral = "=" },
        .{ .expectedType = TokenType.INT, .expectedLiteral = "10" },
        .{ .expectedType = TokenType.SEMICOLON, .expectedLiteral = ";" },
        .{ .expectedType = TokenType.LET, .expectedLiteral = "let" },
        .{ .expectedType = TokenType.IDENT, .expectedLiteral = "add" },
        .{ .expectedType = TokenType.ASSIGN, .expectedLiteral = "=" },
        .{ .expectedType = TokenType.FUNCTION, .expectedLiteral = "fn" },
        .{ .expectedType = TokenType.LPAREN, .expectedLiteral = "(" },
        .{ .expectedType = TokenType.IDENT, .expectedLiteral = "x" },
        .{ .expectedType = TokenType.COMMA, .expectedLiteral = "," },
        .{ .expectedType = TokenType.IDENT, .expectedLiteral = "y" },
        .{ .expectedType = TokenType.RPAREN, .expectedLiteral = ")" },
        .{ .expectedType = TokenType.LBRACE, .expectedLiteral = "{" },
        .{ .expectedType = TokenType.IDENT, .expectedLiteral = "x" },
        .{ .expectedType = TokenType.PLUS, .expectedLiteral = "+" },
        .{ .expectedType = TokenType.IDENT, .expectedLiteral = "y" },
        .{ .expectedType = TokenType.SEMICOLON, .expectedLiteral = ";" },
        .{ .expectedType = TokenType.RBRACE, .expectedLiteral = "}" },
        .{ .expectedType = TokenType.SEMICOLON, .expectedLiteral = ";" },
        .{ .expectedType = TokenType.LET, .expectedLiteral = "let" },
        .{ .expectedType = TokenType.IDENT, .expectedLiteral = "result" },
        .{ .expectedType = TokenType.ASSIGN, .expectedLiteral = "=" },
        .{ .expectedType = TokenType.IDENT, .expectedLiteral = "add" },
        .{ .expectedType = TokenType.LPAREN, .expectedLiteral = "(" },
        .{ .expectedType = TokenType.IDENT, .expectedLiteral = "five" },
        .{ .expectedType = TokenType.COMMA, .expectedLiteral = "," },
        .{ .expectedType = TokenType.IDENT, .expectedLiteral = "ten" },
        .{ .expectedType = TokenType.RPAREN, .expectedLiteral = ")" },
        .{ .expectedType = TokenType.SEMICOLON, .expectedLiteral = ";" },
        .{ .expectedType = TokenType.EOF, .expectedLiteral = "" },
    };

    var l = init(input);

    for (tests) |t| {
        const tok = l.nextToken();

        try std.testing.expectEqual(t.expectedType, tok.token_type);
        try std.testing.expectEqualStrings(t.expectedLiteral, tok.literal);
    }
}
