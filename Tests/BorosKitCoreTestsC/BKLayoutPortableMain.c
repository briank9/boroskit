// BorosKit plain-C core tests: a second, tiny runner for BKVecGPUTypesTests.c compiled with
// -DBK_GPU_TYPES_PORTABLE_STRUCTS=1 (plain-struct bk_float2 / bk_float4: what GCC and plain MSVC get).
// Original BorosKit code written for this project; contains no third-party code.
// Written 2026-11-25 by agent "vulkan-engine" (step M4). Its own executable, because the same test
// functions are also linked (with clang's vector types) into bk_core_tests.

#include "BKCoreTest.h"

int bk_test_checks = 0;
int bk_test_failures = 0;

void bk_test_fail(const char *file, int line, const char *what)
{
    bk_test_failures++;
    const char *name = file;
    for (const char *p = file; *p; p++) if (*p == '/' || *p == '\\') name = p + 1;
    printf("  FAIL [portable structs] %s:%d: %s\n", name, line, what);
}

void bk_test_vec_basics(void);
void bk_test_gpu_types_layout(void);

int main(void)
{
#if !BK_GPU_TYPES_PORTABLE_STRUCTS || BK_GPU_TYPES_CLANG_VECTORS
    printf("FAIL: this runner must be built with -DBK_GPU_TYPES_PORTABLE_STRUCTS=1\n");
    return 1;
#else
    bk_test_vec_basics();
    bk_test_gpu_types_layout();
    printf("%d checks, %d failed (plain-struct GPU types)\n", bk_test_checks, bk_test_failures);
    return bk_test_failures ? 1 : 0;
#endif
}
