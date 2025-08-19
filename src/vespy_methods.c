#include "vespy.h"

PyObject* vestiAddOne(PyObject* self, PyObject* args) {
    //const builtins = PyImport_ImportModule("builtins");
    //defer py.Py_XDECREF(builtins);
    //const print_fnt = py.PyObject_GetAttrString(builtins, "print");
    //defer py.Py_XDECREF(print_fnt);

    //const print_args = py.PyTuple_Pack(1, self);
    //defer py.Py_XDECREF(print_args);
    //const result = py.PyObject_CallObject(print_fnt, print_args);
    //defer py.Py_XDECREF(result);

    PyObject* x;
    if (PyArg_ParseTuple(args, "O", &x) == 0) return NULL;

    PyObject* one = PyLong_FromLong(1);
    PyObject* result = PyNumber_Add(x, one);
    Py_XDECREF(one);

    return result;
}

PyObject* vestiPrint(PyObject* self, PyObject* args) {
    VesPy* vespy = (VesPy*)PyModule_GetState(self);
    const char* str;

    if (PyArg_ParseTuple(args, "s", &str) == 0) return NULL;
    size_t str_len = strlen(str);

    if (!appendCStr(vespy, str, str_len)) return NULL;

    return Py_None;
}

