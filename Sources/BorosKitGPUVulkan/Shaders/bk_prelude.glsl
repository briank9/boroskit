// BorosKitGPUVulkan: bk_prelude.glsl - the shared-subset names in GLSL (the Metal twin is the prelude in
// BKMeshShaderSource.mm). Original BorosKit code written for this project; contains no third-party code.
// Written 2026-11-26 by agent "vulkan-engine" (step M8, shader option C).
//
// PORTING NOTES: included first by every BorosKit GLSL program (glslc -I adds this folder and the BorosKit
// include folders). No precision-relaxing qualifiers, no fast-math: compiled with glslc --target-env=vulkan1.3.

#ifndef BK_PRELUDE_GLSL
#define BK_PRELUDE_GLSL

#define bk_float2 vec2
#define bk_float3 vec3
#define bk_float4 vec4
#define bk_mesh_float4 vec4
#define bk_mesh_float4x4 mat4
#define int32_t int
#define BK_FN
#define BK_MESH_U_PARAM
#define BK_MESH_U_ARG
#define bk_dfdx dFdx
#define bk_dfdy dFdy

const int BKProjPerspective = 1;

#endif
