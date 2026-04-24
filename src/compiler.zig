const std = @import("std");

const ast = @import("ast.zig");
const code = @import("code.zig");
const Lexer = @import("lexer.zig");
const object = @import("object.zig");
const Parser = @import("parser.zig");

const Self = @This();

pub const Error = error{ UnknownNode, UnsupportedOperator };

instructions: std.ArrayList(u8),
constants: std.ArrayList(object.Object),

pub fn init() Self {
    return .{
        .instructions = .empty,
        .constants = .empty,
    };
}

pub fn deinit(self: *Self, alloc: std.mem.Allocator) void {
    self.instructions.deinit(alloc);

    for (self.constants.items) |obj| {
        obj.deinit(alloc);
    }
    self.constants.deinit(alloc);
}

fn addConstant(self: *Self, alloc: std.mem.Allocator, obj: object.Object) !usize {
    try self.constants.append(alloc, try obj.clone(alloc));
    return self.constants.items.len - 1;
}

fn addInstruction(self: *Self, alloc: std.mem.Allocator, ins: []const u8) !usize {
    const pos_new_instruction = self.instructions.items.len;
    try self.instructions.appendSlice(alloc, ins);

    return pos_new_instruction;
}

fn emit(self: *Self, alloc: std.mem.Allocator, op: code.Opcode, operands: []const usize) !usize {
    switch (op) {
        inline else => |comp_op| {
            var ins = try code.make(comp_op, operands);
            const pos = try self.addInstruction(alloc, &ins);

            return pos;
        },
    }
}

pub fn compile(self: *Self, alloc: std.mem.Allocator, node: ast.Node(.Common)) !void {
    switch (node.val) {
        .program => |prog| {
            for (prog.statements) |stmt| {
                try self.compileStatement(alloc, &stmt);
            }
        },
    }
}

fn compileStatement(self: *Self, alloc: std.mem.Allocator, node: *const ast.Node(.Statement)) !void {
    switch (node.val) {
        .expression_stmt => |stmt| {
            try self.compileExpression(alloc, stmt.expression);
            _ = try self.emit(alloc, .pop, &.{});
        },
        else => return Error.UnknownNode,
    }
}

const Operator = enum {
    @"+",
    @"-",
    @"*",
    @"/",
    @">",
    @"==",
    @"!=",
};

fn compileExpression(self: *Self, alloc: std.mem.Allocator, node: *const ast.Node(.Expression)) !void {
    switch (node.val) {
        .infix => |inf| {
            // special case for < operator
            if (std.mem.eql(u8, "<", inf.operator)) {
                try self.compileExpression(alloc, inf.right);
                try self.compileExpression(alloc, inf.left);
                _ = try self.emit(alloc, .greater_than, &.{});

                return;
            }

            try self.compileExpression(alloc, inf.left);
            try self.compileExpression(alloc, inf.right);

            const operator = std.meta.stringToEnum(Operator, inf.operator) orelse
                return Error.UnsupportedOperator;

            switch (operator) {
                .@"+" => _ = try self.emit(alloc, .add, &.{}),
                .@"-" => _ = try self.emit(alloc, .sub, &.{}),
                .@"*" => _ = try self.emit(alloc, .mul, &.{}),
                .@"/" => _ = try self.emit(alloc, .div, &.{}),
                .@">" => _ = try self.emit(alloc, .greater_than, &.{}),
                .@"==" => _ = try self.emit(alloc, .equal, &.{}),
                .@"!=" => _ = try self.emit(alloc, .not_equal, &.{}),
            }
        },
        .int_literal => |int_lit| {
            const integer: object.Object = .{ .integer = .{ .value = int_lit.value } };
            _ = try self.emit(alloc, .constant, &.{try self.addConstant(alloc, integer)});
        },
        .boolean => |bool_lit| _ = try self.emit(alloc, if (bool_lit.value) .true else .false, &.{}),
        else => return Error.UnknownNode,
    }
}

pub const Bytecode = struct {
    instructions: code.Instructions,
    constants: []const object.Object,
};

pub fn bytecode(self: *Self) Bytecode {
    return .{
        .instructions = self.instructions.items,
        .constants = self.constants.items,
    };
}

// Testing

const CompilerTestCase = struct {
    input: []const u8,
    expected_constants: []const union(enum) {
        int: usize,
    },
    expected_instructions: []code.Instructions,
};

test "integer arithmetic" {
    const tests: []const CompilerTestCase = &.{
        .{
            .input = "1 + 2",
            .expected_constants = &.{ .{ .int = 1 }, .{ .int = 2 } },
            .expected_instructions = @constCast(&[_]code.Instructions{
                &(try code.make(.constant, &.{0})),
                &(try code.make(.constant, &.{1})),
                &(try code.make(.add, &.{})),
                &(try code.make(.pop, &.{})),
            }),
        },
        .{
            .input = "1; 2",
            .expected_constants = &.{ .{ .int = 1 }, .{ .int = 2 } },
            .expected_instructions = @constCast(&[_]code.Instructions{
                &(try code.make(.constant, &.{0})),
                &(try code.make(.pop, &.{})),
                &(try code.make(.constant, &.{1})),
                &(try code.make(.pop, &.{})),
            }),
        },
        .{
            .input = "1 - 2",
            .expected_constants = &.{ .{ .int = 1 }, .{ .int = 2 } },
            .expected_instructions = @constCast(&[_]code.Instructions{
                &(try code.make(.constant, &.{0})),
                &(try code.make(.constant, &.{1})),
                &(try code.make(.sub, &.{})),
                &(try code.make(.pop, &.{})),
            }),
        },
        .{
            .input = "1 * 2",
            .expected_constants = &.{ .{ .int = 1 }, .{ .int = 2 } },
            .expected_instructions = @constCast(&[_]code.Instructions{
                &(try code.make(.constant, &.{0})),
                &(try code.make(.constant, &.{1})),
                &(try code.make(.mul, &.{})),
                &(try code.make(.pop, &.{})),
            }),
        },
        .{
            .input = "2 / 1",
            .expected_constants = &.{ .{ .int = 2 }, .{ .int = 1 } },
            .expected_instructions = @constCast(&[_]code.Instructions{
                &(try code.make(.constant, &.{0})),
                &(try code.make(.constant, &.{1})),
                &(try code.make(.div, &.{})),
                &(try code.make(.pop, &.{})),
            }),
        },
    };

    try runCompilerTests(tests);
}

test "boolean expressions" {
    const tests: []const CompilerTestCase = &.{
        .{
            .input = "true",
            .expected_constants = &.{},
            .expected_instructions = @constCast(&[_]code.Instructions{
                &(try code.make(.true, &.{})),
                &(try code.make(.pop, &.{})),
            }),
        },
        .{
            .input = "false",
            .expected_constants = &.{},
            .expected_instructions = @constCast(&[_]code.Instructions{
                &(try code.make(.false, &.{})),
                &(try code.make(.pop, &.{})),
            }),
        },
        .{
            .input = "1 > 2",
            .expected_constants = &.{ .{ .int = 1 }, .{ .int = 2 } },
            .expected_instructions = @constCast(&[_]code.Instructions{
                &(try code.make(.constant, &.{0})),
                &(try code.make(.constant, &.{1})),
                &(try code.make(.greater_than, &.{})),
                &(try code.make(.pop, &.{})),
            }),
        },
        .{
            .input = "1 < 2",
            .expected_constants = &.{ .{ .int = 2 }, .{ .int = 1 } },
            .expected_instructions = @constCast(&[_]code.Instructions{
                &(try code.make(.constant, &.{0})),
                &(try code.make(.constant, &.{1})),
                &(try code.make(.greater_than, &.{})),
                &(try code.make(.pop, &.{})),
            }),
        },
        .{
            .input = "1 == 2",
            .expected_constants = &.{ .{ .int = 1 }, .{ .int = 2 } },
            .expected_instructions = @constCast(&[_]code.Instructions{
                &(try code.make(.constant, &.{0})),
                &(try code.make(.constant, &.{1})),
                &(try code.make(.equal, &.{})),
                &(try code.make(.pop, &.{})),
            }),
        },
        .{
            .input = "1 != 2",
            .expected_constants = &.{ .{ .int = 1 }, .{ .int = 2 } },
            .expected_instructions = @constCast(&[_]code.Instructions{
                &(try code.make(.constant, &.{0})),
                &(try code.make(.constant, &.{1})),
                &(try code.make(.not_equal, &.{})),
                &(try code.make(.pop, &.{})),
            }),
        },
        .{
            .input = "true == false",
            .expected_constants = &.{},
            .expected_instructions = @constCast(&[_]code.Instructions{
                &(try code.make(.true, &.{})),
                &(try code.make(.false, &.{})),
                &(try code.make(.equal, &.{})),
                &(try code.make(.pop, &.{})),
            }),
        },
        .{
            .input = "true != false",
            .expected_constants = &.{},
            .expected_instructions = @constCast(&[_]code.Instructions{
                &(try code.make(.true, &.{})),
                &(try code.make(.false, &.{})),
                &(try code.make(.not_equal, &.{})),
                &(try code.make(.pop, &.{})),
            }),
        },
    };

    try runCompilerTests(tests);
}

fn parse(alloc: std.mem.Allocator, input: []const u8) !ast.Node(.Common) {
    var l = Lexer.init(input);
    var p = Parser.init(&l);

    return ast.Node(.Common){ .val = .{ .program = try p.parseProgram(alloc) } };
}

fn testErrorInstructionsOutput(expected: code.Instructions, actual: code.Instructions) !void {
    const stderr = std.debug.lockStderr(&.{});
    defer std.debug.unlockStderr();
    const writer = &stderr.file_writer.interface;

    _ = try writer.write("================= DISASSEMBLED =================\n");
    _ = try writer.write("expected:\n");
    try code.writeInstructions(expected, writer);
    _ = try writer.write("actual:\n");
    try code.writeInstructions(actual, writer);

    _ = try writer.write("================================================\n");
    _ = try writer.write("\n");

    try writer.flush();
}

fn testInstructions(expected: code.Instructions, actual: code.Instructions) !void {
    std.testing.expectEqualSlices(u8, expected, actual) catch |err| {
        try testErrorInstructionsOutput(expected, actual);
        return err;
    };
}

fn testIntegerObject(expected: i64, actual: object.Object) !void {
    try std.testing.expectEqual(object.ObjectType.integer, @as(object.ObjectType, actual));
    try std.testing.expectEqual(expected, actual.integer.value);
}

fn testConstants(expected: @FieldType(CompilerTestCase, "expected_constants"), actual: []const object.Object) !void {
    try std.testing.expectEqual(expected.len, actual.len);

    for (expected, actual) |exp_const, act_const| {
        switch (exp_const) {
            .int => |exp| try testIntegerObject(@intCast(exp), act_const),
        }
    }
}

fn runCompilerTests(tests: []const CompilerTestCase) !void {
    const talloc = std.testing.allocator;

    for (tests) |tt| {
        var arena = std.heap.ArenaAllocator.init(talloc);
        defer arena.deinit();
        const alloc = arena.allocator();

        const program = try parse(alloc, tt.input);
        var compiler = init();

        try compiler.compile(alloc, program);

        const bcode = compiler.bytecode();
        const exp_instructions = try std.mem.concat(alloc, u8, tt.expected_instructions);
        try testInstructions(exp_instructions, bcode.instructions);
        try testConstants(tt.expected_constants, bcode.constants);
    }
}
