/* perf_count_wrapper.c
 *
 * Thin C wrappers around OpenVINO's variadic compile_model / set_property
 * entry points.
 *
 * The OpenVINO C API exposes property pairs via a `...` variadic. The DLL
 * (openvino_c.dll) is built with MSVC, so it expects the MSVC x64 calling
 * convention for variadic arguments (the first two variadic args go into
 * R8/R9, then the stack). NimVoice's main binary is built with TDM-GCC,
 * which by default uses the System V AMD64 calling convention (all
 * variadic args go on the stack). Crossing these two conventions
 * silently corrupts the property pair list.
 *
 * The fix: declare the variadic OpenVINO entry points with
 * `__attribute__((ms_abi))` so that GCC generates MSVC-style variadic
 * code. Then call them through thin, non-variadic wrappers from Nim.
 *
 * Resolving the symbols via `GetProcAddress` keeps us free of OpenVINO's
 * MinGW import library (which the Python distribution does not ship).
 */

#include <stddef.h>

typedef struct ov_core ov_core_t;
typedef struct ov_model ov_model_t;
typedef struct ov_compiled_model ov_compiled_model_t;
typedef int ov_status_e;

typedef __attribute__((ms_abi)) ov_status_e (*nv_compile_model_fn)(
    const ov_core_t*, const ov_model_t*, const char*, size_t, ...);
typedef __attribute__((ms_abi)) ov_status_e (*nv_set_property_fn)(
    ov_compiled_model_t*, ...);

static nv_compile_model_fn g_compile_model = NULL;
static nv_set_property_fn g_set_property = NULL;
static int g_resolved = 0;

/* Minimal Windows declarations; we intentionally avoid pulling in
 * <windows.h> to keep the translation unit small. */
typedef struct HINSTANCE__* HINSTANCE;
__declspec(dllimport) HINSTANCE __stdcall LoadLibraryA(const char*);
__declspec(dllimport) void* __stdcall GetProcAddress(HINSTANCE, const char*);

static int nv_resolve_symbols(void)
{
    if (g_resolved) return 1;
    HINSTANCE mod = LoadLibraryA("openvino_c.dll");
    if (!mod) return 0;
    g_compile_model = (nv_compile_model_fn)GetProcAddress(mod, "ov_core_compile_model");
    g_set_property = (nv_set_property_fn)GetProcAddress(mod, "ov_compiled_model_set_property");
    g_resolved = (g_compile_model != NULL && g_set_property != NULL);
    return g_resolved;
}

/* Wrapper functions are exported as non-variadic cdecl so Nim can call
 * them through a stable signature. */
__declspec(dllexport) ov_status_e __cdecl nv_compile_model_with_perf_count(
    const ov_core_t* core,
    const ov_model_t* model,
    const char* device_name,
    ov_compiled_model_t** compiled_model)
{
    if (!nv_resolve_symbols() || g_compile_model == NULL) return -1; /* GENERAL_ERROR */
    /* The OpenVINO C API's `property_args_size` is the TOTAL count of
     * variadic args that follow, where each `<key, value>` pair counts
     * as 2. The implementation guards `property_args_size % 2 != 0`
     * with `INVALID_C_PARAM`. We pass one pair (PERF_COUNT=YES), so
     * size = 2. There is no NULL terminator. */
    return g_compile_model(
        core, model, device_name, 2, compiled_model,
        "PERF_COUNT", "YES");
}

__declspec(dllexport) ov_status_e __cdecl nv_enable_perf_count(
    ov_compiled_model_t* compiled_model)
{
    if (!nv_resolve_symbols() || g_set_property == NULL) return -1;
    return g_set_property(
        compiled_model,
        "PERF_COUNT", "YES");
}
