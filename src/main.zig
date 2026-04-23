const std = @import("std");
const repl = @import("repl.zig");

// Ensure all modules are included in `zig build test`.
comptime {
    _ = @import("lexer.zig");
    _ = @import("ast.zig");
    _ = @import("parser.zig");
    _ = @import("evaluator.zig");
    _ = @import("object.zig");
    _ = @import("code.zig");
    _ = @import("compiler.zig");
}

pub fn main(init: std.process.Init) !void {
    const io = init.io;

    var out_buf: [1024]u8 = undefined;
    var in_buf: [1024]u8 = undefined;

    var out_writer = std.Io.File.stdout().writer(io, &out_buf);
    var writer = &out_writer.interface;

    var in_reader = std.Io.File.stdin().reader(io, &in_buf);
    const reader = &in_reader.interface;

    try writer.print("Hello! This is the Monkey programming language!\n", .{});
    try writer.print("Feel free to type in commands\n", .{});
    try writer.flush();

    try repl.start(reader, writer);
}
