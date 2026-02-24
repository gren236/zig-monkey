const std = @import("std");
const repl = @import("repl.zig");

pub fn main() !void {
    var out_buf: [1024]u8 = undefined;
    var in_buf: [1024]u8 = undefined;

    var out_writer = std.fs.File.stdout().writer(&out_buf);
    var writer = &out_writer.interface;

    var in_reader = std.fs.File.stdin().reader(&in_buf);
    const reader = &in_reader.interface;

    try writer.print("Hello! This is the Monkey programming language!\n", .{});
    try writer.print("Feel free to type in commands\n", .{});
    try writer.flush();

    try repl.start(reader, writer);
}
