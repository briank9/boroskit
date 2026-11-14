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
//  - Two colour targets (RGBA8 colour + R32_SFLOAT ray distance) with premultiplied
//    "over" blending on the first only, plus a D32_SFLOAT depth buffer.
// ---------------------------------------------------------------------------------------

#ifndef BK_MESH_SHADER_TYPES_H
#define BK_MESH_SHADER_TYPES_H

#include <simd/simd.h>
#include <stdint.h>

typedef simd_float4   bk_mesh_float4;
typedef simd_float4x4 bk_mesh_float4x4;

#define BK_MESH_UNIFORM_FIELDS \
    bk_mesh_float4x4 model;        /* object -> patient mm (the object's placement) */ \
    bk_mesh_float4x4 normalMatrix; /* turns normals with the object (inverse-transpose of model) */ \
    bk_mesh_float4 cameraPosition; /* xyz: ortho = centre of the image plane; perspective = the eye (mm) */ \
    bk_mesh_float4 cameraRight;    /* xyz: unit vector to the right of the image */ \
    bk_mesh_float4 cameraUp;       /* xyz: unit vector to the top of the image */ \
    bk_mesh_float4 cameraForward;  /* xyz: unit viewing direction */ \
    bk_mesh_float4 color;          /* rgb = object colour, a = opacity */ \
    float halfWidth;               /* ortho: half image width in mm; perspective: tan(half horizontal angle) */ \
    float halfHeight;              /* ortho: half image height in mm; perspective: tan(half vertical angle) */ \
    float nearDistance;            /* depth range (mm along the view direction) that is kept */ \
    float farDistance; \
    float ambient;                 /* lighting, same meaning as BKVolumeRenderer's */ \
    float diffuse; \
    float specular; \
    float specularPower; \
    int32_t projection;            /* BKProjection: 0 orthographic, 1 perspective */ \
    int32_t useVertexColors;       /* 1 = take the colour from the mesh's vertices */ \
    int32_t hasNormals;            /* 0 = no vertex normals: shade each triangle flat */ \
    int32_t lit;                   /* 0 = flat colour, no lighting (labels, lines) */ \
    float viewportWidth;           /* size of the drawing area in pixels (lines are sized in pixels) */ \
    float viewportHeight; \
    float lineHalfWidth;           /* lines: half the line width in pixels */ \
    float paddingForAlignment;

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

#define BK_MESH_STRINGIFY_(...) #__VA_ARGS__
#define BK_MESH_STRINGIFY(...) BK_MESH_STRINGIFY_(__VA_ARGS__)

#endif
