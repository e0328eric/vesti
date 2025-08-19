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
        .ml_name = "addOne",
        .ml_meth = &vestiAddOne,
        .ml_flags = METH_VARARGS,
        .ml_doc = "add one",
    },
    (PyMethodDef){
        .ml_name = "print",
        .ml_meth = &vestiPrint,
        .ml_flags = METH_VARARGS,
        .ml_doc = "writes inner value into the vesti code",
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
    PyObject* mod = PyModule_Create(&VESTI_MODULE);
    if (!mod) return NULL;

    VesPy* vespy = (VesPy*)PyModule_GetState(mod);
    if (!vespy) goto FAILURE;
    if (!initVesPy(vespy)) goto FAILURE;

    return mod;

FAILURE:
    Py_XDECREF(mod);
    return NULL;
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

