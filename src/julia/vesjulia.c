#include <stdio.h>
#include <stdint.h>
#include <stdbool.h>
#include <string.h>
#include <stdarg.h>
#include <assert.h>

#include <julia.h>

#ifdef _WIN32
  #define VESJL_EXPORT __declspec(dllexport)
#else
  #define VESJL_EXPORT __attribute__((visibility("default")))
#endif

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
} VesJl;

extern VesJl ves_jl;

extern void* zigAllocatorAlloc(size_t n);
extern void zigAllocatorFree(void* ptr, size_t n);
extern bool appendCStr(VesJl* self, const char* str, size_t len);
extern void dumpVesPy(VesJl* self);
extern const char* parseVesti(
    const char** output, size_t* output_len,
    const char* code, size_t len,
    LatexEngine engine
);

// wrapper implementation
// Helpers
static inline uint32_t clamp_nl(uint32_t nl) { return nl > 2 ? 2 : nl; }

// Convert any Julia value to Julia String via Base.string(x), GC-rooted.
// Returns a jl_value_t* that is a Julia String.
static jl_value_t* to_jl_string(jl_value_t* x) {
    jl_function_t* f_string = jl_get_function(jl_base_module, "string");
    return jl_call1(f_string, x); // returns a Julia String
}

// === vesti.print(args...; sep=" ", nl::Integer=1) implemented in C ===
//
// Julia will pass a Vector{Any} with the positional args, plus sep and nl.
VESJL_EXPORT void vesti_print(jl_value_t* args_any, const char* sep, uint32_t nl) {
    jl_array_t* args = (jl_array_t*)args_any;
    if (!jl_is_array(args)) return;

    size_t n = jl_array_len(args);
    jl_value_t** data = jl_array_data(args, jl_value_t*);

    uint32_t newline = clamp_nl(nl);
    size_t sep_len = sep ? strlen(sep) : 0;

    JL_GC_PUSH1(&args_any); // root the array itself

    for (size_t i = 0; i < n; ++i) {
        jl_value_t* s = to_jl_string(data[i]);         // Julia String
        JL_GC_PUSH1(&s);
        if (!jl_is_string(s)) { JL_GC_POP(); continue; }

        const char* cstr = jl_string_ptr(s);
        size_t clen = strlen(cstr);

        if (!appendCStr(&ves_jl, cstr, clen)) { JL_GC_POP(); JL_GC_POP(); return; }

        if (i + 1 < n && sep_len) {
            if (!appendCStr(&ves_jl, sep, sep_len)) { JL_GC_POP(); JL_GC_POP(); return; }
        }

        for (uint32_t j = 0; j < newline; ++j) {
            if (!appendCStr(&ves_jl, "\n", 1)) { JL_GC_POP(); JL_GC_POP(); return; }
        }

        JL_GC_POP(); // s
    }

    JL_GC_POP(); // args_any
}

// === vesti.parse(input::String)::String ===
// Returns a new Julia String with the parsed output, or throws on error.
VESJL_EXPORT jl_value_t* vesti_parse(jl_value_t* s_any) {
    if (!jl_is_string(s_any)) {
        jl_exceptionf(jl_argumenterror_type, "non-string value was given");
        return NULL;
    }
    const char* ves_code = jl_string_ptr(s_any);
    size_t ves_len = strlen(ves_code);

    const char* parsed = NULL; size_t out_len = 0;
    parseVesti(&parsed, &out_len, ves_code, ves_len, ves_jl.engine);

    if (!parsed) {
        jl_exceptionf(jl_errorexception_type, "parsing vesti code failed");
        return NULL;
    }

    jl_value_t* out = jl_cstr_to_string(parsed);
    zigAllocatorFree((void*)parsed, out_len);
    return out;
}

// === vesti.get_dummy_dir()::String ===
VESJL_EXPORT jl_value_t* vesti_get_dummy_dir(void) {
    return jl_cstr_to_string(VESTI_DUMMY_DIR);
}

// === vesti.engine_type()::String ===
VESJL_EXPORT jl_value_t* vesti_engine_type(void) {
    switch (ves_jl.engine) {
    case LATEX_ENGINE_LATEX:     return jl_cstr_to_string("latex");
    case LATEX_ENGINE_PDF:       return jl_cstr_to_string("pdf");
    case LATEX_ENGINE_XE:        return jl_cstr_to_string("xe");
    case LATEX_ENGINE_LUA:       return jl_cstr_to_string("lua");
    case LATEX_ENGINE_TECTONIC:  return jl_cstr_to_string("tect");
    default:
        jl_exceptionf(jl_errorexception_type, "internal vesti-julia error: bad engine");
        return NULL;
    }
}

// export to zig
bool run_jlcode(const char* code, const char* fmt, ...) {
    bool result = true;

    va_list args;
    va_start(args, fmt);

    jl_eval_string(code);
    jl_value_t* ex = jl_exception_occurred();
    if (ex) {
        result = false;
        JL_GC_PUSH1(&ex);
        jl_vprintf(jl_stderr_stream(), fmt, args);

        // stderr() IO object
        //jl_function_t* stderr_fn = jl_get_function(jl_base_module, "stderr");
        //jl_value_t* io = jl_call0(stderr_fn);

        // backtrace
        jl_function_t* catch_bt = jl_get_function(jl_base_module, "catch_backtrace");
        jl_value_t* bt = jl_call0(catch_bt);

        {
            JL_GC_PUSH1(&bt);
            jl_function_t* showerror = jl_get_function(jl_base_module, "showerror");
            jl_call2(showerror, jl_stderr_obj(), ex);
            jl_call2(showerror, jl_stderr_obj(), bt);
            jl_printf(jl_stderr_stream(), "\n");
            fflush(stderr);
            JL_GC_POP(); // bt
        }
        JL_GC_POP(); // ex
    }


    va_end(args);
    return result;
}
