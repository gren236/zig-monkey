const std = @import("std");

const ast = @import("ast.zig");
const code = @import("code.zig");
const Lexer = @import("lexer.zig");
const object = @import("object.zig");
const Parser = @import("parser.zig");

const Self = @This();

pub const Error = error{ UnknownNode, UnsupportedOperator, UndefinedVariable };

const SymbolTable = struct {
    const Scope = enum {
        global,
    };

    const Symbol = struct {
        name: []const u8,
        scope: Scope,
        index: usize,
    };

    store: std.StringHashMapUnmanaged(Symbol),
    num_definitions: usize,

    pub fn init() @This() {
        return .{
            .store = .empty,
            .num_definitions = 0,
        };
    }

    pub fn deinit(self: *@This(), alloc: std.mem.Allocator) void {
        var iter = self.store.iterator();
        while (iter.next()) |entry| {
            alloc.free(entry.key_ptr.*);
        }

        self.store.deinit(alloc);
    }

    pub fn define(self: *@This(), alloc: std.mem.Allocator, name: []const u8) !Symbol {
        const symbol: Symbol = .{
            .name = try alloc.dupe(u8, name),
            .scope = .global,
            .index = self.num_definitions,
        };
        errdefer alloc.free(symbol.name);

        try self.store.put(alloc, symbol.name, symbol);
        self.num_definitions += 1;

        return symbol;
    }

    pub fn resolve(self: *@This(), name: []const u8) ?Symbol {
        return self.store.get(name);
    }

    test define {
        const expected: std.StaticStringMap(Symbol) = .initComptime(
            .{
                .{ "a", Symbol{ .name = "a", .scope = .global, .index = 0 } },
                .{ "b", Symbol{ .name = "b", .scope = .global, .index = 1 } },
            },
        );

        const alloc = std.testing.allocator;

        var global: @This() = .init();
        defer global.deinit(alloc);

        const a = try global.define(alloc, "a");
        try std.testing.expectEqualDeep(expected.get("a"), a);

        const b = try global.define(alloc, "b");
        try std.testing.expectEqualDeep(expected.get("b"), b);
    }

    test resolve {
        const alloc = std.testing.allocator;
        var global: @This() = .init();
        defer global.deinit(alloc);

        _ = try global.define(alloc, "a");
        _ = try global.define(alloc, "b");

        const expected = [_]Symbol{
            .{ .name = "a", .scope = .global, .index = 0 },
            .{ .name = "b", .scope = .global, .index = 1 },
        };

        for (expected) |sym| {
            const result = global.resolve(sym.name);
            try std.testing.expect(result != null);
            try std.testing.expectEqualDeep(sym, result);
        }
    }
};

const EmittedInstruction = struct {
    opcode: code.Opcode,
    position: usize,
};

instructions: std.ArrayList(u8),
constants: std.ArrayList(object.Object),
symbol_table: SymbolTable,

last_instruction: EmittedInstruction,
previous_instruction: EmittedInstruction,

pub fn init() Self {
    return .{
        .instructions = .empty,
        .constants = .empty,
        .symbol_table = .init(),
        .last_instruction = std.mem.zeroInit(EmittedInstruction, .{}),
        .previous_instruction = std.mem.zeroInit(EmittedInstruction, .{}),
    };
}

pub fn deinit(self: *Self, alloc: std.mem.Allocator) void {
    self.instructions.deinit(alloc);

    for (self.constants.items) |obj| {
        obj.deinit(alloc);
    }
    self.constants.deinit(alloc);

    self.symbol_table.deinit(alloc);
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

            // set last/prev instructions
            const previous = self.last_instruction;
            const last: EmittedInstruction = .{ .opcode = op, .position = pos };

            self.previous_instruction = previous;
            self.last_instruction = last;

            return pos;
        },
    }
}

fn replaceInstruction(self: *Self, pos: usize, new_instr: []const u8) !void {
    try self.instructions.replaceRangeBounded(pos, new_instr.len, new_instr);
}

fn changeOperand(self: *Self, op_pos: usize, operand: usize) !void {
    const op = std.enums.fromInt(code.Opcode, self.instructions.items[op_pos]) orelse return Error.UnsupportedOperator;

    switch (op) {
        inline else => |comp_op| {
            const new_instr = try code.make(comp_op, &.{operand});
            try self.replaceInstruction(op_pos, &new_instr);
        },
    }
}

fn lastInstructionIsPop(self: *Self) bool {
    return self.last_instruction.opcode == .pop;
}

fn removeLastPop(self: *Self) void {
    _ = self.instructions.pop();
    self.last_instruction = self.previous_instruction;
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
        .block_stmt => |stmt| {
            for (stmt.statements) |b_stmt| {
                try self.compileStatement(alloc, &b_stmt);
            }
        },
        .let_stmt => |stmt| {
            try self.compileExpression(alloc, stmt.value);
            const symbol = try self.symbol_table.define(alloc, stmt.name.value);
            _ = try self.emit(alloc, .set_global, &.{symbol.index});
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
    @"!",
};

fn compileExpression(self: *Self, alloc: std.mem.Allocator, node: *const ast.Node(.Expression)) anyerror!void {
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
                else => return Error.UnsupportedOperator,
            }
        },
        .prefix => |pref| {
            try self.compileExpression(alloc, pref.right);

            const operator = std.meta.stringToEnum(Operator, pref.operator) orelse
                return Error.UnsupportedOperator;

            switch (operator) {
                .@"!" => _ = try self.emit(alloc, .bang, &.{}),
                .@"-" => _ = try self.emit(alloc, .minus, &.{}),
                else => return Error.UnsupportedOperator,
            }
        },
        .int_literal => |int_lit| {
            const integer: object.Object = .{ .integer = .{ .value = int_lit.value } };
            _ = try self.emit(alloc, .constant, &.{try self.addConstant(alloc, integer)});
        },
        .boolean => |bool_lit| _ = try self.emit(alloc, if (bool_lit.value) .true else .false, &.{}),
        .if_exp => |if_exp| {
            try self.compileExpression(alloc, if_exp.condition);

            // emit with a made-up value
            const jump_not_truthy_pos = try self.emit(alloc, .jump_not_truthy, &.{9999});

            try self.compileStatement(alloc, &ast.Node(.Statement){
                .val = .{ .block_stmt = if_exp.consequence.* },
            });

            if (self.lastInstructionIsPop()) self.removeLastPop();

            // emit with a made-up value
            const jump_pos = try self.emit(alloc, .jump, &.{9999});

            const pos_after_consequence = self.instructions.items.len;
            try self.changeOperand(jump_not_truthy_pos, pos_after_consequence);

            if (if_exp.alternative == null) {
                _ = try self.emit(alloc, .nil, &.{});
            } else {
                try self.compileStatement(alloc, &ast.Node(.Statement){
                    .val = .{ .block_stmt = if_exp.alternative.?.* },
                });

                if (self.lastInstructionIsPop()) self.removeLastPop();
            }

            const pos_after_alternative = self.instructions.items.len;
            try self.changeOperand(jump_pos, pos_after_alternative);
        },
        .ident => |ident_exp| {
            const symbol = self.symbol_table.resolve(ident_exp.value) orelse return Error.UndefinedVariable;
            _ = try self.emit(alloc, .get_global, &.{symbol.index});
        },
        else => return Error.UnknownNode,
    }
}

pub const Bytecode = struct {
    instructions: code.Instructions,
    constants: []const object.Object,
};

// bake the processed bytecode
pub fn bytecode(self: *Self) Bytecode {
    return .{
        .instructions = self.instructions.items,
        .constants = self.constants.items,
    };
}

pub fn resetInstructions(self: *Self) void {
    self.instructions.clearRetainingCapacity();
    self.last_instruction = std.mem.zeroInit(EmittedInstruction, .{});
    self.previous_instruction = std.mem.zeroInit(EmittedInstruction, .{});
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
        .{
            .input = "-1",
            .expected_constants = &.{.{ .int = 1 }},
            .expected_instructions = @constCast(&[_]code.Instructions{
                &(try code.make(.constant, &.{0})),
                &(try code.make(.minus, &.{})),
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
        .{
            .input = "!true",
            .expected_constants = &.{},
            .expected_instructions = @constCast(&[_]code.Instructions{
                &(try code.make(.true, &.{})),
                &(try code.make(.bang, &.{})),
                &(try code.make(.pop, &.{})),
            }),
        },
    };

    try runCompilerTests(tests);
}

test "conditionals" {
    const tests: []const CompilerTestCase = &.{
        .{
            .input = "if (true) { 10 }; 3333;",
            .expected_constants = &.{ .{ .int = 10 }, .{ .int = 3333 } },
            .expected_instructions = @constCast(&[_]code.Instructions{
                // 0000
                &(try code.make(.true, &.{})),
                // 0001
                &(try code.make(.jump_not_truthy, &.{10})),
                // 0004
                &(try code.make(.constant, &.{0})),
                // 0007
                &(try code.make(.jump, &.{11})),
                // 0010
                &(try code.make(.nil, &.{})),
                // 0011
                &(try code.make(.pop, &.{})),
                // 0012
                &(try code.make(.constant, &.{1})),
                // 0015
                &(try code.make(.pop, &.{})),
            }),
        },
        .{
            .input = "if (true) { 10 } else { 20 }; 3333;",
            .expected_constants = &.{
                .{ .int = 10 },
                .{ .int = 20 },
                .{ .int = 3333 },
            },
            .expected_instructions = @constCast(&[_]code.Instructions{
                // 0000
                &(try code.make(.true, &.{})),
                // 0001
                &(try code.make(.jump_not_truthy, &.{10})),
                // 0004
                &(try code.make(.constant, &.{0})),
                // 0007
                &(try code.make(.jump, &.{13})),
                // 0010
                &(try code.make(.constant, &.{1})),
                // 0013
                &(try code.make(.pop, &.{})),
                // 0014
                &(try code.make(.constant, &.{2})),
                // 0017
                &(try code.make(.pop, &.{})),
            }),
        },
    };

    try runCompilerTests(tests);
}

test "global let statements" {
    const tests: []const CompilerTestCase = &.{
        .{
            .input = "let one = 1; let two = 2;",
            .expected_constants = &.{ .{ .int = 1 }, .{ .int = 2 } },
            .expected_instructions = @constCast(&[_]code.Instructions{
                &(try code.make(.constant, &.{0})),
                &(try code.make(.set_global, &.{0})),
                &(try code.make(.constant, &.{1})),
                &(try code.make(.set_global, &.{1})),
            }),
        },
        .{
            .input = "let one = 1; one;",
            .expected_constants = &.{.{ .int = 1 }},
            .expected_instructions = @constCast(&[_]code.Instructions{
                &(try code.make(.constant, &.{0})),
                &(try code.make(.set_global, &.{0})),
                &(try code.make(.get_global, &.{0})),
                &(try code.make(.pop, &.{})),
            }),
        },
        .{
            .input = "let one = 1; let two = one; two;",
            .expected_constants = &.{.{ .int = 1 }},
            .expected_instructions = @constCast(&[_]code.Instructions{
                &(try code.make(.constant, &.{0})),
                &(try code.make(.set_global, &.{0})),
                &(try code.make(.get_global, &.{0})),
                &(try code.make(.set_global, &.{1})),
                &(try code.make(.get_global, &.{1})),
                &(try code.make(.pop, &.{})),
            }),
        },
    };

    try runCompilerTests(tests);
}

fn parse(alloc: std.mem.Allocator, input: []const u8) !struct { ast.Node(.Common), Parser } {
    var l = Lexer.init(input);
    var p = Parser.init(&l);

    return .{ ast.Node(.Common){ .val = .{ .program = try p.parseProgram(alloc) } }, p };
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
    const alloc = std.testing.allocator;

    for (tests) |tt| {
        var program, var p = try parse(alloc, tt.input);
        defer program.val.program.deinit(alloc);
        defer p.deinit(alloc);

        var compiler = init();
        defer compiler.deinit(alloc);

        try compiler.compile(alloc, program);

        const bcode = compiler.bytecode();
        const exp_instructions = try std.mem.concat(alloc, u8, tt.expected_instructions);
        defer alloc.free(exp_instructions);

        try testInstructions(exp_instructions, bcode.instructions);
        try testConstants(tt.expected_constants, bcode.constants);
    }
}
