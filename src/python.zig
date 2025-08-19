const std = @import("std");
const mem = std.mem;

const Allocator = std.mem.Allocator;
const ArrayList = std.ArrayList;
//const Parser = @import("./parser/Parser.zig");
//const Codegen = @import("./Codegen.zig");

pub const Error = Allocator.Error || error{
    PyInitFailed,
    PyGetModFailed,
    PyCalcFailed,
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

pub fn init() Error!Self {
    if (pyInitVestiModule() == -1) return error.PyInitFailed;

    var self: Self = undefined;

    Py_Initialize();
    errdefer Py_Finalize();

    self.gil_state = PyEval_SaveThread() orelse return error.PyInitFailed;

    PyEval_RestoreThread(self.gil_state);
    defer self.gil_state = PyEval_SaveThread();
    self.vespy = PyImport_ImportModule("vesti");

    return self;
}

pub fn deinit(self: *Self) void {
    PyEval_RestoreThread(self.gil_state);
    pyDecRef(self.vespy);
    Py_Finalize();
}

pub fn runPyCode(self: *Self, code: [:0]const u8) Error!void {
    PyEval_RestoreThread(self.gil_state);
    defer self.gil_state = PyEval_SaveThread();

    if (PyRun_SimpleString(@ptrCast(code.ptr)) != 0) {
        return error.PyCalcFailed;
    }
}

pub fn getVestiOutputStr(self: *Self, outside_alloc: Allocator) !ArrayList(u8) {
    PyEval_RestoreThread(self.gil_state);
    defer self.gil_state = PyEval_SaveThread();

    const state_ptr = PyModule_GetState(self.vespy) orelse return error.PyGetModFailed;
    const vespy: *VesPy = @ptrCast(@alignCast(state_ptr));

    return try vespy.vesti_output.clone(outside_alloc);
}

pub fn getPyErrorMsg(self: *Self, outside_alloc: Allocator) !?[:0]const u8 {
    PyEval_RestoreThread(self.gil_state);
    defer self.gil_state = PyEval_SaveThread();

    var etype: ?*PyObject = null;
    defer pyDecRef(etype);
    var evalue: ?*PyObject = null;
    defer pyDecRef(evalue);
    var etb: ?*PyObject = null;
    defer pyDecRef(etb);

    PyErr_Fetch(@ptrCast(&etype), @ptrCast(&evalue), @ptrCast(&etb));
    PyErr_NormalizeException(@ptrCast(&etype), @ptrCast(&evalue), @ptrCast(&etb));

    if (evalue) |val| {
        const s = PyObject_Str(val);
        defer pyDecRef(s);
        if (s != null) {
            const msg = PyUnicode_AsUTF8(s);
            var output: ArrayList(u8) = .{};
            errdefer output.deinit(outside_alloc);
            try output.print(outside_alloc, "{s}", .{msg});
            return try output.toOwnedSliceSentinel(outside_alloc, 0);
        }
    }

    return null;
}

//          ╭─────────────────────────────────────────────────────────╮
//          │       boilerplates for making vesti python module       │
//          ╰─────────────────────────────────────────────────────────╯

const c_alloc = std.heap.c_allocator;

const VesPy = extern struct {
    vesti_output: *ArrayList(u8),
};

export fn initVesPy(self: *VesPy) callconv(.c) bool {
    self.vesti_output = c_alloc.create(ArrayList(u8)) catch return false;
    self.vesti_output.* = ArrayList(u8).initCapacity(c_alloc, 100) catch return false;

    return true;
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
