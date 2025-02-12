const std = @import("std");
const mem = std.mem;
const fmt = std.fmt;
const SpinLock = @import("spinlock.zig");
const common = @import("common");
const Color = common.color.Color;

const c = @cImport({
    @cInclude("kernel/types.h");
    @cInclude("kernel/param.h");
    @cInclude("kernel/spinlock.h");
    @cInclude("kernel/sleeplock.h");
    @cInclude("kernel/fs.h");
    @cInclude("kernel/file.h");
    @cInclude("kernel/memlayout.h");
    @cInclude("kernel/riscv.h");
    @cInclude("kernel/defs.h");
    @cInclude("kernel/proc.h");
});

const console = struct {
    pub fn writeBytes(bytes: []const u8) void {
        for (bytes) |byte| c.consputc(byte);
    }
    pub fn writeByte(byte: u8) void {
        c.consputc(byte);
    }
};

/// The errors that can occur when logging
const LoggingError = error{};

/// The Writer for the format function
const Writer = std.io.Writer(void, LoggingError, logCallback);

var lock: SpinLock = SpinLock{};
pub var locking: bool = true;
pub export var panicked: bool = false;

fn logCallback(context: void, str: []const u8) LoggingError!usize {
    // Suppress unused var warning
    _ = context;
    console.writeBytes(str);
    return str.len;
}

fn logLevelColor(lvl: std.log.Level) Color {
    return switch (lvl) {
        .err => .red,
        .warn => .yellow,
        .debug => .magenta,
        .info => .green,
    };
}

pub fn klogFn(
    comptime level: std.log.Level,
    comptime scope: @TypeOf(.EnumLiteral),
    comptime format: []const u8,
    args: anytype,
) void {
    @setRuntimeSafety(false);
    const need_lock = locking;
    if (need_lock) lock.acquire();

    const scope_prefix = "(" ++ comptime Color.dim.ttyStr() ++ @tagName(scope) ++ Color.reset.ttyStr() ++ "): ";

    const prefix = "[" ++ comptime logLevelColor(level).ttyStr() ++ level.asText() ++ Color.reset.ttyStr() ++ "] " ++ scope_prefix;
    print(prefix ++ format ++ "\n", args);

    if (need_lock) lock.release();
}

export fn panic(s: [*:0]u8) noreturn {
    @setCold(true);
    locking = false;
    console.writeBytes("!KERNEL PANIC!\n");
    console.writeBytes(mem.span(s));
    console.writeBytes("\n");
    panicked = true; // freeze uart output from other CPUs
    while (true) {}
}

pub fn print(comptime format: []const u8, args: anytype) void {
    fmt.format(Writer{ .context = {} }, format, args) catch |err| {
        @panic("format: " ++ @errorName(err));
    };
}

pub export fn printf(format: [*:0]const u8, ...) void {
    @setRuntimeSafety(false);
    var need_lock = locking;
    if (need_lock) lock.acquire();
    defer if (need_lock) lock.release();

    if (std.mem.span(format).len == 0) @panic("null fmt");

    var ap = @cVaStart();
    var skip_idx: usize = undefined;
    for (std.mem.span(format), 0..) |byte, i| {
        if (i == skip_idx) {
            continue;
        }
        if (byte != '%') {
            console.writeByte(byte);
            continue;
        }
        var ch = format[i + 1] & 0xff;
        skip_idx = i + 1;
        if (ch == 0) break;
        switch (ch) {
            'd' => print("{d}", .{@cVaArg(&ap, c_int)}),
            'x' => print("{x}", .{@cVaArg(&ap, c_int)}),
            'p' => print("{p}", .{@cVaArg(&ap, *usize)}),
            's' => {
                var s = std.mem.span(@cVaArg(&ap, [*:0]const u8));
                console.writeBytes(s);
            },
            '%' => console.writeByte('%'),
            else => {
                // Print unknown % sequence to draw attention.
                console.writeByte('%');
                console.writeByte(ch);
            },
        }
    }
    @cVaEnd(&ap);
}
