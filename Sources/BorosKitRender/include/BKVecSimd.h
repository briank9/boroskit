// BorosKitRender: BKVecSimd - converts between BorosKit's neutral vectors (BKVec.h) and Apple simd.
//
// Original BorosKit code written for this project; contains no third-party code.
//
// APPLE-ONLY GLUE: include this only from Objective-C / Metal files (the Mac/iPad layer), never
// from a plain-C core. The cores use BKVec.h; the Apple side keeps simd where Metal wants it and
// converts at the boundary with these one-liners. A Windows/Linux build simply does not include it.

#ifndef BK_VEC_SIMD_H
#define BK_VEC_SIMD_H

#include <simd/simd.h>
#include "BKVec.h"
#include "BKGPUTypes.h"

static inline BKVec3d BKV3dFromSimd(simd_double3 v) { return BKV3d(v.x, v.y, v.z); }
static inline simd_double3 BKV3dToSimd(BKVec3d v) { return simd_make_double3(v.x, v.y, v.z); }
static inline BKVec3f BKV3fFromSimd(simd_float3 v) { return BKV3f(v.x, v.y, v.z); }
static inline simd_float3 BKV3fToSimd(BKVec3f v) { return simd_make_float3(v.x, v.y, v.z); }
static inline BKVec2f BKV2fFromSimd(simd_float2 v) { return BKV2f(v.x, v.y); }
static inline simd_float2 BKV2fToSimd(BKVec2f v) { return simd_make_float2(v.x, v.y); }
static inline BKVec4f BKV4fFromSimd(simd_float4 v) { return BKV4f(v.x, v.y, v.z, v.w); }
static inline simd_float4 BKV4fToSimd(BKVec4f v) { return simd_make_float4(v.x, v.y, v.z, v.w); }

// GPU block matrices (2026-11-25, vulkan-engine M2): bk_float4x4 (BKGPUTypes.h) has the same bytes as
// simd_float4x4 (4 float4 columns) but is its own C type. bk_float4 is simd_float4 under clang, so the
// columns copy straight across.
static inline bk_float4x4 BKFloat4x4FromSimd(simd_float4x4 m)
{
    bk_float4x4 r;
    for (int c = 0; c < 4; c++) r.columns[c] = m.columns[c];
    return r;
}
static inline simd_float4x4 BKFloat4x4ToSimd(bk_float4x4 m)
{
    simd_float4x4 r;
    for (int c = 0; c < 4; c++) r.columns[c] = m.columns[c];
    return r;
}

#endif
