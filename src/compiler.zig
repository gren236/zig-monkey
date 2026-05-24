const std = @import("std");

const ast = @import("ast.zig");
const code = @import("code.zig");
const Lexer = @import("lexer.zig");
const object = @import("object.zig");
const Parser = @import("parser.zig");

const Self = @This();

pub const Error = error{ UnknownNode, UnsupportedOperator, UndefinedVariable, ScopeStackExhausted };

const SymbolTable = struct {
    const Scope = enum {
        global,
        local,
        builtin,
        free,
    };

    const Symbol = struct {
        name: []const u8,
        scope: Scope,
        index: usize,
    };

    outer: ?*SymbolTable,

    store: std.StringHashMapUnmanaged(Symbol),
    num_definitions: usize,
    free_symbols: std.ArrayList(Symbol),

    pub fn init() @This() {
        return .{
            .outer = null,
            .store = .empty,
            .num_definitions = 0,
            .free_symbols = .empty,
        };
    }

    pub fn create(alloc: std.mem.Allocator) !*@This() {
        const self = try alloc.create(@This());
        self.* = .init();

        return self;
    }

    pub fn initEnclosed(outer: *@This()) @This() {
        return .{
            .outer = outer,
            .store = .empty,
            .num_definitions = 0,
            .free_symbols = .empty,
        };
    }

    pub fn createEnclosed(alloc: std.mem.Allocator, outer: *@This()) !*@This() {
        const self = try alloc.create(@This());
        self.* = .initEnclosed(outer);

        return self;
    }

    pub fn deinit(self: *@This(), alloc: std.mem.Allocator) void {
        self.free_symbols.deinit(alloc);

        var iter = self.store.iterator();
        while (iter.next()) |entry| {
            alloc.free(entry.key_ptr.*);
        }

        self.store.deinit(alloc);
    }

    pub fn destroy(self: *@This(), alloc: std.mem.Allocator) void {
        self.deinit(alloc);
        alloc.destroy(self);
    }

    pub fn define(self: *@This(), alloc: std.mem.Allocator, name: []const u8) !Symbol {
        const symbol: Symbol = .{
            .name = try alloc.dupe(u8, name),
            .scope = if (self.outer != null) .local else .global,
            .index = self.num_definitions,
        };
        errdefer alloc.free(symbol.name);

        try self.store.put(alloc, symbol.name, symbol);
        self.num_definitions += 1;

        return symbol;
    }

    pub fn defineBuiltin(self: *@This(), alloc: std.mem.Allocator, index: usize, name: []const u8) !Symbol {
        const symbol: Symbol = .{
            .name = try alloc.dupe(u8, name),
            .scope = .builtin,
            .index = index,
        };
        errdefer alloc.free(symbol.name);

        try self.store.put(alloc, symbol.name, symbol);

        return symbol;
    }

    pub fn defineFree(self: *@This(), alloc: std.mem.Allocator, original: Symbol) !Symbol {
        try self.free_symbols.append(alloc, original);

        const symbol: Symbol = .{
            .name = try alloc.dupe(u8, original.name),
            .scope = .free,
            .index = self.free_symbols.items.len - 1,
        };
        errdefer alloc.free(symbol.name);

        try self.store.put(alloc, symbol.name, symbol);

        return symbol;
    }

    pub fn resolve(self: *@This(), alloc: std.mem.Allocator, name: []const u8) ?Symbol {
        var obj = self.store.get(name);

        if (obj == null and self.outer != null) {
            obj = self.outer.?.resolve(alloc, name);
            if (obj == null) return obj;

            if (obj.?.scope == .global or obj.?.scope == .builtin) return obj;

            return self.defineFree(alloc, obj.?) catch return null;
        }

        return obj;
    }

    test define {
        const expected: std.StaticStringMap(Symbol) = .initComptime(
            .{
                .{ "a", Symbol{ .name = "a", .scope = .global, .index = 0 } },
                .{ "b", Symbol{ .name = "b", .scope = .global, .index = 1 } },
                .{ "c", Symbol{ .name = "c", .scope = .local, .index = 0 } },
                .{ "d", Symbol{ .name = "d", .scope = .local, .index = 1 } },
                .{ "e", Symbol{ .name = "e", .scope = .local, .index = 0 } },
                .{ "f", Symbol{ .name = "f", .scope = .local, .index = 1 } },
            },
        );

        const alloc = std.testing.allocator;

        var global: *@This() = try .create(alloc);
        defer global.destroy(alloc);

        const a = try global.define(alloc, "a");
        try std.testing.expectEqualDeep(expected.get("a"), a);

        const b = try global.define(alloc, "b");
        try std.testing.expectEqualDeep(expected.get("b"), b);

        var firstLocal: *@This() = try .createEnclosed(alloc, global);
        defer firstLocal.destroy(alloc);

        const c = try firstLocal.define(alloc, "c");
        try std.testing.expectEqualDeep(expected.get("c"), c);

        const d = try firstLocal.define(alloc, "d");
        try std.testing.expectEqualDeep(expected.get("d"), d);

        var secondLocal: *@This() = try .createEnclosed(alloc, firstLocal);
        defer secondLocal.destroy(alloc);

        const e = try secondLocal.define(alloc, "e");
        try std.testing.expectEqualDeep(expected.get("e"), e);

        const f = try secondLocal.define(alloc, "f");
        try std.testing.expectEqualDeep(expected.get("f"), f);
    }

    test resolve {
        const alloc = std.testing.allocator;
        var global = try create(alloc);
        defer global.destroy(alloc);

        _ = try global.define(alloc, "a");
        _ = try global.define(alloc, "b");

        const expected = [_]Symbol{
            .{ .name = "a", .scope = .global, .index = 0 },
            .{ .name = "b", .scope = .global, .index = 1 },
        };

        for (expected) |sym| {
            const result = global.resolve(alloc, sym.name);
            try std.testing.expect(result != null);
            try std.testing.expectEqualDeep(sym, result);
        }
    }

    test "resolve local" {
        const alloc = std.testing.allocator;

        var global = try create(alloc);
        defer global.destroy(alloc);
        _ = try global.define(alloc, "a");
        _ = try global.define(alloc, "b");

        var local = try createEnclosed(alloc, global);
        defer local.destroy(alloc);
        _ = try local.define(alloc, "c");
        _ = try local.define(alloc, "d");

        const expected: []const Symbol = &.{
            .{ .name = "a", .scope = .global, .index = 0 },
            .{ .name = "b", .scope = .global, .index = 1 },
            .{ .name = "c", .scope = .local, .index = 0 },
            .{ .name = "d", .scope = .local, .index = 1 },
        };

        for (expected) |sym| {
            const result = local.resolve(alloc, sym.name);
            try std.testing.expect(result != null);
            try std.testing.expectEqualDeep(sym, result.?);
        }
    }

    test "resolve nested local" {
        const alloc = std.testing.allocator;

        var global = try create(alloc);
        defer global.destroy(alloc);
        _ = try global.define(alloc, "a");
        _ = try global.define(alloc, "b");

        var firstLocal = try createEnclosed(alloc, global);
        defer firstLocal.destroy(alloc);
        _ = try firstLocal.define(alloc, "c");
        _ = try firstLocal.define(alloc, "d");

        var secondLocal = try createEnclosed(alloc, firstLocal);
        defer secondLocal.destroy(alloc);
        _ = try secondLocal.define(alloc, "e");
        _ = try secondLocal.define(alloc, "f");

        const tests: []const struct {
            table: *SymbolTable,
            expectedSymbols: []const Symbol,
        } = &.{
            .{
                .table = firstLocal,
                .expectedSymbols = &.{
                    .{ .name = "a", .scope = .global, .index = 0 },
                    .{ .name = "b", .scope = .global, .index = 1 },
                    .{ .name = "c", .scope = .local, .index = 0 },
                    .{ .name = "d", .scope = .local, .index = 1 },
                },
            },
            .{
                .table = secondLocal,
                .expectedSymbols = &.{
                    .{ .name = "a", .scope = .global, .index = 0 },
                    .{ .name = "b", .scope = .global, .index = 1 },
                    .{ .name = "e", .scope = .local, .index = 0 },
                    .{ .name = "f", .scope = .local, .index = 1 },
                },
            },
        };

        for (tests) |tt| {
            for (tt.expectedSymbols) |sym| {
                const result = tt.table.resolve(alloc, sym.name);
                try std.testing.expect(result != null);
                try std.testing.expectEqualDeep(sym, result.?);
            }
        }
    }

    test "define resolve builtins" {
        const alloc = std.testing.allocator;

        var global = try create(alloc);
        defer global.destroy(alloc);
        var firstLocal = try createEnclosed(alloc, global);
        defer firstLocal.destroy(alloc);
        var secondLocal = try createEnclosed(alloc, firstLocal);
        defer secondLocal.destroy(alloc);

        const expected: []const Symbol = &.{
            .{ .name = "a", .scope = .builtin, .index = 0 },
            .{ .name = "c", .scope = .builtin, .index = 1 },
            .{ .name = "e", .scope = .builtin, .index = 2 },
            .{ .name = "f", .scope = .builtin, .index = 3 },
        };

        for (expected, 0..) |v, i| {
            _ = try global.defineBuiltin(alloc, i, v.name);
        }

        inline for (.{ global, firstLocal, secondLocal }) |table| {
            for (expected) |sym| {
                const result = table.resolve(alloc, sym.name);
                try std.testing.expect(result != null);
                try std.testing.expectEqualDeep(sym, result.?);
            }
        }
    }

    test "resolve free" {
        const alloc = std.testing.allocator;

        var global = try create(alloc);
        defer global.destroy(alloc);
        _ = try global.define(alloc, "a");
        _ = try global.define(alloc, "b");

        var firstLocal = try createEnclosed(alloc, global);
        defer firstLocal.destroy(alloc);
        _ = try firstLocal.define(alloc, "c");
        _ = try firstLocal.define(alloc, "d");

        var secondLocal = try createEnclosed(alloc, firstLocal);
        defer secondLocal.destroy(alloc);
        _ = try secondLocal.define(alloc, "e");
        _ = try secondLocal.define(alloc, "f");

        const tests: []const struct {
            table: *SymbolTable,
            expected_symbols: []const Symbol,
            expected_free_symbols: []const Symbol,
        } = &.{
            .{
                .table = firstLocal,
                .expected_symbols = &.{
                    .{ .name = "a", .scope = .global, .index = 0 },
                    .{ .name = "b", .scope = .global, .index = 1 },
                    .{ .name = "c", .scope = .local, .index = 0 },
                    .{ .name = "d", .scope = .local, .index = 1 },
                },
                .expected_free_symbols = &.{},
            },
            .{
                .table = secondLocal,
                .expected_symbols = &.{
                    .{ .name = "a", .scope = .global, .index = 0 },
                    .{ .name = "b", .scope = .global, .index = 1 },
                    .{ .name = "c", .scope = .free, .index = 0 },
                    .{ .name = "d", .scope = .free, .index = 1 },
                    .{ .name = "e", .scope = .local, .index = 0 },
                    .{ .name = "f", .scope = .local, .index = 1 },
                },
                .expected_free_symbols = &.{
                    .{ .name = "c", .scope = .local, .index = 0 },
                    .{ .name = "d", .scope = .local, .index = 1 },
                },
            },
        };

        for (tests) |tt| {
            for (tt.expected_symbols) |sym| {
                const result = tt.table.resolve(alloc, sym.name);
                try std.testing.expect(result != null);
                try std.testing.expectEqualDeep(sym, result.?);
            }

            try std.testing.expectEqual(tt.expected_free_symbols.len, tt.table.free_symbols.items.len);

            for (0.., tt.expected_free_symbols) |i, sym| {
                const result = tt.table.free_symbols.items[i];
                try std.testing.expectEqualDeep(sym, result);
            }
        }
    }

    test "resolve unresolvable free" {
        const alloc = std.testing.allocator;

        var global = try create(alloc);
        defer global.destroy(alloc);
        _ = try global.define(alloc, "a");

        var firstLocal = try createEnclosed(alloc, global);
        defer firstLocal.destroy(alloc);
        _ = try firstLocal.define(alloc, "c");

        var secondLocal = try createEnclosed(alloc, firstLocal);
        defer secondLocal.destroy(alloc);
        _ = try secondLocal.define(alloc, "e");
        _ = try secondLocal.define(alloc, "f");

        const expected: []const Symbol = &.{
            .{ .name = "a", .scope = .global, .index = 0 },
            .{ .name = "c", .scope = .free, .index = 0 },
            .{ .name = "e", .scope = .local, .index = 0 },
            .{ .name = "f", .scope = .local, .index = 1 },
        };

        for (expected) |sym| {
            try std.testing.expectEqualDeep(sym, secondLocal.resolve(alloc, sym.name));
        }

        const expected_unresolvable: []const []const u8 = &.{
            "b",
            "d",
        };

        for (expected_unresolvable) |name| {
            try std.testing.expectEqual(null, secondLocal.resolve(alloc, name));
        }
    }
};

const EmittedInstruction = struct {
    opcode: code.Opcode,
    position: usize,
};

const CompilationScope = struct {
    instructions: std.ArrayList(u8),
    last_instruction: EmittedInstruction,
    previous_instruction: EmittedInstruction,
};

scopes: std.ArrayList(CompilationScope),
scopeIndex: usize,

constants: std.ArrayList(object.Object),
symbol_table: *SymbolTable,

pub fn init(alloc: std.mem.Allocator) !Self {
    const main_scope: CompilationScope = .{
        .instructions = .empty,
        .last_instruction = std.mem.zeroInit(EmittedInstruction, .{}),
        .previous_instruction = std.mem.zeroInit(EmittedInstruction, .{}),
    };

    var self: Self = .{
        .constants = .empty,
        .symbol_table = try .create(alloc),
        .scopes = .empty,
        .scopeIndex = 0,
    };

    inline for (std.meta.fields(object.BuiltinFnIdent)) |f| {
        _ = try self.symbol_table.defineBuiltin(alloc, f.value, f.name);
    }

    try self.scopes.append(alloc, main_scope);

    return self;
}

pub fn deinit(self: *Self, alloc: std.mem.Allocator) void {
    for (0..self.scopes.items.len) |i| {
        self.scopes.items[i].instructions.deinit(alloc);
    }

    self.scopes.deinit(alloc);

    for (self.constants.items) |obj| {
        obj.deinit(alloc);
    }
    self.constants.deinit(alloc);

    self.symbol_table.destroy(alloc);
}

fn addConstant(self: *Self, alloc: std.mem.Allocator, obj: object.Object) !usize {
    try self.constants.append(alloc, try obj.clone(alloc));
    return self.constants.items.len - 1;
}

fn currentInstructions(self: *Self) *std.ArrayList(u8) {
    return &self.scopes.items[self.scopeIndex].instructions;
}

fn addInstruction(self: *Self, alloc: std.mem.Allocator, ins: []const u8) !usize {
    const pos_new_instruction = self.currentInstructions().items.len;
    try self.scopes.items[self.scopeIndex].instructions.appendSlice(alloc, ins);

    return pos_new_instruction;
}

fn enterScope(self: *Self, alloc: std.mem.Allocator) !void {
    const scope: CompilationScope = .{
        .instructions = .empty,
        .last_instruction = std.mem.zeroInit(EmittedInstruction, .{}),
        .previous_instruction = std.mem.zeroInit(EmittedInstruction, .{}),
    };

    try self.scopes.append(alloc, scope);
    self.scopeIndex += 1;

    self.symbol_table = try .createEnclosed(alloc, self.symbol_table);
}

fn leaveScope(self: *Self, alloc: std.mem.Allocator) !std.ArrayList(u8) {
    const top_scope = self.scopes.pop() orelse return Error.ScopeStackExhausted;
    self.scopeIndex -= 1;

    const old_symbol_table = self.symbol_table.outer.?;
    self.symbol_table.destroy(alloc);
    self.symbol_table = old_symbol_table;

    return top_scope.instructions;
}

fn emit(self: *Self, alloc: std.mem.Allocator, op: code.Opcode, operands: []const usize) !usize {
    switch (op) {
        inline else => |comp_op| {
            var ins = try code.make(comp_op, operands);
            const pos = try self.addInstruction(alloc, &ins);

            // set last/prev instructions
            const previous = self.scopes.items[self.scopeIndex].last_instruction;
            const last: EmittedInstruction = .{ .opcode = op, .position = pos };

            self.scopes.items[self.scopeIndex].previous_instruction = previous;
            self.scopes.items[self.scopeIndex].last_instruction = last;

            return pos;
        },
    }
}

fn replaceInstruction(self: *Self, pos: usize, new_instr: []const u8) !void {
    var instructions = self.currentInstructions();
    try instructions.replaceRangeBounded(pos, new_instr.len, new_instr);
}

fn changeOperand(self: *Self, op_pos: usize, operand: usize) !void {
    const op = std.enums.fromInt(code.Opcode, self.currentInstructions().items[op_pos]) orelse
        return Error.UnsupportedOperator;

    switch (op) {
        inline else => |comp_op| {
            const new_instr = try code.make(comp_op, &.{operand});
            try self.replaceInstruction(op_pos, &new_instr);
        },
    }
}

fn lastInstructionIs(self: *Self, op: code.Opcode) bool {
    if (self.currentInstructions().items.len == 0) return false;

    return self.scopes.items[self.scopeIndex].last_instruction.opcode == op;
}

fn removeLastPop(self: *Self) void {
    const previous = self.scopes.items[self.scopeIndex].previous_instruction;
    var instructions = self.currentInstructions();

    _ = instructions.pop();
    self.scopes.items[self.scopeIndex].last_instruction = previous;
}

fn replaceLastPopWithReturn(self: *Self) !void {
    const last_pos = self.scopes.items[self.scopeIndex].last_instruction.position;

    const new_instr = try code.make(.return_value, &.{});
    try self.replaceInstruction(last_pos, &new_instr);

    self.scopes.items[self.scopeIndex].last_instruction.opcode = .return_value;
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
            _ = try self.emit(
                alloc,
                if (symbol.scope == .global) .set_global else .set_local,
                &.{symbol.index},
            );
        },
        .return_stmt => |stmt| {
            try self.compileExpression(alloc, stmt.return_value);
            _ = try self.emit(alloc, .return_value, &.{});
        },
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

            if (self.lastInstructionIs(.pop)) self.removeLastPop();

            // emit with a made-up value
            const jump_pos = try self.emit(alloc, .jump, &.{9999});

            const pos_after_consequence = self.currentInstructions().items.len;
            try self.changeOperand(jump_not_truthy_pos, pos_after_consequence);

            if (if_exp.alternative == null) {
                _ = try self.emit(alloc, .nil, &.{});
            } else {
                try self.compileStatement(alloc, &ast.Node(.Statement){
                    .val = .{ .block_stmt = if_exp.alternative.?.* },
                });

                if (self.lastInstructionIs(.pop)) self.removeLastPop();
            }

            const pos_after_alternative = self.currentInstructions().items.len;
            try self.changeOperand(jump_pos, pos_after_alternative);
        },
        .ident => |ident_exp| {
            const symbol = self.symbol_table.resolve(alloc, ident_exp.value) orelse return Error.UndefinedVariable;
            _ = try self.emit(
                alloc,
                switch (symbol.scope) {
                    .global => .get_global,
                    .local => .get_local,
                    .builtin => .get_builtin,
                    .free => .get_free,
                },
                &.{symbol.index},
            );
        },
        .string_literal => |str_exp| {
            const str: object.Object = .{ .string = .{ .value = str_exp.value } };
            _ = try self.emit(alloc, .constant, &.{try self.addConstant(alloc, str)});
        },
        .array_literal => |arr_exp| {
            for (arr_exp.elements) |elem| {
                try self.compileExpression(alloc, &elem);
            }

            _ = try self.emit(alloc, .array, &.{arr_exp.elements.len});
        },
        .hash_literal => |hash_exp| {
            const keys = try alloc.alloc(ast.Node(.Expression), hash_exp.pairs.size);
            defer alloc.free(keys);

            var key_iter = hash_exp.pairs.keyIterator();
            var i: usize = 0;
            while (key_iter.next()) |key_ptr| : (i += 1) {
                keys[i] = key_ptr.*;
            }

            std.mem.sort(ast.Node(.Expression), keys, {}, ast.lessThan);

            for (keys) |key| {
                try self.compileExpression(alloc, &key);
                try self.compileExpression(alloc, &hash_exp.pairs.get(key).?);
            }

            _ = try self.emit(alloc, .hash, &.{hash_exp.pairs.size * 2});
        },
        .index_exp => |index_exp| {
            try self.compileExpression(alloc, index_exp.left);
            try self.compileExpression(alloc, index_exp.index);

            _ = try self.emit(alloc, .index, &.{});
        },
        .fn_literal => |fn_exp| {
            try self.enterScope(alloc);

            for (fn_exp.parameters) |param| {
                _ = try self.symbol_table.define(alloc, param.value);
            }

            try self.compileStatement(
                alloc,
                &.{ .val = .{ .block_stmt = fn_exp.body.* } },
            );

            if (self.lastInstructionIs(.pop)) try self.replaceLastPopWithReturn();
            if (!self.lastInstructionIs(.return_value)) _ = try self.emit(alloc, .@"return", &.{});

            var free_symbols = try self.symbol_table.free_symbols.clone(alloc);
            defer free_symbols.deinit(alloc);
            const num_locals = self.symbol_table.num_definitions;
            var instructions = try self.leaveScope(alloc);
            defer instructions.deinit(alloc);

            for (free_symbols.items) |sym| {
                _ = try self.emit(
                    alloc,
                    switch (sym.scope) {
                        .global => .get_global,
                        .local => .get_local,
                        .builtin => .get_builtin,
                        .free => .get_free,
                    },
                    &.{sym.index},
                );
            }

            const comp_fn: object.Object = .{
                .comp_func = .{
                    .instructions = instructions.items,
                    .num_locals = num_locals,
                    .num_parameters = fn_exp.parameters.len,
                },
            };

            _ = try self.emit(
                alloc,
                .closure,
                &.{ try self.addConstant(alloc, comp_fn), free_symbols.items.len },
            );
        },
        .call_exp => |call_exp| {
            try self.compileExpression(alloc, call_exp.function);

            for (call_exp.arguments) |arg| {
                try self.compileExpression(alloc, &arg);
            }

            _ = try self.emit(alloc, .call, &.{call_exp.arguments.len});
        },
    }
}

pub const Bytecode = struct {
    instructions: code.Instructions,
    constants: []const object.Object,
};

// bake the processed bytecode
pub fn bytecode(self: *Self) Bytecode {
    return .{
        .instructions = self.currentInstructions().items,
        .constants = self.constants.items,
    };
}

pub fn resetInstructions(self: *Self) void {
    self.currentInstructions().clearRetainingCapacity();
    self.scopes.items[self.scopeIndex].last_instruction = std.mem.zeroInit(EmittedInstruction, .{});
    self.scopes.items[self.scopeIndex].previous_instruction = std.mem.zeroInit(EmittedInstruction, .{});
}

// Testing

const CompilerTestCase = struct {
    input: []const u8,
    expected_constants: []const union(enum) {
        int: usize,
        str: []const u8,
        instr: []const code.Instructions,
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

test "string expressions" {
    const tests: []const CompilerTestCase = &.{
        .{
            .input = "\"monkey\"",
            .expected_constants = &.{.{ .str = "monkey" }},
            .expected_instructions = @constCast(&[_]code.Instructions{
                &(try code.make(.constant, &.{0})),
                &(try code.make(.pop, &.{})),
            }),
        },
        .{
            .input = "\"mon\" + \"key\"",
            .expected_constants = &.{ .{ .str = "mon" }, .{ .str = "key" } },
            .expected_instructions = @constCast(&[_]code.Instructions{
                &(try code.make(.constant, &.{0})),
                &(try code.make(.constant, &.{1})),
                &(try code.make(.add, &.{})),
                &(try code.make(.pop, &.{})),
            }),
        },
    };

    try runCompilerTests(tests);
}

test "array literals" {
    const tests: []const CompilerTestCase = &.{
        .{
            .input = "[]",
            .expected_constants = &.{},
            .expected_instructions = @constCast(&[_]code.Instructions{
                &(try code.make(.array, &.{0})),
                &(try code.make(.pop, &.{})),
            }),
        },
        .{
            .input = "[1, 2, 3]",
            .expected_constants = &.{ .{ .int = 1 }, .{ .int = 2 }, .{ .int = 3 } },
            .expected_instructions = @constCast(&[_]code.Instructions{
                &(try code.make(.constant, &.{0})),
                &(try code.make(.constant, &.{1})),
                &(try code.make(.constant, &.{2})),
                &(try code.make(.array, &.{3})),
                &(try code.make(.pop, &.{})),
            }),
        },
        .{
            .input = "[1 + 2, 3 - 4, 5 * 6]",
            .expected_constants = &.{
                .{ .int = 1 },
                .{ .int = 2 },
                .{ .int = 3 },
                .{ .int = 4 },
                .{ .int = 5 },
                .{ .int = 6 },
            },
            .expected_instructions = @constCast(&[_]code.Instructions{
                &(try code.make(.constant, &.{0})),
                &(try code.make(.constant, &.{1})),
                &(try code.make(.add, &.{})),
                &(try code.make(.constant, &.{2})),
                &(try code.make(.constant, &.{3})),
                &(try code.make(.sub, &.{})),
                &(try code.make(.constant, &.{4})),
                &(try code.make(.constant, &.{5})),
                &(try code.make(.mul, &.{})),
                &(try code.make(.array, &.{3})),
                &(try code.make(.pop, &.{})),
            }),
        },
    };

    try runCompilerTests(tests);
}

test "hash literals" {
    const tests: []const CompilerTestCase = &.{
        .{
            .input = "{}",
            .expected_constants = &.{},
            .expected_instructions = @constCast(&[_]code.Instructions{
                &(try code.make(.hash, &.{0})),
                &(try code.make(.pop, &.{})),
            }),
        },
        .{
            .input = "{1: 2, 3: 4, 5: 6}",
            .expected_constants = &.{
                .{ .int = 1 },
                .{ .int = 2 },
                .{ .int = 3 },
                .{ .int = 4 },
                .{ .int = 5 },
                .{ .int = 6 },
            },
            .expected_instructions = @constCast(&[_]code.Instructions{
                &(try code.make(.constant, &.{0})),
                &(try code.make(.constant, &.{1})),
                &(try code.make(.constant, &.{2})),
                &(try code.make(.constant, &.{3})),
                &(try code.make(.constant, &.{4})),
                &(try code.make(.constant, &.{5})),
                &(try code.make(.hash, &.{6})),
                &(try code.make(.pop, &.{})),
            }),
        },
        .{
            .input = "{1: 2 + 3, 4: 5 * 6}",
            .expected_constants = &.{
                .{ .int = 1 },
                .{ .int = 2 },
                .{ .int = 3 },
                .{ .int = 4 },
                .{ .int = 5 },
                .{ .int = 6 },
            },
            .expected_instructions = @constCast(&[_]code.Instructions{
                &(try code.make(.constant, &.{0})),
                &(try code.make(.constant, &.{1})),
                &(try code.make(.constant, &.{2})),
                &(try code.make(.add, &.{})),
                &(try code.make(.constant, &.{3})),
                &(try code.make(.constant, &.{4})),
                &(try code.make(.constant, &.{5})),
                &(try code.make(.mul, &.{})),
                &(try code.make(.hash, &.{4})),
                &(try code.make(.pop, &.{})),
            }),
        },
    };

    try runCompilerTests(tests);
}

test "index expressions" {
    const tests: []const CompilerTestCase = &.{
        .{
            .input = "[1, 2, 3][1 + 1]",
            .expected_constants = &.{
                .{ .int = 1 },
                .{ .int = 2 },
                .{ .int = 3 },
                .{ .int = 1 },
                .{ .int = 1 },
            },
            .expected_instructions = @constCast(&[_]code.Instructions{
                &(try code.make(.constant, &.{0})),
                &(try code.make(.constant, &.{1})),
                &(try code.make(.constant, &.{2})),
                &(try code.make(.array, &.{3})),
                &(try code.make(.constant, &.{3})),
                &(try code.make(.constant, &.{4})),
                &(try code.make(.add, &.{})),
                &(try code.make(.index, &.{})),
                &(try code.make(.pop, &.{})),
            }),
        },
        .{
            .input = "{1: 2}[2 - 1]",
            .expected_constants = &.{
                .{ .int = 1 },
                .{ .int = 2 },
                .{ .int = 2 },
                .{ .int = 1 },
            },
            .expected_instructions = @constCast(&[_]code.Instructions{
                &(try code.make(.constant, &.{0})),
                &(try code.make(.constant, &.{1})),
                &(try code.make(.hash, &.{2})),
                &(try code.make(.constant, &.{2})),
                &(try code.make(.constant, &.{3})),
                &(try code.make(.sub, &.{})),
                &(try code.make(.index, &.{})),
                &(try code.make(.pop, &.{})),
            }),
        },
    };

    try runCompilerTests(tests);
}

test "functions" {
    const tests: []const CompilerTestCase = &.{
        .{
            .input = "fn() { return 5 + 10 }",
            .expected_constants = &.{
                .{ .int = 5 },
                .{ .int = 10 },
                .{ .instr = &.{
                    &(try code.make(.constant, &.{0})),
                    &(try code.make(.constant, &.{1})),
                    &(try code.make(.add, &.{})),
                    &(try code.make(.return_value, &.{})),
                } },
            },
            .expected_instructions = @constCast(&[_]code.Instructions{
                &(try code.make(.closure, &.{ 2, 0 })),
                &(try code.make(.pop, &.{})),
            }),
        },
        .{
            .input = "fn() { 5 + 10 }",
            .expected_constants = &.{
                .{ .int = 5 },
                .{ .int = 10 },
                .{ .instr = &.{
                    &(try code.make(.constant, &.{0})),
                    &(try code.make(.constant, &.{1})),
                    &(try code.make(.add, &.{})),
                    &(try code.make(.return_value, &.{})),
                } },
            },
            .expected_instructions = @constCast(&[_]code.Instructions{
                &(try code.make(.closure, &.{ 2, 0 })),
                &(try code.make(.pop, &.{})),
            }),
        },
        .{
            .input = "fn() { 1; 2 }",
            .expected_constants = &.{
                .{ .int = 1 },
                .{ .int = 2 },
                .{ .instr = &.{
                    &(try code.make(.constant, &.{0})),
                    &(try code.make(.pop, &.{})),
                    &(try code.make(.constant, &.{1})),
                    &(try code.make(.return_value, &.{})),
                } },
            },
            .expected_instructions = @constCast(&[_]code.Instructions{
                &(try code.make(.closure, &.{ 2, 0 })),
                &(try code.make(.pop, &.{})),
            }),
        },
        .{
            .input = "fn() { }",
            .expected_constants = &.{
                .{ .instr = &.{
                    &(try code.make(.@"return", &.{})),
                } },
            },
            .expected_instructions = @constCast(&[_]code.Instructions{
                &(try code.make(.closure, &.{ 0, 0 })),
                &(try code.make(.pop, &.{})),
            }),
        },
    };

    try runCompilerTests(tests);
}

test "closures" {
    const tests: []const CompilerTestCase = &.{
        .{
            .input =
            \\ fn (a) {
            \\     fn (b) {
            \\         a + b
            \\     }
            \\ }
            ,
            .expected_constants = &.{
                .{ .instr = &.{
                    &(try code.make(.get_free, &.{0})),
                    &(try code.make(.get_local, &.{0})),
                    &(try code.make(.add, &.{})),
                    &(try code.make(.return_value, &.{})),
                } },
                .{ .instr = &.{
                    &(try code.make(.get_local, &.{0})),
                    &(try code.make(.closure, &.{ 0, 1 })),
                    &(try code.make(.return_value, &.{})),
                } },
            },
            .expected_instructions = @constCast(&[_]code.Instructions{
                &(try code.make(.closure, &.{ 1, 0 })),
                &(try code.make(.pop, &.{})),
            }),
        },
        .{
            .input =
            \\ fn (a) {
            \\     fn (b) {
            \\         fn (c) {
            \\             a + b + c
            \\         }
            \\     }
            \\ }
            ,
            .expected_constants = &.{
                .{ .instr = &.{
                    &(try code.make(.get_free, &.{0})),
                    &(try code.make(.get_free, &.{1})),
                    &(try code.make(.add, &.{})),
                    &(try code.make(.get_local, &.{0})),
                    &(try code.make(.add, &.{})),
                    &(try code.make(.return_value, &.{})),
                } },
                .{ .instr = &.{
                    &(try code.make(.get_free, &.{0})),
                    &(try code.make(.get_local, &.{0})),
                    &(try code.make(.closure, &.{ 0, 2 })),
                    &(try code.make(.return_value, &.{})),
                } },
                .{ .instr = &.{
                    &(try code.make(.get_local, &.{0})),
                    &(try code.make(.closure, &.{ 1, 1 })),
                    &(try code.make(.return_value, &.{})),
                } },
            },
            .expected_instructions = @constCast(&[_]code.Instructions{
                &(try code.make(.closure, &.{ 2, 0 })),
                &(try code.make(.pop, &.{})),
            }),
        },
        .{
            .input =
            \\ let global = 55;
            \\
            \\ fn() {
            \\     let a = 66;
            \\
            \\     fn() {
            \\         let b = 77;
            \\
            \\         fn() {
            \\             let c = 88;
            \\             global + a + b + c;
            \\         }
            \\     }
            \\ }
            ,
            .expected_constants = &.{
                .{ .int = 55 },
                .{ .int = 66 },
                .{ .int = 77 },
                .{ .int = 88 },
                .{ .instr = &.{
                    &(try code.make(.constant, &.{3})),
                    &(try code.make(.set_local, &.{0})),
                    &(try code.make(.get_global, &.{0})),
                    &(try code.make(.get_free, &.{0})),
                    &(try code.make(.add, &.{})),
                    &(try code.make(.get_free, &.{1})),
                    &(try code.make(.add, &.{})),
                    &(try code.make(.get_local, &.{0})),
                    &(try code.make(.add, &.{})),
                    &(try code.make(.return_value, &.{})),
                } },
                .{ .instr = &.{
                    &(try code.make(.constant, &.{2})),
                    &(try code.make(.set_local, &.{0})),
                    &(try code.make(.get_free, &.{0})),
                    &(try code.make(.get_local, &.{0})),
                    &(try code.make(.closure, &.{ 4, 2 })),
                    &(try code.make(.return_value, &.{})),
                } },
                .{ .instr = &.{
                    &(try code.make(.constant, &.{1})),
                    &(try code.make(.set_local, &.{0})),
                    &(try code.make(.get_local, &.{0})),
                    &(try code.make(.closure, &.{ 5, 1 })),
                    &(try code.make(.return_value, &.{})),
                } },
            },
            .expected_instructions = @constCast(&[_]code.Instructions{
                &(try code.make(.constant, &.{0})),
                &(try code.make(.set_global, &.{0})),
                &(try code.make(.closure, &.{ 6, 0 })),
                &(try code.make(.pop, &.{})),
            }),
        },
    };

    try runCompilerTests(tests);
}

test "function calls" {
    const tests: []const CompilerTestCase = &.{
        .{
            .input = "fn() { 24 }();",
            .expected_constants = &.{
                .{ .int = 24 },
                .{ .instr = &.{
                    &(try code.make(.constant, &.{0})),
                    &(try code.make(.return_value, &.{})),
                } },
            },
            .expected_instructions = @constCast(&[_]code.Instructions{
                &(try code.make(.closure, &.{ 1, 0 })),
                &(try code.make(.call, &.{0})),
                &(try code.make(.pop, &.{})),
            }),
        },
        .{
            .input =
            \\ let noArg = fn() { 24 };
            \\ noArg();
            ,
            .expected_constants = &.{
                .{ .int = 24 },
                .{ .instr = &.{
                    &(try code.make(.constant, &.{0})),
                    &(try code.make(.return_value, &.{})),
                } },
            },
            .expected_instructions = @constCast(&[_]code.Instructions{
                &(try code.make(.closure, &.{ 1, 0 })),
                &(try code.make(.set_global, &.{0})),
                &(try code.make(.get_global, &.{0})),
                &(try code.make(.call, &.{0})),
                &(try code.make(.pop, &.{})),
            }),
        },
        .{
            .input =
            \\ let oneArg = fn(a) { };
            \\ oneArg(24);
            ,
            .expected_constants = &.{
                .{ .instr = &.{
                    &(try code.make(.@"return", &.{})),
                } },
                .{ .int = 24 },
            },
            .expected_instructions = @constCast(&[_]code.Instructions{
                &(try code.make(.closure, &.{ 0, 0 })),
                &(try code.make(.set_global, &.{0})),
                &(try code.make(.get_global, &.{0})),
                &(try code.make(.constant, &.{1})),
                &(try code.make(.call, &.{1})),
                &(try code.make(.pop, &.{})),
            }),
        },
        .{
            .input =
            \\ let manyArg = fn(a, b, c) { };
            \\ manyArg(24, 25, 26);
            ,
            .expected_constants = &.{
                .{ .instr = &.{
                    &(try code.make(.@"return", &.{})),
                } },
                .{ .int = 24 },
                .{ .int = 25 },
                .{ .int = 26 },
            },
            .expected_instructions = @constCast(&[_]code.Instructions{
                &(try code.make(.closure, &.{ 0, 0 })),
                &(try code.make(.set_global, &.{0})),
                &(try code.make(.get_global, &.{0})),
                &(try code.make(.constant, &.{1})),
                &(try code.make(.constant, &.{2})),
                &(try code.make(.constant, &.{3})),
                &(try code.make(.call, &.{3})),
                &(try code.make(.pop, &.{})),
            }),
        },
        .{
            .input =
            \\ let oneArg = fn(a) { a };
            \\ oneArg(24);
            ,
            .expected_constants = &.{
                .{ .instr = &.{
                    &(try code.make(.get_local, &.{0})),
                    &(try code.make(.return_value, &.{})),
                } },
                .{ .int = 24 },
            },
            .expected_instructions = @constCast(&[_]code.Instructions{
                &(try code.make(.closure, &.{ 0, 0 })),
                &(try code.make(.set_global, &.{0})),
                &(try code.make(.get_global, &.{0})),
                &(try code.make(.constant, &.{1})),
                &(try code.make(.call, &.{1})),
                &(try code.make(.pop, &.{})),
            }),
        },
        .{
            .input =
            \\ let manyArg = fn(a, b, c) { a; b; c };
            \\ manyArg(24, 25, 26);
            ,
            .expected_constants = &.{
                .{ .instr = &.{
                    &(try code.make(.get_local, &.{0})),
                    &(try code.make(.pop, &.{})),
                    &(try code.make(.get_local, &.{1})),
                    &(try code.make(.pop, &.{})),
                    &(try code.make(.get_local, &.{2})),
                    &(try code.make(.return_value, &.{})),
                } },
                .{ .int = 24 },
                .{ .int = 25 },
                .{ .int = 26 },
            },
            .expected_instructions = @constCast(&[_]code.Instructions{
                &(try code.make(.closure, &.{ 0, 0 })),
                &(try code.make(.set_global, &.{0})),
                &(try code.make(.get_global, &.{0})),
                &(try code.make(.constant, &.{1})),
                &(try code.make(.constant, &.{2})),
                &(try code.make(.constant, &.{3})),
                &(try code.make(.call, &.{3})),
                &(try code.make(.pop, &.{})),
            }),
        },
    };

    try runCompilerTests(tests);
}

test "let statements scopes" {
    const tests: []const CompilerTestCase = &.{
        .{
            .input =
            \\ let num = 55;
            \\ fn() { num }
            ,
            .expected_constants = &.{
                .{ .int = 55 },
                .{ .instr = &.{
                    &(try code.make(.get_global, &.{0})),
                    &(try code.make(.return_value, &.{})),
                } },
            },
            .expected_instructions = @constCast(&[_]code.Instructions{
                &(try code.make(.constant, &.{0})),
                &(try code.make(.set_global, &.{0})),
                &(try code.make(.closure, &.{ 1, 0 })),
                &(try code.make(.pop, &.{})),
            }),
        },
        .{
            .input =
            \\ fn() {
            \\     let num = 55;
            \\     num
            \\ }
            ,
            .expected_constants = &.{
                .{ .int = 55 },
                .{ .instr = &.{
                    &(try code.make(.constant, &.{0})),
                    &(try code.make(.set_local, &.{0})),
                    &(try code.make(.get_local, &.{0})),
                    &(try code.make(.return_value, &.{})),
                } },
            },
            .expected_instructions = @constCast(&[_]code.Instructions{
                &(try code.make(.closure, &.{ 1, 0 })),
                &(try code.make(.pop, &.{})),
            }),
        },
        .{
            .input =
            \\ fn() {
            \\     let a = 55;
            \\     let b = 77;
            \\     a + b
            \\ }
            ,
            .expected_constants = &.{
                .{ .int = 55 },
                .{ .int = 77 },
                .{ .instr = &.{
                    &(try code.make(.constant, &.{0})),
                    &(try code.make(.set_local, &.{0})),
                    &(try code.make(.constant, &.{1})),
                    &(try code.make(.set_local, &.{1})),
                    &(try code.make(.get_local, &.{0})),
                    &(try code.make(.get_local, &.{1})),
                    &(try code.make(.add, &.{})),
                    &(try code.make(.return_value, &.{})),
                } },
            },
            .expected_instructions = @constCast(&[_]code.Instructions{
                &(try code.make(.closure, &.{ 2, 0 })),
                &(try code.make(.pop, &.{})),
            }),
        },
    };

    try runCompilerTests(tests);
}

test "builtins" {
    const tests: []const CompilerTestCase = &.{
        .{
            .input =
            \\ len([]);
            \\ push([], 1);
            ,
            .expected_constants = &.{
                .{ .int = 1 },
            },
            .expected_instructions = @constCast(&[_]code.Instructions{
                &(try code.make(.get_builtin, &.{0})),
                &(try code.make(.array, &.{0})),
                &(try code.make(.call, &.{1})),
                &(try code.make(.pop, &.{})),
                &(try code.make(.get_builtin, &.{4})),
                &(try code.make(.array, &.{0})),
                &(try code.make(.constant, &.{0})),
                &(try code.make(.call, &.{2})),
                &(try code.make(.pop, &.{})),
            }),
        },
        .{
            .input = "fn() { len([]) }",
            .expected_constants = &.{
                .{ .instr = &.{
                    &(try code.make(.get_builtin, &.{0})),
                    &(try code.make(.array, &.{0})),
                    &(try code.make(.call, &.{1})),
                    &(try code.make(.return_value, &.{})),
                } },
            },
            .expected_instructions = @constCast(&[_]code.Instructions{
                &(try code.make(.closure, &.{ 0, 0 })),
                &(try code.make(.pop, &.{})),
            }),
        },
    };

    try runCompilerTests(tests);
}

test "compilation scopes" {
    const alloc = std.testing.allocator;

    var compiler = try init(alloc);
    defer compiler.deinit(alloc);
    try std.testing.expectEqual(0, compiler.scopeIndex);
    const globalSymbolTable = compiler.symbol_table;

    _ = try compiler.emit(alloc, .mul, &.{});

    try compiler.enterScope(alloc);
    try std.testing.expectEqual(1, compiler.scopeIndex);

    _ = try compiler.emit(alloc, .sub, &.{});

    try std.testing.expectEqual(1, compiler.scopes.items[compiler.scopeIndex].instructions.items.len);
    try std.testing.expectEqual(code.Opcode.sub, compiler.scopes.items[compiler.scopeIndex].last_instruction.opcode);
    try std.testing.expectEqualDeep(globalSymbolTable, compiler.symbol_table.outer.?);

    var instructions = try compiler.leaveScope(alloc);
    defer instructions.deinit(alloc);
    try std.testing.expectEqual(0, compiler.scopeIndex);
    try std.testing.expectEqualDeep(globalSymbolTable, compiler.symbol_table);
    try std.testing.expectEqual(null, compiler.symbol_table.outer);

    _ = try compiler.emit(alloc, .add, &.{});

    try std.testing.expectEqual(2, compiler.scopes.items[compiler.scopeIndex].instructions.items.len);
    try std.testing.expectEqual(code.Opcode.add, compiler.scopes.items[compiler.scopeIndex].last_instruction.opcode);
    try std.testing.expectEqual(code.Opcode.mul, compiler.scopes.items[compiler.scopeIndex].previous_instruction.opcode);
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

fn testStringObject(expected: []const u8, actual: object.Object) !void {
    try std.testing.expectEqual(object.ObjectType.string, @as(object.ObjectType, actual));
    try std.testing.expectEqualStrings(expected, actual.string.value);
}

fn testConstants(expected: @FieldType(CompilerTestCase, "expected_constants"), actual: []const object.Object) !void {
    try std.testing.expectEqual(expected.len, actual.len);

    for (expected, actual) |exp_const, act_const| {
        switch (exp_const) {
            .int => |exp| try testIntegerObject(@intCast(exp), act_const),
            .str => |exp| try testStringObject(exp, act_const),
            .instr => |exp| {
                try std.testing.expectEqual(object.ObjectType.comp_func, @as(object.ObjectType, act_const));

                const exp_instructions = try std.mem.concat(std.testing.allocator, u8, exp);
                defer std.testing.allocator.free(exp_instructions);

                try testInstructions(exp_instructions, act_const.comp_func.instructions);
            },
        }
    }
}

fn runCompilerTests(tests: []const CompilerTestCase) !void {
    const alloc = std.testing.allocator;

    for (tests) |tt| {
        var program, var p = try parse(alloc, tt.input);
        defer program.val.program.deinit(alloc);
        defer p.deinit(alloc);

        var compiler = try init(alloc);
        defer compiler.deinit(alloc);

        try compiler.compile(alloc, program);

        const bcode = compiler.bytecode();
        const exp_instructions = try std.mem.concat(alloc, u8, tt.expected_instructions);
        defer alloc.free(exp_instructions);

        try testInstructions(exp_instructions, bcode.instructions);
        try testConstants(tt.expected_constants, bcode.constants);
    }
}
