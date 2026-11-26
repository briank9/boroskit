// BorosKitGPUVulkan: bk_overlay_common.glsl - the GLSL names of the shared 2D overlay shaders (BKOverlayShaderBodies.h;
// Metal side BKOverlayShaderSource.mm). Original BorosKit code; no third-party code. 2026-11-26, "vulkan-engine".
// Bindings (BKOverlayPass): vertices = storage 0 (vertex), params = storage 1 (both), image = 16, sampler = 40.
#ifndef BK_OVERLAY_COMMON_GLSL
#define BK_OVERLAY_COMMON_GLSL
#define BK_GLSL 1
#define bk_float2 vec2
#define bk_float4 vec4
#define int32_t int
#include "BKOverlayCore.h"
#include "BKOverlayShaderBodies.h"
#define bko_texture2d texture2D
#define bko_sampler sampler
#define BKO_P_PARAM
#define BKO_P_ARG
#define BKO_FN
layout(std430, set = 0, binding = 1) readonly buffer BKOverlayParamsBlock { BK_OVERLAY_PARAMS_FIELDS } p;
#endif
