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
    PyInitSubInterpreterFailed,
    PySubInterpreterIsNull,
    PyGetModFailed,
};

main_tstate: ?*PyThreadState = null,
vesti_output: ArrayList(u8) = .empty,
engine: LatexEngine,

const Self = @This();

// extern functions coming from C
const PyObject = opaque {};
const PyThreadState = opaque {};
const PyStatus = opaque {};

extern "c" fn pyInitVestiModule() c_int;
extern "c" fn pyDecRef(obj: ?*PyObject) void;
extern "c" fn PyEval_InitThreads() void;
extern "c" fn Py_Initialize() void;
extern "c" fn Py_Finalize() void;
extern "c" fn Py_NewInterpreter() ?*PyThreadState;
extern "c" fn Py_EndInterpreter(pst: ?*PyThreadState) void;
extern "c" fn PyEval_SaveThread() ?*PyThreadState;
extern "c" fn PyEval_RestoreThread(pst: ?*PyThreadState) void;
extern "c" fn PyThreadState_Get() ?*PyThreadState;
extern "c" fn PyThreadState_Swap(interp: ?*PyThreadState) ?*PyThreadState;
extern "c" fn PyImport_ImportModule(mod_name: [*:0]const u8) ?*PyObject;
extern "c" fn PyModule_GetState(module: ?*PyObject) ?*anyopaque;
extern "c" fn PyRun_SimpleString(code: [*:0]const u8) c_int;
extern "c" fn PyErr_Occurred() ?*PyObject;
extern "c" fn PyErr_Print() void;
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
extern "c" fn pyNewSubInterpreter(tstate: ?*?*PyThreadState) ?*PyStatus;
extern "c" fn deinitPyStatus(status: ?*PyStatus) void;
extern "c" fn checkPyStatus(status: ?*PyStatus) bool;

//          ╭─────────────────────────────────────────────────────────╮
//          │                    Public Functions                     │
//          ╰─────────────────────────────────────────────────────────╯

pub fn init(engine: LatexEngine) Error!Self {
    if (pyInitVestiModule() == -1) return error.PyInitFailed;

    var self: Self = .{ .engine = engine };

    Py_Initialize();
    errdefer Py_Finalize();

    self.main_tstate = PyThreadState_Get();
    self.vesti_output = try ArrayList(u8).initCapacity(c_alloc, 100);
    return self;
}

pub fn deinit(self: *Self) void {
    self.vesti_output.deinit(c_alloc);
    Py_Finalize();
}

pub fn getVestiOutputStr(self: *Self, outside_alloc: Allocator) !ArrayList(u8) {
    const data = try self.vesti_output.clone(outside_alloc);
    self.vesti_output.clearRetainingCapacity();
    return data;
}

pub fn runPyCode(self: *Self, code: [:0]const u8, is_main: bool) bool {
    if (is_main) {
        const prev = PyThreadState_Swap(self.main_tstate);
        defer _ = PyThreadState_Swap(prev);

        const vesti_mod = PyImport_ImportModule("vesti");
        if (vesti_mod == null) {
            PyErr_Print();
            return false;
        }
        defer pyDecRef(vesti_mod);

        const state_ptr = PyModule_GetState(vesti_mod) orelse {
            PyErr_Print();
            return false;
        };
        const vespy = @as(*VesPy, @ptrCast(@alignCast(state_ptr)));
        vespy.vesti_output = &self.vesti_output;
        vespy.engine = self.engine;

        return runPyCodeHelper(code);
    }

    var tstate: ?*PyThreadState = null;
    defer Py_EndInterpreter(tstate);
    const status = pyNewSubInterpreter(&tstate);
    defer deinitPyStatus(status);
    if (!checkPyStatus(status)) return false;

    const vesti_mod = PyImport_ImportModule("vesti");
    if (vesti_mod == null) {
        PyErr_Print();
        return false;
    }
    defer pyDecRef(vesti_mod);

    const state_ptr = PyModule_GetState(vesti_mod) orelse {
        PyErr_Print();
        return false;
    };
    const vespy = @as(*VesPy, @ptrCast(@alignCast(state_ptr)));
    vespy.vesti_output = &self.vesti_output;
    vespy.engine = self.engine;

    return runPyCodeHelper(code);
}

fn runPyCodeHelper(code: [:0]const u8) bool {
    const rc = PyRun_SimpleString(@ptrCast(code.ptr));
    if (rc != 0 and PyErr_Occurred() != null) PyErr_Print();
    return rc == 0;
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
