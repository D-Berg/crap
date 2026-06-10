const std = @import("std");
const builtin = @import("builtin");

const Spinner = struct {
    pub const frames = "⠋⠙⠹⠸⠼⠴⠦⠧⠇⠏";
    pub const frame1 = "⠋";
    pub const frame_count: u8 = frames.len / frame1.len;

    frame_idx: u8,

    pub const init: Spinner = .{
        .frame_idx = 0,
    };

    pub fn get(self: Spinner) []const u8 {
        return frames[self.frame_idx * frame1.len ..][0..frame1.len];
    }

    pub fn next(self: *Spinner) void {
        self.frame_idx = (self.frame_idx + 1) % frame_count;
    }
};

const bar = "━";
const half_bar_left = "╸";
const half_bar_right = "╺";
const TIOCGWINSZ: u32 = std.posix.T.IOCGWINSZ; // https://docs.rs/libc/latest/libc/constant.TIOCGWINSZ.html
const WIDTH_PADDING: usize = 100;

pub fn getScreenWidth(io: std.Io, stdout: std.Io.File) !usize {
    var winsize: std.posix.winsize = undefined;
    switch (comptime builtin.os.tag) {
        .linux => _ = std.os.linux.ioctl(stdout.handle, TIOCGWINSZ, @intFromPtr(&winsize)),
        .macos => _ = std.c.ioctl(stdout.handle, TIOCGWINSZ, &winsize),
        .windows => {
            // https://stackoverflow.com/questions/6812224/getting-terminal-size-in-c-for-windows
            var get_console_info = std.os.windows.CONSOLE.USER_IO.GET_SCREEN_BUFFER_INFO;
            return switch (try get_console_info.operate(io, stdout)) {
                .SUCCESS => @intCast(get_console_info.Data.dwSize.X),
                else => 80,
            };
        },
        else => @compileError("Unsupported OS"),
    }
    return @intCast(winsize.col);
}

pub const EscapeCodes = struct {
    pub const dim = "\x1b[2m";
    pub const pink = "\x1b[38;5;205m";
    pub const white = "\x1b[37m";
    pub const red = "\x1b[31m";
    pub const yellow = "\x1b[33m";
    pub const green = "\x1b[32m";
    pub const magenta = "\x1b[35m";
    pub const cyan = "\x1b[36m";
    pub const reset = "\x1b[0m";
    pub const erase_line = "\x1b[2K\r";
};

pub const ProgressBar = struct {
    spinner: Spinner,
    current: u64,
    estimate: u64,
    stdout: std.Io.File,
    buf: std.Io.Writer.Allocating,
    last_rendered: std.Io.Timestamp,

    pub fn init(io: std.Io, allocator: std.mem.Allocator, stdout: std.Io.File) !ProgressBar {
        const width = try getScreenWidth(io, stdout);
        const buf: std.Io.Writer.Allocating = try .initCapacity(allocator, width + WIDTH_PADDING);
        return .{
            .spinner = .init,
            .last_rendered = .now(io, .awake),
            .current = 0,
            .estimate = 1,
            .stdout = stdout,
            .buf = buf,
        };
    }

    pub fn deinit(self: *ProgressBar) void {
        self.buf.deinit();
    }

    /// Clears then renders bar if enough time has passed since last render.
    pub fn render(self: *ProgressBar, io: std.Io) !void {
        const now: std.Io.Timestamp = .now(io, .awake);
        if (self.last_rendered.durationTo(now).toMilliseconds() < 50) {
            return;
        }
        try self.clear(io);
        self.last_rendered = now;
        const width = try getScreenWidth(io, self.stdout);
        try self.buf.ensureTotalCapacity(width + WIDTH_PADDING);
        const writer = &self.buf.writer;
        const bar_width = width - Spinner.frame1.len - " 10000 runs ".len - " 100% ".len;
        const prog_len = (bar_width * 2) * self.current / self.estimate;
        const full_bars_len: usize = @intCast(prog_len / 2);

        try writer.print("{s}{s}{s} {d: >5} runs ", .{ EscapeCodes.cyan, self.spinner.get(), EscapeCodes.reset, self.current });
        self.spinner.next();

        try writer.print("{s}", .{EscapeCodes.pink}); // pink
        for (0..full_bars_len) |_| {
            try writer.print(bar, .{});
        }
        if (prog_len % 2 == 1) {
            try writer.print(half_bar_left, .{});
        }
        try writer.print("{s}{s}", .{ EscapeCodes.white, EscapeCodes.dim }); // white
        if (prog_len % 2 == 0) {
            try writer.print(half_bar_right, .{});
        }
        for (0..(bar_width - full_bars_len - 1)) |_| {
            try writer.print(bar, .{});
        }
        try writer.print("{s}", .{EscapeCodes.reset}); // reset
        try writer.print(" {d: >3.0}% ", .{
            @as(f64, @floatFromInt(self.current)) * 100 / @as(f64, @floatFromInt(self.estimate)),
        });
        try self.stdout.writeStreamingAll(io, self.buf.written());
    }

    pub fn clear(self: *ProgressBar, io: std.Io) !void {
        try self.stdout.writeStreamingAll(io, EscapeCodes.erase_line); // clear and reset line
        self.buf.clearRetainingCapacity();
    }
};
