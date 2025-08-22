#include <stdarg.h>

#include "vespy.h"

//          ╭─────────────────────────────────────────────────────────╮
//          │       boilerplates for making vesti python module       │
//          ╰─────────────────────────────────────────────────────────╯

static int modTraverse(PyObject* v, visitproc visit, void* arg) {
    //UNUSED(v);
    UNUSED(visit);
    UNUSED(arg);

    VesPy* vespy = (VesPy*)PyModule_GetState(v);
    return 0;
}

static int modClear(PyObject* v) {
    UNUSED(v);

    return 0;
}

static void modFree(void* v) {
    if (!v) return;
    
    VesPy* vespy = (VesPy*)PyModule_GetState((PyObject*)v);
    deinitVesPy(vespy);
}

// vesti module builin methods definitions
#include "vespy_methods.c"

static struct PyMethodDef VESTI_PY_BUILTINS[] = {
    (PyMethodDef){
        .ml_name = "print",
        .ml_meth = (PyCFunction)(&vestiPrint),
        .ml_flags = METH_FASTCALL | METH_KEYWORDS,
        .ml_doc = vestiPrint_Documentation,
    },
    (PyMethodDef){
        .ml_name = "parse",
        .ml_meth = &vestiParse,
        .ml_flags = METH_O,
        .ml_doc = vestiParse_Documentation,
    },
    (PyMethodDef){
        .ml_name = "getDummyDir",
        .ml_meth = &vestiGetDummyDir,
        .ml_flags = METH_NOARGS,
        .ml_doc = vestiGetDummyDir_Documentation,
    },
    (PyMethodDef){
        .ml_name = "engineType",
        .ml_meth = &vestiEngineType,
        .ml_flags = METH_NOARGS,
        .ml_doc = vestiEngineType_Documentation,
    },
    {NULL, NULL, 0, NULL},
};

static struct PyModuleDef VESTI_MODULE = {
    .m_base = PyModuleDef_HEAD_INIT,
    .m_name = "vesti",
    .m_doc = "vesti related functions in pycode",
    .m_size = sizeof(VesPy),
    .m_methods = VESTI_PY_BUILTINS,
    .m_traverse = &modTraverse,
    .m_clear = &modClear,
    .m_free = &modFree,
    .m_slots = NULL,
};

static PyObject* pyInitVesti(void) {
    return PyModule_Create(&VESTI_MODULE);
}

//          ╭─────────────────────────────────────────────────────────╮
//          │                    Export Functions                     │
//          ╰─────────────────────────────────────────────────────────╯

int pyInitVestiModule(void) {
    return PyImport_AppendInittab("vesti", &pyInitVesti);
}

void pyDecRef(PyObject* obj) {
    Py_XDECREF(obj);
}

PyObject* raiseError(const char* fmt, ...) {
    va_list args;
    va_start(args, fmt);
    PyObject* result = PyErr_FormatV(PyExc_RuntimeError, fmt, args);
    va_end(args);

    return result;
}
