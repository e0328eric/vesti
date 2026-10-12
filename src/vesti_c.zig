//          ╭─────────────────────────────────────────────────────────╮
//          │       Minimal Manual Translate C for <windows.h>        │
//          ╰─────────────────────────────────────────────────────────╯
const builtin = @import("builtin");
const win = @import("std").os.windows;

pub const MessageBoxA = switch (builtin.os.tag) {
    .windows => struct {
        pub extern "kernel32" fn MessageBoxA(
            hWnd: ?*anyopaque,
            lpText: [*c]const u8,
            lpCaption: [*c]const u8,
            uType: c_uint,
        ) callconv(.winapi) [*c]const u8;
    }.MessageBoxA,
    else => {},
};
pub const SetConsoleOutputCP = switch (builtin.os.tag) {
    .windows => struct {
        pub extern "kernel32" fn SetConsoleOutputCP(wCodePageID: c_uint) callconv(.winapi) c_int;
    }.SetConsoleOutputCP,
    else => {},
};
pub const LoadLibraryW = switch (builtin.os.tag) {
    .windows => struct {
        pub extern "kernel32" fn LoadLibraryW(lib_name: win.LPCWSTR) callconv(.winapi) ?win.HMODULE;
    }.LoadLibraryW,
    else => {},
};
pub const GetProcAddress = switch (builtin.os.tag) {
    .windows => struct {
        pub extern "kernel32" fn GetProcAddress(handle: win.HMODULE, proc_name: win.LPCSTR) callconv(.winapi) ?win.FARPROC;
    }.GetProcAddress,
    else => {},
};
pub const FreeLibrary = switch (builtin.os.tag) {
    .windows => struct {
        pub extern "kernel32" fn FreeLibrary(handle: win.HMODULE) callconv(.winapi) void;
    }.FreeLibrary,
    else => {},
};

pub const MB_OK: c_uint = 0x00;
pub const MB_ICONEXCLAMATION: c_uint = 0x30;

//          ╭─────────────────────────────────────────────────────────╮
//          │                Translate C of <signal.h>                │
//          │                DO NOT MODIFY MANUALLY!!!                │
//          ╰─────────────────────────────────────────────────────────╯

pub const __p_sig_fn_t = ?*const fn (c_int) callconv(.c) void;
pub extern fn signal(_SigNum: c_int, _Func: __p_sig_fn_t) __p_sig_fn_t;

pub const NSIG = @as(c_int, 23);
pub const SIGINT = @as(c_int, 2);
pub const SIGILL = @as(c_int, 4);
pub const SIGABRT_COMPAT = @as(c_int, 6);
pub const SIGFPE = @as(c_int, 8);
pub const SIGSEGV = @as(c_int, 11);
pub const SIGTERM = @as(c_int, 15);
pub const SIGBREAK = @as(c_int, 21);
pub const SIGABRT = @as(c_int, 22);
pub const SIGABRT2 = @as(c_int, 22);
