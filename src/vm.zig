const std = @import("std");
const builtin = @import("builtin");
const assert = std.debug.assert;
const _value = @import("./value.zig");
const _chunk = @import("./chunk.zig");
const _disassembler = @import("./disassembler.zig");
const _obj = @import("./obj.zig");
const _node = @import("./node.zig");
const Allocator = std.mem.Allocator;
const BuildOptions = @import("build_options");
const _memory = @import("./memory.zig");
const GarbageCollector = _memory.GarbageCollector;
const TypeRegistry = _memory.TypeRegistry;
const MIRJIT = @import("mirjit.zig");

const Value = _value.Value;
const floatToInteger = _value.floatToInteger;
const valueToString = _value.valueToString;
const valueToStringAlloc = _value.valueToStringAlloc;
const valueEql = _value.valueEql;
const valueIs = _value.valueIs;
const ObjType = _obj.ObjType;
const Obj = _obj.Obj;
const ObjNative = _obj.ObjNative;
const NativeFn = _obj.NativeFn;
const Native = _obj.Native;
const NativeCtx = _obj.NativeCtx;
const ObjString = _obj.ObjString;
const ObjUpValue = _obj.ObjUpValue;
const ObjClosure = _obj.ObjClosure;
const ObjFunction = _obj.ObjFunction;
const ObjObjectInstance = _obj.ObjObjectInstance;
const ObjObject = _obj.ObjObject;
const ObjectDef = _obj.ObjectDef;
const ObjList = _obj.ObjList;
const ObjMap = _obj.ObjMap;
const ObjEnum = _obj.ObjEnum;
const ObjFiber = _obj.ObjFiber;
const ObjEnumInstance = _obj.ObjEnumInstance;
const ObjBoundMethod = _obj.ObjBoundMethod;
const ObjTypeDef = _obj.ObjTypeDef;
const ObjPattern = _obj.ObjPattern;
const FunctionNode = _node.FunctionNode;
const cloneObject = _obj.cloneObject;
const OpCode = _chunk.OpCode;
const Chunk = _chunk.Chunk;
const Arg = _chunk.Arg;
const FullArg = _chunk.FullArg;
const Reg = _chunk.Reg;
const Code = _chunk.Code;
const Instruction = _chunk.Instruction;
const disassembleChunk = _disassembler.disassembleChunk;
const dumpStack = _disassembler.dumpStack;
const dumpRegisters = _disassembler.dumpRegisters;
const jmp = @import("jmp.zig").jmp;

pub const ImportRegistry = std.AutoHashMap(*ObjString, std.ArrayList(Value));

pub const CallFrame = struct {
    const Self = @This();

    closure: *ObjClosure,
    // Index into closure's chunk
    ip: usize,
    // Frame
    slots: [*]Value,

    // Default value in case of error
    error_value: ?Value = null,

    // Line in source code where the call occured
    call_site: ?usize,

    // Offset at which error can be handled (means we're in a try block)
    try_ip: ?usize = null,
    // Top when try block started
    try_top: ?[*]Value = null,

    // True if a native function is being called, we need this because a native function can also
    // call buzz code and we need to know how to stop interpreting once we get back to native code
    in_native_call: bool = false,

    // In which register to put the function result
    result_register: ?Reg,

    registers: [255]Value,
};

pub const TryCtx = extern struct {
    previous: ?*TryCtx,
    env: jmp.jmp_buf = undefined,
    // FIXME: remember top here
};

pub const Fiber = struct {
    const Self = @This();

    pub const Status = enum {
        // Just created, never started
        Instanciated,
        // Currently running
        Running,
        // Yielded an expected value
        Yielded,
        // Reached return statement
        Over,
    };

    allocator: Allocator,

    parent_fiber: ?*Fiber,

    call_type: OpCode,
    arg_count: u8,
    has_catch_value: bool,
    method: ?*ObjString,

    frames: std.ArrayList(CallFrame),
    frame_count: u64 = 0,

    stack: []Value,
    stack_top: [*]Value,
    open_upvalues: ?*ObjUpValue,

    status: Status = .Instanciated,
    // true: we did `resolve fiber`, false: we did `resume fiber`
    resolved: bool = false,

    // When the fiber finishes within a resume and not a resolve, we need to remember the result because the frame is popped
    resolved_value: ?Value = null,

    // When within a try catch in a JIT compiled function
    try_context: ?*TryCtx = null,

    // In which register a yield value from another fiber must be put
    yield_register: ?Reg = null,
    // In which register a resolved value from another fiber must be put
    resolve_register: ?Reg = null,

    pub fn init(
        allocator: Allocator,
        parent_fiber: ?*Fiber,
        stack_slice: ?[]Value,
        call_type: OpCode,
        arg_count: u8,
        has_catch_value: bool,
        method: ?*ObjString,
    ) !Self {
        var self: Self = .{
            .allocator = allocator,
            .parent_fiber = parent_fiber,
            .stack = try allocator.alloc(Value, 100000),
            .stack_top = undefined,
            .frames = std.ArrayList(CallFrame).init(allocator),
            .open_upvalues = null,
            .call_type = call_type,
            .arg_count = arg_count,
            .has_catch_value = has_catch_value,
            .method = method,
        };

        if (stack_slice != null) {
            std.mem.copy(Value, self.stack, stack_slice.?);

            self.stack_top = @ptrCast([*]Value, self.stack[stack_slice.?.len..]);
        } else {
            self.stack_top = @ptrCast([*]Value, self.stack[0..]);
        }

        return self;
    }

    pub fn deinit(self: *Self) void {
        self.allocator.free(self.stack);

        self.frames.deinit();
    }

    pub fn start(self: *Self, vm: *VM, yield_reg: ?Reg, resolve_reg: ?Reg) !void {
        assert(self.status == .Instanciated);

        vm.current_fiber = self;
        vm.current_fiber.yield_register = yield_reg;
        vm.current_fiber.resolve_register = resolve_reg;

        switch (self.call_type) {
            .OP_ROUTINE => { // | closure | ...args | ?catch |
                try vm.callValue(
                    vm.peek(self.arg_count),
                    self.arg_count,
                    if (self.has_catch_value) vm.pop() else null,
                    true,
                    resolve_reg,
                );
            },
            .OP_INVOKE_ROUTINE => { // | receiver | ...args | ?catch |
                try vm.invoke(
                    self.method.?,
                    self.arg_count,
                    if (self.has_catch_value) vm.pop() else null,
                    true,
                    resolve_reg,
                );
            },
            else => unreachable,
        }

        self.status = .Running;
    }

    pub fn yield(self: *Self, vm: *VM, yielded_value: Value) void {
        assert(self.status == .Running);

        // If resolved or not run in a fiber, dismiss yielded value and keep running
        if (self.resolved or self.parent_fiber == null) {
            return;
        }

        // Was resumed, so push the yielded value on the parent fiber and give control back to parent fiber
        vm.current_fiber = self.parent_fiber.?;

        if (self.parent_fiber) |parent_fiber| {
            if (self.yield_register) |yield_register| {
                parent_fiber.currentFrame().?.registers[yield_register] = yielded_value;
                parent_fiber.yield_register = null;
            }
        }

        self.status = .Yielded;

        // Do we need to finish OP_CODE that triggered the yield?
        const full_instruction = vm.readPreviousInstruction();
        if (full_instruction) |ufull_instruction| {
            const instruction = VM.getCode(ufull_instruction);
            switch (instruction) {
                .OP_FIBER_FOREACH => {
                    _ = vm.pop();

                    var value_slot: *Value = @ptrCast(*Value, vm.current_fiber.stack_top - 2);

                    value_slot.* = yielded_value;
                },
                else => {},
            }
        }
    }

    pub fn resume_(self: *Self, vm: *VM, yield_reg: ?Reg, resolve_reg: ?Reg) !void {
        switch (self.status) {
            .Instanciated => {
                // No yet started, do so
                try self.start(vm, yield_reg, resolve_reg);
            },
            .Yielded => {
                // Give control to fiber
                self.resolve_register = resolve_reg;
                self.yield_register = yield_reg;
                self.parent_fiber = vm.current_fiber;
                vm.current_fiber = self;

                self.status = .Running;
            },
            .Over => {
                // User should check fiber.over() before doing `resume`
                try vm.throw(VM.Error.FiberOver, (try vm.gc.copyString("Fiber is over")).toValue());
            },
            .Running => unreachable,
        }
    }

    pub fn resolve_(self: *Self, vm: *VM, dest_reg: Reg) !void {
        self.resolved = true;

        switch (self.status) {
            .Instanciated => try self.start(vm, null, dest_reg),
            .Yielded => try self.resume_(vm, null, dest_reg),
            .Over => {
                // Already over, just take the result value
                const parent_fiber = vm.current_fiber;
                vm.current_fiber = self;

                const result = self.resolved_value orelse Value.Void;

                vm.current_fiber = parent_fiber;
                vm.currentFrame().?.registers[dest_reg] = result;
                self.resolve_register = null;

                // FIXME: but this means we can do several `resolve fiber`
            },
            .Running => unreachable,
        }
    }

    pub fn finish(self: *Self, vm: *VM, result: Value) !void {
        // Fiber is now over
        self.status = .Over;
        const resolved = self.resolved;

        self.resolved_value = result;

        // Go back to parent fiber
        vm.current_fiber = self.parent_fiber.?;

        if (self.resolve_register) |resolve_register| {
            vm.currentFrame().?.registers[resolve_register] = if (resolved)
                result // We did `resolve fiber` we want the returned value
            else
                Value.Null; // We did `resume fiber` and hit return, we don't yet care about that value
        } // else we discard the result

        // If the fiber finishes because of a `resume`, we put null in the yield register
        if (self.yield_register) |yield_register| {
            vm.currentFrame().?.registers[yield_register] = Value.Null;
        }

        // Do we need to finish OP_CODE that triggered the yield?
        const full_instruction = vm.readPreviousInstruction();
        if (full_instruction) |ufull_instruction| {
            const instruction = VM.getCode(ufull_instruction);
            switch (instruction) {
                .OP_FIBER_FOREACH => {
                    // We don't care about the returned value
                    _ = vm.pop();

                    var value_slot: *Value = @ptrCast(*Value, vm.current_fiber.stack_top - 2);

                    value_slot.* = Value.Null;
                },
                else => {},
            }
        }
    }

    pub inline fn currentFrame(self: *Self) ?*CallFrame {
        if (self.frame_count == 0) {
            return null;
        }

        return &self.frames.items[self.frame_count - 1];
    }
};

pub const VM = struct {
    const Self = @This();

    pub const Error = error{
        UnwrappedNull,
        OutOfBound,
        NumberOverflow,
        NotInFiber,
        FiberOver,
        BadNumber,
        Custom, // TODO: remove when user can use this set directly in buzz code
    } || Allocator.Error || std.fmt.BufPrintError;

    gc: *GarbageCollector,
    current_fiber: *Fiber,
    globals: std.ArrayList(Value),
    import_registry: *ImportRegistry,
    mir_jit: ?MIRJIT = null,
    testing: bool,

    pub fn init(gc: *GarbageCollector, import_registry: *ImportRegistry, testing: bool) !Self {
        var self: Self = .{
            .gc = gc,
            .import_registry = import_registry,
            .globals = std.ArrayList(Value).init(gc.allocator),
            .current_fiber = try gc.allocator.create(Fiber),
            .testing = testing,
        };

        return self;
    }

    pub fn deinit(self: *Self) void {
        // TODO: we can't free this because exported closure refer to it
        // self.globals.deinit();
        if (BuildOptions.jit) {
            self.mir_jit.?.deinit();
            self.mir_jit = null;
        }
    }

    pub fn initJIT(self: *Self) !void {
        self.mir_jit = MIRJIT.init(self);
    }

    pub fn cliArgs(self: *Self, args: ?[][:0]u8) !*ObjList {
        var list_def: ObjList.ListDef = ObjList.ListDef.init(
            self.gc.allocator,
            try self.gc.allocateObject(
                ObjTypeDef,
                ObjTypeDef{ .def_type = .String },
            ),
        );

        var list_def_union: ObjTypeDef.TypeUnion = .{
            .List = list_def,
        };

        var list_def_type: *ObjTypeDef = try self.gc.allocateObject(
            ObjTypeDef,
            ObjTypeDef{
                .def_type = .List,
                .optional = false,
                .resolved_type = list_def_union,
            },
        );

        var arg_list = try self.gc.allocateObject(
            ObjList,
            ObjList.init(
                self.gc.allocator,
                // TODO: get instance that already exists
                list_def_type,
            ),
        );

        // Prevent gc
        self.push(arg_list.toValue());

        if (args) |uargs| {
            for (uargs, 0..) |arg, index| {
                // We can't have more than 255 arguments to a function
                // TODO: should we silently ignore them or should we raise an error?
                if (index >= 255) {
                    break;
                }

                try arg_list.items.append(
                    Value.fromObj((try self.gc.copyString(std.mem.sliceTo(arg, 0))).toObj()),
                );
            }
        }

        _ = self.pop();

        return arg_list;
    }

    pub fn push(self: *Self, value: Value) void {
        // FIXME: check overflow, can't we do it at compile time?

        self.current_fiber.stack_top[0] = value;
        self.current_fiber.stack_top += 1;
    }

    pub fn pop(self: *Self) Value {
        self.current_fiber.stack_top -= 1;
        return self.current_fiber.stack_top[0];
    }

    pub fn peek(self: *Self, distance: u32) Value {
        return (self.current_fiber.stack_top - 1 - distance)[0];
    }

    pub fn copy(self: *Self, n: u24) void {
        if (n == 0) {
            self.push(self.peek(0));
            return;
        }

        var i = n - 1;
        while (i >= 0) : (i -= 1) {
            self.push(self.peek(i));

            if (i == 0) {
                break;
            }
        }
    }

    pub inline fn cloneValue(self: *Self, value: Value) !Value {
        return if (value.isObj()) try cloneObject(value.obj(), self) else value;
    }

    inline fn clone(self: *Self) !void {
        self.push(try self.cloneValue(self.pop()));
    }

    inline fn swap(self: *Self, from: u8, to: u8) void {
        var temp: Value = (self.current_fiber.stack_top - to - 1)[0];
        (self.current_fiber.stack_top - to - 1)[0] = (self.current_fiber.stack_top - from - 1)[0];
        (self.current_fiber.stack_top - from - 1)[0] = temp;
    }

    pub inline fn currentFrame(self: *Self) ?*CallFrame {
        if (self.current_fiber.frame_count == 0) {
            return null;
        }

        return &self.current_fiber.frames.items[self.current_fiber.frame_count - 1];
    }

    pub inline fn currentGlobals(self: *Self) *std.ArrayList(Value) {
        return self.currentFrame().?.closure.globals;
    }

    pub fn interpret(self: *Self, function: *ObjFunction, args: ?[][:0]u8) MIRJIT.Error!void {
        self.current_fiber.* = try Fiber.init(
            self.gc.allocator,
            null, // parent fiber
            null, // stack_slice
            .OP_CALL, // call_type
            1, // arg_count
            false, // catch_count
            null, // method/member
        );

        self.push((try self.gc.allocateObject(
            ObjClosure,
            try ObjClosure.init(self.gc.allocator, self, function),
        )).toValue());

        self.push((try self.cliArgs(args)).toValue());

        try self.gc.registerVM(self);
        defer self.gc.unregisterVM(self);

        try self.callValue(
            self.peek(1),
            0,
            null,
            false,
            null,
        );

        self.current_fiber.status = .Running;

        return self.run();
    }

    fn readPreviousInstruction(self: *Self) ?u32 {
        const current_frame: *CallFrame = self.currentFrame().?;

        if (current_frame.ip > 0) {
            return current_frame.closure.function.chunk.code.items[current_frame.ip - 1];
        }

        return null;
    }

    inline fn readInstruction(self: *Self) u32 {
        const current_frame: *CallFrame = self.currentFrame().?;
        var instruction: u32 = current_frame.closure.function.chunk.code.items[current_frame.ip];

        current_frame.ip += 1;

        return instruction;
    }

    pub inline fn getCode(instruction: Instruction) OpCode {
        return @intToEnum(OpCode, @intCast(_chunk.Code, instruction >> @bitSizeOf(FullArg)));
    }

    inline fn getArg(instruction: Instruction) FullArg {
        return @intCast(FullArg, 0x01ffffff & instruction);
    }

    inline fn readByte(self: *Self) u8 {
        return @intCast(u8, self.readInstruction());
    }

    inline fn readConstant(self: *Self, arg: FullArg) Value {
        return self.currentFrame().?.closure.function.chunk.constants.items[arg];
    }

    inline fn readString(self: *Self, arg: FullArg) *ObjString {
        return ObjString.cast(self.readConstant(arg).obj()).?;
    }

    inline fn getCodeReg(instruction: Instruction) struct { code: OpCode, reg: Reg } {
        return .{
            .code = getCode(instruction),
            .reg = @intCast(Reg, getArg(instruction)),
        };
    }

    inline fn getCodeArgReg(instruction: Instruction) struct { code: OpCode, arg: Arg, reg: Reg } {
        return .{
            .code = getCode(instruction),
            .arg = @intCast(Arg, (0x01ffffff & instruction) >> @bitSizeOf(Reg)),
            .reg = @intCast(Reg, 0x000000ff & instruction),
        };
    }

    inline fn getCodeArgRegs(instruction: Instruction) struct { code: OpCode, arg: u9, reg: Reg, dest_reg: Reg } {
        return .{
            .code = getCode(instruction),
            .arg = @intCast(Reg, (0x01ff0000 & instruction) >> (@bitSizeOf(Reg) * 2)),
            .reg = @intCast(Reg, (0x0000ff00 & instruction) >> @bitSizeOf(Reg)),
            .dest_reg = @intCast(Reg, 0x000000ff & instruction),
        };
    }

    inline fn getCodeArgsReg(instruction: Instruction) struct { code: OpCode, a: u8, b: u9, reg: Reg } {
        return .{
            .code = getCode(instruction),
            .a = @intCast(u8, (0x01ff0000 & instruction) >> (@bitSizeOf(u9) + @bitSizeOf(Reg))),
            .b = @intCast(u9, (0x0000ff00 & instruction) >> @bitSizeOf(Reg)),
            .reg = @intCast(Reg, 0x000000ff & instruction),
        };
    }

    inline fn getCodeRegReg(instruction: Instruction) struct { code: OpCode, reg: Reg, dest_reg: Reg } {
        return .{
            .code = getCode(instruction),
            .reg = @truncate(Reg, (0x01ffffff & instruction) >> @bitSizeOf(Reg)),
            .dest_reg = @intCast(Reg, 0x000000ff & instruction),
        };
    }

    inline fn getCodeRegs(instruction: Instruction) struct { code: OpCode, reg1: Reg, reg2: Reg, reg3: Reg } {
        return .{
            .code = getCode(instruction),
            .reg1 = @intCast(Reg, (0x01ff0000 & instruction) >> (@bitSizeOf(Reg) * 2)),
            .reg2 = @intCast(Reg, (0x0000ff00 & instruction) >> @bitSizeOf(Reg)),
            .reg3 = @intCast(Reg, 0x000000ff & instruction),
        };
    }

    const OpFn = *const fn (*Self, *CallFrame, Instruction, OpCode, FullArg) void;

    // WARNING: same order as OpCode enum
    const op_table = [_]OpFn{
        OP_CONSTANT,
        OP_NULL,
        OP_VOID,
        OP_TRUE,
        OP_FALSE,
        OP_POP,
        OP_PUSH,
        OP_PEEK,
        OP_CLONE,

        OP_DEFINE_GLOBAL,
        OP_GET_GLOBAL,
        OP_SET_GLOBAL,
        OP_GET_LOCAL,
        OP_SET_LOCAL,
        OP_GET_UPVALUE,
        OP_SET_UPVALUE,
        OP_GET_LIST_SUBSCRIPT,
        OP_GET_MAP_SUBSCRIPT,
        OP_GET_STRING_SUBSCRIPT,
        OP_SET_LIST_SUBSCRIPT,
        OP_SET_MAP_SUBSCRIPT,

        OP_EQUAL,
        OP_IS,
        OP_GREATER,
        OP_LESS,
        OP_ADD,
        OP_ADD_STRING,
        OP_ADD_LIST,
        OP_ADD_MAP,
        OP_SUBTRACT,
        OP_MULTIPLY,
        OP_DIVIDE,
        OP_MOD,
        OP_BNOT,
        OP_BAND,
        OP_BOR,
        OP_XOR,
        OP_SHL,
        OP_SHR,

        OP_UNWRAP,

        OP_NOT,
        OP_NEGATE,

        OP_JUMP,
        OP_JUMP_IF_FALSE,
        OP_JUMP_IF_NOT_NULL,
        OP_LOOP,
        OP_STRING_FOREACH,
        OP_LIST_FOREACH,
        OP_ENUM_FOREACH,
        OP_MAP_FOREACH,
        OP_FIBER_FOREACH,

        OP_CALL,
        OP_INSTANCE_INVOKE,
        OP_STRING_INVOKE,
        OP_PATTERN_INVOKE,
        OP_FIBER_INVOKE,
        OP_LIST_INVOKE,
        OP_MAP_INVOKE,

        OP_CLOSURE,
        OP_CLOSE_UPVALUE,

        OP_ROUTINE,
        OP_INVOKE_ROUTINE,
        OP_RESUME,
        OP_RESOLVE,
        OP_YIELD,

        OP_TRY,
        OP_TRY_END,
        OP_THROW,

        OP_RETURN,

        OP_OBJECT,
        OP_INSTANCE,
        OP_METHOD,
        OP_PROPERTY,
        OP_GET_OBJECT_PROPERTY,
        OP_GET_INSTANCE_PROPERTY,
        OP_GET_LIST_PROPERTY,
        OP_GET_MAP_PROPERTY,
        OP_GET_STRING_PROPERTY,
        OP_GET_PATTERN_PROPERTY,
        OP_GET_FIBER_PROPERTY,
        OP_SET_OBJECT_PROPERTY,
        OP_SET_INSTANCE_PROPERTY,

        OP_ENUM,
        OP_ENUM_CASE,
        OP_GET_ENUM_CASE,
        OP_GET_ENUM_CASE_VALUE,
        OP_GET_ENUM_CASE_FROM_VALUE,

        OP_LIST,
        OP_LIST_APPEND,

        OP_MAP,
        OP_SET_MAP,

        OP_EXPORT,
        OP_IMPORT,

        OP_TO_STRING,
    };

    fn dispatch(self: *Self, current_frame: *CallFrame, full_instruction: Instruction, instruction: OpCode, arg: FullArg) void {
        if (BuildOptions.debug_current_instruction or BuildOptions.debug_stack) {
            std.debug.print(
                "{}: {} {x}\n",
                .{
                    current_frame.ip,
                    instruction,
                    full_instruction,
                },
            );
            dumpStack(self);
            dumpRegisters(self);
        }

        // We're at the start of catch clauses because an error was thrown
        // We must close the try block scope
        if (current_frame.try_ip == current_frame.ip - 1) {
            assert(current_frame.try_top != null);
            const err = self.pop();

            // Close scope
            self.closeUpValues(@ptrCast(*Value, current_frame.try_top.?));
            self.current_fiber.stack_top = current_frame.try_top.?;

            // Put error back on stack
            self.push(err);

            // As soon as we step into catch clauses, we're not in a try-catch block anymore
            current_frame.try_ip = null;
            current_frame.try_top = null;
        }

        // Tail call
        @call(
            .always_tail,
            op_table[@enumToInt(instruction)],
            .{
                self,
                current_frame,
                full_instruction,
                instruction,
                arg,
            },
        );
    }

    fn OP_PUSH(self: *Self, frame: *CallFrame, _: Instruction, _: OpCode, reg: FullArg) void {
        self.push(frame.registers[reg]);

        const next_full_instruction = self.readInstruction();
        @call(
            .always_tail,
            dispatch,
            .{
                self,
                self.currentFrame().?,
                next_full_instruction,
                getCode(next_full_instruction),
                getArg(next_full_instruction),
            },
        );
    }

    fn OP_NULL(self: *Self, frame: *CallFrame, _: Instruction, _: OpCode, reg: FullArg) void {
        frame.registers[reg] = Value.Null;

        const next_full_instruction = self.readInstruction();
        @call(
            .always_tail,
            dispatch,
            .{
                self,
                self.currentFrame().?,
                next_full_instruction,
                getCode(next_full_instruction),
                getArg(next_full_instruction),
            },
        );
    }

    fn OP_VOID(self: *Self, frame: *CallFrame, _: Instruction, _: OpCode, reg: FullArg) void {
        frame.registers[reg] = Value.Void;

        const next_full_instruction = self.readInstruction();
        @call(
            .always_tail,
            dispatch,
            .{
                self,
                self.currentFrame().?,
                next_full_instruction,
                getCode(next_full_instruction),
                getArg(next_full_instruction),
            },
        );
    }

    fn OP_TRUE(self: *Self, frame: *CallFrame, _: Instruction, _: OpCode, reg: FullArg) void {
        frame.registers[reg] = Value.True;

        const next_full_instruction = self.readInstruction();
        @call(
            .always_tail,
            dispatch,
            .{
                self,
                self.currentFrame().?,
                next_full_instruction,
                getCode(next_full_instruction),
                getArg(next_full_instruction),
            },
        );
    }

    fn OP_FALSE(self: *Self, frame: *CallFrame, _: Instruction, _: OpCode, reg: FullArg) void {
        frame.registers[reg] = Value.False;

        const next_full_instruction = self.readInstruction();
        @call(
            .always_tail,
            dispatch,
            .{
                self,
                self.currentFrame().?,
                next_full_instruction,
                getCode(next_full_instruction),
                getArg(next_full_instruction),
            },
        );
    }

    fn OP_POP(self: *Self, frame: *CallFrame, _: Instruction, _: OpCode, reg: FullArg) void {
        frame.registers[reg] = self.pop();

        const next_full_instruction: Instruction = self.readInstruction();
        @call(
            .always_tail,
            dispatch,
            .{
                self,
                self.currentFrame().?,
                next_full_instruction,
                getCode(next_full_instruction),
                getArg(next_full_instruction),
            },
        );
    }

    fn OP_PEEK(self: *Self, frame: *CallFrame, instruction: Instruction, _: OpCode, _: FullArg) void {
        const args = getCodeArgReg(instruction);
        const dist = args.arg;
        const reg = args.reg;

        frame.registers[reg] = self.peek(dist);

        const next_full_instruction: Instruction = self.readInstruction();
        @call(
            .always_tail,
            dispatch,
            .{
                self,
                self.currentFrame().?,
                next_full_instruction,
                getCode(next_full_instruction),
                getArg(next_full_instruction),
            },
        );
    }

    fn OP_CLONE(self: *Self, frame: *CallFrame, instruction: Instruction, _: OpCode, _: FullArg) void {
        const args = getCodeRegReg(instruction);
        const val_reg = args.reg;
        const dest = args.dest_reg;

        frame.registers[dest] = self.cloneValue(frame.registers[val_reg]) catch @panic("Could not clone value");

        const next_full_instruction: Instruction = self.readInstruction();
        @call(
            .always_tail,
            dispatch,
            .{
                self,
                self.currentFrame().?,
                next_full_instruction,
                getCode(next_full_instruction),
                getArg(next_full_instruction),
            },
        );
    }

    fn OP_DEFINE_GLOBAL(self: *Self, frame: *CallFrame, instruction: Instruction, _: OpCode, _: FullArg) void {
        const args = getCodeArgReg(instruction);
        const slot = args.arg;
        const reg = args.reg;

        self.globals.ensureTotalCapacity(slot + 1) catch @panic("Could not create new global");
        self.globals.expandToCapacity();
        self.globals.items[slot] = frame.registers[reg];

        const next_full_instruction = self.readInstruction();
        @call(
            .always_tail,
            dispatch,
            .{
                self,
                self.currentFrame().?,
                next_full_instruction,
                getCode(next_full_instruction),
                getArg(next_full_instruction),
            },
        );
    }

    fn OP_GET_GLOBAL(self: *Self, frame: *CallFrame, instruction: Instruction, _: OpCode, _: FullArg) void {
        const args = getCodeArgReg(instruction);
        const slot = args.arg;
        const reg = args.reg;

        frame.registers[reg] = self.currentGlobals().items[slot];

        const next_full_instruction = self.readInstruction();
        @call(
            .always_tail,
            dispatch,
            .{
                self,
                self.currentFrame().?,
                next_full_instruction,
                getCode(next_full_instruction),
                getArg(next_full_instruction),
            },
        );
    }

    fn OP_SET_GLOBAL(self: *Self, frame: *CallFrame, instruction: Instruction, _: OpCode, _: FullArg) void {
        const args = getCodeArgReg(instruction);
        const slot = args.arg;
        const reg = args.reg;

        self.currentGlobals().items[slot] = frame.registers[reg];

        const next_full_instruction = self.readInstruction();
        @call(
            .always_tail,
            dispatch,
            .{
                self,
                self.currentFrame().?,
                next_full_instruction,
                getCode(next_full_instruction),
                getArg(next_full_instruction),
            },
        );
    }

    fn OP_GET_LOCAL(self: *Self, frame: *CallFrame, instruction: Instruction, _: OpCode, _: FullArg) void {
        const args = getCodeArgReg(instruction);
        const slot = args.arg;
        const reg = args.reg;

        frame.registers[reg] = frame.slots[slot];

        const next_full_instruction = self.readInstruction();
        @call(
            .always_tail,
            dispatch,
            .{
                self,
                self.currentFrame().?,
                next_full_instruction,
                getCode(next_full_instruction),
                getArg(next_full_instruction),
            },
        );
    }

    fn OP_SET_LOCAL(self: *Self, frame: *CallFrame, instruction: Instruction, _: OpCode, _: FullArg) void {
        const args = getCodeArgReg(instruction);
        const slot = args.arg;
        const reg = args.reg;

        frame.slots[slot] = frame.registers[reg];

        const next_full_instruction = self.readInstruction();
        @call(
            .always_tail,
            dispatch,
            .{
                self,
                self.currentFrame().?,
                next_full_instruction,
                getCode(next_full_instruction),
                getArg(next_full_instruction),
            },
        );
    }

    fn OP_GET_UPVALUE(self: *Self, frame: *CallFrame, instruction: Instruction, _: OpCode, _: FullArg) void {
        const args = getCodeArgReg(instruction);
        const slot = args.arg;
        const reg = args.reg;

        frame.registers[reg] = frame.closure.upvalues.items[slot].location.*;

        const next_full_instruction = self.readInstruction();
        @call(
            .always_tail,
            dispatch,
            .{
                self,
                self.currentFrame().?,
                next_full_instruction,
                getCode(next_full_instruction),
                getArg(next_full_instruction),
            },
        );
    }

    fn OP_SET_UPVALUE(self: *Self, frame: *CallFrame, instruction: Instruction, _: OpCode, _: FullArg) void {
        const args = getCodeArgReg(instruction);
        const slot = args.arg;
        const reg = args.reg;

        frame.closure.upvalues.items[slot].location.* = frame.registers[reg];

        const next_full_instruction = self.readInstruction();
        @call(
            .always_tail,
            dispatch,
            .{
                self,
                self.currentFrame().?,
                next_full_instruction,
                getCode(next_full_instruction),
                getArg(next_full_instruction),
            },
        );
    }

    fn OP_CONSTANT(self: *Self, frame: *CallFrame, instruction: Instruction, _: OpCode, _: FullArg) void {
        const args = getCodeArgReg(instruction);
        const constant = args.arg;
        const reg = args.reg;

        frame.registers[reg] = self.readConstant(constant);

        const next_full_instruction = self.readInstruction();
        @call(
            .always_tail,
            dispatch,
            .{
                self,
                self.currentFrame().?,
                next_full_instruction,
                getCode(next_full_instruction),
                getArg(next_full_instruction),
            },
        );
    }

    fn OP_TO_STRING(self: *Self, frame: *CallFrame, instruction: Instruction, _: OpCode, _: FullArg) void {
        const args = getCodeRegReg(instruction);
        const value_reg = args.reg;
        const dest_reg = args.dest_reg;

        const str = valueToStringAlloc(
            self.gc.allocator,
            frame.registers[value_reg],
        ) catch @panic("Could not create new string");
        defer str.deinit();

        frame.registers[dest_reg] = Value.fromObj(
            (self.gc.copyString(str.items) catch @panic("Could not copy string")).toObj(),
        );

        const next_full_instruction = self.readInstruction();
        @call(
            .always_tail,
            dispatch,
            .{
                self,
                self.currentFrame().?,
                next_full_instruction,
                getCode(next_full_instruction),
                getArg(next_full_instruction),
            },
        );
    }

    fn OP_NEGATE(self: *Self, frame: *CallFrame, instruction: Instruction, _: OpCode, _: FullArg) void {
        const args = getCodeRegReg(instruction);
        const value_reg = args.reg;
        const dest_reg = args.dest_reg;

        const value = frame.registers[value_reg];

        frame.registers[dest_reg] = if (value.isInteger())
            Value.fromInteger(-value.integer())
        else
            Value.fromFloat(-value.float());

        const next_full_instruction = self.readInstruction();
        @call(
            .always_tail,
            dispatch,
            .{
                self,
                self.currentFrame().?,
                next_full_instruction,
                getCode(next_full_instruction),
                getArg(next_full_instruction),
            },
        );
    }

    fn OP_CLOSURE(self: *Self, frame: *CallFrame, instruction: Instruction, _: OpCode, _: FullArg) void {
        const args = getCodeArgReg(instruction);
        const constant = args.arg;
        const reg = args.reg;

        var function: *ObjFunction = ObjFunction.cast(self.readConstant(constant).obj()).?;
        var closure: *ObjClosure = self.gc.allocateObject(
            ObjClosure,
            ObjClosure.init(self.gc.allocator, self, function) catch @panic("Could not create closure"),
        ) catch @panic("Could not create closure");

        frame.registers[reg] = closure.toValue();

        var i: usize = 0;
        while (i < function.upvalue_count) : (i += 1) {
            var is_local = self.readByte() == 1;
            var index = self.readByte();

            if (is_local) {
                closure.upvalues.append(
                    self.captureUpvalue(&(frame.slots[index])) catch @panic("Could not capture upvalue"),
                ) catch @panic("Could not capture upvalue");
            } else {
                closure.upvalues.append(frame.closure.upvalues.items[index]) catch @panic("Could not add new upvalue");
            }
        }

        const next_full_instruction = self.readInstruction();
        @call(
            .always_tail,
            dispatch,
            .{
                self,
                self.currentFrame().?,
                next_full_instruction,
                getCode(next_full_instruction),
                getArg(next_full_instruction),
            },
        );
    }

    fn OP_CLOSE_UPVALUE(self: *Self, _: *CallFrame, _: Instruction, _: OpCode, _: FullArg) void {
        self.closeUpValues(@ptrCast(*Value, self.current_fiber.stack_top - 1));
        _ = self.pop();

        const next_full_instruction = self.readInstruction();
        @call(
            .always_tail,
            dispatch,
            .{
                self,
                self.currentFrame().?,
                next_full_instruction,
                getCode(next_full_instruction),
                getArg(next_full_instruction),
            },
        );
    }

    fn OP_ROUTINE(self: *Self, frame: *CallFrame, instruction: u32, code: OpCode, _: FullArg) void {
        const args = getCodeArgsReg(instruction);
        const arg_count = args.a;
        const catch_count = args.b;
        const reg = args.reg;

        const stack_ptr = self.current_fiber.stack_top - arg_count - catch_count - 1;
        const stack_len = arg_count + catch_count + 1;
        const stack_slice = stack_ptr[0..stack_len];

        var fiber = self.gc.allocator.create(Fiber) catch @panic("Could not create fiber");
        fiber.* = Fiber.init(
            self.gc.allocator,
            self.current_fiber,
            stack_slice,
            code,
            arg_count,
            catch_count > 0,
            null,
        ) catch @panic("Could not create fiber");

        // Pop arguments and catch clauses
        self.current_fiber.stack_top = self.current_fiber.stack_top - stack_len;

        const type_def = ObjTypeDef.cast(self.pop().obj()).?;

        // Put new fiber on the stack
        var obj_fiber = self.gc.allocateObject(ObjFiber, ObjFiber{
            .fiber = fiber,
            .type_def = type_def,
        }) catch @panic("Could not create fiber");

        frame.registers[reg] = obj_fiber.toValue();

        const next_full_instruction = self.readInstruction();
        @call(
            .always_tail,
            dispatch,
            .{
                self,
                self.currentFrame().?,
                next_full_instruction,
                getCode(next_full_instruction),
                getArg(next_full_instruction),
            },
        );
    }

    fn OP_INVOKE_ROUTINE(self: *Self, _: *CallFrame, _: Instruction, code: OpCode, arg: FullArg) void {
        const method: *ObjString = self.readString(arg);
        const arg_instruction: u32 = self.readInstruction();
        const arg_count: u8 = @intCast(u8, arg_instruction >> 25);
        const catch_count: u24 = @intCast(u8, 0x01ffffff & arg_instruction);

        const stack_ptr = self.current_fiber.stack_top - arg_count - catch_count - 1;
        const stack_len = arg_count + catch_count + 1;
        const stack_slice = stack_ptr[0..stack_len];

        var fiber = self.gc.allocator.create(Fiber) catch @panic("Could not create fiber");
        fiber.* = Fiber.init(
            self.gc.allocator,
            self.current_fiber,
            stack_slice,
            code,
            arg_count,
            catch_count > 0,
            method,
        ) catch @panic("Could not create fiber");

        // Pop arguments and catch clauses
        self.current_fiber.stack_top = self.current_fiber.stack_top - stack_len;

        const type_def = ObjTypeDef.cast(self.pop().obj()).?;

        // Push new fiber on the stack
        var obj_fiber = self.gc.allocateObject(ObjFiber, ObjFiber{
            .fiber = fiber,
            .type_def = type_def,
        }) catch @panic("Could not create fiber");

        self.push(obj_fiber.toValue());

        const next_full_instruction = self.readInstruction();
        @call(
            .always_tail,
            dispatch,
            .{
                self,
                self.currentFrame().?,
                next_full_instruction,
                getCode(next_full_instruction),
                getArg(next_full_instruction),
            },
        );
    }

    fn OP_RESUME(self: *Self, frame: *CallFrame, instruction: Instruction, _: OpCode, _: FullArg) void {
        const args = getCodeRegReg(instruction);

        ObjFiber.cast(frame.registers[args.reg].obj()).?.fiber.resume_(
            self,
            args.dest_reg,
            null,
        ) catch @panic("Could not resume fiber");

        const next_full_instruction = self.readInstruction();
        @call(
            .always_tail,
            dispatch,
            .{
                self,
                self.currentFrame().?,
                next_full_instruction,
                getCode(next_full_instruction),
                getArg(next_full_instruction),
            },
        );
    }

    fn OP_RESOLVE(self: *Self, frame: *CallFrame, instruction: Instruction, _: OpCode, _: FullArg) void {
        const args = getCodeRegReg(instruction);

        ObjFiber.cast(frame.registers[args.reg].obj()).?.fiber.resolve_(
            self,
            args.dest_reg,
        ) catch @panic("Could not resolve fiber");

        const next_full_instruction = self.readInstruction();
        @call(
            .always_tail,
            dispatch,
            .{
                self,
                self.currentFrame().?,
                next_full_instruction,
                getCode(next_full_instruction),
                getArg(next_full_instruction),
            },
        );
    }

    fn OP_YIELD(self: *Self, frame: *CallFrame, _: Instruction, _: OpCode, reg: FullArg) void {
        self.current_fiber.yield(self, frame.registers[reg]);

        const next_full_instruction = self.readInstruction();
        @call(
            .always_tail,
            dispatch,
            .{
                self,
                self.currentFrame().?,
                next_full_instruction,
                getCode(next_full_instruction),
                getArg(next_full_instruction),
            },
        );
    }

    fn OP_CALL(self: *Self, _: *CallFrame, instruction: u32, _: OpCode, _: FullArg) void {
        const args = getCodeArgsReg(instruction);
        const arg_count = args.a;
        const catch_count = args.b;
        const reg = args.reg;

        // FIXME: no reason to take the catch value off the stack
        const catch_value = if (catch_count > 0) self.pop() else null;

        self.callValue(
            self.peek(arg_count),
            arg_count,
            catch_value,
            false,
            reg,
        ) catch @panic("Could not call value");

        const next_full_instruction = self.readInstruction();
        @call(
            .always_tail,
            dispatch,
            .{
                self,
                self.currentFrame().?,
                next_full_instruction,
                getCode(next_full_instruction),
                getArg(next_full_instruction),
            },
        );
    }

    fn OP_INSTANCE_INVOKE(self: *Self, _: *CallFrame, instruction: Instruction, _: OpCode, _: FullArg) void {
        const args = getCodeArgReg(instruction);
        const constant = args.arg;
        const reg = args.reg;

        const method = self.readString(constant);
        const arg_instruction = self.readInstruction();
        const arg_count = @truncate(u8, arg_instruction >> 16);
        const catch_count = 0x0000ffff & arg_instruction;
        const catch_value = if (catch_count > 0) self.pop() else null;

        const instance: *ObjObjectInstance = ObjObjectInstance.cast(self.peek(arg_count).obj()).?;

        assert(instance.object != null);

        if (instance.fields.get(method)) |field| {
            (self.current_fiber.stack_top - arg_count - 1)[0] = field;

            self.callValue(
                field,
                arg_count,
                catch_value,
                false,
                reg,
            ) catch @panic("Could not call value");
        } else {
            self.invokeFromObject(
                instance.object.?,
                method,
                arg_count,
                catch_value,
                false,
                reg,
            ) catch @panic("Could not invoke value");
        }

        const next_full_instruction = self.readInstruction();
        @call(
            .always_tail,
            dispatch,
            .{
                self,
                self.currentFrame().?,
                next_full_instruction,
                getCode(next_full_instruction),
                getArg(next_full_instruction),
            },
        );
    }

    fn OP_STRING_INVOKE(self: *Self, _: *CallFrame, instruction: Instruction, _: OpCode, _: FullArg) void {
        const args = getCodeArgReg(instruction);
        const constant = args.arg;
        const reg = args.reg;

        const method = self.readString(constant);
        const arg_instruction = self.readInstruction();
        const arg_count = @truncate(u8, arg_instruction >> 16);
        const catch_count = 0x0000ffff & arg_instruction;
        const catch_value = if (catch_count > 0) self.pop() else null;

        const member = (ObjString.member(self, method) catch @panic("Could not get string member")).?;
        var member_value: Value = member.toValue();
        (self.current_fiber.stack_top - arg_count - 1)[0] = member_value;

        self.callValue(
            member_value,
            arg_count,
            catch_value,
            false,
            reg,
        ) catch @panic("Could not call string member");

        const next_full_instruction = self.readInstruction();
        @call(
            .always_tail,
            dispatch,
            .{
                self,
                self.currentFrame().?,
                next_full_instruction,
                getCode(next_full_instruction),
                getArg(next_full_instruction),
            },
        );
    }

    fn OP_PATTERN_INVOKE(self: *Self, _: *CallFrame, instruction: Instruction, _: OpCode, _: FullArg) void {
        const args = getCodeArgReg(instruction);
        const constant = args.arg;
        const reg = args.reg;

        const method = self.readString(constant);
        const arg_instruction = self.readInstruction();
        const arg_count = @truncate(u8, arg_instruction >> 16);
        const catch_count = 0x0000ffff & arg_instruction;
        const catch_value = if (catch_count > 0) self.pop() else null;

        const member = (ObjPattern.member(self, method) catch @panic("Could not get pattern member")).?;
        var member_value: Value = member.toValue();
        (self.current_fiber.stack_top - arg_count - 1)[0] = member_value;

        self.callValue(
            member_value,
            arg_count,
            catch_value,
            false,
            reg,
        ) catch @panic("Could not call pattern method");

        const next_full_instruction = self.readInstruction();
        @call(
            .always_tail,
            dispatch,
            .{
                self,
                self.currentFrame().?,
                next_full_instruction,
                getCode(next_full_instruction),
                getArg(next_full_instruction),
            },
        );
    }

    fn OP_FIBER_INVOKE(self: *Self, _: *CallFrame, instruction: Instruction, _: OpCode, _: FullArg) void {
        const args = getCodeArgReg(instruction);
        const constant = args.arg;
        const reg = args.reg;

        const method = self.readString(constant);
        const arg_instruction = self.readInstruction();
        const arg_count = @truncate(u8, arg_instruction >> 16);
        const catch_count = 0x0000ffff & arg_instruction;
        const catch_value = if (catch_count > 0) self.pop() else null;

        const member = (ObjFiber.member(self, method) catch @panic("Could not get fiber method")).?;
        var member_value: Value = member.toValue();
        (self.current_fiber.stack_top - arg_count - 1)[0] = member_value;
        self.callValue(
            member_value,
            arg_count,
            catch_value,
            false,
            reg,
        ) catch @panic("Could not call fiber method");

        const next_full_instruction = self.readInstruction();
        @call(
            .always_tail,
            dispatch,
            .{
                self,
                self.currentFrame().?,
                next_full_instruction,
                getCode(next_full_instruction),
                getArg(next_full_instruction),
            },
        );
    }

    fn OP_LIST_INVOKE(self: *Self, _: *CallFrame, instruction: Instruction, _: OpCode, _: FullArg) void {
        const args = getCodeArgReg(instruction);
        const constant = args.arg;
        const reg = args.reg;

        const method = self.readString(constant);
        const arg_instruction = self.readInstruction();
        const arg_count = @truncate(u8, arg_instruction >> 16);
        const catch_count = 0x0000ffff & arg_instruction;
        const catch_value = if (catch_count > 0) self.pop() else null;

        const list = ObjList.cast(self.peek(arg_count).obj()).?;
        const member = (list.member(self, method) catch @panic("Could not get list method")).?;

        const member_value: Value = member.toValue();
        (self.current_fiber.stack_top - arg_count - 1)[0] = member_value;
        self.callValue(
            member_value,
            arg_count,
            catch_value,
            false,
            reg,
        ) catch @panic("Could not call list method");

        const next_full_instruction = self.readInstruction();
        @call(
            .always_tail,
            dispatch,
            .{
                self,
                self.currentFrame().?,
                next_full_instruction,
                getCode(next_full_instruction),
                getArg(next_full_instruction),
            },
        );
    }

    fn OP_MAP_INVOKE(self: *Self, _: *CallFrame, instruction: Instruction, _: OpCode, _: FullArg) void {
        const args = getCodeArgReg(instruction);
        const constant = args.arg;
        const reg = args.reg;

        const method = self.readString(constant);
        const arg_instruction = self.readInstruction();
        const arg_count = @truncate(u8, arg_instruction >> 16);
        const catch_count = 0x0000ffff & arg_instruction;
        const catch_value = if (catch_count > 0) self.pop() else null;

        const map = ObjMap.cast(self.peek(arg_count).obj()).?;
        const member = (map.member(self, method) catch @panic("Could not get map method")).?;

        var member_value: Value = member.toValue();
        (self.current_fiber.stack_top - arg_count - 1)[0] = member_value;
        self.callValue(
            member_value,
            arg_count,
            catch_value,
            false,
            reg,
        ) catch @panic("Could not call map method");

        const next_full_instruction = self.readInstruction();
        @call(
            .always_tail,
            dispatch,
            .{
                self,
                self.currentFrame().?,
                next_full_instruction,
                getCode(next_full_instruction),
                getArg(next_full_instruction),
            },
        );
    }

    // result_count > 0 when the return is `export`
    inline fn returnFrame(self: *Self, value_register: Reg) bool {
        const result = self.currentFrame().?.registers[value_register];

        const frame: *CallFrame = self.currentFrame().?;

        self.closeUpValues(&frame.slots[0]);

        self.current_fiber.frame_count -= 1;
        _ = self.current_fiber.frames.pop();

        // We popped the last frame
        if (self.current_fiber.frame_count == 0) {
            // We're in a fiber
            if (self.current_fiber.parent_fiber != null) {
                self.current_fiber.finish(self, result) catch @panic("Could not finish fiber");

                // Don't stop the VM
                return false;
            }

            // We're not in a fiber, the program is over
            _ = self.pop();
            return true;
        }

        // Normal return, set the stack back and push the result
        self.current_fiber.stack_top = frame.slots;

        if (frame.result_register) |result_register| {
            self.currentFrame().?.registers[result_register] = result;
        } else {
            self.push(result);
        }

        return false;
    }

    fn OP_RETURN(self: *Self, _: *CallFrame, _: Instruction, _: OpCode, reg: FullArg) void {
        if (self.returnFrame(@intCast(Reg, reg)) or self.currentFrame().?.in_native_call) {
            return;
        }

        const next_full_instruction = self.readInstruction();
        @call(
            .always_tail,
            dispatch,
            .{
                self,
                self.currentFrame().?,
                next_full_instruction,
                getCode(next_full_instruction),
                getArg(next_full_instruction),
            },
        );
    }

    fn OP_EXPORT(self: *Self, _: *CallFrame, _: Instruction, _: OpCode, arg: FullArg) void {
        self.push(Value.fromInteger(@intCast(i32, arg)));

        // Ends program, so we don't call dispatch
    }

    fn OP_IMPORT(self: *Self, frame: *CallFrame, instruction: Instruction, _: OpCode, _: FullArg) void {
        const constant = @intCast(Arg, (0x01ffffff & instruction) >> @bitSizeOf(Reg));
        const reg = @intCast(Reg, 0x000000ff & instruction);

        const fullpath = self.readString(constant);
        const closure = ObjClosure.cast(frame.registers[reg].obj()).?;

        if (self.import_registry.get(fullpath)) |globals| {
            for (globals.items) |global| {
                self.globals.append(global) catch @panic("Could not add new global");
            }
        } else {
            var vm = self.gc.allocator.create(VM) catch @panic("Could not create VM");
            // FIXME: give reference to JIT?
            vm.* = VM.init(self.gc, self.import_registry, self.testing) catch @panic("Could not create VM");
            // TODO: how to free this since we copy things to new vm, also fails anyway
            // {
            //     defer vm.deinit();
            //     defer gn.deinit();
            // }

            vm.interpret(closure.function, null) catch @panic("Could not interpret program");

            // Top of stack is how many export we got
            var exported_count: u8 = @intCast(u8, vm.peek(0).integer());

            // Copy them to this vm globals
            var import_cache = std.ArrayList(Value).init(self.gc.allocator);
            if (exported_count > 0) {
                var i: u8 = exported_count;
                while (i > 0) : (i -= 1) {
                    const global = vm.peek(i);
                    self.globals.append(global) catch @panic("Could not add new global");
                    import_cache.append(global) catch @panic("Could not add new global");
                }
            }

            self.import_registry.put(fullpath, import_cache) catch @panic("Could not import script");
        }

        const next_full_instruction = self.readInstruction();
        @call(
            .always_tail,
            dispatch,
            .{
                self,
                self.currentFrame().?,
                next_full_instruction,
                getCode(next_full_instruction),
                getArg(next_full_instruction),
            },
        );
    }

    fn OP_TRY(self: *Self, _: *CallFrame, _: Instruction, _: OpCode, arg: FullArg) void {
        self.currentFrame().?.try_ip = @intCast(usize, arg);
        // We will close scope up to this top if an error is thrown
        self.currentFrame().?.try_top = self.current_fiber.stack_top;

        const next_full_instruction = self.readInstruction();
        @call(
            .always_tail,
            dispatch,
            .{
                self,
                self.currentFrame().?,
                next_full_instruction,
                getCode(next_full_instruction),
                getArg(next_full_instruction),
            },
        );
    }

    fn OP_TRY_END(self: *Self, _: *CallFrame, _: Instruction, _: OpCode, _: FullArg) void {
        self.currentFrame().?.try_ip = null;
        self.currentFrame().?.try_top = null;

        const next_full_instruction = self.readInstruction();
        @call(
            .always_tail,
            dispatch,
            .{
                self,
                self.currentFrame().?,
                next_full_instruction,
                getCode(next_full_instruction),
                getArg(next_full_instruction),
            },
        );
    }

    fn OP_THROW(self: *Self, frame: *CallFrame, _: Instruction, _: OpCode, reg: FullArg) void {
        self.throw(Error.Custom, frame.registers[reg]) catch @panic("Could not raise error");

        const next_full_instruction = self.readInstruction();
        @call(
            .always_tail,
            dispatch,
            .{
                self,
                self.currentFrame().?,
                next_full_instruction,
                getCode(next_full_instruction),
                getArg(next_full_instruction),
            },
        );
    }

    fn OP_LIST(self: *Self, frame: *CallFrame, instruction: Instruction, _: OpCode, _: FullArg) void {
        const args = getCodeArgReg(instruction);
        const constant = args.arg;
        const reg = args.reg;

        var list: *ObjList = self.gc.allocateObject(
            ObjList,
            ObjList.init(self.gc.allocator, ObjTypeDef.cast(self.readConstant(constant).obj()).?),
        ) catch @panic("Could not create list");

        frame.registers[reg] = list.toValue();

        const next_full_instruction = self.readInstruction();
        @call(
            .always_tail,
            dispatch,
            .{
                self,
                self.currentFrame().?,
                next_full_instruction,
                getCode(next_full_instruction),
                getArg(next_full_instruction),
            },
        );
    }

    fn OP_LIST_APPEND(self: *Self, frame: *CallFrame, instruction: Instruction, _: OpCode, _: FullArg) void {
        const args = getCodeRegReg(instruction);
        const item_reg = args.reg;
        const list_reg = args.dest_reg;

        var list: *ObjList = ObjList.cast(frame.registers[list_reg].obj()).?;
        var list_value: Value = frame.registers[item_reg];

        list.rawAppend(self.gc, list_value) catch @panic("Could not append item to list");

        const next_full_instruction = self.readInstruction();
        @call(
            .always_tail,
            dispatch,
            .{
                self,
                self.currentFrame().?,
                next_full_instruction,
                getCode(next_full_instruction),
                getArg(next_full_instruction),
            },
        );
    }

    fn OP_MAP(self: *Self, frame: *CallFrame, instruction: Instruction, _: OpCode, _: FullArg) void {
        const args = getCodeArgReg(instruction);
        const constant = args.arg;
        const reg = args.reg;

        var map: *ObjMap = self.gc.allocateObject(ObjMap, ObjMap.init(
            self.gc.allocator,
            ObjTypeDef.cast(self.readConstant(constant).obj()).?,
        )) catch @panic("Could not create map");

        frame.registers[reg] = map.toValue();

        const next_full_instruction = self.readInstruction();
        @call(
            .always_tail,
            dispatch,
            .{
                self,
                self.currentFrame().?,
                next_full_instruction,
                getCode(next_full_instruction),
                getArg(next_full_instruction),
            },
        );
    }

    fn OP_SET_MAP(self: *Self, frame: *CallFrame, instruction: Instruction, _: OpCode, _: FullArg) void {
        const args = getCodeRegs(instruction);
        const key_reg = args.reg1;
        const value_reg = args.reg2;
        const map_reg = args.reg3;

        const map: *ObjMap = ObjMap.cast(frame.registers[map_reg].obj()).?;
        const key: Value = frame.registers[key_reg];
        const value: Value = frame.registers[value_reg];

        map.set(self.gc, key, value) catch @panic("Could not set map element");

        const next_full_instruction = self.readInstruction();
        @call(
            .always_tail,
            dispatch,
            .{
                self,
                self.currentFrame().?,
                next_full_instruction,
                getCode(next_full_instruction),
                getArg(next_full_instruction),
            },
        );
    }

    fn OP_GET_LIST_SUBSCRIPT(self: *Self, frame: *CallFrame, instruction: Instruction, _: OpCode, _: FullArg) void {
        const args = getCodeRegs(instruction);
        const list_reg = args.reg1;
        const key_reg = args.reg2;
        const dest_reg = args.reg3;

        const list: *ObjList = ObjList.cast(frame.registers[list_reg].obj()).?;
        const index = frame.registers[key_reg].integer();

        if (index < 0) {
            self.throw(
                Error.OutOfBound,
                (self.gc.copyString("Out of bound list access.") catch @panic("Could not raise error")).toValue(),
            ) catch @panic("Could not raise error");
        }

        const list_index: usize = @intCast(usize, index);

        if (list_index >= list.items.items.len) {
            self.throw(
                Error.OutOfBound,
                (self.gc.copyString("Out of bound list access.") catch @panic("Could not raise error")).toValue(),
            ) catch @panic("Could not raise error");

            return;
        }

        const list_item = list.items.items[list_index];

        frame.registers[dest_reg] = list_item;

        const next_full_instruction = self.readInstruction();
        @call(
            .always_tail,
            dispatch,
            .{
                self,
                self.currentFrame().?,
                next_full_instruction,
                getCode(next_full_instruction),
                getArg(next_full_instruction),
            },
        );
    }

    fn OP_GET_MAP_SUBSCRIPT(self: *Self, frame: *CallFrame, instruction: Instruction, _: OpCode, _: FullArg) void {
        const args = getCodeRegs(instruction);
        const map_reg = args.reg1;
        const key_reg = args.reg2;
        const dest_reg = args.reg3;

        const map: *ObjMap = ObjMap.cast(frame.registers[map_reg].obj()).?;
        const index: Value = floatToInteger(frame.registers[key_reg]);

        if (map.map.get(index)) |value| {
            frame.registers[dest_reg] = value;
        } else {
            frame.registers[dest_reg] = Value.Null;
        }

        const next_full_instruction = self.readInstruction();
        @call(
            .always_tail,
            dispatch,
            .{
                self,
                self.currentFrame().?,
                next_full_instruction,
                getCode(next_full_instruction),
                getArg(next_full_instruction),
            },
        );
    }

    fn OP_GET_STRING_SUBSCRIPT(self: *Self, frame: *CallFrame, instruction: Instruction, _: OpCode, _: FullArg) void {
        const args = getCodeRegs(instruction);
        const subscript_reg = args.reg1;
        const key_reg = args.reg2;
        const dest_reg = args.reg3;

        const str = ObjString.cast(frame.registers[subscript_reg].obj()).?;
        const index = frame.registers[key_reg].integer();

        if (index < 0) {
            self.throw(
                Error.OutOfBound,
                (self.gc.copyString("Out of bound string access.") catch @panic("Could not raise error")).toValue(),
            ) catch @panic("Could not raise error");
        }

        const str_index: usize = @intCast(usize, index);

        if (str_index < str.string.len) {
            const str_item: Value = (self.gc.copyString(&([_]u8{str.string[str_index]})) catch @panic("Could not subscript string")).toValue();

            frame.registers[dest_reg] = str_item;
        } else {
            self.throw(
                Error.OutOfBound,
                (self.gc.copyString("Out of bound string access.") catch @panic("Could not raise error")).toValue(),
            ) catch @panic("Could not raise error");
        }

        const next_full_instruction = self.readInstruction();
        @call(
            .always_tail,
            dispatch,
            .{
                self,
                self.currentFrame().?,
                next_full_instruction,
                getCode(next_full_instruction),
                getArg(next_full_instruction),
            },
        );
    }

    fn OP_SET_LIST_SUBSCRIPT(self: *Self, frame: *CallFrame, instruction: Instruction, _: OpCode, _: FullArg) void {
        const args = getCodeRegs(instruction);
        const key_reg = args.reg1;
        const value_reg = args.reg2;
        const list_reg = args.reg3;

        const list = ObjList.cast(frame.registers[list_reg].obj()).?;
        const index = frame.registers[key_reg];
        const value = frame.registers[value_reg];

        if (index.integer() < 0) {
            self.throw(
                Error.OutOfBound,
                (self.gc.copyString("Out of bound string access.") catch @panic("Could not raise error")).toValue(),
            ) catch @panic("Could not raise error");
        }

        const list_index: usize = @intCast(usize, index.integer());

        if (list_index < list.items.items.len) {
            list.set(self.gc, list_index, value) catch @panic("Could not set list element");
        } else {
            self.throw(
                Error.OutOfBound,
                (self.gc.copyString("Out of bound string access.") catch @panic("Could not raise error")).toValue(),
            ) catch @panic("Could not raise error");
        }

        const next_full_instruction = self.readInstruction();
        @call(
            .always_tail,
            dispatch,
            .{
                self,
                self.currentFrame().?,
                next_full_instruction,
                getCode(next_full_instruction),
                getArg(next_full_instruction),
            },
        );
    }

    fn OP_SET_MAP_SUBSCRIPT(self: *Self, frame: *CallFrame, instruction: Instruction, _: OpCode, _: FullArg) void {
        const args = getCodeRegs(instruction);
        const key_reg = args.reg1;
        const value_reg = args.reg2;
        const map_reg = args.reg3;

        const map: *ObjMap = ObjMap.cast(frame.registers[map_reg].obj()).?;
        const index = frame.registers[key_reg];
        const value = frame.registers[value_reg];

        map.set(self.gc, index, value) catch @panic("Could not set map element");

        const next_full_instruction = self.readInstruction();
        @call(
            .always_tail,
            dispatch,
            .{
                self,
                self.currentFrame().?,
                next_full_instruction,
                getCode(next_full_instruction),
                getArg(next_full_instruction),
            },
        );
    }

    fn OP_ENUM(self: *Self, frame: *CallFrame, instruction: Instruction, _: OpCode, _: FullArg) void {
        const args = getCodeArgReg(instruction);
        const constant = args.arg;
        const reg = args.reg;

        const enum_: *ObjEnum = self.gc.allocateObject(
            ObjEnum,
            ObjEnum.init(self.gc.allocator, ObjTypeDef.cast(self.readConstant(constant).obj()).?),
        ) catch @panic("Could not create enum");

        frame.registers[reg] = Value.fromObj(enum_.toObj());

        const next_full_instruction = self.readInstruction();
        @call(
            .always_tail,
            dispatch,
            .{
                self,
                self.currentFrame().?,
                next_full_instruction,
                getCode(next_full_instruction),
                getArg(next_full_instruction),
            },
        );
    }

    fn OP_ENUM_CASE(self: *Self, frame: *CallFrame, instruction: Instruction, _: OpCode, _: FullArg) void {
        const args = getCodeRegReg(instruction);
        const enum_reg = args.reg;
        const value_reg = args.dest_reg;

        const enum_ = ObjEnum.cast(frame.registers[enum_reg].obj()).?;
        const enum_value = frame.registers[value_reg];

        enum_.cases.append(enum_value) catch @panic("Could append new enum case");
        self.gc.markObjDirty(&enum_.obj) catch @panic("Could append new enum case");

        const next_full_instruction = self.readInstruction();
        @call(
            .always_tail,
            dispatch,
            .{
                self,
                self.currentFrame().?,
                next_full_instruction,
                getCode(next_full_instruction),
                getArg(next_full_instruction),
            },
        );
    }

    fn OP_GET_ENUM_CASE(self: *Self, frame: *CallFrame, instruction: Instruction, _: OpCode, _: FullArg) void {
        const args = getCodeArgRegs(instruction);
        const case = args.arg;
        const enum_reg = args.reg;
        const dest_reg = args.dest_reg;

        const enum_ = ObjEnum.cast(frame.registers[enum_reg].obj()).?;

        const enum_case: *ObjEnumInstance = self.gc.allocateObject(ObjEnumInstance, ObjEnumInstance{
            .enum_ref = enum_,
            .case = @intCast(u8, case),
        }) catch @panic("Could not get enum case");

        frame.registers[dest_reg] = Value.fromObj(enum_case.toObj());

        const next_full_instruction = self.readInstruction();
        @call(
            .always_tail,
            dispatch,
            .{
                self,
                self.currentFrame().?,
                next_full_instruction,
                getCode(next_full_instruction),
                getArg(next_full_instruction),
            },
        );
    }

    fn OP_GET_ENUM_CASE_VALUE(self: *Self, frame: *CallFrame, instruction: Instruction, _: OpCode, _: FullArg) void {
        const args = getCodeRegReg(instruction);
        const enum_instance_reg = args.reg;
        const dest_reg = args.dest_reg;

        const enum_case: *ObjEnumInstance = ObjEnumInstance.cast(frame.registers[enum_instance_reg].obj()).?;

        frame.registers[dest_reg] = enum_case.enum_ref.cases.items[enum_case.case];

        const next_full_instruction = self.readInstruction();
        @call(
            .always_tail,
            dispatch,
            .{
                self,
                self.currentFrame().?,
                next_full_instruction,
                getCode(next_full_instruction),
                getArg(next_full_instruction),
            },
        );
    }

    fn OP_GET_ENUM_CASE_FROM_VALUE(self: *Self, frame: *CallFrame, instruction: Instruction, _: OpCode, _: FullArg) void {
        const args = getCodeRegs(instruction);
        const enum_reg = args.reg1;
        const value_reg = args.reg2;
        const dest_reg = args.reg3;

        const enum_: *ObjEnum = ObjEnum.cast(frame.registers[enum_reg].obj()).?;
        const case_value = frame.registers[value_reg];

        var found = false;
        for (enum_.cases.items, 0..) |case, index| {
            if (valueEql(case, case_value)) {
                const enum_case: *ObjEnumInstance = self.gc.allocateObject(ObjEnumInstance, ObjEnumInstance{
                    .enum_ref = enum_,
                    .case = @intCast(u8, index),
                }) catch @panic("Could not create enum instance");

                frame.registers[dest_reg] = Value.fromObj(enum_case.toObj());
                found = true;

                break;
            }
        }

        if (!found) {
            frame.registers[dest_reg] = Value.Null;
        }

        const next_full_instruction = self.readInstruction();
        @call(
            .always_tail,
            dispatch,
            .{
                self,
                self.currentFrame().?,
                next_full_instruction,
                getCode(next_full_instruction),
                getArg(next_full_instruction),
            },
        );
    }

    fn OP_OBJECT(self: *Self, frame: *CallFrame, instruction: Instruction, _: OpCode, _: FullArg) void {
        const args = getCodeArgReg(instruction);
        const name_constant = args.arg;
        const dest_reg = args.reg;

        var object: *ObjObject = self.gc.allocateObject(
            ObjObject,
            ObjObject.init(
                self.gc.allocator,
                ObjString.cast(self.readConstant(name_constant).obj()).?,
                ObjTypeDef.cast(self.readConstant(@intCast(u24, self.readInstruction())).obj()).?,
            ),
        ) catch @panic("Could not create object");

        frame.registers[dest_reg] = Value.fromObj(object.toObj());

        const next_full_instruction = self.readInstruction();
        @call(
            .always_tail,
            dispatch,
            .{
                self,
                self.currentFrame().?,
                next_full_instruction,
                getCode(next_full_instruction),
                getArg(next_full_instruction),
            },
        );
    }

    fn OP_INSTANCE(self: *Self, frame: *CallFrame, instruction: Instruction, _: OpCode, _: FullArg) void {
        const args = getCodeRegReg(instruction);
        const obj_reg = args.reg;
        const dest_reg = args.dest_reg;

        const object_or_type = frame.registers[obj_reg].obj();
        const instance = self.gc.allocateObject(
            ObjObjectInstance,
            ObjObjectInstance.init(
                self.gc.allocator,
                ObjObject.cast(object_or_type),
                ObjTypeDef.cast(object_or_type),
            ),
        ) catch @panic("Could not create object instance");

        // If not anonymous, set default fields
        if (ObjObject.cast(object_or_type)) |object| {
            // Set instance fields with default values
            var it = object.fields.iterator();
            while (it.next()) |kv| {
                instance.setField(
                    self.gc,
                    kv.key_ptr.*,
                    self.cloneValue(kv.value_ptr.*) catch @panic("Could not set object instance field default value"),
                ) catch @panic("Could not set object instance field default value");
            }
        }

        frame.registers[dest_reg] = instance.toValue();

        const next_full_instruction = self.readInstruction();
        @call(
            .always_tail,
            dispatch,
            .{
                self,
                self.currentFrame().?,
                next_full_instruction,
                getCode(next_full_instruction),
                getArg(next_full_instruction),
            },
        );
    }

    fn OP_METHOD(self: *Self, frame: *CallFrame, instruction: Instruction, _: OpCode, _: FullArg) void {
        const args = getCodeArgReg(instruction);
        const constant = args.arg;
        const obj_reg = args.reg;
        const value_reg = self.readInstruction();

        const name = self.readString(constant);
        const method = frame.registers[value_reg];
        const object = ObjObject.cast(frame.registers[obj_reg].obj()).?;

        object.methods.put(name, ObjClosure.cast(method.obj()).?) catch @panic("Could not set object method");

        const next_full_instruction = self.readInstruction();
        @call(
            .always_tail,
            dispatch,
            .{
                self,
                self.currentFrame().?,
                next_full_instruction,
                getCode(next_full_instruction),
                getArg(next_full_instruction),
            },
        );
    }

    fn OP_PROPERTY(self: *Self, frame: *CallFrame, instruction: Instruction, _: OpCode, _: FullArg) void {
        const args = getCodeArgReg(instruction);
        const constant = args.arg;
        const obj_reg = args.reg;
        const value_reg = self.readInstruction();

        const name = self.readString(constant);
        const property = frame.registers[value_reg];
        const object = ObjObject.cast(frame.registers[obj_reg].obj()).?;

        if (object.type_def.resolved_type.?.Object.fields.contains(name.string)) {
            object.setField(self.gc, name, property) catch @panic("Could not set object field");
        } else {
            assert(object.type_def.resolved_type.?.Object.static_fields.contains(name.string));
            object.setStaticField(self.gc, name, property) catch @panic("Could not set object static field");
        }

        const next_full_instruction = self.readInstruction();
        @call(
            .always_tail,
            dispatch,
            .{
                self,
                self.currentFrame().?,
                next_full_instruction,
                getCode(next_full_instruction),
                getArg(next_full_instruction),
            },
        );
    }

    fn OP_GET_OBJECT_PROPERTY(self: *Self, frame: *CallFrame, instruction: Instruction, _: OpCode, _: FullArg) void {
        const args = getCodeRegReg(instruction);
        const constant = @intCast(FullArg, self.readInstruction());
        const obj_reg = args.reg;
        const dest_reg = args.dest_reg;

        const object: *ObjObject = ObjObject.cast(frame.registers[obj_reg].obj()).?;
        const name: *ObjString = self.readString(constant);

        frame.registers[dest_reg] = object.static_fields.get(name).?;

        const next_full_instruction = self.readInstruction();
        @call(
            .always_tail,
            dispatch,
            .{
                self,
                self.currentFrame().?,
                next_full_instruction,
                getCode(next_full_instruction),
                getArg(next_full_instruction),
            },
        );
    }

    fn OP_GET_INSTANCE_PROPERTY(self: *Self, frame: *CallFrame, instruction: Instruction, _: OpCode, _: FullArg) void {
        const args = getCodeRegReg(instruction);
        const constant = @intCast(FullArg, self.readInstruction());
        const instance_reg = args.reg;
        const dest_reg = args.dest_reg;

        const instance = ObjObjectInstance.cast(frame.registers[instance_reg].obj()).?;
        const name = self.readString(constant);

        if (instance.fields.get(name)) |field| {
            frame.registers[dest_reg] = field;
        } else if (instance.object) |object| {
            if (object.methods.get(name)) |method| {
                self.bindMethod(
                    method,
                    null,
                    instance.toValue(),
                    dest_reg,
                ) catch @panic("Could not bind method");
            } else {
                unreachable;
            }
        }

        const next_full_instruction = self.readInstruction();
        @call(
            .always_tail,
            dispatch,
            .{
                self,
                self.currentFrame().?,
                next_full_instruction,
                getCode(next_full_instruction),
                getArg(next_full_instruction),
            },
        );
    }

    fn OP_GET_LIST_PROPERTY(self: *Self, frame: *CallFrame, instruction: Instruction, _: OpCode, _: FullArg) void {
        const args = getCodeRegReg(instruction);
        const constant = @intCast(FullArg, self.readInstruction());
        const list_reg = args.reg;
        const dest_reg = args.dest_reg;

        const list = ObjList.cast(frame.registers[list_reg].obj()).?;
        const name: *ObjString = self.readString(constant);

        if (list.member(self, name) catch @panic("Could not get list member")) |member| {
            self.bindMethod(
                null,
                member,
                list.toValue(),
                dest_reg,
            ) catch @panic("Could not bind method");
        } else {
            unreachable;
        }

        const next_full_instruction = self.readInstruction();
        @call(
            .always_tail,
            dispatch,
            .{
                self,
                self.currentFrame().?,
                next_full_instruction,
                getCode(next_full_instruction),
                getArg(next_full_instruction),
            },
        );
    }
    fn OP_GET_MAP_PROPERTY(self: *Self, frame: *CallFrame, instruction: Instruction, _: OpCode, _: FullArg) void {
        const args = getCodeRegReg(instruction);
        const constant = @intCast(FullArg, self.readInstruction());
        const map_reg = args.reg;
        const dest_reg = args.dest_reg;

        const map = ObjMap.cast(frame.registers[map_reg].obj()).?;
        const name: *ObjString = self.readString(constant);

        if (map.member(self, name) catch @panic("Could not get map method")) |member| {
            self.bindMethod(
                null,
                member,
                map.toValue(),
                dest_reg,
            ) catch @panic("Could not bind method");
        } else {
            unreachable;
        }

        const next_full_instruction = self.readInstruction();
        @call(
            .always_tail,
            dispatch,
            .{
                self,
                self.currentFrame().?,
                next_full_instruction,
                getCode(next_full_instruction),
                getArg(next_full_instruction),
            },
        );
    }

    fn OP_GET_STRING_PROPERTY(self: *Self, frame: *CallFrame, instruction: Instruction, _: OpCode, _: FullArg) void {
        const args = getCodeRegReg(instruction);
        const constant = @intCast(FullArg, self.readInstruction());
        const str_reg = args.reg;
        const dest_reg = args.dest_reg;

        const name: *ObjString = self.readString(constant);

        if (ObjString.member(self, name) catch @panic("Could not get string method")) |member| {
            self.bindMethod(
                null,
                member,
                frame.registers[str_reg],
                dest_reg,
            ) catch @panic("Could not bind method");
        } else {
            unreachable;
        }

        const next_full_instruction = self.readInstruction();
        @call(
            .always_tail,
            dispatch,
            .{
                self,
                self.currentFrame().?,
                next_full_instruction,
                getCode(next_full_instruction),
                getArg(next_full_instruction),
            },
        );
    }

    fn OP_GET_PATTERN_PROPERTY(self: *Self, frame: *CallFrame, instruction: Instruction, _: OpCode, _: FullArg) void {
        const args = getCodeRegReg(instruction);
        const constant = @intCast(FullArg, self.readInstruction());
        const pat_reg = args.reg;
        const dest_reg = args.dest_reg;

        const name: *ObjString = self.readString(constant);

        if (ObjPattern.member(self, name) catch @panic("Could not get pattern method")) |member| {
            self.bindMethod(
                null,
                member,
                frame.registers[pat_reg],
                dest_reg,
            ) catch @panic("Could not bind method");
        } else {
            unreachable;
        }

        const next_full_instruction = self.readInstruction();
        @call(
            .always_tail,
            dispatch,
            .{
                self,
                self.currentFrame().?,
                next_full_instruction,
                getCode(next_full_instruction),
                getArg(next_full_instruction),
            },
        );
    }

    fn OP_GET_FIBER_PROPERTY(self: *Self, frame: *CallFrame, instruction: Instruction, _: OpCode, _: FullArg) void {
        const args = getCodeRegReg(instruction);
        const constant = @intCast(FullArg, self.readInstruction());
        const fib_reg = args.reg;
        const dest_reg = args.dest_reg;

        const name: *ObjString = self.readString(constant);

        if (ObjFiber.member(self, name) catch @panic("Could not get fiber member")) |member| {
            self.bindMethod(
                null,
                member,
                frame.registers[fib_reg],
                dest_reg,
            ) catch @panic("Could not bind method");
        }

        const next_full_instruction = self.readInstruction();
        @call(
            .always_tail,
            dispatch,
            .{
                self,
                self.currentFrame().?,
                next_full_instruction,
                getCode(next_full_instruction),
                getArg(next_full_instruction),
            },
        );
    }

    fn OP_SET_OBJECT_PROPERTY(self: *Self, frame: *CallFrame, instruction: Instruction, _: OpCode, _: FullArg) void {
        const args = getCodeRegReg(instruction);
        const constant = @intCast(FullArg, self.readInstruction());
        const value_reg = args.dest_reg;
        const obj_reg = args.reg;

        const object: *ObjObject = ObjObject.cast(frame.registers[obj_reg].obj()).?;
        const name: *ObjString = self.readString(constant);

        // Set new value
        object.setStaticField(
            self.gc,
            name,
            frame.registers[value_reg],
        ) catch @panic("Could not set static field");

        const next_full_instruction = self.readInstruction();
        @call(
            .always_tail,
            dispatch,
            .{
                self,
                self.currentFrame().?,
                next_full_instruction,
                getCode(next_full_instruction),
                getArg(next_full_instruction),
            },
        );
    }

    fn OP_SET_INSTANCE_PROPERTY(self: *Self, frame: *CallFrame, instruction: Instruction, _: OpCode, _: FullArg) void {
        const args = getCodeRegReg(instruction);
        const constant = @intCast(FullArg, self.readInstruction());
        const value_reg = args.dest_reg;
        const inst_reg = args.reg;

        const instance: *ObjObjectInstance = ObjObjectInstance.cast(frame.registers[inst_reg].obj()).?;
        const name: *ObjString = self.readString(constant);

        // Set new value
        instance.setField(
            self.gc,
            name,
            frame.registers[value_reg],
        ) catch @panic("Could not set instance property");

        const next_full_instruction = self.readInstruction();
        @call(
            .always_tail,
            dispatch,
            .{
                self,
                self.currentFrame().?,
                next_full_instruction,
                getCode(next_full_instruction),
                getArg(next_full_instruction),
            },
        );
    }

    fn OP_NOT(self: *Self, frame: *CallFrame, instruction: Instruction, _: OpCode, _: FullArg) void {
        const args = getCodeRegReg(instruction);

        frame.registers[args.dest_reg] = Value.fromBoolean(!frame.registers[args.reg].boolean());

        const next_full_instruction = self.readInstruction();
        @call(
            .always_tail,
            dispatch,
            .{
                self,
                self.currentFrame().?,
                next_full_instruction,
                getCode(next_full_instruction),
                getArg(next_full_instruction),
            },
        );
    }

    fn OP_BNOT(self: *Self, frame: *CallFrame, instruction: Instruction, _: OpCode, _: FullArg) void {
        const args = getCodeRegReg(instruction);

        const value = frame.registers[args.reg];

        frame.registers[args.dest_reg] = Value.fromInteger(~(if (value.isInteger()) value.integer() else @floatToInt(i32, value.float())));

        const next_full_instruction = self.readInstruction();
        @call(
            .always_tail,
            dispatch,
            .{
                self,
                self.currentFrame().?,
                next_full_instruction,
                getCode(next_full_instruction),
                getArg(next_full_instruction),
            },
        );
    }

    fn OP_GREATER(self: *Self, frame: *CallFrame, instruction: Instruction, _: OpCode, _: FullArg) void {
        const args = getCodeRegs(instruction);

        const left_value = floatToInteger(frame.registers[args.reg1]);
        const right_value = floatToInteger(frame.registers[args.reg2]);

        const left_f: ?f64 = if (left_value.isFloat()) left_value.float() else null;
        const left_i: ?i32 = if (left_value.isInteger()) left_value.integer() else null;
        const right_f: ?f64 = if (right_value.isFloat()) right_value.float() else null;
        const right_i: ?i32 = if (right_value.isInteger()) right_value.integer() else null;

        if (left_f) |lf| {
            if (right_f) |rf| {
                frame.registers[args.reg3] = Value.fromBoolean(lf > rf);
            } else {
                frame.registers[args.reg3] = Value.fromBoolean(lf > @intToFloat(f64, right_i.?));
            }
        } else {
            if (right_f) |rf| {
                frame.registers[args.reg3] = Value.fromBoolean(@intToFloat(f64, left_i.?) > rf);
            } else {
                frame.registers[args.reg3] = Value.fromBoolean(left_i.? > right_i.?);
            }
        }

        const next_full_instruction = self.readInstruction();
        @call(
            .always_tail,
            dispatch,
            .{
                self,
                self.currentFrame().?,
                next_full_instruction,
                getCode(next_full_instruction),
                getArg(next_full_instruction),
            },
        );
    }

    fn OP_LESS(self: *Self, frame: *CallFrame, instruction: Instruction, _: OpCode, _: FullArg) void {
        const args = getCodeRegs(instruction);

        const left_value = floatToInteger(frame.registers[args.reg1]);
        const right_value = floatToInteger(frame.registers[args.reg2]);

        const left_f: ?f64 = if (left_value.isFloat()) left_value.float() else null;
        const left_i: ?i32 = if (left_value.isInteger()) left_value.integer() else null;
        const right_f: ?f64 = if (right_value.isFloat()) right_value.float() else null;
        const right_i: ?i32 = if (right_value.isInteger()) right_value.integer() else null;

        if (left_f) |lf| {
            if (right_f) |rf| {
                frame.registers[args.reg3] = Value.fromBoolean(lf < rf);
            } else {
                frame.registers[args.reg3] = Value.fromBoolean(lf < @intToFloat(f64, right_i.?));
            }
        } else {
            if (right_f) |rf| {
                frame.registers[args.reg3] = Value.fromBoolean(@intToFloat(f64, left_i.?) < rf);
            } else {
                frame.registers[args.reg3] = Value.fromBoolean(left_i.? < right_i.?);
            }
        }

        const next_full_instruction = self.readInstruction();
        @call(
            .always_tail,
            dispatch,
            .{
                self,
                self.currentFrame().?,
                next_full_instruction,
                getCode(next_full_instruction),
                getArg(next_full_instruction),
            },
        );
    }

    fn OP_ADD_STRING(self: *Self, frame: *CallFrame, instruction: Instruction, _: OpCode, _: FullArg) void {
        const args = getCodeRegs(instruction);

        const left: *ObjString = ObjString.cast(frame.registers[args.reg1].obj()).?;
        const right: *ObjString = ObjString.cast(frame.registers[args.reg2].obj()).?;

        frame.registers[args.reg3] = Value.fromObj(
            (left.concat(self, right) catch @panic("Could not concatenate strings")).toObj(),
        );

        const next_full_instruction = self.readInstruction();
        @call(
            .always_tail,
            dispatch,
            .{
                self,
                self.currentFrame().?,
                next_full_instruction,
                getCode(next_full_instruction),
                getArg(next_full_instruction),
            },
        );
    }

    fn OP_ADD_LIST(self: *Self, frame: *CallFrame, instruction: Instruction, _: OpCode, _: FullArg) void {
        const args = getCodeRegs(instruction);

        const left: *ObjList = ObjList.cast(frame.registers[args.reg1].obj()).?;
        const right: *ObjList = ObjList.cast(frame.registers[args.reg2].obj()).?;

        var new_list = std.ArrayList(Value).init(self.gc.allocator);
        new_list.appendSlice(left.items.items) catch @panic("Could not concatenate lists");
        new_list.appendSlice(right.items.items) catch @panic("Could not concatenate lists");

        frame.registers[args.reg3] =
            (self.gc.allocateObject(ObjList, ObjList{
            .type_def = left.type_def,
            .methods = left.methods,
            .items = new_list,
        }) catch @panic("Could not concatenate lists")).toValue();

        const next_full_instruction = self.readInstruction();
        @call(
            .always_tail,
            dispatch,
            .{
                self,
                self.currentFrame().?,
                next_full_instruction,
                getCode(next_full_instruction),
                getArg(next_full_instruction),
            },
        );
    }

    fn OP_ADD_MAP(self: *Self, frame: *CallFrame, instruction: Instruction, _: OpCode, _: FullArg) void {
        const args = getCodeRegs(instruction);

        const left: *ObjMap = ObjMap.cast(frame.registers[args.reg1].obj()).?;
        const right: *ObjMap = ObjMap.cast(frame.registers[args.reg2].obj()).?;

        var new_map = left.map.clone() catch @panic("Could not concatenate maps");
        var it = right.map.iterator();
        while (it.next()) |entry| {
            new_map.put(entry.key_ptr.*, entry.value_ptr.*) catch @panic("Could not concatenate maps");
        }

        frame.registers[args.reg3] =
            (self.gc.allocateObject(ObjMap, ObjMap{
            .type_def = left.type_def,
            .methods = left.methods,
            .map = new_map,
        }) catch @panic("Could not concatenate maps")).toValue();

        const next_full_instruction = self.readInstruction();
        @call(
            .always_tail,
            dispatch,
            .{
                self,
                self.currentFrame().?,
                next_full_instruction,
                getCode(next_full_instruction),
                getArg(next_full_instruction),
            },
        );
    }

    fn OP_ADD(self: *Self, frame: *CallFrame, instruction: Instruction, _: OpCode, _: FullArg) void {
        const args = getCodeRegs(instruction);

        const left: Value = floatToInteger(frame.registers[args.reg1]);
        const right: Value = floatToInteger(frame.registers[args.reg2]);

        const right_f: ?f64 = if (right.isFloat()) right.float() else null;
        const left_f: ?f64 = if (left.isFloat()) left.float() else null;
        const right_i: ?i32 = if (right.isInteger()) right.integer() else null;
        const left_i: ?i32 = if (left.isInteger()) left.integer() else null;

        if (right_f != null or left_f != null) {
            frame.registers[args.reg3] = Value.fromFloat((left_f orelse @intToFloat(f64, left_i.?)) + (right_f orelse @intToFloat(f64, right_i.?)));
        } else {
            // both integers
            frame.registers[args.reg3] = Value.fromInteger(left_i.? + right_i.?);
        }

        const next_full_instruction = self.readInstruction();
        @call(
            .always_tail,
            dispatch,
            .{
                self,
                self.currentFrame().?,
                next_full_instruction,
                getCode(next_full_instruction),
                getArg(next_full_instruction),
            },
        );
    }

    fn OP_SUBTRACT(self: *Self, frame: *CallFrame, instruction: Instruction, _: OpCode, _: FullArg) void {
        const args = getCodeRegs(instruction);

        const left: Value = floatToInteger(frame.registers[args.reg1]);
        const right: Value = floatToInteger(frame.registers[args.reg2]);

        const right_f: ?f64 = if (right.isFloat()) right.float() else null;
        const left_f: ?f64 = if (left.isFloat()) left.float() else null;
        const right_i: ?i32 = if (right.isInteger()) right.integer() else null;
        const left_i: ?i32 = if (left.isInteger()) left.integer() else null;

        if (right_f != null or left_f != null) {
            frame.registers[args.reg3] = Value.fromFloat((left_f orelse @intToFloat(f64, left_i.?)) - (right_f orelse @intToFloat(f64, right_i.?)));
        } else {
            frame.registers[args.reg3] = Value.fromInteger(left_i.? - right_i.?);
        }

        const next_full_instruction = self.readInstruction();
        @call(
            .always_tail,
            dispatch,
            .{
                self,
                self.currentFrame().?,
                next_full_instruction,
                getCode(next_full_instruction),
                getArg(next_full_instruction),
            },
        );
    }

    fn OP_MULTIPLY(self: *Self, frame: *CallFrame, instruction: Instruction, _: OpCode, _: FullArg) void {
        const args = getCodeRegs(instruction);

        const left: Value = floatToInteger(frame.registers[args.reg1]);
        const right: Value = floatToInteger(frame.registers[args.reg2]);

        const right_f: ?f64 = if (right.isFloat()) right.float() else null;
        const left_f: ?f64 = if (left.isFloat()) left.float() else null;
        const right_i: ?i32 = if (right.isInteger()) right.integer() else null;
        const left_i: ?i32 = if (left.isInteger()) left.integer() else null;

        if (right_f != null or left_f != null) {
            frame.registers[args.reg3] = Value.fromFloat((left_f orelse @intToFloat(f64, left_i.?)) * (right_f orelse @intToFloat(f64, right_i.?)));
        } else {
            frame.registers[args.reg3] = Value.fromInteger(left_i.? * right_i.?);
        }

        const next_full_instruction = self.readInstruction();
        @call(
            .always_tail,
            dispatch,
            .{
                self,
                self.currentFrame().?,
                next_full_instruction,
                getCode(next_full_instruction),
                getArg(next_full_instruction),
            },
        );
    }

    fn OP_DIVIDE(self: *Self, frame: *CallFrame, instruction: Instruction, _: OpCode, _: FullArg) void {
        const args = getCodeRegs(instruction);

        const left: Value = floatToInteger(frame.registers[args.reg1]);
        const right: Value = floatToInteger(frame.registers[args.reg2]);

        const right_f: ?f64 = if (right.isFloat()) right.float() else null;
        const left_f: ?f64 = if (left.isFloat()) left.float() else null;
        const right_i: ?i32 = if (right.isInteger()) right.integer() else null;
        const left_i: ?i32 = if (left.isInteger()) left.integer() else null;

        frame.registers[args.reg3] =
            Value.fromFloat((left_f orelse @intToFloat(f64, left_i.?)) / (right_f orelse @intToFloat(f64, right_i.?)));

        const next_full_instruction = self.readInstruction();
        @call(
            .always_tail,
            dispatch,
            .{
                self,
                self.currentFrame().?,
                next_full_instruction,
                getCode(next_full_instruction),
                getArg(next_full_instruction),
            },
        );
    }

    fn OP_MOD(self: *Self, frame: *CallFrame, instruction: Instruction, _: OpCode, _: FullArg) void {
        const args = getCodeRegs(instruction);

        const left: Value = floatToInteger(frame.registers[args.reg1]);
        const right: Value = floatToInteger(frame.registers[args.reg2]);

        const right_f: ?f64 = if (right.isFloat()) right.float() else null;
        const left_f: ?f64 = if (left.isFloat()) left.float() else null;
        const right_i: ?i32 = if (right.isInteger()) right.integer() else null;
        const left_i: ?i32 = if (left.isInteger()) left.integer() else null;

        if (right_f != null or left_f != null) {
            frame.registers[args.reg3] = Value.fromFloat(@mod((left_f orelse @intToFloat(f64, left_i.?)), (right_f orelse @intToFloat(f64, right_i.?))));
        } else {
            frame.registers[args.reg3] = Value.fromInteger(@mod(left_i.?, right_i.?));
        }

        const next_full_instruction = self.readInstruction();
        @call(
            .always_tail,
            dispatch,
            .{
                self,
                self.currentFrame().?,
                next_full_instruction,
                getCode(next_full_instruction),
                getArg(next_full_instruction),
            },
        );
    }

    fn OP_BAND(self: *Self, frame: *CallFrame, instruction: Instruction, _: OpCode, _: FullArg) void {
        const args = getCodeRegs(instruction);

        const left: Value = floatToInteger(frame.registers[args.reg1]);
        const right: Value = floatToInteger(frame.registers[args.reg2]);

        const right_f: ?f64 = if (right.isFloat()) right.float() else null;
        const left_f: ?f64 = if (left.isFloat()) left.float() else null;
        const right_i: ?i32 = if (right.isInteger()) right.integer() else null;
        const left_i: ?i32 = if (left.isInteger()) left.integer() else null;

        frame.registers[args.reg3] = Value.fromInteger((left_i orelse @floatToInt(i32, left_f.?)) & (right_i orelse @floatToInt(i32, right_f.?)));

        const next_full_instruction = self.readInstruction();
        @call(
            .always_tail,
            dispatch,
            .{
                self,
                self.currentFrame().?,
                next_full_instruction,
                getCode(next_full_instruction),
                getArg(next_full_instruction),
            },
        );
    }

    fn OP_BOR(self: *Self, frame: *CallFrame, instruction: Instruction, _: OpCode, _: FullArg) void {
        const args = getCodeRegs(instruction);

        const left: Value = floatToInteger(frame.registers[args.reg1]);
        const right: Value = floatToInteger(frame.registers[args.reg2]);

        const right_f: ?f64 = if (right.isFloat()) right.float() else null;
        const left_f: ?f64 = if (left.isFloat()) left.float() else null;
        const right_i: ?i32 = if (right.isInteger()) right.integer() else null;
        const left_i: ?i32 = if (left.isInteger()) left.integer() else null;

        frame.registers[args.reg3] = Value.fromInteger((left_i orelse @floatToInt(i32, left_f.?)) | (right_i orelse @floatToInt(i32, right_f.?)));

        const next_full_instruction = self.readInstruction();
        @call(
            .always_tail,
            dispatch,
            .{
                self,
                self.currentFrame().?,
                next_full_instruction,
                getCode(next_full_instruction),
                getArg(next_full_instruction),
            },
        );
    }

    fn OP_XOR(self: *Self, frame: *CallFrame, instruction: Instruction, _: OpCode, _: FullArg) void {
        const args = getCodeRegs(instruction);

        const left: Value = floatToInteger(frame.registers[args.reg1]);
        const right: Value = floatToInteger(frame.registers[args.reg2]);

        const right_f: ?f64 = if (right.isFloat()) right.float() else null;
        const left_f: ?f64 = if (left.isFloat()) left.float() else null;
        const right_i: ?i32 = if (right.isInteger()) right.integer() else null;
        const left_i: ?i32 = if (left.isInteger()) left.integer() else null;

        frame.registers[args.reg3] = Value.fromInteger((left_i orelse @floatToInt(i32, left_f.?)) ^ (right_i orelse @floatToInt(i32, right_f.?)));

        const next_full_instruction = self.readInstruction();
        @call(
            .always_tail,
            dispatch,
            .{
                self,
                self.currentFrame().?,
                next_full_instruction,
                getCode(next_full_instruction),
                getArg(next_full_instruction),
            },
        );
    }

    fn OP_SHL(self: *Self, frame: *CallFrame, instruction: Instruction, _: OpCode, _: FullArg) void {
        const args = getCodeRegs(instruction);

        const left: Value = floatToInteger(frame.registers[args.reg1]);
        const right: Value = floatToInteger(frame.registers[args.reg2]);

        const right_f: ?f64 = if (right.isFloat()) right.float() else null;
        const left_f: ?f64 = if (left.isFloat()) left.float() else null;
        const right_i: ?i32 = if (right.isInteger()) right.integer() else null;
        const left_i: ?i32 = if (left.isInteger()) left.integer() else null;
        const b = right_i orelse @floatToInt(i32, right_f.?);

        if (b < 0) {
            if (b * -1 > std.math.maxInt(u5)) {
                frame.registers[args.reg3] = Value.fromInteger(0);
            } else {
                frame.registers[args.reg3] = Value.fromInteger((left_i orelse @floatToInt(i32, left_f.?)) >> @truncate(u5, @intCast(u64, b * -1)));
            }
        } else {
            if (b > std.math.maxInt(u5)) {
                frame.registers[args.reg3] = Value.fromInteger(0);
            } else {
                frame.registers[args.reg3] = Value.fromInteger((left_i orelse @floatToInt(i32, left_f.?)) << @truncate(u5, @intCast(u64, b)));
            }
        }

        const next_full_instruction = self.readInstruction();
        @call(
            .always_tail,
            dispatch,
            .{
                self,
                self.currentFrame().?,
                next_full_instruction,
                getCode(next_full_instruction),
                getArg(next_full_instruction),
            },
        );
    }

    fn OP_SHR(self: *Self, frame: *CallFrame, instruction: Instruction, _: OpCode, _: FullArg) void {
        const args = getCodeRegs(instruction);

        const left: Value = floatToInteger(frame.registers[args.reg1]);
        const right: Value = floatToInteger(frame.registers[args.reg2]);

        const right_f: ?f64 = if (right.isFloat()) right.float() else null;
        const left_f: ?f64 = if (left.isFloat()) left.float() else null;
        const right_i: ?i32 = if (right.isInteger()) right.integer() else null;
        const left_i: ?i32 = if (left.isInteger()) left.integer() else null;
        const b = right_i orelse @floatToInt(i32, right_f.?);

        if (b < 0) {
            if (b * -1 > std.math.maxInt(u5)) {
                frame.registers[args.reg3] = Value.fromInteger(0);
            } else {
                frame.registers[args.reg3] = Value.fromInteger((left_i orelse @floatToInt(i32, left_f.?)) << @truncate(u5, @intCast(u64, b * -1)));
            }
        } else {
            if (b > std.math.maxInt(u5)) {
                frame.registers[args.reg3] = Value.fromInteger(0);
            } else {
                frame.registers[args.reg3] = Value.fromInteger((left_i orelse @floatToInt(i32, left_f.?)) >> @truncate(u5, @intCast(u64, b)));
            }
        }

        const next_full_instruction = self.readInstruction();
        @call(
            .always_tail,
            dispatch,
            .{
                self,
                self.currentFrame().?,
                next_full_instruction,
                getCode(next_full_instruction),
                getArg(next_full_instruction),
            },
        );
    }

    fn OP_EQUAL(self: *Self, frame: *CallFrame, instruction: Instruction, _: OpCode, _: FullArg) void {
        const args = getCodeRegs(instruction);

        frame.registers[args.reg3] = Value.fromBoolean(
            valueEql(
                frame.registers[args.reg1],
                frame.registers[args.reg2],
            ),
        );

        const next_full_instruction = self.readInstruction();
        @call(
            .always_tail,
            dispatch,
            .{
                self,
                self.currentFrame().?,
                next_full_instruction,
                getCode(next_full_instruction),
                getArg(next_full_instruction),
            },
        );
    }

    fn OP_IS(self: *Self, frame: *CallFrame, instruction: Instruction, _: OpCode, _: FullArg) void {
        const args = getCodeRegs(instruction);

        frame.registers[args.reg3] = Value.fromBoolean(
            valueIs(
                frame.registers[args.reg2],
                frame.registers[args.reg1],
            ),
        );

        const next_full_instruction = self.readInstruction();
        @call(
            .always_tail,
            dispatch,
            .{
                self,
                self.currentFrame().?,
                next_full_instruction,
                getCode(next_full_instruction),
                getArg(next_full_instruction),
            },
        );
    }

    fn OP_JUMP(self: *Self, current_frame: *CallFrame, _: Instruction, _: OpCode, arg: FullArg) void {
        current_frame.ip += arg;

        const next_full_instruction = self.readInstruction();
        @call(
            .always_tail,
            dispatch,
            .{
                self,
                self.currentFrame().?,
                next_full_instruction,
                getCode(next_full_instruction),
                getArg(next_full_instruction),
            },
        );
    }

    fn OP_JUMP_IF_FALSE(self: *Self, frame: *CallFrame, _: Instruction, _: OpCode, arg: FullArg) void {
        const cond_reg = @intCast(Reg, self.readInstruction());

        if (!frame.registers[cond_reg].boolean()) {
            frame.ip += arg;
        }

        const next_full_instruction = self.readInstruction();
        @call(
            .always_tail,
            dispatch,
            .{
                self,
                self.currentFrame().?,
                next_full_instruction,
                getCode(next_full_instruction),
                getArg(next_full_instruction),
            },
        );
    }

    fn OP_JUMP_IF_NOT_NULL(self: *Self, frame: *CallFrame, _: Instruction, _: OpCode, arg: FullArg) void {
        const cond_reg = @intCast(Reg, self.readInstruction());

        if (!frame.registers[cond_reg].isNull()) {
            frame.ip += arg;
        }

        const next_full_instruction = self.readInstruction();
        @call(
            .always_tail,
            dispatch,
            .{
                self,
                self.currentFrame().?,
                next_full_instruction,
                getCode(next_full_instruction),
                getArg(next_full_instruction),
            },
        );
    }

    fn OP_LOOP(self: *Self, frame: *CallFrame, _: Instruction, _: OpCode, arg: FullArg) void {
        frame.ip -= arg;

        const next_full_instruction = self.readInstruction();
        @call(
            .always_tail,
            dispatch,
            .{
                self,
                self.currentFrame().?,
                next_full_instruction,
                getCode(next_full_instruction),
                getArg(next_full_instruction),
            },
        );
    }

    fn OP_STRING_FOREACH(self: *Self, _: *CallFrame, _: Instruction, _: OpCode, _: FullArg) void {
        const key_slot: *Value = @ptrCast(*Value, self.current_fiber.stack_top - 3);
        const value_slot: *Value = @ptrCast(*Value, self.current_fiber.stack_top - 2);
        const str: *ObjString = ObjString.cast(self.peek(0).obj()).?;

        key_slot.* = if (str.next(self, if (key_slot.*.isNull()) null else key_slot.integer()) catch @panic("Could not get next char from string")) |new_index|
            Value.fromInteger(new_index)
        else
            Value.Null;

        // Set new value
        if (key_slot.*.isInteger()) {
            value_slot.* = (self.gc.copyString(&([_]u8{str.string[@intCast(usize, key_slot.integer())]})) catch @panic("Could not get next char from string")).toValue();
        }

        const next_full_instruction = self.readInstruction();
        @call(
            .always_tail,
            dispatch,
            .{
                self,
                self.currentFrame().?,
                next_full_instruction,
                getCode(next_full_instruction),
                getArg(next_full_instruction),
            },
        );
    }

    fn OP_LIST_FOREACH(self: *Self, _: *CallFrame, _: Instruction, _: OpCode, _: FullArg) void {
        const key_slot: *Value = @ptrCast(*Value, self.current_fiber.stack_top - 3);
        const value_slot: *Value = @ptrCast(*Value, self.current_fiber.stack_top - 2);
        const list: *ObjList = ObjList.cast(self.peek(0).obj()).?;

        // Get next index
        key_slot.* = if (list.rawNext(
            self,
            if (key_slot.*.isNull()) null else key_slot.integer(),
        ) catch @panic("Could not get next element from list")) |new_index|
            Value.fromInteger(new_index)
        else
            Value.Null;

        // Set new value
        if (key_slot.*.isInteger()) {
            value_slot.* = list.items.items[@intCast(usize, key_slot.integer())];
        }

        const next_full_instruction = self.readInstruction();
        @call(
            .always_tail,
            dispatch,
            .{
                self,
                self.currentFrame().?,
                next_full_instruction,
                getCode(next_full_instruction),
                getArg(next_full_instruction),
            },
        );
    }

    fn OP_ENUM_FOREACH(self: *Self, _: *CallFrame, _: Instruction, _: OpCode, _: FullArg) void {
        const value_slot: *Value = @ptrCast(*Value, self.current_fiber.stack_top - 2);
        const enum_case: ?*ObjEnumInstance = if (value_slot.*.isNull()) null else ObjEnumInstance.cast(value_slot.obj()).?;
        const enum_: *ObjEnum = ObjEnum.cast(self.peek(0).obj()).?;

        // Get next enum case
        const next_case: ?*ObjEnumInstance = enum_.rawNext(self, enum_case) catch @panic("Could not get next case from enum");
        value_slot.* = (if (next_case) |new_case| Value.fromObj(new_case.toObj()) else Value.Null);

        const next_full_instruction = self.readInstruction();
        @call(
            .always_tail,
            dispatch,
            .{
                self,
                self.currentFrame().?,
                next_full_instruction,
                getCode(next_full_instruction),
                getArg(next_full_instruction),
            },
        );
    }

    fn OP_MAP_FOREACH(self: *Self, _: *CallFrame, _: Instruction, _: OpCode, _: FullArg) void {
        const key_slot: *Value = @ptrCast(*Value, self.current_fiber.stack_top - 3);
        const value_slot: *Value = @ptrCast(*Value, self.current_fiber.stack_top - 2);
        const map: *ObjMap = ObjMap.cast(self.peek(0).obj()).?;
        const current_key: ?Value = if (!key_slot.*.isNull()) key_slot.* else null;

        var next_key: ?Value = map.rawNext(current_key);
        key_slot.* = if (next_key) |unext_key| unext_key else Value.Null;

        if (next_key) |unext_key| {
            value_slot.* = map.map.get(unext_key) orelse Value.Null;
        }

        const next_full_instruction = self.readInstruction();
        @call(
            .always_tail,
            dispatch,
            .{
                self,
                self.currentFrame().?,
                next_full_instruction,
                getCode(next_full_instruction),
                getArg(next_full_instruction),
            },
        );
    }

    fn OP_FIBER_FOREACH(self: *Self, _: *CallFrame, _: Instruction, _: OpCode, _: FullArg) void {
        const value_slot: *Value = @ptrCast(*Value, self.current_fiber.stack_top - 2);
        const fiber = ObjFiber.cast(self.peek(0).obj()).?;

        if (fiber.fiber.status == .Over) {
            value_slot.* = Value.Null;
        } else {
            fiber.fiber.resume_(self, null, null) catch @panic("Could not resume fiber");
        }

        const next_full_instruction = self.readInstruction();
        @call(
            .always_tail,
            dispatch,
            .{
                self,
                self.currentFrame().?,
                next_full_instruction,
                getCode(next_full_instruction),
                getArg(next_full_instruction),
            },
        );
    }

    fn OP_UNWRAP(self: *Self, frame: *CallFrame, _: Instruction, _: OpCode, arg: FullArg) void {
        if (frame.registers[arg].isNull()) {
            self.throw(
                Error.UnwrappedNull,
                (self.gc.copyString("Force unwrapped optional is null") catch @panic("Could not raise error")).toValue(),
            ) catch @panic("Could not raise error");
        }

        const next_full_instruction = self.readInstruction();
        @call(
            .always_tail,
            dispatch,
            .{
                self,
                self.currentFrame().?,
                next_full_instruction,
                getCode(next_full_instruction),
                getArg(next_full_instruction),
            },
        );
    }

    pub fn run(self: *Self) void {
        const next_current_frame: *CallFrame = self.currentFrame().?;
        const next_full_instruction = self.readInstruction();
        const next_instruction: OpCode = getCode(next_full_instruction);
        const next_arg: FullArg = getArg(next_full_instruction);

        if (BuildOptions.debug_current_instruction) {
            std.debug.print(
                "{}: {} {x}\n",
                .{
                    next_current_frame.ip,
                    next_instruction,
                    next_full_instruction,
                },
            );
            dumpStack(self);
            dumpRegisters(self);
        }

        op_table[@enumToInt(next_instruction)](
            self,
            next_current_frame,
            next_full_instruction,
            next_instruction,
            next_arg,
        );
    }

    pub fn throw(self: *Self, code: Error, payload: Value) MIRJIT.Error!void {
        var stack = std.ArrayList(CallFrame).init(self.gc.allocator);
        defer stack.deinit();

        while (self.current_fiber.frame_count > 0 or self.current_fiber.parent_fiber != null) {
            const frame = self.currentFrame();
            // Pop the frame
            if (self.current_fiber.frame_count > 0) {
                try stack.append(frame.?.*);

                // Are we in a try-catch?
                if (frame.?.try_ip) |try_ip| {
                    // Push error and jump to start of the catch clauses
                    self.push(payload);

                    frame.?.ip = try_ip;

                    return;
                }

                // Pop frame
                self.closeUpValues(&frame.?.slots[0]);
                self.current_fiber.frame_count -= 1;
                _ = self.current_fiber.frames.pop();
            }

            if (self.current_fiber.frame_count == 0 and self.current_fiber.parent_fiber == null) {
                // No more frames, the error is uncaught.
                _ = self.pop();

                // Raise the runtime error
                // If object instance, does it have a str `message` field ?
                var processed_payload = payload;
                if (payload.isObj()) {
                    if (ObjObjectInstance.cast(payload.obj())) |instance| {
                        processed_payload = instance.fields.get(try self.gc.copyString("message")) orelse payload;
                    }
                }

                const value_str = try valueToStringAlloc(self.gc.allocator, processed_payload);
                defer value_str.deinit();
                std.debug.print("\n\u{001b}[31mError: {s}\u{001b}[0m\n", .{value_str.items});

                for (stack.items) |stack_frame| {
                    std.debug.print(
                        "\tat {s} in {s}",
                        .{
                            stack_frame.closure.function.name.string,
                            stack_frame.closure.function.type_def.resolved_type.?.Function.script_name.string,
                        },
                    );
                    if (stack_frame.call_site) |call_site| {
                        std.debug.print(":{}\n", .{call_site + 1});
                    } else {
                        std.debug.print("\n", .{});
                    }
                }

                std.os.exit(1);
            } else if (self.current_fiber.frame_count == 0) {
                // Error raised inside a fiber, forward it to parent fiber
                self.current_fiber = self.current_fiber.parent_fiber.?;

                try self.throw(code, payload);

                return;
            }

            if (frame != null) {
                self.current_fiber.stack_top = frame.?.slots;

                if (frame.?.error_value) |error_value| {
                    // Push error_value as failed function return value
                    if (frame.?.result_register) |result_register| {
                        self.currentFrame().?.registers[result_register] = error_value;
                    } else {
                        self.push(error_value);
                    }

                    return;
                }
            }
        }
    }

    // FIXME: catch_values should be on the stack like arguments
    fn call(
        self: *Self,
        closure: *ObjClosure,
        arg_count: u8,
        catch_value: ?Value,
        in_fiber: bool,
        dest_register: ?Reg,
    ) MIRJIT.Error!void {
        closure.function.call_count += 1;

        var native = closure.function.native;
        if (self.mir_jit) |*mir_jit| {
            mir_jit.call_count += 1;
            // Do we need to jit the function?
            // TODO: figure out threshold strategy
            if (!in_fiber and self.shouldCompileFunction(closure)) {
                var timer = std.time.Timer.start() catch unreachable;

                var success = true;
                mir_jit.compileFunction(closure) catch |err| {
                    if (err == MIRJIT.Error.CantCompile) {
                        success = false;
                    } else {
                        return err;
                    }
                };

                if (BuildOptions.jit_debug and success) {
                    std.debug.print(
                        "Compiled function `{s}` in {d} ms\n",
                        .{
                            closure.function.type_def.resolved_type.?.Function.name.string,
                            @intToFloat(f64, timer.read()) / 1000000,
                        },
                    );
                }

                mir_jit.jit_time += timer.read();

                if (success) {
                    native = closure.function.native;
                }
            }
        }

        // Is there a compiled version of it?
        if (!in_fiber and native != null) {
            if (BuildOptions.jit_debug) {
                std.debug.print("Calling compiled version of function `{s}`\n", .{closure.function.name.string});
            }

            try self.callCompiled(
                closure,
                @ptrCast(
                    NativeFn,
                    @alignCast(
                        @alignOf(Native),
                        native.?,
                    ),
                ),
                arg_count,
                catch_value,
                dest_register,
            );

            return;
        }

        // TODO: check for stack overflow
        var frame = CallFrame{
            .closure = closure,
            .ip = 0,
            // -1 is because we reserve slot 0 for this
            .slots = self.current_fiber.stack_top - arg_count - 1,
            .call_site = if (self.currentFrame()) |current_frame|
                current_frame.closure.function.chunk.lines.items[current_frame.ip - 1]
            else
                null,
            .result_register = dest_register,
            .registers = [_]Value{Value.Void} ** 255,
        };

        frame.error_value = catch_value;

        if (self.current_fiber.frames.items.len <= self.current_fiber.frame_count) {
            try self.current_fiber.frames.append(frame);
        } else {
            self.current_fiber.frames.items[self.current_fiber.frame_count] = frame;
        }

        self.current_fiber.frame_count += 1;

        if (BuildOptions.jit_debug) {
            std.debug.print("Calling uncompiled version of function `{s}`\n", .{closure.function.name.string});
        }
    }

    fn callNative(
        self: *Self,
        closure: ?*ObjClosure,
        native: NativeFn,
        arg_count: u8,
        catch_value: ?Value,
        dest_register: ?Reg,
    ) !void {
        self.currentFrame().?.in_native_call = true;

        var result: Value = Value.Null;
        const native_return = native(
            &NativeCtx{
                .vm = self,
                .globals = if (closure) |uclosure| uclosure.globals.items.ptr else &[_]Value{},
                .upvalues = if (closure) |uclosure| uclosure.upvalues.items.ptr else &[_]*ObjUpValue{},
                .base = self.current_fiber.stack_top - arg_count - 1,
                .stack_top = &self.current_fiber.stack_top,
            },
        );

        self.currentFrame().?.in_native_call = false;

        if (native_return == 1 or native_return == 0) {
            if (native_return == 1) {
                result = self.pop();
            }

            self.current_fiber.stack_top = self.current_fiber.stack_top - arg_count - 1;

            if (dest_register) |dest_reg| {
                self.currentFrame().?.registers[dest_reg] = result;
            } else {
                self.push(result);
            }
        } else {
            // An error occured within the native function -> call error handlers
            if (catch_value != null) {
                // We discard the error
                _ = self.pop();

                // Default value in case of error
                self.current_fiber.stack_top = self.current_fiber.stack_top - arg_count - 1;
                if (dest_register) |dest_reg| {
                    self.currentFrame().?.registers[dest_reg] = catch_value.?;
                } else {
                    self.push(catch_value.?);
                }
                return;
            }

            // Error was not handled are we in a try-catch ?
            var frame = self.currentFrame().?;
            if (frame.try_ip) |try_ip| {
                frame.ip = try_ip;
            } else {
                // No error handler or default value was triggered so forward the error
                try self.throw(Error.Custom, self.peek(0));
            }
        }
    }

    // A JIT compiled function pops its stack on its own
    fn callCompiled(
        self: *Self,
        closure: ?*ObjClosure,
        native: NativeFn,
        arg_count: u8,
        catch_value: ?Value,
        dest_register: ?Reg,
    ) !void {
        if (self.currentFrame()) |frame| {
            frame.in_native_call = true;
        }

        const native_return = native(
            &NativeCtx{
                .vm = self,
                .globals = if (closure) |uclosure| uclosure.globals.items.ptr else &[_]Value{},
                .upvalues = if (closure) |uclosure| uclosure.upvalues.items.ptr else &[_]*ObjUpValue{},
                .base = self.current_fiber.stack_top - arg_count - 1,
                .stack_top = &self.current_fiber.stack_top,
            },
        );

        if (self.currentFrame()) |frame| {
            frame.in_native_call = false;
        }

        if (native_return == -1) {
            // An error occured within the native function -> call error handlers
            if (catch_value != null) {
                // We discard the error
                _ = self.pop();

                // Default value in case of error
                if (dest_register) |dest_reg| {
                    self.currentFrame().?.registers[dest_reg] = catch_value.?;
                } else {
                    self.push(catch_value.?);
                }
                return;
            }

            // Error was not handled are we in a try-catch ?
            if (self.currentFrame() != null and self.currentFrame().?.try_ip != null) {
                self.currentFrame().?.ip = self.currentFrame().?.try_ip.?;
            } else {
                // No error handler or default value was triggered so forward the error
                try self.throw(Error.Custom, self.peek(0));
            }
        } else if (native_return == 1) {
            if (dest_register) |dest_reg| {
                self.currentFrame().?.registers[dest_reg] = self.pop();
            }
        }
    }

    fn bindMethod(self: *Self, method: ?*ObjClosure, native: ?*ObjNative, receiver: Value, dest: Reg) !void {
        var bound: *ObjBoundMethod = try self.gc.allocateObject(ObjBoundMethod, .{
            .receiver = receiver,
            .closure = method,
            .native = native,
        });

        self.currentFrame().?.registers[dest] = Value.fromObj(bound.toObj());
    }

    pub fn callValue(
        self: *Self,
        callee: Value,
        arg_count: u8,
        catch_value: ?Value,
        in_fiber: bool,
        dest_register: ?Reg,
    ) MIRJIT.Error!void {
        var obj: *Obj = callee.obj();
        switch (obj.obj_type) {
            .Bound => {
                var bound: *ObjBoundMethod = ObjBoundMethod.cast(obj).?;
                (self.current_fiber.stack_top - arg_count - 1)[0] = bound.receiver;

                if (bound.closure) |closure| {
                    return try self.call(
                        closure,
                        arg_count,
                        catch_value,
                        in_fiber,
                        dest_register,
                    );
                } else {
                    assert(bound.native != null);
                    return try self.callNative(
                        null,
                        @ptrCast(NativeFn, @alignCast(@alignOf(NativeFn), bound.native.?.native)),
                        arg_count,
                        catch_value,
                        dest_register,
                    );
                }
            },
            .Closure => {
                return try self.call(
                    ObjClosure.cast(obj).?,
                    arg_count,
                    catch_value,
                    in_fiber,
                    dest_register,
                );
            },
            .Native => {
                return try self.callNative(
                    null,
                    @ptrCast(NativeFn, @alignCast(@alignOf(Native), ObjNative.cast(obj).?.native)),
                    arg_count,
                    catch_value,
                    dest_register,
                );
            },
            else => unreachable,
        }
    }

    fn invokeFromObject(
        self: *Self,
        object: *ObjObject,
        name: *ObjString,
        arg_count: u8,
        catch_value: ?Value,
        in_fiber: bool,
        dest_register: ?Reg,
    ) !void {
        if (object.methods.get(name)) |method| {
            return self.call(
                method,
                arg_count,
                catch_value,
                in_fiber,
                dest_register,
            );
        } else {
            unreachable;
        }
    }

    // FIXME: find way to remove
    fn invoke(
        self: *Self,
        name: *ObjString,
        arg_count: u8,
        catch_value: ?Value,
        in_fiber: bool,
        dest_register: ?Reg,
    ) !void {
        var receiver: Value = self.peek(arg_count);

        var obj: *Obj = receiver.obj();
        switch (obj.obj_type) {
            .ObjectInstance => {
                var instance: *ObjObjectInstance = ObjObjectInstance.cast(obj).?;

                assert(instance.object != null);

                if (instance.fields.get(name)) |field| {
                    (self.current_fiber.stack_top - arg_count - 1)[0] = field;

                    return try self.callValue(
                        field,
                        arg_count,
                        catch_value,
                        in_fiber,
                        dest_register,
                    );
                }

                try self.invokeFromObject(
                    instance.object.?,
                    name,
                    arg_count,
                    catch_value,
                    in_fiber,
                    dest_register,
                );
            },
            .String => {
                if (try ObjString.member(self, name)) |member| {
                    var member_value: Value = member.toValue();
                    (self.current_fiber.stack_top - arg_count - 1)[0] = member_value;

                    return try self.callValue(
                        member_value,
                        arg_count,
                        catch_value,
                        in_fiber,
                        dest_register,
                    );
                }

                unreachable;
            },
            .Pattern => {
                if (try ObjPattern.member(self, name)) |member| {
                    var member_value: Value = member.toValue();
                    (self.current_fiber.stack_top - arg_count - 1)[0] = member_value;

                    return try self.callValue(
                        member_value,
                        arg_count,
                        catch_value,
                        in_fiber,
                        dest_register,
                    );
                }

                unreachable;
            },
            .Fiber => {
                if (try ObjFiber.member(self, name)) |member| {
                    var member_value: Value = member.toValue();
                    (self.current_fiber.stack_top - arg_count - 1)[0] = member_value;

                    return try self.callValue(
                        member_value,
                        arg_count,
                        catch_value,
                        in_fiber,
                        dest_register,
                    );
                }

                unreachable;
            },
            .List => {
                var list: *ObjList = ObjList.cast(obj).?;

                if (try list.member(self, name)) |member| {
                    var member_value: Value = member.toValue();
                    (self.current_fiber.stack_top - arg_count - 1)[0] = member_value;

                    return try self.callValue(
                        member_value,
                        arg_count,
                        catch_value,
                        in_fiber,
                        dest_register,
                    );
                }

                unreachable;
            },
            .Map => {
                var map: *ObjMap = ObjMap.cast(obj).?;

                if (try map.member(self, name)) |member| {
                    var member_value: Value = member.toValue();
                    (self.current_fiber.stack_top - arg_count - 1)[0] = member_value;

                    return try self.callValue(
                        member_value,
                        arg_count,
                        catch_value,
                        in_fiber,
                        dest_register,
                    );
                }

                unreachable;
            },
            else => unreachable,
        }
    }

    pub fn closeUpValues(self: *Self, last: *Value) void {
        while (self.current_fiber.open_upvalues != null and @ptrToInt(self.current_fiber.open_upvalues.?.location) >= @ptrToInt(last)) {
            var upvalue: *ObjUpValue = self.current_fiber.open_upvalues.?;
            upvalue.closed = upvalue.location.*;
            upvalue.location = &upvalue.closed.?;
            self.current_fiber.open_upvalues = upvalue.next;
        }
    }

    pub fn captureUpvalue(self: *Self, local: *Value) !*ObjUpValue {
        var prev_upvalue: ?*ObjUpValue = null;
        var upvalue: ?*ObjUpValue = self.current_fiber.open_upvalues;
        while (upvalue != null and @ptrToInt(upvalue.?.location) > @ptrToInt(local)) {
            prev_upvalue = upvalue;
            upvalue = upvalue.?.next;
        }

        if (upvalue != null and upvalue.?.location == local) {
            return upvalue.?;
        }

        var created_upvalue: *ObjUpValue = try self.gc.allocateObject(
            ObjUpValue,
            ObjUpValue.init(local),
        );
        created_upvalue.next = upvalue;

        if (prev_upvalue) |uprev_upvalue| {
            uprev_upvalue.next = created_upvalue;
        } else {
            self.current_fiber.open_upvalues = created_upvalue;
        }

        return created_upvalue;
    }

    fn shouldCompileFunction(self: *Self, closure: *ObjClosure) bool {
        const function_type = closure.function.type_def.resolved_type.?.Function.function_type;

        if (function_type == .Extern or function_type == .Script or function_type == .ScriptEntryPoint or function_type == .EntryPoint) {
            return false;
        }

        if (self.mir_jit != null and (self.mir_jit.?.compiled_closures.get(closure) != null or self.mir_jit.?.blacklisted_closures.get(closure) != null)) {
            return false;
        }

        const function_node = @ptrCast(*FunctionNode, @alignCast(@alignOf(FunctionNode), closure.function.node));
        const user_hot = function_node.node.docblock != null and std.mem.indexOf(u8, function_node.node.docblock.?.lexeme, "@hot") != null;

        return if (BuildOptions.jit_debug_on)
            return true
        else
            (BuildOptions.jit_debug and user_hot) or (closure.function.call_count > 10 and (@intToFloat(f128, closure.function.call_count) / @intToFloat(f128, self.mir_jit.?.call_count)) > BuildOptions.jit_prof_threshold);
    }
};
