const std = @import("std");
const print = std.debug.print;
const _chunk = @import("./chunk.zig");
const _value = @import("./value.zig");
const _obj = @import("./obj.zig");
const _vm = @import("./vm.zig");

const VM = _vm.VM;
const Chunk = _chunk.Chunk;
const OpCode = _chunk.OpCode;
const ObjFunction = _obj.ObjFunction;
const Arg = _chunk.Arg;
const FullArg = _chunk.FullArg;
const Reg = _chunk.Reg;
const Code = _chunk.Code;
const Instruction = _chunk.Instruction;

pub fn disassembleChunk(chunk: *Chunk, name: []const u8) void {
    print("\u{001b}[2m", .{}); // Dimmed
    print("=== {s} ===\n", .{name});

    var offset: usize = 0;
    while (offset < chunk.code.items.len) {
        offset = disassembleInstruction(chunk, offset);
    }
    print("\u{001b}[0m", .{});
}

fn invokeInstruction(code: OpCode, chunk: *Chunk, offset: usize) usize {
    const instruction = chunk.code.items[offset];
    const constant = @intCast(Arg, (0x01ffffff & instruction) >> @bitSizeOf(Reg));
    const reg = @intCast(Reg, 0x000000ff & instruction);
    const arg_instruction = chunk.code.items[offset + 1];
    const arg_count = @truncate(u8, arg_instruction >> 16);
    const catch_count = 0x0000ffff & arg_instruction;

    var value_str = _value.valueToStringAlloc(std.heap.c_allocator, chunk.constants.items[constant]) catch unreachable;
    defer value_str.deinit();

    print("{}\t{} {s}({} args, {} catches)", .{
        code,
        reg,
        value_str.items[0..std.math.min(value_str.items.len, 100)],
        arg_count,
        catch_count,
    });

    return offset + 2;
}

fn codeArgInstruction(code: OpCode, chunk: *Chunk, offset: usize) usize {
    const instruction = chunk.code.items[offset];
    const arg = @intCast(FullArg, 0x01ffffff & instruction);

    print("{}\t{}", .{ code, arg });

    return offset + 1;
}

fn codeConstantRegsInstruction(code: OpCode, chunk: *Chunk, offset: usize) usize {
    const instruction = chunk.code.items[offset];
    const reg = @truncate(Reg, (0x01ffffff & instruction) >> @bitSizeOf(Reg));
    const dest_reg = @intCast(Reg, 0x000000ff & instruction);
    const constant = @intCast(FullArg, 0x01ffffff & chunk.code.items[offset + 1]);

    var value_str = _value.valueToStringAlloc(std.heap.c_allocator, chunk.constants.items[constant]) catch unreachable;
    defer value_str.deinit();

    print(
        "{}\t{}\t{}\t{} {s}",
        .{
            code,
            reg,
            dest_reg,
            constant,
            value_str.items,
        },
    );

    return offset + 2;
}

fn codeRegInstruction(code: OpCode, chunk: *Chunk, offset: usize) usize {
    const instruction = chunk.code.items[offset];
    const reg = @intCast(FullArg, 0x01ffffff & instruction);

    print("{}\t{}", .{ code, reg });

    return offset + 1;
}

fn codeArgRegInstruction(code: OpCode, chunk: *Chunk, offset: usize) usize {
    const instruction = chunk.code.items[offset];
    const arg = @intCast(Arg, (0x01ffffff & instruction) >> @bitSizeOf(Reg));
    const reg = @intCast(Reg, 0x000000ff & instruction);

    print("{}\t{}\t{}", .{ code, arg, reg });

    return offset + 1;
}

fn codeArgRegsInstruction(code: OpCode, chunk: *Chunk, offset: usize) usize {
    const instruction = chunk.code.items[offset];
    const arg = @intCast(Reg, (0x01ff0000 & instruction) >> (@bitSizeOf(Reg) * 2));
    const reg = @intCast(Reg, (0x0000ff00 & instruction) >> @bitSizeOf(Reg));
    const dest_reg = @intCast(Reg, 0x000000ff & instruction);

    print("{}\t{}\t{}\t{}", .{ code, arg, reg, dest_reg });

    return offset + 1;
}

fn codeArgRegConstantInstruction(code: OpCode, chunk: *Chunk, offset: usize) usize {
    const instruction = chunk.code.items[offset];
    const arg = @intCast(Arg, (0x01ffffff & instruction) >> @bitSizeOf(Reg));
    const reg = @intCast(Reg, 0x000000ff & instruction);
    const constant = chunk.code.items[offset + 1];

    var value_str = _value.valueToStringAlloc(std.heap.c_allocator, chunk.constants.items[constant]) catch unreachable;
    defer value_str.deinit();

    print(
        "{}\t{}\t{}\t{} {s}",
        .{
            code,
            arg,
            reg,
            constant,
            value_str.items,
        },
    );

    return offset + 2;
}

fn codeArgsRegInstruction(code: OpCode, chunk: *Chunk, offset: usize) usize {
    const instruction = chunk.code.items[offset];
    const a = @intCast(u8, (0x01ff0000 & instruction) >> (@bitSizeOf(u9) + @bitSizeOf(Reg)));
    const b = @intCast(u9, (0x0000ff00 & instruction) >> @bitSizeOf(Reg));
    const reg = @intCast(Reg, 0x000000ff & instruction);

    print("{}\t{}\t{}\t{}", .{ code, a, b, reg });

    return offset + 1;
}

fn codeRegRegInstruction(code: OpCode, chunk: *Chunk, offset: usize) usize {
    const instruction = chunk.code.items[offset];
    const reg = @truncate(Reg, (0x01ffffff & instruction) >> @bitSizeOf(Reg));
    const dest_reg = @intCast(Reg, 0x000000ff & instruction);

    print("{}\t{}\t{}", .{ code, reg, dest_reg });

    return offset + 1;
}

fn codeRegsInstruction(code: OpCode, chunk: *Chunk, offset: usize) usize {
    const instruction = chunk.code.items[offset];
    const reg1 = @intCast(Reg, (0x01ff0000 & instruction) >> (@bitSizeOf(Reg) * 2));
    const reg2 = @intCast(Reg, (0x0000ff00 & instruction) >> @bitSizeOf(Reg));
    const reg3 = @intCast(Reg, 0x000000ff & instruction);

    print("{}\t{}\t{}\t{}", .{ code, reg1, reg2, reg3 });

    return offset + 1;
}

fn constantInstruction(code: OpCode, chunk: *Chunk, offset: usize) usize {
    const instruction = chunk.code.items[offset];
    const constant = @intCast(Arg, (0x01ffffff & instruction) >> @bitSizeOf(Reg));
    const reg = @intCast(Reg, 0x000000ff & instruction);

    var value_str = _value.valueToStringAlloc(std.heap.c_allocator, chunk.constants.items[constant]) catch unreachable;
    defer value_str.deinit();

    print(
        "{}\t{}\t{} {s}",
        .{
            code,
            constant,
            reg,
            value_str.items,
        },
    );

    return offset + 1;
}

fn jumpInstruction(code: OpCode, chunk: *Chunk, direction: bool, offset: usize) usize {
    const instruction = chunk.code.items[offset];
    const jump = @intCast(FullArg, 0x01ffffff & instruction);

    if (direction) {
        print("{}\t{} -> {}", .{ code, offset, offset + 1 + 1 * jump });
    } else {
        print("{}\t{} -> {}", .{ code, offset, offset + 1 - 1 * jump });
    }

    return offset + 1;
}

fn conditionalJumpInstruction(code: OpCode, chunk: *Chunk, offset: usize) usize {
    const instruction = chunk.code.items[offset];
    const arg = @intCast(FullArg, 0x01ffffff & instruction);
    const reg = chunk.code.items[offset + 1];

    print("{}\t{}\t{} -> {}", .{ code, reg, offset, offset + 1 + 1 * arg });

    return offset + 1;
}

pub fn dumpStack(vm: *VM) void {
    print("\u{001b}[2m", .{}); // Dimmed
    print("stack>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>\n", .{});

    var value = @ptrCast([*]_value.Value, vm.current_fiber.stack[0..]);
    while (@ptrToInt(value) < @ptrToInt(vm.current_fiber.stack_top)) {
        var value_str = _value.valueToStringAlloc(std.heap.c_allocator, value[0]) catch unreachable;
        defer value_str.deinit();

        if (vm.currentFrame().?.slots == value) {
            print(" {} {s} frame\n", .{ @ptrToInt(value), value_str.items[0..std.math.min(value_str.items.len, 100)] });
        } else {
            print(" {} {s}\n", .{ @ptrToInt(value), value_str.items[0..std.math.min(value_str.items.len, 100)] });
        }

        value += 1;
    }
    print(" {} top\n", .{@ptrToInt(vm.current_fiber.stack_top)});

    print("<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<\n\n\n", .{});
    print("\u{001b}[0m", .{});
}

pub fn dumpRegisters(vm: *VM) void {
    print("\u{001b}[2m", .{}); // Dimmed
    print("registers>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>\n", .{});

    for (vm.current_fiber.registers, 0..) |value, i| {
        // FIXME: We don't know if its the end of meaningful registers
        if (value.val == _value.Value.Void.val) {
            break;
        }

        var value_str = _value.valueToStringAlloc(std.heap.c_allocator, value) catch unreachable;
        defer value_str.deinit();

        print(" r{} {s}\n", .{ i, value_str.items[0..std.math.min(value_str.items.len, 100)] });
    }

    print("<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<\n\n\n", .{});
    print("\u{001b}[0m", .{});
}

pub fn disassembleInstruction(chunk: *Chunk, offset: usize) usize {
    print("\n{:0>3} ", .{offset});

    if (offset > 0 and chunk.lines.items[offset] == chunk.lines.items[offset - 1]) {
        print("|   ", .{});
    } else {
        print("{:0>3} ", .{chunk.lines.items[offset]});
    }

    const full_instruction: u32 = chunk.code.items[offset];
    const instruction: OpCode = @intToEnum(OpCode, @intCast(_chunk.Code, full_instruction >> @bitSizeOf(FullArg)));
    return switch (instruction) {
        .OP_TRUE,
        .OP_FALSE,
        .OP_NULL,
        .OP_VOID,
        .OP_UNWRAP,
        .OP_RETURN,
        .OP_PUSH,
        .OP_YIELD,
        .OP_RESOLVE,
        .OP_THROW,
        .OP_POP,
        .OP_STRING_FOREACH,
        .OP_LIST_FOREACH,
        .OP_ENUM_FOREACH,
        .OP_MAP_FOREACH,
        .OP_FIBER_FOREACH,
        .OP_CLOSE_UPVALUE,
        .OP_TRY_END,
        => codeRegInstruction(instruction, chunk, offset),

        .OP_GET_LOCAL,
        .OP_SET_LOCAL,
        .OP_GET_GLOBAL,
        .OP_SET_GLOBAL,
        .OP_GET_UPVALUE,
        .OP_SET_UPVALUE,
        .OP_LIST,
        .OP_MAP,
        .OP_DEFINE_GLOBAL,
        .OP_ENUM,
        .OP_IMPORT,
        => codeArgRegInstruction(instruction, chunk, offset),

        .OP_CALL,
        .OP_ROUTINE,
        => codeArgsRegInstruction(instruction, chunk, offset),

        .OP_TO_STRING,
        .OP_LIST_APPEND,
        .OP_NOT,
        .OP_NEGATE,
        .OP_BNOT,
        .OP_RESUME,
        .OP_ENUM_CASE,
        .OP_GET_ENUM_CASE_VALUE,
        .OP_INSTANCE,
        => codeRegRegInstruction(instruction, chunk, offset),

        .OP_ADD_LIST,
        .OP_ADD_MAP,
        .OP_ADD_STRING,
        .OP_ADD,
        .OP_BAND,
        .OP_BOR,
        .OP_DIVIDE,
        .OP_EQUAL,
        .OP_GET_ENUM_CASE_FROM_VALUE,
        .OP_GET_LIST_SUBSCRIPT,
        .OP_GET_MAP_SUBSCRIPT,
        .OP_GET_STRING_SUBSCRIPT,
        .OP_GREATER,
        .OP_IS,
        .OP_LESS,
        .OP_MOD,
        .OP_MULTIPLY,
        .OP_SET_LIST_SUBSCRIPT,
        .OP_SET_MAP_SUBSCRIPT,
        .OP_SET_MAP,
        .OP_SHL,
        .OP_SHR,
        .OP_SUBTRACT,
        .OP_XOR,
        => codeRegsInstruction(instruction, chunk, offset),

        .OP_JUMP => jumpInstruction(instruction, chunk, true, offset),
        .OP_LOOP => jumpInstruction(instruction, chunk, false, offset),

        .OP_INVOKE_ROUTINE,
        .OP_TRY,
        .OP_EXPORT,
        => codeArgInstruction(instruction, chunk, offset),

        .OP_JUMP_IF_FALSE,
        .OP_JUMP_IF_NOT_NULL,
        => conditionalJumpInstruction(instruction, chunk, offset),

        .OP_GET_OBJECT_PROPERTY,
        .OP_GET_INSTANCE_PROPERTY,
        .OP_GET_LIST_PROPERTY,
        .OP_GET_MAP_PROPERTY,
        .OP_GET_STRING_PROPERTY,
        .OP_GET_PATTERN_PROPERTY,
        .OP_GET_FIBER_PROPERTY,
        .OP_SET_OBJECT_PROPERTY,
        .OP_SET_INSTANCE_PROPERTY,
        => codeConstantRegsInstruction(instruction, chunk, offset),

        .OP_CONSTANT => constantInstruction(instruction, chunk, offset),
        .OP_INSTANCE_INVOKE,
        .OP_STRING_INVOKE,
        .OP_PATTERN_INVOKE,
        .OP_FIBER_INVOKE,
        .OP_LIST_INVOKE,
        .OP_MAP_INVOKE,
        => invokeInstruction(instruction, chunk, offset),

        .OP_OBJECT,
        .OP_METHOD,
        .OP_PROPERTY,
        => codeArgRegConstantInstruction(instruction, chunk, offset),

        .OP_GET_ENUM_CASE => codeArgRegsInstruction(instruction, chunk, offset),

        .OP_CLOSURE => closure: {
            const constant = @intCast(Arg, (0x01ffffff & full_instruction) >> @bitSizeOf(Reg));
            const reg = @intCast(Reg, 0x000000ff & full_instruction);

            var off_offset: usize = offset + 1;

            var value_str = _value.valueToStringAlloc(std.heap.c_allocator, chunk.constants.items[constant]) catch unreachable;
            defer value_str.deinit();

            print(
                "{}\t{}\t{} {s}",
                .{
                    instruction,
                    constant,
                    reg,
                    value_str.items[0..std.math.min(value_str.items.len, 100)],
                },
            );

            var function: *ObjFunction = ObjFunction.cast(chunk.constants.items[constant].obj()).?;
            var i: u8 = 0;
            while (i < function.upvalue_count) : (i += 1) {
                var is_local: bool = chunk.code.items[off_offset] == 1;
                off_offset += 1;
                var index: u8 = @intCast(u8, chunk.code.items[off_offset]);
                off_offset += 1;
                print("\n{:0>3} |                         \t{s} {}\n", .{ off_offset - 2, if (is_local) "local  " else "upvalue", index });
            }

            break :closure off_offset;
        },
    };
}
