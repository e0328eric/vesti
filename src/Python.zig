const std = @import("std");
const diag = @import("diagnostic.zig");
const mem = std.mem;

const Allocator = std.mem.Allocator;
const ArrayList = std.ArrayList;
const Child = std.process.Child;
const CowStr = @import("CowStr.zig").CowStr;
const Codegen = @import("Codegen.zig");
const Io = std.Io;
const Parser = @import("parser/Parser.zig");
const LatexEngine = Parser.LatexEngine;

pub const Error = Allocator.Error || error{
    PyInitFailed,
    PyGetModFailed,
};

gil_state: ?*PyThreadState,
vespy: ?*PyObject,

const Self = @This();

// extern functions coming from C
const PyObject = opaque {};
const PyThreadState = opaque {};

extern "c" fn pyInitVestiModule() c_int;
extern "c" fn pyDecRef(obj: ?*PyObject) void;
extern "c" fn PyEval_InitThreads() void;
extern "c" fn Py_Initialize() void;
extern "c" fn Py_Finalize() void;
extern "c" fn Py_NewInterpreter() ?*PyThreadState;
extern "c" fn Py_EndInterpreter(pst: ?*PyThreadState) void;
extern "c" fn PyEval_SaveThread() ?*PyThreadState;
extern "c" fn PyEval_RestoreThread(pst: ?*PyThreadState) void;
extern "c" fn PyImport_ImportModule(mod_name: [*:0]const u8) ?*PyObject;
extern "c" fn PyModule_GetState(module: ?*PyObject) ?*anyopaque;
extern "c" fn PyRun_SimpleString(code: [*:0]const u8) c_int;
extern "c" fn PyErr_Occurred() ?*PyObject;
extern "c" fn PyErr_Fetch(
    etype: ?*?*PyObject,
    evalue: ?*?*PyObject,
    etb: ?*?*PyObject,
) void;
extern "c" fn PyErr_NormalizeException(
    etype: ?*?*PyObject,
    evalue: ?*?*PyObject,
    etb: ?*?*PyObject,
) void;
extern "c" fn PyObject_Str(val: ?*PyObject) ?*PyObject;
extern "c" fn PyUnicode_AsUTF8(val: ?*PyObject) [*:0]const u8;

//          ╭─────────────────────────────────────────────────────────╮
//          │                    Public Functions                     │
//          ╰─────────────────────────────────────────────────────────╯

pub fn init(engine: LatexEngine) Error!Self {
    if (pyInitVestiModule() == -1) return error.PyInitFailed;

    var self: Self = undefined;

    Py_Initialize();
    errdefer Py_Finalize();

    self.gil_state = PyEval_SaveThread() orelse return error.PyInitFailed;

    PyEval_RestoreThread(self.gil_state);
    defer self.gil_state = PyEval_SaveThread();
    self.vespy = PyImport_ImportModule("vesti");

    const vespy = @as(*VesPy, @ptrCast(@alignCast(PyModule_GetState(self.vespy).?)));
    vespy.vesti_output = c_alloc.create(ArrayList(u8)) catch return error.PyInitFailed;
    vespy.vesti_output.* = ArrayList(u8).initCapacity(c_alloc, 100) catch return error.PyInitFailed;
    vespy.engine = engine;

    return self;
}

pub fn deinit(self: *Self) void {
    PyEval_RestoreThread(self.gil_state);
    pyDecRef(self.vespy);
    Py_Finalize();
}

pub fn runPyCode(self: *Self, code: [:0]const u8) bool {
    PyEval_RestoreThread(self.gil_state);
    defer self.gil_state = PyEval_SaveThread();

    return PyRun_SimpleString(@ptrCast(code.ptr)) == 0;
}

pub fn getVestiOutputStr(self: *Self, outside_alloc: Allocator) !ArrayList(u8) {
    PyEval_RestoreThread(self.gil_state);
    defer self.gil_state = PyEval_SaveThread();

    const state_ptr = PyModule_GetState(self.vespy) orelse return error.PyGetModFailed;
    const vespy: *VesPy = @ptrCast(@alignCast(state_ptr));

    return try vespy.vesti_output.clone(outside_alloc);
}

//          ╭─────────────────────────────────────────────────────────╮
//          │       boilerplates for making vesti python module       │
//          ╰─────────────────────────────────────────────────────────╯

const c_alloc = std.heap.c_allocator;

const VesPy = extern struct {
    vesti_output: *ArrayList(u8),
    engine: LatexEngine,
};

export fn zigAllocatorAlloc(n: usize) callconv(.c) ?*anyopaque {
    const ptr = c_alloc.alloc(u8, n) catch return null;
    return @ptrCast(ptr);
}

export fn zigAllocatorFree(ptr: ?*anyopaque, n: usize) callconv(.c) void {
    if (ptr) |p| c_alloc.free(@as([*]u8, @ptrCast(@alignCast(p)))[0..n]);
}

export fn deinitVesPy(self: *VesPy) callconv(.c) void {
    self.vesti_output.deinit(c_alloc);
    c_alloc.destroy(self.vesti_output);
}

export fn appendCStr(self: *VesPy, str: [*:0]const u8, len: usize) bool {
    self.vesti_output.appendSlice(c_alloc, str[0..len]) catch return false;
    return true;
}

export fn dumpVesPy(self: *VesPy) void {
    std.debug.print("pointer: {*}\n", .{self.vesti_output});
}

export fn parseVesti(
    output_str: *?[*:0]const u8,
    output_str_len: *usize,
    code: [*:0]const u8,
    len: usize,
    engine: LatexEngine,
) void {
    const vesti_code = code[0..len];

    var diagnostic = diag.Diagnostic{
        .allocator = c_alloc,
    };
    defer diagnostic.deinit();

    var cwd_dir = std.fs.cwd();
    var parser = Parser.init(
        c_alloc,
        vesti_code,
        &cwd_dir,
        &diagnostic,
        false, // disallow nested pycode
        null, // disallow changing engine type
    ) catch |err| {
        std.debug.print(
            "parse init failed because of {s}\n",
            .{@errorName(err).ptr},
        );
        output_str.* = null;
        return;
    };

    var ast = parser.parse() catch |err| {
        switch (err) {
            Parser.ParseError.ParseFailed => {
                diagnostic.initMetadata(
                    CowStr.init(.Borrowed, .{@as([]const u8, "<pycode>")}),
                    CowStr.init(.Borrowed, .{@as([]const u8, @ptrCast(vesti_code))}),
                );
                diagnostic.prettyPrint(true) catch {
                    std.debug.print(
                        "diagnostic pretty print failed\n",
                        .{},
                    );
                    output_str.* = null;
                    return;
                };
            },
            else => {},
        }
        std.debug.print(
            "parse failed because of {s}\n",
            .{@errorName(err).ptr},
        );
        output_str.* = null;
        return;
    };
    defer {
        for (ast.items) |*stmt| stmt.deinit(c_alloc);
        ast.deinit(c_alloc);
    }

    var aw = Io.Writer.Allocating.initCapacity(c_alloc, 256) catch @panic("OOM");
    errdefer aw.deinit();
    var codegen = Codegen.init(
        c_alloc,
        vesti_code,
        ast.items,
        &diagnostic,
        engine,
        true, // disallow nested pycode
    ) catch |err| {
        std.debug.print(
            "codegen init failed because of {s}\n",
            .{@errorName(err).ptr},
        );
        output_str.* = null;
        return;
    };
    defer codegen.deinit();
    codegen.codegen(&aw.writer) catch |err| {
        diagnostic.initMetadata(
            CowStr.init(.Borrowed, .{@as([]const u8, "<pycode>")}),
            CowStr.init(.Borrowed, .{@as([]const u8, @ptrCast(vesti_code))}),
        );
        diagnostic.prettyPrint(true) catch {
            std.debug.print(
                "diagnostic pretty print failed\n",
                .{},
            );
            output_str.* = null;
            return;
        };
        std.debug.print(
            "vesti code generation failed because of {s}\n",
            .{@errorName(err).ptr},
        );
        output_str.* = null;
        return;
    };

    const content = aw.toOwnedSliceSentinel(0) catch @panic("OOM");

    output_str.* = content.ptr;
    output_str_len.* = content.len;
    return;
}
