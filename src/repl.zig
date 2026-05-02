const std = @import("std");

const ast = @import("ast.zig");
const Compiler = @import("compiler.zig");
const Lexer = @import("lexer.zig");
const object = @import("object.zig");
const Parser = @import("parser.zig");
const Vm = @import("vm.zig");

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

pub fn start(alloc: std.mem.Allocator, in: *std.Io.Reader, out: *std.Io.Writer) !void {
    var comp: Compiler = .init();
    defer comp.deinit(alloc);

    var machine = Vm.init();

    while (true) {
        try out.print(prompt, .{});
        try out.flush();

        const line = try in.takeDelimiter('\n') orelse continue;

        if (std.mem.eql(u8, line, "exit")) return;

        var arena = std.heap.ArenaAllocator.init(alloc);
        defer arena.deinit();
        const iter_alloc = arena.allocator();

        var lexer = Lexer.init(line);
        var parser = Parser.init(&lexer);
        defer parser.deinit(iter_alloc);

        var program = try parser.parseProgram(iter_alloc);
        defer program.deinit(iter_alloc);

        if (parser.errors.items.len != 0) {
            try printParserErrors(out, parser.errors);
            continue;
        }

        comp.compile(alloc, .{ .val = .{ .program = program } }) catch |err| {
            std.debug.print("Compilation error: {t}\n", .{err});
            continue;
        };
        defer comp.resetInstructions();

        const bcode = comp.bytecode();
        machine.run(bcode) catch |err| {
            std.debug.print("VM run error: {t}\n", .{err});
            continue;
        };

        const stack_top = machine.lastPoppedStackElem();
        try stack_top.inspect(out);
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

test start {
    const input = "let a = 5;\nlet b = a + 5;\nexit\n";
    const expected = ">> 5\n>> 10\n";

    const alloc = std.testing.allocator;

    var in = std.Io.Reader.fixed(input);
    var actual_buf: [1024]u8 = undefined;
    var out = std.Io.Writer.fixed(&actual_buf);

    try start(alloc, &in, &out);
    try std.testing.expectEqualStrings(expected, actual_buf[0..expected.len]);
}
