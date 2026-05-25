const std = @import("std");

const ast = @import("ast.zig");
const code = @import("code.zig");
const Compiler = @import("compiler.zig");
const Evaluator = @import("evaluator.zig");
const Lexer = @import("lexer.zig");
const object = @import("object.zig");
const Parser = @import("parser.zig");
const Vm = @import("vm.zig");

const input =
    \\ let fibonacci = fn(x) {
    \\     if (x == 0) {
    \\         return 0;
    \\     } else {
    \\         if (x == 1) {
    \\             return 1;
    \\         } else {
    \\             fibonacci(x - 1) + fibonacci(x - 2);
    \\         }
    \\     }
    \\ };
    \\ fibonacci(24);
;

pub fn main(init: std.process.Init) !void {
    const io = init.io;

    var stdout = std.Io.File.stdout();
    var buf: [1024]u8 = undefined;
    var stdout_writer = stdout.writer(io, &buf);
    var writer = &stdout_writer.interface;

    var arg_iter = init.minimal.args.iterate();
    _ = arg_iter.next(); // skip name
    const engine = arg_iter.next() orelse return error.NoEngineProvided;

    var gpa: std.heap.DebugAllocator(.{}) = .init;
    var arena_alloc: std.heap.ArenaAllocator = .init(gpa.allocator());
    defer arena_alloc.deinit();
    const alloc = arena_alloc.allocator();

    var start = std.Io.Clock.awake.now(io);

    var l = Lexer.init(input);
    var p = Parser.init(&l);
    const program = try p.parseProgram(alloc);

    if (std.mem.eql(u8, engine, "vm")) {
        _ = try writer.write("vm chosen\n");

        var compiler: Compiler = try .init(alloc);
        var machine = try Vm.create(alloc);

        compiler.compile(alloc, .{ .val = .{ .program = program } }) catch |err| {
            std.debug.print("Compilation error: {t}\n", .{err});
            return;
        };

        const bcode = compiler.bytecode();
        machine.run(bcode) catch |err| {
            std.debug.print("VM run error: {t}\n", .{err});
            return;
        };
        const stack_top = machine.lastPoppedStackElem();
        try stack_top.inspect(writer);
    } else {
        _ = try writer.write("eval chosen\n");

        var env = try object.Environment.init(alloc);
        const evaluated = try Evaluator.eval(
            alloc,
            &ast.Node(.Common){ .val = .{ .program = program } },
            &env,
        );
        try evaluated.inspect(writer);
    }
    _ = try writer.write("\n");

    const end = std.Io.Clock.awake.now(io);
    const elapsed: f64 = @floatFromInt(start.durationTo(end).nanoseconds);
    try writer.print("Time elapsed is: {d:.3}ms\n", .{
        elapsed / std.time.ns_per_ms,
    });

    try writer.flush();
}
