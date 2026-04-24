const std = @import("std");

const ast = @import("ast.zig");
const code = @import("code.zig");
const Compiler = @import("compiler.zig");
const Lexer = @import("lexer.zig");
const object = @import("object.zig");
const Parser = @import("parser.zig");

const Self = @This();

const Error = error{ UnknownOpcode, StackOverflow };

const stack_size = 2048;

constants: []const object.Object,
instructions: code.Instructions,

stack: [stack_size]object.Object,
sp: usize, // Always points to the next value. Top of stack is stack[sp-1]

pub fn init(bytecode: Compiler.Bytecode) Self {
    return .{
        .instructions = bytecode.instructions,
        .constants = bytecode.constants,
        .stack = undefined,
        .sp = 0,
    };
}

pub fn run(self: *Self) !void {
    var ip: usize = 0;
    while (ip < self.instructions.len) {
        const op = std.enums.fromInt(code.Opcode, self.instructions[ip]) orelse
            return Error.UnknownOpcode;

        switch (op) {
            .constant => {
                const width = 2;
                const const_index = code.readOperandInt(width, self.instructions[ip + 1 ..][0..width]);
                ip += width;

                try self.push(self.constants[const_index]);
            },
        }

        ip += 1;
    }
}

fn push(self: *Self, o: object.Object) !void {
    if (self.sp >= stack_size) return Error.StackOverflow;

    self.stack[self.sp] = o;
    self.sp += 1;
}

fn stackTop(self: *Self) ?object.Object {
    if (self.sp == 0) return null;

    return self.stack[self.sp - 1];
}

// Testing

const VmTestCase = struct {
    input: []const u8,
    expected: union(enum) {
        int: usize,
    },
};

test "integer arithmetic" {
    const tests: []const VmTestCase = &.{
        .{ .input = "1", .expected = .{ .int = 1 } },
        .{ .input = "2", .expected = .{ .int = 2 } },
        .{ .input = "1 + 2", .expected = .{ .int = 2 } }, // FIXME
    };

    try runVmTests(tests);
}

fn parse(alloc: std.mem.Allocator, input: []const u8) !ast.Node(.Common) {
    var l = Lexer.init(input);
    var p = Parser.init(&l);

    return ast.Node(.Common){ .val = .{ .program = try p.parseProgram(alloc) } };
}

fn testIntegerObject(expected: i64, actual: object.Object) !void {
    try std.testing.expectEqual(object.ObjectType.integer, @as(object.ObjectType, actual));
    try std.testing.expectEqual(expected, actual.integer.value);
}

fn testExpectedObject(expected: @FieldType(VmTestCase, "expected"), actual: object.Object) !void {
    switch (expected) {
        .int => |exp| try testIntegerObject(@intCast(exp), actual),
    }
}

fn runVmTests(tests: []const VmTestCase) !void {
    const talloc = std.testing.allocator;

    for (tests) |tt| {
        var arena = std.heap.ArenaAllocator.init(talloc);
        defer arena.deinit();
        const alloc = arena.allocator();

        const program = try parse(alloc, tt.input);
        var compiler = Compiler.init();

        try compiler.compile(alloc, program);

        var vm = init(compiler.bytecode());
        try vm.run();

        const stack_elem = vm.stackTop();
        try std.testing.expect(stack_elem != null);

        try testExpectedObject(tt.expected, stack_elem.?);
    }
}
