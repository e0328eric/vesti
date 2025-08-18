const std = @import("std");
const py = @import("pyzig");
const diag = @import("./diagnostic.zig");

const Parser = @import("./parser/Parser.zig");
const Codegen = @import("./Codegen.zig");

const VESTI_OUTPUT_STR: [:0]const u8 = "__VESTI_OUTPUT_STR__";
const VESTI_ERROR_STR: [:0]const u8 = "__VESTI_ERROR_STR__";

pub const Error = error{
    PyInitFailed,
    PyCalcFailed,
};

//          ╭─────────────────────────────────────────────────────────╮
//          │               public apis that vesti uses               │
//          ╰─────────────────────────────────────────────────────────╯

pub fn init() Error!void {
    if (py.PyImport_AppendInittab("vesti", &pyInitVesti) == -1) {
        return error.PyInitFailed;
    }

    py.Py_Initialize();
    return .{};
}

pub fn deinit() void {
    py.Py_Finalize();
}

pub fn runPycode(code: [:0]const u8) Error!void {
    if (py.PyRun_SimpleString(@ptrCast(code.ptr)) != 0) {
        return error.PyCalFailed;
    }
}

//          ╭─────────────────────────────────────────────────────────╮
//          │       boilerplates for making vesti python module       │
//          ╰─────────────────────────────────────────────────────────╯

const VESTI_PY_BUILTINS: [3]py.PyMethodDef = .{
    .{
        .ml_name = "addOne",
        .ml_meth = @ptrCast(&vesti_addOne),
        .ml_flags = py.METH_VARARGS,
        .ml_doc = "",
    },
    .{
        .ml_name = "mulTwo",
        .ml_meth = @ptrCast(&vesti_mulTwo),
        .ml_flags = py.METH_VARARGS,
        .ml_doc = "",
    },
    .{}, // DO NOT REMOVE
};

// translate-c cannot translate the following code.
const PYMODULEDEF_HEAD_INIT: py.PyModuleDef_Base = .{
    .ob_base = .{
        .unnamed_0 = .{
            .ob_refcnt = py._Py_IMMORTAL_REFCNT,
        },
    },
};

var VESTI_MODULE: py.PyModuleDef = .{
    .m_base = PYMODULEDEF_HEAD_INIT,
    .m_name = "vesti",
    .m_doc = "vesti modules",
    .m_size = -1,
    .m_methods = @ptrCast(@constCast(&VESTI_PY_BUILTINS)),
};

fn pyInitVesti() callconv(.c) [*c]py.PyObject {
    return @ptrCast(py.PyModule_Create(
        @as([*c]py.PyModuleDef, @ptrCast(&VESTI_MODULE)),
    ));
}

//          ╭─────────────────────────────────────────────────────────╮
//          │         Implementations of vesti python module          │
//          ╰─────────────────────────────────────────────────────────╯

fn vesti_addOne(self: *py.PyObject, args: *py.PyObject) callconv(.c) ?*py.PyObject {
    _ = self;
    //const builtins = py.PyImport_ImportModule("builtins");
    //defer py.Py_DECREF(builtins);
    //const print_fnt = py.PyObject_GetAttrString(builtins, "print");
    //defer py.Py_DECREF(print_fnt);

    //const print_args = py.PyTuple_Pack(1, self);
    //defer py.Py_DECREF(print_args);
    //const result = py.PyObject_CallObject(print_fnt, print_args);
    //defer py.Py_DECREF(result);

    var x: *py.PyObject = undefined;
    if (py.PyArg_ParseTuple(
        @ptrCast(args),
        "O",
        @as(**py.PyObject, @ptrCast(&x)),
    ) == 0) {
        return null;
    }

    const one = py.PyLong_FromLong(1);
    defer py.Py_DECREF(one);

    return py.PyNumber_Add(x, one);
}

fn vesti_mulTwo(self: *py.PyObject, args: *py.PyObject) callconv(.c) ?*py.PyObject {
    _ = self;
    var x: *py.PyObject = undefined;
    var y: *py.PyObject = undefined;
    if (py.PyArg_ParseTuple(
        @ptrCast(args),
        "OO",
        @as(**py.PyObject, @ptrCast(&x)),
        @as(**py.PyObject, @ptrCast(&y)),
    ) == 0) {
        return null;
    }

    return py.PyNumber_Multiply(x, y);
}
