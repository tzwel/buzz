const std = @import("std");
const api = @import("buzz_api.zig");

// fun random(int? min = null, int? max = null) > int
export fn random(ctx: *api.NativeCtx) c_int {
    const min = ctx.vm.bz_peek(1);
    const max = ctx.vm.bz_peek(0);

    ctx.vm.bz_push(
        api.Value.fromInteger(
            std.crypto.random.intRangeAtMost(
                i32,
                if (min.isInteger())
                    min.integer()
                else
                    0,
                if (max.isInteger())
                    max.integer()
                else
                    (if (min.isInteger()) min.integer() else 0) + 1,
            ),
        ),
    );

    return 1;
}

export fn print(ctx: *api.NativeCtx) c_int {
    var len: usize = 0;
    const string = ctx.vm.bz_peek(0).bz_valueToString(&len);

    if (len == 0) {
        return 0;
    }

    _ = std.io.getStdOut().write(string.?[0..len]) catch return 0;
    _ = std.io.getStdOut().write("\n") catch return 0;

    return 0;
}

export fn floatToInt(ctx: *api.NativeCtx) c_int {
    const value = ctx.vm.bz_peek(0);

    ctx.vm.bz_push(
        api.Value.fromInteger(
            @as(i32, @intFromFloat(value.float())),
        ),
    );

    return 1;
}

export fn floatToUint(ctx: *api.NativeCtx) c_int {
    const value = ctx.vm.bz_peek(0);

    ctx.vm.bz_push(
        api.Value.fromUnsigned(
            @as(u32, @intFromFloat(value.float())),
        ),
    );

    return 1;
}

export fn intToFloat(ctx: *api.NativeCtx) c_int {
    const value = ctx.vm.bz_peek(0);

    ctx.vm.bz_push(
        api.Value.fromFloat(
            @as(f64, @floatFromInt(value.integer())),
        ),
    );

    return 1;
}

export fn uintToFloat(ctx: *api.NativeCtx) c_int {
    const value = ctx.vm.bz_peek(0);

    ctx.vm.bz_push(
        api.Value.fromFloat(
            @as(f64, @floatFromInt(value.unsigned())),
        ),
    );

    return 1;
}

export fn parseInt(ctx: *api.NativeCtx) c_int {
    const string_value = ctx.vm.bz_peek(0);

    var len: usize = 0;
    const string = string_value.bz_valueToString(&len);

    if (len == 0) {
        ctx.vm.bz_push(api.Value.Null);

        return 1;
    }

    const string_slice = string.?[0..len];

    const number = std.fmt.parseInt(i32, string_slice, 10) catch {
        ctx.vm.bz_push(api.Value.Null);

        return 1;
    };

    ctx.vm.bz_push(api.Value.fromInteger(number));

    return 1;
}

export fn parseUint(ctx: *api.NativeCtx) c_int {
    const string_value = ctx.vm.bz_peek(0);

    var len: usize = 0;
    const string = string_value.bz_valueToString(&len);

    if (len == 0) {
        ctx.vm.bz_push(api.Value.Null);

        return 1;
    }

    const string_slice = string.?[0..len];

    const number = std.fmt.parseInt(u32, string_slice, 10) catch {
        ctx.vm.bz_push(api.Value.Null);

        return 1;
    };

    ctx.vm.bz_push(api.Value.fromUnsigned(number));

    return 1;
}

export fn parseFloat(ctx: *api.NativeCtx) c_int {
    const string_value = ctx.vm.bz_peek(0);

    var len: usize = 0;
    const string = string_value.bz_valueToString(&len);

    if (len == 0) {
        ctx.vm.bz_push(api.Value.Null);

        return 1;
    }

    const string_slice = string.?[0..len];

    const number: f64 = std.fmt.parseFloat(f64, string_slice) catch {
        ctx.vm.bz_push(api.Value.Null);

        return 1;
    };

    ctx.vm.bz_push(api.Value.fromFloat(number));

    return 1;
}

export fn char(ctx: *api.NativeCtx) c_int {
    const byte_value = ctx.vm.bz_peek(0);

    var byte = byte_value.integer();

    if (byte > 255) {
        byte = 255;
    } else if (byte < 0) {
        byte = 0;
    }

    const str = [_]u8{@as(u8, @intCast(byte))};

    if (api.ObjString.bz_string(ctx.vm, str[0..], 1)) |obj_string| {
        ctx.vm.bz_push(obj_string.bz_objStringToValue());

        return 1;
    }

    @panic("Out of memory");
}

export fn assert(ctx: *api.NativeCtx) c_int {
    const condition_value = ctx.vm.bz_peek(1);
    const message_value = ctx.vm.bz_peek(0);

    if (!condition_value.boolean()) {
        var len: usize = 0;
        const message = api.Value.bz_valueToString(message_value, &len).?;
        // TODO: debug.getTrace
        std.io.getStdOut().writer().print(
            "Assert failed: {s}\n",
            .{
                message[0..len],
            },
        ) catch unreachable;

        std.os.exit(1);
    }

    return 0;
}
