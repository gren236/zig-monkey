const std = @import("std");

const Error = error{ OpcodeUndefined, UnexpectedOperandWidth };

const Definition = struct {
    name: []const u8,
    operand_widths: []const usize,
};

pub const Opcode = enum(u8) {
    constant,
    add,
    sub,
    mul,
    div,
    pop,
    true,
    false,
    equal,
    not_equal,
    greater_than,
    minus,
    bang,
    jump,
    jump_not_truthy,
    nil,
    set_global,
    get_global,
    array,
    hash,
    index,
    call,
    return_value,
    @"return",
    set_local,
    get_local,
    get_builtin,
    closure,
    current_closure,
    get_free,

    inline fn lookup(op: @This()) Definition {
        return switch (op) {
            // 2 bytes should be enough to represent a const index
            .constant => .{ .name = "OpConstant", .operand_widths = &.{2} },
            .add => .{ .name = "OpAdd", .operand_widths = &.{} },
            .sub => .{ .name = "OpSub", .operand_widths = &.{} },
            .mul => .{ .name = "OpMul", .operand_widths = &.{} },
            .div => .{ .name = "OpDiv", .operand_widths = &.{} },
            .pop => .{ .name = "OpPop", .operand_widths = &.{} },
            .true => .{ .name = "OpTrue", .operand_widths = &.{} },
            .false => .{ .name = "OpFalse", .operand_widths = &.{} },
            .equal => .{ .name = "OpEqual", .operand_widths = &.{} },
            .not_equal => .{ .name = "OpNotEqual", .operand_widths = &.{} },
            .greater_than => .{ .name = "OpGreaterThan", .operand_widths = &.{} },
            .minus => .{ .name = "OpMinus", .operand_widths = &.{} },
            .bang => .{ .name = "OpBang", .operand_widths = &.{} },
            .jump => .{ .name = "OpJump", .operand_widths = &.{2} },
            .jump_not_truthy => .{ .name = "OpJumpNotTruthy", .operand_widths = &.{2} },
            .nil => .{ .name = "OpNil", .operand_widths = &.{} },
            .set_global => .{ .name = "OpSetGlobal", .operand_widths = &.{2} },
            .get_global => .{ .name = "OpGetGlobal", .operand_widths = &.{2} },
            .array => .{ .name = "OpArray", .operand_widths = &.{2} },
            .hash => .{ .name = "OpHash", .operand_widths = &.{2} },
            .index => .{ .name = "OpIndex", .operand_widths = &.{} },
            .call => .{ .name = "OpCall", .operand_widths = &.{1} },
            .return_value => .{ .name = "OpReturnValue", .operand_widths = &.{} },
            .@"return" => .{ .name = "OpReturn", .operand_widths = &.{} },
            .set_local => .{ .name = "OpSetLocal", .operand_widths = &.{1} },
            .get_local => .{ .name = "OpGetLocal", .operand_widths = &.{1} },
            .get_builtin => .{ .name = "OpGetBuiltin", .operand_widths = &.{1} },
            .closure => .{ .name = "OpClosure", .operand_widths = &.{ 2, 1 } },
            .current_closure => .{ .name = "OpCurrentClosure", .operand_widths = &.{} },
            .get_free => .{ .name = "OpGetFree", .operand_widths = &.{1} },
        };
    }

    inline fn instructionLen(op: @This()) comptime_int {
        var instruction_len: comptime_int = 1;
        for (op.lookup().operand_widths) |w| {
            instruction_len += w;
        }

        return instruction_len;
    }
};

pub const Instructions = []const u8;

pub fn writeInstructions(ins: Instructions, writer: *std.Io.Writer) !void {
    var i: usize = 0;
    while (i < ins.len) {
        const op = std.enums.fromInt(Opcode, ins[i]) orelse return Error.OpcodeUndefined;

        switch (op) {
            inline else => |comp_op| {
                const def = comptime comp_op.lookup();

                const operands, const read = try readOperands(def, ins[i + 1 ..]);
                if (operands.len != def.operand_widths.len) return Error.UnexpectedOperandWidth;

                try writer.print("{d:0>4} ", .{i});

                switch (def.operand_widths.len) {
                    0 => try writer.print("{s}\n", .{def.name}),
                    1 => try writer.print("{s} {d}\n", .{ def.name, operands[0] }),
                    2 => try writer.print("{s} {d} {d}\n", .{ def.name, operands[0], operands[1] }),
                    else => return Error.UnexpectedOperandWidth,
                }

                i += 1 + read;
            },
        }
    }
}

test writeInstructions {
    const instructions: []const Instructions = &.{
        &(try make(.add, &.{})),
        &(try make(.get_local, &.{1})),
        &(try make(.constant, &.{2})),
        &(try make(.constant, &.{65535})),
        &(try make(.closure, &.{ 65535, 255 })),
    };

    const expected =
        \\0000 OpAdd
        \\0001 OpGetLocal 1
        \\0003 OpConstant 2
        \\0006 OpConstant 65535
        \\0009 OpClosure 65535 255
    ;

    const alloc = std.testing.allocator;
    const concatted: Instructions = try std.mem.concat(alloc, u8, instructions);
    defer alloc.free(concatted);

    var buffer: [1024]u8 = undefined;
    var writer = std.Io.Writer.fixed(&buffer);
    try writeInstructions(concatted, &writer);
    try writer.flush();

    try std.testing.expectEqualStrings(expected, buffer[0..expected.len]);
}

pub fn make(comptime op: Opcode, operands: []const usize) ![op.instructionLen()]u8 {
    const def = op.lookup();

    var instruction: [op.instructionLen()]u8 = @splat(0);
    instruction[0] = @intFromEnum(op);

    var offset: usize = 1;
    for (0.., operands) |i, o| {
        const width = def.operand_widths[i];

        switch (width) {
            1 => instruction[offset] = @intCast(o),
            2 => std.mem.writeInt(u16, instruction[offset..][0..2], @intCast(o), .big),
            else => return Error.UnexpectedOperandWidth,
        }

        offset += width;
    }

    return instruction;
}

test make {
    const tests: []const struct {
        op: Opcode,
        operands: []const usize,
        expected: []const u8,
    } = comptime &.{
        .{
            .op = .constant,
            .operands = &[_]usize{65534},
            .expected = &[_]u8{ @intFromEnum(Opcode.constant), 255, 254 },
        },
        .{
            .op = .add,
            .operands = &[0]usize{},
            .expected = &[_]u8{@intFromEnum(Opcode.add)},
        },
        .{
            .op = .get_local,
            .operands = &[_]usize{255},
            .expected = &[_]u8{ @intFromEnum(Opcode.get_local), 255 },
        },
        .{
            .op = .closure,
            .operands = &[_]usize{ 65534, 255 },
            .expected = &[_]u8{ @intFromEnum(Opcode.closure), 255, 254, 255 },
        },
    };

    inline for (tests) |tt| {
        const instruction = try make(tt.op, tt.operands);

        try std.testing.expectEqual(tt.expected.len, instruction.len);

        for (&instruction, tt.expected) |got, exp| {
            try std.testing.expectEqual(exp, got);
        }
    }
}

pub fn OperandInt(comptime width: usize) type {
    return switch (width) {
        1 => u8,
        2 => u16,
        else => @compileError("unsupported operand width: " ++ std.fmt.comptimePrint("{d}", .{width})),
    };
}

pub fn readOperandInt(comptime width: usize, buffer: *const [width]u8) OperandInt(width) {
    return std.mem.readInt(OperandInt(width), buffer, .big);
}

fn readOperands(comptime def: Definition, ins: Instructions) !struct { [def.operand_widths.len]usize, usize } {
    var operands: [def.operand_widths.len]usize = undefined;

    var offset: usize = 0;
    for (0.., def.operand_widths) |i, width| {
        switch (width) {
            1 => operands[i] = readOperandInt(1, ins[offset..][0..1]),
            2 => operands[i] = readOperandInt(2, ins[offset..][0..2]),
            else => return Error.UnexpectedOperandWidth,
        }

        offset += width;
    }

    return .{ operands, offset };
}

test readOperands {
    const tests: []const struct {
        op: Opcode,
        operands: []const usize,
        bytes_read: usize,
    } = comptime &.{
        .{ .op = .constant, .operands = &.{65535}, .bytes_read = 2 },
        .{ .op = .get_local, .operands = &.{255}, .bytes_read = 1 },
        .{ .op = .closure, .operands = &.{ 65535, 255 }, .bytes_read = 3 },
    };

    inline for (tests) |tt| {
        var instruction = try make(tt.op, tt.operands);
        const def = comptime tt.op.lookup();

        const operands_read, const n = try readOperands(def, instruction[1..]);
        try std.testing.expectEqual(tt.bytes_read, n);
        try std.testing.expectEqualSlices(usize, tt.operands, &operands_read);
    }
}
