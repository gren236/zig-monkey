const std = @import("std");

const Lexer = @import("lexer.zig");
const Parser = @import("parser.zig");

const prompt = ">> ";
const monkey_face =
    \\            __,__
    \\   .--.  .-"     "-.  .--.
    \\  / .. \/  .-. .-.  \/ .. \
    \\ | |  '|  /   Y   \  |'  | |
    \\ | \   \  \ 0 | 0 /  /   / |
    \\  \ '- ,\.-"""""""-./, -' /
    \\   ''-' /_   ^ ^   _\ '-''
    \\       |  \._   _./  |
    \\       \   \ '~' /   /
    \\        '._ '-=-' _.'
    \\           '-----'
    \\
;

pub fn start(in: *std.Io.Reader, out: *std.Io.Writer) !void {
    var gpa: std.heap.DebugAllocator(.{}) = .init;
    const alloc = gpa.allocator();

    while (true) {
        try out.print(prompt, .{});
        try out.flush();

        const line = try in.takeDelimiter('\n') orelse continue;

        var lexer = Lexer.init(line);
        var parser = Parser.init(&lexer);
        defer parser.deinit(alloc);

        var program = try parser.parseProgram(alloc);
        defer program.deinit(alloc);

        if (parser.errors.items.len != 0) {
            try printParserErrors(out, parser.errors);
            continue;
        }

        try program.writeString(out);
        _ = try out.write("\n");

        try out.flush();
    }
}

fn printParserErrors(out: *std.Io.Writer, errors: std.ArrayList([]const u8)) !void {
    _ = try out.write(monkey_face);
    _ = try out.write("Huh! We ran into some trouble here!\n");
    _ = try out.write(" parser errors:\n");
    for (errors.items) |err| {
        try out.print("\t{s}\n", .{err});
    }
}
