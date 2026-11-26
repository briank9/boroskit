// BorosKit plain-C core tests: BKVec (neutral vectors) and BKGPUTypes (GPU block types + layouts).
// Original BorosKit code written for this project; contains no third-party code.
// Written 2026-11-25 by agent "vulkan-engine" (step M4). This file is compiled twice by CMake: once
// with clang's vector types and once with -DBK_GPU_TYPES_PORTABLE_STRUCTS=1 (what GCC / MSVC see), so
// both definitions of bk_float4 are proven to give the same layouts.

#include "BKCoreTest.h"
#include "BKVec.h"
#include "BKGPUTypes.h"
#include "BKShaderTypes.h"          // BKRenderParams
#include "BKMeshShaderTypes.h"      // BKMeshUniforms, BKMeshGPUVertex
#include "BKOverlayCore.h"          // BKOverlayParams, BKOverlayVertex
#include "BKDisplayShaderTypes.h"   // BKDisplayParams
#include "BKSurfaceShaderTypes.h"   // BKSurfaceParams
#include "BKCurvedReformatCore.h"   // BKReformatParams, BKReformatFrame
#include <stddef.h>

void bk_test_vec_basics(void)
{
    BKVec3d a = BKV3d(1, 2, 3), b = BKV3d(-2, 0.5, 4);
    BK_CHECK_SAME(BKV3dDot(a, b), 1 * -2 + 2 * 0.5 + 3 * 4);
    BKVec3d c = BKV3dCross(BKV3d(1, 0, 0), BKV3d(0, 1, 0));
    BK_CHECK(c.x == 0 && c.y == 0 && c.z == 1);                    // x cross y = z
    BK_CHECK_NEAR(BKV3dLength(BKV3d(3, 4, 12)), 13, 0);
    BKVec3d n = BKV3dNormalize(BKV3d(0, 0, -5));
    BK_CHECK(n.x == 0 && n.y == 0 && n.z == -1);
    BKVec3d s = BKV3dAddScaled(a, b, 2);
    BK_CHECK(s.x == -3 && s.y == 3 && s.z == 11);
    BK_CHECK_NEAR(BKV3dDistance(a, BKV3d(1, 2, 0)), 3, 0);
}

void bk_test_gpu_types_layout(void)
{
    // bk_make_float4 / bk_make_float2 store the components in x, y, z, w order (memory order too).
    bk_float4 v = bk_make_float4(1, 2, 3, 4);
    const float *f = (const float *)&v;
    BK_CHECK(f[0] == 1 && f[1] == 2 && f[2] == 3 && f[3] == 4);
    BK_CHECK(v.x == 1 && v.w == 4);
    bk_float2 v2 = bk_make_float2(5, 6);
    BK_CHECK(((const float *)&v2)[1] == 6);
    // The sizes / offsets the GPU (Metal now, GLSL std430 later) relies on. The headers already pin
    // them at compile time; checking again here proves this exact compile (type mode) agrees.
    BK_CHECK(sizeof(bk_float4) == 16 && sizeof(bk_float4x4) == 64 && sizeof(bk_float2) == 8);
    BK_CHECK(sizeof(BKRenderParams) == 592);
    BK_CHECK(offsetof(BKRenderParams, clipPlanes) == 256);
    BK_CHECK(offsetof(BKRenderParams, viewWidth) == 432);
    BK_CHECK(offsetof(BKRenderParams, reserved1) == 588);
    BK_CHECK(sizeof(BKMeshUniforms) == 272);
    BK_CHECK(offsetof(BKMeshUniforms, normalMatrix) == 64);
    BK_CHECK(offsetof(BKMeshUniforms, color) == 192);
    BK_CHECK(offsetof(BKMeshUniforms, projection) == 240);
    BK_CHECK(sizeof(BKMeshGPUVertex) == 40);
    BK_CHECK(sizeof(BKOverlayParams) == 24 && offsetof(BKOverlayParams, mode) == 16);
    BK_CHECK(sizeof(BKOverlayVertex) == 32);
    BK_CHECK(sizeof(BKDisplayParams) == 80);
    BK_CHECK(sizeof(BKSurfaceParams) == 336 && offsetof(BKSurfaceParams, gridSize) == 272);
    BK_CHECK(sizeof(BKReformatParams) == 80 && sizeof(BKReformatFrame) == 48);
    BK_CHECK(BK_MAX_CLIP_PLANES == 6);
}
