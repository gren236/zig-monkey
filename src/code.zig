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
        &(try make(.constant, &.{2})),
        &(try make(.constant, &.{65535})),
    };

    const expected =
        \\0000 OpAdd
        \\0001 OpConstant 2
        \\0004 OpConstant 65535
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

    var instruction: [op.instructionLen()]u8 = undefined;
    instruction[0] = @intFromEnum(op);

    var offset: usize = 1;
    for (0.., operands) |i, o| {
        const width = def.operand_widths[i];

        switch (width) {
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
        .{ .op = Opcode.constant, .operands = &[_]usize{65534}, .expected = &[_]u8{ @intFromEnum(Opcode.constant), 255, 254 } },
        .{ .op = Opcode.add, .operands = &[0]usize{}, .expected = &[_]u8{@intFromEnum(Opcode.add)} },
    };

    inline for (tests) |tt| {
        const instruction = try make(tt.op, tt.operands);

        try std.testing.expectEqual(tt.expected.len, instruction.len);

        for (&instruction, tt.expected) |got, exp| {
            try std.testing.expectEqual(exp, got);
        }
    }
}

pub fn readOperandInt(comptime width: usize, buffer: *const [width]u8) u16 {
    return std.mem.readInt(u16, buffer, .big);
}

fn readOperands(comptime def: Definition, ins: Instructions) !struct { [def.operand_widths.len]usize, usize } {
    var operands: [def.operand_widths.len]usize = undefined;

    var offset: usize = 0;
    for (0.., def.operand_widths) |i, width| {
        switch (width) {
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
    };

    inline for (tests) |tt| {
        var instruction = try make(tt.op, tt.operands);
        const def = comptime tt.op.lookup();

        const operands_read, const n = try readOperands(def, instruction[1..]);
        try std.testing.expectEqual(tt.bytes_read, n);
        try std.testing.expectEqualSlices(usize, tt.operands, &operands_read);
    }
}
