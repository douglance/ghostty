//! External backend for terminal IO.
//!
//! This backend does not launch subprocesses or own a PTY. Instead, writes are
//! forwarded to a host callback and output is expected to be delivered back via
//! `Termio.processOutput`.
const External = @This();

const std = @import("std");
const Allocator = std.mem.Allocator;
const renderer = @import("../renderer.zig");
const terminal = @import("../terminal/main.zig");
const termio = @import("../termio.zig");

config: Config,

pub const Config = struct {
    userdata: ?*anyopaque = null,
    write: ?*const fn (?*anyopaque, [*]const u8, usize) callconv(.c) void = null,
};

pub fn init(config: Config) External {
    return .{ .config = config };
}

pub fn deinit(self: *External) void {
    _ = self;
}

pub fn initTerminal(self: *External, t: *terminal.Terminal) void {
    _ = self;
    _ = t;
}

pub fn threadEnter(
    self: *External,
    alloc: Allocator,
    io: *termio.Termio,
    td: *termio.Termio.ThreadData,
) !void {
    _ = self;
    _ = alloc;
    _ = io;
    td.backend = .{ .external = .{} };
}

pub fn threadExit(self: *External, td: *termio.Termio.ThreadData) void {
    _ = self;
    _ = td;
}

pub fn focusGained(
    self: *External,
    td: *termio.Termio.ThreadData,
    focused: bool,
) !void {
    _ = self;
    _ = td;
    _ = focused;
}

pub fn resize(
    self: *External,
    grid_size: renderer.GridSize,
    screen_size: renderer.ScreenSize,
) !void {
    _ = self;
    _ = grid_size;
    _ = screen_size;
}

pub fn queueWrite(
    self: *External,
    alloc: Allocator,
    td: *termio.Termio.ThreadData,
    data: []const u8,
    linefeed: bool,
) !void {
    _ = td;

    const write = self.config.write orelse return;
    if (data.len == 0) return;

    if (!linefeed) {
        write(self.config.userdata, data.ptr, data.len);
        return;
    }

    var carriage_returns: usize = 0;
    for (data) |byte| {
        if (byte == '\r') carriage_returns += 1;
    }

    // In linefeed mode we expand CR into CRLF to mirror exec backend behavior.
    var normalized = try std.ArrayList(u8).initCapacity(
        alloc,
        data.len + carriage_returns,
    );
    defer normalized.deinit(alloc);

    for (data) |byte| {
        if (byte == '\r') {
            try normalized.append(alloc, '\r');
            try normalized.append(alloc, '\n');
        } else {
            try normalized.append(alloc, byte);
        }
    }

    if (normalized.items.len == 0) return;
    write(self.config.userdata, normalized.items.ptr, normalized.items.len);
}

pub fn childExitedAbnormally(
    self: *External,
    gpa: Allocator,
    t: *terminal.Terminal,
    exit_code: u32,
    runtime_ms: u64,
) !void {
    _ = self;
    _ = gpa;
    _ = t;
    _ = exit_code;
    _ = runtime_ms;
}

pub const ThreadData = struct {
    pub fn deinit(self: *ThreadData, alloc: Allocator) void {
        _ = self;
        _ = alloc;
    }

    pub fn changeConfig(self: *ThreadData, config: *termio.DerivedConfig) void {
        _ = self;
        _ = config;
    }
};

test "queueWrite forwards bytes" {
    const testing = std.testing;

    const Capture = struct {
        const Self = @This();

        buf: [128]u8 = undefined,
        len: usize = 0,

        fn write(userdata: ?*anyopaque, ptr: [*]const u8, len: usize) callconv(.c) void {
            const self: *Self = @ptrCast(@alignCast(userdata.?));
            const copy_len = @min(len, self.buf.len - self.len);
            @memcpy(self.buf[self.len .. self.len + copy_len], ptr[0..copy_len]);
            self.len += copy_len;
        }

        fn slice(self: *const Self) []const u8 {
            return self.buf[0..self.len];
        }
    };

    var capture: Capture = .{};
    var backend = External.init(.{
        .userdata = &capture,
        .write = Capture.write,
    });
    var td: termio.Termio.ThreadData = undefined;
    try backend.queueWrite(testing.allocator, &td, "hello", false);

    try testing.expectEqualStrings("hello", capture.slice());
}

test "queueWrite linefeed expands carriage return" {
    const testing = std.testing;

    const Capture = struct {
        const Self = @This();

        buf: [128]u8 = undefined,
        len: usize = 0,

        fn write(userdata: ?*anyopaque, ptr: [*]const u8, len: usize) callconv(.c) void {
            const self: *Self = @ptrCast(@alignCast(userdata.?));
            const copy_len = @min(len, self.buf.len - self.len);
            @memcpy(self.buf[self.len .. self.len + copy_len], ptr[0..copy_len]);
            self.len += copy_len;
        }

        fn slice(self: *const Self) []const u8 {
            return self.buf[0..self.len];
        }
    };

    var capture: Capture = .{};
    var backend = External.init(.{
        .userdata = &capture,
        .write = Capture.write,
    });
    var td: termio.Termio.ThreadData = undefined;
    try backend.queueWrite(testing.allocator, &td, "a\rb\r", true);

    try testing.expectEqualStrings("a\r\nb\r\n", capture.slice());
}
