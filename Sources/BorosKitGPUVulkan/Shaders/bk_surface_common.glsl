// BorosKitGPUVulkan: bk_surface_common.glsl - the GLSL side of the shared surface kernels (BKSurfaceShaderBodies.h,
// shader option C; the Metal side is the prelude in Sources/BorosKitSurface/BKSurfaceShaderSource.mm).
// Original BorosKit code written for this project; contains no third-party code.
// Written 2026-11-26 by agent "vulkan-engine"; since the "one source" step the maths lives only in
// BKSurfaceShaderBodies.h - this file defines the shared-subset names, the params block, the scan texture and the
// workgroup scan array.
//
// PORTING NOTES:
//   - Bindings: see BKSurfacePass.h (storage slot n = binding n; scan texture = binding 16; sampler = binding 40).
//   - Workgroup size = specialization constants 0..2 (BKGPU.h ComputeDesc); bkScratch is sized gl_WorkGroupSize.x.
//   - Each kernel declares binding 1 as `fieldWords` (read-write in sample, read-only elsewhere) and its other
//     storage blocks under the shared names BEFORE pasting BK_SURFACE_HELPER_BODIES (the helpers read fieldWords).
#ifndef BK_SURFACE_COMMON_GLSL
#define BK_SURFACE_COMMON_GLSL

#define BK_GLSL 1
#define bk_u32 uint
#include "BKSurfaceShaderTypes.h"
#include "BKSurfaceShaderBodies.h"

#define bk_uint3 uvec3
#define bk_float3 vec3
#define bk_float4 vec4
#define bk_float3x3 mat3
#define bk_float4x4 mat4
#define bk_rint roundEven
#define bk_popcount(x) uint(bitCount(x))
#define bk_barrier() barrier()
#define BK_FN
#define BK_OUT_UINT(name) out uint name
#define BK_SURF_PARAM
#define BK_SURF_ARG
#define BK_SCAN_PARAM
#define BK_SCAN_ARG
#define BK_READ16(words, i) (((words)[(i) >> 1] >> (((i) & 1u) * 16u)) & 0xffffu)
#define BK_VOLUME_READ(p) texelFetch(sampler3D(bkVolume, bkSampler), ivec3(p), 0).r
#define BK_VOLUME_SAMPLE(c) texture(sampler3D(bkVolume, bkSampler), c).r

layout(local_size_x_id = 0, local_size_y_id = 1, local_size_z_id = 2) in;
layout(std430, set = 0, binding = 0) readonly buffer BKSurfaceParamsBlock { BK_SURFACE_PARAM_FIELDS } P;
layout(set = 0, binding = 16) uniform texture3D bkVolume;
layout(set = 0, binding = 40) uniform sampler bkSampler;
shared uint bkScratch[gl_WorkGroupSize.x];

#endif
