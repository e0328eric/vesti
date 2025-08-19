#ifndef VESTI_PYTHON_H_
#define VESTI_PYTHON_H_

#include <stdbool.h>
#include <string.h>

#define PY_SSIZE_T_CLEAN
#include <Python.h>

#define UNUSED(_val) (void)_val

// extern functions comming from zig
typedef struct {
    void* vesti_output;
} VesPy;

extern bool initVesPy(VesPy* self);
extern void deinitVesPy(VesPy* self);
extern bool appendCStr(VesPy* self, const char* str, size_t len);
extern void dumpVesPy(VesPy* self);

#endif // VESTI_PYTHON_H_
