//
// minimal translate-c of vesti_c.h
//
// because of the following issue, there is no choice to include this translated
// file in the repo until the issue is resolved.
// https://github.com/issues/created?issue=ziglang%7Ctranslate-c%7C189
//

//          ╭─────────────────────────────────────────────────────────╮
//          │       Minimal Manual Translate C for <windows.h>        │
//          ╰─────────────────────────────────────────────────────────╯

pub extern "kernel32" fn MessageBoxA(
    hWnd: ?*anyopaque,
    lpText: [*c]const u8,
    lpCaption: [*c]const u8,
    uType: c_uint,
) callconv(.winapi) [*c]const u8;

