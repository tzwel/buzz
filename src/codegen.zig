const std = @import("std");
const builtin = @import("builtin");
const mem = std.mem;
const Allocator = mem.Allocator;
const assert = std.debug.assert;

const _chunk = @import("./chunk.zig");
const _obj = @import("./obj.zig");
const _vm = @import("./vm.zig");
const _value = @import("./value.zig");
const _disassembler = @import("./disassembler.zig");
const _parser = @import("./parser.zig");
const _node = @import("./node.zig");
const _token = @import("./token.zig");
const GarbageCollector = @import("./memory.zig").GarbageCollector;
const BuildOptions = @import("build_options");
const ParseNode = _node.ParseNode;
const FunctionNode = _node.FunctionNode;
const ObjFunction = _obj.ObjFunction;
const Global = _parser.Global;
const Parser = _parser.Parser;
const OpCode = _chunk.OpCode;
const Value = _value.Value;
const Chunk = _chunk.Chunk;
const Arg = _chunk.Arg;
const FullArg = _chunk.FullArg;
const Reg = _chunk.Reg;
const Instruction = _chunk.Instruction;
const Token = _token.Token;
const ObjTypeDef = _obj.ObjTypeDef;
const PlaceholderDef = _obj.PlaceholderDef;
const TypeRegistry = _obj.TypeRegistry;

pub const Frame = struct {
    enclosing: ?*Frame = null,
    function_node: *FunctionNode,
    function: ?*ObjFunction = null,
    return_counts: bool = false,
    return_emitted: bool = false,
    register_top: u8 = 0,

    try_should_handle: ?std.AutoHashMap(*ObjTypeDef, void) = null,
};

pub const CodeGen = struct {
    const Self = @This();

    current: ?*Frame = null,
    gc: *GarbageCollector,
    testing: bool,
    // Jump to patch at end of current expression with a optional unwrapping in the middle of it
    opt_jumps: ?std.ArrayList(usize) = null,
    had_error: bool = false,
    panic_mode: bool = false,
    // Used to generate error messages
    parser: *Parser,

    pub fn init(
        gc: *GarbageCollector,
        parser: *Parser,
        testing: bool,
    ) Self {
        return .{
            .gc = gc,
            .parser = parser,
            .testing = testing,
        };
    }

    pub fn deinit(_: *Self) void {}

    pub fn pushRegister(self: *Self) u8 {
        self.current.?.register_top += 1;

        if (self.current.?.register_top >= 255) {
            @panic("Expressions uses too many registers");
        }

        return self.current.?.register_top - 1;
    }

    pub fn popRegister(self: *Self) u8 {
        self.current.?.register_top -= 1;

        assert(self.current.?.register_top >= 0);

        return self.current.?.register_top;
    }

    pub fn peekRegister(self: *Self, distance: u8) u8 {
        assert(distance <= self.current.?.register_top);
        return self.current.?.register_top - distance - 1;
    }

    pub inline fn currentCode(self: *Self) usize {
        return self.current.?.function.?.chunk.code.items.len;
    }

    pub fn generate(self: *Self, root: *FunctionNode) anyerror!?*ObjFunction {
        self.had_error = false;
        self.panic_mode = false;

        if (BuildOptions.debug) {
            var out = std.ArrayList(u8).init(self.gc.allocator);
            defer out.deinit();

            try root.node.toJson(&root.node, &out.writer());

            try std.io.getStdOut().writer().print("\n{s}", .{out.items});
        }

        const function = try root.node.toByteCode(&root.node, self, null);

        return if (self.had_error) null else function;
    }

    pub fn emit(self: *Self, location: Token, code: Instruction) !void {
        try self.current.?.function.?.chunk.write(code, location.line);
    }

    pub fn emitTwo(self: *Self, location: Token, a: u16, b: u16) !void {
        try self.emit(location, (@intCast(Instruction, a) << 16) | @intCast(Instruction, b));
    }

    // OP_ | arg
    pub fn emitCodeArg(self: *Self, location: Token, code: OpCode, arg: FullArg) !void {
        try self.emit(location, (@intCast(Instruction, @enumToInt(code)) << @bitSizeOf(FullArg)) | @intCast(Instruction, arg));
    }

    pub fn emitOpCode(self: *Self, location: Token, code: OpCode) !void {
        try self.emit(location, @intCast(Instruction, @intCast(Instruction, @enumToInt(code)) << @bitSizeOf(FullArg)));
    }

    // OP | register
    pub fn emitCodeReg(self: *Self, location: Token, code: OpCode, register: Reg) !void {
        try self.emit(
            location,
            (@intCast(Instruction, @enumToInt(code)) << @bitSizeOf(FullArg)) | (@intCast(Instruction, register)),
        );
    }

    // OP_ | arg | register
    pub fn emitCodeArgReg(self: *Self, location: Token, code: OpCode, arg: Arg, register: Reg) !void {
        try self.emit(
            location,
            (@intCast(Instruction, @enumToInt(code)) << @bitSizeOf(FullArg)) |
                (@intCast(Instruction, arg) << @bitSizeOf(Reg)) |
                @intCast(Instruction, register),
        );
    }

    // OP_ | arg | register | register
    pub fn emitCodeArgRegs(self: *Self, location: Token, code: OpCode, arg: u9, register: Reg, dest_register: Reg) !void {
        try self.emit(
            location,
            (@intCast(Instruction, @enumToInt(code)) << @bitSizeOf(FullArg)) |
                (@intCast(Instruction, arg) << @bitSizeOf(Reg) * 2) |
                @intCast(Instruction, register) << @bitSizeOf(Reg) |
                @intCast(Instruction, dest_register),
        );
    }

    // OP_ | full_arg | register
    // register
    pub fn emitCodeFullArgRegs(self: *Self, location: Token, code: OpCode, arg: FullArg, register: Reg, dest_register: Reg) !void {
        try self.emitCodeRegReg(location, code, register, dest_register);
        try self.emit(location, arg);
    }

    // OP_ | a | b | register
    pub fn emitCodeArgsReg(self: *Self, location: Token, code: OpCode, a: u8, b: u9, register: Reg) !void {
        try self.emit(
            location,
            (@intCast(Instruction, @enumToInt(code)) << @bitSizeOf(FullArg)) |
                (@intCast(Instruction, a) << @bitSizeOf(Arg)) |
                (@intCast(Instruction, b) << @bitSizeOf(Reg)) |
                @intCast(Instruction, register),
        );
    }

    // OP_ | register | register
    pub fn emitCodeRegReg(self: *Self, location: Token, code: OpCode, register: Reg, dest: Reg) !void {
        try self.emit(
            location,
            (@intCast(Instruction, @enumToInt(code)) << @bitSizeOf(FullArg)) |
                (@intCast(Instruction, register) << @bitSizeOf(Reg)) |
                @intCast(Instruction, dest),
        );
    }

    // OP_ | register | register | register
    pub fn emitCodeRegs(self: *Self, location: Token, code: OpCode, reg1: Reg, reg2: Reg, dest: Reg) !void {
        try self.emit(
            location,
            (@intCast(Instruction, @enumToInt(code)) << @bitSizeOf(FullArg)) |
                (@intCast(Instruction, reg1) << @bitSizeOf(Reg) * 2) |
                (@intCast(Instruction, reg2) << @bitSizeOf(Reg)) |
                @intCast(Instruction, dest),
        );
    }

    pub fn emitLoop(self: *Self, location: Token, loop_start: usize) !void {
        const offset: usize = self.currentCode() - loop_start + 1;
        if (offset > std.math.maxInt(FullArg)) {
            try self.reportError("Loop body too large.");
        }

        try self.emitCodeArg(location, .OP_LOOP, @intCast(FullArg, offset));
    }

    pub fn emitJump(self: *Self, location: Token, instruction: OpCode, cond_register: ?Reg) !usize {
        if (cond_register) |cond| {
            try self.emitCodeArg(location, instruction, std.math.maxInt(FullArg));
            try self.emit(location, cond);

            return self.currentCode() - 2;
        } else {
            try self.emitCodeArg(location, instruction, std.math.maxInt(FullArg));

            return self.currentCode() - 1;
        }
    }

    pub fn patchJumpOrLoop(self: *Self, offset: usize, loop_start: ?usize) !void {
        const original = self.current.?.function.?.chunk.code.items[offset];
        const instruction: u8 = @intCast(u8, original >> 25);
        const code: OpCode = @intToEnum(OpCode, instruction);

        if (code == .OP_LOOP) { // Patching a continue statement
            assert(loop_start != null);
            const loop_offset: usize = offset - loop_start.? + 1;
            if (loop_offset > std.math.maxInt(FullArg)) {
                try self.reportError("Loop body too large.");
            }

            self.current.?.function.?.chunk.code.items[offset] =
                (@intCast(Instruction, instruction) << @bitSizeOf(FullArg)) | @intCast(Instruction, loop_offset);
        } else { // Patching a break statement
            try self.patchJump(offset, false);
        }
    }

    pub fn patchJump(self: *Self, offset: usize, conditional: bool) !void {
        assert(offset < self.currentCode());

        var delta: usize = 1;
        if (conditional) {
            delta = 2;
        }
        const jump: usize = self.currentCode() - offset - delta;

        if (jump > std.math.maxInt(FullArg)) {
            try self.reportError("Jump too large.");
        }

        const original = self.current.?.function.?.chunk.code.items[offset];
        const instruction = @intCast(Reg, original >> @bitSizeOf(FullArg));

        self.current.?.function.?.chunk.code.items[offset] =
            (@intCast(Instruction, instruction) << @bitSizeOf(FullArg)) | @intCast(Instruction, jump);
    }

    pub fn patchTry(self: *Self, offset: usize) !void {
        assert(offset < self.currentCode());

        const jump: usize = self.currentCode();

        if (jump > std.math.maxInt(FullArg)) {
            try self.reportError("Try block too large.");
        }

        const original = self.current.?.function.?.chunk.code.items[offset];
        const instruction: u8 = @intCast(u8, original >> @bitSizeOf(FullArg));

        self.current.?.function.?.chunk.code.items[offset] =
            (@intCast(Instruction, instruction) << @bitSizeOf(FullArg)) | @intCast(Instruction, jump);
    }

    pub fn emitReturn(self: *Self, location: Token) !void {
        try self.OP_NULL(location, self.pushRegister());
        try self.OP_RETURN(location, self.popRegister());
    }

    pub fn emitConstant(self: *Self, location: Token, value: Value) !void {
        try self.emitCodeArgReg(
            location,
            .OP_CONSTANT,
            try self.makeConstant(value),
            self.pushRegister(),
        );
    }

    pub fn makeConstant(self: *Self, value: Value) !Arg {
        var constant: Arg = try self.current.?.function.?.chunk.addConstant(null, value);
        if (constant > Chunk.max_constants) {
            try self.reportError("Too many constants in one chunk.");
            return 0;
        }

        return constant;
    }

    pub fn identifierConstant(self: *Self, name: []const u8) !Arg {
        return try self.makeConstant(
            Value.fromObj((try self.gc.copyString(name)).toObj()),
        );
    }

    fn report(self: *Self, location: Token, message: []const u8) !void {
        const lines: std.ArrayList([]const u8) = try location.getLines(self.gc.allocator, 3);
        defer lines.deinit();
        var report_line = std.ArrayList(u8).init(self.gc.allocator);
        defer report_line.deinit();
        var writer = report_line.writer();

        try writer.print("", .{});
        var l: usize = if (location.line > 0) location.line - 1 else 0;
        for (lines.items) |line| {
            if (l != location.line) {
                try writer.print("\u{001b}[2m", .{});
            }

            var prefix_len: usize = report_line.items.len;
            try writer.print(" {: >5} |", .{l + 1});
            prefix_len = report_line.items.len - prefix_len;
            try writer.print(" {s}\n\u{001b}[0m", .{line});

            if (l == location.line) {
                try writer.writeByteNTimes(' ', location.column + prefix_len);
                try writer.print("\u{001b}[31m^\u{001b}[0m\n", .{});
            }

            l += 1;
        }
        std.debug.print("{s}:{}:{}: \u{001b}[31mCompile error:\u{001b}[0m {s}\n{s}", .{
            location.script_name,
            location.line + 1,
            location.column + 1,
            message,
            report_line.items,
        });

        if (BuildOptions.stop_on_report) {
            unreachable;
        }
    }

    // Unlocated error, should not be used
    fn reportError(self: *Self, message: []const u8) !void {
        if (self.panic_mode) {
            return;
        }

        self.panic_mode = true;
        self.had_error = true;

        try self.report(
            Token{
                .token_type = .Error,
                .source = "",
                .script_name = "",
                .lexeme = "",
                .line = 0,
                .column = 0,
            },
            message,
        );
    }

    pub fn reportErrorAt(self: *Self, token: Token, message: []const u8) !void {
        if (self.panic_mode) {
            return;
        }

        self.panic_mode = true;
        self.had_error = true;

        try self.report(token, message);
    }

    pub fn reportErrorFmt(self: *Self, token: Token, comptime fmt: []const u8, args: anytype) !void {
        var message = std.ArrayList(u8).init(self.gc.allocator);
        defer message.deinit();

        var writer = message.writer();
        try writer.print(fmt, args);

        try self.reportErrorAt(token, message.items);
    }

    pub fn reportTypeCheckAt(self: *Self, expected_type: *ObjTypeDef, actual_type: *ObjTypeDef, message: []const u8, at: Token) !void {
        var error_message = std.ArrayList(u8).init(self.gc.allocator);
        var writer = &error_message.writer();

        try writer.print("{s}: expected type `", .{message});
        try expected_type.toString(writer);
        try writer.writeAll("`, got `");
        try actual_type.toString(writer);
        try writer.writeAll("`");

        try self.reportErrorAt(at, error_message.items);
    }

    // Got to the root placeholder and report it
    pub fn reportPlaceholder(self: *Self, placeholder: PlaceholderDef) anyerror!void {
        if (placeholder.parent) |parent| {
            if (parent.def_type == .Placeholder) {
                try self.reportPlaceholder(parent.resolved_type.?.Placeholder);
            }
        } else {
            // Should be a root placeholder with a name
            assert(placeholder.name != null);
            try self.reportErrorFmt(placeholder.where, "`{s}` is not defined", .{placeholder.name.?.string});
        }
    }

    // OP helpers to avoid emitting invalid instructions

    pub inline fn OP_CONSTANT(self: *Self, location: Token, constant: Arg, register: Reg) !void {
        try self.emitCodeArgReg(location, .OP_CONSTANT, @intCast(Arg, constant), register);
    }

    pub inline fn OP_GET_LOCAL(self: *Self, location: Token, slot: Arg, dest_register: Reg) !void {
        try self.emitCodeArgReg(location, .OP_GET_LOCAL, slot, dest_register);
    }

    pub inline fn OP_SET_LOCAL(self: *Self, location: Token, value_register: Reg, slot: Arg) !void {
        try self.emitCodeArgReg(location, .OP_SET_LOCAL, slot, value_register);
    }

    pub inline fn OP_GET_GLOBAL(self: *Self, location: Token, slot: Arg, dest_register: Reg) !void {
        try self.emitCodeArgReg(location, .OP_GET_GLOBAL, slot, dest_register);
    }

    pub inline fn OP_SET_GLOBAL(self: *Self, location: Token, value_register: Reg, slot: Arg) !void {
        try self.emitCodeArgReg(location, .OP_SET_GLOBAL, slot, value_register);
    }

    pub inline fn OP_GET_UPVALUE(self: *Self, location: Token, slot: FullArg, dest_register: Reg) !void {
        try self.emitCodeArgReg(location, .OP_GET_UPVALUE, slot, dest_register);
    }

    pub inline fn OP_SET_UPVALUE(self: *Self, location: Token, value_register: Reg, slot: Arg) !void {
        try self.emitCodeArgReg(location, .OP_SET_UPVALUE, slot, value_register);
    }

    pub inline fn OP_TRUE(self: *Self, location: Token, register: Reg) !void {
        try self.emitCodeReg(location, .OP_TRUE, register);
    }

    pub inline fn OP_FALSE(self: *Self, location: Token, register: Reg) !void {
        try self.emitCodeReg(location, .OP_FALSE, register);
    }

    pub inline fn OP_NULL(self: *Self, location: Token, register: Reg) !void {
        try self.emitCodeReg(location, .OP_NULL, register);
    }

    pub inline fn OP_VOID(self: *Self, location: Token, register: Reg) !void {
        try self.emitCodeReg(location, .OP_VOID, register);
    }

    pub inline fn OP_TO_STRING(self: *Self, location: Token, value_register: Reg, dest_register: Reg) !void {
        try self.emitCodeRegReg(location, .OP_TO_STRING, value_register, dest_register);
    }

    pub inline fn OP_ADD_STRING(self: *Self, location: Token, left_register: Reg, right_register: Reg, dest_register: Reg) !void {
        try self.emitCodeRegs(location, .OP_ADD_STRING, left_register, right_register, dest_register);
    }

    pub inline fn OP_LIST(self: *Self, location: Token, constant: Arg, dest_register: Reg) !void {
        try self.emitCodeArgReg(location, .OP_LIST, constant, dest_register);
    }

    pub inline fn OP_LIST_APPEND(self: *Self, location: Token, item_register: Reg, list_register: Reg) !void {
        try self.emitCodeRegReg(location, .OP_LIST_APPEND, item_register, list_register);
    }

    pub inline fn OP_MAP(self: *Self, location: Token, constant: Arg, dest_register: Reg) !void {
        try self.emitCodeArgReg(location, .OP_MAP, constant, dest_register);
    }

    pub inline fn OP_SET_MAP(self: *Self, location: Token, key_register: Reg, value_register: Reg, map_register: Reg) !void {
        try self.emitCodeRegs(location, .OP_SET_MAP, key_register, value_register, map_register);
    }

    pub inline fn OP_EQUAL(self: *Self, location: Token, left_register: Reg, right_register: Reg, dest_register: Reg) !void {
        try self.emitCodeRegs(location, .OP_EQUAL, left_register, right_register, dest_register);
    }

    pub inline fn OP_NOT(self: *Self, location: Token, value_register: Reg, dest_register: Reg) !void {
        try self.emitCodeRegReg(location, .OP_NOT, value_register, dest_register);
    }

    pub inline fn OP_NEGATE(self: *Self, location: Token, value_register: Reg, dest_register: Reg) !void {
        try self.emitCodeRegReg(location, .OP_NEGATE, value_register, dest_register);
    }

    pub inline fn OP_BNOT(self: *Self, location: Token, value_register: Reg, dest_register: Reg) !void {
        try self.emitCodeRegReg(location, .OP_BNOT, value_register, dest_register);
    }

    pub inline fn OP_UNWRAP(self: *Self, location: Token, value_register: Reg) !void {
        try self.emitCodeReg(location, .OP_UNWRAP, value_register);
    }

    pub inline fn OP_IS(self: *Self, location: Token, operand_register: Reg, constant_register: Reg, dest_register: Reg) !void {
        try self.emitCodeRegs(location, .OP_IS, operand_register, constant_register, dest_register);
    }

    pub inline fn OP_BAND(self: *Self, location: Token, left_register: Reg, right_register: Reg, dest_register: Reg) !void {
        try self.emitCodeRegs(location, .OP_BAND, left_register, right_register, dest_register);
    }

    pub inline fn OP_BOR(self: *Self, location: Token, left_register: Reg, right_register: Reg, dest_register: Reg) !void {
        try self.emitCodeRegs(location, .OP_BOR, left_register, right_register, dest_register);
    }

    pub inline fn OP_XOR(self: *Self, location: Token, left_register: Reg, right_register: Reg, dest_register: Reg) !void {
        try self.emitCodeRegs(location, .OP_XOR, left_register, right_register, dest_register);
    }

    pub inline fn OP_SHL(self: *Self, location: Token, left_register: Reg, right_register: Reg, dest_register: Reg) !void {
        try self.emitCodeRegs(location, .OP_SHL, left_register, right_register, dest_register);
    }

    pub inline fn OP_SHR(self: *Self, location: Token, left_register: Reg, right_register: Reg, dest_register: Reg) !void {
        try self.emitCodeRegs(location, .OP_SHR, left_register, right_register, dest_register);
    }

    pub inline fn OP_GREATER(self: *Self, location: Token, left_register: Reg, right_register: Reg, dest_register: Reg) !void {
        try self.emitCodeRegs(location, .OP_GREATER, left_register, right_register, dest_register);
    }

    pub inline fn OP_LESS(self: *Self, location: Token, left_register: Reg, right_register: Reg, dest_register: Reg) !void {
        try self.emitCodeRegs(location, .OP_LESS, left_register, right_register, dest_register);
    }

    pub inline fn OP_SUBTRACT(self: *Self, location: Token, left_register: Reg, right_register: Reg, dest_register: Reg) !void {
        try self.emitCodeRegs(location, .OP_SUBTRACT, left_register, right_register, dest_register);
    }

    pub inline fn OP_MULTIPLY(self: *Self, location: Token, left_register: Reg, right_register: Reg, dest_register: Reg) !void {
        try self.emitCodeRegs(location, .OP_MULTIPLY, left_register, right_register, dest_register);
    }

    pub inline fn OP_DIVIDE(self: *Self, location: Token, left_register: Reg, right_register: Reg, dest_register: Reg) !void {
        try self.emitCodeRegs(location, .OP_DIVIDE, left_register, right_register, dest_register);
    }

    pub inline fn OP_MOD(self: *Self, location: Token, left_register: Reg, right_register: Reg, dest_register: Reg) !void {
        try self.emitCodeRegs(location, .OP_MOD, left_register, right_register, dest_register);
    }

    pub inline fn OP_EXPORT(self: *Self, location: Token, exported_count: FullArg) !void {
        try self.emitCodeArg(location, .OP_EXPORT, exported_count);
    }

    pub inline fn OP_RETURN(self: *Self, location: Token, value_register: Reg) !void {
        try self.emitCodeReg(location, .OP_RETURN, value_register);
    }

    pub inline fn OP_PUSH(self: *Self, location: Token, value_register: Reg) !void {
        try self.emitCodeReg(location, .OP_PUSH, value_register);
    }

    pub inline fn OP_POP(self: *Self, location: Token, dest_register: Reg) !void {
        try self.emitCodeReg(location, .OP_POP, dest_register);
    }

    pub inline fn OP_PEEK(self: *Self, location: Token, distance: Arg, dest_register: Reg) !void {
        try self.emitCodeArgReg(location, .OP_PEEK, distance, dest_register);
    }

    pub inline fn OP_CLONE(self: *Self, location: Token, value_reg: Reg, dest: Reg) !void {
        try self.emitCodeRegReg(location, .OP_CLONE, value_reg, dest);
    }

    pub inline fn OP_CLOSURE(self: *Self, location: Token, constant: Arg, dest_register: Reg) !void {
        try self.emitCodeArgReg(location, .OP_CLOSURE, constant, dest_register);
    }

    pub inline fn OP_YIELD(self: *Self, location: Token, expr_register: Reg) !void {
        try self.emitCodeReg(location, .OP_YIELD, expr_register);
    }

    pub inline fn OP_RESOLVE(self: *Self, location: Token, fiber_register: Reg, dest_reg: Reg) !void {
        try self.emitCodeRegReg(location, .OP_RESOLVE, fiber_register, dest_reg);
    }

    pub inline fn OP_RESUME(self: *Self, location: Token, fiber_register: Reg, yield_register: Reg) !void {
        try self.emitCodeRegReg(location, .OP_RESUME, fiber_register, yield_register);
    }

    pub inline fn OP_GET_ENUM_CASE_FROM_VALUE(self: *Self, location: Token, enum_register: Reg, value_register: Reg, dest_register: Reg) !void {
        try self.emitCodeRegs(location, .OP_GET_ENUM_CASE_FROM_VALUE, enum_register, value_register, dest_register);
    }

    pub inline fn OP_ROUTINE(self: *Self, location: Token, call_arg_count: u8, catch_default: u8, dest_register: Reg) !void {
        try self.emitCodeArgsReg(location, .OP_ROUTINE, call_arg_count, catch_default, dest_register);
    }

    pub inline fn OP_INVOKE_ROUTINE(self: *Self, location: Token, identifier_constant: Arg) !void {
        try self.emitCodeArg(location, .OP_INVOKE_ROUTINE, @intCast(Arg, identifier_constant));
    }

    pub inline fn OP_CALL(self: *Self, location: Token, arg_count: u8, has_catch_default: bool, dest_register: Reg) !void {
        try self.emitCodeArgsReg(location, .OP_CALL, arg_count, if (has_catch_default) 1 else 0, dest_register);
    }

    pub inline fn OP_DEFINE_GLOBAL(self: *Self, location: Token, slot: Arg, value_register: Reg) !void {
        try self.emitCodeArgReg(location, .OP_DEFINE_GLOBAL, slot, value_register);
    }

    pub inline fn OP_ENUM(self: *Self, location: Token, constant: Arg, dest_register: Reg) !void {
        try self.emitCodeArgReg(location, .OP_ENUM, constant, dest_register);
    }

    pub inline fn OP_ENUM_CASE(self: *Self, location: Token, enum_register: Reg, value_register: Reg) !void {
        try self.emitCodeRegReg(location, .OP_ENUM_CASE, enum_register, value_register);
    }

    pub inline fn OP_GET_ENUM_CASE(self: *Self, location: Token, index: u9, enum_register: Reg, dest_register: Reg) !void {
        try self.emitCodeArgRegs(location, .OP_GET_ENUM_CASE, index, enum_register, dest_register);
    }

    pub inline fn OP_GET_ENUM_CASE_VALUE(self: *Self, location: Token, enum_instance_register: Reg, dest_register: Reg) !void {
        try self.emitCodeRegReg(location, .OP_GET_ENUM_CASE_VALUE, enum_instance_register, dest_register);
    }

    pub inline fn OP_THROW(self: *Self, location: Token, error_register: Reg) !void {
        try self.emitCodeReg(location, .OP_THROW, error_register);
    }

    pub inline fn OP_INSTANCE(self: *Self, location: Token, object_register: Reg, dest_register: Reg) !void {
        try self.emitCodeRegReg(location, .OP_INSTANCE, object_register, dest_register);
    }

    pub inline fn OP_SET_INSTANCE_PROPERTY(self: *Self, location: Token, instance_register: Reg, field_constant: Arg, value_register: Reg) !void {
        try self.emitCodeFullArgRegs(location, .OP_SET_INSTANCE_PROPERTY, field_constant, instance_register, value_register);
    }

    pub inline fn OP_OBJECT(self: *Self, location: Token, name_constant: Arg, type_constant: Arg, dest_register: Reg) !void {
        try self.emitCodeArgReg(location, .OP_OBJECT, name_constant, dest_register);
        try self.emit(location, @intCast(Instruction, type_constant));
    }

    pub inline fn OP_PROPERTY(self: *Self, location: Token, object_register: Reg, member_name_constant: Arg, value_register: Reg) !void {
        try self.emitCodeArgReg(location, .OP_PROPERTY, member_name_constant, object_register);
        try self.emit(location, @intCast(Instruction, value_register));
    }

    pub inline fn OP_METHOD(self: *Self, location: Token, object_register: Reg, member_name_constant: Arg, value_register: Reg) !void {
        try self.emitCodeArgReg(location, .OP_METHOD, member_name_constant, object_register);
        try self.emit(location, @intCast(Instruction, value_register));
    }

    pub inline fn OP_SET_OBJECT_PROPERTY(self: *Self, location: Token, object_register: Reg, member_name_constant: Arg, value_register: Reg) !void {
        try self.emitCodeFullArgRegs(location, .OP_SET_OBJECT_PROPERTY, member_name_constant, object_register, value_register);
    }

    pub inline fn OP_IMPORT(self: *Self, location: Token, path_constant: Arg, function_register: Reg) !void {
        try self.emitCodeArgReg(location, .OP_IMPORT, path_constant, function_register);
    }
};
