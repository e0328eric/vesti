#ifndef VESTI_PYTHON_H_
#define VESTI_PYTHON_H_

#include <stdbool.h>
#include <assert.h>
#include <string.h>
#include <stdlib.h>

#define PY_SSIZE_T_CLEAN
#include <Python.h>

#define UNUSED(_val) (void)_val

// extern functions comming from zig
typedef enum {
    LATEX_ENGINE_LATEX,
    LATEX_ENGINE_PDF,
    LATEX_ENGINE_XE,
    LATEX_ENGINE_LUA,
    LATEX_ENGINE_TECTONIC,
} LatexEngine;

typedef struct {
    void* vesti_output;
    LatexEngine engine;
} VesPy;

extern void* zigAllocatorAlloc(size_t n);
extern void zigAllocatorFree(void* ptr, size_t n);
extern void deinitVesPy(VesPy* self);
extern bool appendCStr(VesPy* self, const char* str, size_t len);
extern void dumpVesPy(VesPy* self);
extern const char* parseVesti(
    const char** output, size_t* output_len,
    const char* code, size_t len,
    LatexEngine engine
);

#endif // VESTI_PYTHON_H_
