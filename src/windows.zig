/// zig 0.15.2 std.os.windows
///
const std = @import("std");

pub const TRUE = 1;
pub const BOOL = c_int;
pub const UINT = c_uint;
pub const SHORT = i16;
pub const WORD = u16;

pub const COORD = extern struct {
    X: SHORT,
    Y: SHORT,
};

pub const SMALL_RECT = extern struct {
    Left: SHORT,
    Top: SHORT,
    Right: SHORT,
    Bottom: SHORT,
};

pub const CONSOLE_SCREEN_BUFFER_INFO = extern struct {
    dwSize: COORD,
    dwCursorPosition: COORD,
    wAttributes: WORD,
    srWindow: SMALL_RECT,
    dwMaximumWindowSize: COORD,
};

pub extern "kernel32" fn GetConsoleScreenBufferInfo(
    hConsoleOutput: std.os.windows.HANDLE,
    lpConsoleScreenBufferInfo: *CONSOLE_SCREEN_BUFFER_INFO,
) callconv(.winapi) BOOL;

pub extern "kernel32" fn SetConsoleOutputCP(
    wCodePageID: UINT,
) callconv(.winapi) BOOL;

pub extern "kernel32" fn GetConsoleOutputCP() UINT;
