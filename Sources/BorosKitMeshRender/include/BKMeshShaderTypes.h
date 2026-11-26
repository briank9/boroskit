// BorosKitMeshRender: the settings block the CPU hands to the GPU for every mesh drawn,
// and the layout of one vertex in GPU memory.
//
// Why a macro (same trick as BKShaderTypes.h in BorosKitRender): the struct must exist
// twice, once in Objective-C (to fill it in) and once in the Metal shader (to read it).
// The fields are written ONCE below; the Objective-C side expands them into a C struct
// and the shader source pulls in the very same text as a string, so the two copies can
// never drift apart. Only 16-byte vectors/matrices first, then 4-byte scalars, so
// both compilers lay the struct out identically (a unit test checks the size too).

//
// ---- PORTING NOTES (future Vulkan backend) -------------------------------------------
//  - BKMeshUniforms is std430- and std140-compatible as is: two float4x4, five float4,
//    then 4-byte scalars (float / int32_t), 272 bytes (a multiple of 16), no float3, no
//    bool. Larger than the guaranteed 128 bytes of push constants: use a uniform buffer.
//  - BKMeshGPUVertex (40 bytes) is read as vertex attributes in Vulkan:
//    location 0 = R32G32B32_SFLOAT at offset 0, 1 = R32G32B32_SFLOAT at 12,
//    2 = R32G32B32A32_SFLOAT at 24, stride 40 (Metal reads it as packed_float3/4 from a
//    buffer by vertex_id; either way gives the same numbers).
//  - Line points are a tightly packed float x3 array (12-byte stride), fetched by
//    vertex index: in GLSL read them from a std430 `float points[]` buffer (3 floats per
//    point), NOT a vec3[] (which would have a 16-byte stride).
//  - Clip space: Vulkan's y axis points down and its depth range is 0..1 like Metal's;
//    flip y (negative viewport height, core since Vulkan 1.1) and keep the depth maths.
//  - The fragment shader uses screen-space derivatives (dfdx/dfdy -> GLSL dFdx/dFdy) for
//    flat normals when a mesh has none: core in Vulkan.
//  - 2026-11-14: textured meshes read a second vertex stream (binding 2 in Metal): texture
//    coordinates as tightly packed float x2 (8-byte stride; Vulkan: R32G32_SFLOAT, location 3).
//    The texture is RGBA8 at texture slot 0 with its sampler at slot 0 (linear or nearest,
//    repeat or clamp-to-edge, no mipmaps). Rules: BKMeshDrawCore.h.
//  - 2026-11-14: points are expanded to two triangles per point in the vertex shader (6
//    vertices, vertex index / 6 = point), from the same packed float x3 array as lines.
//  - Two colour targets (RGBA8 colour + R32_SFLOAT ray distance) with premultiplied
//    "over" blending on the first only, plus a D32_SFLOAT depth buffer.
//  - 2026-11-25: every untextured SEE-THROUGH mesh is drawn twice: (1) depth-only (colour write
//    masks 0, depth test LESS + write), (2) colour with depth test LESS_OR_EQUAL, no depth write.
//    Both passes use the same vertex shader; its position output is invariant (GLSL:
//    `invariant gl_Position;`), so the depths match exactly. See-through objects are still
//    drawn farthest first (object centres); lines/points and textured meshes: one pass.
// ---------------------------------------------------------------------------------------

#ifndef BK_MESH_SHADER_TYPES_H
#define BK_MESH_SHADER_TYPES_H

// 2026-11-25 (vulkan-engine M2): plain C now - the types come from BorosKitVec's BKGPUTypes.h instead of
// Apple <simd/simd.h>. bk_mesh_float4 is the same type as simd_float4 with clang; bk_mesh_float4x4 is
// BorosKit's own column-major struct (same bytes as simd_float4x4): Objective-C glue converts it with
// BKFloat4x4FromSimd (BKVecSimd.h). The Metal shader source defines the same two names as float4 / float4x4.
#include <stdint.h>
#include "BKGPUTypes.h"

typedef bk_float4   bk_mesh_float4;
typedef bk_float4x4 bk_mesh_float4x4;

// The field list lives in BKMeshUniformFields.h (2026-11-26, vulkan-engine M8): that header holds only the
// #define, so the Vulkan GLSL shaders can #include the very same text.
#include "BKMeshUniformFields.h"

typedef struct BKMeshUniforms {
    BK_MESH_UNIFORM_FIELDS
} BKMeshUniforms;

// One vertex as stored in the GPU buffer: 10 floats, 40 bytes, no padding (the shader
// reads it as packed_float3 / packed_float3 / packed_float4).
typedef struct BKMeshGPUVertex {
    float position[3];   // mesh coordinates (mm, before the object's placement)
    float normal[3];     // zero if the mesh has no normals
    float color[4];      // per-vertex RGBA 0..1 (white if the mesh has no colours)
} BKMeshGPUVertex;

// The layout promises above, checked by the compiler (2026-11-25, vulkan-engine M2).
BK_GPU_STATIC_ASSERT(sizeof(BKMeshUniforms) == 272, "BKMeshUniforms must stay 272 bytes (see PORTING NOTES)");
BK_GPU_ASSERT_OFFSET(BKMeshUniforms, model, 0);
BK_GPU_ASSERT_OFFSET(BKMeshUniforms, normalMatrix, 64);
BK_GPU_ASSERT_OFFSET(BKMeshUniforms, cameraPosition, 128);
BK_GPU_ASSERT_OFFSET(BKMeshUniforms, cameraRight, 144);
BK_GPU_ASSERT_OFFSET(BKMeshUniforms, cameraUp, 160);
BK_GPU_ASSERT_OFFSET(BKMeshUniforms, cameraForward, 176);
BK_GPU_ASSERT_OFFSET(BKMeshUniforms, color, 192);
BK_GPU_ASSERT_OFFSET(BKMeshUniforms, halfWidth, 208);
BK_GPU_ASSERT_OFFSET(BKMeshUniforms, nearDistance, 216);
BK_GPU_ASSERT_OFFSET(BKMeshUniforms, ambient, 224);
BK_GPU_ASSERT_OFFSET(BKMeshUniforms, projection, 240);
BK_GPU_ASSERT_OFFSET(BKMeshUniforms, lit, 252);
BK_GPU_ASSERT_OFFSET(BKMeshUniforms, viewportWidth, 256);
BK_GPU_ASSERT_OFFSET(BKMeshUniforms, lineHalfWidth, 264);
BK_GPU_ASSERT_OFFSET(BKMeshUniforms, paddingForAlignment, 268);
BK_GPU_STATIC_ASSERT(sizeof(BKMeshGPUVertex) == 40, "BKMeshGPUVertex must stay 40 bytes (10 floats)");
BK_GPU_ASSERT_OFFSET(BKMeshGPUVertex, normal, 12);
BK_GPU_ASSERT_OFFSET(BKMeshGPUVertex, color, 24);

#define BK_MESH_STRINGIFY_(...) #__VA_ARGS__
#define BK_MESH_STRINGIFY(...) BK_MESH_STRINGIFY_(__VA_ARGS__)

#endif
