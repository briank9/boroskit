// BorosKitGPUVulkan: bk_raycast_common.glsl - the GLSL side of the shared volume ray caster (BKRaycastShaderBodies.h,
// shader option C; the Metal side is the prelude in Sources/BorosKitRender/BKShaderSource.mm).
// Original BorosKit code written for this project; contains no third-party code.
// Written 2026-11-26 by agent "vulkan-engine" (Vulkan plan 7.1 #4b).
//
// PORTING NOTES:
//   - Defines the shared-subset names, the render constants and the one bound sampler (binding 40: linear, clamp,
//     normalised - the Metal kernels' constexpr samplers). Exact texel reads use texelFetch through that sampler
//     (no filtering happens with texelFetch).
//   - Each kernel declares its params block as `p` (binding = its slot) and its resources under the shared names
//     BEFORE pasting the bodies. Bindings: see BKRaycastPass.h.
//   - BK_MAX_CLIP_PLANES must equal BKGPUTypes.h (6); the layout of the params block is checked by the Vulkan test.
#ifndef BK_RAYCAST_COMMON_GLSL
#define BK_RAYCAST_COMMON_GLSL

#define BK_GLSL 1
#define bk_float4 vec4
#define uint32_t uint
#define int32_t int
#define BK_MAX_CLIP_PLANES 6
#include "BKShaderTypes.h"
#include "BKRaycastShaderBodies.h"

#define bk_float2 vec2
#define bk_float3 vec3
#define bk_int3 ivec3
#define bk_uint2 uvec2
#define bk_uint3 uvec3
#define bk_uint4 uvec4
#define bk_float3x3 mat3
#define bk_texture2d texture2D
#define bk_texture3d texture3D
#define bk_sampler sampler
#define BK_TEX2_READ(t, c) texelFetch(sampler2D(t, bkLinearSampler), ivec2(c), 0)
#define BK_TEX3_READ(t, c) texelFetch(sampler3D(t, bkLinearSampler), ivec3(c), 0)
#define BK_TEX2_SAMPLE(t, s, c) texture(sampler2D(t, s), c)
#define BK_TEX3_SAMPLE(t, s, c) texture(sampler3D(t, s), c)
#define BK_TEX2_WIDTH(t) uint(textureSize(sampler2D(t, bkLinearSampler), 0).x)
#define BK_TEX2_HEIGHT(t) uint(textureSize(sampler2D(t, bkLinearSampler), 0).y)
#define BK_INF uintBitsToFloat(0x7f800000u)
#define bk_fabs abs
#define bk_rint roundEven
#define bk_all_ge(a, b) all(greaterThanEqual(a, b))
#define bk_all_le(a, b) all(lessThanEqual(a, b))
#define bk_any_ge(a, b) any(greaterThanEqual(a, b))
#define BK_FN
#define BK_OUT(T, n) out T n
#define BK_INOUT(T, n) inout T n
#define BK_P_PARAM
#define BK_P_ARG
#define BK_P_ONLY_PARAM
#define BK_P_ONLY_ARG
#define BK_P_PARAM_FIRST
#define BK_P_ARG_FIRST
#define BK_BRICK_PARAM
#define BK_BRICK_ARG
#define BK_TRACE_SAMPLERS
#define linearSampler bkLinearSampler
#define tfSampler bkLinearSampler

const int BKModeComposite = 0;
const int BKModeMIP = 1;
const int BKModeMinIP = 2;
const int BKModeAverage = 3;
const int BKProjPerspective = 1;
const int BKBrickSize = BK_BRICK_SIZE;
const int BKTransferFunctionEntries = BK_TRANSFER_FUNCTION_ENTRIES;
const int BKMaxClipPlanes = BK_MAX_CLIP_PLANES;

layout(local_size_x_id = 0, local_size_y_id = 1, local_size_z_id = 2) in;
layout(set = 0, binding = 40) uniform sampler bkLinearSampler;

#endif
