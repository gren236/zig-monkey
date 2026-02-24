const std = @import("std");
const Lexer = @import("lexer.zig");

const prompt = ">> ";

pub fn start(in: *std.Io.Reader, out: *std.Io.Writer) !void {
    while (true) {
        try out.print(prompt, .{});
        try out.flush();

        const line = try in.takeDelimiter('\n') orelse continue;

        var lexer = Lexer.init(line);

        var tok = lexer.nextToken();
        while (tok.token_type != Lexer.TokenType.EOF) {
            try out.print("{}\n", .{tok});

            tok = lexer.nextToken();
        }

        try out.flush();
    }
}
