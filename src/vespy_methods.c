#ifndef VESTI_PYTHON_BUILTINS_IMPLEMENTATION_C_
#define VESTI_PYTHON_BUILTINS_IMPLEMENTATION_C_

#include "vespy.h"

#define vestiPrint_Documentation                                 \
    "bake inner values inside of generated latex codebase\n"     \
    "\n"                                                         \
    "<Default Arguments>\n"                                      \
    "sep (str, default = " ")\n"                                 \
    "    A separator between each parameters of `vesti.print`\n" \
    "\n"                                                         \
    "nl  (int, default = 1)\n"                                   \
    "    Add newlines after `vesti.print` outputs\n"             \
    "    If nl > 2, then it changes into nl = 2\n"               \

typedef struct {
    const char* separator;
    uint8_t newline;
} PrintKwArgs;

// this function is used on METH_FASTCALL | METH_KEYWORDS
static bool parsePrintKwArgs(PrintKwArgs* output, PyObject* kwnames, 
    PyObject* const* kwargs)
{
    output->separator = " ";
    output->newline = 1; // in default, vesti add an newline for each print
    if (!kwnames) return true;

    Py_ssize_t nkw = PyTuple_GET_SIZE(kwnames);
    for (Py_ssize_t i = 0; i < nkw; ++i) {
        PyObject* key = PyTuple_GET_ITEM(kwnames, i);
        PyObject* val = kwargs[i];
        if (!PyUnicode_Check(key)) {
            PyErr_SetString(PyExc_TypeError, "kwargs key must be str");
            return false;
        }
        const char* k = PyUnicode_AsUTF8(key);
        if (!k) return false;

        if (strcmp(k, "sep") == 0) {
            if (PyUnicode_CheckExact(val)) {
                output->separator = PyUnicode_AsUTF8(val);
            }
        }
        else if (strcmp(k, "nl") == 0) {
            if (PyLong_CheckExact(val)) {
                output->newline = (uint8_t)PyLong_AsSize_t(val);
                output->newline = output->newline > 2 ? 2 : output->newline;
            }
        }
    }

    return true;
}

static PyObject* vestiPrint(
    PyObject* self,
    PyObject* const* args,
    Py_ssize_t nargs,
    PyObject* kwnames
) {
    PyObject* result = Py_None;
    VesPy* vespy = (VesPy*)PyModule_GetState(self);

    if (nargs < 1) {
        result = PyErr_Format(PyExc_RuntimeError, "no argument");
        goto EXIT_FUNCTION;
    };

    PrintKwArgs kwargs_data;
    if (!parsePrintKwArgs(&kwargs_data, kwnames, args + nargs)) return NULL;

    for (size_t i = 0; i < (size_t)nargs; ++i) {
        PyObject* val = args[i];
        PyObject* str_obj = PyObject_Str(val);

        Py_ssize_t str_len;
        const char* str = PyUnicode_AsUTF8AndSize(str_obj, &str_len);
        assert(str_len >= 0 && "python should give a valid string");

        if (!appendCStr(vespy, str, str_len)) return NULL; // OOM
        if (i + 1 < (size_t)nargs) {
            if (!appendCStr(
                vespy,
                kwargs_data.separator,
                strlen(kwargs_data.separator)
            )) return NULL; // OOM
        }

        for (uint8_t j = 0; j < kwargs_data.newline; ++j) {
            if (!appendCStr(vespy, "\n", 1)) return NULL; // OOM
        }

        Py_XDECREF(str_obj);
    }


EXIT_FUNCTION:
    return result;
}

#define vestiParse_Documentation           \
    "parse input string as a vesti code\n"

static PyObject* vestiParse(PyObject* self, PyObject* arg) {
    VesPy* vespy = (VesPy*)PyModule_GetState(self);

    if (!PyUnicode_CheckExact(arg)) {
        PyErr_SetString(PyExc_TypeError, "non-string value was given");
        return Py_None;
    }

    Py_ssize_t ves_code_len;
    const char* ves_code = PyUnicode_AsUTF8AndSize(arg, &ves_code_len);

    const char* parsed_code; size_t len;
    parseVesti(&parsed_code, &len, ves_code, (size_t)ves_code_len, vespy->engine);

    if (!parsed_code) {
        PyErr_SetString(PyExc_RuntimeError, "parsing vesti code failed");
        return NULL;
    }

    PyObject* output =  PyUnicode_FromString(parsed_code);
    zigAllocatorFree((void*)parsed_code, len);
    return output;
}

#define vestiGetDummyDir_Documentation \
    "give the string " VESTI_DUMMY_DIR ", a default vesti cache directory\n"

static PyObject* vestiGetDummyDir(PyObject* self, PyObject* noargs) {
    UNUSED(self);
    UNUSED(noargs);

    return PyUnicode_FromString(VESTI_DUMMY_DIR);
}

#define vestiEngineType_Documentation                         \
    "give the engine type of current running latex backend\n" \
    "\n"                                                      \
    "<Possible Values>\n"                                     \
    "    - latex\n"                                           \
    "    - pdf  (indicates pdflatex)\n"                       \
    "    - xe   (indicates xelatex)\n"                        \
    "    - lua  (indicates lualatex)\n"                       \
    "    - tect (indicates tectonic)\n"

static PyObject* vestiEngineType(PyObject* self, PyObject* noargs) {
    UNUSED(noargs);
    VesPy* vespy = (VesPy*)PyModule_GetState(self);

    switch (vespy->engine) {
    case LATEX_ENGINE_LATEX:
        return PyUnicode_FromString("latex");
    case LATEX_ENGINE_PDF:
        return PyUnicode_FromString("pdf");
    case LATEX_ENGINE_XE:
        return PyUnicode_FromString("xe");
    case LATEX_ENGINE_LUA:
        return PyUnicode_FromString("lua");
    case LATEX_ENGINE_TECTONIC:
        return PyUnicode_FromString("tect");
    default:
        PyErr_SetString(PyExc_RuntimeError, 
            "internal vesti-python error. unreachable branch reached...");
        return NULL;
    }
}

#endif // VESTI_PYTHON_BUILTINS_IMPLEMENTATION_C_

// REFERENCE NOTE
//
//const builtins = PyImport_ImportModule("builtins");
//defer py.Py_XDECREF(builtins);
//const print_fnt = py.PyObject_GetAttrString(builtins, "print");
//defer py.Py_XDECREF(print_fnt);

//const print_args = py.PyTuple_Pack(1, self);
//defer py.Py_XDECREF(print_args);
//const result = py.PyObject_CallObject(print_fnt, print_args);
//defer py.Py_XDECREF(result);
