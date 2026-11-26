// BorosKitVec: BKGPUTypes - the small vector / matrix types used inside CPU -> GPU parameter blocks,
// in plain C, plus the compile-time layout check macro.
//
// Original BorosKit code written for this project; contains no third-party code.
// Written 2026-11-25 by agent "vulkan-engine" (Vulkan engine kickoff, step M2; readiness audit
// finding 4).
//
// PORTING NOTES (Vulkan / Windows / Linux):
//   - What each GPU language calls these types (the field lists in the *ShaderTypes.h headers are
//     pasted into the shader text, and each shader prelude defines the same names):
//         C (this file)       Metal (MSL)      GLSL (Vulkan, std430)    size / alignment
//         bk_float2           float2           vec2                     8 / 8
//         bk_float4           float4           vec4                     16 / 16
//         bk_float4x4         float4x4         mat4 (column-major)      64 / 16
//   - With clang (Apple clang, clang / clang-cl on Windows and Linux: the compilers BorosKit uses
//     everywhere) bk_float2 / bk_float4 are clang "extended vectors". That is a language feature of
//     the compiler, NOT Apple's <simd/simd.h> (which does not exist on Windows / Linux); it happens
//     to be the very same type as Apple's simd_float2 / simd_float4, so Objective-C glue can keep
//     assigning simd values to these fields without any conversion and the bytes cannot change.
//   - Any other compiler (GCC, plain MSVC) - or clang with -DBK_GPU_TYPES_PORTABLE_STRUCTS=1, which
//     the CMake core tests use to prove it - gets plain structs { float x, y, z, w; } with the same
//     size and alignment.
//   - RULE for plain-C cores: touch these types ONLY through .x / .y / .z / .w, bk_make_float4()
//     and bk_float4x4.columns[i]. Never use vector arithmetic (a + b), swizzles (.xyz) or
//     subscripts (v[i]) on them in a core: those only compile with clang's vectors.
//   - bk_float4x4 is a struct of 4 columns (column-major, like Metal and GLSL), the same layout as
//     Apple's simd_float4x4 but a different C type: Apple glue converts with BKVecSimd.h.
//   - No 3-component vectors here on purpose: float3 is 16 bytes in C / Metal but 12 in a std430
//     array, so GPU blocks use bk_float4 and leave .w unused (VULKAN-PORT-PLAN.md rule 2).
//
// Plain language: these are the "four numbers in a row" and "4 x 4 table" boxes that BorosKit hands
// to the graphics card. Written once here so the Mac (Metal) and the future Windows / Linux engine
// (Vulkan) read exactly the same bytes.

#ifndef BK_GPU_TYPES_H
#define BK_GPU_TYPES_H

#include <stddef.h>   // offsetof, for the layout checks
#include <stdint.h>

#if defined(__clang__) && !BK_GPU_TYPES_PORTABLE_STRUCTS
typedef float bk_float2 __attribute__((ext_vector_type(2)));
typedef float bk_float4 __attribute__((ext_vector_type(4)));
#define BK_GPU_TYPES_CLANG_VECTORS 1
#else
// Plain structs with the GPU alignment (8 / 16 bytes).
#if defined(_MSC_VER) && !defined(__clang__)
#define BK_GPU_ALIGN(n) __declspec(align(n))
#else
#define BK_GPU_ALIGN(n) __attribute__((aligned(n)))
#endif
typedef struct BK_GPU_ALIGN(8) { float x, y; } bk_float2;
typedef struct BK_GPU_ALIGN(16) { float x, y, z, w; } bk_float4;
#define BK_GPU_TYPES_CLANG_VECTORS 0
#endif

// 4 x 4 matrix, column-major: columns[c] is column c (element row r = .x/.y/.z/.w).
typedef struct { bk_float4 columns[4]; } bk_float4x4;

// What: build a bk_float4 / bk_float2 the same way with either definition above.
static inline bk_float4 bk_make_float4(float x, float y, float z, float w)
{
    bk_float4 v;
    v.x = x; v.y = y; v.z = z; v.w = w;
    return v;
}
static inline bk_float2 bk_make_float2(float x, float y)
{
    bk_float2 v;
    v.x = x; v.y = y;
    return v;
}

// What: a compile-time check of a layout promise (size or field offset), in C99, C11+ and C++.
// Why: a CPU == Metal size test cannot catch a layout both Apple compilers agree on but GLSL std430
// does not; pinning every offset in the header catches a moved or resized field at compile time.
// C99 has no _Static_assert (the cores are checked as strict C99), so there a failed check declares
// an array of size -1, which every C compiler refuses (named with __COUNTER__ - clang, GCC and MSVC
// all have it - so checks from different headers never clash).
#if defined(__cplusplus)
#define BK_GPU_STATIC_ASSERT(cond, msg) static_assert(cond, msg)
#elif defined(__STDC_VERSION__) && __STDC_VERSION__ >= 201112L
#define BK_GPU_STATIC_ASSERT(cond, msg) _Static_assert(cond, msg)
#else
#define BK_GPU_CONCAT2_(a, b) a##b
#define BK_GPU_CONCAT_(a, b) BK_GPU_CONCAT2_(a, b)
#define BK_GPU_STATIC_ASSERT(cond, msg) typedef char BK_GPU_CONCAT_(bk_gpu_layout_check_, __COUNTER__)[(cond) ? 1 : -1]
#endif
// Shorthand: struct `type` field `field` must start at byte `offset`.
#define BK_GPU_ASSERT_OFFSET(type, field, offset) \
    BK_GPU_STATIC_ASSERT(offsetof(type, field) == (offset), #type "." #field " must stay at byte " #offset " (std430 layout)")

// Alignment probes (C99 has no _Alignof): the field after one char starts at the type's alignment.
typedef struct { char c; bk_float2 v; } bk_gpu_align_probe_float2_;
typedef struct { char c; bk_float4 v; } bk_gpu_align_probe_float4_;
BK_GPU_STATIC_ASSERT(sizeof(bk_float2) == 8, "bk_float2 must be 8 bytes (vec2)");
BK_GPU_ASSERT_OFFSET(bk_gpu_align_probe_float2_, v, 8);
BK_GPU_STATIC_ASSERT(sizeof(bk_float4) == 16, "bk_float4 must be 16 bytes (vec4)");
BK_GPU_ASSERT_OFFSET(bk_gpu_align_probe_float4_, v, 16);
BK_GPU_STATIC_ASSERT(sizeof(bk_float4x4) == 64, "bk_float4x4 must be 64 bytes (mat4)");

// Clipping planes a ray-cast can use at once (a box needs 6). Lives here (not in the Objective-C
// BKClipPlanes.h, which pulls in the LGPL N3 types) because it sizes an array inside the GPU block
// BKRenderParams. Moved 2026-11-25 (M2); BKClipPlanes.h includes this header, so its users still see it.
#define BK_MAX_CLIP_PLANES 6

#endif // BK_GPU_TYPES_H
