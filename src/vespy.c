#include <stdbool.h>
#include <stdarg.h>
#include <stdlib.h>

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
    UNUSED(v);
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

static int vestiExec(PyObject* m) {
    if (PyModule_AddFunctions(m, VESTI_PY_BUILTINS) < 0) return -1;
    return 0;
}


static PyModuleDef_Slot VESTI_SLOTS[] = {
    {Py_mod_exec, vestiExec},
    {Py_mod_multiple_interpreters, Py_MOD_PER_INTERPRETER_GIL_SUPPORTED},
    {0, NULL}
};

static struct PyModuleDef VESTI_MODULE = {
    .m_base = PyModuleDef_HEAD_INIT,
    .m_name = "vesti",
    .m_doc = "vesti related functions in pycode",
    .m_size = sizeof(VesPy),
    .m_methods = NULL, // add via Py_mod_exec
    .m_slots = VESTI_SLOTS,
    .m_traverse = &modTraverse,
    .m_clear = &modClear,
    .m_free = &modFree,
};

PyMODINIT_FUNC pyInitVesti(void) {
    return PyModuleDef_Init(&VESTI_MODULE);
}

//          ╭─────────────────────────────────────────────────────────╮
//          │                    Export Functions                     │
//          ╰─────────────────────────────────────────────────────────╯

int pyInitVestiModule(void) {
    return PyImport_AppendInittab("vesti", pyInitVesti);
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

PyStatus* pyNewSubInterpreter(PyThreadState** tstate) {
    if (!tstate) return NULL;

    PyStatus* status = malloc(sizeof(PyStatus));
    PyInterpreterConfig cfg = {
        .check_multi_interp_extensions = 1,
        .gil = PyInterpreterConfig_OWN_GIL,
    };
    *status = Py_NewInterpreterFromConfig(tstate, &cfg);

    return status;
}

// status must be initialized from pyNewSubInterpreter
void deinitPyStatus(PyStatus* status) {
    free(status);
}

bool checkPyStatus(PyStatus* status) {
    if (PyStatus_Exception(*status)) {
        Py_ExitStatusException(*status);
        return false;
    }
    return true;
}
