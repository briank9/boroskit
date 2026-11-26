// BorosKitGPUVulkan: bk_display_common.glsl - the GLSL names of the shared 2D display shaders (BKDisplayShaderBodies.h;
// the Metal side is BKDisplayShaderSource.mm). Original BorosKit code; no third-party code. 2026-11-26, "vulkan-engine".
// Bindings (BKDisplayPass): params = storage binding 0, image = 16, colour table = 17, sampler = 40 (texelFetch only).
#ifndef BK_DISPLAY_COMMON_GLSL
#define BK_DISPLAY_COMMON_GLSL
#define BK_GLSL 1
#define bk_i32 int
#include "BKDisplayShaderTypes.h"
#include "BKDisplayShaderBodies.h"
#define bk_float2 vec2
#define bk_float4 vec4
#define bk_int2 ivec2
#define bk_uint2 uvec2
#define bkd_texture2d texture2D
#define BKD_READ(t, c) texelFetch(sampler2D(t, bkdSampler), ivec2(c), 0)
#define BKD_P_PARAM
#define BKD_P_ARG
#define BKD_FN
#endif
