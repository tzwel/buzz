const std = @import("std");
const builtin = @import("builtin");
const VM = @import("./vm.zig").VM;
const _obj = @import("./obj.zig");
const _value = @import("./value.zig");
const utils = @import("./utils.zig");
const memory = @import("./memory.zig");
const _parser = @import("./parser.zig");
const _codegen = @import("./codegen.zig");

const Value = _value.Value;
const valueToString = _value.valueToString;
const ObjString = _obj.ObjString;
const ObjTypeDef = _obj.ObjTypeDef;
const ObjFunction = _obj.ObjFunction;
const ObjList = _obj.ObjList;
const ObjUserData = _obj.ObjUserData;
const UserData = _obj.UserData;
const TypeRegistry = _obj.TypeRegistry;
const Parser = _parser.Parser;
const CodeGen = _codegen.CodeGen;
const GarbageCollector = memory.GarbageCollector;

var gpa = std.heap.GeneralPurposeAllocator(.{
    .safety = true,
}){};

var allocator: std.mem.Allocator = if (builtin.mode == .Debug)
    gpa.allocator()
else
    std.heap.c_allocator;

// Stack manipulation

/// Push a Value to the stack
export fn bz_push(self: *VM, value: *Value) void {
    self.push(value.*);
}

/// Pop a Value from the stack and returns it
export fn bz_pop(self: *VM) *Value {
    self.current_fiber.stack_top -= 1;
    return @ptrCast(*Value, self.current_fiber.stack_top);
}

/// Peeks at the stack at [distance] from the stack top
export fn bz_peek(self: *VM, distance: u32) *Value {
    return @ptrCast(*Value, self.current_fiber.stack_top - 1 - distance);
}

// Value manipulations

/// Push a boolean value on the stack
export fn bz_pushBool(self: *VM, value: bool) void {
    self.push(Value{ .Boolean = value });
}

/// Push a float value on the stack
export fn bz_pushFloat(self: *VM, value: f64) void {
    self.push(Value{ .Float = value });
}

/// Push a integer value on the stack
export fn bz_pushInteger(self: *VM, value: i64) void {
    self.push(Value{ .Integer = value });
}

/// Push null on the stack
export fn bz_pushNull(self: *VM) void {
    self.push(Value{ .Null = {} });
}

/// Push void on the stack
export fn bz_pushVoid(self: *VM) void {
    self.push(Value{ .Void = {} });
}

/// Push string on the stack
export fn bz_pushString(self: *VM, value: *ObjString) void {
    self.push(value.toValue());
}

/// Push list on the stack
export fn bz_pushList(self: *VM, value: *ObjList) void {
    self.push(value.toValue());
}

/// Converts a value to a boolean
export fn bz_valueToBool(value: *Value) bool {
    return value.Boolean;
}

/// Converts a value to a string
export fn bz_valueToString(value: *Value) ?[*:0]const u8 {
    if (value.* != .Obj or value.Obj.obj_type != .String) {
        return null;
    }

    return utils.toCString(allocator, ObjString.cast(value.Obj).?.string);
}

/// Converts a value to a float
export fn bz_valueToFloat(value: *Value) f64 {
    return if (value.* == .Integer) @intToFloat(f64, value.Integer) else value.Float;
}

/// Converts a value to a integer, returns null if float value with decimal part
export fn bz_valueToInteger(value: *Value) i64 {
    return if (value.* == .Integer) value.Integer else @floatToInt(i64, value.Float);
}

export fn bz_valueIsInteger(value: *Value) bool {
    return value.* == .Integer;
}
export fn bz_valueIsFloat(value: *Value) bool {
    return value.* == .Float;
}

// Obj manipulations

/// Converts a c string to a *ObjString
export fn bz_string(vm: *VM, string: [*:0]const u8) ?*ObjString {
    return vm.gc.copyString(utils.toSlice(string)) catch null;
}

// Other stuff

// Type helpers

// TODO: should always return the same instance
/// Returns the [bool] type
export fn bz_boolType() ?*ObjTypeDef {
    var bool_type: ?*ObjTypeDef = allocator.create(ObjTypeDef) catch null;

    if (bool_type == null) {
        return null;
    }

    bool_type.?.* = ObjTypeDef{ .def_type = .Bool, .optional = false };

    return bool_type;
}

/// Returns the [str] type
export fn bz_stringType() ?*ObjTypeDef {
    var bool_type: ?*ObjTypeDef = allocator.create(ObjTypeDef) catch null;

    if (bool_type == null) {
        return null;
    }

    bool_type.?.* = ObjTypeDef{ .def_type = .String, .optional = false };

    return bool_type;
}

/// Returns the [void] type
export fn bz_voidType() ?*ObjTypeDef {
    var void_type: ?*ObjTypeDef = allocator.create(ObjTypeDef) catch null;

    if (void_type == null) {
        return null;
    }

    void_type.?.* = ObjTypeDef{ .def_type = .Void, .optional = false };

    return void_type;
}

export fn bz_allocated(self: *VM) usize {
    return self.gc.bytes_allocated;
}

export fn bz_collect(self: *VM) bool {
    self.gc.collectGarbage() catch {
        return false;
    };

    return true;
}

export fn bz_newList(vm: *VM, of_type: *ObjTypeDef) ?*ObjList {
    var list_def: ObjList.ListDef = ObjList.ListDef.init(
        vm.gc.allocator,
        of_type,
    );

    var list_def_union: ObjTypeDef.TypeUnion = .{
        .List = list_def,
    };

    var list_def_type: *ObjTypeDef = vm.gc.allocateObject(ObjTypeDef, ObjTypeDef{
        .def_type = .List,
        .optional = false,
        .resolved_type = list_def_union,
    }) catch {
        return null;
    };

    return vm.gc.allocateObject(
        ObjList,
        ObjList.init(vm.gc.allocator, list_def_type),
    ) catch {
        return null;
    };
}

export fn bz_listAppend(self: *ObjList, gc: *GarbageCollector, value: *Value) bool {
    self.rawAppend(gc, value.*) catch {
        return false;
    };

    return true;
}

export fn bz_valueToList(value: *Value) *ObjList {
    return ObjList.cast(value.Obj).?;
}

export fn bz_listGet(self: *ObjList, index: usize) *Value {
    return &self.items.items[index];
}

export fn bz_listLen(self: *ObjList) usize {
    return self.items.items.len;
}

export fn bz_newUserData(vm: *VM, userdata: *UserData) ?*ObjUserData {
    return vm.gc.allocateObject(
        ObjUserData,
        ObjUserData{ .userdata = userdata },
    ) catch {
        return null;
    };
}

export fn bz_throw(vm: *VM, value: *Value) void {
    vm.push(value.*);
}

export fn bz_throwString(vm: *VM, message: [*:0]const u8) void {
    bz_pushString(vm, bz_string(vm, message) orelse {
        _ = std.io.getStdErr().write(utils.toSlice(message)) catch unreachable;
        std.os.exit(1);
    });
}

export fn bz_newVM(self: *VM) ?*VM {
    var vm = self.gc.allocator.create(VM) catch {
        return null;
    };
    var gc = self.gc.allocator.create(GarbageCollector) catch {
        return null;
    };
    gc.* = GarbageCollector.init(self.gc.allocator);

    vm.* = VM.init(gc) catch {
        return null;
    };

    return vm;
}

export fn bz_deinitVM(_: *VM) void {
    // self.deinit();
}

export fn bz_getGC(vm: *VM) *memory.GarbageCollector {
    return vm.gc;
}

export fn bz_compile(self: *VM, source: [*:0]const u8, file_name: [*:0]const u8) ?*ObjFunction {
    var imports = std.StringHashMap(Parser.ScriptImport).init(self.gc.allocator);
    var strings = std.StringHashMap(*ObjString).init(self.gc.allocator);
    var type_registry = TypeRegistry{
        .gc = self.gc,
        .registry = std.StringHashMap(*ObjTypeDef).init(self.gc.allocator),
    };
    var parser = Parser.init(self.gc, &imports, &type_registry, false);
    var codegen = CodeGen.init(self.gc, &parser, &type_registry, false);
    defer {
        codegen.deinit();
        imports.deinit();
        parser.deinit();
        strings.deinit();
        // FIXME: fails
        // gc.deinit();
        // self.gc.allocator.destroy(self.gc);
    }

    if (parser.parse(utils.toSlice(source), utils.toSlice(file_name)) catch null) |function_node| {
        return function_node.toByteCode(function_node, &codegen, null) catch null;
    } else {
        return null;
    }
}

export fn bz_interpret(self: *VM, function: *ObjFunction) bool {
    self.interpret(function, null) catch {
        return false;
    };

    return true;
}
